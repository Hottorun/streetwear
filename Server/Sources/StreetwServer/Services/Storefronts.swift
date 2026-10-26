// Storefronts.swift
// Which of a brand's shops is read, and which one each person is served.
//
// A brand has a main shop — the brand row and every source with no storefront — and, where
// somebody attached one, shops that each serve a set of countries (`StorefrontModel`,
// `StorefrontCountryModel`): `uk.example.com` for Britain, `eu.kith.com` for 48 countries at
// once. Three questions are asked of that, by four callers, and they are answered here so that
// they cannot disagree:
//
// - **Is a shop read at all?** Only while one of its countries is switched on
//   (`STOREFRONT_COUNTRIES`) and somebody there follows the brand — `wanted`, asked by the
//   poller once per tick. Each country multiplies the polling of every brand followed there,
//   which is why it is paid for only where somebody is. A shop is read once however many of its
//   countries ask for it: membership decides *whether*, and the claim is per source.
// - **Which shop serves this person?** The one whose set holds their country, when that country
//   is switched on, the shop is being read and it has been read once — `serving`. Otherwise the
//   main shop, which is what everybody was served before this existed. Asked by the feed, a
//   brand's feed, Discover, every route that hands over a brand, and `Notifier`.
// - **Has a paused shop been away long enough to start again from a baseline?** —
//   `hasLapsed`, of the shop as a whole: its sources are read for all its countries at once.
//
// **One shop per brand per person, never both.** A reader in Britain served the British shop
// and the American one would see every drop twice, once in each currency, and be pushed twice.
// `storefront_countries` is unique on (brand, country), so no country can name two.

import Fluent
import Foundation
import StreetwCore
import Vapor

struct StorefrontCountriesKey: StorageKey {
    typealias Value = Set<String>
}

extension Application {
    /// The countries switched on, from `STOREFRONT_COUNTRIES` at boot. Empty unless set, which
    /// is every brand's main shop for everybody — the behaviour before storefronts existed.
    var storefrontCountries: Set<String> {
        get { storage[StorefrontCountriesKey.self] ?? [] }
        set { storage[StorefrontCountriesKey.self] = newValue }
    }
}

enum Storefronts {
    /// How long a shop can go unread before its next read is a baseline again.
    ///
    /// A day, because nothing else ever leaves a source unread that long — the longest failure
    /// backoff is six hours and the quiet cadence two — so a gap this size only means the shop
    /// was paused for want of a follower in any of its countries. What it knew then is stale,
    /// and comparing against it would announce everything since as news to whoever follows it
    /// next.
    static let resumeAfter: TimeInterval = 86_400

    /// `STOREFRONT_COUNTRIES` — "GB,DE", spaces allowed — as codes. Anything that is not a
    /// country code is dropped rather than failing the boot. The admin routes read their
    /// `countries=` the same way.
    static func countries(from raw: String?) -> Set<String> {
        Set(
            (raw ?? "")
                .split(whereSeparator: { $0 == "," || $0.isWhitespace })
                .compactMap { CountryCode.normalized(String($0)) }
        )
    }

    /// The countries an admin route was asked about.
    enum Requested: Equatable {
        /// Nothing named. The attach route answers with its offer and writes nothing.
        case unnamed
        /// `all`: every country the shop's `/meta.json` ships to that no other shop of the
        /// brand serves.
        case all
        case these(Set<String>)
        /// Something that is not a country code — refused whole, never half-applied, because
        /// a dropped "Deutschland" would attach a shop for everybody but the country meant.
        case invalid([String])
    }

    /// `countries=DE,FR,IT`, `country=GB`, or a JSON body's `countries`, all read alike.
    static func requested(_ raws: [String]) -> Requested {
        let tokens = raws.flatMap { $0.split(whereSeparator: { $0 == "," || $0.isWhitespace }).map(String.init) }
        guard !tokens.isEmpty else { return .unnamed }
        if tokens.count == 1, tokens[0].lowercased() == "all" { return .all }
        let rejected = tokens.filter { CountryCode.normalized($0) == nil }
        guard rejected.isEmpty else { return .invalid(rejected) }
        return .these(Set(tokens.compactMap(CountryCode.normalized)))
    }

    static func hasLapsed(since lastRead: Date?, now: Date = Date()) -> Bool {
        guard let lastRead else { return false }
        return now.timeIntervalSince(lastRead) > resumeAfter
    }

    /// Whether a shop serves a person — the whole rule, without a database.
    ///
    /// - Parameters:
    ///   - countries: who the shop serves.
    ///   - isRead: whether the shop is being read at all (`isRead(_:brand:enabled:followed:)`).
    ///     For a person who follows the brand from one of its countries this is always true;
    ///     for Discover, which is about brands the caller does *not* follow, it is the real
    ///     question — a shop nobody in any of its countries follows is not polled, and its
    ///     prices are as old as its last follower.
    ///   - baselined: whether the shop has been read once. Until then it holds nothing, and the
    ///     main shop is what there is to show.
    static func serves(
        countries: Set<String>,
        to person: String?,
        enabled: Set<String>,
        isRead: Bool,
        baselined: Bool
    ) -> Bool {
        guard let person = CountryCode.normalized(person), countries.contains(person) else { return false }
        return enabled.contains(person) && isRead && baselined
    }

    /// Whether a shop is polled: one of its countries is switched on and has a follower of the
    /// brand. `wanted` and `serving` both ask it, so a shop is never served on a rule the
    /// poller does not read it by.
    static func isRead(
        _ countries: some Sequence<String>,
        brand: UUID,
        enabled: Set<String>,
        followed: Set<Following>
    ) -> Bool {
        countries.contains { enabled.contains($0) && followed.contains(Following(brand: brand, country: $0)) }
    }

    /// The storefronts the poller should read this tick — each once, however many of its
    /// countries have a follower.
    static func wanted(enabled: Set<String>, on db: any Database) async throws -> Set<UUID> {
        guard !enabled.isEmpty else { return [] }
        let memberships = try await StorefrontCountryModel.query(on: db)
            .filter(\.$country ~~ Array(enabled))
            .all()
        guard !memberships.isEmpty else { return [] }

        let followed = try await followedCountries(
            brandIDs: Set(memberships.map(\.brandID)),
            countries: Set(memberships.map(\.country)),
            on: db
        )
        return Set(
            memberships
                .filter { isRead([$0.country], brand: $0.brandID, enabled: enabled, followed: followed) }
                .map(\.$storefront.id)
        )
    }

    /// The storefront serving a person in `country`, per brand — only for brands where one
    /// does. A brand missing from the answer is served its main shop.
    ///
    /// Returns at once, without a query, for a person with no country or one not switched on,
    /// which is everybody until a country is: every route asks this, and for them it must cost
    /// nothing. The storefronts come back with their sources and countries loaded, for
    /// `BrandDTO`.
    ///
    /// - Parameter brandIDs: the brands in question, or nil for every brand — Discover pages
    ///   through the whole catalogue.
    static func serving(
        country raw: String?,
        enabled: Set<String>,
        brandIDs: [UUID]? = nil,
        on db: any Database
    ) async throws -> [UUID: StorefrontModel] {
        guard let country = CountryCode.normalized(raw), enabled.contains(country) else { return [:] }
        if let brandIDs, brandIDs.isEmpty { return [:] }

        let memberships = StorefrontCountryModel.query(on: db).filter(\.$country == country)
        if let brandIDs { memberships.filter(\.$brandID ~~ brandIDs) }
        let ids = try await memberships.all().map(\.$storefront.id)
        guard !ids.isEmpty else { return [:] }

        let storefronts = try await StorefrontModel.query(on: db)
            .filter(\.$id ~~ ids)
            .with(\.$sources)
            .with(\.$countries)
            .all()
        // Whether each shop is being read, which may be on another of its countries' account:
        // a German follower keeps `eu.kith.com` read for somebody browsing it from France.
        let followed = try await followedCountries(
            brandIDs: Set(storefronts.map(\.$brand.id)),
            countries: Set(storefronts.flatMap(\.countryCodes)).intersection(enabled),
            on: db
        )
        var serving: [UUID: StorefrontModel] = [:]
        for storefront in storefronts {
            let codes = storefront.countryCodes
            guard serves(
                countries: Set(codes),
                to: country,
                enabled: enabled,
                isRead: isRead(codes, brand: storefront.$brand.id, enabled: enabled, followed: followed),
                baselined: storefront.sources.contains { $0.baselinedAt != nil }
            ) else { continue }
            serving[storefront.$brand.id] = storefront
        }
        return serving
    }

    /// The caller's storefronts: those of the profile the request acts for, whose country is
    /// its account's (`Accounts.setCountry`) — so every profile is served where its holder is.
    static func serving(
        _ req: Request,
        brandIDs: [UUID]? = nil
    ) async throws -> [UUID: StorefrontModel] {
        let enabled = req.application.storefrontCountries
        // Nothing switched on is the common case, and it must not cost even the user row.
        guard !enabled.isEmpty else { return [:] }
        let user = try await req.actingUser()
        return try await serving(country: user.country, enabled: enabled, brandIDs: brandIDs, on: req.db)
    }

    /// The brand's shops in any of `countries`, with their sources and countries — what
    /// `Notifier` chooses among per follower. Not asked at all while no country is switched on.
    static func live(brandIDs: Set<UUID>, enabled: Set<String>, on db: any Database) async throws -> [StorefrontModel] {
        guard !enabled.isEmpty, !brandIDs.isEmpty else { return [] }
        let ids = try await StorefrontCountryModel.query(on: db)
            .filter(\.$brandID ~~ Array(brandIDs))
            .filter(\.$country ~~ Array(enabled))
            .all()
            .map(\.$storefront.id)
        guard !ids.isEmpty else { return [] }
        return try await StorefrontModel.query(on: db)
            .filter(\.$id ~~ Array(Set(ids)))
            .with(\.$sources)
            .with(\.$countries)
            .all()
    }

    /// Adds countries to a shop. The caller has checked that no other shop of the brand holds
    /// them; the unique constraint is the guard behind that check, not the check.
    static func add(_ countries: Set<String>, to storefront: StorefrontModel, on db: any Database) async throws {
        let id = try storefront.requireID()
        for country in countries.sorted() {
            try await StorefrontCountryModel(storefrontID: id, brandID: storefront.$brand.id, country: country)
                .create(on: db)
        }
    }

    /// What `release` did, for the admin route to say.
    struct Released {
        /// Shops left serving nobody, removed with what was read from them: (url, products).
        var removed: [(url: String, products: Int)] = []
        /// Shops that gave up some countries and kept others: (url, the countries taken).
        var narrowed: [(url: String, countries: [String])] = []
    }

    /// Takes `countries` off whichever of the brand's shops serve them — the attach route's
    /// "replace", generalised from one country to a set.
    ///
    /// A shop left with none is removed, history and all, which is what replacing a
    /// one-country shop always did. A shop left with some keeps them and its history, and moves
    /// its `homeCountry` to one it still serves. Run it inside a transaction, and before the
    /// countries are given to anybody else.
    static func release(
        _ countries: Set<String>,
        brandID: UUID,
        on db: any Database
    ) async throws -> Released {
        var released = Released()
        guard !countries.isEmpty else { return released }
        let holding = try await StorefrontModel.query(on: db)
            .filter(\.$brand.$id == brandID)
            .with(\.$countries)
            .all()
        for storefront in holding {
            let taken = storefront.countries.filter { countries.contains($0.country) }
            guard !taken.isEmpty, let id = storefront.id else { continue }
            let kept = storefront.countryCodes.filter { !countries.contains($0) }
            if kept.isEmpty {
                released.removed.append((storefront.url, try await remove(id, on: db)))
            } else {
                try await narrow(storefront, removing: Set(taken.map(\.country)), keeping: kept, on: db)
                released.narrowed.append((storefront.url, taken.map(\.country).sorted()))
            }
        }
        return released
    }

    /// Takes countries off a shop that keeps serving others. Its products and events stay —
    /// the shop is still read, for whoever is left — and a person in a country taken off is
    /// served the main shop from their next request.
    static func narrow(
        _ storefront: StorefrontModel,
        removing: Set<String>,
        keeping: [String],
        on db: any Database
    ) async throws {
        let id = try storefront.requireID()
        try await StorefrontCountryModel.query(on: db)
            .filter(\.$storefront.$id == id)
            .filter(\.$country ~~ Array(removing))
            .delete()
        if removing.contains(storefront.homeCountry), let home = keeping.sorted().first {
            storefront.homeCountry = home
            try await storefront.update(on: db)
        }
    }

    /// Deletes a storefront and everything read from it, returning how many products went.
    ///
    /// **The products by hand, because the cascade does not reach them.** `sources` cascades
    /// from the storefront, but `products.source_id` is `ON DELETE SET NULL` — from the initial
    /// schema — so a bare delete would leave the shop's whole catalogue behind with no source,
    /// still carrying the storefront's id, and its events in the feed of nobody. Products first
    /// (their events cascade on `product_id`), then any event left with the storefront's id,
    /// then its sources, its countries and the row. Run it inside a transaction.
    @discardableResult
    static func remove(_ id: UUID, on db: any Database) async throws -> Int {
        let products = try await ProductModel.query(on: db).filter(\.$storefrontID == id).count()
        try await ProductModel.query(on: db).filter(\.$storefrontID == id).delete()
        try await EventModel.query(on: db).filter(\.$storefrontID == id).delete()
        // The foreign keys would take these, where the database enforces them; said outright
        // so the answer does not depend on a pragma.
        try await SourceModel.query(on: db).filter(\.$storefront.$id == id).delete()
        try await StorefrontCountryModel.query(on: db).filter(\.$storefront.$id == id).delete()
        try await StorefrontModel.query(on: db).filter(\.$id == id).delete()
        return products
    }

    /// A brand somebody in a country follows.
    struct Following: Hashable {
        var brand: UUID
        var country: String
    }

    /// Which (brand, country) pairs have a follower, among these brands and countries.
    ///
    /// A join rather than two queries: the follow list of a popular brand is long, and only
    /// the followers in a country with a shop are wanted.
    static func followedCountries(
        brandIDs: Set<UUID>,
        countries: Set<String>,
        on db: any Database
    ) async throws -> Set<Following> {
        guard !brandIDs.isEmpty, !countries.isEmpty else { return [] }
        let follows = try await FollowModel.query(on: db)
            .join(UserModel.self, on: \FollowModel.$user.$id == \UserModel.$id)
            .filter(\.$brand.$id ~~ Array(brandIDs))
            .filter(UserModel.self, \.$country ~~ Array(countries))
            .all()
        return Set(try follows.compactMap { follow in
            guard let country = try follow.joined(UserModel.self).country else { return nil }
            return Following(brand: follow.$brand.id, country: country)
        })
    }
}

extension ProductModel {
    /// What this row's prices are in, for the wire.
    ///
    /// Its own when the read said; otherwise, for a main-shop row, the brand's — every row
    /// from before currencies were stored is the main shop's, so that is the truth for it. A
    /// country shop's row with none says none: the brand's currency is a different shop's.
    func priceCurrency(main: String?) -> String? {
        currency ?? (storefrontID == nil ? main : nil)
    }
}

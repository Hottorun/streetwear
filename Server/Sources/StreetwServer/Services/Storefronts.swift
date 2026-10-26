// Storefronts.swift
// Which of a brand's shops is read, and which one each person is served.
//
// A brand has a main shop — the brand row and every source with no storefront — and, where
// somebody attached one, a shop per country (`StorefrontModel`). Three questions are asked of
// that, by four callers, and they are answered here so that they cannot disagree:
//
// - **Is a country's shop read at all?** Only while its country is switched on
//   (`STOREFRONT_COUNTRIES`) and somebody there follows the brand — `wanted`, asked by the
//   poller once per tick. Each country multiplies the polling of every brand followed there,
//   which is why it is paid for only where somebody is.
// - **Which shop serves this person?** Their country's, when it is switched on, the brand has
//   one, somebody there follows the brand and it has been read once — `serving`. Otherwise the
//   main shop, which is what everybody was served before this existed. Asked by the feed, a
//   brand's feed, Discover, every route that hands over a brand, and `Notifier`.
// - **Has a paused shop been away long enough to start again from a baseline?** —
//   `hasLapsed`.
//
// **One shop per brand per person, never both.** A reader in Britain served the British shop
// and the American one would see every drop twice, once in each currency, and be pushed twice.

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
    /// How long a country's shop can go unread before its next read is a baseline again.
    ///
    /// A day, because nothing else ever leaves a source unread that long — the longest failure
    /// backoff is six hours and the quiet cadence two — so a gap this size only means the shop
    /// was paused for want of a follower. What it knew then is stale, and comparing against it
    /// would announce everything since as news to whoever follows it next.
    static let resumeAfter: TimeInterval = 86_400

    /// `STOREFRONT_COUNTRIES` — "GB,DE", spaces allowed — as codes. Anything that is not a
    /// country code is dropped rather than failing the boot.
    static func countries(from raw: String?) -> Set<String> {
        Set(
            (raw ?? "")
                .split(whereSeparator: { $0 == "," || $0.isWhitespace })
                .compactMap { CountryCode.normalized(String($0)) }
        )
    }

    static func hasLapsed(since lastRead: Date?, now: Date = Date()) -> Bool {
        guard let lastRead else { return false }
        return now.timeIntervalSince(lastRead) > resumeAfter
    }

    /// Whether one country's shop serves a person there — the whole rule, without a database.
    ///
    /// - Parameters:
    ///   - followedThere: whether anybody in the shop's country follows the brand. For a
    ///     person who follows it themselves this is always true; for Discover, which is about
    ///     brands the caller does *not* follow, it is the question of whether the shop is being
    ///     read at all — a shop nobody there follows is not polled, and its prices are as old as
    ///     its last follower.
    ///   - baselined: whether the shop has been read once. Until then it holds nothing, and the
    ///     main shop is what there is to show.
    static func serves(
        country: String,
        to person: String?,
        enabled: Set<String>,
        followedThere: Bool,
        baselined: Bool
    ) -> Bool {
        guard let person = CountryCode.normalized(person), person == country else { return false }
        return enabled.contains(country) && followedThere && baselined
    }

    /// The country storefronts the poller should read this tick.
    static func wanted(enabled: Set<String>, on db: any Database) async throws -> Set<UUID> {
        guard !enabled.isEmpty else { return [] }
        let storefronts = try await StorefrontModel.query(on: db)
            .filter(\.$country ~~ Array(enabled))
            .all()
        guard !storefronts.isEmpty else { return [] }

        let followed = try await followedCountries(
            brandIDs: Set(storefronts.map(\.$brand.id)),
            countries: Set(storefronts.map(\.country)),
            on: db
        )
        return Set(
            storefronts
                .filter { followed.contains(Following(brand: $0.$brand.id, country: $0.country)) }
                .compactMap(\.id)
        )
    }

    /// The storefront serving a person in `country`, per brand — only for brands where one
    /// does. A brand missing from the answer is served its main shop.
    ///
    /// Returns at once, without a query, for a person with no country or one not switched on,
    /// which is everybody until a country is: every route asks this, and for them it must cost
    /// nothing. The storefronts come back with their sources loaded, for `BrandDTO`.
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

        let query = StorefrontModel.query(on: db)
            .filter(\.$country == country)
            .with(\.$sources)
        if let brandIDs { query.filter(\.$brand.$id ~~ brandIDs) }
        let storefronts = try await query.all()
        guard !storefronts.isEmpty else { return [:] }

        let followed = try await followedCountries(
            brandIDs: Set(storefronts.map(\.$brand.id)),
            countries: [country],
            on: db
        )
        var serving: [UUID: StorefrontModel] = [:]
        for storefront in storefronts where serves(
            country: storefront.country,
            to: country,
            enabled: enabled,
            followedThere: followed.contains(Following(brand: storefront.$brand.id, country: country)),
            baselined: storefront.sources.contains { $0.baselinedAt != nil }
        ) {
            serving[storefront.$brand.id] = storefront
        }
        return serving
    }

    /// The caller's storefronts, for a route that has the device in hand.
    static func serving(
        _ req: Request,
        device: DeviceModel,
        brandIDs: [UUID]? = nil
    ) async throws -> [UUID: StorefrontModel] {
        let enabled = req.application.storefrontCountries
        // Nothing switched on is the common case, and it must not cost even the user row.
        guard !enabled.isEmpty else { return [:] }
        let user = try await device.$user.get(on: req.db)
        return try await serving(country: user.country, enabled: enabled, brandIDs: brandIDs, on: req.db)
    }

    /// Deletes a storefront and everything read from it, returning how many products went.
    ///
    /// **The products by hand, because the cascade does not reach them.** `sources` cascades
    /// from the storefront, but `products.source_id` is `ON DELETE SET NULL` — from the initial
    /// schema — so a bare delete would leave the shop's whole catalogue behind with no source,
    /// still carrying the storefront's id, and its events in the feed of nobody. Products first
    /// (their events cascade on `product_id`), then any event left with the storefront's id,
    /// then its sources and the row. Run it inside a transaction.
    @discardableResult
    static func remove(_ id: UUID, on db: any Database) async throws -> Int {
        let products = try await ProductModel.query(on: db).filter(\.$storefrontID == id).count()
        try await ProductModel.query(on: db).filter(\.$storefrontID == id).delete()
        try await EventModel.query(on: db).filter(\.$storefrontID == id).delete()
        // The foreign key would take these, where the database enforces it; said outright so
        // the answer does not depend on a pragma.
        try await SourceModel.query(on: db).filter(\.$storefront.$id == id).delete()
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

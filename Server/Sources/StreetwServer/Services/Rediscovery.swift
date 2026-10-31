// Rediscovery.swift
// Looking at every brand in the catalogue again, once, under discovery's current rules.
//
// A brand's sources are decided the day it is added and never revisited. Discovery has learned
// since — feed index pages, UCP behind a rate-limited catalogue, Shopify on `www.`, country
// shops from `hreflang` — and none of it reached a brand added before it did. Subdued is the
// case that forced this: watched in production by a page watch alone, because its sitemap went
// away, while `/rss` lists a feed of its new products and its homepage names a Shopify store for
// the US.
//
// So once per pass, in the background, each brand is discovered again, one at a time, and:
//
// - **Gains what it lacks, and loses nothing.** A source is added only where the brand has no
//   source of that role: something that reads its products (Shopify, UCP, a sitemap, a feed of
//   new products) only when it reads none — two would name the same garments under two ids and
//   put every one on screen twice — `collections` only beside a Shopify catalogue, a blog's
//   feed only when it has no feed. A better catalogue found beside a working one is *said*, in
//   the line, for `…/repoint` by hand. **Never a page watch**, and never a removal: a page watch
//   on a brand nobody asked about would put its banner swaps into its followers' feeds overnight,
//   and the one it has stays — it is the only lock detector.
//   A product source that has never been read and is failing does not count as reading: that is
//   the apex Shopify a Hydrogen storefront 404s, and the `www.` catalogue beside it is the fix.
// - **Every added source's first read is a baseline**, by the poll's own rule — `baselined_at`
//   starts nil — so a brand's back catalogue arrives as context, never as a drop to everybody
//   following it (`docs/design-decisions.md`, *baselines*).
// - **Country shops are attached** from its homepage's `hreflang` (`CountryShops`).
// - **Politely and slowly.** One brand at a time through the shared `PoliteFetcher`, a brand
//   every `REDISCOVERY_INTERVAL` seconds (60) after a few minutes' grace at boot: a few hundred
//   brands over a few hours, each of them ten-odd requests at the host's own spacing.
// - **Once per pass.** A pass is the rules' `version` and the countries switched on
//   (`pass(countries:)`), so switching a country on looks at every brand again for its shop
//   there. `rediscoveries` holds a row per brand per pass, written before the first request, so a
//   restart resumes with the next brand and no brand is looked at twice; a row a dead process left
//   unfinished is taken again after `abandonAfter`. A brand a check adds is discovered by the
//   check under these same rules and gets its row then.
//
// `GET /admin/rediscovery` reads the ledger back; `DISABLE_REDISCOVERY=true` switches it off.

import Fluent
import Foundation
import StreetwCore
import Vapor

enum Rediscovery {
    /// The rules' revision. Bumping it looks at every brand again — do that when discovery
    /// learns something a brand added before it should have, or a country is switched on.
    static let version = 1

    /// Between brands.
    static let interval: TimeInterval = 60

    /// After boot, so a deploy's first polls are not queued behind a brand's discovery.
    static let startAfter: TimeInterval = 5 * 60

    /// A look started this long ago and never finished was on a process that died.
    static let abandonAfter: TimeInterval = 30 * 60

    /// A source the brand already has, as the additions rule sees it.
    struct Held: Equatable {
        var kind: BrandSource.Kind
        var url: URL
        /// False for a source that has never been read and is failing — it reads nothing.
        var isReading: Bool
    }

    struct Additions: Equatable {
        var sources: [BrandSource] = []
        /// Things found and deliberately not added, for the line.
        var notes: [String] = []
    }

    /// What a brand gains from what discovery found now — the whole rule, without a request.
    static func additions(to held: [Held], from found: DiscoveredSources) -> Additions {
        var result = Additions()
        func has(_ kind: BrandSource.Kind, _ url: URL) -> Bool {
            held.contains { $0.kind == kind && same($0.url, url) }
                || result.sources.contains { $0.kind == kind && same($0.url, url) }
        }
        var readsProducts = held.contains { $0.isReading && BrandDiscovery.readsProducts(kind: $0.kind, url: $0.url) }
        var hasShopify = held.contains { $0.kind == .shopify }

        for source in found.sources where source.kind.isAutomatic && source.kind != .page {
            guard !has(source.kind, source.url) else { continue }
            let isProducts = source.kind == .feed
                ? found.feedAnnouncesProducts || FeedSource.announcesProducts(url: source.url)
                : BrandDiscovery.readsProducts(kind: source.kind, url: source.url)
            if isProducts {
                guard !readsProducts else {
                    result.notes.append("found \(describe(source)) beside the catalogue it reads — not added; repoint by hand")
                    continue
                }
                result.sources.append(source)
                readsProducts = true
                if source.kind == .shopify { hasShopify = true }
            } else if source.kind == .collections {
                guard hasShopify, !held.contains(where: { $0.kind == .collections }) else { continue }
                result.sources.append(source)
            } else if source.kind == .feed {
                guard !held.contains(where: { $0.kind == .feed }) else { continue }
                result.sources.append(source)
            }
        }
        return result
    }

    /// "+feed new_products", "+ucp us.subdued.com", "+sitemap /sitemap_us_en.xml".
    static func describe(_ source: BrandSource) -> String {
        let path = source.url.path(percentEncoded: false)
        switch source.kind {
        case .feed:
            if let marker = FeedSource.productPathMarkers.first(where: path.lowercased().contains) {
                return "feed \(marker)"
            }
            return "feed \(path)"
        case .sitemap:
            return "sitemap \(path)"
        default:
            return "\(source.kind.rawValue) \(source.url.host() ?? source.url.absoluteString)"
        }
    }

    /// One look, start to finish: discover, add, attach, record. Never throws away the row's
    /// claim on failure — a brand whose look failed is recorded as failed, not looked at again.
    @discardableResult
    static func look(at row: RediscoveryModel, app: Application, http: any HTTPFetching) async -> String {
        let db = app.db
        let brandID = row.$brand.id
        var line: String
        do {
            guard let brand = try await BrandModel.query(on: db).filter(\.$id == brandID).with(\.$sources).first() else {
                try await row.delete(on: db)
                return ""
            }
            let name = brand.website.flatMap { URL(string: $0)?.host() } ?? brand.slug
            let website = brand.website ?? "https://\(brand.slug)"
            let found = await BrandDiscovery.discover(website: website, instagramHandle: nil, http: http)

            let main = brand.sources.filter { $0.$storefront.id == nil }
            let held = main.compactMap { source -> Held? in
                guard let kind = BrandSource.Kind(rawValue: source.kind), let url = URL(string: source.url) else { return nil }
                return Held(kind: kind, url: url, isReading: source.baselinedAt != nil || source.failureCount == 0)
            }
            let additions = additions(to: held, from: found)
            for source in additions.sources {
                // Un-baselined, so its first read is context rather than news.
                try await SourceModel(brandID: brandID, kind: source.kind, url: source.url.absoluteString).save(on: db)
            }

            let shops = try await CountryShops.attach(
                brandID: brandID,
                alternates: found.alternates,
                enabled: app.storefrontCountries,
                http: http,
                on: db
            )

            let parts = additions.sources.map { "+" + describe($0) } + shops.map(\.line) + additions.notes
            if found.sources.isEmpty, parts.isEmpty {
                line = "\(name): nothing answered; left as it was"
            } else {
                line = "\(name): " + (parts.isEmpty ? "nothing new" : parts.joined(separator: ", "))
            }
            row.added = additions.sources.count
            row.storefronts = shops.filter(\.isAttached).count
        } catch {
            line = "brand \(brandID): failed — \(error)"
        }
        row.line = line
        row.finishedAt = Date()
        do {
            try await row.save(on: db)
        } catch {
            app.logger.error("rediscovery: could not record \(brandID): \(error)")
        }
        if row.added > 0 || row.storefronts > 0 {
            app.logger.notice("rediscovery: \(line)")
        } else {
            app.logger.info("rediscovery: \(line)")
        }
        return line
    }

    /// Which pass a look belongs to: the rules' version and the countries switched on, so
    /// switching a country on — after the pass, or with the deploy that brings it — looks at
    /// every brand again for its shops there, where a version alone would have run once with
    /// whatever `STOREFRONT_COUNTRIES` said that day.
    static func pass(countries: Set<String>) -> String {
        "\(version):" + countries.sorted().joined(separator: ",")
    }

    /// Claims the next brand to look at in this pass: a look a dead process left, else the
    /// next brand with no row. The row is the claim, and its unique key is what keeps two
    /// instances off one brand.
    static func claimNext(
        on db: any Database,
        countries: Set<String> = [],
        now: Date = Date()
    ) async throws -> RediscoveryModel? {
        let pass = pass(countries: countries)
        if let stale = try await RediscoveryModel.query(on: db)
            .filter(\.$pass == pass)
            .filter(\.$finishedAt == nil)
            .filter(\.$startedAt < now.addingTimeInterval(-abandonAfter))
            .first() {
            stale.startedAt = now
            try await stale.save(on: db)
            return stale
        }
        let claimed = Set(try await RediscoveryModel.query(on: db)
            .filter(\.$pass == pass)
            .all()
            .map(\.$brand.id))
        let brands = try await BrandModel.query(on: db).sort(\.$slug).all().compactMap(\.id)
        for brandID in brands where !claimed.contains(brandID) {
            let row = RediscoveryModel(brandID: brandID, pass: pass, startedAt: now)
            do {
                try await row.create(on: db)
                return row
            } catch {
                // Another instance took it between the read and the write — the unique key.
                let taken = try await RediscoveryModel.query(on: db)
                    .filter(\.$pass == pass).filter(\.$brand.$id == brandID).count() > 0
                if taken { continue }
                throw error
            }
        }
        return nil
    }

    /// The row of a brand in this pass, if it has one.
    static func row(brandID: UUID, countries: Set<String>, on db: any Database) async throws -> RediscoveryModel? {
        try await RediscoveryModel.query(on: db)
            .filter(\.$pass == pass(countries: countries)).filter(\.$brand.$id == brandID).first()
    }

    /// Records a brand a check has just discovered under these rules, so the pass leaves it be.
    static func record(brandID: UUID, line: String, countries: Set<String>, on db: any Database) async throws {
        let exists = try await row(brandID: brandID, countries: countries, on: db)
        let row = exists ?? RediscoveryModel(brandID: brandID, pass: pass(countries: countries))
        row.finishedAt = Date()
        row.line = line
        try await row.save(on: db)
    }

    struct Summary: Content {
        var pass: String
        var brands: Int
        var finished: Int
        var running: Int
        var sourcesAdded: Int
        var storefrontsAttached: Int
    }

    static func summary(on db: any Database, countries: Set<String>) async throws -> Summary {
        let pass = pass(countries: countries)
        let rows = try await RediscoveryModel.query(on: db).filter(\.$pass == pass).all()
        let finished = rows.filter { $0.finishedAt != nil }
        return Summary(
            pass: pass,
            brands: try await BrandModel.query(on: db).count(),
            finished: finished.count,
            running: rows.count - finished.count,
            sourcesAdded: finished.reduce(0) { $0 + $1.added },
            storefrontsAttached: finished.reduce(0) { $0 + $1.storefronts }
        )
    }

    /// Whether two source URLs name the same thing: scheme, case and a trailing slash aside.
    static func same(_ a: URL, _ b: URL) -> Bool {
        func key(_ url: URL) -> String {
            var path = url.path(percentEncoded: true)
            while path.hasSuffix("/") { path.removeLast() }
            let query = url.query(percentEncoded: true).map { "?\($0)" } ?? ""
            return (url.host()?.lowercased() ?? "") + path + query
        }
        return key(a) == key(b)
    }
}

/// Runs `Rediscovery` in the background, a brand at a time, until every brand has a row for
/// the current version — then checks every quarter of an hour for brands added another way.
actor RediscoveryLoop {
    private let app: Application
    private let http: any HTTPFetching
    private let interval: TimeInterval
    private let startAfter: TimeInterval
    private var task: Task<Void, Never>?

    init(
        app: Application,
        http: any HTTPFetching,
        interval: TimeInterval = Rediscovery.interval,
        startAfter: TimeInterval = Rediscovery.startAfter
    ) {
        self.app = app
        self.http = http
        self.interval = interval
        self.startAfter = startAfter
    }

    func start() {
        guard task == nil else { return }
        task = Task { await self.run() }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    private func run() async {
        let logger = app.logger
        let countries = app.storefrontCountries
        if let summary = try? await Rediscovery.summary(on: app.db, countries: countries), summary.finished < summary.brands {
            logger.notice("rediscovery \(summary.pass): \(summary.brands - summary.finished) of \(summary.brands) brands to look at, one every \(Int(interval))s from \(Int(startAfter))s after boot")
        }
        try? await Task.sleep(for: .seconds(startAfter))
        var saidDone = false
        while !Task.isCancelled {
            do {
                if let row = try await Rediscovery.claimNext(on: app.db, countries: countries) {
                    saidDone = false
                    await Rediscovery.look(at: row, app: app, http: http)
                    try? await Task.sleep(for: .seconds(interval))
                    continue
                }
                if !saidDone, let summary = try? await Rediscovery.summary(on: app.db, countries: countries) {
                    logger.notice("rediscovery \(summary.pass): done —\(summary.finished) brands looked at, +\(summary.sourcesAdded) sources, +\(summary.storefrontsAttached) storefronts (GET /admin/rediscovery)")
                    saidDone = true
                }
            } catch {
                logger.error("rediscovery: \(error)")
            }
            try? await Task.sleep(for: .seconds(15 * 60))
        }
    }
}

struct RediscoveryLoopKey: StorageKey {
    typealias Value = RediscoveryLoop
}

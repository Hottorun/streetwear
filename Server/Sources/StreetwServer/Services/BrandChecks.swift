// BrandChecks.swift
// Discovery, run off the request.
//
// `POST /v1/brands/discover` ran `BrandDiscovery.discover` inside the request and said
// nothing until it finished. A site that is not on Shopify costs about thirteen requests at
// the politeness interval — subdued.com measured 26.8s — and the app gives up after thirty
// seconds of silence, so "this site can't be added" was very often the app timing out on a
// site that was perfectly readable. The add screen also asked twice, once to preview and
// once to add, and paid the whole cost both times.
//
// So a check is a row. Starting one answers at once; the phone asks again until it
// settles; somebody who asks about the same shop within `reuseFor` shares it, which is what
// makes the add reuse the preview. Watching a check that is still running is a standing
// request — settled into a follow, and a push, when it finishes.

import Fluent
import Foundation
import StreetwCore
import Vapor

/// The two catalogue writes discovery makes, shared by `POST /v1/brands/discover` and by
/// checks, so the rules below cannot hold on one path and not the other.
enum BrandCatalog {
    /// The catalogue's brand for a site, if it already has one.
    ///
    /// **Matched on the registrable domain, not the exact host.** The slug is the hostname,
    /// and a brand is not one hostname — the rule the client already learned when saves from
    /// `usa.palaceskateboards.com` were attributed to nobody. Here the same fact makes
    /// *duplicate brands*: `stussy.com` and `www.stussy.com` are two slugs, so the catalogue
    /// ended up holding Stüssy twice, Palace twice (once as a sitemap and once as a Shopify
    /// catalog), Corteiz twice and Supreme twice. Both rows poll, both fill with products,
    /// and the person adding one has no way to tell which is the real one — they follow a
    /// brand and get half its drops.
    ///
    /// The catalogue is global, so this is the one place that can prevent it. Checked over
    /// loaded rows rather than in SQL because the comparison is
    /// `BrandDiscovery.registrableDomain`, which is Swift and shared with the client so the
    /// two cannot disagree about what counts as the same brand.
    static func existing(domain: String, on db: any Database) async throws -> BrandModel? {
        let candidates = try await BrandModel.query(on: db).with(\.$sources).all()
        return candidates.first { brand in
            guard let host = brand.website.flatMap({ URL(string: $0)?.host() }) ?? Optional(brand.slug)
            else { return false }
            return BrandDiscovery.registrableDomain(of: host) == domain
        }
    }

    /// Creates the shared brand and its automatic sources.
    ///
    /// **The caller does not get to name the brand.** The catalogue is *global*, so whatever
    /// the first person to add a shop typed becomes its name for everybody who ever follows
    /// it. A typo is permanent, and anything worse is a vandalism vector that costs one HTTP
    /// request — there is no second person to correct it and no review step between.
    ///
    /// The site's own account of itself is both more trustworthy and freely available:
    /// `/meta.json` is the merchant's own setting, `og:site_name` is what they publish to
    /// link previews, and the `<title>` is the same claim with marketing attached. See
    /// `BrandNaming.pick`. Where all three are silent the host is used, which is ugly and
    /// honest — and `usesGeneratedName` stays true so the first poll can still improve it
    /// from the storefront. An operator can override a bad one through
    /// `POST /admin/brands/:id/name`, which is behind the admin key.
    static func create(
        base: URL,
        suggestedName: String?,
        logoURL: String?,
        instagram: String?,
        sources: [(kind: BrandSource.Kind, url: String)],
        on db: any Database
    ) async throws -> (brand: BrandModel, sources: [SourceModel]) {
        let slug = base.host() ?? base.absoluteString
        let brand = BrandModel(
            name: suggestedName ?? slug,
            slug: slug,
            website: base.absoluteString,
            instagramHandle: BrandDiscovery.normalizedHandle(instagram),
            usesGeneratedName: true
        )
        brand.logoURL = logoURL
        try await brand.save(on: db)

        let brandID = try brand.requireID()
        // Collected as they are written rather than re-queried: these are the rows this
        // call just created, and the caller is about to name them.
        var created: [SourceModel] = []
        for source in sources where source.kind.isAutomatic {
            let model = SourceModel(brandID: brandID, kind: source.kind, url: source.url)
            try await model.save(on: db)
            created.append(model)
        }
        return (brand, created)
    }
}

actor BrandChecks {
    private let app: Application

    /// How long a `checking` row nobody here is running may go on claiming to be checked.
    ///
    /// **Not a limit on how long a check may take.** That was the first version — five
    /// minutes, "longer than any real check" — and it was wrong the first time a storefront
    /// slowed down: every request is allowed two minutes (`Net.live`), a site that tarpits a
    /// caller makes each one use all of it, and Hollister measured twenty-four minutes in one
    /// run, read as interrupted for nineteen of them while it was still working. A check this
    /// process is running is `checking` for as long as it runs (`running`); this grace only
    /// decides when a row *without* a runner — left by a restart, or started by the other
    /// instance during a rolling deploy — stops pretending.
    static let orphanAfter: TimeInterval = 2 * 60

    /// How long a finished check answers for its shop. Long enough to cover the preview,
    /// reading it, and tapping START WATCHING; short enough that a site which has just
    /// switched its catalogue on is not refused on the strength of an old look.
    static let reuseFor: TimeInterval = 10 * 60

    /// The settle in flight for each check, so the next one waits its turn.
    ///
    /// An actor alone does not serialise them: it is re-entrant at every `await`, so two
    /// settles of one check — the check finishing while somebody taps START WATCHING — could
    /// both see no brand and create two, the duplicate-brand bug `BrandCatalog.existing`
    /// exists to prevent, or both write the same follow and fail on its unique key.
    private var settling: [UUID: Task<Void, any Error>] = [:]

    /// The checks this process is running right now. In memory on purpose: it is a fact about
    /// this process, which a restart makes false, and that is exactly the question it answers.
    private var running: Set<UUID> = []

    /// Country shops being looked for, per brand a check made (`discovered`).
    private var countryShops: [UUID: Task<Void, Never>] = [:]

    init(app: Application) {
        self.app = app
    }

    /// Starts a check of `raw`, or joins the one already running or just finished for the
    /// same shop.
    ///
    /// - Parameter catalogueOnly: somebody saved from this shop and the catalogue did not have
    ///   it. The shop is added to the catalogue if the check finds a real one
    ///   (`addsToCatalogue`), so search can recommend from it, and nobody follows it. Nothing
    ///   about the caller is kept: the flag is the whole record.
    func start(url raw: String, catalogueOnly: Bool = false) async throws -> BrandCheckModel {
        guard let base = BrandDiscovery.normalizedURL(raw) else {
            throw Abort(.badRequest, reason: "Not a usable URL")
        }
        let domain = BrandDiscovery.registrableDomain(of: base.host() ?? raw)
        let db = app.db

        let recent = try await BrandCheckModel.query(on: db)
            .filter(\.$domain == domain)
            .filter(\.$createdAt > Date().addingTimeInterval(-86_400))
            .sort(\.$createdAt, .descending)
            .first()
        if let recent, isReusable(recent) {
            if catalogueOnly, recent.catalogueOnly != true {
                recent.catalogueOnly = true
                try await recent.save(on: db)
                // A look that has already finished is settled now; one still running is
                // settled by `run` when it does.
                if status(of: recent) != .checking, let id = recent.id {
                    try await addToCatalogueIfReal(id)
                }
            }
            return recent
        }

        // A shop somebody already added needs no fetching at all — and, catalogue-only, adds
        // nothing: it is already there.
        if let brand = try await BrandCatalog.existing(domain: domain, on: db) {
            let check = BrandCheckModel(domain: domain, url: base.absoluteString, status: .ready)
            check.$brand.id = try brand.requireID()
            check.probe = try Self.encode(Self.probe(for: brand))
            check.logoURL = brand.logoURL
            check.finishedAt = Date()
            try await check.save(on: db)
            return check
        }

        // A brand whose site sells no clothes is refused before anything is fetched: no
        // request could change the answer (`ShopRefusal.sellsNoClothes`).
        if ShopRefusal.sellsNoClothes(host: base.host() ?? domain) {
            let check = BrandCheckModel(domain: domain, url: base.absoluteString, status: .refused)
            check.refusal = BrandCheck.Refusal.sellsNoClothes.rawValue
            check.probe = try Self.encode(BrandProbe(suggestedName: nil, sources: []))
            check.finishedAt = Date()
            try await check.save(on: db)
            return check
        }

        let check = BrandCheckModel(domain: domain, url: base.absoluteString, status: .checking)
        if catalogueOnly { check.catalogueOnly = true }
        try await check.save(on: db)
        let id = try check.requireID()
        launch(checkID: id, base: base)
        return check
    }

    /// Asks to watch a check's shop, now or as soon as the check can say it is watchable.
    func watch(checkID: UUID, userID: UUID, instagram: String?) async throws -> BrandCheckModel {
        guard let check = try await BrandCheckModel.find(checkID, on: app.db) else {
            throw Abort(.notFound, reason: "No check with that id.")
        }
        let handle = instagram?.trimmingCharacters(in: .whitespaces)
        let existing = try await BrandCheckWatcherModel.query(on: app.db)
            .filter(\.$check.$id == checkID)
            .filter(\.$user.$id == userID)
            .first()
        if existing == nil {
            try await BrandCheckWatcherModel(
                checkID: checkID,
                userID: userID,
                instagram: handle?.isEmpty == false ? handle : nil
            ).save(on: app.db)
        }

        // Settled here as well as when the check finishes, and the order is what closes the
        // gap between them: a check that finished between the find above and the insert has
        // already settled the watchers it could see, which did not include this one.
        // Re-reading after the insert means one of the two paths always gets it.
        // On screen, so the answer is the response itself — no push.
        try await settle(checkID, announce: false)
        return try await BrandCheckModel.find(checkID, on: app.db) ?? check
    }

    /// The wire shape, from the point of view of one caller.
    func response(for check: BrandCheckModel, userID: UUID) async throws -> BrandCheck {
        let id = try check.requireID()
        var brand: BrandDTO?
        if let brandID = check.$brand.id,
           let model = try await BrandModel.query(on: app.db)
               .filter(\.$id == brandID)
               .with(\.$sources)
               .first() {
            brand = BrandDTO(model, sources: model.sources)
        }
        let isWatching = try await BrandCheckWatcherModel.query(on: app.db)
            .filter(\.$check.$id == id)
            .filter(\.$user.$id == userID)
            .count() > 0
        let status = status(of: check)
        return BrandCheck(
            id: id,
            status: status,
            probe: check.probe.flatMap(Self.decode),
            brand: brand,
            isWatching: isWatching,
            refusal: status == .refused ? Self.refusal(of: check) : nil
        )
    }

    /// A refused check's reason; one refused before reasons were recorded reads as the generic.
    static func refusal(of check: BrandCheckModel) -> BrandCheck.Refusal {
        check.refusal.flatMap(BrandCheck.Refusal.init(rawValue:)) ?? .nothingAnswered
    }

    private func status(of check: BrandCheckModel) -> BrandCheck.Status {
        Self.status(of: check, isRunning: check.id.map(running.contains) ?? false)
    }

    /// `checking` for as long as something is running it, and for `orphanAfter` past that.
    static func status(
        of check: BrandCheckModel,
        isRunning: Bool,
        now: Date = Date()
    ) -> BrandCheck.Status {
        let status = BrandCheck.Status(rawValue: check.status) ?? .interrupted
        guard status == .checking, !isRunning else { return status }
        if let createdAt = check.createdAt, now.timeIntervalSince(createdAt) > orphanAfter {
            return .interrupted
        }
        return status
    }

    // MARK: Running

    /// Runs again the checks a restart left unfinished, where somebody is still waiting.
    ///
    /// This is what the row buys over memory. A deploy mid-check would otherwise leave the
    /// person who tapped START WATCHING and walked away waiting for a push that never comes.
    /// A check nobody is watching is only a preview, and the phone that asked for it sees
    /// interrupted and can start another.
    func resumeOrphans() async {
        do {
            let orphans = try await BrandCheckModel.query(on: app.db)
                .filter(\.$status == BrandCheck.Status.checking.rawValue)
                .filter(\.$createdAt > Date().addingTimeInterval(-86_400))
                .with(\.$watchers)
                .all()
            for check in orphans where check.watchers.contains(where: { $0.settledAt == nil }) {
                guard let id = check.id, let base = URL(string: check.url) else { continue }
                launch(checkID: id, base: base)
            }
        } catch {
            app.logger.error("checks: could not resume unfinished checks: \(error)")
        }
    }

    private func isReusable(_ check: BrandCheckModel) -> Bool {
        switch status(of: check) {
        case .checking:
            return true
        case .ready, .refused:
            guard let finishedAt = check.finishedAt else { return false }
            return Date().timeIntervalSince(finishedAt) < Self.reuseFor
        case .interrupted:
            return false
        }
    }

    /// Marked running before the task starts, with no `await` between, so there is no
    /// moment at which a fresh check could read as orphaned.
    private func launch(checkID: UUID, base: URL) {
        running.insert(checkID)
        Task { await self.run(checkID: checkID, base: base) }
    }

    private func run(checkID: UUID, base: URL) async {
        defer { running.remove(checkID) }
        // Through the shared fetcher, so a check obeys robots.txt and queues behind the
        // poller like everything else. Read here rather than captured at init, so a test
        // can stub it after `configure`.
        //
        // Watched by a `ProbeLog`, which changes nothing about the requests and remembers what
        // each came back with — the only evidence of *why* a site could not be read. A shop
        // that refuses machines is said to, and never retried another way (`ShopRefusal`).
        let log = ProbeLog(wrapping: app.fetcher)
        let found = await BrandDiscovery.discover(
            website: base.absoluteString, instagramHandle: nil, http: log
        )
        do {
            guard let check = try await BrandCheckModel.find(checkID, on: app.db) else { return }
            check.status = (found.canMonitor ? BrandCheck.Status.ready : .refused).rawValue
            check.refusal = found.canMonitor ? nil : ShopRefusal.classify(log.outcomes).rawValue
            check.probe = try Self.encode(BrandProbe(
                suggestedName: found.suggestedName,
                sources: found.sources.map {
                    BrandProbe.Source(
                        kind: $0.kind.rawValue,
                        url: $0.url.absoluteString,
                        isAutomatic: $0.kind.isAutomatic
                    )
                }
            ))
            check.logoURL = found.logoURL?.absoluteString
            // Kept for the brand this check makes, whose country shops are found from them
            // (`CountryShops`) — the homepage is not fetched a second time to read them again.
            if !found.alternates.isEmpty {
                check.alternates = String(decoding: try JSONEncoder().encode(found.alternates), as: UTF8.self)
            }
            check.finishedAt = Date()
            try await check.save(on: app.db)
            if check.catalogueOnly == true { try await addToCatalogueIfReal(checkID) }
            try await settle(checkID, announce: true)
        } catch {
            // Left `checking`, which `orphanAfter` turns into interrupted: the phone offers a
            // retry rather than a verdict about the site that nobody reached.
            app.logger.error("checks: \(base.host() ?? "?") could not be recorded: \(error)")
        }
    }

    /// Turns everybody waiting on a check into a follow — or, for a site nothing could
    /// read, tells them so. Runs after whichever settle of the same check is in flight.
    private func settle(_ checkID: UUID, announce: Bool) async throws {
        let previous = settling[checkID]
        let task = Task {
            _ = await previous?.result
            try await self.settlePass(checkID, announce: announce)
        }
        settling[checkID] = task
        defer { if settling[checkID] == task { settling[checkID] = nil } }
        try await task.value
    }

    /// **A site nothing could read is not added**, the same rule `POST /v1/brands/discover`
    /// holds: a brand row that reports no error and delivers nothing forever, in a catalogue
    /// everybody shares, is worse than a refusal. So a refused check only announces.
    private func settlePass(_ checkID: UUID, announce: Bool) async throws {
        // Read fresh rather than passed in: the pass before this one may have created the
        // brand, and a stale copy would create it again.
        guard let check = try await BrandCheckModel.find(checkID, on: app.db),
              status(of: check) != .checking
        else { return }
        let waiting = try await BrandCheckWatcherModel.query(on: app.db)
            .filter(\.$check.$id == checkID)
            .filter(\.$settledAt == nil)
            .all()
        guard !waiting.isEmpty else { return }
        let host = URL(string: check.url)?.host() ?? check.domain

        // Interrupted is not a verdict about the site, so nobody is told it was refused.
        // They stay waiting, and `resumeOrphans` runs the check again on the next boot.
        if status(of: check) == .interrupted { return }

        guard status(of: check) == .ready else {
            let body = switch Self.refusal(of: check) {
            case .blocksReaders: "It blocks automated readers. Saving from Safari still works."
            case .sellsNoClothes: "It doesn't sell clothes online."
            case .nothingAnswered: "It publishes nothing Dropwall can read — no catalogue, feed, sitemap or page."
            }
            for watcher in waiting {
                watcher.settledAt = Date()
                try await watcher.save(on: app.db)
                if announce {
                    await app.notifier?.tell(
                        userID: watcher.$user.id,
                        title: "Couldn't watch \(host)",
                        body: body,
                        brandID: nil,
                        collapseID: "check-\(checkID)"
                    )
                }
            }
            return
        }

        let brand = try await materialize(check, instagram: waiting.compactMap(\.instagram).first)
        let brandID = try brand.requireID()
        for watcher in waiting {
            let userID = watcher.$user.id
            let following = try await FollowModel.query(on: app.db)
                .filter(\.$user.$id == userID)
                .filter(\.$brand.$id == brandID)
                .count() > 0
            if !following {
                try await FollowModel(userID: userID, brandID: brandID).save(on: app.db)
            }
            watcher.settledAt = Date()
            try await watcher.save(on: app.db)
            if announce {
                await app.notifier?.tell(
                    userID: userID,
                    title: "Now watching \(brand.name)",
                    body: "Its drops, restocks and markdowns will show up in your feed.",
                    brandID: brandID,
                    collapseID: "check-\(checkID)"
                )
            }
        }
    }

    // MARK: Catalogue-only

    /// Whether a finished check found a shop worth adding to the catalogue with nobody
    /// following it: ready, and readable for its *products* — a Shopify catalogue, a sitemap,
    /// UCP or a feed of new products (`BrandDiscovery.readsProducts`). A page watch counts for a follow, where "something changed" is worth a push (see
    /// CLAUDE.md, *Who may call what*), and is refused here: search recommends products, and a
    /// page watch has none to give. A refused check — readers blocked, no clothes sold, nothing
    /// answered (`ShopRefusal`) — adds nothing.
    static func addsToCatalogue(_ check: BrandCheckModel, isRunning: Bool = false) -> Bool {
        guard status(of: check, isRunning: isRunning) == .ready,
              let probe = check.probe.flatMap(decode)
        else { return false }
        return probe.sources.contains { source in
            guard source.isAutomatic, let kind = BrandSource.Kind(rawValue: source.kind),
                  let url = URL(string: source.url)
            else { return false }
            return BrandDiscovery.readsProducts(kind: kind, url: url)
        }
    }

    /// Adds a catalogue-only check's shop to the catalogue, once, and follows nobody. Through
    /// the same `materialize` a follow uses, inside the same per-check serialisation, so a
    /// catalogue-only request and somebody's follow of the same shop make one brand. The
    /// brand is then an unfollowed catalogue brand like any other, which the poller reads.
    private func addToCatalogueIfReal(_ checkID: UUID) async throws {
        let previous = settling[checkID]
        let task = Task {
            _ = await previous?.result
            guard let check = try await BrandCheckModel.find(checkID, on: self.app.db),
                  check.$brand.id == nil,
                  Self.addsToCatalogue(check)
            else { return }
            let brand = try await self.materialize(check, instagram: nil)
            self.app.logger.info("checks: added \(brand.slug) to the catalogue from a save")
        }
        settling[checkID] = task
        defer { if settling[checkID] == task { settling[checkID] = nil } }
        try await task.value
    }

    /// The catalogue brand for a ready check, created if nobody has added the shop yet.
    private func materialize(_ check: BrandCheckModel, instagram: String?) async throws -> BrandModel {
        let db = app.db
        if let brandID = check.$brand.id, let brand = try await BrandModel.find(brandID, on: db) {
            return brand
        }
        // Somebody may have added the shop another way since this check started.
        let brand: BrandModel
        if let existing = try await BrandCatalog.existing(domain: check.domain, on: db) {
            brand = existing
        } else {
            guard let base = URL(string: check.url) else { throw Abort(.internalServerError) }
            let probe = check.probe.flatMap(Self.decode)
            brand = try await BrandCatalog.create(
                base: base,
                suggestedName: probe?.suggestedName,
                logoURL: check.logoURL,
                instagram: instagram,
                sources: (probe?.sources ?? []).compactMap { source in
                    BrandSource.Kind(rawValue: source.kind).map { ($0, source.url) }
                },
                on: db
            ).brand
            try await discovered(brand, alternates: check.alternates)
        }
        check.$brand.id = try brand.requireID()
        try await check.save(on: db)
        return brand
    }

    /// A brand this check has just made: discovered under the current rules, so the
    /// rediscovery pass leaves it be — and its country shops, from the `hreflang` the check
    /// read, are looked for in the background. Through the shared fetcher, after the settle,
    /// because verifying a shop is a discovery of its own and nobody should wait on it.
    private func discovered(_ brand: BrandModel, alternates raw: String?) async throws {
        let brandID = try brand.requireID()
        let line = "\(brand.slug): added by a check"
        let enabled = app.storefrontCountries
        try await Rediscovery.record(brandID: brandID, line: line, countries: enabled, on: app.db)

        guard !enabled.isEmpty,
              let raw,
              let alternates = try? JSONDecoder().decode([LanguageAlternate].self, from: Data(raw.utf8)),
              !alternates.isEmpty
        else { return }
        let app = self.app
        countryShops[brandID] = Task {
            do {
                let results = try await CountryShops.attach(
                    brandID: brandID, alternates: alternates, enabled: enabled, http: app.fetcher, on: app.db
                )
                guard !results.isEmpty else { return }
                let said = ([line] + results.map(\.line)).joined(separator: ", ")
                try await Rediscovery.record(brandID: brandID, line: said, countries: enabled, on: app.db)
                if let row = try await Rediscovery.row(brandID: brandID, countries: enabled, on: app.db) {
                    row.storefronts = results.filter(\.isAttached).count
                    try await row.save(on: app.db)
                }
                app.logger.notice("checks: \(said)")
            } catch {
                app.logger.error("checks: country shops for \(brand.slug) failed: \(error)")
            }
        }
    }

    /// Waits for the country-shop looks this process has started. For tests.
    func countryShopsSettled() async {
        for task in countryShops.values { await task.value }
    }

    // MARK: Encoding

    /// What an existing brand's check shows: the sources it is already watched through.
    private static func probe(for brand: BrandModel) -> BrandProbe {
        BrandProbe(
            suggestedName: brand.name,
            sources: brand.sources.map { source in
                BrandProbe.Source(
                    kind: source.kind,
                    url: source.url,
                    isAutomatic: BrandSource.Kind(rawValue: source.kind)?.isAutomatic ?? false
                )
            }
        )
    }

    private static func encode(_ probe: BrandProbe) throws -> String {
        String(decoding: try JSONEncoder().encode(probe), as: UTF8.self)
    }

    private static func decode(_ text: String) -> BrandProbe? {
        try? JSONDecoder().decode(BrandProbe.self, from: Data(text.utf8))
    }
}

struct BrandChecksKey: StorageKey {
    typealias Value = BrandChecks
}

extension Application {
    var brandChecks: BrandChecks? { storage[BrandChecksKey.self] }
}

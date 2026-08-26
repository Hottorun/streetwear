// Poller.swift
// Walks the due-source queue and folds results into the store.
//
// The diff logic mirrors the app's SyncEngine, but the *baseline* rule differs in an
// important way: here a brand's first poll is shared by everyone, so it is a baseline
// once globally rather than once per user.

import Fluent
import Foundation
import SQLKit
import StreetwCore
import Vapor

actor Poller {
    private let app: Application
    private let http: any HTTPFetching
    private var isRunning = false

    init(app: Application, http: any HTTPFetching = Net.live) {
        self.app = app
        self.http = http
    }

    /// How long until a source should be looked at again. Uniform polling is how you
    /// get blocked; this spends requests where something is actually happening.
    enum Cadence {
        /// - Parameter inDropWindow: whether now is inside the brand's own usual release
        ///   window, read from its publication history — see `DropCadence.isWithinWindow`.
        ///
        ///   **This is the fix for "the drop happened and streetw told me hours later".**
        ///   The quiet cadence is two hours, and a brand that drops once a week is quiet
        ///   right up until the moment it isn't: nothing had happened for six days, so the
        ///   source was on the slowest schedule at exactly the minute it mattered. A
        ///   Thursday 11am release could be found at 12:50 and pushed then, which in
        ///   streetwear is not a late notification but a useless one. `quietForAWeek` was
        ///   measuring the wrong thing — a weekly brand is not a dormant brand, it is a
        ///   *punctual* one.
        ///
        ///   The window is what pays for itself: outside it the source stays lazy, so this
        ///   spends the same request budget in a far better place rather than polling
        ///   everything harder. It ranks above `hadRecentEvent` because a drop in progress
        ///   is worth a minute, not five.
        /// - Parameter hinted: whether somebody has written down a release time for this
        ///   brand and it is happening around now — see `PollHintPolicy`.
        ///
        ///   The same minute as a lock and a historical window, and deliberately not less:
        ///   a hint is only reached by brands with *no* readable rhythm, since a brand with
        ///   one is already at 60 seconds inside its own window. So this is not a new
        ///   capability, it is the existing one extended to the case the estimator cannot
        ///   see — a brand that never locks and never publishes a date until the products
        ///   are already up.
        ///
        ///   Ranked below `locked`, which is an *observation*, and above everything else
        ///   for the reason `inDropWindow` is: a drop that is actually in progress is worth
        ///   a minute rather than five. It cannot escape the failure backoff above it —
        ///   somebody's date must never turn a site that is refusing us into a retry every
        ///   sixty seconds.
        static func next(
            locked: Bool,
            hadRecentEvent: Bool,
            quietForAWeek: Bool,
            failures: Int,
            inDropWindow: Bool = false,
            hinted: Bool = false
        ) -> TimeInterval {
            if failures > 0 {
                return min(pow(2.0, Double(failures)) * 60, 6 * 3600)
            }
            if locked { return 60 }               // a drop is imminent
            if inDropWindow { return 60 }         // ...and so, historically, is this
            if hinted { return 60 }               // ...and somebody says so about this one
            if hadRecentEvent { return 5 * 60 }
            if quietForAWeek { return 2 * 3600 }
            return 20 * 60
        }
    }

    /// How many hinted sources may be claimed per tick, over and above the ordinary queue.
    ///
    /// **This is the number that makes poll hints safe, and it is a constant on purpose.**
    /// Everything else about a hint — following the brand, one per brand, a fixed window, a
    /// cap per person — bounds what one account can *ask for*. This bounds what all of them
    /// together can *get*: five sources per tick, whether one person hinted one brand or a
    /// thousand people hinted a thousand. Hinting more does not buy more requests, it
    /// divides the same ones. `PoliteFetcher` then spaces those five per host on top.
    ///
    /// Separate from `tick`'s own `limit` rather than carved out of it, so the answer to
    /// "can hints starve the ordinary queue" is no by construction rather than by tuning:
    /// the normal claim explicitly excludes hinted brands, and its budget is untouched.
    static let hintBudget = 5

    /// And how many hint rows are read to decide which brands those are.
    ///
    /// Ordered by `release_at`, so under a cap the soonest drops win — which is the right
    /// tie-break, and means a flood of far-off hints cannot displace the one happening in
    /// four minutes.
    static let maxActiveHints = 200

    /// One pass over everything currently due.
    ///
    /// Two claims, against two budgets. The ordinary queue takes `limit` sources and
    /// **excludes** any brand somebody has hinted at; hinted brands then take up to
    /// `hintBudget` of their own. Written this way round so a brand in a hint window cannot
    /// fill the general claim — a hint moves a source's `next_check_at` to sixty seconds,
    /// which without the exclusion would make it due on nearly every tick and let a handful
    /// of hinted brands own the whole pass. Whether that would actually happen depends on
    /// how many hints exist, which is exactly the thing a stranger controls.
    @discardableResult
    func tick(limit: Int = 20) async -> Int {
        guard !isRunning else { return 0 }
        isRunning = true
        defer { isRunning = false }

        // Once per tick, not once per source: the answer is the same for every source in
        // the pass, and it decides both claims as well as each source's next cadence.
        let hinted = await activeHintedBrandIDs()

        let due: [SourceModel]
        do {
            due = try await claimDue(limit: limit, excluding: hinted)
        } catch {
            app.logger.error("poller: queue query failed: \(error)")
            return 0
        }

        var hintedDue: [SourceModel] = []
        if !hinted.isEmpty {
            do {
                hintedDue = try await claimHinted(limit: Self.hintBudget, brandIDs: hinted)
            } catch {
                // Non-fatal by design. A hint is an optimisation on top of a queue that
                // already works, so a failure here must cost latency on a few brands rather
                // than the whole pass.
                app.logger.error("poller: hinted queue query failed: \(error)")
            }
        }

        var polled = 0
        for source in due + hintedDue {
            // One domain at a time — see the politeness budget in BACKEND.md.
            do {
                try await poll(source, isHinted: hinted.contains(source.$brand.id))
                polled += 1
            } catch {
                app.logger.error("poller: \(source.url) failed: \(error)")
                // Critical: if `poll` threw before it could persist the source, the row
                // still says "due", so the next tick re-fetches the entire catalog —
                // a hot loop against the brand. Always push the schedule forward, even
                // when we could not record anything else.
                await quarantine(source, reason: error)
            }
        }
        return polled
    }

    /// How long a claimed source stays off the queue before another instance may retry
    /// it. Long enough for the slowest first sweep (Kith's ten pages take ~11s), short
    /// enough that a process killed mid-poll doesn't strand a brand for an hour.
    private static let leaseDuration: TimeInterval = 5 * 60

    /// Takes the next batch of due sources *and claims them in the same statement*, so
    /// two instances polling the same database cannot both fetch the same storefront —
    /// which would double the request rate against a brand and put the politeness budget
    /// out by a factor of the instance count.
    ///
    /// The claim is a lease: `next_check_at` is pushed forward before any network call,
    /// and `poll` overwrites it with the real cadence when it finishes. A crash in
    /// between costs one lease period rather than losing the source.
    ///
    /// SQLite has no `SKIP LOCKED` and no second instance to protect against, so it
    /// keeps the plain query.
    /// The ordinary queue, minus anything a hint is currently covering.
    private func claimDue(limit: Int, excluding hinted: Set<UUID>) async throws -> [SourceModel] {
        try await claim(limit: limit, brandIDs: hinted, matching: false)
    }

    /// And the hinted brands, against their own budget. Never called with an empty set —
    /// `matching: true` with nothing to match would claim the entire queue.
    private func claimHinted(limit: Int, brandIDs: Set<UUID>) async throws -> [SourceModel] {
        try await claim(limit: limit, brandIDs: brandIDs, matching: true)
    }

    /// - Parameters:
    ///   - brandIDs: brands the claim is restricted to, or excluded from.
    ///   - matching: `true` claims only those brands' sources, `false` claims everything
    ///     except them. An empty set with `matching: false` is the original unfiltered
    ///     query, which is the common case and stays byte-identical.
    private func claim(limit: Int, brandIDs: Set<UUID>, matching: Bool) async throws -> [SourceModel] {
        let db = app.db
        guard let sql = db as? any SQLDatabase, sql.dialect.name == "postgresql" else {
            return try await dueWithoutClaim(limit: limit, brandIDs: brandIDs, matching: matching)
        }

        let now = Date()
        let lease = now.addingTimeInterval(Self.leaseDuration)
        let ids: [UUID]
        do {
            // Three literal statements rather than one composed from fragments. The
            // composed version is shorter and this one is the only piece of the poller no
            // local test can reach — SQLite has neither `SKIP LOCKED` nor `= ANY`, so this
            // is exercised only against the deployed database, and "read it and be sure" is
            // worth more here than "write it once".
            //
            // `= ANY(array)` rather than a generated `IN (…)` list for the same reason:
            // one bound parameter whatever the length, so there is no string building
            // anywhere near a query that takes locks.
            let query: SQLQueryString
            let brands = Array(brandIDs)
            if brands.isEmpty {
                query = """
                    UPDATE sources SET next_check_at = \(bind: lease) \
                    WHERE id IN ( \
                        SELECT id FROM sources \
                        WHERE enabled = true AND next_check_at <= \(bind: now) \
                        ORDER BY next_check_at LIMIT \(bind: limit) \
                        FOR UPDATE SKIP LOCKED \
                    ) RETURNING id
                    """
            } else if matching {
                query = """
                    UPDATE sources SET next_check_at = \(bind: lease) \
                    WHERE id IN ( \
                        SELECT id FROM sources \
                        WHERE enabled = true AND next_check_at <= \(bind: now) \
                        AND brand_id = ANY(\(bind: brands)) \
                        ORDER BY next_check_at LIMIT \(bind: limit) \
                        FOR UPDATE SKIP LOCKED \
                    ) RETURNING id
                    """
            } else {
                query = """
                    UPDATE sources SET next_check_at = \(bind: lease) \
                    WHERE id IN ( \
                        SELECT id FROM sources \
                        WHERE enabled = true AND next_check_at <= \(bind: now) \
                        AND brand_id <> ALL(\(bind: brands)) \
                        ORDER BY next_check_at LIMIT \(bind: limit) \
                        FOR UPDATE SKIP LOCKED \
                    ) RETURNING id
                    """
            }
            ids = try await sql.raw(query).all(decodingColumn: "id", as: UUID.self)
        } catch {
            // Degrading to the unclaimed query keeps polling alive if the statement above
            // turns out to be wrong on the deployment; a single instance behaves exactly as
            // it did before claiming existed.
            app.logger.error("poller: claim failed, falling back to plain queue: \(error)")
            return try await dueWithoutClaim(limit: limit, brandIDs: brandIDs, matching: matching)
        }

        guard !ids.isEmpty else { return [] }
        return try await SourceModel.query(on: db)
            .filter(\.$id ~~ ids)
            .with(\.$brand)
            .all()
    }

    private func dueWithoutClaim(
        limit: Int,
        brandIDs: Set<UUID> = [],
        matching: Bool = false
    ) async throws -> [SourceModel] {
        var builder = SourceModel.query(on: app.db)
            .filter(\.$enabled == true)
            .filter(\.$nextCheckAt <= Date())
        if !brandIDs.isEmpty {
            let brands = Array(brandIDs)
            builder = matching
                ? builder.filter(\.$brand.$id ~~ brands)
                : builder.filter(\.$brand.$id !~ brands)
        }
        return try await builder
            .sort(\.$nextCheckAt)
            .limit(limit)
            .with(\.$brand)
            .all()
    }

    /// Which brands are inside somebody's stated release window right now.
    ///
    /// One bounded query per tick. Ordered by `release_at` under `maxActiveHints` so the
    /// soonest drops survive the cap — a flood of far-off hints cannot displace the one
    /// happening in four minutes. Failure is silent and empty: a hint is an optimisation,
    /// and a poll queue that stops when this table is unreadable would be a worse trade
    /// than a few brands being found late.
    private func activeHintedBrandIDs() async -> Set<UUID> {
        let range = PollHintPolicy.activeRange()
        do {
            let rows = try await PollHintModel.query(on: app.db)
                .filter(\.$releaseAt >= range.lowerBound)
                .filter(\.$releaseAt <= range.upperBound)
                .sort(\.$releaseAt)
                .limit(Self.maxActiveHints)
                .all()
            return Set(rows.map { $0.$brand.id })
        } catch {
            app.logger.error("poller: could not read poll hints: \(error)")
            return []
        }
    }

    /// Best-effort schedule bump for a source we failed to update normally.
    private func quarantine(_ source: SourceModel, reason: any Error) async {
        source.failureCount += 1
        source.lastError = String(describing: reason)
        source.lastCheckedAt = Date()
        source.nextCheckAt = Date().addingTimeInterval(
            Cadence.next(locked: false, hadRecentEvent: false, quietForAWeek: false, failures: source.failureCount)
        )
        do {
            try await source.save(on: app.db)
        } catch {
            app.logger.critical("poller: could not quarantine \(source.url): \(error)")
        }
    }

    /// - Parameter isHinted: whether this brand is inside somebody's stated release window.
    ///   Passed in rather than looked up, because `tick` has already asked once for the
    ///   whole pass and asking again per source would put a query on the hot path for an
    ///   answer that cannot have changed.
    private func poll(_ source: SourceModel, isHinted: Bool = false) async throws {
        let db = app.db
        let brand = source.brand
        guard let brandID = brand.id, let sourceID = source.id else { return }

        let kind = BrandSource.Kind(rawValue: source.kind) ?? .page
        guard kind.isAutomatic, let adapter = SourceAdapters.adapter(for: kind, http: http) else { return }

        // A source that has never *stored* anything has no baseline yet. Deliberately
        // not `lastCheckedAt == nil`: that is stamped below before the fetch and survives
        // a failure, so a source that errored once would count its first real batch as
        // news and announce a whole back catalogue.
        let isFirstPoll = source.baselinedAt == nil
        let since = source.lastCheckedAt

        var hadEvent = false
        source.lastCheckedAt = Date()

        do {
            let result = try await adapter.fetch(source.asBrandSource, since: since)

            source.lastError = nil
            source.failureCount = 0
            if let etag = result.etag { source.etag = etag }
            if let fingerprint = result.fingerprint { source.fingerprint = fingerprint }

            source.lockedAt = result.isLocked ? (source.lockedAt ?? Date()) : nil
            if let currency = result.shopCurrency, brand.currency != currency {
                brand.currency = currency
                try await brand.save(on: db)
            }
            if let name = result.shopName, brand.usesGeneratedName {
                brand.name = name
                brand.usesGeneratedName = false
                try await brand.save(on: db)
            }

            if !result.notModified {
                hadEvent = try await merge(
                    result.items,
                    brandID: brandID,
                    sourceID: sourceID,
                    isBaseline: isFirstPoll
                )
            }

            // Only now, once a fetch has completed and its batch is stored, is the
            // baseline genuinely spent. A source that emits nothing on a first sight —
            // a page watch storing its opening fingerprint — counts too: it has seen
            // the "before", which is exactly what a baseline is.
            if source.baselinedAt == nil { source.baselinedAt = Date() }
        } catch {
            source.failureCount += 1
            source.lastError = String(describing: error)
            // A source we can't reach is not a source that is locked. Leaving the lock
            // standing is how a brand behind a bot wall stayed "drop imminent" forever —
            // and, because the locked cadence is 60 seconds, kept being retried a minute
            // at a time against a site that was already refusing us.
            source.lockedAt = nil
        }

        let quiet = try await EventModel.query(on: db)
            .filter(\.$brand.$id == brandID)
            .filter(\.$createdAt >= Date().addingTimeInterval(-7 * 86_400))
            .count() == 0

        source.nextCheckAt = Date().addingTimeInterval(
            Cadence.next(
                locked: source.lockedAt != nil,
                hadRecentEvent: hadEvent,
                quietForAWeek: quiet,
                failures: source.failureCount,
                // Only asked when a hint hasn't already answered it: both produce sixty
                // seconds, and the rhythm read costs an indexed query over 400 rows.
                inDropWindow: isHinted ? false : try await isInDropWindow(brandID: brandID),
                hinted: isHinted
            )
        )
        try await source.save(on: db)

        try await reconcileLock(brandID: brandID, brand: brand)
    }

    /// Whether this brand is inside the release window its own history describes.
    ///
    /// Read fresh from the catalogue rather than cached on the brand: it costs one indexed
    /// query on `products.brand_id` — which is what `AddProductBrandIndex` exists for — and
    /// a cached rhythm is a rhythm that goes stale the season a brand moves from Saturdays
    /// to Thursdays, which is exactly when being wrong is expensive.
    ///
    /// Bounded to the same 180 days `DropCadenceEstimator` reads, so the query returns what
    /// the estimator would have kept anyway rather than a whole back catalogue.
    private func isInDropWindow(brandID: UUID) async throws -> Bool {
        let since = Date().addingTimeInterval(-180 * 86_400)
        let dates = try await ProductModel.query(on: app.db)
            .filter(\.$brand.$id == brandID)
            .filter(\.$publishedAt >= since)
            .sort(\.$publishedAt, .descending)
            .limit(400)
            .all()
            .map(\.publishedAt)

        guard let cadence = DropCadenceEstimator.estimate(from: dates), cadence.isReliable else {
            return false
        }
        return cadence.isWithinWindow()
    }

    /// The brand is locked when *any* of its sources currently is.
    ///
    /// Derived after the source has been written rather than assigned during the poll,
    /// because a brand has several sources on independent schedules and each one only
    /// knows its own answer. Assigning from inside the poll meant the last source to run
    /// won, so a real lock seen by the catalog was erased minutes later by the collections
    /// endpoint answering normally.
    private func reconcileLock(brandID: UUID, brand: BrandModel) async throws {
        let locked = try await SourceModel.query(on: app.db)
            .filter(\.$brand.$id == brandID)
            .filter(\.$lockedAt != nil)
            .count() > 0

        guard brand.lockedForDrop != locked else { return }
        brand.lockedForDrop = locked
        try await brand.save(on: app.db)
    }

    /// Returns whether anything user-visible happened.
    private func merge(
        _ items: [FetchedItem],
        brandID: UUID,
        sourceID: UUID,
        isBaseline: Bool
    ) async throws -> Bool {
        guard !items.isEmpty else { return false }
        let db = app.db

        let existing = try await ProductModel.query(on: db)
            .filter(\.$source.$id == sourceID)
            .filter(\.$externalID ~~ items.map(\.externalID))
            .with(\.$variants)
            .all()
        let byExternalID = Dictionary(existing.map { ($0.externalID, $0) }, uniquingKeysWith: { a, _ in a })

        var producedEvent = false

        for item in items {
            if let product = byExternalID[item.externalID] {
                if try await refresh(product, with: item, brandID: brandID, isBaseline: isBaseline) {
                    producedEvent = true
                }
            } else {
                let product = ProductModel(brandID: brandID, sourceID: sourceID, item: item)
                try await product.save(on: db)
                if let productID = product.id {
                    try await insertVariants(item.variants, productID: productID)
                    // What this first sighting is worth saying, which is sometimes
                    // *nothing*: a storefront re-publishing year-old sold-out stock has
                    // announced no drop and left nothing to buy. The product row is saved
                    // either way, so a watch can be set on it and a genuine restock later
                    // fires normally — see `Reshelving`.
                    //
                    // The first poll of a brand must not fire 2,500 notifications, which is
                    // the other reason there may be no event here.
                    if !isBaseline, let kind = Reshelving.firstSighting(of: item) {
                        try await EventModel(brandID: brandID, productID: productID, kind: kind)
                            .save(on: db)
                        producedEvent = true
                    }
                }
            }
        }
        return producedEvent
    }

    private func insertVariants(_ variants: [VariantInfo], productID: UUID) async throws {
        for info in variants {
            try await VariantModel(productID: productID, info: info).save(on: app.db)
        }
    }

    /// A product we already have. The one thing worth re-surfacing is a restock, and
    /// only for the variants that actually came back.
    private func refresh(
        _ product: ProductModel,
        with item: FetchedItem,
        brandID: UUID,
        isBaseline: Bool
    ) async throws -> Bool {
        let db = app.db
        guard let productID = product.id else { return false }

        let previous = Dictionary(
            product.variants.map { ($0.externalID, $0) },
            uniquingKeysWith: { a, _ in a }
        )
        var returnedSizes: [String] = []

        for info in item.variants {
            if let existing = previous[info.id] {
                let returned = !existing.available && info.available
                if returned {
                    returnedSizes.append(info.size ?? info.title)
                }
                // **Only written when something actually differs.** See the note on
                // `product.save` below: an unconditional `save` here was the larger half of
                // the same problem, because a product has ten to thirty variants and every
                // one of them was being rewritten on every poll of every brand, forever.
                let changed = returned
                    || existing.available != info.available
                    || existing.price != info.price
                    || existing.size != info.size
                    || existing.color != info.color
                    || existing.imageIndex != info.imageIndex
                if changed {
                    if returned { existing.availableChangedAt = Date() }
                    existing.available = info.available
                    existing.price = info.price
                    existing.size = info.size
                    existing.color = info.color
                    existing.imageIndex = info.imageIndex
                    try await existing.save(on: db)
                }
            } else {
                try await VariantModel(productID: productID, info: info).save(on: db)
            }
        }

        // Products without variant data fall back to whole-product availability.
        let wholeProductReturned = item.variants.isEmpty
            && product.isAvailable == false
            && item.isAvailable == true

        // Checked before the incoming price overwrites the stored one — and kept, because
        // the event needs to say what it dropped *from* and by how much.
        let dropped = PriceChange.isDrop(from: product.priceAmount, to: item.priceAmount)
        let wasText = product.priceText
        let wasAmount = product.priceAmount

        // **A row is only written when something about it changed.**
        //
        // This was an unconditional `save` on every poll of every product, and it is what
        // filled the volume. Postgres does not edit a row in place: every UPDATE writes a
        // new tuple and leaves the old one dead until autovacuum reclaims it — and reclaimed
        // space is returned to the *table* for reuse, not to the filesystem, so the volume's
        // high-water mark only ever goes up. A Shopify source returns 250 products a poll
        // and polls every twenty minutes, so one brand was writing eighteen thousand dead
        // product tuples a day before a single thing about it had changed, plus one per
        // variant on top.
        //
        // Nothing here is new behaviour: the same values are stored, just not restored
        // identically several thousand times a day.
        var changed = product.isAvailable != item.isAvailable
            || product.priceText != item.priceText
            || product.priceAmount != item.priceAmount
        product.isAvailable = item.isAvailable
        product.priceText = item.priceText
        product.priceAmount = item.priceAmount

        // **`last_seen_at` is coarsened to a day, and that is the whole point of it.**
        //
        // Stamping it with `Date()` every poll guaranteed every row differed every time, so
        // no dirty check above this line could ever have saved a write. Its one and only
        // reader is `Reaper`, which compares it against a cutoff measured in *months*
        // (`PRODUCT_RETENTION_DAYS`, 180 by default) — per-poll precision on a field read at
        // 180-day granularity buys nothing and costs a rewrite of the entire catalogue every
        // twenty minutes. A day is still three orders of magnitude finer than the question.
        if Date().timeIntervalSince(product.lastSeenAt) > 86_400 {
            product.lastSeenAt = Date()
            changed = true
        }

        if product.imageURLs.isEmpty, !item.imageURLStrings.isEmpty {
            product.imageURLs = item.imageURLStrings
            changed = true
        }
        // A name can arrive late. Rows stored before the sitemap adapter learned to read
        // the image extension hold a randomised handle where the product name should be,
        // and nothing else would ever revisit them — the merge above only touches a row
        // it already has, and dedupe is on `externalID`, so the feed would keep saying
        // "E7Anvz3I1Psy" for as long as that product exists. Only ever an upgrade: a real
        // title is never replaced, least of all by a hash.
        if SitemapSource.isProvisional(product.title), !SitemapSource.isProvisional(item.title) {
            product.title = item.title
            changed = true
        }
        if changed { try await product.save(on: db) }

        guard !isBaseline else { return false }

        // A restock outranks a markdown: something coming *back* matters more than the
        // same thing getting cheaper, and one product should never write two events for
        // one poll.
        if !returnedSizes.isEmpty || wholeProductReturned {
            try await EventModel(
                brandID: brandID,
                productID: productID,
                kind: .restock,
                sizes: returnedSizes.filter { $0 != "Default Title" && !$0.isEmpty }
            ).save(on: db)
            return true
        }

        if dropped {
            try await EventModel(
                brandID: brandID,
                productID: productID,
                kind: .priceDrop,
                previousPriceText: wasText,
                previousPriceAmount: wasAmount
            ).save(on: db)
            return true
        }
        return false
    }
}

/// Runs `tick()` on an interval for as long as the app is up. One process, no Redis —
/// `next_check_at` in the database is the schedule, so a restart loses nothing.
///
/// Notification and retention ride along on the same loop rather than getting timers of
/// their own: both are driven by what polling produced, and a single sequential loop
/// means they can never overlap a poll pass or each other.
actor PollLoop {
    private let poller: Poller
    private let notifier: Notifier?
    private let reaper: Reaper?
    private let interval: Duration
    /// Retention is a table scan; it has no business running every 30 seconds.
    private let sweepInterval: TimeInterval
    private var lastSweep: Date?
    private var task: Task<Void, Never>?

    init(
        poller: Poller,
        notifier: Notifier? = nil,
        reaper: Reaper? = nil,
        interval: Duration = .seconds(30),
        sweepInterval: TimeInterval = 6 * 3600
    ) {
        self.poller = poller
        self.notifier = notifier
        self.reaper = reaper
        self.interval = interval
        self.sweepInterval = sweepInterval
    }

    func start(logger: Logger) {
        guard task == nil else { return }
        task = Task { [poller, notifier, reaper, interval] in
            while !Task.isCancelled {
                let count = await poller.tick()
                if count > 0 { logger.info("poller: checked \(count) sources") }

                // Runs every pass, not only after a poll: an event can be left unsent by
                // a crash or a transient APNs failure, and this is what picks it back up.
                if let notifier { await notifier.dispatch() }

                if let reaper, await self.isSweepDue() { await reaper.sweep() }

                try? await Task.sleep(for: interval)
            }
        }
    }

    private func isSweepDue() -> Bool {
        let now = Date()
        // The first sweep waits a full interval so a crash-looping deploy can't turn
        // retention into a delete-on-every-boot.
        guard let lastSweep else {
            self.lastSweep = now
            return false
        }
        guard now.timeIntervalSince(lastSweep) >= sweepInterval else { return false }
        self.lastSweep = now
        return true
    }

    func stop() {
        task?.cancel()
        task = nil
    }
}

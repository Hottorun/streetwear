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
    /// The country storefronts being read this pass — `Storefronts.wanted`, asked once per tick.
    /// Kept for `enrich`, which reads product pages under the same rule the claim does.
    private var wantedStorefronts: Set<UUID> = []

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
        // Which country shops somebody in one of their countries follows — the only ones
        // claimed, and each once however many of its countries ask. Empty whenever no
        // country is switched on, which leaves every claim reading the main shops alone,
        // exactly as before storefronts existed.
        wantedStorefronts = await liveStorefrontIDs()

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

        // After the polls and inside the same pass, so a product found a moment ago is read
        // and announced before `PollLoop` hands the pass to the notifier.
        await enrich()
        // And the announcement bars that are due, on the same politeness budget — a homepage
        // is a request to a storefront like any other. See `SaleBanners`.
        await SaleBanners(app: app, http: http).checkDue()
        return polled
    }

    // MARK: - Product pages

    /// Pages read per pass, at most.
    ///
    /// A page is the heaviest request this server makes — Hollister's is 968 KB — and each
    /// one waits its turn on the politeness budget like everything else, so six to one host
    /// is twelve seconds at the default interval. Enough that a sitemap's new products are
    /// read and announced within a pass or two; never enough to turn the poller into a crawler.
    static let enrichmentBudget = 6

    /// How long a watched product's page is believed before it is read again.
    ///
    /// The one product a sitemap brand has that anybody is waiting on. Re-reading it is what
    /// lets a watch fire at all on a brand with no catalogue endpoint — the restock is only
    /// visible on the page — and six hours is a restock found the same day for four requests
    /// a day per watched product.
    static let recheckAfter: TimeInterval = 6 * 3600

    /// The queue beyond what is owed an announcement is a scan of the products table, and
    /// has no business running every thirty seconds.
    static let backfillInterval: TimeInterval = 5 * 60
    private var lastBackfill: Date?

    /// Reads the pages of sitemap products, most urgent first, within `enrichmentBudget`.
    ///
    /// Three queues in order. **Owed an announcement** — a product just found, whose event is
    /// waiting on its page (`PendingAnnouncement`); oldest first, because it has waited
    /// longest. **Watched** — read again after `recheckAfter`, through the same `refresh` a
    /// poll uses, so a restock or a markdown there fires exactly as it would on Shopify.
    /// **Never read** — a baseline's rows, newest first, so the brand's page and Discover
    /// show prices and photographs too; last, because nobody is waiting on any of them.
    @discardableResult
    func enrich(budget: Int = Poller.enrichmentBudget) async -> Int {
        let queue: [ProductModel]
        do {
            queue = try await enrichmentQueue(limit: budget)
        } catch {
            app.logger.error("poller: enrichment queue failed: \(error)")
            return 0
        }

        var read = 0
        for product in queue {
            let outcome: ProductPage.Outcome
            if let link = product.linkURL.flatMap(URL.init(string:)) {
                outcome = await ProductPage.read(link, http: http)
            } else {
                outcome = .unreachable(retryable: false)
            }
            do {
                try await apply(outcome, to: product)
                read += 1
            } catch {
                app.logger.error("poller: could not store the page of \(product.externalID): \(error)")
            }
        }
        return read
    }

    private func enrichmentQueue(limit: Int) async throws -> [ProductModel] {
        let db = app.db
        let wanted = wantedStorefronts
        var queue = try await ProductModel.query(on: db)
            .filter(\.$pendingAnnouncement != nil)
            .group(.or) { shops in Self.readable(shops, wanted: wanted) }
            .sort(\.$firstSeenAt)
            .limit(limit)
            .with(\.$variants)
            .all()

        let now = Date()
        guard queue.count < limit,
              lastBackfill.map({ now.timeIntervalSince($0) >= Self.backfillInterval }) ?? true
        else { return queue }
        lastBackfill = now

        let watched = try await WatchModel.query(on: db)
            .filter(\.$firedAt == nil)
            .all()
            .map(\.$product.id)
        if !watched.isEmpty {
            let stale = now.addingTimeInterval(-Self.recheckAfter)
            queue += try await ProductModel.query(on: db)
                .filter(\.$id ~~ Array(Set(watched)))
                .filter(\.$externalID =~ "sitemap:")
                .group(.or) { $0.filter(\.$enrichedAt == nil).filter(\.$enrichedAt < stale) }
                .limit(limit - queue.count)
                .with(\.$variants)
                .all()
        }

        guard queue.count < limit else { return queue }
        let held = Set(queue.compactMap(\.id))
        let unread = try await ProductModel.query(on: db)
            .filter(\.$externalID =~ "sitemap:")
            .group(.or) { shops in Self.readable(shops, wanted: wanted) }
            .filter(\.$enrichedAt == nil)
            .filter(\.$kind == UpdateKind.product.rawValue)
            .sort(\.$firstSeenAt, .descending)
            .limit(limit)
            .with(\.$variants)
            .all()
        queue += unread.filter { $0.id.map { !held.contains($0) } ?? false }.prefix(limit - queue.count)
        return queue
    }

    /// The main shop, or a country shop somebody there follows: the products whose pages may
    /// be read. A product page is a request to a storefront like any other, and a paused
    /// storefront is not read at all. Grouped with `.or`, so the main shop alone is
    /// `storefront_id IS NULL` — what every product was before storefronts existed.
    private static func readable(_ group: QueryBuilder<ProductModel>, wanted: Set<UUID>) {
        group.filter(\.$storefrontID == nil)
        if !wanted.isEmpty { group.filter(\.$storefrontID ~~ Array(wanted)) }
    }

    /// What one page read means for its row.
    private func apply(_ outcome: ProductPage.Outcome, to product: ProductModel) async throws {
        let db = app.db
        let owed = product.pendingAnnouncement.flatMap(PendingAnnouncement.init(rawValue:))
        let firstRead = product.enrichedAt == nil

        switch outcome {
        case .unreachable(retryable: true):
            // Our own queue for that host was full. Nothing is stamped, so the next pass
            // asks again — this is congestion, not an answer.
            return

        case .product(let page):
            let item = page.applied(to: storedItem(product))
            product.title = item.title
            if product.summary == nil { product.summary = item.summary }
            if item.imageURLStrings.count > product.imageURLs.count { product.imageURLs = item.imageURLStrings }
            if product.productType == nil { product.productType = item.productType }
            if product.tags.isEmpty { product.tags = item.tags }
            product.enrichedAt = Date()
            product.pendingAnnouncement = nil
            // Price, stock and variants go through the poll's own `refresh`, so a watched
            // product read again raises the same restock and price-drop events a Shopify
            // poll would. A first read is a baseline: there is nothing to compare it with.
            _ = try await refresh(product, with: item, brandID: product.$brand.id, isBaseline: firstRead)
            try await product.save(on: db)

        case .notAProduct, .unreachable(retryable: false):
            // A guess the page did not bear out is not a product. Nothing was announced and
            // the sitemap's memory still holds the URL, so it will not come back.
            if owed == .confirm {
                try await product.delete(on: db)
                return
            }
            product.enrichedAt = Date()
            product.pendingAnnouncement = nil
            try await product.save(on: db)
        }

        // Owed, and either the page confirmed it or it was surely a product all along. A
        // page that failed costs the announcement its details, never the announcement.
        if let owed, owed == .announce || outcomeIsProduct(outcome), let productID = product.id {
            try await EventModel(
                brandID: product.$brand.id,
                productID: productID,
                storefrontID: product.storefrontID,
                kind: .product
            ).save(on: db)
        }
    }

    private func outcomeIsProduct(_ outcome: ProductPage.Outcome) -> Bool {
        if case .product = outcome { return true }
        return false
    }

    /// The row as the adapter item it was made from, so a page can be laid over it.
    private func storedItem(_ product: ProductModel) -> FetchedItem {
        FetchedItem(
            externalID: product.externalID,
            title: product.title,
            summary: product.summary,
            linkURL: product.linkURL.flatMap(URL.init(string:)),
            imageURLStrings: product.imageURLs,
            publishedAt: product.publishedAt,
            kind: UpdateKind(rawValue: product.kind) ?? .product,
            priceText: product.priceText,
            priceAmount: product.priceAmount,
            currency: product.currency,
            originalPriceAmount: product.originalPriceAmount,
            originalPriceText: product.originalPriceText,
            isAvailable: product.isAvailable,
            tags: product.tags,
            productType: product.productType,
            variants: product.variants.map(\.asVariantInfo)
        )
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
        // **The main shop always, a country shop only while somebody in one of its countries
        // follows the brand**
        // — see `Storefronts.wanted`. The one fragment the statements below share, and the
        // only one built at all: with no country switched on it is `storefront_id IS NULL`,
        // which every source written before storefronts existed is.
        let wanted = Array(wantedStorefronts)
        let shops: SQLQueryString = wanted.isEmpty
            ? "storefront_id IS NULL"
            : "(storefront_id IS NULL OR storefront_id = ANY(\(bind: wanted)))"
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
                        AND \(shops) \
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
                        AND \(shops) \
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
                        AND \(shops) \
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
            .with(\.$storefront)
            .all()
    }

    private func dueWithoutClaim(
        limit: Int,
        brandIDs: Set<UUID> = [],
        matching: Bool = false
    ) async throws -> [SourceModel] {
        let wanted = Array(wantedStorefronts)
        var builder = SourceModel.query(on: app.db)
            .filter(\.$enabled == true)
            .filter(\.$nextCheckAt <= Date())
            .group(.or) { shops in
                shops.filter(\.$storefront.$id == nil)
                if !wanted.isEmpty { shops.filter(\.$storefront.$id ~~ wanted) }
            }
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
            .with(\.$storefront)
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

    /// The country storefronts somebody in one of their countries follows, once per tick.
    /// Failure is silent and
    /// empty, for the reason a hint's is: the main shops are polled either way, and a queue
    /// that stopped because this could not be read would be the worse trade.
    private func liveStorefrontIDs() async -> Set<UUID> {
        do {
            return try await Storefronts.wanted(enabled: app.storefrontCountries, on: app.db)
        } catch {
            app.logger.error("poller: could not read which storefronts are followed: \(error)")
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
        //
        // A country shop that sat unread — nobody in any of its countries followed the brand
        // for a while — owes
        // a baseline again, because whatever it knew is months old and everything since would
        // otherwise go out as news to the first follower back. The baseline is *unspent* rather
        // than this one poll declared one, so a resumed poll that fails leaves it owed, exactly
        // as a first poll that fails does. See `Storefronts.resumeAfter`.
        let storefront = source.$storefront.id == nil ? nil : source.storefront
        if storefront != nil, Storefronts.hasLapsed(since: source.lastCheckedAt) {
            source.baselinedAt = nil
        }
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
            // **A country shop's currency is its own**, and it must not reach the brand row:
            // `brands.currency` is the main shop's, and the price of every row from before
            // currencies were stored is read in it. Nor may a country shop rename the brand —
            // the name is the brand's, and a British shop's `/meta.json` can say "Palace UK".
            if let storefront {
                if let currency = result.shopCurrency, storefront.currency != currency {
                    storefront.currency = currency
                    try await storefront.save(on: db)
                }
            } else if let currency = result.shopCurrency, brand.currency != currency {
                brand.currency = currency
                try await brand.save(on: db)
            }
            if storefront == nil, let name = result.shopName, brand.usesGeneratedName {
                brand.name = name
                brand.usesGeneratedName = false
                try await brand.save(on: db)
            }

            // A source can declare its own read a baseline when this one has already been
            // spent: a sitemap meeting its memory for the first time has no idea what it has
            // seen, and without this a source baselined under the old rules would offer up a
            // poll's worth of long-listed products as drops. See `FetchResult.isBaseline`.
            if !result.notModified {
                hadEvent = try await merge(
                    result.items,
                    brand: brand,
                    sourceID: sourceID,
                    storefrontID: storefront?.id,
                    isBaseline: isFirstPoll || result.isBaseline,
                    kind: kind
                )
            }

            // Collections announced before the membership could be read hold none, and
            // nothing else would ever go back for them: `/collections.json` is filtered by
            // `since`, so a collection is offered to the merge exactly once in its life.
            // Without this the fix reaches only collections published from today onward,
            // while every release already on somebody's feed keeps falling back to the word
            // match — which is what put five board shorts inside a hat.
            if kind == .collections, !isFirstPoll {
                try? await fillMemberships(brandID: brandID, storefrontID: storefront?.id, store: source.asBrandSource.url)
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

        let cadence = Cadence.next(
            locked: source.lockedAt != nil,
            hadRecentEvent: hadEvent,
            quietForAWeek: quiet,
            failures: source.failureCount,
            // Only asked when a hint hasn't already answered it: both produce sixty
            // seconds, and the rhythm read costs an indexed query over 400 rows.
            inDropWindow: isHinted ? false : try await isInDropWindow(brandID: brandID),
            hinted: isHinted
        )
        // A sitemap is regenerated on a schedule, not as products go up, and can be megabytes
        // a read — see `SitemapSource.minimumInterval`. The app's own copy of the rule is in
        // `BrandSource.isReadyToCheck`.
        source.nextCheckAt = Date().addingTimeInterval(
            kind == .sitemap ? max(cadence, SitemapSource.minimumInterval) : cadence
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

    /// How many stored collections one poll goes back for. A handful per brand per cycle
    /// converges within a day and keeps the cost beside the poll that is already happening.
    private static let membershipBackfill = 3
    /// How far back it is worth going. A release nobody can still see in a feed is not
    /// worth a request — the client keeps 400 rows per brand and retention prunes events at
    /// thirty days.
    private static let membershipBackfillDays = 45.0

    /// Reads the real contents of collections stored before that was possible.
    ///
    /// Newest first and capped, filtered in Swift rather than in SQL: "an empty array
    /// column" is not something Fluent expresses the same way on Postgres and SQLite, which
    /// is exactly the class of difference that passes locally and fails on the deployment.
    /// The window keeps the scan small enough that reading a few extra rows is cheaper than
    /// being clever about it.
    private func fillMemberships(brandID: UUID, storefrontID: UUID?, store: URL) async throws {
        let since = Date().addingTimeInterval(-Self.membershipBackfillDays * 86_400)
        let stale = try await ProductModel.query(on: app.db)
            .filter(\.$brand.$id == brandID)
            // This shop's collections, asked of this shop — a British release is not in the
            // American catalogue.
            .filter(\.$storefrontID == storefrontID)
            .filter(\.$kind == UpdateKind.collection.rawValue)
            .filter(\.$publishedAt >= since)
            .sort(\.$publishedAt, .descending)
            .limit(40)
            .all()
            .filter { $0.memberExternalIDs.isEmpty }
            .prefix(Self.membershipBackfill)

        for collection in stale {
            // The handle is the last segment of the link the adapter built —
            // `/collections/<handle>` — and is the only place it survives.
            guard let link = collection.linkURL,
                  let handle = URL(string: link)?.lastPathComponent,
                  !handle.isEmpty, handle != "collections"
            else { continue }
            guard let membership = try? await CollectionsSource.membership(
                of: handle,
                in: store,
                http: http
            ), !membership.externalIDs.isEmpty else { continue }

            collection.memberExternalIDs = membership.externalIDs
            try await collection.save(on: app.db)
        }
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
    ///
    /// - Parameter kind: the source's. A new sitemap product is stored with its event held
    ///   back for its page to be read — see `PendingAnnouncement` and `enrich`.
    /// - Parameter storefrontID: the country shop the source reads, nil for the main shop —
    ///   copied onto every product and event this writes.
    private func merge(
        _ items: [FetchedItem],
        brand: BrandModel,
        sourceID: UUID,
        storefrontID: UUID? = nil,
        isBaseline: Bool,
        kind: BrandSource.Kind
    ) async throws -> Bool {
        // A tentative item is a guess only its page can settle, and a baseline settles
        // nothing — storing one would leave a category page in the catalogue for good.
        let items = isBaseline ? items.filter { !$0.isTentative } : items
        guard !items.isEmpty, let brandID = brand.id else { return false }
        let db = app.db
        // How much of what this pass read is marked down — counted before `refresh`
        // overwrites the stored price, which is the "previous" half of a cut. See
        // `CatalogueSale`.
        var reading = CatalogueSale.Reading()
        let holdsAnnouncements = kind == .sitemap && !isBaseline

        let existing = try await ProductModel.query(on: db)
            .filter(\.$source.$id == sourceID)
            .filter(\.$externalID ~~ items.map(\.externalID))
            .with(\.$variants)
            .all()
        let byExternalID = Dictionary(existing.map { ($0.externalID, $0) }, uniquingKeysWith: { a, _ in a })

        var producedEvent = false

        for item in items {
            if let product = byExternalID[item.externalID] {
                reading.count(now: item.priceAmount, original: item.originalPriceAmount, previous: product.priceAmount)
                if try await refresh(product, with: item, brandID: brandID, isBaseline: isBaseline) {
                    producedEvent = true
                }
            } else {
                reading.count(now: item.priceAmount, original: item.originalPriceAmount, previous: nil)
                let product = ProductModel(brandID: brandID, sourceID: sourceID, storefrontID: storefrontID, item: item)
                if holdsAnnouncements {
                    product.pendingAnnouncement = (item.isTentative
                        ? PendingAnnouncement.confirm
                        : PendingAnnouncement.announce).rawValue
                }
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
                    // the other reason there may be no event here. A held announcement is
                    // the third: `enrich` writes it once the page has been read.
                    if !isBaseline, !holdsAnnouncements, let kind = Reshelving.firstSighting(of: item) {
                        // A markdown met for the first time has no earlier poll to have
                        // fallen from, so what it fell from is the brand's own original.
                        let isMarkdown = kind == .priceDrop
                        try await EventModel(
                            brandID: brandID,
                            productID: productID,
                            storefrontID: storefrontID,
                            kind: kind,
                            previousPriceText: isMarkdown ? item.originalPriceText : nil,
                            previousPriceAmount: isMarkdown ? item.originalPriceAmount : nil
                        ).save(on: db)
                        producedEvent = true
                    }
                }
            }
        }
        // The main shop's alone: the sale state lives on the brand row, and a British shop
        // marking down is not the brand's main shop going on sale. See `docs/server.md`.
        if storefrontID == nil, try await settleSale(reading, of: brand, isBaseline: isBaseline) {
            producedEvent = true
        }
        return producedEvent
    }

    /// Whether this pass put the brand on sale, and if it did, the one event that says so.
    ///
    /// The state is written only on a transition — `CatalogueSale.decide` answers
    /// `.unchanged` for every pass in between — because the brand row is read on every poll
    /// and rewriting it each time is the volume problem `refresh` guards against.
    private func settleSale(_ reading: CatalogueSale.Reading, of brand: BrandModel, isBaseline: Bool) async throws -> Bool {
        guard let brandID = brand.id else { return false }
        let state = CatalogueSale.State(measuredAt: brand.saleMeasuredAt, since: brand.saleSince)
        let next: CatalogueSale.State
        let started: Bool
        switch CatalogueSale.decide(reading, state: state, isBaseline: isBaseline) {
        case .unchanged: return false
        case .record(let recorded): (next, started) = (recorded, false)
        case .started(let recorded): (next, started) = (recorded, true)
        }
        brand.saleMeasuredAt = next.measuredAt
        brand.saleSince = next.since
        try await brand.save(on: app.db)
        guard started else { return false }
        let said = CatalogueSale.announcement(for: reading)
        return try await SaleEvents.announce(on: app.db, brandID: brandID, title: said.title, summary: said.summary)
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
        let dropped = PriceChange.isDrop(
            from: product.priceAmount, in: product.currency,
            to: item.priceAmount, in: item.currency
        )
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
        //
        // **A source that says nothing about price or stock does not erase them.** A sitemap
        // item carries neither; the row's came from its page (`enrich`), and a sitemap read
        // that rewrote them with nil would undo that read. Every source that does publish a
        // price — Shopify, UCP — publishes one every time, so for those nothing changes.
        let isAvailable = item.isAvailable ?? product.isAvailable
        let priceText = item.priceText ?? product.priceText
        let priceAmount = item.priceAmount ?? product.priceAmount
        var changed = product.isAvailable != isAvailable
            || product.priceText != priceText
            || product.priceAmount != priceAmount
        product.isAvailable = isAvailable
        product.priceText = priceText
        product.priceAmount = priceAmount
        // The currency follows the price it belongs to, and only a read that priced the row
        // may change it — a sitemap says nothing about either.
        if let currency = item.currency, item.priceAmount != nil, product.currency != currency {
            product.currency = currency
            changed = true
        }
        // The brand's original follows the price it belongs to. A source that publishes a
        // price says every time whether it is marked down — compare-at comes back null once
        // a sale ends, which must clear it — and one that publishes no price says nothing
        // about either.
        let originalText = item.priceAmount == nil ? product.originalPriceText : item.originalPriceText
        let originalAmount = item.priceAmount == nil ? product.originalPriceAmount : item.originalPriceAmount
        if product.originalPriceText != originalText || product.originalPriceAmount != originalAmount {
            product.originalPriceText = originalText
            product.originalPriceAmount = originalAmount
            changed = true
        }

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
        // A collection stored before the membership was readable holds none, and the merge
        // above only ever touches rows it already has — so without this the release pages
        // for every collection already in the catalogue stay on the word match forever.
        // Filled only when empty, like the images: a storefront that stops answering must
        // not blank a list we were once told.
        if product.memberExternalIDs.isEmpty, !item.memberExternalIDs.isEmpty {
            product.memberExternalIDs = item.memberExternalIDs
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
                storefrontID: product.storefrontID,
                kind: .restock,
                sizes: returnedSizes.filter { $0 != "Default Title" && !$0.isEmpty }
            ).save(on: db)
            return true
        }

        if dropped {
            try await EventModel(
                brandID: brandID,
                productID: productID,
                storefrontID: product.storefrontID,
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

                if let reaper, self.isSweepDue() { await reaper.sweep() }

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

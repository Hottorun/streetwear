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
        static func next(locked: Bool, hadRecentEvent: Bool, quietForAWeek: Bool, failures: Int) -> TimeInterval {
            if failures > 0 {
                return min(pow(2.0, Double(failures)) * 60, 6 * 3600)
            }
            if locked { return 60 }               // a drop is imminent
            if hadRecentEvent { return 5 * 60 }
            if quietForAWeek { return 2 * 3600 }
            return 20 * 60
        }
    }

    /// One pass over everything currently due.
    @discardableResult
    func tick(limit: Int = 20) async -> Int {
        guard !isRunning else { return 0 }
        isRunning = true
        defer { isRunning = false }

        let due: [SourceModel]
        do {
            due = try await claimDue(limit: limit)
        } catch {
            app.logger.error("poller: queue query failed: \(error)")
            return 0
        }

        var polled = 0
        for source in due {
            // One domain at a time — see the politeness budget in BACKEND.md.
            do {
                try await poll(source)
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
    private func claimDue(limit: Int) async throws -> [SourceModel] {
        let db = app.db
        guard let sql = db as? any SQLDatabase, sql.dialect.name == "postgresql" else {
            return try await dueWithoutClaim(limit: limit)
        }

        let now = Date()
        let ids: [UUID]
        do {
            ids = try await sql.raw("""
                UPDATE sources SET next_check_at = \(bind: now.addingTimeInterval(Self.leaseDuration)) \
                WHERE id IN ( \
                    SELECT id FROM sources \
                    WHERE enabled = true AND next_check_at <= \(bind: now) \
                    ORDER BY next_check_at LIMIT \(bind: limit) \
                    FOR UPDATE SKIP LOCKED \
                ) RETURNING id
                """).all(decodingColumn: "id", as: UUID.self)
        } catch {
            // This statement is the one piece of the poller that no local test can
            // reach — SQLite has no `SKIP LOCKED`, so it is only ever exercised against
            // the deployed database. Degrading to the unclaimed query keeps polling
            // alive if it turns out to be wrong there; a single instance behaves exactly
            // as it did before claiming existed.
            app.logger.error("poller: claim failed, falling back to plain queue: \(error)")
            return try await dueWithoutClaim(limit: limit)
        }

        guard !ids.isEmpty else { return [] }
        return try await SourceModel.query(on: db)
            .filter(\.$id ~~ ids)
            .with(\.$brand)
            .all()
    }

    private func dueWithoutClaim(limit: Int) async throws -> [SourceModel] {
        try await SourceModel.query(on: app.db)
            .filter(\.$enabled == true)
            .filter(\.$nextCheckAt <= Date())
            .sort(\.$nextCheckAt)
            .limit(limit)
            .with(\.$brand)
            .all()
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

    private func poll(_ source: SourceModel) async throws {
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

            if brand.lockedForDrop != result.isLocked {
                brand.lockedForDrop = result.isLocked
                try await brand.save(on: db)
            }
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
        }

        let quiet = try await EventModel.query(on: db)
            .filter(\.$brand.$id == brandID)
            .filter(\.$createdAt >= Date().addingTimeInterval(-7 * 86_400))
            .count() == 0

        source.nextCheckAt = Date().addingTimeInterval(
            Cadence.next(
                locked: brand.lockedForDrop,
                hadRecentEvent: hadEvent,
                quietForAWeek: quiet,
                failures: source.failureCount
            )
        )
        try await source.save(on: db)
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
                    // The first poll of a brand must not fire 2,500 notifications.
                    if !isBaseline {
                        try await EventModel(brandID: brandID, productID: productID, kind: item.kind)
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
                if !existing.available && info.available {
                    returnedSizes.append(info.size ?? info.title)
                    existing.availableChangedAt = Date()
                }
                existing.available = info.available
                existing.price = info.price
                existing.size = info.size
                existing.color = info.color
                try await existing.save(on: db)
            } else {
                try await VariantModel(productID: productID, info: info).save(on: db)
            }
        }

        // Products without variant data fall back to whole-product availability.
        let wholeProductReturned = item.variants.isEmpty
            && product.isAvailable == false
            && item.isAvailable == true

        // Checked before the incoming price overwrites the stored one.
        let dropped = PriceChange.isDrop(from: product.priceAmount, to: item.priceAmount)

        product.isAvailable = item.isAvailable
        product.priceText = item.priceText
        product.priceAmount = item.priceAmount
        product.lastSeenAt = Date()
        if product.imageURLs.isEmpty { product.imageURLs = item.imageURLStrings }
        try await product.save(on: db)

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
            try await EventModel(brandID: brandID, productID: productID, kind: .priceDrop).save(on: db)
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

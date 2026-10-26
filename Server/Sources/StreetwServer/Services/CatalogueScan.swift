// CatalogueScan.swift
// The daily full scan: every product a Shopify shop lists, with its price and stock.
//
// The poll is the fast half and stays exactly as it was: it reads the newest products every few
// minutes and is the only thing that may call a product new. Its baseline is a shop's newest
// 2,500 and it re-reads only the newest ~250, so everything older — exactly what goes on sale —
// sat at whatever price it had the day it fell out of that window: invisible to markdowns, to
// a restock, to a watch and to `CatalogueSale`. This is the slow half. Once a day per source it
// reads `/products.json` to the end, a few pages a pass, and writes what changed.
//
// What it is careful about, each with the failure it prevents (see `docs/server.md`):
//
// - **It writes catalogue state and says nothing new.** Events come only from `refresh`, by the
//   rules the poll already keeps — a size coming back, a markdown past 5% — and from
//   `CatalogueSale`. A product the scan meets for the first time is stored silently, and one
//   published inside the last day is not stored at all: it belongs to the poll, and a scan that
//   reached it first would have swallowed the drop.
// - **A first scan, and a scan after a lapse, is a baseline.** The stored state of old stock is
//   months stale on the day this ships; comparing against it would announce every restock and
//   markdown since as news.
// - **An unchanged product is not written**, and the scan does not stamp `last_seen_at` — the
//   rewrite of a whole catalogue a day is the volume problem `refresh` exists to avoid.
// - **It never slows the poll.** Its own loop, one page in flight at a time through the shared
//   `PoliteFetcher`, so a poll to the same host waits one politeness slot at most, and a poll of
//   the same brand waits at most one page being written (`Poller.holdBrand`).

import Fluent
import Foundation
import SQLKit
import StreetwCore
import Vapor

enum CatalogueScan {
    /// Pages one source reads in a pass before it goes back in the queue.
    ///
    /// Four pages is a thousand products and eight seconds of one host's politeness budget. A
    /// 30,000-product shop is 120 pages — thirty turns, each behind every scan that has waited
    /// longer — so it takes its share of the fetcher and never all of it.
    static let pagesPerTurn = 4
    /// Sources given a turn per pass. With a pass a minute that is up to twelve pages a minute,
    /// ~17,000 a day: far more than a daily read of every catalogue needs (a 5,000-product shop
    /// is 20 pages), so a scan delayed by a backlog catches up the same day.
    static let scansPerPass = 3
    /// The most one scan reads: 50,000 products. A scan that reaches it stops and says so
    /// (`last_truncated`), keeps the prices it read, and does not count as complete, so nothing
    /// past the cap is ever taken for removed.
    static let maxPages = 200
    /// How long a claim holds a source off the queue — far longer than a turn takes, short
    /// enough that a process killed mid-turn costs minutes, not the day.
    static let leaseDuration: TimeInterval = 10 * 60
    /// A scan in progress this old is started again rather than resumed. Resuming is for a
    /// deploy or a crash; a memory of what was listed that spans days is not one catalogue.
    static let abandonAfter: TimeInterval = 12 * 3600
    /// A scan is a baseline when no scan has finished for this long, because the stored prices
    /// it would compare against are that old.
    static let staleAfter: TimeInterval = 3 * 86_400
    /// Products published this recently are the poll's, not the scan's — see `merge`.
    static let newsMargin: TimeInterval = 86_400
    /// A shop behind its password wall is asked again in an hour: it is about to drop, and the
    /// poll is the one watching that.
    static let lockedRetry: TimeInterval = 3600
    /// How often the scanner looks for Shopify sources it has no row for yet.
    static let enrolInterval: TimeInterval = 10 * 60
    /// More than this share of a shop missing from one scan is not believed — see `unlist`.
    static let removalCeiling = 0.5
    /// …unless it is this few products, which is what a small shop clearing a rail looks like.
    static let removalFloor = 25

    /// Where in the UTC day this source's scan falls, fixed by its id.
    ///
    /// **Spread across the day, not at midnight.** Every catalogue scanned at once would be a
    /// burst of thousands of requests to dozens of hosts while the poll queued behind it, then
    /// silence. By id rather than at random, so a source keeps its slot across deploys and the
    /// slots of a few hundred sources fall evenly.
    static func slot(for sourceID: UUID) -> TimeInterval {
        var hash: UInt32 = 2_166_136_261
        for byte in withUnsafeBytes(of: sourceID.uuid, Array.init) {
            hash ^= UInt32(byte)
            hash = hash &* 16_777_619
        }
        return TimeInterval(hash % 86_400)
    }

    /// The first time at or after `date` that is this source's slot.
    static func nextSlot(onOrAfter date: Date, sourceID: UUID) -> Date {
        let day = floor(date.timeIntervalSince1970 / 86_400) * 86_400
        let today = Date(timeIntervalSince1970: day + slot(for: sourceID))
        return today >= date ? today : today.addingTimeInterval(86_400)
    }

    /// When the scan after one that started at `started` is due: the source's slot, at least
    /// twelve hours on. **At most once a day** — one scan per slot — and a scan that started
    /// late because the queue was busy does not push the next one a day later.
    static func nextDue(afterStart started: Date, sourceID: UUID) -> Date {
        nextSlot(onOrAfter: started.addingTimeInterval(12 * 3600), sourceID: sourceID)
    }

    /// A failed turn waits five minutes, doubling, up to six hours — the poll's ceiling.
    static func backoff(failures: Int) -> TimeInterval {
        min(pow(2.0, Double(max(failures - 1, 0))) * 5 * 60, 6 * 3600)
    }
}

/// The products a scan has seen, as 32-bit FNV-1a digests of their `external_id`.
///
/// What removal is decided from, and kept in the scan's row so an interrupted scan resumes with
/// it. Digests rather than ids for the reason `SitemapMemory` gives — 4 bytes a product, 20 KB
/// for a 5,000-product shop — and a collision fails safe: a removed product taken for a listed
/// one stays listed for another day.
enum ScanDigests {
    static func digest(_ externalID: String) -> UInt32 {
        var hash: UInt32 = 2_166_136_261
        for byte in externalID.utf8 {
            hash ^= UInt32(byte)
            hash = hash &* 16_777_619
        }
        return hash
    }

    static func decode(_ stored: String?) -> Set<UInt32> {
        guard let stored, let bytes = Data(base64Encoded: stored), bytes.count % 4 == 0 else { return [] }
        var seen = Set<UInt32>(minimumCapacity: bytes.count / 4)
        var index = bytes.startIndex
        while index < bytes.endIndex {
            seen.insert(bytes[index..<(index + 4)].reduce(UInt32(0)) { $0 << 8 | UInt32($1) })
            index += 4
        }
        return seen
    }

    static func encode(_ seen: Set<UInt32>) -> String {
        var bytes = Data()
        bytes.reserveCapacity(seen.count * 4)
        for value in seen.sorted() {
            bytes.append(contentsOf: [UInt8(value >> 24), UInt8((value >> 16) & 0xFF), UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)])
        }
        return bytes.base64EncodedString()
    }
}

extension Poller {
    /// One pass of the scanner: up to `limit` due sources, `pagesPerTurn` pages each.
    ///
    /// Returns the pages read.
    @discardableResult
    func scanTick(
        limit: Int = CatalogueScan.scansPerPass,
        pagesPerTurn: Int = CatalogueScan.pagesPerTurn
    ) async -> Int {
        guard !isScanning else { return 0 }
        isScanning = true
        defer { isScanning = false }

        let now = Date()
        if lastScanEnrolment.map({ now.timeIntervalSince($0) >= CatalogueScan.enrolInterval }) ?? true {
            lastScanEnrolment = now
            do { try await enrolScans(now: now) } catch {
                app.logger.error("scan: could not enrol sources: \(error)")
            }
        }

        // The poll's rule for country shops, asked for this pass: a paused shop is never
        // scanned, and a live one is scanned like the main shop.
        let wanted = await liveStorefrontIDs()
        let due: [CatalogueScanModel]
        do {
            due = try await claimScans(limit: limit, wanted: wanted, now: now)
        } catch {
            app.logger.error("scan: queue query failed: \(error)")
            return 0
        }

        var pages = 0
        for scan in due {
            do {
                pages += try await turn(scan, pages: pagesPerTurn)
            } catch {
                // A turn that threw after its claim still leaves the lease as the schedule, so
                // the source is retried once it lapses rather than every pass.
                app.logger.error("scan: \(scan.source.url) failed: \(error)")
            }
        }
        return pages
    }

    /// Gives every Shopify source without one a scan row, due at its slot.
    ///
    /// **Created by the scanner, not where sources are made.** Five paths make a source —
    /// discovery, a check, a repoint, a storefront, the admin — and a scan that depended on
    /// each remembering would be missing for whichever forgot. Due at the *next* slot, so a
    /// deploy spreads the first scans over the following day instead of starting them all.
    func enrolScans(now: Date = Date()) async throws {
        let db = app.db
        guard let sql = db as? any SQLDatabase else { return }
        let enrolled = Set(try await sql.raw("SELECT source_id FROM catalogue_scans")
            .all(decodingColumn: "source_id", as: UUID.self))
        let sources = try await SourceModel.query(on: db)
            .filter(\.$kind == BrandSource.Kind.shopify.rawValue)
            .all()
        for source in sources {
            guard let id = source.id, !enrolled.contains(id) else { continue }
            let scan = CatalogueScanModel(sourceID: id, dueAt: CatalogueScan.nextSlot(onOrAfter: now, sourceID: id))
            // Unique on the source: another instance enrolling it first is not a failure.
            try? await scan.create(on: db)
        }
    }

    /// Claims due scans, **as a lease**, the way the poll queue does: `due_at` pushed forward in
    /// the statement that picks them, `FOR UPDATE SKIP LOCKED` so two instances never scan one
    /// source. Only the scan rows are locked (`FOR UPDATE OF`), never `sources`, which the
    /// poll's own claim locks every tick. Only sources the poll has baselined — a scan before
    /// the poll's first read would take the shop's newest products for old ones — and only
    /// country shops somebody there follows. SQLite has neither the syntax nor a second
    /// instance and keeps a plain query.
    private func claimScans(limit: Int, wanted: Set<UUID>, now: Date) async throws -> [CatalogueScanModel] {
        let db = app.db
        let lease = now.addingTimeInterval(CatalogueScan.leaseDuration)
        var ids: [UUID] = []

        if let sql = db as? any SQLDatabase, sql.dialect.name == "postgresql" {
            let shops: SQLQueryString = wanted.isEmpty
                ? "sources.storefront_id IS NULL"
                : "(sources.storefront_id IS NULL OR sources.storefront_id = ANY(\(bind: Array(wanted))))"
            let query: SQLQueryString = """
                UPDATE catalogue_scans SET due_at = \(bind: lease) \
                WHERE id IN ( \
                    SELECT catalogue_scans.id FROM catalogue_scans \
                    JOIN sources ON sources.id = catalogue_scans.source_id \
                    WHERE catalogue_scans.due_at <= \(bind: now) \
                    AND sources.enabled = true AND sources.kind = 'shopify' \
                    AND sources.baselined_at IS NOT NULL \
                    AND \(shops) \
                    ORDER BY catalogue_scans.due_at LIMIT \(bind: limit) \
                    FOR UPDATE OF catalogue_scans SKIP LOCKED \
                ) RETURNING id
                """
            ids = try await sql.raw(query).all(decodingColumn: "id", as: UUID.self)
        } else {
            let due = try await CatalogueScanModel.query(on: db)
                .filter(\.$dueAt <= now)
                .sort(\.$dueAt)
                .with(\.$source)
                .all()
            for scan in due where ids.count < limit {
                let source = scan.source
                guard source.enabled, source.kind == BrandSource.Kind.shopify.rawValue, source.baselinedAt != nil,
                      source.$storefront.id.map(wanted.contains) ?? true
                else { continue }
                scan.dueAt = lease
                try await scan.save(on: db)
                if let id = scan.id { ids.append(id) }
            }
        }

        guard !ids.isEmpty else { return [] }
        return try await CatalogueScanModel.query(on: db)
            .filter(\.$id ~~ ids)
            .with(\.$source) { source in
                source.with(\.$brand)
                source.with(\.$storefront)
            }
            .sort(\.$dueAt)
            .all()
    }

    /// Whether a scan beginning now is a baseline: none has finished recently, or the poll has
    /// spent its baseline again since the last one did (a country shop back from a pause), so
    /// what is stored is not a "before" that anything can be news against.
    static func scanIsBaseline(completedAt: Date?, sourceBaselinedAt: Date?, now: Date) -> Bool {
        guard let completedAt, now.timeIntervalSince(completedAt) <= CatalogueScan.staleAfter else { return true }
        if let baselined = sourceBaselinedAt, baselined > completedAt { return true }
        return false
    }

    /// One turn of one source's scan. Returns the pages read.
    private func turn(_ scan: CatalogueScanModel, pages budget: Int) async throws -> Int {
        let db = app.db
        let now = Date()
        let source = scan.source
        let brand = source.brand
        guard source.enabled, source.baselinedAt != nil,
              let brandID = brand.id, let sourceID = source.id,
              let base = URL(string: source.url)
        else {
            scan.dueAt = CatalogueScan.nextSlot(onOrAfter: now.addingTimeInterval(1), sourceID: source.id ?? UUID())
            try await scan.save(on: db)
            return 0
        }
        let storefront = source.$storefront.id == nil ? nil : source.storefront

        // Begin, or carry on where the last turn — or the last process — left off.
        if scan.startedAt.map({ now.timeIntervalSince($0) >= CatalogueScan.abandonAfter }) ?? true {
            scan.startedAt = now
            scan.nextPage = 1
            scan.seen = nil
            scan.priced = 0
            scan.markedDown = 0
            scan.deepest = nil
            scan.isBaseline = Self.scanIsBaseline(
                completedAt: scan.completedAt,
                sourceBaselinedAt: source.baselinedAt,
                now: now
            )
        }
        let startedAt = scan.startedAt ?? now
        var seen = ScanDigests.decode(scan.seen)
        var reading = scan.reading
        // **New is the poll's word, and the scan never says it.** Anything the poll has not
        // stored and was published within a day of its last read is left for the poll to find
        // and announce; and while the poll is failing, the scan stores nothing new at all —
        // a shop the poll cannot reach is a shop whose drops it has not seen yet.
        let horizon: Date? = source.failureCount == 0
            ? min(source.lastCheckedAt ?? now, now).addingTimeInterval(-CatalogueScan.newsMargin)
            : nil
        let currency = storefront?.currency ?? brand.currency

        var read = 0
        var finished: Bool? = nil
        while read < budget {
            if scan.nextPage > CatalogueScan.maxPages {
                finished = true
                break
            }
            let page: ShopifySource.CataloguePage
            do {
                page = try await ShopifySource.cataloguePage(of: base, page: scan.nextPage, currency: currency, http: http)
            } catch SourceError.hostBusy(_, let retryAfter) {
                // Our own queue for the host is full: congestion, not an answer.
                scan.dueAt = Date().addingTimeInterval(max(retryAfter, 30))
                return try await keep(scan, seen: seen, reading: reading, read: read)
            } catch {
                scan.failureCount += 1
                scan.lastError = String(describing: error)
                scan.dueAt = Date().addingTimeInterval(CatalogueScan.backoff(failures: scan.failureCount))
                return try await keep(scan, seen: seen, reading: reading, read: read)
            }
            if page.isLocked {
                scan.dueAt = Date().addingTimeInterval(CatalogueScan.lockedRetry)
                return try await keep(scan, seen: seen, reading: reading, read: read)
            }

            await holdBrand(brandID)
            do {
                try await mergeScanPage(
                    page.items,
                    brandID: brandID,
                    sourceID: sourceID,
                    storefrontID: storefront?.id,
                    isBaseline: scan.isBaseline,
                    insertsBefore: horizon,
                    reading: &reading
                )
            } catch {
                releaseBrand(brandID)
                throw error
            }
            releaseBrand(brandID)

            for item in page.items { seen.insert(ScanDigests.digest(item.externalID)) }
            scan.nextPage += 1
            read += 1
            if !page.isFull {
                finished = false
                break
            }
        }

        guard let truncated = finished else {
            // More to read: back in the queue at once, behind every scan that has waited longer.
            scan.dueAt = Date()
            scan.failureCount = 0
            scan.lastError = nil
            return try await keep(scan, seen: seen, reading: reading, read: read)
        }

        let finishedAt = Date()
        await holdBrand(brandID)
        do {
            if !truncated {
                try await unlist(sourceID: sourceID, seen: seen, scanStartedAt: startedAt, now: finishedAt)
                scan.completedAt = finishedAt
            }
            // The main shop's alone, as the poll's: the sale state lives on the brand row.
            if storefront == nil {
                try await settleCatalogueSale(reading, brandID: brandID, isBaseline: scan.isBaseline, now: finishedAt)
            }
        } catch {
            releaseBrand(brandID)
            throw error
        }
        releaseBrand(brandID)

        app.logger.info("scan: \(source.url) \(truncated ? "stopped at the page cap" : "complete"): \(scan.nextPage - 1) pages, \(seen.count) products\(scan.isBaseline ? ", baseline" : "")")
        scan.lastStartedAt = startedAt
        scan.finishedAt = finishedAt
        scan.lastPages = scan.nextPage - 1
        scan.lastProducts = seen.count
        scan.lastTruncated = truncated
        scan.startedAt = nil
        scan.nextPage = 1
        scan.seen = nil
        scan.priced = 0
        scan.markedDown = 0
        scan.deepest = nil
        scan.isBaseline = false
        scan.failureCount = 0
        scan.lastError = nil
        scan.dueAt = CatalogueScan.nextDue(afterStart: startedAt, sourceID: sourceID)
        try await scan.save(on: db)
        return read
    }

    /// Stores a scan in progress so the next turn, on any instance, carries on from it.
    private func keep(
        _ scan: CatalogueScanModel,
        seen: Set<UInt32>,
        reading: CatalogueSale.Reading,
        read: Int
    ) async throws -> Int {
        scan.seen = ScanDigests.encode(seen)
        scan.priced = reading.priced
        scan.markedDown = reading.markedDown
        scan.deepest = reading.deepest
        try await scan.save(on: app.db)
        return read
    }

    /// Writes one page of the catalogue.
    ///
    /// - Parameter horizon: products the poll has not stored are inserted only when published
    ///   before this, and never when it is nil.
    /// - Parameter reading: the sale reading, counted over what can be bought — see
    ///   `CatalogueSale.startShare` for why sold-out stock is left out of the scan's share.
    private func mergeScanPage(
        _ items: [FetchedItem],
        brandID: UUID,
        sourceID: UUID,
        storefrontID: UUID?,
        isBaseline: Bool,
        insertsBefore horizon: Date?,
        reading: inout CatalogueSale.Reading
    ) async throws {
        guard !items.isEmpty else { return }
        let db = app.db
        let existing = try await ProductModel.query(on: db)
            .filter(\.$source.$id == sourceID)
            .filter(\.$externalID ~~ items.map(\.externalID))
            .with(\.$variants)
            .all()
        var byExternalID = Dictionary(existing.map { ($0.externalID, $0) }, uniquingKeysWith: { a, _ in a })

        for item in items {
            let product = byExternalID[item.externalID]
            if item.isAvailable != false {
                // Counted before `refresh` overwrites the stored price, which is the
                // "previous" half of a cut — as the poll counts it.
                reading.count(now: item.priceAmount, original: item.originalPriceAmount, previous: product?.priceAmount)
            }
            if let product {
                // The poll's own rules, and nothing else: a size back, a markdown past 5%.
                _ = try await refresh(product, with: item, brandID: brandID, isBaseline: isBaseline, marksSeen: false)
                continue
            }
            guard let horizon, item.publishedAt < horizon else { continue }
            // Old stock the poll's window never reached: stored, never announced.
            let stored = ProductModel(brandID: brandID, sourceID: sourceID, storefrontID: storefrontID, item: item)
            try await stored.save(on: db)
            byExternalID[item.externalID] = stored
            guard let productID = stored.id, !item.variants.isEmpty else { continue }
            // One statement for the run rather than one per size: a first scan inserts the
            // whole back catalogue.
            try await item.variants.map { VariantModel(productID: productID, info: $0) }.create(on: db)
        }
    }

    /// Marks what a complete scan did not find: missing the first time, unlisted the second.
    ///
    /// **Two complete scans in a row, never one.** `/products.json` is paged by number, and a
    /// product removed while the scan is reading shifts every later row up by one, so the row
    /// at the top of the next page is skipped without having gone anywhere. A product first
    /// stored after this scan began cannot have been in it. Only an unlisting is acted on, and
    /// only by retention, six months later — nothing is deleted here.
    ///
    /// **A scan that finds most of a shop gone is not believed.** A catalogue that stopped
    /// answering past some page, a storefront pagination limit, a theme change that empties
    /// the listing: each reads as "everything after page n was removed". Over half (and more
    /// than `removalFloor`) missing at once marks nothing and is logged; a shop that really did
    /// delist most of its stock is unlisted by the scans after it, which see the same.
    private func unlist(sourceID: UUID, seen: Set<UInt32>, scanStartedAt: Date, now: Date) async throws {
        let db = app.db
        let listed = try await ProductModel.query(on: db)
            .filter(\.$source.$id == sourceID)
            .filter(\.$unlistedAt == nil)
            .field(\.$id)
            .field(\.$externalID)
            .field(\.$missingSince)
            .field(\.$firstSeenAt)
            .all()
        let missing = listed.filter { product in
            !seen.contains(ScanDigests.digest(product.externalID))
                && (product.firstSeenAt ?? .distantPast) < scanStartedAt
        }
        guard !missing.isEmpty else { return }

        let ceiling = max(CatalogueScan.removalFloor, Int(Double(listed.count) * CatalogueScan.removalCeiling))
        guard missing.count <= ceiling else {
            app.logger.warning("scan: \(missing.count) of \(listed.count) products missing from one scan of source \(sourceID); not believed")
            return
        }

        let once = missing.filter { $0.missingSince == nil }.compactMap(\.id)
        let twice = missing.filter { $0.missingSince != nil }.compactMap(\.id)
        for chunk in stride(from: 0, to: once.count, by: 500).map({ Array(once[$0..<min($0 + 500, once.count)]) }) {
            try await ProductModel.query(on: db).filter(\.$id ~~ chunk).set(\.$missingSince, to: now).update()
        }
        for chunk in stride(from: 0, to: twice.count, by: 500).map({ Array(twice[$0..<min($0 + 500, twice.count)]) }) {
            try await ProductModel.query(on: db).filter(\.$id ~~ chunk).set(\.$unlistedAt, to: now).update()
        }
    }

    /// The scan's half of `CatalogueSale`: records the catalogue's share, and may start a sale.
    private func settleCatalogueSale(
        _ reading: CatalogueSale.Reading,
        brandID: UUID,
        isBaseline: Bool,
        now: Date
    ) async throws {
        let db = app.db
        guard let brand = try await BrandModel.find(brandID, on: db) else { return }
        let state = CatalogueSale.State(
            measuredAt: brand.saleMeasuredAt,
            since: brand.saleSince,
            catalogueShare: brand.catalogueShare,
            catalogueMeasuredAt: brand.catalogueMeasuredAt
        )
        let next: CatalogueSale.State
        let started: Bool
        switch CatalogueSale.decideScan(reading, state: state, isBaseline: isBaseline, now: now) {
        case .unchanged: return
        case .record(let recorded): (next, started) = (recorded, false)
        case .started(let recorded): (next, started) = (recorded, true)
        }
        if brand.saleSince != next.since { brand.saleSince = next.since }
        brand.catalogueShare = next.catalogueShare
        brand.catalogueMeasuredAt = next.catalogueMeasuredAt
        try await brand.save(on: db)
        guard started else { return }
        let said = CatalogueSale.announcement(for: reading)
        _ = try await SaleEvents.announce(on: db, brandID: brandID, title: said.title, summary: said.summary, now: now)
    }
}

/// Runs the scanner on its own interval, beside `PollLoop` rather than inside it — a pass of
/// the scan is pages of a catalogue at the politeness interval, and in the poll's loop it
/// would hold up every poll and every push behind it.
actor ScanLoop {
    private let poller: Poller
    private let interval: Duration
    private var task: Task<Void, Never>?

    init(poller: Poller, interval: Duration = .seconds(60)) {
        self.poller = poller
        self.interval = interval
    }

    func start() {
        guard task == nil else { return }
        task = Task { [poller, interval] in
            while !Task.isCancelled {
                await poller.scanTick()
                try? await Task.sleep(for: interval)
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }
}

// SyncEngine.swift
// Fetches every brand's sources and folds the results into the store.
//
// Networking happens off the main actor and returns value types (`FetchResult`);
// only the merge step touches SwiftData, on the main actor. That keeps model objects
// from crossing actor boundaries without the ceremony of a full @ModelActor.

import Foundation
import StreetwCore
import SwiftData

@MainActor
@Observable
final class SyncEngine {
    private(set) var isSyncing = false
    private(set) var lastSyncedAt: Date?
    private(set) var lastError: String?
    private(set) var progress: String?

    /// Number of updates surfaced by the most recent sync, for the feed header.
    private(set) var newItemCount = 0

    /// Keep at most this many updates per brand; older ones are pruned unless saved.
    static let retentionPerBrand = 400

    private let context: ModelContext

    init(context: ModelContext) {
        self.context = context
    }

    func syncAll() async {
        let brands = (try? context.fetch(FetchDescriptor<Brand>())) ?? []
        await sync(brands: brands.filter(\.followed))
    }

    func sync(brands: [Brand]) async {
        guard !isSyncing, !brands.isEmpty else { return }
        isSyncing = true
        lastError = nil
        newItemCount = 0
        defer {
            isSyncing = false
            progress = nil
            lastSyncedAt = Date()
        }

        for brand in brands {
            progress = brand.name
            await sync(brand: brand)
        }

        prune(brands)
        try? context.save()

        // After the save, so a watch that fires sees committed variant data — and after
        // pruning, so it can't fire on a product that is about to be dropped.
        await WatchNotifier.run(in: context)
    }

    func sync(brand: Brand) async {
        let due = brand.sources.filter { $0.enabled && $0.kind.isAutomatic && $0.isReadyToCheck }
        guard !due.isEmpty else { return }

        let since = brand.lastSyncedAt

        // Fetch every source concurrently. These are independent network calls that
        // were previously run strictly one after another.
        let outcomes: [(BrandSource, Result<FetchResult, any Error>)] = await withTaskGroup(
            of: (BrandSource, Result<FetchResult, any Error>).self
        ) { group in
            for source in due {
                guard let adapter = SourceAdapters.adapter(for: source.kind) else { continue }
                group.addTask {
                    do {
                        return (source, .success(try await adapter.fetch(source, since: since)))
                    } catch {
                        return (source, .failure(error))
                    }
                }
            }
            var collected: [(BrandSource, Result<FetchResult, any Error>)] = []
            for await outcome in group { collected.append(outcome) }
            return collected
        }

        apply(outcomes, to: brand)

        // Only a sync that actually reached something counts. `lastSyncedAt` is both the
        // incremental cursor *and* the "have we baselined this brand" flag, so stamping
        // it after a total failure spends the baseline on a sync that stored nothing —
        // and the first batch that does arrive is then announced as a back catalogue of
        // new drops. The server had exactly this bug; this is the same rule.
        let reachedSomething = outcomes.contains { if case .success = $0.1 { true } else { false } }
        if reachedSomething { brand.lastSyncedAt = Date() }

        // The same repair the server's `Poller.fillMemberships` makes, for the mode where
        // the phone is the poller. `/collections.json` is filtered by `since`, so a
        // collection is offered to the merge exactly once in its life — without this, the
        // membership reaches only collections published from here on and every release
        // already on the feed keeps falling back to the word match.
        if since != nil, reachedSomething { await fillMemberships(brand) }
    }

    /// How many stored collections one sync goes back for, and how far back it looks. Small
    /// because it converges — a brand with three unfilled releases is done in one sync, and
    /// a release old enough to have aged out of the feed is not worth a request.
    private static let membershipBackfill = 3
    private static let membershipBackfillDays = 45.0

    /// Reads the real contents of collections stored before that was possible.
    private func fillMemberships(_ brand: Brand) async {
        guard let store = brand.sources.first(where: { $0.kind == .collections })?.url else { return }
        let cutoff = Date().addingTimeInterval(-Self.membershipBackfillDays * 86_400)
        let stale = brand.updates
            .filter { $0.kind == .collection && $0.memberExternalIDs.isEmpty && $0.publishedAt >= cutoff }
            .sorted(by: BrandUpdate.newestFirst)
            .prefix(Self.membershipBackfill)

        for collection in stale {
            // The handle is the last segment of the link the adapter built —
            // `/collections/<handle>` — and is the only place it survives.
            guard let handle = collection.linkURL?.lastPathComponent,
                  !handle.isEmpty, handle != "collections"
            else { continue }
            guard let membership = try? await CollectionsSource.membership(of: handle, in: store),
                  !membership.externalIDs.isEmpty
            else { continue }
            collection.memberExternalIDs = membership.externalIDs
        }
    }

    // MARK: - Applying results

    private func apply(_ outcomes: [(BrandSource, Result<FetchResult, any Error>)], to brand: Brand) {
        var updated = Dictionary(brand.sources.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var sawLock = false
        let isFirstSync = brand.lastSyncedAt == nil

        for (source, outcome) in outcomes {
            var source = source
            source.lastCheckedAt = Date()

            switch outcome {
            case .success(let result):
                source.lastError = nil
                source.failureCount = 0
                if let etag = result.etag { source.etag = etag }
                if let fingerprint = result.fingerprint { source.fingerprint = fingerprint }
                if result.isLocked { sawLock = true }

                // A 304 means "unchanged", which is different from "returned nothing" —
                // merging its empty item list would be harmless but pointless.
                if !result.notModified {
                    merge(result.items, into: brand, isFirstSync: isFirstSync)
                }
                if let currency = result.shopCurrency { brand.currencyCode = currency }
                if let name = result.shopName, brand.usesGeneratedName {
                    brand.name = name
                    brand.usesGeneratedName = false
                }

            case .failure(let error):
                source.failureCount += 1
                source.lastError = error.localizedDescription
                lastError = "\(brand.name): \(error.localizedDescription)"
            }

            updated[source.id] = source
        }

        // Codable-array properties need a whole-array assignment to persist.
        brand.sources = brand.sources.compactMap { updated[$0.id] }
        brand.isLockedForDrop = sawLock
    }

    private func merge(_ items: [FetchedItem], into brand: Brand, isFirstSync: Bool) {
        guard !items.isEmpty else { return }

        let existing = Dictionary(
            brand.updates.map { ($0.externalID, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        for item in items {
            if let match = existing[item.externalID] {
                refresh(match, with: item)
            } else {
                // What, if anything, a first sighting is worth saying. Nil is a product
                // being put back on the shelf with nothing buyable in it — stored, so a
                // watch can be set and a real restock still fires, but never announced.
                // See `Reshelving`.
                let news = Reshelving.firstSighting(of: item)
                // A brand added today shouldn't dump its entire back catalogue into the
                // feed as "new" — the first sync is a baseline.
                insert(item, into: brand, as: news, markSeen: isFirstSync || news == nil)
            }
        }
    }

    private func insert(_ item: FetchedItem, into brand: Brand, as kind: UpdateKind?, markSeen: Bool) {
        let update = BrandUpdate(
            externalID: item.externalID,
            brand: brand,
            title: item.title,
            summary: item.summary,
            linkURL: item.linkURL,
            imageURLStrings: item.imageURLStrings,
            publishedAt: item.publishedAt,
            kind: kind ?? item.kind,
            priceText: item.priceText,
            priceAmount: item.priceAmount,
            isAvailable: item.isAvailable,
            tags: item.tags,
            productType: item.productType,
            variants: item.variants
        )
        update.releaseDate = item.releaseDate
        // What the storefront says is in this collection, when it said anything. Empty for
        // every other kind — see `BrandUpdate.memberExternalIDs`.
        update.memberExternalIDs = item.memberExternalIDs
        // Classified at write time rather than on every read: it is pure text work over
        // fields that never change after insert, and the feed re-evaluates its filter on
        // every render pass.
        update.refreshGender()
        // Same argument, for whether the row is clothing at all — a gift card and a size
        // chart arrive through this function like everything else. See
        // `BrandUpdate.isMerchandise`.
        update.refreshMerchandise()
        update.isSeen = markSeen
        context.insert(update)
        // See `Brand.lastActivityAt`: the feed's sort order, stored so it never has to be
        // recomputed by walking every update the brand has.
        update.brand?.noteActivity(item.publishedAt)
        if !markSeen { newItemCount += 1 }
    }

    /// An item we've seen before. The one thing worth surfacing again is a restock:
    /// sold out last time, buyable now. Comparing per variant means we can say
    /// *which sizes* came back rather than just "something did".
    private func refresh(_ update: BrandUpdate, with item: FetchedItem) {
        let previous = Dictionary(
            update.variants.map { ($0.id, $0.available) },
            uniquingKeysWith: { first, _ in first }
        )
        let returned = item.variants
            .filter { $0.available && previous[$0.id] == false }
            .map(\.title)

        // Fall back to whole-product availability for sources without variants.
        let wholeProductReturned = update.variants.isEmpty
            && update.isAvailable == false
            && item.isAvailable == true

        // A markdown on something already in the catalogue. Checked before the restock
        // branch overwrites `kind`, but ranked below it: a thing coming *back* matters
        // more than the same thing getting cheaper, so a restock wins when both happen.
        let dropped = PriceChange.isDrop(from: update.priceAmount, to: item.priceAmount)

        // A restock and a markdown are events, so they move the brand's activity date the
        // same way a new product does — see `Brand.lastActivityAt`. They are written by
        // *rewriting* an existing row rather than inserting one, which is why this needs
        // saying twice: the insert path stamps it and this one would otherwise not, so a
        // brand whose only news was a restock kept the date of its last new product and
        // sorted below brands that had done nothing since. In server mode the question
        // does not arise — every event is its own row there, and `merge` inserts it.
        if !returned.isEmpty || wholeProductReturned {
            update.kind = .restock
            update.restockedSizes = returned
            update.publishedAt = Date()
            update.brand?.noteActivity(update.publishedAt)
            update.isSeen = false
            newItemCount += 1
        } else if dropped {
            update.kind = .priceDrop
            update.previousPriceText = update.priceText
            // The number as well as the string. `previousPriceText` can say "was €180";
            // only this can say which of two markdowns is the better one, which is what
            // the markdowns list is ordered by.
            update.previousPriceAmount = update.priceAmount
            update.publishedAt = Date()
            update.brand?.noteActivity(update.publishedAt)
            update.isSeen = false
            // A second cut is a new markdown, so a dismissal of the first one is spent.
            // This path *rewrites* the row rather than inserting one — in server mode every
            // event is its own row and the question never arises — so without this, waving
            // off a 10% cut in March would silently swallow the 40% cut in June.
            update.markdownDismissedAt = nil
            newItemCount += 1
        }

        update.variants = item.variants
        update.isAvailable = item.isAvailable
        update.priceAmount = item.priceAmount
        update.priceText = item.priceText
        if update.imageURLStrings.isEmpty { update.imageURLStrings = item.imageURLStrings }
        if update.tags.isEmpty { update.tags = item.tags }
        // A collection stored before the membership was read has none, and nothing else
        // would ever revisit it — the same reason `RemoteSync.backfill` exists. Filled only
        // when empty: a storefront that later stops answering must not blank a list we hold.
        if update.memberExternalIDs.isEmpty, !item.memberExternalIDs.isEmpty {
            update.memberExternalIDs = item.memberExternalIDs
        }
        // A name can arrive late: a sitemap row stored before the adapter learned to read
        // the image extension holds a randomised handle where the product name should be.
        // Only ever an upgrade — a real title is never replaced by a hash.
        if SitemapSource.isProvisional(update.title), !SitemapSource.isProvisional(item.title) {
            update.title = item.title
        }
        // Re-derived whenever the stored answer came from an older revision of the
        // classifier, which also covers rows written before it existed at all. Without
        // this an improvement to the rules would only ever reach products discovered
        // after the update.
        if update.genderVersion != GenderClassifier.version { update.refreshGender() }
    }

    // MARK: - Retention

    /// Catalogs are large and mostly static; two brands alone produced 530 rows on a
    /// first sync. Keep the newest slice per brand, and never drop anything saved or
    /// still unread.
    private func prune(_ brands: [Brand]) {
        for brand in brands where brand.updates.count > Self.retentionPerBrand {
            let expendable = brand.updates
                .filter { $0.saves.isEmpty && $0.isSeen }
                .sorted(by: BrandUpdate.newestFirst)
                .dropFirst(Self.retentionPerBrand)

            for update in expendable {
                context.delete(update)
            }
        }
    }
}

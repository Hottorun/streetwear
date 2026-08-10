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
                // A brand added today shouldn't dump its entire back catalogue into the
                // feed as "new" — the first sync is a baseline.
                insert(item, into: brand, markSeen: isFirstSync)
            }
        }
    }

    private func insert(_ item: FetchedItem, into brand: Brand, markSeen: Bool) {
        let update = BrandUpdate(
            externalID: item.externalID,
            brand: brand,
            title: item.title,
            summary: item.summary,
            linkURL: item.linkURL,
            imageURLStrings: item.imageURLStrings,
            publishedAt: item.publishedAt,
            kind: item.kind,
            priceText: item.priceText,
            isAvailable: item.isAvailable,
            tags: item.tags,
            productType: item.productType,
            variants: item.variants
        )
        update.isSeen = markSeen
        context.insert(update)
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

        if !returned.isEmpty || wholeProductReturned {
            update.kind = .restock
            update.restockedSizes = returned
            update.publishedAt = Date()
            update.isSeen = false
            newItemCount += 1
        }

        update.variants = item.variants
        update.isAvailable = item.isAvailable
        update.priceText = item.priceText
        if update.imageURLStrings.isEmpty { update.imageURLStrings = item.imageURLStrings }
        if update.tags.isEmpty { update.tags = item.tags }
    }

    // MARK: - Retention

    /// Catalogs are large and mostly static; two brands alone produced 530 rows on a
    /// first sync. Keep the newest slice per brand, and never drop anything saved or
    /// still unread.
    private func prune(_ brands: [Brand]) {
        for brand in brands where brand.updates.count > Self.retentionPerBrand {
            let expendable = brand.updates
                .filter { $0.saves.isEmpty && $0.isSeen }
                .sorted { $0.publishedAt > $1.publishedAt }
                .dropFirst(Self.retentionPerBrand)

            for update in expendable {
                context.delete(update)
            }
        }
    }
}

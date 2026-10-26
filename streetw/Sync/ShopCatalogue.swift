// ShopCatalogue.swift
// The products Shop searches: everything from the shops you follow that is on this phone.
//
// That sentence is the whole scope, and the screen prints it. Until Phase 3 stores whole
// catalogues on the server, "your shops" means the newest few hundred products per shop that
// the app keeps (`SyncEngine.retentionPerBrand`) — and in server mode only what arrived as
// news. Saying "in your shops" while searching that is honest; saying "search" alone would
// not be.
//
// Three things about how it is read, each the lesson of a screen in `docs/performance.md`.
//
// - **Asked once, not subscribed to.** A `@Query` over `BrandUpdate` would hold the view on the
//   whole table and rebuild it on every poll. This is one bounded fetch, re-asked only when a
//   cheap stamp — how many rows, the newest one, how many shops, the gender filter — moves.
// - **The models are read once each, and everything after that is values.** The fetch is
//   decorated into `ShopListing`s on the main actor, a property read per field per row; the
//   classifying and tokenising happen in a detached task over those values, and the search
//   that runs per keystroke never touches SwiftData.
// - **No predicate over an array attribute.** "Has a photograph" is checked in Swift, for the
//   reason `FitCandidates` writes down: `#Predicate { !$0.imageURLStrings.isEmpty }` is not a
//   narrowing, it is a crash.

import Foundation
import Observation
import StreetwCore
import SwiftData

@MainActor
@Observable
final class ShopCatalogue {
    enum Phase: Equatable {
        /// Never read.
        case unread
        /// Reading, for the first time — later refreshes keep the old index on screen.
        case reading
        case ready
    }

    private(set) var phase: Phase = .unread
    private(set) var index = ShopIndex([])
    /// How many shops are followed, and how many of their products the gender filter shows —
    /// the line that says what is being searched.
    private(set) var shops = 0
    private(set) var shown = 0
    /// The fetch hit its bound, so the scope line has to say "the newest".
    private(set) var isCapped = false
    /// Bumped on every rebuild, so whatever is derived from the index can key on it.
    private(set) var version = 0

    /// What the store looked like when the index was built.
    private struct Stamp: Equatable {
        var rows: Int
        var newest: Date?
        var shops: Int
        var gender: GenderPreference
    }

    @ObservationIgnored private var stamp: Stamp?
    @ObservationIgnored private var rows: [String: BrandUpdate] = [:]
    @ObservationIgnored private var fitsMemo: [String: Bool] = [:]
    @ObservationIgnored private var fitsProfile: SizeProfile?

    /// The most rows read. Generous — a dozen shops at their retention cap — and a bound on
    /// memory rather than an expected size; reaching it is said on screen.
    static let window = 12_000

    /// The kinds that are a garment somebody could buy. A sale, a collection, a page change
    /// and a lock are news about a shop, not products.
    private static let kinds: Set<UpdateKind> = [.product, .restock, .priceDrop]

    /// The row behind a listing, or nil once it has gone — a prune deletes rows, and reading
    /// any property of a deleted model traps (see `Fit.isGone`).
    func row(_ id: String) -> BrandUpdate? {
        guard let update = rows[id], !update.isDeleted, update.modelContext != nil else { return nil }
        return update
    }

    /// Re-reads the store if it has changed since the index was built.
    func refreshIfNeeded(in context: ModelContext, profile: SizeProfile) async {
        let current = Self.stamp(in: context, gender: profile.gender)
        guard current != stamp else { return }
        if phase == .unread { phase = .reading }

        var descriptor = FetchDescriptor<BrandUpdate>(
            predicate: #Predicate { $0.brand?.followed == true },
            sortBy: [SortDescriptor(\.publishedAt, order: .reverse)]
        )
        descriptor.fetchLimit = Self.window
        descriptor.relationshipKeyPathsForPrefetching = [\.brand]
        let fetched = (try? context.fetch(descriptor)) ?? []

        // One row per garment, the newest event standing for it — a restock this morning
        // describes the jacket better than the drop that announced it in March.
        let products = BrandUpdate.oncePerProduct(fetched.filter { Self.kinds.contains($0.kind) && $0.hasPhotograph })

        var copies: [CatalogueRow] = []
        copies.reserveCapacity(products.count)
        var found: [String: BrandUpdate] = [:]
        found.reserveCapacity(products.count)
        for (position, update) in products.enumerated() {
            // The read yields every few hundred rows so a large store does not hold the main
            // actor for the whole walk — and a yield is a point where a sync may have deleted
            // what is next, so every row is checked before it is read.
            if position % 400 == 399 {
                await Task.yield()
                // A newer read has been asked for — a sync landed mid-walk — and will do this
                // properly; finishing this one would only be overwritten.
                guard !Task.isCancelled else { return }
            }
            guard !update.isDeleted, update.modelContext != nil, let brand = update.brand else { continue }
            let copy = CatalogueRow(update: update, brand: brand, profile: profile)
            copies.append(copy)
            found[copy.id] = update
        }

        let built = await Task.detached(priority: .userInitiated) {
            ShopIndex(copies.map(\.listing))
        }.value
        guard !Task.isCancelled else { return }

        rows = found
        index = built
        shops = current.shops
        shown = copies.count { $0.isShown }
        isCapped = fetched.count >= Self.window
        fitsMemo = [:]
        stamp = current
        version += 1
        phase = .ready
    }

    /// Whether a listing is buyable in a size the reader told us they wear.
    ///
    /// `claims`, never `matches` — "in my size" is a statement about the reader, and the
    /// filter's optimism would answer it yes for every size it cannot read. Remembered per
    /// listing, because the size context costs a classifier run and the same listings are
    /// asked about on every keystroke.
    func fits(_ listing: ShopListing, profile: SizeProfile) -> Bool {
        if fitsProfile != profile {
            fitsMemo = [:]
            fitsProfile = profile
        }
        if let known = fitsMemo[listing.id] { return known }
        let answer = row(listing.id)?.isInMySize(profile) ?? false
        fitsMemo[listing.id] = answer
        return answer
    }

    private static func stamp(in context: ModelContext, gender: GenderPreference) -> Stamp {
        var newest = FetchDescriptor<BrandUpdate>(sortBy: [SortDescriptor(\.discoveredAt, order: .reverse)])
        newest.fetchLimit = 1
        return Stamp(
            rows: (try? context.fetchCount(FetchDescriptor<BrandUpdate>())) ?? 0,
            newest: (try? context.fetch(newest))?.first?.discoveredAt,
            shops: (try? context.fetchCount(FetchDescriptor<Brand>(predicate: #Predicate { $0.followed }))) ?? 0,
            gender: gender
        )
    }
}

/// One row's fields, copied out of SwiftData so the expensive part — classifying and
/// tokenising — can run off the main actor. `nonisolated` because this target is main-actor
/// by default, and being read off it is the point; only the initialiser, which reads the
/// model, is on the main actor.
private nonisolated struct CatalogueRow: Sendable {
    var id: String
    var brandKey: String
    var brandName: String
    var title: String
    var productType: String?
    var tags: [String]
    var colourways: [String]
    var measuredColours: [String]
    var visionCategories: [String]
    var price: Double?
    var publishedAt: Date
    var isAvailable: Bool
    var isShown: Bool

    @MainActor
    init(update: BrandUpdate, brand: Brand, profile: SizeProfile) {
        let variants = update.variants
        var colourways: [String] = []
        for variant in variants {
            guard let colour = variant.color, !colour.isEmpty, colour != "Default Title",
                  !colourways.contains(colour) else { continue }
            colourways.append(colour)
        }
        id = update.productExternalID ?? update.externalID
        brandKey = brand.id.uuidString
        brandName = brand.name
        title = update.title
        productType = update.productType
        tags = update.tags
        self.colourways = colourways
        measuredColours = [update.visionColor, update.visionSecondaryColor].compactMap { $0 }
        visionCategories = update.visionCategories
        price = update.priceAmount
        publishedAt = update.publishedAt
        isAvailable = variants.isEmpty ? (update.isAvailable ?? true) : variants.contains(where: \.available)
        isShown = update.passes(profile)
    }

    /// Built where it is read, in the detached task: the listing runs the same slot
    /// classifier `BrandUpdate.garmentSlot` does.
    var listing: ShopListing {
        ShopListing(
            id: id,
            brandKey: brandKey,
            brandName: brandName,
            title: title,
            productType: productType,
            tags: tags,
            colourways: colourways,
            measuredColours: measuredColours,
            visionCategories: visionCategories,
            price: price,
            publishedAt: publishedAt,
            isAvailable: isAvailable,
            isShown: isShown
        )
    }
}

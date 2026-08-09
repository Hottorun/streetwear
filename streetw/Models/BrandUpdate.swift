// BrandUpdate.swift
// Represents a new post/product/update from a brand
import Foundation
import StreetwCore
import SwiftData

@Model
final class BrandUpdate {
    /// Kept as a nested alias so existing call sites (`BrandUpdate.Kind`) keep reading
    /// naturally; the real definition lives in the portable `Sources/` layer.
    typealias Kind = UpdateKind

    var id: UUID = UUID()
    /// Stable identity from the source (e.g. "shopify:8286011326592"). Used to dedupe across syncs.
    var externalID: String = ""
    var brand: Brand?

    var title: String = ""
    var summary: String?
    var linkURL: URL?
    /// Stored as strings — SwiftData is happier with these than with `[URL]`.
    var imageURLStrings: [String] = []

    var publishedAt: Date = Date()
    var discoveredAt: Date = Date()
    var kind: Kind = Kind.product

    var priceText: String?
    var isAvailable: Bool?
    var tags: [String] = []
    var productType: String?

    /// Per-variant stock, so a restock can name the sizes that came back.
    var variants: [VariantInfo] = []

    /// Sizes that returned to stock on the sync that flagged this as a restock.
    var restockedSizes: [String] = []

    var isSeen: Bool = false

    /// Inverse of `SavedItem.update`, so a card can check its saved state directly
    /// instead of running a per-card query.
    @Relationship(deleteRule: .cascade, inverse: \SavedItem.update)
    var saves: [SavedItem] = []

    /// There is at most one save per update; `setSave` updates rather than duplicates.
    var save: SavedItem? { saves.first }

    init(
        externalID: String,
        brand: Brand?,
        title: String,
        summary: String? = nil,
        linkURL: URL? = nil,
        imageURLStrings: [String] = [],
        publishedAt: Date = Date(),
        kind: Kind,
        priceText: String? = nil,
        isAvailable: Bool? = nil,
        tags: [String] = [],
        productType: String? = nil,
        variants: [VariantInfo] = []
    ) {
        self.id = UUID()
        self.externalID = externalID
        self.brand = brand
        self.title = title
        self.summary = summary
        self.linkURL = linkURL
        self.imageURLStrings = imageURLStrings
        self.publishedAt = publishedAt
        self.discoveredAt = Date()
        self.kind = kind
        self.priceText = priceText
        self.isAvailable = isAvailable
        self.tags = tags
        self.productType = productType
        self.variants = variants
    }

    /// Sizes currently buyable, for the card subtitle. Empty for one-size products.
    var availableSizes: [String] {
        variants.filter { $0.available && $0.isMeaningfulSize }.map(\.displaySize)
    }

    /// Buyable right now *and* in a size the user wears.
    func availableSizes(matching profile: SizeProfile) -> [String] {
        variants
            .filter { $0.available && profile.matches($0) }
            .map(\.displaySize)
    }

    /// Products with no variant data (feed posts, page changes) always pass — the
    /// filter should never hide something just because we don't know its sizing.
    func isAvailable(in profile: SizeProfile) -> Bool {
        guard !variants.isEmpty else { return true }
        return variants.contains { $0.available && profile.matches($0) }
    }

    /// Sizes from this restock that the user actually wears.
    func restockedSizes(matching profile: SizeProfile) -> [String] {
        restockedSizes.filter { profile.matches($0) }
    }

    var imageURLs: [URL] {
        imageURLStrings.compactMap(URL.init(string:))
    }

    var primaryImageURL: URL? { imageURLs.first }
}

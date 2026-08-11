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
    /// The numeric price, kept so a markdown can be *detected*. `priceText` is formatted
    /// for display and two different strings tell you nothing about direction.
    var priceAmount: Double?
    /// A start time the source explicitly announced. Nil is the normal case — most
    /// storefronts never publish a machine-readable release time.
    var releaseDate: Date?
    /// What it cost before the most recent drop, so a card can say "was €180".
    var previousPriceText: String?
    var isAvailable: Bool?
    var tags: [String] = []
    var productType: String?

    /// Per-variant stock, so a restock can name the sizes that came back.
    var variants: [VariantInfo] = []

    /// Sizes that returned to stock on the sync that flagged this as a restock.
    var restockedSizes: [String] = []

    var isSeen: Bool = false

    /// Dominant colour read off the photograph rather than out of the title — a brand
    /// calling a shoe "Triple White" is naming a colourway, not a colour.
    var visionColor: String?
    /// Wardrobe categories from Vision's on-device classifier.
    var visionCategories: [String] = []
    /// Width ÷ height of the primary image, measured when it was analysed. Lets the
    /// collection wall lay tiles out at the shape of the actual photograph instead of
    /// guessing.
    var imageAspect: Double?
    /// When the image was last analysed. Nil means "not yet"; set even when analysis
    /// fails, so a dead image URL isn't retried on every launch forever.
    var analyzedAt: Date?

    /// Set by the server, which matched this item against the device's size profile.
    /// Server-mode items carry no variants, so the local check can't answer this.
    var serverSaysInMySize: Bool = false

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
        priceAmount: Double? = nil,
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
        self.priceAmount = priceAmount
        self.isAvailable = isAvailable
        self.tags = tags
        self.productType = productType
        self.variants = variants
    }

    /// Sizes currently buyable, for the card subtitle. Empty for one-size products.
    var availableSizes: [String] {
        variants.filter { $0.available && $0.isMeaningfulSize }.map(\.displaySize)
    }

    /// True when something is buyable in the user's sizes. Uses local variant data when
    /// present, and otherwise trusts the server's answer.
    func isInMySize(_ profile: SizeProfile) -> Bool {
        guard !profile.isEmpty else { return false }
        if variants.isEmpty { return serverSaysInMySize }
        return !availableSizes(matching: profile).isEmpty
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

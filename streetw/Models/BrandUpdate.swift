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
    /// Filename of the subject lifted off this item's photograph, in `Cutout.directory`.
    ///
    /// A name rather than the bytes: a cutout is a few hundred KB of RGBA and there is one
    /// per saved item, which is not a thing to keep in a row that gets faulted in to draw a
    /// feed. Nil is normal and permanent for anything with no single subject to lift — a
    /// flat-lay, a lookbook shot, a size chart — and the canvas falls back to the original.
    var cutoutFile: String?

    /// Which revision of `Cutout` last looked at this photograph.
    ///
    /// `analyzedAt` cannot answer for the cutout, because a row analysed before cutouts
    /// existed is stamped and would never be revisited — so the whole collection stays
    /// sticker-less and the canvas is a mood board forever. This is the `genderVersion`
    /// pattern: a row written by an older build decodes as 0, is therefore stale, and gets
    /// one more look. Stamped even when nothing was lifted, so an item with no single
    /// subject isn't re-cut on every launch.
    var cutoutVersion: Int = 0

    /// True when this photograph has never been offered to the current lift.
    var needsCutout: Bool { cutoutVersion != Cutout.version }

    /// Which revision of the share importer last tried to find this in a catalogue.
    ///
    /// A link shared from Safari is enriched once, on the next foreground, and if that
    /// fails the row keeps whatever Open Graph gave it — a title, one photograph, no
    /// price history, no size run, no stock, and therefore no watch. Forever: the inbox
    /// file is deleted on import and nothing ever looks at that row again. Every reason a
    /// first attempt fails is temporary or fixable — a regional subdomain that serves no
    /// catalogue, a storefront that was slow that minute, a product further back in the
    /// listing than the importer pages while somebody waits, or simply an older build of
    /// this app.
    ///
    /// So it is the `cutoutVersion` pattern again, for the same reason and with the same
    /// discipline: a row written by an older build decodes 0 and gets one more look;
    /// stamping happens even when the attempt found nothing, so a genuinely un-catalogued
    /// link is not re-fetched on every launch for the rest of its life. Bump the version
    /// whenever enrichment learns something new.
    var enrichmentVersion: Int = 0

    /// The sticker, when there is one. Read as a file each time rather than cached here:
    /// `UIImage(contentsOfFile:)` is lazily decoded and the canvas draws at most a dozen.
    var cutoutURL: URL? {
        cutoutFile.map { Cutout.url(for: $0) }
    }

    /// Set by the server, which matched this item against the device's size profile.
    /// Only consulted for items that genuinely carry no variants.
    var serverSaysInMySize: Bool = false

    /// Who the garment is cut for, as a raw string so a value added to `Gender` later
    /// can't fail to decode against a store written today.
    var genderRaw: String?

    /// Which revision of the classifier produced `genderRaw`.
    ///
    /// Gender is a heuristic over catalogue text, so it will keep improving — and a
    /// stored answer from an older revision is worse than no answer, because nothing
    /// would ever revisit it. A row written before this field existed decodes as 0 and is
    /// therefore always stale, which is exactly right.
    var genderVersion: Int = 0

    /// Never nil. An unclassifiable product is `.unknown`, which no filter hides.
    ///
    /// Falls back to classifying on the spot when the stored answer is missing or stale —
    /// which covers a row written by an older build, and a feed from a server that
    /// doesn't send a gender yet. Sync backfills the stored value, so the live path is
    /// transient rather than the steady state.
    var gender: Gender {
        if genderVersion == GenderClassifier.version, let genderRaw {
            return Gender(rawValue: genderRaw) ?? .unknown
        }
        return classifyGender()
    }

    /// Pure string work over fields this row already holds.
    func classifyGender() -> Gender {
        GenderClassifier.classify(
            title: title,
            productType: productType,
            tags: tags,
            handle: linkURL?.lastPathComponent
        )
    }

    /// Writes the current classifier's answer, so `gender` stops recomputing.
    func refreshGender() {
        genderRaw = classifyGender().rawValue
        genderVersion = GenderClassifier.version
    }

    /// Colourways this comes in, or empty when there is only one — which is most
    /// products, and why a single colour deliberately isn't a colourway.
    var colorways: [Colorway] { Colorways.from(variants) }

    /// Inverse of `SavedItem.update`, so a card can check its saved state directly
    /// instead of running a per-card query.
    @Relationship(deleteRule: .cascade, inverse: \SavedItem.update)
    var saves: [SavedItem] = []

    /// There is at most one save per update; `setSave` updates rather than duplicates.
    var save: SavedItem? { saves.first }

    /// Restock watches on this product. Several are legitimate — a person may want an M
    /// in black *or* an L in sand — so unlike saves this is genuinely a list.
    @Relationship(deleteRule: .cascade, inverse: \StockWatch.update)
    var watches: [StockWatch] = []

    var activeWatches: [StockWatch] { watches.filter(\.isActive) }

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

    /// Everything the feed filter asks of one item: is it in a size I wear, and is it cut
    /// for me. Kept together so the two halves can't drift apart between the feed, the
    /// brand page and anywhere else that filters.
    func passes(_ profile: SizeProfile) -> Bool {
        profile.allows(gender) && isAvailable(in: profile)
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

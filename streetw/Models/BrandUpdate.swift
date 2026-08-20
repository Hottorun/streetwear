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
    /// The old price as a number, so a cut can be *ranked* rather than only announced.
    ///
    /// The pair to `priceAmount`, and stored for exactly the reason that one is: two
    /// formatted strings say nothing about how big the difference between them is, and a
    /// list of markdowns is only worth having if the deepest one is at the top. Optional
    /// because rows written before this existed have no numeric history, and inferring one
    /// from a formatted string would mean parsing currency by hand.
    var previousPriceAmount: Double?
    var isAvailable: Bool?
    /// When the storefront was last asked what is actually left. Nil means never — see
    /// `StockRefresh`.
    var stockCheckedAt: Date?
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

    /// Which photograph those answers are about.
    ///
    /// `analyzedAt` alone says *that* something was looked at, never *what* — and a row's
    /// photograph can change after the fact. That is the ordinary path for a share, not an
    /// edge case: a link from Safari lands with whatever Open Graph gave it, which is often
    /// one marketing image and sometimes a URL that 404s. Either way the pass stamps the row
    /// — deliberately, so a dead URL is not retried forever — and then
    /// `SharedSaveImporter.repair` finds the product in the catalogue and fills in the real
    /// photographs. Nothing ever looked at them: the row was already stamped, the cutout and
    /// reading versions were already current, and the item sat in the collection with no
    /// colour, no cutout, no measured aspect and no silhouette for as long as it existed.
    ///
    /// So the stamp records the subject as well as the time, and a photograph the analysis
    /// has never seen makes every part of the pass due again. Nil on rows written before
    /// this existed, which reads as "unknown subject" and earns one more look — the same
    /// bargain the version fields make.
    var analyzedImageURL: String?

    /// True when the current lead photograph is not the one the analysis was run against.
    var hasUnreadPhotograph: Bool {
        guard let current = imageURLStrings.first else { return false }
        return analyzedImageURL != current
    }
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

    // MARK: - The deeper read of the photograph
    //
    // Everything below is measured by `VisualReading` in the same pass that already
    // decodes the picture for the colour and the cutout. Stored flat rather than as one
    // Codable struct **on purpose**: SwiftData decodes a stored `Codable` with an internal
    // `try!`, so a field added later is a crash on launch for anybody holding older data —
    // which is exactly what `BrandSource.failureCount` did on a real device. A new
    // property with a default is a lightweight migration and cannot fail that way.

    /// The second colour in the photograph, where there is a real one.
    ///
    /// Nil is the common and correct answer: most garments are one colour, and inventing
    /// an accent for them would put "Black · Grey" on every row in the collection. Only a
    /// runner-up holding a meaningful share of the garment's pixels earns this.
    var visionSecondaryColor: String?

    /// How much is going on in the picture, 0…1 — colour variety plus edge density inside
    /// the garment. A plain black hoodie sits near 0; an all-over print sits near 1.
    ///
    /// Deliberately *not* called "has a print": a four-panel colourblock jacket scores high
    /// and has no print on it at all. What this measures is visual noise, which is the
    /// property that actually matters for whether two pieces argue.
    var visionBusyness: Double = 0

    /// How much of the garment is covered in legible text, 0…1.
    ///
    /// The one axis in streetwear that title-parsing can never reach. A brand does not tag
    /// a product "logo-heavy" — but a chest wordmark is right there in the photograph, and
    /// on-device text recognition reads it reliably. Logo-heavy versus blank is most of
    /// what separates two wardrobes that a colour histogram would call identical.
    var visionTextCoverage: Double = 0

    /// The garment's shape, read off the cutout mask — "Boxy", "Slim", "Wide", "Long".
    ///
    /// Nil whenever there is no mask to measure, which is ordinary: Vision's subject lift
    /// does not run in the Simulator, `Seamless` declines on anything but a flat sweep, and
    /// a lookbook photograph has no single garment to outline. Never guessed from the
    /// bounding box alone — see `Silhouette`.
    var visionSilhouette: String?

    /// Mean lightness and colourfulness of the garment's own pixels, 0…1.
    ///
    /// Two numbers that cost nothing — they fall out of the histogram the colour vote
    /// already builds — and together they say the thing a list of colour names cannot:
    /// whether somebody dresses dark and muted or bright and loud. That is the axis that
    /// separates a Palace wardrobe from a Kith one while both read "mostly black".
    var visionLightness: Double = 0
    var visionSaturation: Double = 0

    /// Vision's perceptual fingerprint of the photograph.
    ///
    /// About two kilobytes, computed on device, with a distance function built in — so two
    /// garments can be compared on *how they look* rather than on which words they share.
    /// `SimilarItems` has only ever matched vocabulary, which cannot see that two jackets
    /// resemble each other and can be fooled by two unrelated things both tagged "cotton".
    var visionFeaturePrint: Data?

    /// Which revision of `VisualReading` produced the fields above.
    ///
    /// The `cutoutVersion` argument exactly: `analyzedAt` was stamped long before any of
    /// these existed, so gating on it would leave every established collection with none of
    /// them, forever. A row from an older build decodes 0, is stale, and gets one more look.
    /// Stamped even when a measurement finds nothing, so a photograph with no text on it is
    /// not re-read on every launch.
    var visionVersion: Int = 0

    /// True when this photograph has not been through the current deeper read.
    var needsVisualReading: Bool { visionVersion != VisualReading.version }

    /// The product this row is about, as the catalogue keys it — `shopify:<id>`.
    ///
    /// Distinct from `externalID`, which identifies the *event*. In server mode a feed row
    /// is `event:<uuid>` and one garment produces several over its life, so nothing could
    /// tell that a link shared from Safari and a card already in the feed were the same
    /// thing. Nil for an event with no product behind it, and for rows written before this
    /// existed — `RemoteSync.backfill` fills those in.
    var productExternalID: String?

    // MARK: - Who made it, when nobody is following them

    /// What the site this was shared from calls itself.
    ///
    /// A shared link belongs to a brand whether or not that brand is in the app. `brand` is
    /// only set when the link matches something already followed, so everything shared from
    /// a label somebody has not added — which is most of what a share is *for* — arrived
    /// anonymous: no wordmark on the wall, "Saved" for a page title, and nothing to tap
    /// through to. The app knew the host and refused to say it.
    ///
    /// The host is not the answer either. `gvgallery.com` is "GV Gallery" and
    /// `bbcicecream.com` is "Billionaire Boys Club", which is the same argument
    /// `SiteIdentity` makes for a followed brand — and the same fetch answers it, so this is
    /// read from `og:site_name` or the homepage `<title>` rather than invented from a
    /// domain. Nil until that has been tried; `SharedSaveImporter.identifySites` fills it in
    /// afterwards.
    var siteName: String?

    /// The mark that site publishes, so an unattributed save still gets a monogram.
    var siteLogoURLString: String?

    /// Which revision of the site probe last looked at this row's host. The `cutoutVersion`
    /// pattern once more: a row written before the probe existed reads 0 and earns one look,
    /// and the stamp lands even when the site said nothing, so a blog that publishes no name
    /// is not re-fetched on every foreground.
    var siteIdentityVersion: Int = 0

    var siteLogoURL: URL? { siteLogoURLString.flatMap(URL.init(string:)) }

    /// Who this is by, as far as anything knows. Never empty when there is a link.
    ///
    /// The followed brand first, because that is a fact rather than a reading; then what the
    /// site calls itself; then the domain, tidied. A card that says "GV GALLERY" over a
    /// shared hoodie is right even though nobody follows GV Gallery, and that name is what
    /// makes the brand line on a saved item something to tap.
    var brandLabel: String? {
        if let name = brand?.name, !name.isEmpty { return name }
        if let siteName, !siteName.isEmpty { return siteName }
        return linkURL?.host().flatMap(BrandNaming.hostName(of:))
    }

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

    /// Whether this item belongs in a browsing view at all.
    ///
    /// **The one filter, called from every screen that shows a list of a brand's output.**
    /// It had said so in this comment for a while and had no callers: the feed applied
    /// `profile.allows(gender)` inline instead, and `BrandFeedView` — which is where
    /// "+36 more from Kith" goes — applied nothing whatsoever. So somebody who had chosen
    /// Menswear got it on the feed and lost it the moment they opened the rest of the same
    /// drop, which reads as the setting not working rather than as one screen missing it.
    ///
    /// Gender hides; **size does not**. A size you don't wear is said in vermilion — or by
    /// its absence from the run — not by removing the product, because a sold-out size
    /// today is a restock tomorrow and that restock is the thing this app exists to catch.
    /// `isAvailable(in:)` is still here for anywhere that genuinely wants the stricter
    /// question.
    func passes(_ profile: SizeProfile) -> Bool {
        profile.allows(gender)
    }

    /// Newest first, and **totally ordered** — the comparator every list of a brand's
    /// output sorts by.
    ///
    /// The date alone is not an ordering. A storefront publishes a drop in one write and
    /// stamps the batch with the same second: Represent's 250 most recent products carry
    /// only 154 distinct timestamps, so nearly half of them are tied with something else,
    /// and a sitemap brand whose `lastmod` is date-only ties an entire day together.
    /// `sorted(by:)` is not a stable sort, and `brand.updates` is a to-many relationship
    /// whose array order is unspecified and free to differ between two reads — so sorting
    /// on `publishedAt` alone gave the tied items a *fresh arbitrary order on every render*.
    ///
    /// On screen that is the bug where marking one card read in "+36 more" briefly shows
    /// the wrong item next and then swaps back to the right one: the mutation re-renders
    /// the list, the ties reshuffle, and a later pass reshuffles them again. Nothing was
    /// wrong with the data and no amount of looking at the filter would have found it.
    ///
    /// `externalID` is the tiebreaker because it is the one field that is stable across
    /// relaunches, identical on the phone and the server, and unique per row — the same
    /// string dedupe already keys on.
    static func newestFirst(_ a: BrandUpdate, _ b: BrandUpdate) -> Bool {
        a.publishedAt == b.publishedAt
            ? a.externalID > b.externalID
            : a.publishedAt > b.publishedAt
    }

    /// One row per garment, newest first.
    ///
    /// **A list of a brand's output is a list of clothes, and the store holds events.** In
    /// server mode a feed row is keyed `event:<uuid>` and one garment produces several over
    /// its life — it drops, it is marked down, it comes back in an L — so a brand page, a
    /// release and a brand's spread in the feed could each print the same jacket three
    /// times, at three different prices, side by side. Nothing was wrong with any of the
    /// rows; there is simply no reason for a person to be shown the same product twice in
    /// one list.
    ///
    /// Keyed on `productExternalID`, which is the garment, never on `externalID`, which is
    /// the *event*. A row with no product behind it — a page change, a drop lock, a share
    /// that never found a catalogue record — keeps its own key and so is never folded into
    /// anything: two different links must never collapse into one because neither could name
    /// its product.
    ///
    /// The survivor is the newest by `newestFirst`, which is the same total ordering every
    /// list already sorts by — so the choice is stable across relaunches rather than
    /// whichever row the relationship happened to hand over first. Newest is also the right
    /// one on the merits: a restock this morning describes the garment better than the drop
    /// it announced in March.
    static func oncePerProduct(_ updates: [BrandUpdate]) -> [BrandUpdate] {
        var seen = Set<String>()
        return updates
            .sorted(by: newestFirst)
            .filter { seen.insert($0.productExternalID ?? $0.externalID).inserted }
    }

    /// How much was taken off, 0…1. Nil when there is nothing to compare against.
    var discountShare: Double? {
        guard let now = priceAmount, let was = previousPriceAmount, was > 0, now < was else {
            return nil
        }
        return (was - now) / was
    }

    /// Which part of an outfit this is, read off the catalogue text.
    ///
    /// The same classification `SavedItem.slot` performs, on the product rather than on the
    /// save — "more like this" has to answer for things nobody has kept.
    var garmentSlot: GarmentSlot {
        GarmentClassifier.classify(
            title: title,
            productType: productType,
            tags: tags,
            visionCategories: visionCategories
        )
    }

    /// The words that decide whether two products are alternatives to each other.
    ///
    /// Tags and product type, not the title — the same choice `BrandVector` makes and for
    /// the same reason: a product *name* ("Nocturne", "Wolfgang") is unique to one item, so
    /// matching on it finds nothing, while the words a merchandiser files it under are
    /// exactly the ones shared by the things it sits beside on the shelf.
    var matchTerms: [String] {
        let source = tags + [productType ?? ""]
        return source
            .flatMap { $0.lowercased().split { !$0.isLetter } }
            .map(String.init)
            .filter { $0.count > 2 }
    }

    /// Words from a collection's name worth searching a catalogue for.
    ///
    /// A season code ("FW26", "SS25") or a collaborator's name identifies a release; "the",
    /// "collection" and "new" identify nothing, and matching on them would put the whole
    /// catalogue inside every collection. Anything with a digit is kept whatever its
    /// length, because that is exactly the shape a season code takes.
    static func distinctiveWords(in title: String) -> [String] {
        let stop: Set<String> = [
            "the", "and", "new", "collection", "collections", "capsule", "drop", "release",
            "collab", "collaboration", "part", "vol", "volume", "edition", "series", "all",
            "shop", "our", "for", "with", "by", "of", "in", "a"
        ]
        return title
            .lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
            .filter { word in
                guard !stop.contains(word) else { return false }
                return word.contains(where: \.isNumber) || word.count >= 4
            }
    }

    /// Whether this product's own text carries one of those words.
    func mentionsAny(of words: [String]) -> Bool {
        guard !words.isEmpty else { return false }
        let haystack = ([title, productType ?? ""] + tags).joined(separator: " ").lowercased()
        return words.contains { haystack.contains($0) }
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

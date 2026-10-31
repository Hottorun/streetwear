// Models.swift
// Fluent models. The shape mirrors BACKEND.md: brands/sources/products/variants are
// GLOBAL — one row per real-world thing, shared by every user — while users, devices,
// follows and size profiles are personal. That is what lets one poll of Kith serve
// everybody who follows it.

import Fluent
import Foundation
import StreetwCore
import Vapor

final class BrandModel: Model, @unchecked Sendable {
    static let schema = "brands"

    @ID(key: .id) var id: UUID?
    @Field(key: "name") var name: String
    /// `name` as it is searched — `BrandNaming.searchKey`, kept current by `BrandSearchName`.
    /// Nil only on a row the column has not reached; see `BrandSearch`.
    @OptionalField(key: "search_name") var searchName: String?
    @Field(key: "slug") var slug: String
    @OptionalField(key: "website") var website: String?
    @OptionalField(key: "instagram_handle") var instagramHandle: String?
    @OptionalField(key: "currency") var currency: String?
    /// The icon the brand's own site publishes. Global like the rest of the catalog —
    /// one lookup serves every follower.
    @OptionalField(key: "logo_url") var logoURL: String?
    @Field(key: "locked_for_drop") var lockedForDrop: Bool
    /// True while `name` is still derived from the hostname, so the first successful
    /// poll may replace it with the storefront's real name.
    @Field(key: "uses_generated_name") var usesGeneratedName: Bool
    /// When this brand last interrupted anybody. The rate limit that turns a drop from a
    /// trickle of pushes into one alert and one follow-up — see `Notifier.cooldown`.
    @OptionalField(key: "last_notified_at") var lastNotifiedAt: Date?
    /// When this brand's prices were first measured for a sale, and when the sale now
    /// running started — `CatalogueSale.State`, written only on a transition.
    @OptionalField(key: "sale_measured_at") var saleMeasuredAt: Date?
    @OptionalField(key: "sale_since") var saleSince: Date?
    /// When the announcement bar is next due a read; nil until it has been read once, which
    /// makes that read a baseline. See `SaleBanners`.
    @OptionalField(key: "banner_check_at") var bannerCheckAt: Date?
    /// The offer last announced from the bar, and when it was last seen there —
    /// `SaleBannerLedger`.
    @OptionalField(key: "sale_banner") var saleBanner: String?
    @OptionalField(key: "sale_banner_seen_at") var saleBannerSeenAt: Date?
    /// The share of the buyable catalogue the last complete scan found marked down, and when —
    /// the scan's half of `CatalogueSale.State`. Written once per completed scan.
    @OptionalField(key: "catalogue_share") var catalogueShare: Double?
    @OptionalField(key: "catalogue_measured_at") var catalogueMeasuredAt: Date?
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?

    @Children(for: \.$brand) var sources: [SourceModel]
    @Children(for: \.$brand) var products: [ProductModel]
    @Children(for: \.$brand) var storefronts: [StorefrontModel]

    init() {}

    init(name: String, slug: String, website: String?, instagramHandle: String?, usesGeneratedName: Bool) {
        self.name = name
        self.slug = slug
        self.website = website
        self.instagramHandle = instagramHandle
        self.lockedForDrop = false
        self.usesGeneratedName = usesGeneratedName
    }
}

/// A brand's shop for a set of countries, when it runs one apart from its main shop.
///
/// **The main shop is not a row.** It is the brand itself — `brands.website`,
/// `brands.currency` and every source whose `storefront_id` is null — which is what let every
/// brand already in the catalogue keep working unchanged: no backfill, no re-discovery, no
/// baseline spent twice. A storefront exists only where somebody attached one
/// (`POST /admin/brands/:id/storefronts`), and is only polled while somebody in one of its
/// countries follows the brand — see `Storefronts`.
///
/// **A shop serves a set of countries** (`countries`, `storefront_countries`). `eu.kith.com`
/// is one shop, in euros, for 48 of them; when a row was one country it could be attached for
/// one, and attaching it for a second was refused as a catalogue already read.
///
/// Catalogue, not personal: one row per real-world shop, shared by everybody it serves.
final class StorefrontModel: Model, @unchecked Sendable {
    static let schema = "storefronts"

    @ID(key: .id) var id: UUID?
    @Parent(key: "brand_id") var brand: BrandModel
    /// One of `countries`, always: the first, alphabetically, of those it was attached for.
    ///
    /// **Not who it serves — `countries` is.** This is the column a shop was identified by
    /// when it served one country, kept because it sits inside the `(brand_id, country)` unique
    /// constraint and SQLite cannot drop a column that does, and the two databases must not
    /// diverge. Kept *in* the set so that constraint can never fire on its own — the set is
    /// unique per brand, so its members are — and sent as `StorefrontDTO.country` to a client
    /// that reads no set. Removing it from the set moves it to another member.
    @Field(key: "country") var homeCountry: String
    /// The shop's own base URL — what discovery was run on, and what a brand page names.
    @Field(key: "url") var url: String
    /// What this shop charges in, from its own `/meta.json` when it publishes one. Kept apart
    /// from `brands.currency`, which is the main shop's and would otherwise be overwritten by
    /// whichever of the two shops polled last.
    @OptionalField(key: "currency") var currency: String?
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?

    @Children(for: \.$storefront) var sources: [SourceModel]
    /// Who it serves. Never empty: removing the last is refused, because that is deleting
    /// the shop.
    @Children(for: \.$storefront) var countries: [StorefrontCountryModel]

    init() {}

    init(brandID: UUID, homeCountry: String, url: String, currency: String?) {
        self.$brand.id = brandID
        self.homeCountry = homeCountry
        self.url = url
        self.currency = currency
    }

    /// The codes it serves, sorted. Needs `countries` loaded.
    var countryCodes: [String] { countries.map(\.country).sorted() }

    /// Needs `countries` loaded, which every storefront `Storefronts.serving` hands back has.
    var asDTO: StorefrontDTO {
        StorefrontDTO(country: homeCountry, url: url, currency: currency, countries: countryCodes)
    }
}

/// One country a storefront serves.
///
/// **Unique on (brand, country), which is "one shop per brand per person" written into the
/// schema.** The brand is copied onto the row for that alone — a constraint cannot reach
/// through the storefront to its brand — and it is always the storefront's. Two shops of one
/// brand for one country would leave which of them a person there is served undecided.
final class StorefrontCountryModel: Model, @unchecked Sendable {
    static let schema = "storefront_countries"

    @ID(key: .id) var id: UUID?
    @Parent(key: "storefront_id") var storefront: StorefrontModel
    @Field(key: "brand_id") var brandID: UUID
    /// ISO 3166-1 alpha-2, as `CountryCode` writes it.
    @Field(key: "country") var country: String

    init() {}

    init(storefrontID: UUID, brandID: UUID, country: String) {
        self.$storefront.id = storefrontID
        self.brandID = brandID
        self.country = country
    }
}

final class SourceModel: Model, @unchecked Sendable {
    static let schema = "sources"

    @ID(key: .id) var id: UUID?
    @Parent(key: "brand_id") var brand: BrandModel
    /// The country shop this source reads, or nil for the brand's main shop — which every
    /// source written before storefronts existed is. See `StorefrontModel`.
    @OptionalParent(key: "storefront_id") var storefront: StorefrontModel?
    @Field(key: "kind") var kind: String
    @Field(key: "url") var url: String
    @Field(key: "enabled") var enabled: Bool
    @OptionalField(key: "etag") var etag: String?
    @OptionalField(key: "fingerprint") var fingerprint: String?
    @Field(key: "failure_count") var failureCount: Int
    @OptionalField(key: "last_error") var lastError: String?
    @OptionalField(key: "last_checked_at") var lastCheckedAt: Date?
    /// When this source first *successfully stored* a batch. Distinct from
    /// `lastCheckedAt`, which is stamped when a poll begins and therefore survives a
    /// failure — using that to decide "is this the baseline" spends the baseline on a
    /// poll that stored nothing, and the real first batch then goes out as news.
    @OptionalField(key: "baselined_at") var baselinedAt: Date?
    /// When this source last observed a lock, or nil when it is seeing the storefront
    /// normally. On the source rather than the brand because sources poll independently:
    /// a brand-level flag written from inside one source's poll is overwritten by the
    /// next source to run, and never cleared at all if the locking source starts failing.
    @OptionalField(key: "locked_at") var lockedAt: Date?
    /// The poll queue is `ORDER BY next_check_at`, so cadence lives in the row rather
    /// than in a scheduler that would have to be rebuilt on restart.
    @Field(key: "next_check_at") var nextCheckAt: Date

    init() {}

    init(brandID: UUID, kind: BrandSource.Kind, url: String, storefrontID: UUID? = nil) {
        self.$brand.id = brandID
        self.$storefront.id = storefrontID
        self.kind = kind.rawValue
        self.url = url
        self.enabled = true
        self.failureCount = 0
        self.nextCheckAt = Date()
    }

    /// Rehydrate the value type the adapters actually take.
    var asBrandSource: BrandSource {
        BrandSource(
            id: id ?? UUID(),
            kind: BrandSource.Kind(rawValue: kind) ?? .page,
            url: URL(string: url) ?? URL(string: "https://invalid.invalid")!,
            enabled: enabled,
            fingerprint: fingerprint,
            etag: etag,
            lastCheckedAt: lastCheckedAt,
            lastError: lastError,
            failureCount: failureCount
        )
    }
}

/// A Shopify source's daily full scan: when it is due, how far the one in progress has got,
/// and what the last one found. See `Poller.scanTick`.
///
/// One row per source, made by the scanner itself for any Shopify source without one. Its own
/// table so the scan's lease never locks the `sources` row the poll claims.
final class CatalogueScanModel: Model, @unchecked Sendable {
    static let schema = "catalogue_scans"

    @ID(key: .id) var id: UUID?
    @Parent(key: "source_id") var source: SourceModel
    /// The schedule and the lease: the claim pushes it forward before any request, and a turn
    /// sets it to now (more pages to read), to the source's next slot (finished), or to a
    /// backoff (failed).
    @Field(key: "due_at") var dueAt: Date
    /// When the scan in progress began, nil between scans.
    @OptionalField(key: "started_at") var startedAt: Date?
    /// The page the scan in progress reads next.
    @Field(key: "next_page") var nextPage: Int
    /// Whether the scan in progress is a baseline — decided when it begins, so one scan is
    /// one or the other from its first page to its last.
    @Field(key: "is_baseline") var isBaseline: Bool
    /// The products the scan in progress has seen, as `ScanDigests`. Kept in the row so an
    /// interrupted scan resumes with its memory, on this instance or another.
    @OptionalField(key: "seen") var seen: String?
    /// The scan in progress's sale reading so far — `CatalogueSale.Reading`, accumulated a
    /// page at a time.
    @Field(key: "priced") var priced: Int
    @Field(key: "marked_down") var markedDown: Int
    @OptionalField(key: "deepest") var deepest: Int?
    @Field(key: "failure_count") var failureCount: Int
    @OptionalField(key: "last_error") var lastError: String?
    /// When a scan last read to the end of the catalogue. Nil until one has, and the reason a
    /// scan stops counting as the catalogue's word: see `Poller.scanIsBaseline` and `Reaper`.
    @OptionalField(key: "completed_at") var completedAt: Date?
    /// The last finished scan, complete or cut short at the page cap, for `/admin/status`.
    @OptionalField(key: "last_started_at") var lastStartedAt: Date?
    @OptionalField(key: "finished_at") var finishedAt: Date?
    @OptionalField(key: "last_pages") var lastPages: Int?
    @OptionalField(key: "last_products") var lastProducts: Int?
    @OptionalField(key: "last_truncated") var lastTruncated: Bool?

    init() {}

    init(sourceID: UUID, dueAt: Date) {
        self.$source.id = sourceID
        self.dueAt = dueAt
        self.nextPage = 1
        self.isBaseline = false
        self.priced = 0
        self.markedDown = 0
        self.failureCount = 0
    }

    /// The reading so far, as the rule takes it.
    var reading: CatalogueSale.Reading {
        var reading = CatalogueSale.Reading()
        reading.priced = priced
        reading.markedDown = markedDown
        reading.deepest = deepest
        return reading
    }
}

final class ProductModel: Model, @unchecked Sendable {
    static let schema = "products"

    @ID(key: .id) var id: UUID?
    @Parent(key: "brand_id") var brand: BrandModel
    @OptionalParent(key: "source_id") var source: SourceModel?
    /// Stable per source — "shopify:<id>", "feed:<guid>". Unique with source_id.
    @Field(key: "external_id") var externalID: String
    @Field(key: "title") var title: String
    @OptionalField(key: "summary") var summary: String?
    @OptionalField(key: "link_url") var linkURL: String?
    @Field(key: "image_urls") var imageURLs: [String]
    @Field(key: "kind") var kind: String
    @OptionalField(key: "price_text") var priceText: String?
    /// The numeric price, so a markdown is detectable. `price_text` is formatted for
    /// display and two different strings say nothing about direction.
    @OptionalField(key: "price_amount") var priceAmount: Double?
    /// The ISO 4217 code of both prices, from the read that produced them — nil when the source
    /// did not say, and on every row from before the column, all of which are the main shop's
    /// and so in `brands.currency`. See `AddStorefrontColumns`.
    @OptionalField(key: "currency") var currency: String?
    /// The storefront this row was read from, copied from its source when the row is made —
    /// nil for the main shop. Here as well as on the source because Discover asks for one
    /// shop's products and the feed for one shop's events, and neither should have to join
    /// through `sources` to say which shop it means. A source never changes storefront, so
    /// the copy cannot go stale.
    @OptionalField(key: "storefront_id") var storefrontID: UUID?
    /// What the brand says it cost before it was marked down — `compare_at_price`. Beside
    /// the price rather than on an event, because it describes the product as it is now.
    /// See `AddProductOriginalPrice`.
    @OptionalField(key: "original_price_text") var originalPriceText: String?
    @OptionalField(key: "original_price_amount") var originalPriceAmount: Double?
    @OptionalField(key: "is_available") var isAvailable: Bool?
    @Field(key: "tags") var tags: [String]
    @OptionalField(key: "product_type") var productType: String?
    /// For a `kind == "collection"` row, the products the storefront says are in it, keyed
    /// as `external_id` is. Empty for every other kind and for anything stored before
    /// `CollectionsSource` learned to read the membership — see `AddProductMembers`.
    @Field(key: "member_external_ids") var memberExternalIDs: [String]
    @Field(key: "published_at") var publishedAt: Date
    @Timestamp(key: "first_seen_at", on: .create) var firstSeenAt: Date?
    @Field(key: "last_seen_at") var lastSeenAt: Date
    /// When this product's own page was last read for its details (`ProductPage`), or nil
    /// if it never has been. Stamped even when the page had nothing to say, so a page that
    /// cannot be read is not asked again every pass. Only sitemap products are ever read.
    @OptionalField(key: "enriched_at") var enrichedAt: Date?
    /// What this product is owed once its page has been read — see `PendingAnnouncement`.
    @OptionalField(key: "pending_announcement") var pendingAnnouncement: String?
    /// When a complete catalogue scan first failed to find this product, or nil while it is
    /// listed. One miss is not a removal: paging a catalogue that changes under the reader
    /// can skip a row.
    @OptionalField(key: "missing_since") var missingSince: Date?
    /// When a second complete scan in a row failed to find it: the shop no longer lists it.
    /// Retention counts from here (`Reaper`). Cleared by any read that sees it again.
    @OptionalField(key: "unlisted_at") var unlistedAt: Date?
    /// Which of `imageURLs` is the clean product shot, as `ProductReading` read it — nil before
    /// it has, and when no photograph is one. See `AddProductReading`.
    @OptionalField(key: "shot_index") var shotIndex: Int?
    /// The style words the same reading found (`StyleWords`): nil before it has read the
    /// product, empty when it did and nothing was clear.
    @OptionalField(key: "style_words") var styleWords: [String]?

    @Children(for: \.$product) var variants: [VariantModel]

    init() { self.memberExternalIDs = [] }

    init(brandID: UUID, sourceID: UUID?, storefrontID: UUID? = nil, item: FetchedItem) {
        self.$brand.id = brandID
        self.$source.id = sourceID
        self.storefrontID = storefrontID
        self.currency = item.currency
        self.externalID = item.externalID
        self.title = item.title
        self.summary = item.summary
        self.linkURL = item.linkURL?.absoluteString
        self.imageURLs = item.imageURLStrings
        self.kind = item.kind.rawValue
        self.priceText = item.priceText
        self.priceAmount = item.priceAmount
        self.originalPriceText = item.originalPriceText
        self.originalPriceAmount = item.originalPriceAmount
        self.isAvailable = item.isAvailable
        self.tags = item.tags
        self.productType = item.productType
        self.memberExternalIDs = item.memberExternalIDs
        self.publishedAt = item.publishedAt
        self.lastSeenAt = Date()
    }
}

/// The event a new sitemap product is waiting to be announced with.
///
/// **A sitemap product is announced from its page, not from the sitemap.** The sitemap has
/// a URL and at best a photograph; the page has the name, the price and the size run. An
/// event written at first sight went out as a push saying "New arrival" and a card with no
/// price — and the phone keeps the copy it was sent, so reading the page a minute later
/// fixed the server's row and nobody's screen. So the row is stored, the event is held,
/// and `Poller.enrich` writes it once the page has been read, usually in the same pass.
enum PendingAnnouncement: String {
    /// Surely a product: announced once the page is read, whatever it says.
    case announce
    /// Only the page can say — `FetchedItem.isTentative`. Announced if it shows a product,
    /// and the row deleted if it does not, since a category page is not a catalogue entry.
    case confirm
}

/// Per-variant stock is the whole reason restock alerts can name a size.
final class VariantModel: Model, @unchecked Sendable {
    static let schema = "variants"

    @ID(key: .id) var id: UUID?
    @Parent(key: "product_id") var product: ProductModel
    @Field(key: "external_id") var externalID: String
    @Field(key: "title") var title: String
    @OptionalField(key: "size") var size: String?
    @OptionalField(key: "color") var color: String?
    @Field(key: "available") var available: Bool
    @OptionalField(key: "price") var price: String?
    @OptionalField(key: "available_changed_at") var availableChangedAt: Date?
    /// Which of the product's photographs shows this variant. Stored rather than derived
    /// because the association lives in the catalogue payload the poller decodes and
    /// nowhere else — by the time the feed is assembled, the images are a bare array.
    @OptionalField(key: "image_index") var imageIndex: Int?

    init() {}

    init(productID: UUID, info: VariantInfo) {
        self.$product.id = productID
        self.externalID = info.id
        self.title = info.title
        self.size = info.size
        self.color = info.color
        self.available = info.available
        self.price = info.price
        self.imageIndex = info.imageIndex
    }

    var asVariantInfo: VariantInfo {
        VariantInfo(
            id: externalID,
            title: title,
            available: available,
            price: price,
            size: size,
            color: color,
            imageIndex: imageIndex
        )
    }
}

/// Append-only spine. The poller writes these, the feed reads them, the notifier fans
/// them out — so "what happened" stays separate from "what is currently true".
final class EventModel: Model, @unchecked Sendable {
    static let schema = "events"

    @ID(key: .id) var id: UUID?
    @Parent(key: "brand_id") var brand: BrandModel
    @OptionalParent(key: "product_id") var product: ProductModel?
    @Field(key: "kind") var kind: String
    @Field(key: "sizes") var sizes: [String]
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?
    /// When this event was fanned out to push, or nil if it hasn't been. Held in the row
    /// for the same reason as `next_check_at`: a restart must not re-notify, and a
    /// second instance can later claim rows without a shared cache.
    @OptionalField(key: "notified_at") var notifiedAt: Date?
    /// What the product cost before this event, for a `.priceDrop`. On the event rather
    /// than the product for the same reason `sizes` is: the product row holds what is
    /// currently true and the next poll overwrites it, while an event has to keep what was
    /// true when it fired.
    @OptionalField(key: "previous_price_text") var previousPriceText: String?
    @OptionalField(key: "previous_price_amount") var previousPriceAmount: Double?
    /// The event's own words, for a kind with no product to take them from — a `.sale`
    /// ("25% OFF EVERYTHING · CODE AUTUMN", and the bar's message as written). Nil for every
    /// other kind, which is drawn from its product.
    @OptionalField(key: "title") var title: String?
    @OptionalField(key: "summary") var summary: String?
    /// Which of the brand's shops this happened in — its product's storefront, nil for the
    /// main shop. A `.sale` is the main shop's: both detectors read it alone. The feed and
    /// `Notifier` serve each person one shop per brand, and this is what they serve by.
    @OptionalField(key: "storefront_id") var storefrontID: UUID?
    /// What the model read off a `.sale`'s banner, when AI was on: the sale's last day (the
    /// end of it, UTC) and its fine print in one line. See `AddSaleReading`.
    @OptionalField(key: "sale_ends_at") var saleEndsAt: Date?
    @OptionalField(key: "sale_terms") var saleTerms: String?

    init() {}

    init(
        brandID: UUID,
        productID: UUID?,
        storefrontID: UUID? = nil,
        kind: UpdateKind,
        sizes: [String] = [],
        previousPriceText: String? = nil,
        previousPriceAmount: Double? = nil,
        title: String? = nil,
        summary: String? = nil
    ) {
        self.$brand.id = brandID
        self.$product.id = productID
        self.storefrontID = storefrontID
        self.kind = kind.rawValue
        self.sizes = sizes
        self.previousPriceText = previousPriceText
        self.previousPriceAmount = previousPriceAmount
        self.title = title
        self.summary = summary
    }
}

final class UserModel: Model, @unchecked Sendable {
    static let schema = "users"

    @ID(key: .id) var id: UUID?
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?

    // Size profile, stored inline — it is one small value per user.
    //
    // Discrete columns rather than an encoded blob, which means a new field on
    // `SizeProfile` is *not* automatically persisted: it round-trips through the
    // accessor below and is silently dropped on write. Anything added to the struct
    // needs a column and a line in both halves of `sizeProfile`.
    @Field(key: "apparel_sizes") var apparelSizes: [String]
    @Field(key: "shoe_sizes") var shoeSizes: [String]
    /// Waists in inches. Its own ladder, not a flavour of `apparel_sizes` — a 32 is not
    /// an M and no table converts between them.
    @Field(key: "waist_sizes") var waistSizes: [String]
    /// Women's dress sizes as US tokens. See `AddUserDressAndSuitSizes`.
    @Field(key: "dress_sizes") var dressSizes: [String]
    /// Jacket chests in inches.
    @Field(key: "suit_sizes") var suitSizes: [String]
    /// Jacket lengths: "S", "R", "L". Its own column rather than folded into `suit_sizes`,
    /// for the reason `SizeProfile.suitLength` is its own field.
    @Field(key: "suit_lengths") var suitLengths: [String]
    /// Vestigial. One-size items fit everyone, so the preference was removed and this is
    /// now always true — kept only because the column is `NOT NULL` in a schema that is
    /// already applied in production, and dropping it would be a migration bought for
    /// nothing.
    @Field(key: "include_one_size") var includeOneSize: Bool
    /// Nullable: absent means "everything", which is the default for a new profile and
    /// the honest reading of someone who has never expressed a preference.
    @OptionalField(key: "gender") var gender: String?
    /// The Sign in with Apple account this user belongs to, or nil for an anonymous one —
    /// which is every user 1.0 and 1.1 make, and every user until somebody signs in. See
    /// `CreateAccounts`.
    @OptionalParent(key: "account_id") var account: AccountModel?
    /// Which country's shops this person is served, as `CountryCode` writes it. Nullable, and
    /// null is the main shop of every brand — what every user was before this existed, what 1.0
    /// always is, and the honest reading of somebody who has never said. Not part of
    /// `sizeProfile`: it says nothing about what fits, and it is set by its own field on
    /// `UpdateDevice`. See `Storefronts`.
    @OptionalField(key: "country") var country: String?
    /// What a profile is called, printed at the start of its alerts ("For Anna: …"). Nil for
    /// every anonymous user and for the holder until they name themselves. See
    /// `AddUserProfiles` and `docs/profiles.md`.
    @OptionalField(key: "display_name") var displayName: String?
    /// The profile's own switch for every push about it — summaries, watches, markdowns and
    /// replies alike. A watch still fires and is still spent with it off.
    @Field(key: "alerts_enabled") var alertsEnabled: Bool

    init() {
        self.apparelSizes = []
        self.shoeSizes = []
        self.waistSizes = []
        self.dressSizes = []
        self.suitSizes = []
        self.suitLengths = []
        self.includeOneSize = true
        self.alertsEnabled = true
    }

    /// The display scales (`shoeScale`, `dressScale`, `suitScale`) have no column on
    /// purpose: they change how a size is *read out*, never what is stored or matched, and
    /// they never leave the phone.
    var sizeProfile: SizeProfile {
        get {
            var profile = SizeProfile()
            profile.apparel = Set(apparelSizes)
            profile.shoe = Set(shoeSizes)
            profile.waist = Set(waistSizes)
            profile.dress = Set(dressSizes)
            profile.suit = Set(suitSizes)
            profile.suitLength = Set(suitLengths)
            profile.gender = gender.flatMap(GenderPreference.init(rawValue:)) ?? .everything
            return profile
        }
        set {
            apparelSizes = Array(newValue.apparel)
            shoeSizes = Array(newValue.shoe)
            waistSizes = Array(newValue.waist)
            dressSizes = Array(newValue.dress)
            suitSizes = Array(newValue.suit)
            suitLengths = Array(newValue.suitLength)
            includeOneSize = true
            gender = newValue.gender.rawValue
        }
    }
}

/// The identity that survives a reinstall: one Sign in with Apple subject.
///
/// Personal, and above `users` rather than beside it — an account owns its users (one now,
/// one per profile later), and every device reaches it through its user. Holds nothing a
/// person typed: Apple's opaque `sub`, the credit settings the operator sets by hand, and
/// the refresh token deletion has to revoke. See `CreateAccounts`.
final class AccountModel: Model, @unchecked Sendable {
    static let schema = "accounts"

    @ID(key: .id) var id: UUID?
    /// Apple's `sub` claim — stable per developer team, opaque, and the only lookup key.
    @Field(key: "apple_subject") var appleSubject: String
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?
    /// The owner's switch: this account is never charged. Means nothing until credits
    /// exist, and is stored now so the owner can flip it on their own account the day they
    /// sign in. Set only by `POST /admin/accounts/:id/credits`.
    @Field(key: "unlimited_credits") var unlimitedCredits: Bool
    /// A ceiling on what this account may cost in a month, in millionths of a dollar. Nil
    /// is no account-specific cap.
    @OptionalField(key: "monthly_cost_cap_micros") var monthlyCostCapMicros: Int64?
    /// What `/auth/revoke` needs on deletion. Never logged, never on the wire. Nil when the
    /// deployment has no Sign in with Apple key, so the exchange was skipped.
    @OptionalField(key: "apple_refresh_token") var appleRefreshToken: String?

    @Children(for: \.$account) var users: [UserModel]

    init() {
        self.unlimitedCredits = false
    }

    init(appleSubject: String) {
        self.appleSubject = appleSubject
        self.unlimitedCredits = false
    }
}

final class DeviceModel: Model, @unchecked Sendable {
    static let schema = "devices"

    @ID(key: .id) var id: UUID?
    @Parent(key: "user_id") var user: UserModel
    @OptionalField(key: "apns_token") var apnsToken: String?
    /// Opaque bearer credential. No login, no PII — see BACKEND.md on auth.
    @Field(key: "auth_token") var authToken: String
    @Field(key: "environment") var environment: String
    @OptionalField(key: "locale") var locale: String?
    @Timestamp(key: "updated_at", on: .update) var updatedAt: Date?
    /// The UTC day (`yyyy-MM-dd`) this device last sent a usage report, and nothing finer.
    ///
    /// The one per-device fact the usage counts keep, and it is overwritten rather than
    /// appended to: it is what lets "how many people used it this week" be answered without
    /// counting one person's ten opens as ten people, and without any row that says which
    /// device did what. Written only by `POST /v1/usage` — never by the feed or the size push,
    /// which a background refresh also makes, so a phone in a drawer is not an active user.
    /// See `UsageLedger.markActive`.
    @OptionalField(key: "active_on") var activeOn: String?

    init() {}

    init(userID: UUID, apnsToken: String?, environment: String, locale: String?) {
        self.$user.id = userID
        self.apnsToken = apnsToken
        self.authToken = [UInt8].random(count: 32).base64
        self.environment = environment
        self.locale = locale
    }
}

final class FollowModel: Model, @unchecked Sendable {
    static let schema = "follows"

    @ID(key: .id) var id: UUID?
    @Parent(key: "user_id") var user: UserModel
    @Parent(key: "brand_id") var brand: BrandModel
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?
    /// `FollowMode` raw value. A string rather than an enum column for the reason the wire
    /// carries one: a mode a later deploy writes must still read on an earlier one, as
    /// `.everything`. See `AddFollowMode`.
    @Field(key: "mode") var modeRaw: String
    /// `FollowFilter` as JSON text, or nil for *All* — see `AddFollowFilter`.
    @OptionalField(key: "filter") var filterJSON: String?

    init() {
        self.modeRaw = FollowMode.everything.rawValue
    }

    init(userID: UUID, brandID: UUID, mode: FollowMode = .everything) {
        self.$user.id = userID
        self.$brand.id = brandID
        self.modeRaw = mode.rawValue
    }

    var mode: FollowMode {
        get { FollowMode(lenient: modeRaw) }
        set { modeRaw = newValue.rawValue }
    }

    /// Which part of the brand this follow lets through. Setting an empty filter stores nil,
    /// so *All* has one spelling (`FollowFilter.normalized`).
    var filter: FollowFilter? {
        get { filterJSON.flatMap { try? JSONDecoder().decode(FollowFilter.self, from: Data($0.utf8)) } }
        set {
            filterJSON = newValue?.normalized
                .flatMap { try? JSONEncoder().encode($0) }
                .map { String(decoding: $0, as: UTF8.self) }
        }
    }
}

/// "Tell me when this specific thing comes back", per user.
///
/// The one personal row that points at a catalog product. That is not a violation of the
/// global-catalog rule — the *product* stays one row for everyone, and this is a person's
/// interest in it, exactly like `FollowModel` is a person's interest in a brand.
final class WatchModel: Model, @unchecked Sendable {
    static let schema = "watches"

    @ID(key: .id) var id: UUID?
    @Parent(key: "user_id") var user: UserModel
    @Parent(key: "brand_id") var brand: BrandModel
    @Parent(key: "product_id") var product: ProductModel
    /// Nil means "any size" / "any colour". Raw catalogue text; `WatchTarget` normalises
    /// at comparison time so both ends agree.
    @OptionalField(key: "size") var size: String?
    @OptionalField(key: "color") var color: String?
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?
    /// The ledger, in the row for the same reason `events.notified_at` is: a restart must
    /// not re-fire a watch, and a watch that has fired is a record worth keeping rather
    /// than a row to delete.
    @OptionalField(key: "fired_at") var firedAt: Date?
    @Field(key: "fired_sizes") var firedSizes: [String]

    init() {
        self.firedSizes = []
    }

    init(userID: UUID, brandID: UUID, productID: UUID, size: String?, color: String?) {
        self.$user.id = userID
        self.$brand.id = brandID
        self.$product.id = productID
        self.size = size
        self.color = color
        self.firedSizes = []
    }

    var target: WatchTarget { WatchTarget(size: size, color: color) }
}

/// "This brand drops at this moment" — a date somebody typed, spending nothing but poll
/// cadence.
///
/// Personal, like `FollowModel` and `WatchModel`, and for the same reason those are not a
/// violation of the global-catalog rule: the *brand* stays one row for everybody, and this
/// is one person's claim about it. Nothing here is ever read back to another user — there
/// is no route that returns somebody else's hints, and no event, product or notification is
/// derived from one. The only thing it can do is make `Poller` look sooner.
///
/// The two columns that are not obvious:
///
/// - **`release_at` is the only thing the client sets.** The window around it is
///   `PollHintPolicy`'s and is applied at query time rather than stored, so tightening it
///   on a deployment takes effect immediately rather than only for hints written after.
/// - **Unique on (user_id, brand_id).** One hint per brand per person, which is what stops
///   a client covering a whole week by posting a row every hour. `PUT /v1/poll-hints`
///   replaces the caller's whole set, so the constraint is a guard rather than a thing
///   normal use can hit.
final class PollHintModel: Model, @unchecked Sendable {
    static let schema = "poll_hints"

    @ID(key: .id) var id: UUID?
    @Parent(key: "user_id") var user: UserModel
    @Parent(key: "brand_id") var brand: BrandModel
    @Field(key: "release_at") var releaseAt: Date
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?

    init() {}

    init(userID: UUID, brandID: UUID, releaseAt: Date) {
        self.$user.id = userID
        self.$brand.id = brandID
        self.releaseAt = releaseAt
    }

    var asPollHint: PollHint { PollHint(brandID: $brand.id, releaseAt: releaseAt) }
}

/// One look at a site, run off the request — see `BrandChecks`.
///
/// Not part of the catalogue: a check is a short-lived record of *asking*, pruned within a
/// day. It is shared by everybody who asks about the same shop in that time, which is what
/// lets the add reuse the preview's answer rather than fetching the storefront again.
///
/// **In the database rather than in memory**, because a deploy restarts the process: a check
/// held in memory would vanish mid-flight, and the phone asking about it would get a 404 it
/// could not tell apart from a bad id. A row left `checking` by a restart is read back as
/// interrupted (`BrandChecks.orphanAfter`), and re-run if somebody is still waiting on it.
final class BrandCheckModel: Model, @unchecked Sendable {
    static let schema = "brand_checks"

    @ID(key: .id) var id: UUID?
    /// `BrandDiscovery.registrableDomain`, so `www.` and the apex share one check — the same
    /// rule that stops them becoming two brands.
    @Field(key: "domain") var domain: String
    @Field(key: "url") var url: String
    /// A `BrandCheck.Status` raw value.
    @Field(key: "status") var status: String
    /// The finished `BrandProbe`, JSON-encoded. Text rather than an array or JSONB column,
    /// so there is nothing here for the Postgres/SQLite difference in `docs/server.md` to
    /// bite on.
    @OptionalField(key: "probe") var probe: String?
    @OptionalField(key: "logo_url") var logoURL: String?
    /// The catalogue brand this check is about, once there is one.
    @OptionalParent(key: "brand_id") var brand: BrandModel?
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?
    @OptionalField(key: "finished_at") var finishedAt: Date?
    /// A `BrandCheck.Refusal` raw value, on a refused check only — see `AddBrandCheckRefusal`.
    @OptionalField(key: "refusal") var refusal: String?
    /// Somebody saved from this shop and the catalogue did not have it: add it to the catalogue
    /// once the check finds a real shop, and follow nobody — see `AddCatalogueOnlyCheck`.
    /// **The row records nothing about who asked**, and the route adds no watcher for it.
    @OptionalField(key: "catalogue_only") var catalogueOnly: Bool?
    /// The homepage's `hreflang` alternates, JSON-encoded `[LanguageAlternate]` — what the
    /// brand's country shops are found from once the check makes a brand (`CountryShops`), so
    /// the homepage the check already read is not fetched again. See `AddRediscovery`.
    @OptionalField(key: "alternates") var alternates: String?

    @Children(for: \.$check) var watchers: [BrandCheckWatcherModel]

    init() {}

    init(domain: String, url: String, status: BrandCheck.Status) {
        self.domain = domain
        self.url = url
        self.status = status.rawValue
    }
}

/// Somebody who asked to watch a check's shop before — or after — the check finished.
///
/// Personal, and pointing at a check the way `FollowModel` points at a brand. Settled into
/// a follow the moment the check finds something to watch; the row stays until the check is
/// pruned, so a second tap does not follow twice or notify twice.
final class BrandCheckWatcherModel: Model, @unchecked Sendable {
    static let schema = "brand_check_watchers"

    @ID(key: .id) var id: UUID?
    @Parent(key: "check_id") var check: BrandCheckModel
    @Parent(key: "user_id") var user: UserModel
    /// Offered on the add screen. Only used if this check is the one that creates the
    /// brand — an existing brand keeps the handle it has, exactly as `POST
    /// /v1/brands/discover` always treated it.
    @OptionalField(key: "instagram") var instagram: String?
    /// When this watcher was turned into a follow. The ledger, so settling twice is a no-op.
    @OptionalField(key: "settled_at") var settledAt: Date?
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?

    init() {}

    init(checkID: UUID, userID: UUID, instagram: String?) {
        self.$check.id = checkID
        self.$user.id = userID
        self.instagram = instagram
    }
}

/// How many times one thing happened on one day, across everybody.
///
/// **Not personal and not catalogue — a total.** There is no `user_id` and no `device_id` here
/// and there must never be one: the whole promise of the usage counts is that what arrives is
/// added to a number shared by everybody and nothing else is kept. One row per (day, event),
/// unique, so the table grows by at most a dozen rows a day however many reports arrive.
/// See `UsageLedger` and `UsagePolicy`.
final class UsageCountModel: Model, @unchecked Sendable {
    static let schema = "usage_counts"

    @ID(key: .id) var id: UUID?
    /// `yyyy-MM-dd` in UTC. A string rather than a date column, so Postgres and SQLite agree
    /// on where a day ends and the ordering is plain text.
    @Field(key: "day") var day: String
    /// A `UsageEvent` raw value, or one of `UsagePolicy`'s server-only active rows.
    @Field(key: "event") var event: String
    @Field(key: "total") var total: Int

    init() {}
}

/// One brand looked at again under one version of discovery's rules — see `Rediscovery`.
///
/// The ledger that makes the pass run once: a brand with a row for the current pass —
/// `Rediscovery.pass`, the rules' version and the countries switched on — is never claimed
/// again, whether its look finished or is still running on another instance, and the row is
/// written *before* the first request so a restart resumes with the next brand rather than the
/// one it was on. Unique on (brand, pass).
final class RediscoveryModel: Model, @unchecked Sendable {
    static let schema = "rediscoveries"

    @ID(key: .id) var id: UUID?
    @Parent(key: "brand_id") var brand: BrandModel
    /// `Rediscovery.pass`: "1:DE,US".
    @Field(key: "pass") var pass: String
    @Field(key: "started_at") var startedAt: Date
    /// Nil while the look is running — or after the process running it died, which
    /// `Rediscovery.abandonAfter` turns back into a claim.
    @OptionalField(key: "finished_at") var finishedAt: Date?
    /// What it did, as logged: "subdued.com: +feed new_products, +storefront US us.subdued.com (ucp)".
    @OptionalField(key: "line") var line: String?
    /// Sources added to the main shop, and country shops attached.
    @Field(key: "added") var added: Int
    @Field(key: "storefronts") var storefronts: Int

    init() {}

    init(brandID: UUID, pass: String, startedAt: Date = Date()) {
        self.$brand.id = brandID
        self.pass = pass
        self.startedAt = startedAt
        self.added = 0
        self.storefronts = 0
    }
}

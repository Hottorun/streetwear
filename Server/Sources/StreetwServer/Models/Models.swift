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
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?

    @Children(for: \.$brand) var sources: [SourceModel]
    @Children(for: \.$brand) var products: [ProductModel]

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

final class SourceModel: Model, @unchecked Sendable {
    static let schema = "sources"

    @ID(key: .id) var id: UUID?
    @Parent(key: "brand_id") var brand: BrandModel
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

    init(brandID: UUID, kind: BrandSource.Kind, url: String) {
        self.$brand.id = brandID
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
    @OptionalField(key: "is_available") var isAvailable: Bool?
    @Field(key: "tags") var tags: [String]
    @OptionalField(key: "product_type") var productType: String?
    @Field(key: "published_at") var publishedAt: Date
    @Timestamp(key: "first_seen_at", on: .create) var firstSeenAt: Date?
    @Field(key: "last_seen_at") var lastSeenAt: Date

    @Children(for: \.$product) var variants: [VariantModel]

    init() {}

    init(brandID: UUID, sourceID: UUID?, item: FetchedItem) {
        self.$brand.id = brandID
        self.$source.id = sourceID
        self.externalID = item.externalID
        self.title = item.title
        self.summary = item.summary
        self.linkURL = item.linkURL?.absoluteString
        self.imageURLs = item.imageURLStrings
        self.kind = item.kind.rawValue
        self.priceText = item.priceText
        self.priceAmount = item.priceAmount
        self.isAvailable = item.isAvailable
        self.tags = item.tags
        self.productType = item.productType
        self.publishedAt = item.publishedAt
        self.lastSeenAt = Date()
    }
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

    init() {}

    init(
        brandID: UUID,
        productID: UUID?,
        kind: UpdateKind,
        sizes: [String] = [],
        previousPriceText: String? = nil,
        previousPriceAmount: Double? = nil
    ) {
        self.$brand.id = brandID
        self.$product.id = productID
        self.kind = kind.rawValue
        self.sizes = sizes
        self.previousPriceText = previousPriceText
        self.previousPriceAmount = previousPriceAmount
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
    /// Vestigial. One-size items fit everyone, so the preference was removed and this is
    /// now always true — kept only because the column is `NOT NULL` in a schema that is
    /// already applied in production, and dropping it would be a migration bought for
    /// nothing.
    @Field(key: "include_one_size") var includeOneSize: Bool
    /// Nullable: absent means "everything", which is the default for a new profile and
    /// the honest reading of someone who has never expressed a preference.
    @OptionalField(key: "gender") var gender: String?

    init() {
        self.apparelSizes = []
        self.shoeSizes = []
        self.waistSizes = []
        self.includeOneSize = true
    }

    var sizeProfile: SizeProfile {
        get {
            var profile = SizeProfile()
            profile.apparel = Set(apparelSizes)
            profile.shoe = Set(shoeSizes)
            profile.waist = Set(waistSizes)
            profile.gender = gender.flatMap(GenderPreference.init(rawValue:)) ?? .everything
            return profile
        }
        set {
            apparelSizes = Array(newValue.apparel)
            shoeSizes = Array(newValue.shoe)
            waistSizes = Array(newValue.waist)
            includeOneSize = true
            gender = newValue.gender.rawValue
        }
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

    init() {}

    init(userID: UUID, brandID: UUID) {
        self.$user.id = userID
        self.$brand.id = brandID
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

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
    @Field(key: "locked_for_drop") var lockedForDrop: Bool
    /// True while `name` is still derived from the hostname, so the first successful
    /// poll may replace it with the storefront's real name.
    @Field(key: "uses_generated_name") var usesGeneratedName: Bool
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

    init() {}

    init(productID: UUID, info: VariantInfo) {
        self.$product.id = productID
        self.externalID = info.id
        self.title = info.title
        self.size = info.size
        self.color = info.color
        self.available = info.available
        self.price = info.price
    }

    var asVariantInfo: VariantInfo {
        VariantInfo(id: externalID, title: title, available: available, price: price, size: size, color: color)
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

    init() {}

    init(brandID: UUID, productID: UUID?, kind: UpdateKind, sizes: [String] = []) {
        self.$brand.id = brandID
        self.$product.id = productID
        self.kind = kind.rawValue
        self.sizes = sizes
    }
}

final class UserModel: Model, @unchecked Sendable {
    static let schema = "users"

    @ID(key: .id) var id: UUID?
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?

    // Size profile, stored inline — it is one small value per user.
    @Field(key: "apparel_sizes") var apparelSizes: [String]
    @Field(key: "shoe_sizes") var shoeSizes: [String]
    @Field(key: "include_one_size") var includeOneSize: Bool

    init() {
        self.apparelSizes = []
        self.shoeSizes = []
        self.includeOneSize = true
    }

    var sizeProfile: SizeProfile {
        get {
            var profile = SizeProfile()
            profile.apparel = Set(apparelSizes)
            profile.shoe = Set(shoeSizes)
            profile.includeOneSize = includeOneSize
            return profile
        }
        set {
            apparelSizes = Array(newValue.apparel)
            shoeSizes = Array(newValue.shoe)
            includeOneSize = newValue.includeOneSize
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

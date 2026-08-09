// DTO.swift
// Wire types. Kept separate from the Fluent models so the database schema can change
// without silently changing the API.

import Fluent
import Foundation
import StreetwCore
import Vapor

// MARK: - Requests

struct RegisterDevice: Content {
    var apnsToken: String?
    var environment: String?
    var locale: String?
    var sizes: SizePayload?
}

struct UpdateDevice: Content {
    var apnsToken: String?
    var sizes: SizePayload?
}

struct SizePayload: Content {
    var apparel: [String]
    var shoe: [String]
    var includeOneSize: Bool?

    /// Normalises on the way in, so "medium" and "M" can't both end up stored.
    var asProfile: SizeProfile {
        var profile = SizeProfile()
        profile.apparel = Set(apparel.compactMap { SizeNormalizer.normalize($0)?.token })
        profile.shoe = Set(shoe.compactMap { SizeNormalizer.normalize($0)?.token })
        profile.includeOneSize = includeOneSize ?? true
        return profile
    }
}

struct DiscoverBrand: Content {
    var url: String
    var name: String?
    var instagram: String?
}

struct FollowBrand: Content {
    var brandID: UUID
}

// MARK: - Responses

struct DeviceResponse: Content {
    var deviceID: UUID
    var token: String
}

struct BrandResponse: Content {
    var id: UUID?
    var name: String
    var slug: String
    var website: String?
    var instagramHandle: String?
    var currency: String?
    var lockedForDrop: Bool

    init(_ brand: BrandModel) {
        self.id = brand.id
        self.name = brand.name
        self.slug = brand.slug
        self.website = brand.website
        self.instagramHandle = brand.instagramHandle
        self.currency = brand.currency
        self.lockedForDrop = brand.lockedForDrop
    }
}

struct FeedResponse: Content {
    var items: [FeedItem]
    var nextCursor: Date?
}

struct FeedItem: Content {
    var eventID: UUID
    var kind: String
    var createdAt: Date
    var brandID: UUID
    var brandName: String
    var title: String
    var summary: String?
    var linkURL: String?
    var imageURLs: [String]
    var priceText: String?
    var isAvailable: Bool?
    /// Sizes that came back in a restock, already narrowed to ones the user wears.
    var restockedSizes: [String]
    /// Whether anything is currently buyable in the user's sizes — lets the client
    /// badge without shipping every variant.
    var availableInMySize: Bool

    init?(event: EventModel, profile: SizeProfile) {
        guard let eventID = event.id, let createdAt = event.createdAt else { return nil }
        self.eventID = eventID
        self.kind = event.kind
        self.createdAt = createdAt
        self.brandID = event.$brand.id
        self.brandName = event.brand.name

        let product = event.product
        self.title = product?.title ?? event.brand.name
        self.summary = product?.summary
        self.linkURL = product?.linkURL
        self.imageURLs = product?.imageURLs ?? []
        self.priceText = product?.priceText
        self.isAvailable = product?.isAvailable

        let mine = event.sizes.filter { profile.matches($0) }
        // Fall back to all returned sizes when the user hasn't set a profile, so the
        // card can still say "Back in M, L".
        self.restockedSizes = profile.isEmpty ? event.sizes : mine

        let variants = product?.variants ?? []
        self.availableInMySize = variants.isEmpty
            ? false
            : variants.contains { $0.available && profile.matches($0.asVariantInfo) }
    }
}

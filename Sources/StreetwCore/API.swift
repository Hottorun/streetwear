// API.swift
// The wire contract, shared by the server and the app so the two cannot drift.
//
// Plain Codable value types — the server adds Vapor's `Content` conformance by
// extension, the client decodes them directly. Anything that needs a Fluent model to
// build lives on the server as an extension, not here.

import Foundation

// MARK: - Requests

public struct SizePayload: Codable, Sendable, Hashable {
    public var apparel: [String]
    public var shoe: [String]
    public var includeOneSize: Bool?

    public init(apparel: [String], shoe: [String], includeOneSize: Bool? = nil) {
        self.apparel = apparel
        self.shoe = shoe
        self.includeOneSize = includeOneSize
    }

    public init(_ profile: SizeProfile) {
        self.apparel = Array(profile.apparel)
        self.shoe = Array(profile.shoe)
        self.includeOneSize = profile.includeOneSize
    }

    /// Normalises on the way in, so "medium" and "M" can't both end up stored.
    public var asProfile: SizeProfile {
        var profile = SizeProfile()
        profile.apparel = Set(apparel.compactMap { SizeNormalizer.normalize($0)?.token })
        profile.shoe = Set(shoe.compactMap { SizeNormalizer.normalize($0)?.token })
        profile.includeOneSize = includeOneSize ?? true
        return profile
    }
}

public struct RegisterDevice: Codable, Sendable {
    public var apnsToken: String?
    public var environment: String?
    public var locale: String?
    public var sizes: SizePayload?

    public init(
        apnsToken: String? = nil,
        environment: String? = nil,
        locale: String? = nil,
        sizes: SizePayload? = nil
    ) {
        self.apnsToken = apnsToken
        self.environment = environment
        self.locale = locale
        self.sizes = sizes
    }
}

public struct UpdateDevice: Codable, Sendable {
    public var apnsToken: String?
    /// "production" or "sandbox". Sent on update as well as registration because the
    /// same install can move between them — a debug build and a TestFlight build get
    /// tokens from different APNs environments, and a token is only valid at its own.
    public var environment: String?
    public var sizes: SizePayload?

    public init(apnsToken: String? = nil, environment: String? = nil, sizes: SizePayload? = nil) {
        self.apnsToken = apnsToken
        self.environment = environment
        self.sizes = sizes
    }
}

public struct DiscoverBrand: Codable, Sendable {
    public var url: String
    public var name: String?
    public var instagram: String?

    public init(url: String, name: String? = nil, instagram: String? = nil) {
        self.url = url
        self.name = name
        self.instagram = instagram
    }
}

public struct FollowBrand: Codable, Sendable {
    public var brandID: UUID

    public init(brandID: UUID) {
        self.brandID = brandID
    }
}

// MARK: - Responses

public struct DeviceResponse: Codable, Sendable {
    public var deviceID: UUID
    public var token: String

    public init(deviceID: UUID, token: String) {
        self.deviceID = deviceID
        self.token = token
    }
}

public struct BrandDTO: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID?
    public var name: String
    public var slug: String
    public var website: String?
    public var instagramHandle: String?
    public var currency: String?
    public var lockedForDrop: Bool
    /// The brand's own mark, from the icon its site publishes. Optional so a client can
    /// still decode a response from a server that predates it.
    public var logoURL: String?

    public init(
        id: UUID?,
        name: String,
        slug: String,
        website: String? = nil,
        instagramHandle: String? = nil,
        currency: String? = nil,
        lockedForDrop: Bool = false,
        logoURL: String? = nil
    ) {
        self.id = id
        self.name = name
        self.slug = slug
        self.website = website
        self.instagramHandle = instagramHandle
        self.currency = currency
        self.lockedForDrop = lockedForDrop
        self.logoURL = logoURL
    }
}

/// Result of a dry-run probe: what the server *would* watch, without creating anything.
public struct BrandProbe: Codable, Sendable, Hashable {
    public struct Source: Codable, Sendable, Hashable, Identifiable {
        public var id: String { url }
        public var kind: String
        public var url: String
        public var isAutomatic: Bool

        public init(kind: String, url: String, isAutomatic: Bool) {
            self.kind = kind
            self.url = url
            self.isAutomatic = isAutomatic
        }

        public var label: String {
            BrandSource.Kind(rawValue: kind)?.label ?? kind
        }

        public var symbol: String {
            BrandSource.Kind(rawValue: kind)?.symbol ?? "questionmark"
        }
    }

    public var suggestedName: String?
    public var sources: [Source]

    public init(suggestedName: String?, sources: [Source]) {
        self.suggestedName = suggestedName
        self.sources = sources
    }
}

public struct FeedItem: Codable, Sendable, Hashable, Identifiable {
    public var eventID: UUID
    public var kind: String
    public var createdAt: Date
    public var brandID: UUID
    public var brandName: String
    public var title: String
    public var summary: String?
    public var linkURL: String?
    public var imageURLs: [String]
    public var priceText: String?
    public var isAvailable: Bool?
    /// Sizes that came back in a restock, already narrowed to ones the user wears.
    public var restockedSizes: [String]
    /// Whether anything is currently buyable in the user's sizes — lets the client badge
    /// without shipping every variant down the wire.
    public var availableInMySize: Bool

    public var id: UUID { eventID }

    public var updateKind: UpdateKind { UpdateKind(rawValue: kind) ?? .product }

    public init(
        eventID: UUID,
        kind: String,
        createdAt: Date,
        brandID: UUID,
        brandName: String,
        title: String,
        summary: String? = nil,
        linkURL: String? = nil,
        imageURLs: [String] = [],
        priceText: String? = nil,
        isAvailable: Bool? = nil,
        restockedSizes: [String] = [],
        availableInMySize: Bool = false
    ) {
        self.eventID = eventID
        self.kind = kind
        self.createdAt = createdAt
        self.brandID = brandID
        self.brandName = brandName
        self.title = title
        self.summary = summary
        self.linkURL = linkURL
        self.imageURLs = imageURLs
        self.priceText = priceText
        self.isAvailable = isAvailable
        self.restockedSizes = restockedSizes
        self.availableInMySize = availableInMySize
    }
}

public struct FeedResponse: Codable, Sendable {
    public var items: [FeedItem]
    /// Timestamp of the newest event in this page; pass back as `since` to page forward.
    public var nextCursor: Date?

    public init(items: [FeedItem], nextCursor: Date? = nil) {
        self.items = items
        self.nextCursor = nextCursor
    }
}

public struct StatusResponse: Codable, Sendable {
    public var database: String
    public var environment: String
    public var pollerRunning: Bool
    public var databaseConnected: Bool
    public var databaseError: String?
    public var brands: Int
    public var sources: Int
    public var products: Int
    public var events: Int
    public var devices: Int
    /// Counted separately from `devices` because registration writes `users` first:
    /// if that table is the broken one, every other count still looks healthy.
    public var users: Int
    public var nextPollAt: Date?
    /// Optional so a client can still decode a response from a server that predates
    /// them — the same reason every field added here from now on should be.
    public var apnsConfigured: Bool?
    /// Events written but not yet fanned out. Persistently non-zero means the notifier
    /// is stuck, which is otherwise invisible: polling and the feed both look fine.
    public var pendingPushes: Int?

    public init(
        database: String,
        environment: String,
        pollerRunning: Bool,
        databaseConnected: Bool = false,
        databaseError: String? = nil,
        brands: Int = 0,
        sources: Int = 0,
        products: Int = 0,
        events: Int = 0,
        devices: Int = 0,
        users: Int = 0,
        nextPollAt: Date? = nil,
        apnsConfigured: Bool? = nil,
        pendingPushes: Int? = nil
    ) {
        self.database = database
        self.environment = environment
        self.pollerRunning = pollerRunning
        self.databaseConnected = databaseConnected
        self.databaseError = databaseError
        self.brands = brands
        self.sources = sources
        self.products = products
        self.events = events
        self.devices = devices
        self.users = users
        self.nextPollAt = nextPollAt
        self.apnsConfigured = apnsConfigured
        self.pendingPushes = pendingPushes
    }
}

/// Both sides must agree on date encoding or every `since` cursor silently misbehaves.
public enum APICoding {
    public static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    public static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

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
    /// Always US tokens — `SizeProfile` stores them canonically, whatever scale the user
    /// reads them in, so this needs no scale of its own.
    public var shoe: [String]
    /// Which genders the user wants pushed. Held server-side for the same reason the
    /// sizes are: the server decides whether a drop is news for this person, and it can
    /// only do that if it knows. Optional for back-compatibility.
    public var gender: String?

    public init(apparel: [String], shoe: [String], gender: String? = nil) {
        self.apparel = apparel
        self.shoe = shoe
        self.gender = gender
    }

    public init(_ profile: SizeProfile) {
        self.apparel = Array(profile.apparel)
        self.shoe = Array(profile.shoe)
        self.gender = profile.gender.rawValue
    }

    /// Normalises on the way in, so "medium" and "M" can't both end up stored.
    public var asProfile: SizeProfile {
        var profile = SizeProfile()
        profile.apparel = Set(apparel.compactMap { SizeNormalizer.normalize($0)?.token })
        profile.shoe = Set(shoe.compactMap { SizeNormalizer.normalize($0)?.token })
        profile.gender = gender.flatMap(GenderPreference.init(rawValue:)) ?? .everything
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

/// "Tell me when this comes back", pinned to a size and/or a colour.
///
/// Identified by the product's `externalID` rather than a server UUID because the client
/// knows that string — it is what dedupes the feed — and looking the product up server-
/// side keeps the client from having to hold a second identity for the same thing.
public struct CreateWatch: Codable, Sendable, Hashable {
    public var brandID: UUID
    public var productExternalID: String
    /// Nil means "any size". Raw catalogue text; the server normalises when matching.
    public var size: String?
    /// Nil means "any colour".
    public var color: String?

    public init(brandID: UUID, productExternalID: String, size: String? = nil, color: String? = nil) {
        self.brandID = brandID
        self.productExternalID = productExternalID
        self.size = size
        self.color = color
    }
}

public struct WatchDTO: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    public var brandID: UUID
    public var productExternalID: String
    public var productTitle: String?
    public var size: String?
    public var color: String?
    public var createdAt: Date
    /// Set once it has fired, so a client can show it as satisfied rather than pending.
    public var firedAt: Date?
    public var firedSizes: [String]

    public init(
        id: UUID,
        brandID: UUID,
        productExternalID: String,
        productTitle: String? = nil,
        size: String? = nil,
        color: String? = nil,
        createdAt: Date = Date(),
        firedAt: Date? = nil,
        firedSizes: [String] = []
    ) {
        self.id = id
        self.brandID = brandID
        self.productExternalID = productExternalID
        self.productTitle = productTitle
        self.size = size
        self.color = color
        self.createdAt = createdAt
        self.firedAt = firedAt
        self.firedSizes = firedSizes
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

/// A brand other people follow, with enough to show it without a round trip per card.
public struct PopularBrand: Codable, Sendable, Hashable, Identifiable {
    public var brand: BrandDTO
    /// How many people watch it. A count only — the app never learns who.
    public var followers: Int
    /// A few recent product shots, so a recommendation shows clothes rather than asking
    /// someone to take a wordmark on faith.
    public var previewImageURLs: [String]
    /// What the brand is like, so the *client* can re-rank against a taste profile built
    /// from its own saves — which never leave the phone. Optional so a client can still
    /// decode a response from a server that predates it.
    public var vector: BrandVector?
    /// How close the server judged this to what the user already follows, 0…1. Nil when
    /// they follow nothing yet and the list is pure popularity.
    public var affinity: Double?

    public var id: UUID { brand.id ?? UUID() }

    public init(
        brand: BrandDTO,
        followers: Int,
        previewImageURLs: [String] = [],
        vector: BrandVector? = nil,
        affinity: Double? = nil
    ) {
        self.brand = brand
        self.followers = followers
        self.previewImageURLs = previewImageURLs
        self.vector = vector
        self.affinity = affinity
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
    /// Whether anything is currently buyable in the user's sizes.
    public var availableInMySize: Bool
    /// The product's full variant list.
    ///
    /// This used to be deliberately withheld — the client got `availableInMySize` and was
    /// expected to badge from that alone. It made the whole size feature inert in the mode
    /// the app actually ships in: with no variants, `isAvailable(in:)` returns true for
    /// everything so the "my size" filter matched every item, and the size run had nothing
    /// to print, so the app's signature element rendered as blank space on every product
    /// that wasn't a restock.
    ///
    /// The saving was never real either. A product carries tens of variants, not
    /// thousands — the 25k figure is the whole catalogue across every product — and the
    /// feed page is capped at 200 events.
    ///
    /// Optional so a client can still decode a response from a server that predates it.
    public var variants: [VariantInfo]?
    /// Who the garment is cut for, decided server-side so both platforms agree.
    /// Optional for the same back-compatibility reason.
    public var gender: String?

    public var id: UUID { eventID }

    public var updateKind: UpdateKind { UpdateKind(rawValue: kind) ?? .product }

    /// Never nil: an absent or unrecognised value means we don't know, which is a real
    /// answer and one that is never filtered out.
    public var itemGender: Gender {
        gender.flatMap(Gender.init(rawValue:)) ?? .unknown
    }

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
        availableInMySize: Bool = false,
        variants: [VariantInfo]? = nil,
        gender: String? = nil
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
        self.variants = variants
        self.gender = gender
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
    /// How many of `devices` actually handed over an APNs token.
    ///
    /// Counted separately for the same reason `users` is: `apnsConfigured: true` with a
    /// healthy poller and a filling feed still delivers nothing at all if this is zero,
    /// and nothing else in this response would say so. Zero here means the *app* never
    /// registered for remote notifications — usually a missing `aps-environment`
    /// entitlement — not that the server is misconfigured.
    public var devicesWithToken: Int?

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
        pendingPushes: Int? = nil,
        devicesWithToken: Int? = nil
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
        self.devicesWithToken = devicesWithToken
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

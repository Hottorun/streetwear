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
    /// The waist ladder, which is its own question: a 32 is not an M, no table converts
    /// between them, and a person wears one of each.
    ///
    /// **It was missing from this payload while the column, the migration and the
    /// server-side matching all existed.** So the server stored an empty waist set on
    /// every device update, `claims` answered false for every pair of trousers, and
    /// restock targeting was switched off on denim and workwear — half of what these
    /// brands make. The client recomputes size matching locally from `variants`, so the
    /// screen looked right the whole time and only the notifications were wrong. Someone
    /// who had entered waists and nothing else got no size targeting at all.
    ///
    /// Optional, so a server that predates it still decodes this body.
    public var waist: [String]?
    /// Women's dress sizes, as US tokens — the same canonical form `shoe` travels in, so
    /// `dressScale` stays on the phone. The waist's lesson applied up front: a ladder the
    /// app holds and the payload does not carry is a ladder the server targets alerts
    /// without, while the screen goes on looking right.
    ///
    /// Optional, because the 1.0 app has no dress ladder and sends nothing; absent reads
    /// as empty, and an empty ladder filters nothing.
    public var dress: [String]?
    /// Jacket chests in inches. Optional for the same reason.
    public var suit: [String]?
    /// Jacket lengths, "S", "R" or "L". Optional for the same reason.
    public var suitLength: [String]?
    /// Which genders the user wants pushed. Held server-side for the same reason the
    /// sizes are: the server decides whether a drop is news for this person, and it can
    /// only do that if it knows. Optional for back-compatibility.
    public var gender: String?

    public init(
        apparel: [String],
        shoe: [String],
        waist: [String]? = nil,
        dress: [String]? = nil,
        suit: [String]? = nil,
        suitLength: [String]? = nil,
        gender: String? = nil
    ) {
        self.apparel = apparel
        self.shoe = shoe
        self.waist = waist
        self.dress = dress
        self.suit = suit
        self.suitLength = suitLength
        self.gender = gender
    }

    public init(_ profile: SizeProfile) {
        self.apparel = Array(profile.apparel)
        self.shoe = Array(profile.shoe)
        self.waist = Array(profile.waist)
        self.dress = Array(profile.dress)
        self.suit = Array(profile.suit)
        self.suitLength = Array(profile.suitLength)
        self.gender = profile.gender.rawValue
    }

    /// Normalises on the way in, so "medium" and "M" can't both end up stored.
    public var asProfile: SizeProfile {
        var profile = SizeProfile()
        profile.apparel = Set(apparel.compactMap { SizeNormalizer.normalize($0)?.token })
        profile.shoe = Set(shoe.compactMap { SizeNormalizer.normalize($0)?.token })
        // Absent and empty are the same thing here — an older client simply never had a
        // waist to send — so both leave the ladder empty, and an empty ladder filters
        // nothing rather than hiding everything.
        profile.waist = Set((waist ?? []).compactMap { SizeNormalizer.normalize($0)?.token })
        // Strictly: a token that is not on the ladder is dropped, not kept as `.other`.
        profile.dress = Set((dress ?? []).compactMap(SizeProfile.dressToken))
        profile.suit = Set((suit ?? []).compactMap(SizeProfile.suitToken))
        profile.suitLength = Set((suitLength ?? []).compactMap(SizeProfile.suitLengthToken))
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
    /// How much of the brand should reach this person. Optional, and absent from every body
    /// the 1.0 app sends — which the server reads as `.everything`, the only mode that build
    /// can show. Sent when a follow is *restored* rather than made, so a re-registration
    /// puts a quiet brand back quiet.
    public var mode: FollowMode?

    public init(brandID: UUID, mode: FollowMode? = nil) {
        self.brandID = brandID
        self.mode = mode
    }
}

/// Changes how much of an already-followed brand reaches this person. See `FollowMode`.
public struct UpdateFollow: Codable, Sendable {
    public var mode: FollowMode

    public init(mode: FollowMode) {
        self.mode = mode
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

/// "This brand drops at this moment — poll it harder around then."
///
/// The whole of what a hand-entered date sends to the server. A brand and an instant, and
/// nothing else: not the title, not the note, not which of somebody's several drops this
/// is. See `PollHintPolicy` for everything that constrains it, and `PlannedDrop` for why
/// the calendar itself never leaves the phone.
///
/// There is no window in this type on purpose. How long a hint lasts is the server's
/// decision and is echoed back in `PollHintsResponse` — a client that could name its own
/// window could name a fortnight.
public struct PollHint: Codable, Sendable, Hashable {
    public var brandID: UUID
    public var releaseAt: Date

    public init(brandID: UUID, releaseAt: Date) {
        self.brandID = brandID
        self.releaseAt = releaseAt
    }
}

/// The caller's **whole** set of hints, replacing whatever it held before.
///
/// A replace rather than a create/delete pair, and for the reason `DropReminders.refresh`
/// rewrites the notification centre rather than diffing it: reconciling a set across edits,
/// deletions, brands being unfollowed and a device being offline for a week is a mechanism
/// that can drift, and drift here means the server quietly polling a storefront hard for a
/// drop somebody deleted last month. Sending the whole set costs one small request and
/// cannot drift.
public struct PollHintSync: Codable, Sendable {
    public var hints: [PollHint]

    public init(hints: [PollHint]) {
        self.hints = hints
    }
}

// MARK: - Responses

/// What the server actually took, and what it refused and why.
///
/// Both halves are load-bearing. `accepted` is what the client stores as "already sent", so
/// it can skip the request next time nothing has changed. `rejected` names a reason per
/// brand, because "your hint didn't work" is equally true when you don't follow the brand,
/// when the date has passed, and when you sent too many — three different fixes, the same
/// as `/admin/push-test` reports per device rather than as a count.
public struct PollHintsResponse: Codable, Sendable {
    public struct Rejected: Codable, Sendable, Hashable {
        public var brandID: UUID
        public var reason: PollHintPolicy.Rejection

        public init(brandID: UUID, reason: PollHintPolicy.Rejection) {
            self.brandID = brandID
            self.reason = reason
        }
    }

    public var accepted: [PollHint]
    public var rejected: [Rejected]
    /// The window the server applies, in seconds either side. Echoed so the app can say
    /// what it bought without hard-coding a number that only the server decides.
    public var windowBefore: TimeInterval
    public var windowAfter: TimeInterval

    public init(
        accepted: [PollHint],
        rejected: [Rejected] = [],
        windowBefore: TimeInterval = PollHintPolicy.windowBefore,
        windowAfter: TimeInterval = PollHintPolicy.windowAfter
    ) {
        self.accepted = accepted
        self.rejected = rejected
        self.windowBefore = windowBefore
        self.windowAfter = windowAfter
    }
}

public struct DeviceResponse: Codable, Sendable {
    public var deviceID: UUID
    public var token: String

    public init(deviceID: UUID, token: String) {
        self.deviceID = deviceID
        self.token = token
    }
}

/// How one place a brand is watched is doing, as far as a client needs to know.
///
/// Deliberately *not* `BrandSource`, even though the server holds one of those per row and
/// the client stores an array of them. `fingerprint` and `etag` are the poller's working
/// state — a content hash and a cache validator — and they are meaningless to anybody who
/// is not the thing doing the polling. Sending them would put two fields on the wire that
/// a future client could only misuse.
///
/// What is here is what the two screens that show this actually print: which mechanism,
/// where it points, and whether it is failing.
public struct BrandSourceDTO: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    /// `BrandSource.Kind` raw value. Kept as a string so a server that learns a new source
    /// kind doesn't fail to decode on an older client — it renders as its raw name and is
    /// treated as manual, rather than taking the whole brand list down with it.
    public var kind: String
    public var url: String
    public var enabled: Bool
    public var lastCheckedAt: Date?
    public var lastError: String?
    public var failureCount: Int

    public init(
        id: UUID,
        kind: String,
        url: String,
        enabled: Bool = true,
        lastCheckedAt: Date? = nil,
        lastError: String? = nil,
        failureCount: Int = 0
    ) {
        self.id = id
        self.kind = kind
        self.url = url
        self.enabled = enabled
        self.lastCheckedAt = lastCheckedAt
        self.lastError = lastError
        self.failureCount = failureCount
    }

    public var sourceKind: BrandSource.Kind? { BrandSource.Kind(rawValue: kind) }

    public var label: String { sourceKind?.label ?? kind }

    public var isAutomatic: Bool { sourceKind?.isAutomatic ?? false }
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
    /// Where this brand is watched, and how those are doing.
    ///
    /// Required, not optional. Without it every server-backed brand arrived with an empty
    /// `Brand.sources`, so the brands list printed "NOT WATCHED" against every row the
    /// server was polling perfectly well, the brand page offered "0 SOURCES", and the
    /// empty state claimed the site could not be watched automatically. Three false
    /// statements, and the one place a failing source is visible was blank in the mode the
    /// app actually ships in.
    public var sources: [BrandSourceDTO]
    /// How the caller follows this brand — set by `GET /v1/follows` only, because it is a
    /// fact about one person's follow and not about the brand. Every other route that hands
    /// over a brand leaves it nil, and nil means "not said", never "everything": the client
    /// keeps the mode it already holds rather than resetting a quiet brand because it
    /// happened to reappear in a search result.
    public var followMode: FollowMode?

    public init(
        id: UUID?,
        name: String,
        slug: String,
        website: String? = nil,
        instagramHandle: String? = nil,
        currency: String? = nil,
        lockedForDrop: Bool = false,
        logoURL: String? = nil,
        sources: [BrandSourceDTO] = [],
        followMode: FollowMode? = nil
    ) {
        self.id = id
        self.name = name
        self.slug = slug
        self.website = website
        self.instagramHandle = instagramHandle
        self.currency = currency
        self.lockedForDrop = lockedForDrop
        self.logoURL = logoURL
        self.sources = sources
        self.followMode = followMode
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

    /// Whether this site can be monitored at all — see `DiscoveredSources.canMonitor`.
    ///
    /// Derived rather than sent, so a server too old to know about it still gives an honest
    /// answer from the sources it did send, and the screen never has to guess.
    ///
    /// **The same rule as `DiscoveredSources.canMonitor`, page watch included.** This copy
    /// still excluded a page watch after the server had stopped refusing one, so in the mode
    /// the app ships in, a shop whose only source was its page — Hollister, Subdued — read
    /// "Nothing to watch here" with START WATCHING disabled, for a site the server would
    /// have accepted.
    public var canMonitor: Bool {
        sources.contains(where: \.isAutomatic)
    }

    public init(suggestedName: String?, sources: [Source]) {
        self.suggestedName = suggestedName
        self.sources = sources
    }
}

/// Ask the server to look at a site, without waiting for the answer.
public struct StartBrandCheck: Codable, Sendable {
    public var url: String

    public init(url: String) {
        self.url = url
    }
}

/// "Watch this as soon as you know you can" — sent while the check is still running, or
/// after it has finished.
public struct WatchBrandCheck: Codable, Sendable {
    public var instagram: String?

    public init(instagram: String? = nil) {
        self.instagram = instagram
    }
}

/// Discovery, run off the request.
///
/// **Why the add-brand screen no longer waits on one response.** A site that is not on
/// Shopify costs about thirteen requests at the politeness interval, and the server used to
/// say nothing until all of them had finished — while the app gives up after thirty seconds
/// of silence. subdued.com measured 26.8s from a fast connection, and the screen asked
/// twice (the preview, then the add). So a check is started, answers at once, and is asked
/// again until it settles; the add reuses the preview's result instead of repeating it.
public struct BrandCheck: Codable, Sendable, Hashable, Identifiable {
    public enum Status: String, Codable, Sendable {
        case checking
        /// Something on the site can be watched; `probe` says what.
        case ready
        /// Nothing answered — no catalogue, feed, sitemap or readable page.
        case refused
        /// The server stopped before the check finished, most likely a deploy. Says nothing
        /// about the site, and is worth starting again.
        case interrupted

        /// Lenient on purpose, for the reason `BrandSourceDTO.kind` is a string: a status a
        /// newer server learns must not fail to decode on an older client. Reading it as
        /// interrupted offers a retry, which is the one honest thing to do with an answer
        /// you cannot interpret.
        public init(from decoder: any Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = Status(rawValue: raw) ?? .interrupted
        }
    }

    public var id: UUID
    public var status: Status
    /// What was found. Nil while checking, and when the check was interrupted.
    public var probe: BrandProbe?
    /// The catalogue's brand for this site, once there is one — because somebody already
    /// added it, or because watching this check created it.
    public var brand: BrandDTO?
    /// Whether the caller has asked to watch it. A check is shared by everybody who asks
    /// about the same shop, so this is the one field that is about *you*.
    public var isWatching: Bool

    public init(
        id: UUID,
        status: Status,
        probe: BrandProbe? = nil,
        brand: BrandDTO? = nil,
        isWatching: Bool = false
    ) {
        self.id = id
        self.status = status
        self.probe = probe
        self.brand = brand
        self.isWatching = isWatching
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
    /// The same price as a number.
    ///
    /// **A markdown is a claim about two numbers, and the wire carried one.** The phone had
    /// the "was" as an amount and the "now" only as display text, so every server-backed
    /// markdown had no measurable cut: no "−30%" on any card, and a markdowns list that
    /// could not rank one cut against another in the mode the app ships in. Optional, and
    /// ignored by the 1.0 app.
    public var priceAmount: Double?
    /// What it cost before, on a `.priceDrop`. Both forms, for the same reason the model
    /// keeps both: the string is what a card prints, and only the number can say which of
    /// two markdowns is the better one. Optional throughout — a client older than this
    /// decodes without them, and a server older than this sends none.
    public var previousPriceText: String?
    public var previousPriceAmount: Double?
    /// What the brand says the product cost before it was marked down — its own
    /// compare-at price — beside `priceText`, which is what it costs now. Both describe the
    /// product as it is, not as it was when the event fired, so the pair always agrees.
    ///
    /// Sent for any kind, not only a markdown: a product that went live already discounted
    /// is announced as a drop and still says "−30%". Optional, and ignored by the 1.0 app,
    /// which decodes without it.
    public var originalPriceText: String?
    public var originalPriceAmount: Double?
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
    /// The storefront's own classification of the product, and its merchandising tags.
    ///
    /// Sent because the client does not only *display* these — it classifies on them.
    /// Gender, garment slot and the style profile all read `productType` and `tags`, and
    /// with neither on the wire every server-backed item arrived as a bare title, so a
    /// local re-classification could only ever answer "unknown". That is not academic:
    /// YoungLA files its womenswear as `product_type: "For Her"` and nothing else — the
    /// style number `W2156` is the only other tell and it is not a word — so the moment a
    /// row needed re-deriving, every women's product reappeared in a menswear feed.
    ///
    /// Optional so a response from a server that predates them still decodes.
    public var productType: String?
    public var tags: [String]?
    /// Which revision of `GenderClassifier` produced `gender`.
    ///
    /// The two ends compile the same classifier but deploy on different schedules, so
    /// "the server decides" is only true until one of them moves. Sending the revision
    /// lets a client that is *ahead* notice the verdict is stale and re-derive it from
    /// `productType` and `tags` — the same staleness rule it already applies to its own
    /// stored rows. Absent, or behind, means take the server's word for it.
    public var genderVersion: Int?
    /// What the *product* is, as opposed to what this event is.
    ///
    /// A feed row is keyed by its event — `event:<uuid>` — because one product produces
    /// several over its life: a drop, a markdown, a restock. That is right for the feed and
    /// wrong for everything that wants to know whether two things are the same garment.
    ///
    /// Sharing a link is the case that broke. `SharedSaveImporter` keys a catalogue hit
    /// `shopify:<id>`, the way the local poller keys it, and looked for an existing row
    /// under that key — which a server-backed feed row never has. So sharing something the
    /// app was already showing you minted a second card for it. The dedupe only ever worked
    /// standalone, which is the one mode the app doesn't ship in.
    ///
    /// Nil for an event with no product behind it: a page change, a storefront locking.
    public var productExternalID: String?
    /// For a `.collection`, the products the storefront says are in it.
    ///
    /// Optional because a server that predates it sends nothing, and an older client must
    /// go on decoding — the client falls back to matching a distinctive word from the
    /// title, which is what every release page did before this existed and got wrong.
    public var memberExternalIDs: [String]?

    public var id: UUID { eventID }

    public var updateKind: UpdateKind { UpdateKind(rawValue: kind) ?? .product }

    /// The kind, or nil for one this build has never heard of.
    ///
    /// `updateKind` falls back to `.product`, which is what 1.0 does with an unknown kind —
    /// and it is exactly the misreading `FeedKinds` exists to keep from happening: a row
    /// with no garment behind it drawn as a new product, counted in "N new products" and
    /// handed a drop's lead slot. The server only sends what this build named, so an unknown
    /// kind here is a server bug or a newer server ignoring the request; the merge skips it.
    public var knownKind: UpdateKind? { UpdateKind(rawValue: kind) }

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
        priceAmount: Double? = nil,
        previousPriceText: String? = nil,
        previousPriceAmount: Double? = nil,
        originalPriceText: String? = nil,
        originalPriceAmount: Double? = nil,
        isAvailable: Bool? = nil,
        restockedSizes: [String] = [],
        availableInMySize: Bool = false,
        variants: [VariantInfo]? = nil,
        gender: String? = nil,
        productType: String? = nil,
        tags: [String]? = nil,
        genderVersion: Int? = nil,
        productExternalID: String? = nil,
        memberExternalIDs: [String]? = nil
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
        self.priceAmount = priceAmount
        self.previousPriceText = previousPriceText
        self.previousPriceAmount = previousPriceAmount
        self.originalPriceText = originalPriceText
        self.originalPriceAmount = originalPriceAmount
        self.isAvailable = isAvailable
        self.restockedSizes = restockedSizes
        self.availableInMySize = availableInMySize
        self.variants = variants
        self.gender = gender
        self.productType = productType
        self.tags = tags
        self.genderVersion = genderVersion
        self.productExternalID = productExternalID
        self.memberExternalIDs = memberExternalIDs
    }
}

/// Which kinds of event a client can draw, so the server never sends it one it cannot.
///
/// **1.0 cannot be told about a kind it does not know.** It decodes `FeedItem.kind` as a
/// string and maps anything it does not recognise onto `.product` — so a `.sale` would land
/// as a new product with no photograph, be counted in the spread's "N new products", and,
/// being sudden, take the lead slot reserved for a drop. Nothing would crash; everything
/// would be wrong, on the build that cannot be changed.
///
/// So a client names what it understands in `?kinds=` on `GET /v1/feed` and
/// `GET /v1/brands/:id/feed`, and the server sends only those. A request that names nothing
/// — every request 1.0 makes — gets `legacy`, the seven kinds 1.0 shipped with. A kind added
/// later is therefore invisible to every client until it says it can draw it, and adding one
/// never needs a change here: `understood` is this build's own `UpdateKind.allCases`.
///
/// The filter is applied to the window a read pages through, and the kinds travel inside
/// the continuation, so one read is one set of kinds from its first page to its last.
public enum FeedKinds {
    public static let parameter = "kinds"

    /// What the 1.0 app decodes. Frozen: a kind added after it never joins this list.
    public static let legacy: [UpdateKind] = [
        .product, .restock, .collection, .post, .pageChange, .dropLock, .priceDrop
    ]

    /// This build's whole vocabulary, as the value of `?kinds=`.
    public static var understood: String {
        UpdateKind.allCases.map(\.rawValue).joined(separator: ",")
    }

    /// The kinds a request may be sent, as raw values.
    ///
    /// Only kinds *this* side knows survive — nothing else exists in its tables, and it
    /// bounds the filter whatever a client sends. A request that names none of them is read
    /// as naming nothing, and gets `legacy`.
    public static func accepted(_ raw: String?) -> [String] {
        let named = Set(
            (raw ?? "")
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
        )
        let known = UpdateKind.allCases.map(\.rawValue).filter(named.contains)
        return known.isEmpty ? legacy.map(\.rawValue) : known
    }
}

public struct FeedResponse: Codable, Sendable {
    public var items: [FeedItem]
    /// Timestamp of the newest event the read could see; pass back as `since` on the next
    /// sync. Set on the first page of a read only — a continued page is not progress through
    /// the head of the feed, and nil there means "leave the cursor where it is".
    public var nextCursor: Date?
    /// The rest of this read, when it did not fit in one page. Pass back as `continuation`
    /// and nothing else; nil means the window is complete.
    ///
    /// **Why a sync now takes more than one request.** The first page used to be the whole
    /// answer: newest first, capped at 200, with `nextCursor` its newest event — so whatever
    /// was older than the 200th event fell behind the cursor without ever being sent. A
    /// device that had been away while a busy brand wrote 250 restocks lost every other
    /// brand's news in that window, and the quiet brand's one drop was precisely the row that
    /// went. See `FeedPaging` on the server for the order pages come in and why it is fair
    /// between brands.
    ///
    /// Optional, and ignored by the 1.0 app, which asks once and moves its cursor exactly as
    /// before. Opaque for the reason `DiscoverResponse.nextCursor` is.
    public var continuation: String?

    public init(items: [FeedItem], nextCursor: Date? = nil, continuation: String? = nil) {
        self.items = items
        self.nextCursor = nextCursor
        self.continuation = continuation
    }
}

/// One garment in the discovery feed, from a brand the caller does not follow.
///
/// **Not a `FeedItem`, and the difference is the point.** A feed item is an *event* — a drop,
/// a markdown, a restock — keyed `event:<uuid>`, and it exists because something happened to
/// a product belonging to a brand somebody follows. A discovery card is the product itself,
/// from a brand nobody here has an opinion about, and nothing has happened to it: it is being
/// shown because it might go with clothes the person already owns. Reusing `FeedItem` would
/// mean inventing an event id for a non-event and a `kind` for a non-change, and the first
/// thing the client would do with either is throw it away.
///
/// It carries the brand rather than just a name and an id, because the card is an argument
/// for *following the brand* — the wordmark, the mark, the site and the sources are all on
/// screen, and a second round trip per card in a scrolling feed is not available.
public struct DiscoverCard: Codable, Sendable, Hashable, Identifiable {
    /// The garment, keyed the way the local poller keys it — `shopify:<id>`. This is what
    /// makes a save from the deck land on the row the app may already hold rather than
    /// minting a second card for the same jacket.
    public var productExternalID: String
    /// What this card is *about* — a garment, or a whole release.
    ///
    /// A release is the one thing a brand publishes that is about other things it publishes,
    /// and it is the strongest card the feed has: "DENIM TEARS FW26" is more interesting than
    /// any single garment in it. It arrives as its own row in `/collections.json` with **no
    /// photograph of its own**, which is why `members` exists — a release card is drawn out
    /// of its contents' pictures.
    ///
    /// A string rather than an enum on the wire, so a server that learns a third kind does
    /// not fail to decode on an older client and take the whole page down with it. Optional
    /// for the same reason: a server predating this sends nothing and everything is a
    /// product, which is what it was.
    public var kind: String?
    /// For a release, photographs of the garments in it. Empty for a product card.
    public var members: [String]
    /// How many garments the release was found to contain, which is usually more than
    /// `members` has room for.
    public var memberCount: Int
    /// Who makes it, with its sources.
    ///
    /// Sources travel because **every route that hands over a brand hands over its
    /// sources**: the client stores one `Brand` row whichever route it arrived on, and a
    /// discovery card that is then followed must not overwrite a populated list with an
    /// empty one — which is what put "NOT WATCHED" against every row of the brands list the
    /// last time a route forgot.
    public var brand: BrandDTO
    public var title: String
    /// The storefront's own description, where it publishes one.
    ///
    /// Worth carrying for releases above all: a season's page usually says what the season
    /// *is* ("boiled-wool knits and raw-edge overshirts"), which is the only sentence about a
    /// brand in this whole system that a human actually wrote. Everything else the card says
    /// is derived. Nil is ordinary — most product rows have none — and a card with no blurb
    /// simply prints one less line rather than inventing one.
    public var summary: String?
    /// **Every** photograph, not the lead one.
    ///
    /// The feed sends what a card draws; this sends what a card *chooses from*. Two things
    /// downstream need the rest: the gallery, and the pick of which frame to measure — a
    /// storefront's ordering is a merchandising decision, not a convention, and Stüssy
    /// publishes its packshot fifth. See `ProductShot`.
    public var imageURLs: [String]
    public var linkURL: String?
    public var priceText: String?
    public var priceAmount: Double?
    public var isAvailable: Bool?
    /// The classifier's inputs, for the same reason `FeedItem` carries them: the client does
    /// not merely display these. `GarmentSlot`, `Gender` and the whole of `Pairing` are read
    /// off `productType` and `tags`, and without them a card arrives as a bare title and
    /// every judgement this feed exists to make resolves to "unknown".
    public var productType: String?
    public var tags: [String]
    public var gender: String?
    public var genderVersion: Int?
    public var variants: [VariantInfo]?
    public var publishedAt: Date
    /// A few more of this brand's garments, so one product is not the whole basis for
    /// judging a shop. Already filtered through `PreviewImages.pick`, so no gift cards,
    /// size guides or delivery banners.
    public var spread: [String]
    /// What the brand is like, so the phone can rank against a taste profile built from its
    /// own saves — which never leave the device. Optional: a brand too new to have been
    /// vectorised is still worth showing.
    public var vector: BrandVector?

    /// The product key, not the brand's. Two cards from one brand are two rows.
    public var id: String { productExternalID }

    /// Whether this card announces a release rather than a garment. Never nil: an absent or
    /// unrecognised kind means a product, which is what every card was before releases
    /// existed.
    public var isRelease: Bool { kind == UpdateKind.collection.rawValue }

    /// Never nil: an absent or unrecognised value means we don't know, which is a real
    /// answer and one that is never filtered out.
    public var itemGender: Gender {
        gender.flatMap(Gender.init(rawValue:)) ?? .unknown
    }

    public init(
        productExternalID: String,
        brand: BrandDTO,
        title: String,
        summary: String? = nil,
        kind: String? = nil,
        members: [String] = [],
        memberCount: Int = 0,
        imageURLs: [String] = [],
        linkURL: String? = nil,
        priceText: String? = nil,
        priceAmount: Double? = nil,
        isAvailable: Bool? = nil,
        productType: String? = nil,
        tags: [String] = [],
        gender: String? = nil,
        genderVersion: Int? = nil,
        variants: [VariantInfo]? = nil,
        publishedAt: Date,
        spread: [String] = [],
        vector: BrandVector? = nil
    ) {
        self.productExternalID = productExternalID
        self.brand = brand
        self.title = title
        self.summary = summary
        self.kind = kind
        self.members = members
        self.memberCount = memberCount
        self.imageURLs = imageURLs
        self.linkURL = linkURL
        self.priceText = priceText
        self.priceAmount = priceAmount
        self.isAvailable = isAvailable
        self.productType = productType
        self.tags = tags
        self.gender = gender
        self.genderVersion = genderVersion
        self.variants = variants
        self.publishedAt = publishedAt
        self.spread = spread
        self.vector = vector
    }
}

public struct DiscoverResponse: Codable, Sendable {
    public var cards: [DiscoverCard]
    /// Pass back as `cursor` to page forward.
    ///
    /// Opaque, and deliberately not a bare date the way `FeedResponse.nextCursor` is. That
    /// one pages a *timeline*, where a timestamp is the whole state; this pages a catalogue
    /// ordered by publication with ties everywhere — storefronts stamp a whole drop with one
    /// second, and Represent's 250 newest products carry 154 distinct timestamps. A date
    /// alone would either re-serve a tie or skip past it, so the position is a date **and**
    /// an id, encoded here so no client is tempted to do arithmetic on it.
    ///
    /// Nil means the catalogue is exhausted — and the deck must say so rather than looping.
    public var nextCursor: String?

    public init(cards: [DiscoverCard], nextCursor: String? = nil) {
        self.cards = cards
        self.nextCursor = nextCursor
    }
}

/// Whether a push could reach **this** device.
///
/// Replaces the app reading `/status`, which answered a global question — "does anybody
/// have a token" — to a personal one, and did it from an endpoint that also counts users,
/// names the environment and prints the database error verbatim. Two booleans about the
/// caller are the whole of what Settings needs, and `devicesWithToken == 0` was never the
/// right proxy anyway: it is false the moment one other person registers, while yours is
/// still missing.
public struct DeliveryStatus: Codable, Sendable {
    /// Whether the deployment holds APNs credentials at all.
    public var apnsConfigured: Bool
    /// Whether *this* device has handed over a token.
    public var hasToken: Bool

    public init(apnsConfigured: Bool, hasToken: Bool) {
        self.apnsConfigured = apnsConfigured
        self.hasToken = hasToken
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

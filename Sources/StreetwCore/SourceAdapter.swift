// SourceAdapter.swift
// Turning a watched URL into a list of value-type items the sync engine can diff.
//
// Deliberately *not* here: an Instagram scraper. Instagram doesn't permit aggregating
// arbitrary public profiles, and anything built on undocumented endpoints breaks within
// weeks and risks the account doing the fetching. `BrandSource.Kind.instagram` is a
// link-out only; the automatic signal comes from catalogs, feeds and page watching.

import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// What an adapter produces. A plain value type so fetching stays off the model actor.
public struct FetchedItem: Sendable, Hashable {
    public var externalID: String
    public var title: String
    public var summary: String?
    public var linkURL: URL?
    public var imageURLStrings: [String]
    public var publishedAt: Date
    public var kind: UpdateKind
    public var priceText: String?
    /// The same price as a number, in the shop's own currency.
    ///
    /// `priceText` is formatted for display ("€180") and cannot be compared: a markdown
    /// from 180 to 120 is two different strings and nothing more. Carrying the amount is
    /// what makes a *price drop* detectable, which is the one silent product edit worth
    /// telling someone about.
    public var priceAmount: Double?
    /// An announced start time, when the page explicitly labels one. Nil is the normal
    /// case — most storefronts never publish a machine-readable release time.
    public var releaseDate: Date?
    public var isAvailable: Bool?
    public var tags: [String]
    public var productType: String?
    public var variants: [VariantInfo]

    public init(
        externalID: String,
        title: String,
        summary: String? = nil,
        linkURL: URL? = nil,
        imageURLStrings: [String] = [],
        publishedAt: Date,
        kind: UpdateKind,
        priceText: String? = nil,
        priceAmount: Double? = nil,
        releaseDate: Date? = nil,
        isAvailable: Bool? = nil,
        tags: [String] = [],
        productType: String? = nil,
        variants: [VariantInfo] = []
    ) {
        self.externalID = externalID
        self.title = title
        self.summary = summary
        self.linkURL = linkURL
        self.imageURLStrings = imageURLStrings
        self.publishedAt = publishedAt
        self.kind = kind
        self.priceText = priceText
        self.priceAmount = priceAmount
        self.releaseDate = releaseDate
        self.isAvailable = isAvailable
        self.tags = tags
        self.productType = productType
        self.variants = variants
    }
}

/// The outcome of checking one source once.
public struct FetchResult: Sendable {
    public var items: [FetchedItem]
    /// New content hash for page-watch sources; nil means "don't change what's stored".
    public var fingerprint: String?
    /// Storefront appears locked (password page / 401 / 403) — often a drop is imminent.
    public var isLocked: Bool
    /// Validator to replay as `If-None-Match` next time.
    public var etag: String?
    /// Server answered 304: nothing changed, and `items` is meaningless rather than empty.
    public var notModified: Bool
    /// Storefront currency and display name, when the source can determine them.
    public var shopCurrency: String?
    public var shopName: String?

    public init(
        items: [FetchedItem] = [],
        fingerprint: String? = nil,
        isLocked: Bool = false,
        etag: String? = nil,
        notModified: Bool = false,
        shopCurrency: String? = nil,
        shopName: String? = nil
    ) {
        self.items = items
        self.fingerprint = fingerprint
        self.isLocked = isLocked
        self.etag = etag
        self.notModified = notModified
        self.shopCurrency = shopCurrency
        self.shopName = shopName
    }
}

public enum SourceError: LocalizedError, Equatable {
    case badResponse(Int)
    case notThisKind
    case emptyPayload
    case disallowedByRobots(String)
    /// An edge sat in front of the origin and refused us — a bot challenge, not the
    /// storefront's own answer. Its own case because the fix is completely different from
    /// every other failure here: there is nothing wrong with the source, and nothing a
    /// retry will change.
    case blockedByEdge

    public var errorDescription: String? {
        switch self {
        case .badResponse(let code): "Server returned \(code)"
        case .notThisKind: "Not a supported source"
        case .emptyPayload: "Nothing returned"
        case .disallowedByRobots(let path): "robots.txt disallows \(path)"
        case .blockedByEdge: "Blocked by the site's bot protection"
        }
    }
}

public protocol SourceAdapter: Sendable {
    var kind: BrandSource.Kind { get }
    /// `since` lets paginating adapters stop early instead of walking a whole catalog.
    func fetch(_ source: BrandSource, since: Date?) async throws -> FetchResult
}

public enum SourceAdapters {
    public static func adapter(
        for kind: BrandSource.Kind,
        http: any HTTPFetching = Net.live
    ) -> (any SourceAdapter)? {
        switch kind {
        case .shopify: ShopifySource(http: http)
        case .collections: CollectionsSource(http: http)
        case .sitemap: SitemapSource(http: http)
        case .feed: FeedSource(http: http)
        case .page: PageWatchSource(http: http)
        case .instagram: nil // link-out only, by design
        }
    }
}

// MARK: - HTTP

public struct HTTPResponse: Sendable {
    public var data: Data
    public var status: Int
    public var finalURL: URL?
    public var etag: String?

    public init(data: Data, status: Int, finalURL: URL? = nil, etag: String? = nil) {
        self.data = data
        self.status = status
        self.finalURL = finalURL
        self.etag = etag
    }

    public var notModified: Bool { status == 304 }

    /// Storefronts lock down before a drop; that's a signal, not a failure.
    ///
    /// **A bot wall is not a lock**, and conflating the two was expensive. `yeezy.com`
    /// sits behind a Cloudflare challenge that answers 403 to everything, forever — under
    /// the old rule that read as "drop imminent", so the brand showed permanently locked
    /// *and* the poller's locked cadence hammered it every 60 seconds, against a site that
    /// was already refusing us. A challenge is a failure: we cannot see the storefront, and
    /// the honest report is a failing source that backs off.
    ///
    /// 401 and a redirect to `/password` still mean locked outright — those are Shopify
    /// saying "this store is closed", which is the actual signal. A bare 403 with nothing
    /// challenge-shaped about it is left as a lock, because that is what it meant before
    /// and there is no evidence to the contrary.
    public var isLocked: Bool {
        if isChallenged { return false }
        return status == 401 || status == 403 || finalURL?.path.contains("password") == true
    }

    /// Whether an edge protected the origin from us rather than the origin answering.
    ///
    /// Read off the body, because the status code alone cannot tell a WAF apart from a
    /// storefront: both are 403. The markers here are the interstitials themselves —
    /// Cloudflare's "Just a moment…" challenge, Akamai's reference page, PerimeterX's
    /// block — which are stable, distinctive, and never present on a real product page.
    public var isChallenged: Bool {
        guard status == 403 || status == 429 || status == 503 else { return false }
        guard let text = String(data: data.prefix(4_096), encoding: .utf8)?.lowercased() else {
            return false
        }
        return Self.challengeMarkers.contains { text.contains($0) }
    }

    /// The one place a non-200 becomes an error, so "blocked" can never quietly decay
    /// into a generic bad response at one of five call sites.
    public func requireOK() throws {
        if isChallenged { throw SourceError.blockedByEdge }
        guard status == 200 else { throw SourceError.badResponse(status) }
    }

    private static let challengeMarkers = [
        "just a moment",            // Cloudflare's interstitial title
        "cf-browser-verification",
        "challenge-platform",
        "__cf_chl",
        "cf_chl_opt",
        "attention required",       // Cloudflare block page
        "enable javascript and cookies to continue",
        "access denied",            // Akamai / generic WAF
        "reference #",              // Akamai error reference
        "px-captcha",               // PerimeterX
        "are you a robot",
        "unusual traffic"
    ]
}

/// Seam for tests and for swapping in a server-side client with its own rate limiting.
///
/// Named `HTTPFetching` rather than `HTTPClient` on purpose: Vapor re-exports
/// `AsyncHTTPClient.HTTPClient`, and an unqualified collision in the server target is
/// worse than a slightly wordier name here.
public protocol HTTPFetching: Sendable {
    func get(_ url: URL, etag: String?) async throws -> HTTPResponse
}

public extension HTTPFetching {
    func get(_ url: URL) async throws -> HTTPResponse {
        try await get(url, etag: nil)
    }
}

public struct LiveHTTPFetcher: HTTPFetching {
    private let userAgent: String

    public init(userAgent: String = Net.userAgent) {
        self.userAgent = userAgent
    }

    /// Returns body plus status, without throwing on 4xx — callers care about
    /// 401/403 as a *signal* (drop lock), not only as a failure.
    ///
    /// `etag` is replayed as `If-None-Match`, so unchanged catalogs cost a 304 with an
    /// empty body instead of re-downloading megabytes of JSON on every poll.
    public func get(_ url: URL, etag: String?) async throws -> HTTPResponse {
        var request = URLRequest(url: url)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        if let etag {
            request.setValue(etag, forHTTPHeaderField: "If-None-Match")
        }
        let (data, response) = try await Net.session.data(for: request)
        let http = response as? HTTPURLResponse
        return HTTPResponse(
            data: data,
            status: http?.statusCode ?? 0,
            finalURL: http?.url,
            etag: http?.value(forHTTPHeaderField: "ETag")
        )
    }
}

public enum Net {
    /// Identifies the client honestly and says where to complain. Verified to receive
    /// 200s from the storefronts we actually poll, so there is nothing to gain from
    /// impersonating a browser — and being identifiable is what keeps access.
    public static let userAgent = "streetw/1.0 (+https://github.com/Hottorun/streetwear)"

    public static let live = LiveHTTPFetcher()

    static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 20
        config.requestCachePolicy = .useProtocolCachePolicy
        return URLSession(configuration: config)
    }()

    /// Shared on-disk cache. `AsyncImage` goes through `URLSession.shared`, which by
    /// default has a memory-only cache — product shots were being refetched on every
    /// scroll. Configured once at launch.
    public static func configureSharedCache() {
        let memory = 32 * 1024 * 1024
        let disk = 512 * 1024 * 1024
        // swift-corelibs-foundation's URLCache has no two-argument initialiser; the
        // disk path is required there and absent on Apple platforms.
        #if canImport(FoundationNetworking)
        URLCache.shared = URLCache(memoryCapacity: memory, diskCapacity: disk, diskPath: nil)
        #else
        URLCache.shared = URLCache(memoryCapacity: memory, diskCapacity: disk)
        #endif
    }
}

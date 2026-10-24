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
    /// When the product came into existence, where the source says so.
    ///
    /// Not the same question as `publishedAt`, which is when it was last *put on the
    /// shelf* — storefronts rewrite that on every re-merchandising sweep, so on its own it
    /// reports three-year-old stock as today's newest drop. See `Reshelving`. Nil is normal
    /// and common: only Shopify publishes a creation date.
    public var createdAt: Date?
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
    /// For a `.collection`, the products the storefront says are **in** it.
    ///
    /// `/collections.json` announces a release and does not list it, so which garments
    /// belong to one used to be guessed — a distinctive word from the title, falling back
    /// to whatever published within a day and a half of it. The fallback is what put five
    /// ALWEIZ board shorts and a bag on a page headed ISLAND PUFF PRINT TRUCKER HAT, whose
    /// actual contents are six colourways of that hat. A guess presented as a release's
    /// contents is a statement about stock, and it was wrong on every brand looked at.
    ///
    /// Shopify does publish the membership, at `/collections/<handle>/products.json`, and
    /// that is what this carries — `CollectionsSource` reads it for the few collections a
    /// poll is about to announce. Empty for every other kind, for a storefront that
    /// answered nothing, and for rows written before this existed; `Brand.members(of:)`
    /// keeps the word match for exactly those.
    public var memberExternalIDs: [String]
    /// The source could only guess this is a product, and the page has to say so before
    /// anybody is told.
    ///
    /// Set by `SitemapSource` for a URL that sits in a mixed sitemap with nothing to mark
    /// it — no product path, no photograph, no product-named file. Subdued's categories and
    /// CMS pages look exactly like that, and so do a handful of its products. The server
    /// stores such a row silently and announces it only once `ProductPage` has found a
    /// product on it; standalone, the phone leaves these out.
    public var isTentative: Bool

    public init(
        externalID: String,
        title: String,
        summary: String? = nil,
        linkURL: URL? = nil,
        imageURLStrings: [String] = [],
        publishedAt: Date,
        createdAt: Date? = nil,
        kind: UpdateKind,
        priceText: String? = nil,
        priceAmount: Double? = nil,
        releaseDate: Date? = nil,
        isAvailable: Bool? = nil,
        tags: [String] = [],
        productType: String? = nil,
        variants: [VariantInfo] = [],
        memberExternalIDs: [String] = [],
        isTentative: Bool = false
    ) {
        self.externalID = externalID
        self.title = title
        self.summary = summary
        self.linkURL = linkURL
        self.imageURLStrings = imageURLStrings
        self.publishedAt = publishedAt
        self.createdAt = createdAt
        self.kind = kind
        self.priceText = priceText
        self.priceAmount = priceAmount
        self.releaseDate = releaseDate
        self.isAvailable = isAvailable
        self.tags = tags
        self.productType = productType
        self.variants = variants
        self.memberExternalIDs = memberExternalIDs
        self.isTentative = isTentative
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
    /// Nothing in `items` is news, whatever the caller's own baseline says.
    ///
    /// The callers decide a baseline from their own state — `sources.baselined_at` on the
    /// server, `Brand.lastSyncedAt` on the phone — and for every other adapter that is the
    /// whole answer. A sitemap keeps its own memory of what it has seen (`SitemapMemory`),
    /// and a source that was baselined long before that memory existed has none: its first
    /// read under the new rules would otherwise offer up to `SitemapSource.maxNewItems`
    /// long-listed products as new drops, to everyone following it. Also set when a sitemap
    /// has plainly been rebuilt rather than added to.
    public var isBaseline: Bool

    public init(
        items: [FetchedItem] = [],
        fingerprint: String? = nil,
        isLocked: Bool = false,
        etag: String? = nil,
        notModified: Bool = false,
        shopCurrency: String? = nil,
        shopName: String? = nil,
        isBaseline: Bool = false
    ) {
        self.items = items
        self.fingerprint = fingerprint
        self.isLocked = isLocked
        self.etag = etag
        self.notModified = notModified
        self.shopCurrency = shopCurrency
        self.shopName = shopName
        self.isBaseline = isBaseline
    }
}

public enum SourceError: LocalizedError, Equatable {
    case badResponse(Int)
    case notThisKind
    case emptyPayload
    case disallowedByRobots(String)
    /// This host's politeness queue is already booked past its horizon, so the request was
    /// refused rather than joined to the back of it.
    ///
    /// Its own case because the right answer is unlike every other failure here: nothing is
    /// wrong with the storefront, the request would very likely have worked, and the only
    /// reason it did not run is that somebody else is already queued for that host. A caller
    /// should say "busy, try shortly" rather than "this site could not be read". See
    /// `PoliteFetcher.maxQueueAhead`.
    case hostBusy(String, retryAfter: TimeInterval)
    /// An edge sat in front of the origin and refused us — a bot challenge, not the
    /// storefront's own answer. Its own case because the fix is completely different from
    /// every other failure here: there is nothing wrong with the source, and nothing a
    /// retry will change.
    case blockedByEdge
    /// A UCP business answered and declined, with a reason. Distinct from every other case
    /// because the fault is usually **ours** — an agent profile that failed to resolve, or
    /// a protocol version the merchant does not implement — and those are fixed by changing
    /// this app, not by retrying against the storefront. Folding them into `badResponse`
    /// would hide the one class of failure we can actually do something about.
    case ucp(String)
    /// The URL names an address no storefront lives at — see `HostSafety`.
    ///
    /// Refused by the fetchers themselves rather than only where a person types a URL,
    /// because most URLs this package fetches were never typed by anybody: a sitemap index
    /// names its children, robots.txt names its sitemaps, a page names its next hop. Each of
    /// those is the storefront's word, and the storefront is whoever controls the domain.
    case privateHost(String)

    public var errorDescription: String? {
        switch self {
        case .badResponse(let code): "Server returned \(code)"
        case .notThisKind: "Not a supported source"
        case .emptyPayload: "Nothing returned"
        case .disallowedByRobots(let path): "robots.txt disallows \(path)"
        case .hostBusy(let host, _): "Too many requests queued for \(host) just now"
        case .blockedByEdge: "Blocked by the site's bot protection"
        case .ucp(let reason): "The store's agent endpoint refused: \(reason)"
        case .privateHost(let host): "\(host) is not a public address"
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
        case .ucp: UCPSource(http: http)
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
    /// The `Location` header, verbatim, of a redirect nobody followed yet.
    ///
    /// Carried because redirects are followed by hand now — see `Net.maxRedirects` — and
    /// whoever follows them needs to know where they point.
    public var location: String?

    public init(data: Data, status: Int, finalURL: URL? = nil, etag: String? = nil, location: String? = nil) {
        self.data = data
        self.status = status
        self.finalURL = finalURL
        self.etag = etag
        self.location = location
    }

    public var notModified: Bool { status == 304 }

    /// Where this redirect points, resolved against the URL that answered — nil for anything
    /// that is not one, or that points somewhere a fetch must not go.
    ///
    /// `Location` is routinely relative (Hollister answers `/products.json` with
    /// `/shop/FileNotFoundError?…`), so it is resolved rather than parsed. Only http and
    /// https come back: a `javascript:` or `file:` target is not a page.
    ///
    /// - Parameter keepsMethod: true for a request that is not a GET. Only 307 and 308
    ///   promise to repeat the same method and body; a 301 or 302 after a POST is a browser
    ///   being sent somewhere to *look*, and replaying a JSON-RPC call there means nothing.
    public func redirectTarget(from url: URL, keepsMethod: Bool = false) -> URL? {
        let statuses: Set<Int> = keepsMethod ? [307, 308] : [301, 302, 303, 307, 308]
        guard statuses.contains(status),
              let location = location?.trimmingCharacters(in: .whitespaces), !location.isEmpty,
              let resolved = URL(string: location, relativeTo: url)?.absoluteURL,
              resolved.scheme == "https" || resolved.scheme == "http",
              var components = URLComponents(url: resolved, resolvingAgainstBaseURL: false)
        else { return nil }
        // A fragment never reaches the server, and leaving it on makes two spellings of the
        // same hop look like a new URL to the loop check.
        components.fragment = nil
        return components.url
    }

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

    /// A JSON body sent to an endpoint that answers with one.
    ///
    /// Added for `UCPSource` and nothing else, and deliberately narrow: this is not a
    /// general-purpose request builder. Every catalogue source in this app is a GET,
    /// because every catalogue source *should* be — a poll is a read. UCP is the exception
    /// only because its transport is JSON-RPC, where "read the catalogue" is spelled as a
    /// POST. Nothing here writes anything: `UCPSource` calls `search_catalog` and no other
    /// method, and the cart and checkout tools the same endpoint exposes are never touched.
    ///
    /// `accept` exists because MCP servers negotiate between plain JSON and an event
    /// stream on that header alone, and the ones that default to streaming are unreadable
    /// with the plain decoder here.
    func post(_ url: URL, json body: Data, accept: String) async throws -> HTTPResponse
}

public extension HTTPFetching {
    func get(_ url: URL) async throws -> HTTPResponse {
        try await get(url, etag: nil)
    }

    func post(_ url: URL, json body: Data) async throws -> HTTPResponse {
        try await post(url, json: body, accept: "application/json")
    }
}

public struct LiveHTTPFetcher: HTTPFetching {
    private let userAgent: String
    private let followsRedirects: Bool

    /// - Parameter followsRedirects: false for a fetcher that something else will follow
    ///   redirects *for* — `PoliteFetcher`, which has to see every hop to apply robots.txt
    ///   and the host's spacing to it. See `Net.singleHop`.
    public init(userAgent: String = Net.userAgent, followsRedirects: Bool = true) {
        self.userAgent = userAgent
        self.followsRedirects = followsRedirects
    }

    /// Returns body plus status, without throwing on 4xx — callers care about
    /// 401/403 as a *signal* (drop lock), not only as a failure.
    ///
    /// `etag` is replayed as `If-None-Match`, so unchanged catalogs cost a 304 with an
    /// empty body instead of re-downloading megabytes of JSON on every poll.
    public func get(_ url: URL, etag: String?) async throws -> HTTPResponse {
        try await follow(from: url, keepsMethod: false) { target in
            var request = URLRequest(url: target)
            request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
            if let etag {
                request.setValue(etag, forHTTPHeaderField: "If-None-Match")
            }
            return request
        }
    }

    public func post(_ url: URL, json body: Data, accept: String) async throws -> HTTPResponse {
        try await follow(from: url, keepsMethod: true) { target in
            var request = URLRequest(url: target)
            request.httpMethod = "POST"
            request.httpBody = body
            request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue(accept, forHTTPHeaderField: "Accept")
            return request
        }
    }

    /// One request per hop, every hop checked, at most `Net.maxRedirects` of them.
    ///
    /// The session never follows a redirect itself (`Net.session`), so this is the only
    /// place one is followed here — and the private-address check that used to live in the
    /// session's delegate lives here, on the first URL as well as on every hop after it. A
    /// hop that is refused, loops back or exceeds the limit is returned as the redirect it
    /// was: a 3xx with no body, which every adapter already reads as "nothing here".
    private func follow(
        from url: URL,
        keepsMethod: Bool,
        request build: (URL) -> URLRequest
    ) async throws -> HTTPResponse {
        guard HostSafety.isPublic(url: url) else {
            throw SourceError.privateHost(url.host() ?? url.absoluteString)
        }
        var current = url
        var response = try await send(build(current))
        guard followsRedirects else { return response }

        var visited: Set<String> = [current.absoluteString]
        for _ in 0..<Net.maxRedirects {
            guard let next = response.redirectTarget(from: current, keepsMethod: keepsMethod),
                  HostSafety.isPublic(url: next),
                  visited.insert(next.absoluteString).inserted
            else { break }
            current = next
            response = try await send(build(current))
        }
        return response
    }

    private func send(_ request: URLRequest) async throws -> HTTPResponse {
        let (data, response) = try await Net.session.data(for: request)
        let http = response as? HTTPURLResponse
        return HTTPResponse(
            data: data,
            status: http?.statusCode ?? 0,
            finalURL: http?.url ?? request.url,
            etag: http?.value(forHTTPHeaderField: "ETag"),
            location: http?.value(forHTTPHeaderField: "Location")
        )
    }
}

public enum Net {
    /// Identifies the client honestly and says where to complain. Verified to receive
    /// 200s from the storefronts we actually poll, so there is nothing to gain from
    /// impersonating a browser — and being identifiable is what keeps access.
    public static let userAgent = "Dropwall/1.0 (+https://github.com/Hottorun/streetwear)"

    /// Follows redirects itself, checking each hop's host and nothing else. For one-off
    /// reads on somebody's behalf — a shared link, the product page somebody is looking
    /// at — where there is no politeness budget in play.
    public static let live = LiveHTTPFetcher()

    /// Never follows a redirect: the 3xx comes back with its `Location`, for a caller that
    /// follows it under its own rules. This is what `PoliteFetcher` wraps.
    public static let singleHop = LiveHTTPFetcher(followsRedirects: false)

    /// How many redirects one fetch will follow.
    ///
    /// **Five: the floor RFC 9309 sets for robots.txt, and plenty for a storefront.** An
    /// ordinary chain is two or three — http to https, apex to `www.`, a region. Hollister
    /// answers `/products.json` with a redirect to `/shop/FileNotFoundError` that loops, and
    /// URLSession's own limit meant a long run of unspaced requests to learn nothing.
    public static let maxRedirects = 5

    static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 20
        // **An inactivity timer is not a ceiling.** `timeoutIntervalForRequest` resets on
        // every byte received, so a host that drips one byte a second holds a slot open
        // forever — and the poller runs its sources in sequence, so one such host stalls
        // polling, notifications and retention for everybody. This is the wall-clock bound.
        config.timeoutIntervalForResource = 120
        config.requestCachePolicy = .useProtocolCachePolicy
        return URLSession(configuration: config, delegate: RedirectRefusal(), delegateQueue: nil)
    }()

    /// Hands every redirect back instead of following it.
    ///
    /// **Following was where two checks went missing.** The session used to follow on its
    /// own, re-checking only that each hop's host was public — necessary, because a public
    /// host a stranger controls can answer a 302 pointing at `http://169.254.169.254/…` —
    /// and nothing else. robots.txt was read for the first URL alone and every later hop
    /// went out unspaced: victoriassecret.com redirects to `/gb/`, which its robots.txt
    /// disallows, and Hollister's `/products.json` to `/shop/FileNotFoundError`, which its
    /// robots.txt disallows too. Both were fetched anyway, because nothing asked.
    ///
    /// So the session follows nothing and the fetchers do it by hand: `LiveHTTPFetcher`
    /// with the host check, `PoliteFetcher` with the host check, robots.txt and the
    /// per-host interval on every hop. Returning nil delivers the redirect response itself,
    /// `Location` included. That holds on Linux as well: swift-corelibs-foundation asks the
    /// session's delegate for tasks started by `data(for:)` and treats nil the same way —
    /// read in its source, since no local build can show it.
    private final class RedirectRefusal: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        func urlSession(
            _ session: URLSession,
            task: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest,
            completionHandler: @escaping (URLRequest?) -> Void
        ) {
            completionHandler(nil)
        }
    }

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

import Foundation
import Testing

@testable import StreetwCore

@Suite("Feeds")
struct FeedSourceTests {
    @Test("Parses a real Atom feed into dated entries")
    func parsesAtom() async throws {
        let http = MockHTTPClient()
        http.stub("/blogs/news.atom", fixture: "feed_atom.xml")

        let source = BrandSource(kind: .feed, url: URL(string: "https://example.com/blogs/news.atom")!)
        let result = try await FeedSource(http: http).fetch(source, since: nil)

        #expect(!result.items.isEmpty)
        let item = try #require(result.items.first)
        #expect(!item.title.isEmpty)
        #expect(item.externalID.hasPrefix("feed:"))
        #expect(item.linkURL != nil)
        #expect(item.publishedAt < Date().addingTimeInterval(60))
    }

    @Test("Handles RSS as well as Atom")
    func parsesRSS() async throws {
        let rss = """
        <?xml version="1.0"?>
        <rss version="2.0"><channel>
          <title>Brand</title>
          <item>
            <title>FW26 Collection</title>
            <link>https://example.com/fw26</link>
            <guid>fw26</guid>
            <pubDate>Fri, 31 Jul 2026 22:00:00 +0000</pubDate>
            <description><![CDATA[<img src="https://cdn.example.com/a.jpg">Lookbook]]></description>
          </item>
        </channel></rss>
        """
        let http = MockHTTPClient()
        http.stub("/feed", .init(body: Data(rss.utf8)))

        let source = BrandSource(kind: .feed, url: URL(string: "https://example.com/feed")!)
        let result = try await FeedSource(http: http).fetch(source, since: nil)

        let item = try #require(result.items.first)
        #expect(item.title == "FW26 Collection")
        #expect(item.externalID == "feed:fw26")
        // A season code in the title means a drop, not a blog post.
        #expect(item.kind == .collection)
        // The hero shot is recovered from the description HTML.
        #expect(item.imageURLStrings == ["https://cdn.example.com/a.jpg"])
    }

    @Test("An ordinary post is not mistaken for a collection")
    func plainPost() async throws {
        let rss = """
        <?xml version="1.0"?>
        <rss version="2.0"><channel><item>
          <title>Store hours this weekend</title><link>https://example.com/x</link><guid>x</guid>
        </item></channel></rss>
        """
        let http = MockHTTPClient()
        http.stub("/feed", .init(body: Data(rss.utf8)))
        let source = BrandSource(kind: .feed, url: URL(string: "https://example.com/feed")!)

        let result = try await FeedSource(http: http).fetch(source, since: nil)
        #expect(result.items.first?.kind == .post)
    }

    @Test("An empty feed is an error, not a silent success")
    func emptyFeed() async {
        let http = MockHTTPClient()
        http.stub("/feed", .init(body: Data("<rss><channel/></rss>".utf8)))
        let source = BrandSource(kind: .feed, url: URL(string: "https://example.com/feed")!)

        await #expect(throws: SourceError.self) {
            try await FeedSource(http: http).fetch(source, since: nil)
        }
    }
}

@Suite("Page watching")
struct PageWatchSourceTests {
    private func source(fingerprint: String? = nil) -> BrandSource {
        BrandSource(kind: .page, url: URL(string: "https://example.com/")!, fingerprint: fingerprint)
    }

    private func client(_ html: String) -> MockHTTPClient {
        let http = MockHTTPClient()
        http.stub("/", .init(body: Data(html.utf8)))
        return http
    }

    @Test("First sight of a page is a baseline, not a change")
    func firstSightIsBaseline() async throws {
        let result = try await PageWatchSource(http: client("<html><body>Hello</body></html>"))
            .fetch(source(), since: nil)

        #expect(result.items.isEmpty)
        #expect(result.fingerprint != nil)
    }

    @Test("An unchanged page produces nothing")
    func unchangedPage() async throws {
        let html = "<html><body>Hello</body></html>"
        let first = try await PageWatchSource(http: client(html)).fetch(source(), since: nil)
        let second = try await PageWatchSource(http: client(html))
            .fetch(source(fingerprint: first.fingerprint), since: nil)

        #expect(second.items.isEmpty)
        #expect(second.fingerprint == first.fingerprint)
    }

    @Test("A changed page produces one pageChange")
    func changedPage() async throws {
        let first = try await PageWatchSource(http: client("<html><body>Hello</body></html>"))
            .fetch(source(), since: nil)
        let second = try await PageWatchSource(http: client("<html><body>New drop</body></html>"))
            .fetch(source(fingerprint: first.fingerprint), since: nil)

        #expect(second.items.count == 1)
        #expect(second.items.first?.kind == .pageChange)
        #expect(second.fingerprint != first.fingerprint)
    }

    /// The reason the fingerprint hashes visible text: real pages carry CSRF tokens and
    /// cache-busting ids that change on every load and would fire a false alert each poll.
    @Test("Volatile markup does not count as a change")
    func ignoresVolatileMarkup() {
        let a = """
        <html><head><script>var t="a3f9c21b8e7d4f60";</script><style>.x{}</style></head>
        <body><!-- built 1 --><p>Same words</p></body></html>
        """
        let b = """
        <html><head><script>var t="ffffffffffffffff";</script><style>.y{}</style></head>
        <body><!-- built 2 --><p>Same words</p></body></html>
        """
        #expect(PageWatchSource.fingerprint(of: a) == PageWatchSource.fingerprint(of: b))
    }

    @Test("A password-locked storefront is a drop signal")
    func lockedIsDropSignal() async throws {
        let http = MockHTTPClient()
        http.setDefault(.init(status: 403))

        let result = try await PageWatchSource(http: http).fetch(source(), since: nil)

        #expect(result.isLocked)
        #expect(result.items.first?.kind == .dropLock)
        #expect(result.fingerprint == PageWatchSource.lockedFingerprint)
    }

    @Test("Polling through a drop does not repeat the lock alert")
    func lockDoesNotRepeat() async throws {
        let http = MockHTTPClient()
        http.setDefault(.init(status: 403))
        let locked = source(fingerprint: PageWatchSource.lockedFingerprint)

        let again = try await PageWatchSource(http: http).fetch(locked, since: nil)

        #expect(again.isLocked)
        #expect(again.items.isEmpty, "a lock should fire on the transition, not every poll")
    }

    /// The regression that matters: keying the event on the source alone made a lock a
    /// once-ever occurrence, so the *next* drop would never alert.
    @Test("Re-locking after reopening fires a fresh alert")
    func relockFiresAgain() async throws {
        let openHTTP = MockHTTPClient()
        openHTTP.stub("/", .init(body: Data("<html><body>Shop</body></html>".utf8)))

        // Reopened: fingerprint goes back to a content hash.
        let reopened = try await PageWatchSource(http: openHTTP)
            .fetch(source(fingerprint: PageWatchSource.lockedFingerprint), since: nil)
        #expect(reopened.fingerprint != PageWatchSource.lockedFingerprint)

        let lockedHTTP = MockHTTPClient()
        lockedHTTP.setDefault(.init(status: 403))
        let next = try await PageWatchSource(http: lockedHTTP)
            .fetch(source(fingerprint: reopened.fingerprint), since: nil)

        #expect(next.items.count == 1)
        #expect(next.items.first?.kind == .dropLock)
    }
}

@Suite("Discovery")
struct BrandDiscoveryTests {
    @Test("Normalises whatever the user pastes down to a host", arguments: [
        "kith.com", "https://kith.com", "kith.com/", "https://kith.com/collections/new?page=2"
    ])
    func normalisesURL(raw: String) {
        #expect(BrandDiscovery.normalizedURL(raw)?.absoluteString == "https://kith.com")
    }

    @Test("Rejects nonsense")
    func rejectsJunk() {
        #expect(BrandDiscovery.normalizedURL("") == nil)
        #expect(BrandDiscovery.normalizedURL("   ") == nil)
    }

    @Test("Accepts a handle, a @handle or a profile URL", arguments: [
        "kith", "@kith", "https://instagram.com/kith", "  kith  "
    ])
    func normalisesHandle(raw: String) {
        #expect(BrandDiscovery.normalizedHandle(raw) == "kith")
    }

    @Test("A Shopify store is discovered as a catalog, and Instagram stays link-only")
    func discoversCatalog() async {
        let http = MockHTTPClient()
        http.stub("/products.json?limit=250&page=1", fixture: "shopify_kith.json")
        http.stub("/meta.json", fixture: "shopify_meta.json")

        let found = await BrandDiscovery.discover(
            website: "example.com",
            instagramHandle: "kith",
            http: http
        )

        #expect(found.sources.contains { $0.kind == .shopify })
        let instagram = found.sources.first { $0.kind == .instagram }
        #expect(instagram != nil)
        #expect(instagram?.kind.isAutomatic == false)
        #expect(SourceAdapters.adapter(for: .instagram) == nil)
    }

    @Test("A site with no catalog or feed still gets a page watch")
    func fallsBackToPageWatch() async {
        let http = MockHTTPClient()
        http.setDefault(.init(status: 404))

        let found = await BrandDiscovery.discover(website: "example.com", instagramHandle: nil, http: http)

        #expect(found.sources.map(\.kind) == [.page])
    }
}

@Suite("Backoff")
struct BrandSourceTests {
    @Test("A healthy source is always ready")
    func healthyIsReady() {
        var source = BrandSource.shopify()
        source.lastCheckedAt = Date()
        #expect(source.isReadyToCheck)
    }

    @Test("Failures back off exponentially and cap out")
    func backsOff() {
        let now = Date()
        var source = BrandSource.shopify()
        source.lastCheckedAt = now

        source.failureCount = 1
        #expect(!source.isReadyToCheck(now: now.addingTimeInterval(60)))
        #expect(source.isReadyToCheck(now: now.addingTimeInterval(121)))

        source.failureCount = 5
        #expect(!source.isReadyToCheck(now: now.addingTimeInterval(1_800)))
        #expect(source.isReadyToCheck(now: now.addingTimeInterval(1_921)))

        // Capped at six hours no matter how bad it gets.
        source.failureCount = 99
        #expect(source.isReadyToCheck(now: now.addingTimeInterval(6 * 3600 + 1)))
    }

    /// `Brand.sources` is a Codable array inside SwiftData, and SwiftData decodes those
    /// with an internal `try!` — so a payload written before a field existed crashes the
    /// app on launch rather than failing softly. It shipped that way once, with
    /// `failureCount`. Every operational field must survive being absent.
    @Test("Decodes a payload written before the operational fields existed")
    func decodesLegacyPayload() throws {
        let legacy = """
        {"id":"3F2504E0-4F89-11D3-9A0C-0305E82C3301","kind":"shopify","url":"https://kith.com/products.json"}
        """
        let source = try JSONDecoder().decode(BrandSource.self, from: Data(legacy.utf8))

        #expect(source.kind == .shopify)
        #expect(source.failureCount == 0)
        #expect(source.enabled)
        #expect(source.fingerprint == nil)
        #expect(source.etag == nil)
        #expect(source.isReadyToCheck)
    }

    @Test("A full payload still round-trips")
    func roundTrips() throws {
        var source = BrandSource.shopify()
        source.etag = "W/\"abc\""
        source.fingerprint = "deadbeef"
        source.failureCount = 3
        source.lastError = "timed out"

        let data = try JSONEncoder().encode(source)
        let decoded = try JSONDecoder().decode(BrandSource.self, from: data)

        #expect(decoded == source)
    }
}

@Suite("Brand marks")
struct BrandMarkTests {
    private let base = URL(string: "https://kith.com")!

    @Test("Prefers the apple-touch-icon — the mark the brand chose for a home screen")
    func prefersAppleTouchIcon() {
        let html = """
        <head>
        <link rel="shortcut icon" href="/favicon.ico">
        <link rel="icon" type="image/png" sizes="32x32" href="/icon-32.png">
        <link rel="apple-touch-icon" sizes="180x180" href="/cdn/shop/files/touch.png?v=2">
        </head>
        """
        let found = BrandMark.find(in: html, base: base)
        #expect(found?.absoluteString == "https://kith.com/cdn/shop/files/touch.png?v=2")
    }

    @Test("Falls back to the largest declared icon when there's no apple-touch-icon")
    func largestIconWins() {
        let html = """
        <link rel="icon" sizes="16x16" href="/small.png">
        <link rel="icon" sizes="192x192" href="/large.png">
        """
        #expect(BrandMark.find(in: html, base: base)?.absoluteString == "https://kith.com/large.png")
    }

    /// A mask-icon is a monochrome silhouette for Safari's tab bar and renders as a
    /// black blob wherever a logo is expected.
    @Test("Ignores mask-icon")
    func ignoresMaskIcon() {
        let html = "<link rel=\"mask-icon\" href=\"/safari.svg\" color=\"black\">"
        #expect(BrandMark.find(in: html, base: base) == nil)
    }

    @Test("Handles absolute hrefs, single quotes and unquoted attributes")
    func attributeShapes() {
        let absolute = "<link rel='apple-touch-icon' href='https://cdn.example.com/a.png'>"
        #expect(BrandMark.find(in: absolute, base: base)?.host == "cdn.example.com")

        let unquoted = "<link rel=icon href=/b.png>"
        #expect(BrandMark.find(in: unquoted, base: base)?.absoluteString == "https://kith.com/b.png")
    }

    /// An inlined icon can't be handed to an image loader, so it must not win over a
    /// real file — or be returned at all.
    @Test("Skips data: URIs")
    func skipsDataURIs() {
        let html = #"<link rel="icon" href="data:image/png;base64,iVBORw0KGgo=">"#
        #expect(BrandMark.find(in: html, base: base) == nil)
    }

    @Test("A page declaring nothing falls back to /favicon.ico")
    func fallsBackToFavicon() {
        #expect(BrandMark.find(in: "<head></head>", base: base) == nil)
        #expect(BrandMark.fallback(for: base)?.absoluteString == "https://kith.com/favicon.ico")
    }
}

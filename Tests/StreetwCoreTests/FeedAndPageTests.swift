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

    /// A brand is not one hostname. Palace answers on four, the Brands tab holds one, and
    /// an exact-host check attributed everything shared from the other three to nobody —
    /// a saved card with no wordmark on it.
    @Test("A brand's storefronts are recognised as one brand", arguments: [
        ("https://usa.palaceskateboards.com/products/x", "https://palaceskateboards.com"),
        ("https://eu.palaceskateboards.com/products/x", "https://usa.palaceskateboards.com"),
        ("https://palaceskateboards.com/products/x", "https://www.palaceskateboards.com"),
        ("https://www.bbcicecream.com/products/x", "https://bbcicecream.com"),
        ("https://shop.example.co.uk/products/x", "https://www.example.co.uk")
    ])
    func sameBrandAcrossStorefronts(link: String, brand: String) {
        #expect(BrandDiscovery.isSameBrandHost(URL(string: link), URL(string: brand)))
    }

    /// And two brands are still two brands. A suffix match that reached across
    /// registrable domains would file somebody's save under the wrong label, which is
    /// worse than leaving it unfiled.
    @Test("Different brands are not folded together", arguments: [
        ("https://kith.com/products/x", "https://palaceskateboards.com"),
        ("https://notkith.com/products/x", "https://kith.com"),
        ("https://example.co.uk/products/x", "https://other.co.uk")
    ])
    func differentBrandsStayApart(link: String, brand: String) {
        #expect(!BrandDiscovery.isSameBrandHost(URL(string: link), URL(string: brand)))
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

    /// Palace's shape: the apex runs Hydrogen and knows nothing about `/products.json`,
    /// while the classic origin still serves the whole catalog on `www.`. Probing only
    /// what was typed demoted a full storefront to a sitemap of randomised handles.
    @Test("A catalog served only on www. is still found, and the sources point at it")
    func findsCatalogOnWWW() async {
        let http = MockHTTPClient()
        http.stub(host: "brand.com", "/products.json?limit=250&page=1", .init(status: 404))
        http.stub(host: "www.brand.com", "/products.json?limit=250&page=1", fixture: "shopify_kith.json")
        http.stub(host: "www.brand.com", "/meta.json", fixture: "shopify_meta.json")

        let found = await BrandDiscovery.discover(website: "brand.com", instagramHandle: nil, http: http)
        let shopify = found.sources.first { $0.kind == .shopify }

        #expect(shopify?.url.host() == "www.brand.com")
        // And nothing was demoted to the fallbacks by the apex's 404.
        #expect(!found.sources.contains { $0.kind == .sitemap || $0.kind == .page })
    }

    /// Any *other* subdomain is a decision — a region, usually, with its own currency and
    /// its own catalogue. Swapping someone off it would change every price in their feed.
    @Test("Only www. is tried as an alternate host")
    func onlySwapsWWW() {
        let variant = { (host: String) in
            ShopifySource.wwwVariant(of: URL(string: "https://\(host)")!)?.host()
        }
        #expect(variant("brand.com") == "www.brand.com")
        #expect(variant("www.brand.com") == "brand.com")
        #expect(variant("usa.brand.com") == nil)
        #expect(variant("shop.brand.co.uk") == nil)
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

/// The hostname was never a name. It produced "Usa" for `usa.palaceskateboards.com` and
/// "Bbcicecream" for Billionaire Boys Club — and because the catalog is global, whatever
/// the first person to add a brand accepted is what everyone else inherits.
@Suite("Brand naming")
struct BrandNamingTests {
    @Test("The merchant's own name beats everything")
    func shopNameWins() {
        #expect(
            BrandNaming.pick(
                shopName: "Billionaire Boys Club",
                siteName: "BBC ICECREAM",
                host: "shop.bbcicecream.com"
            ) == "Billionaire Boys Club"
        )
    }

    /// ...but "beats everything" was taken too literally. `/meta.json` really does say
    /// "REPRESENT | US" — the field is what shows in the merchant's tab and their checkout,
    /// where the region matters — and because it outranked every other claim, a brand row
    /// printed a wordmark with a country stapled to it and nothing could correct it.
    @Test("A region tail is stripped from the merchant's own name too")
    func stripsTheTailFromAShopName() {
        // "REPRESENT", not "Represent": a single shouted word is how the brand writes
        // itself and is left alone, exactly as "KITH" and "BAPE" are. Only the "| US" goes.
        #expect(BrandNaming.pick(shopName: "REPRESENT | US", host: "representclo.com") == "REPRESENT")
        #expect(BrandNaming.pick(shopName: "Kith – Official Site", host: "kith.com") == "Kith")
    }

    /// A plain hyphen is deliberately not a separator: splitting on it trades one wrong
    /// name for another.
    @Test("A hyphenated name survives intact")
    func keepsHyphenatedNames() {
        #expect(BrandNaming.pick(shopName: "SNS - SNEAKERSNSTUFF", host: "sneakersnstuff.com")
            == "Sns - Sneakersnstuff")
        #expect(BrandNaming.pick(shopName: "A-COLD-WALL*", host: "a-cold-wall.com") == "A-COLD-WALL*")
    }

    /// Falling back to the whole thing rather than to nothing: a name that is *only* a
    /// generic head still has to produce something to put on a row.
    @Test("A generic head falls back rather than vanishing")
    func neverReturnsNothingForARealName() {
        #expect(BrandNaming.pick(shopName: "Home | Palace", host: "palaceskateboards.com") != nil)
    }

    @Test("og:site_name is read before the title, and either beats the host")
    func readsDeclaredName() {
        let withOG = """
        <head><meta property="og:site_name" content="YoungLA">
        <title>Lifestyle Clothing Brand: Youngla.com</title></head>
        """
        #expect(BrandNaming.declaredName(in: withOG) == "YoungLA")

        // Attribute order is theme-dependent; matching only one shape loses half of them.
        let reversed = #"<meta content="Kith" name="og:site_name">"#
        #expect(BrandNaming.declaredName(in: reversed) == "Kith")
    }

    /// Palace declares no `og:site_name` at all — its title is the whole answer.
    @Test("A title is used once its marketing tail is removed")
    func readsTitle() {
        #expect(BrandNaming.declaredName(in: "<title>PALACE SKATEBOARDS</title>") == "Palace Skateboards")
        #expect(BrandNaming.declaredName(in: "<title>Kith\n &ndash; Homepage</title>") == "Kith")
        #expect(
            BrandNaming.declaredName(in: "<title>Billionaire Boys Club &amp; ICECREAM | US Official Site</title>")
                == "Billionaire Boys Club & ICECREAM"
        )
    }

    /// A brand called "Home" is worse than no suggestion, because the field is pre-filled
    /// and pre-filled fields get accepted.
    @Test("A generic title is refused rather than adopted")
    func refusesGenericTitles() {
        #expect(BrandNaming.declaredName(in: "<title>Home</title>") == nil)
        #expect(BrandNaming.declaredName(in: "<title>Official Site | Some Brand</title>") == nil)
    }

    /// The fallback, and the specific complaint that started this: a region subdomain is
    /// not what the brand is called.
    @Test("The host is the last resort, and drops region and shop subdomains")
    func hostFallback() {
        #expect(BrandNaming.pick(host: "usa.palaceskateboards.com") == "Palaceskateboards")
        #expect(BrandNaming.pick(host: "shop.bbcicecream.com") == "Bbcicecream")
        #expect(BrandNaming.pick(host: "www.kith.com") == "Kith")
        // Two labels left means we've reached the registrable name — no public-suffix
        // list needed, and "brand.co.uk" doesn't lose its brand.
        #expect(BrandNaming.pick(host: "eu.brand.co.uk") == "Brand")
    }

    /// A logotype is not a name to store: every place a brand is drawn sets its own case,
    /// and a stored "PALACE SKATEBOARDS" shouts in all of them.
    @Test("Shouted names are evened out, but a one-word logotype is left alone")
    func evensOutCapitals() {
        #expect(BrandNaming.tidy("PALACE SKATEBOARDS") == "Palace Skateboards")
        #expect(BrandNaming.tidy("KITH") == "KITH")
        #expect(BrandNaming.tidy("  Aimé   Leon Dore ") == "Aimé Leon Dore")
    }
}

/// What a shared link can be turned into. Open Graph gives a bookmark; the storefront's
/// own product endpoint gives something you can put a stock watch on.
@Suite("A single product from its page")
struct SingleProductTests {
    @Test("A product handle is recognised whatever the link carries")
    func findsHandle() {
        func handle(_ raw: String) -> String? {
            ShopifySource.productHandle(in: URL(string: raw)!)
        }
        #expect(handle("https://kith.com/products/box-logo-hoodie") == "box-logo-hoodie")
        // Share sheets hand over links with tracking and variant parameters attached.
        #expect(handle("https://kith.com/products/box-logo-hoodie?variant=42&utm_source=x") == "box-logo-hoodie")
        #expect(handle("https://kith.com/collections/new/products/tee") == "tee")
        // Not a product page: the caller falls back to Open Graph rather than guessing.
        #expect(handle("https://kith.com/collections/new") == nil)
        #expect(handle("https://kith.com/products/") == nil)
        #expect(handle("https://someblog.com/posts/kith-review") == nil)
    }

    /// The whole reason this uses `.js` and not the `.json` beside it.
    @Test("Variants come back with their stock, and prices out of minor units")
    func readsVariantsAndStock() async {
        let http = MockHTTPClient()
        http.stub("/products/box-logo-hoodie.js", .init(body: Data("""
        {"id": 9, "title": "Box Logo Hoodie", "handle": "box-logo-hoodie",
         "tags": ["mens"], "type": "Hoodies",
         "images": ["//cdn.shopify.com/hoodie-1.jpg"],
         "options": [{"name": "Size", "position": 1}],
         "variants": [
           {"id": 1, "title": "S", "available": false, "price": 22000, "option1": "S"},
           {"id": 2, "title": "M", "available": true,  "price": 22000, "option1": "M"}
         ]}
        """.utf8)))
        http.stub("/meta.json", .init(body: Data(#"{"name": "Kith", "currency": "USD"}"#.utf8)))

        let item = await ShopifySource.product(
            at: URL(string: "https://kith.com/products/box-logo-hoodie?variant=2")!,
            http: http
        )
        let found = try? #require(item)

        #expect(found?.title == "Box Logo Hoodie")
        #expect(found?.variants.count == 2)
        #expect(found?.variants.first { $0.size == "S" }?.available == false)
        #expect(found?.variants.first { $0.size == "M" }?.available == true)
        // 22000 minor units is $220, not $22,000.
        #expect(found?.priceAmount == 220)
        // A protocol-relative CDN path is not something an image loader can open.
        #expect(found?.imageURLStrings == ["https://cdn.shopify.com/hoodie-1.jpg"])
        // Keyed the way the poller keys it, so a link shared for a followed brand lands
        // on the row that already exists.
        #expect(found?.externalID == "shopify:9")
        // The variant parameter must not survive into the stored link.
        #expect(found?.linkURL?.absoluteString == "https://kith.com/products/box-logo-hoodie")
    }

    @Test("Anything that isn't a Shopify product page returns nil rather than failing")
    func fallsBack() async {
        let http = MockHTTPClient()   // everything 404s
        let item = await ShopifySource.product(
            at: URL(string: "https://someblog.com/posts/review")!,
            http: http
        )
        #expect(item == nil)
    }

    /// Palace does exactly this on all three of its hosts: `.js` is 404, the catalogue is
    /// fine. Falling through to Open Graph lost the size run and — the part that matters —
    /// the stock, so a sold-out share was never offered a watch.
    @Test("A storefront that doesn't serve .js is read out of the catalogue instead")
    func fallsBackToTheCatalogue() async {
        let http = MockHTTPClient()
        http.stub("/products/hairy-beanie.js", .init(status: 404))
        http.stub("/products.json?limit=250&page=1", .init(body: Data("""
        {"products": [
          {"id": 91, "title": "Too Hairy Beanie", "handle": "hairy-beanie",
           "product_type": "Headwear", "tags": ["accessories"],
           "images": [{"src": "https://cdn.shopify.com/beanie.jpg"}],
           "options": [{"name": "Size", "position": 1}],
           "variants": [{"id": 5, "title": "OS", "available": false, "price": "48.00", "option1": "OS"}]}
        ]}
        """.utf8)))
        http.stub("/meta.json", .init(body: Data(#"{"name": "Palace", "currency": "GBP"}"#.utf8)))

        let item = await ShopifySource.product(
            at: URL(string: "https://palaceskateboards.com/products/hairy-beanie")!,
            http: http
        )
        let found = try? #require(item)

        #expect(found?.title == "Too Hairy Beanie")
        // The whole point: stock survives the fallback, so the watch can be offered.
        #expect(found?.isAvailable == false)
        #expect(found?.variants.first?.available == false)
        #expect(found?.variants.first?.size == "OS")
        // Still keyed like the poller's, so a re-share lands on the existing row.
        #expect(found?.externalID == "shopify:91")
    }

    /// The listing is newest first and this runs while somebody waits for their share to
    /// land, so it must not walk an entire catalogue looking for a handle that isn't there.
    @Test("The catalogue search is bounded rather than paging a whole store")
    func stopsPagingTheCatalogue() async {
        let http = MockHTTPClient()
        // A full page every time, never containing the handle — the worst case.
        let page = Data("""
        {"products": [
          {"id": 1, "title": "Something Else", "handle": "something-else",
           "variants": [{"id": 1, "title": "OS", "available": true, "price": "10.00"}]}
        ]}
        """.utf8)
        for index in 1...(ShopifySource.maxListedPages + 3) {
            http.stub("/products.json?limit=250&page=\(index)", .init(body: page))
        }

        let item = await ShopifySource.product(
            at: URL(string: "https://palaceskateboards.com/products/never-listed")!,
            http: http
        )
        #expect(item == nil)

        // A short page ends the walk immediately, so only the first is ever fetched here.
        let pages = http.requestedKeys.filter { $0.hasPrefix("/products.json") }
        #expect(pages.count <= ShopifySource.maxListedPages * 2)
        #expect(!http.requestedKeys.contains("/products.json?limit=250&page=\(ShopifySource.maxListedPages + 1)"))
    }
}

/// Availability out of a page's own metadata — the fallback for a shared link that isn't
/// a Shopify product.
@Suite("Declared availability")
struct AvailabilityTests {
    @Test("schema.org's vocabulary, in the forms storefronts actually write it")
    func readsAvailability() {
        for sold in ["OutOfStock", "https://schema.org/OutOfStock", "out of stock", "sold_out"] {
            #expect(PageMetadataParser.availability(from: sold) == false, "\(sold)")
        }
        for stocked in ["InStock", "http://schema.org/InStock", "in stock", "PreOrder"] {
            #expect(PageMetadataParser.availability(from: stocked) == true, "\(stocked)")
        }
    }

    /// Nil is a third answer and has to stay one. Presenting an unlabelled page as sold
    /// out means an unprompted "want to be notified?" about something you could just buy.
    @Test("An unrecognised value is unknown, not available")
    func unknownStaysUnknown() {
        #expect(PageMetadataParser.availability(from: "") == nil)
        #expect(PageMetadataParser.availability(from: "LimitedTimeOffer") == nil)
    }
}

/// Telling "the storefront closed itself" apart from "an edge refused us". They arrive as
/// the same status code and mean opposite things.
@Suite("Locks and bot walls")
struct LockDetectionTests {
    private func response(_ status: Int, _ body: String = "", finalURL: String = "https://brand.com/") -> HTTPResponse {
        HTTPResponse(data: Data(body.utf8), status: status, finalURL: URL(string: finalURL)!)
    }

    /// The Yeezy case, exactly. A permanent Cloudflare challenge read as "drop imminent",
    /// so the brand showed locked forever — and the locked cadence is 60 seconds, so the
    /// poller hammered a site that was already refusing it.
    @Test("A Cloudflare challenge is a failure, not a drop lock")
    func challengeIsNotALock() {
        let challenge = response(403, """
        <!DOCTYPE html><html><head><title>Just a moment...</title>
        <script src="/cdn-cgi/challenge-platform/h/b/orchestrate/chl_page"></script>
        """)
        #expect(challenge.isChallenged)
        #expect(!challenge.isLocked)
        #expect(throws: SourceError.blockedByEdge) { try challenge.requireOK() }
    }

    @Test("A storefront that closed itself is still a lock")
    func realLocksSurvive() {
        #expect(response(401).isLocked)
        #expect(response(302, finalURL: "https://brand.com/password").isLocked)
        // A bare 403 with nothing challenge-shaped about it keeps its old meaning; there
        // is no evidence it was ever wrong.
        #expect(response(403, "<html><body>Forbidden</body></html>").isLocked)
    }

    @Test("A normal page is neither")
    func normalPage() {
        let ok = response(200, "<html><body>Shop</body></html>")
        #expect(!ok.isLocked)
        #expect(!ok.isChallenged)
        #expect(throws: Never.self) { try ok.requireOK() }
    }

    /// The Phase London shape: a storefront that answers 200 while its own markup says
    /// you are being turned away. Status-code checking cannot see this at all.
    @Test("Locksmith's own verdict is read out of the markup")
    func readsLocksmith() {
        let locked = #"<script type="application/vnd.locksmith+json" data-locksmith>{"version":"v324","locked":true,"access_granted":false,"access_denied":true,"scope":"index"}</script>"#
        #expect(StorefrontLock.locksmithVerdict(in: locked) == true)
        #expect(StorefrontLock.isLocked(html: locked))

        let open = #"<script type="application/vnd.locksmith+json" data-locksmith>{"version":"v324","locked":false,"initialized":true,"scope":"index","access_granted":true,"access_denied":false}</script>"#
        #expect(StorefrontLock.locksmithVerdict(in: open) == false)
        #expect(!StorefrontLock.isLocked(html: open))

        // Locked, but you hold a key — which is open, for you.
        let granted = #"<script type="application/vnd.locksmith+json">{"locked":true,"access_granted":true,"access_denied":false}</script>"#
        #expect(StorefrontLock.locksmithVerdict(in: granted) == false)

        // No Locksmith at all is *unknown*, not "open" — which is why it isn't a Bool.
        #expect(StorefrontLock.locksmithVerdict(in: "<html><body>Shop</body></html>") == nil)
    }

    /// "password" on its own appears in the markup of plenty of open stores — a login
    /// form, an account link — so one marker is never enough.
    @Test("A password page needs two markers, not one")
    func passwordPage() {
        #expect(StorefrontLock.isLocked(html: #"<form action="/password" class="password-page__form">"#))
        #expect(!StorefrontLock.isLocked(html: #"<a href="/account/login">Forgot your password?</a>"#))
        #expect(!StorefrontLock.isLocked(html: #"<form action="/password">"#))
    }

    @Test("A page that admits it is locked reports a lock even on a 200")
    func pageWatchReadsDeclaredLock() async throws {
        let http = MockHTTPClient()
        http.stub("/", .init(body: Data(#"""
        <html><head><script type="application/vnd.locksmith+json">{"locked":true,"access_denied":true}</script></head>
        <body>Back soon</body></html>
        """#.utf8)))

        let source = BrandSource(kind: .page, url: URL(string: "https://brand.com/")!)
        let result = try await PageWatchSource(http: http).fetch(source, since: nil)

        #expect(result.isLocked)
        #expect(result.items.first?.kind == .dropLock)
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

    /// Nearly every Shopify storefront declares only a 32×32 favicon, which is a blur at
    /// 44pt on a 3× screen. Both brands measured against ship exactly that.
    @Test("Asks Shopify's CDN for a bigger rendition")
    func upscalesShopifyIcons() {
        let html = """
        <link rel="icon" href="//kith.com/cdn/shop/files/favicon3_32x32.png?v=161&width=32&height=32">
        """
        let found = try? #require(BrandMark.find(in: html, base: base))
        #expect(found?.query?.contains("width=180") == true)
        #expect(found?.query?.contains("height=180") == true)
        // The cache-busting version must survive, or the CDN serves a different asset.
        #expect(found?.query?.contains("v=161") == true)
    }

    @Test("A URL with no size parameters is served at its natural size and left alone")
    func leavesUnsizedURLsAlone() {
        let url = URL(string: "https://kith.com/cdn/shop/files/logo.png?v=1")!
        #expect(BrandMark.upscaled(url) == url)

        let offCDN = URL(string: "https://example.com/icon.png?width=32")!
        #expect(BrandMark.upscaled(offCDN) == offCDN)
    }

    @Test("A page declaring nothing falls back to /favicon.ico")
    func fallsBackToFavicon() {
        #expect(BrandMark.find(in: "<head></head>", base: base) == nil)
        #expect(BrandMark.fallback(for: base)?.absoluteString == "https://kith.com/favicon.ico")
    }
}

@Suite("Page metadata")
struct PageMetadataTests {
    private let base = URL(string: "https://kith.com/products/hoodie")!

    @Test("Reads the Open Graph a storefront already publishes")
    func readsOpenGraph() {
        let html = """
        <head>
        <title>Kith Box Logo Hoodie | Kith</title>
        <meta property="og:title" content="Kith Box Logo Hoodie">
        <meta property="og:site_name" content="Kith">
        <meta property="og:image" content="//cdn.shopify.com/s/files/hoodie.jpg?v=1">
        <meta property="og:price:amount" content="180.00">
        <meta property="og:price:currency" content="USD">
        <link rel="canonical" href="https://kith.com/products/hoodie">
        </head>
        """
        let meta = PageMetadataParser.parse(html, base: base)

        #expect(meta.title == "Kith Box Logo Hoodie")
        #expect(meta.siteName == "Kith")
        #expect(meta.imageURL?.absoluteString == "https://cdn.shopify.com/s/files/hoodie.jpg?v=1")
        #expect(meta.price == "180.00 USD")
        #expect(meta.canonicalURL?.absoluteString == "https://kith.com/products/hoodie")
    }

    /// Plenty of sites ship Twitter cards and no Open Graph.
    @Test("Falls back to Twitter cards, then to <title>")
    func fallsBack() {
        let twitter = """
        <meta name="twitter:title" content="Coaches Jacket">
        <meta name="twitter:image" content="https://cdn.example.com/j.jpg">
        """
        let meta = PageMetadataParser.parse(twitter, base: base)
        #expect(meta.title == "Coaches Jacket")
        #expect(meta.imageURL?.host == "cdn.example.com")

        let bare = "<html><head><title>  Just A Title  </title></head></html>"
        #expect(PageMetadataParser.parse(bare, base: base).title == "Just A Title")
    }

    /// Titles arrive HTML-escaped far more often than not, and "&amp;" on a saved card
    /// is the kind of detail that makes an archive look broken.
    @Test("Decodes HTML entities in titles")
    func decodesEntities() {
        let html = #"<meta property="og:title" content="Ronnie Fieg &amp; Clarks &#8211; 8th St.">"#
        #expect(PageMetadataParser.parse(html, base: base).title == "Ronnie Fieg & Clarks – 8th St.")
    }

    @Test("A page with no metadata at all yields nothing rather than junk")
    func emptyPage() {
        let meta = PageMetadataParser.parse("<html><body>hello</body></html>", base: base)
        #expect(meta.isEmpty)
        #expect(meta.imageURL == nil)
    }

    @Test("Ignores a data: URI image, which no image loader can use")
    func skipsDataURIImages() {
        let html = #"<meta property="og:image" content="data:image/png;base64,iVBOR">"#
        #expect(PageMetadataParser.parse(html, base: base).imageURL == nil)
    }
}

@Suite("Drop cadence")
struct DropCadenceTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    /// Builds `count` weekly drops at a fixed weekday and hour, walking backwards.
    private func weekly(from now: Date, count: Int, hour: Int, perDrop: Int = 1) -> [Date] {
        (0..<count).flatMap { week -> [Date] in
            let day = calendar.date(byAdding: .day, value: -7 * week, to: now)!
            let start = calendar.date(bySettingHour: hour, minute: 0, second: 0, of: day)!
            // Several products published minutes apart is one drop, not several.
            return (0..<perDrop).map { start.addingTimeInterval(Double($0) * 60) }
        }
    }

    @Test("A weekly brand reads as a weekly brand")
    func findsWeeklyRhythm() throws {
        let now = calendar.date(from: DateComponents(year: 2026, month: 8, day: 6, hour: 18))!
        let cadence = try #require(
            DropCadenceEstimator.estimate(from: weekly(from: now, count: 10, hour: 11), now: now, calendar: calendar)
        )

        #expect(cadence.weekday == calendar.component(.weekday, from: now))
        #expect(cadence.hour == 11)
        #expect(cadence.confidence == 1.0)
        #expect(cadence.isReliable)
    }

    /// The rule that stops one big collection deciding the answer: a brand publishing
    /// 60 items on a single morning has dropped once.
    @Test("A single large collection counts as one drop, not sixty")
    func collapsesBurstsToOneDrop() {
        let now = calendar.date(from: DateComponents(year: 2026, month: 8, day: 6, hour: 18))!
        // 60 products on one day, plus six ordinary weekly drops on another weekday.
        let burstDay = calendar.date(byAdding: .day, value: -1, to: now)!
        let burst = (0..<60).map { burstDay.addingTimeInterval(Double($0) * 60) }
        let regular = weekly(from: now, count: 6, hour: 11)

        let cadence = DropCadenceEstimator.estimate(from: burst + regular, now: now, calendar: calendar)

        // The weekly weekday wins on *days*, even though the burst has ten times the rows.
        #expect(cadence?.weekday == calendar.component(.weekday, from: now))
    }

    /// The window the poller drops to a one-minute cadence inside.
    ///
    /// The bug it exists for: a brand that drops weekly is "quiet for a week" right up until
    /// the moment it isn't, so the source sat on the two-hour schedule at exactly the minute
    /// it mattered and the notification arrived an hour or more after the drop.
    @Test("A weekly brand is polled hard only around its own release hour")
    func recognisesItsOwnDropWindow() throws {
        let now = calendar.date(from: DateComponents(year: 2026, month: 8, day: 6, hour: 18))!
        let cadence = try #require(
            DropCadenceEstimator.estimate(from: weekly(from: now, count: 10, hour: 11), now: now, calendar: calendar)
        )

        func thursday(hour: Int, minute: Int = 0) -> Date {
            calendar.date(from: DateComponents(year: 2026, month: 8, day: 6, hour: hour, minute: minute))!
        }

        // Early, because the point of the window is to be there before it happens.
        #expect(cadence.isWithinWindow(thursday(hour: 10, minute: 15), calendar: calendar))
        #expect(cadence.isWithinWindow(thursday(hour: 11), calendar: calendar))
        // A release staggers, so the window outlasts the hour.
        #expect(cadence.isWithinWindow(thursday(hour: 13), calendar: calendar))

        // ...and nowhere else, or this would just be polling everything harder.
        #expect(!cadence.isWithinWindow(thursday(hour: 8), calendar: calendar))
        #expect(!cadence.isWithinWindow(thursday(hour: 18), calendar: calendar))
        let wednesday = calendar.date(from: DateComponents(year: 2026, month: 8, day: 5, hour: 11))!
        #expect(!cadence.isWithinWindow(wednesday, calendar: calendar))
    }

    /// A rhythm nobody should plan around must not spend request budget either.
    @Test("An unreliable rhythm has no window")
    func unreliableCadenceNeverOpensTheWindow() {
        let vague = DropCadence(weekday: 5, hour: 11, confidence: 0.2, sampleSize: 20)
        #expect(!vague.isReliable)
        let thursdayAtEleven = calendar.date(from: DateComponents(year: 2026, month: 8, day: 6, hour: 11))!
        #expect(!vague.isWithinWindow(thursdayAtEleven, calendar: calendar))
    }

    @Test("Too little history yields no claim at all")
    func refusesToGuess() {
        let now = Date()
        #expect(DropCadenceEstimator.estimate(from: [], now: now) == nil)
        #expect(DropCadenceEstimator.estimate(from: weekly(from: now, count: 3, hour: 10), now: now) == nil)
    }

    /// A scattered brand has a mode, but not one worth telling anyone to plan around.
    @Test("A brand with no rhythm is reported as unreliable")
    func scatteredIsUnreliable() throws {
        let now = calendar.date(from: DateComponents(year: 2026, month: 8, day: 6, hour: 12))!
        let scattered = (0..<14).map { calendar.date(byAdding: .day, value: -$0 * 3, to: now)! }

        let cadence = try #require(DropCadenceEstimator.estimate(from: scattered, now: now, calendar: calendar))
        #expect(!cadence.isReliable, "every third day hits each weekday about equally")
    }

    /// Behaviour from two years ago should not describe a brand today.
    @Test("Only recent history counts")
    func ignoresAncientHistory() {
        let now = calendar.date(from: DateComponents(year: 2026, month: 8, day: 6, hour: 12))!
        let ancient = (0..<40).map { calendar.date(byAdding: .day, value: -400 - $0 * 7, to: now)! }
        #expect(DropCadenceEstimator.estimate(from: ancient, now: now, calendar: calendar) == nil)
    }

    @Test("The next occurrence is always in the future")
    func nextOccurrenceIsAhead() throws {
        let cadence = DropCadence(weekday: 5, hour: 11, confidence: 0.9, sampleSize: 10)
        let next = try #require(cadence.nextOccurrence(after: Date()))
        #expect(next > Date())
        #expect(Calendar.current.component(.weekday, from: next) == 5)
    }
}

@Suite("Colour naming")
struct ColorNamerTests {
    private func name(_ hex: Int) -> String {
        ColorNamer.name(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        ).name
    }

    /// The colours most of a streetwear wardrobe actually is.
    @Test("Names the achromatic range the way a person would")
    func achromatic() {
        #expect(name(0x000000) == "Black")
        #expect(name(0x1C1C1E) == "Charcoal")
        #expect(name(0x808080) == "Grey")
        #expect(name(0xFFFFFF) == "White")
        // Off-white with a warm cast is "cream", not "white" — half a rail is one or
        // the other and calling both white loses the distinction that matters.
        #expect(name(0xF5EFE0) == "Cream")
    }

    @Test("Distinguishes a dark blue from a blue")
    func bluesSplitByBrightness() {
        #expect(name(0x0A1A3F) == "Navy")
        #expect(name(0x3B82F6) == "Blue")
    }

    /// The band where most outerwear and footwear lands, and the messiest in the space.
    @Test("Separates brown, tan and orange")
    func warmBand() {
        #expect(name(0x4A2F1B) == "Brown")
        #expect(name(0xD2B48C) == "Tan")
        #expect(name(0xF97316) == "Orange")
    }

    @Test("Names the greens streetwear actually uses")
    func greens() {
        #expect(name(0x556B2F) == "Olive")
        #expect(name(0x1B4D2E) == "Forest")
        #expect(name(0x22C55E) == "Green")
    }

    @Test("A dark red is burgundy, not red")
    func darkRed() {
        #expect(name(0x5C0A1E) == "Burgundy")
        #expect(name(0xEF4444) == "Red")
    }

    /// Product shots are overwhelmingly on white or black sweeps; counting those pixels
    /// would make every single profile say "White".
    @Test("Recognises the seamless backdrop so it can be excluded")
    func backdropDetection() {
        #expect(ColorNamer.isLikelyBackdrop(red: 1, green: 1, blue: 1))
        #expect(ColorNamer.isLikelyBackdrop(red: 0.98, green: 0.98, blue: 0.97))
        #expect(ColorNamer.isLikelyBackdrop(red: 0.01, green: 0.01, blue: 0.01))
        // A garment, even a pale one, is not a backdrop.
        #expect(!ColorNamer.isLikelyBackdrop(red: 0.86, green: 0.80, blue: 0.62))
        #expect(!ColorNamer.isLikelyBackdrop(red: 0.2, green: 0.3, blue: 0.6))
    }

    @Test("Confidence is lower for washed-out colours than for saturated ones")
    func confidenceTracksSaturation() {
        let vivid = ColorNamer.name(red: 0.94, green: 0.27, blue: 0.27)
        let washed = ColorNamer.name(red: 0.7, green: 0.55, blue: 0.55)
        #expect(vivid.confidence > washed.confidence)
    }
}

@Suite("Price changes")
struct PriceChangeTests {
    @Test("A real markdown counts")
    func markdown() {
        #expect(PriceChange.isDrop(from: 180, to: 120))
        #expect(PriceChange.dropPercentage(from: 180, to: 120) == 33)
    }

    /// Multi-currency storefronts recompute from an exchange rate several times a day.
    /// Treating that as a sale would fill the feed with noise and bury the real 30% off.
    @Test("Exchange-rate drift and rounding do not")
    func ignoresNoise() {
        #expect(!PriceChange.isDrop(from: 180, to: 179.5))
        #expect(!PriceChange.isDrop(from: 180, to: 172))   // 4.4%, under the threshold
        #expect(PriceChange.isDrop(from: 180, to: 171))    // 5%, exactly at it
    }

    @Test("A price going up is never an event")
    func ignoresIncreases() {
        #expect(!PriceChange.isDrop(from: 120, to: 180))
        #expect(PriceChange.dropPercentage(from: 120, to: 180) == nil)
    }

    /// A product seen for the first time has nothing to compare against, and a missing
    /// amount must never read as "dropped to free".
    @Test("Missing or nonsense amounts are not drops")
    func handlesMissing() {
        #expect(!PriceChange.isDrop(from: nil, to: 120))
        #expect(!PriceChange.isDrop(from: 180, to: nil))
        #expect(!PriceChange.isDrop(from: 0, to: 0))
        #expect(!PriceChange.isDrop(from: 180, to: 0))
    }
}

@Suite("Shopify collections")
struct CollectionsSourceTests {
    /// Trimmed from a live `kith.com/collections.json` response, so the field names are
    /// the real ones — note `description`, where `/products.json` says `body_html`.
    private let payload = """
    {"collections": [
      {"id": 448227213440, "title": "&Kin Fall 2024", "handle": "kin-fall-2024",
       "description": "<p>The second iteration of &amp;Kin.</p>",
       "published_at": "2026-08-09T09:40:18-04:00", "updated_at": "2026-08-09T16:40:26-04:00",
       "image": {"src": "https://cdn.shopify.com/kin.jpg"}, "products_count": 9},
      {"id": 1, "title": "All", "handle": "all",
       "published_at": "2017-03-18T10:59:00-04:00", "image": null, "products_count": 900},
      {"id": 2, "title": "Coming Soon", "handle": "fw26-preview",
       "published_at": "2026-08-09T10:00:00-04:00", "image": null, "products_count": 0}
    ]}
    """

    private func source(etag: String? = nil) -> BrandSource {
        BrandSource(kind: .collections, url: URL(string: "https://kith.com/collections.json")!, etag: etag)
    }

    private func client() -> MockHTTPClient {
        let http = MockHTTPClient()
        http.stub("/collections.json", .init(body: Data(payload.utf8), etag: "W/\"c1\""))
        return http
    }

    @Test("A real collection becomes one event, not sixty product rows")
    func parsesCollections() async throws {
        let result = try await CollectionsSource(http: client()).fetch(source(), since: nil)

        #expect(result.items.count == 1)
        let item = try #require(result.items.first)
        #expect(item.title == "&Kin Fall 2024")
        #expect(item.kind == .collection)
        #expect(item.externalID == "collection:448227213440")
        #expect(item.linkURL?.absoluteString == "https://kith.com/collections/kin-fall-2024")
        #expect(item.imageURLStrings == ["https://cdn.shopify.com/kin.jpg"])
        // Proves the `description` key is read: the wrong key loses this silently.
        #expect(item.summary == "The second iteration of &Kin.")
        #expect(result.etag == "W/\"c1\"")
    }

    /// "All" and "Frontpage" exist on every Shopify store as navigation. Announcing them
    /// would be wrong on the first poll and wrong again on every theme change.
    @Test("Structural collections are never announced")
    func skipsStructural() {
        #expect(CollectionsSource.isStructural("all"))
        #expect(CollectionsSource.isStructural("Frontpage"))
        #expect(!CollectionsSource.isStructural("kin-fall-2024"))
    }

    /// A merchandiser creates the page days before filling it; the empty page is not the
    /// release.
    @Test("An empty collection is not a drop")
    func skipsEmptyCollections() async throws {
        let result = try await CollectionsSource(http: client()).fetch(source(), since: nil)
        #expect(!result.items.contains { $0.title == "Coming Soon" })
    }

    @Test("Anything published before the last check is not news")
    func respectsSince() async throws {
        let since = DateParsing.iso8601("2026-08-10T00:00:00-04:00")
        let result = try await CollectionsSource(http: client()).fetch(source(), since: since)
        #expect(result.items.isEmpty)
    }

    @Test("An unchanged endpoint is a 304, not an empty result")
    func honoursETag() async throws {
        let result = try await CollectionsSource(http: client()).fetch(source(etag: "W/\"c1\""), since: nil)
        #expect(result.notModified)
        #expect(result.items.isEmpty)
    }
}

@Suite("Sitemaps")
struct SitemapSourceTests {
    private let urlset = """
    <?xml version="1.0" encoding="UTF-8"?>
    <urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">
      <url><loc>https://brand.com/products/fw26-box-logo-hoodie</loc>
           <lastmod>2026-08-09T10:00:00+00:00</lastmod></url>
      <url><loc>https://brand.com/products/ss26-tee_white</loc>
           <lastmod>2026-08-01T10:00:00+00:00</lastmod></url>
      <url><loc>https://brand.com/pages/about</loc>
           <lastmod>2026-08-09T10:00:00+00:00</lastmod></url>
      <url><loc>https://brand.com/products/</loc>
           <lastmod>2026-08-09T10:00:00+00:00</lastmod></url>
    </urlset>
    """

    private func source(etag: String? = nil) -> BrandSource {
        BrandSource(kind: .sitemap, url: URL(string: "https://brand.com/sitemap.xml")!, etag: etag)
    }

    private func client(_ body: String) -> MockHTTPClient {
        let http = MockHTTPClient()
        http.stub("/sitemap.xml", .init(body: Data(body.utf8), etag: "W/\"s1\""))
        return http
    }

    @Test("Product URLs become items; pages and listings do not")
    func parsesProductURLs() async throws {
        let result = try await SitemapSource(http: client(urlset)).fetch(source(), since: nil)

        #expect(result.items.count == 2)
        #expect(!result.items.contains { $0.linkURL?.path.contains("/pages/") == true })
        // The listing page itself is not a product.
        #expect(!result.items.contains { $0.linkURL?.absoluteString.hasSuffix("/products/") == true })
        // Newest first.
        #expect(result.items.first?.externalID == "sitemap:https://brand.com/products/fw26-box-logo-hoodie")
    }

    /// A sitemap carries no title, so the slug is all there is — and for streetwear it is
    /// usually the product name.
    @Test("Titles come from the slug, keeping season codes intact")
    func derivesTitles() {
        #expect(
            SitemapSource.title(from: URL(string: "https://brand.com/products/fw26-box-logo-hoodie")!)
                == "FW26 Box Logo Hoodie"
        )
        #expect(
            SitemapSource.title(from: URL(string: "https://brand.com/products/ss26-tee_white")!)
                == "SS26 Tee White"
        )
    }

    @Test("Only what changed since the last check comes back")
    func respectsSince() async throws {
        let since = DateParsing.any("2026-08-05T00:00:00+00:00")
        let result = try await SitemapSource(http: client(urlset)).fetch(source(), since: since)
        #expect(result.items.count == 1)
    }

    /// Without `lastmod` there is no way to tell new from old, and assuming "now" would
    /// resurface the entire catalogue on every single poll.
    @Test("Entries with no lastmod are skipped rather than assumed new")
    func requiresLastmod() async throws {
        let bare = """
        <urlset><url><loc>https://brand.com/products/mystery</loc></url></urlset>
        """
        let result = try await SitemapSource(http: client(bare)).fetch(source(), since: nil)
        #expect(result.items.isEmpty)
    }

    @Test("A sitemap index is followed to its product children")
    func followsIndex() async throws {
        let index = """
        <?xml version="1.0" encoding="UTF-8"?>
        <sitemapindex xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">
          <sitemap><loc>https://brand.com/sitemap_products_1.xml</loc></sitemap>
          <sitemap><loc>https://brand.com/sitemap_blogs_1.xml</loc></sitemap>
        </sitemapindex>
        """
        let http = MockHTTPClient()
        http.stub("/sitemap.xml", .init(body: Data(index.utf8)))
        http.stub("/sitemap_products_1.xml", .init(body: Data(urlset.utf8)))
        // Deliberately not stubbed: following the blog sitemap would be a wasted request.
        let result = try await SitemapSource(http: http).fetch(source(), since: nil)

        #expect(result.items.count == 2)
    }

    @Test("An unchanged sitemap is a 304")
    func honoursETag() async throws {
        let result = try await SitemapSource(http: client(urlset)).fetch(source(etag: "W/\"s1\""), since: nil)
        #expect(result.notModified)
    }

    /// Palace's shape, trimmed: randomised handles that say nothing, with the real name
    /// and the real photograph sitting in the image extension two lines below.
    private let withImages = """
    <?xml version="1.0" encoding="UTF-8"?>
    <urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9"
            xmlns:image="http://www.google.com/schemas/sitemap-image/1.1">
      <url>
        <loc>https://brand.com/products/av1bal6eijz1</loc>
        <lastmod>2026-08-09T10:00:00Z</lastmod>
        <image:image>
          <image:loc>https://cdn.shopify.com/s/files/avirex-jacket-black-1.png</image:loc>
          <image:title>PALACE AVIREX JACKET BLACK</image:title>
          <image:caption></image:caption>
        </image:image>
        <image:image>
          <image:loc>https://cdn.shopify.com/s/files/avirex-jacket-black-2.png</image:loc>
          <image:title>PALACE AVIREX JACKET BLACK</image:title>
        </image:image>
      </url>
      <url>
        <loc>https://brand.com/products/e7anvz3i1psy</loc>
        <lastmod>2026-08-08T10:00:00Z</lastmod>
      </url>
    </urlset>
    """

    /// The bug this fixes shipped a feed of "E7Anvz3I1Psy" over empty grey tiles while
    /// the correct name and photograph were in the same XML entry.
    @Test("The image extension supplies the real name and the lead photograph")
    func readsImageExtension() async throws {
        let result = try await SitemapSource(http: client(withImages)).fetch(source(), since: nil)
        let jacket = try #require(result.items.first)

        #expect(jacket.title == "PALACE AVIREX JACKET BLACK")
        // The lead shot only — a product page lists every angle it has.
        #expect(jacket.imageURLStrings == ["https://cdn.shopify.com/s/files/avirex-jacket-black-1.png"])
        // The page URL, not the CDN's: `<image:loc>` shares a local name with `<loc>`.
        #expect(jacket.linkURL?.absoluteString == "https://brand.com/products/av1bal6eijz1")
    }

    /// A hash is not a product name, and printing one is worse than admitting we don't
    /// have it — the tile still links to the product either way.
    @Test("A randomised handle with no image title doesn't become the title")
    func refusesUnreadableSlugs() async throws {
        let result = try await SitemapSource(http: client(withImages)).fetch(source(), since: nil)
        #expect(result.items.last?.title == "New arrival")

        #expect(!SitemapSource.isReadable("E7Anvz3I1Psy"))
        #expect(!SitemapSource.isReadable("Av1bal6eijz1"))
        // Words are words, however short, and a season code is genuinely a name.
        #expect(SitemapSource.isReadable("FW26 Box Logo Hoodie"))
        #expect(SitemapSource.isReadable("Balaclava"))
        #expect(SitemapSource.isReadable("FW26"))
    }
}

@Suite("Announced drop dates")
struct DropDateTests {
    private let now = DateParsing.iso8601("2026-08-01T00:00:00+00:00")!

    @Test("Reads a <time datetime> element")
    func timeElement() {
        let html = #"<p>Drops <time datetime="2026-08-15T11:00:00+00:00">Friday 11am</time></p>"#
        #expect(DropDateParser.find(in: html, now: now) == DateParsing.iso8601("2026-08-15T11:00:00+00:00"))
    }

    @Test("Reads schema.org availability keys")
    func structuredData() {
        let jsonLD = """
        <script type="application/ld+json">
        {"@type": "Product", "offers": {"availabilityStarts": "2026-08-20T16:00:00+00:00"}}
        </script>
        """
        #expect(DropDateParser.find(in: jsonLD, now: now) == DateParsing.iso8601("2026-08-20T16:00:00+00:00"))
    }

    /// The whole reason this reads only *labelled* dates. A real locked storefront
    /// carries blog dates, asset versions and analytics timestamps in its markup;
    /// picking one would put a confidently wrong time in the calendar.
    @Test("Unlabelled timestamps scattered in a page are ignored")
    func ignoresUnlabelledTimestamps() {
        let html = """
        <div data-render-region="gcp-europe-west1">countdown</div>
        <span>2026-08-02T18:00:00</span>
        <script>var built = "2026-09-01T12:00:00";</script>
        """
        #expect(DropDateParser.find(in: html, now: now) == nil)
    }

    /// A page still showing last season's release date is describing history, and
    /// "upcoming" is the one thing a drop calendar must not get wrong.
    @Test("Dates in the past are not upcoming drops")
    func ignoresPastDates() {
        let html = #"<time datetime="2026-07-01T11:00:00+00:00">last month</time>"#
        #expect(DropDateParser.find(in: html, now: now) == nil)
    }

    @Test("The soonest future date wins when a page names several")
    func picksSoonest() {
        let html = """
        <time datetime="2026-09-01T11:00:00+00:00">later</time>
        <time datetime="2026-08-10T11:00:00+00:00">sooner</time>
        """
        #expect(DropDateParser.find(in: html, now: now) == DateParsing.iso8601("2026-08-10T11:00:00+00:00"))
    }
}

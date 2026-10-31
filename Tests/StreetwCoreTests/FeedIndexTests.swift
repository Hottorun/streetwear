import Foundation
import Testing

@testable import StreetwCore

/// Subdued, read on 2026-10-31: its robots.txt no longer names a sitemap, every sitemap path
/// 404s, and `/rss` answers 200 with Magento's HTML index of feeds — one of new products and
/// seven of categories, all under the `it_en` store view the bare host serves. The fixtures are
/// those pages, trimmed.
@Suite("Feed index pages")
struct FeedIndexTests {
    private let index = "/rss"
    private let newProducts = "/it_en/rss/feed/index/type/new_products/"
    private let newArrivals = "/it_en/rss/feed/index/type/category/cid/29/"
    private let emptyFeed = #"<?xml version="1.0"?><rss version="2.0"><channel><title>Best Sellers</title></channel></rss>"#

    @Test("Magento's index lists new products first, the New Arrivals category next, and no other category")
    func choosesFromTheIndex() throws {
        let base = try #require(URL(string: "https://www.subdued.com/rss"))
        let links = FeedIndex.links(in: Fixtures.string("subdued_rss_index.html"), base: base)
        #expect(links.count == 8)
        #expect(links.first { $0.url.path(percentEncoded: true).hasSuffix("cid/29/") }?.label == "New Arrivals",
                "the name is in the cell beside a link that only says Get Feed")

        let chosen = FeedIndex.choose(links, preferring: .default).map { $0.url.path(percentEncoded: true) }
        #expect(chosen == [newProducts, newArrivals])
    }

    @Test("Discovery follows the index to the new-products feed, and asks for nothing else")
    func followsTheIndex() async throws {
        let http = MockHTTPClient()
        http.stub(index, fixture: "subdued_rss_index.html")
        http.stub(newProducts, fixture: "subdued_rss_new_products.xml")

        let base = try #require(URL(string: "https://www.subdued.com"))
        let found = try #require(await FeedSource.find(at: base, http: http))
        #expect(found.url.absoluteString == "https://www.subdued.com" + newProducts)
        #expect(found.announcesProducts)
        #expect(!http.requestedKeys.contains { $0.contains("/category/") })
    }

    @Test("An empty new-products feed gives way to New Arrivals, and empty categories to nothing")
    func passesOverEmptyFeeds() async throws {
        let base = try #require(URL(string: "https://www.subdued.com"))

        let arrivals = MockHTTPClient()
        arrivals.stub(index, fixture: "subdued_rss_index.html")
        arrivals.stub(newProducts, .init(body: Data(emptyFeed.utf8)))
        arrivals.stub(newArrivals, fixture: "subdued_rss_new_products.xml")
        let found = try #require(await FeedSource.find(at: base, http: arrivals))
        #expect(found.url.path(percentEncoded: true) == newArrivals)
        #expect(found.announcesProducts, "named New Arrivals on the index")

        let nothing = MockHTTPClient()
        nothing.stub(index, fixture: "subdued_rss_index.html")
        nothing.stub(newProducts, .init(body: Data(emptyFeed.utf8)))
        nothing.stub(newArrivals, .init(body: Data(emptyFeed.utf8)))
        #expect(await FeedSource.find(at: base, http: nothing) == nil)
    }

    @Test("A store view in the typed URL is asked first, and its own index chosen from")
    func prefersTheTypedStoreView() async throws {
        let http = MockHTTPClient()
        let view = Fixtures.string("subdued_rss_index.html").replacingOccurrences(of: "/it_en/", with: "/de_en/")
        http.stub("/de_en/rss", .init(body: Data(view.utf8)))
        http.stub("/de_en/rss/feed/index/type/new_products/", fixture: "subdued_rss_new_products.xml")
        http.stub(index, fixture: "subdued_rss_index.html")
        http.stub(newProducts, fixture: "subdued_rss_new_products.xml")

        let base = try #require(URL(string: "https://www.subdued.com"))
        let found = try #require(await FeedSource.find(
            at: base, preferring: URL(string: "https://www.subdued.com/de_en/"), http: http
        ))
        #expect(found.url.path(percentEncoded: true) == "/de_en/rss/feed/index/type/new_products/")
    }

    @Test("Among store views on one index, the preference's wins")
    func choosesTheStoreView() throws {
        let html = """
        <a href="/fr_fr/rss/feed/index/type/new_products/">Get Feed</a>
        <a href="/uk_en/rss/feed/index/type/new_products/">Get Feed</a>
        """
        let links = FeedIndex.links(in: html, base: try #require(URL(string: "https://shop.example/rss")))
        let english = FeedIndex.choose(links, preferring: .default)
        #expect(english.first?.url.path(percentEncoded: true) == "/uk_en/rss/feed/index/type/new_products/")
        let french = FeedIndex.choose(links, preferring: LocalePreference(country: "fr", language: "fr"))
        #expect(french.first?.url.path(percentEncoded: true) == "/fr_fr/rss/feed/index/type/new_products/")
    }

    @Test("A new-products feed's items are products, with the full-size photograph")
    func readsProducts() async throws {
        let http = MockHTTPClient()
        http.stub(newProducts, fixture: "subdued_rss_new_products.xml")
        let source = BrandSource(kind: .feed, url: try #require(URL(string: "https://www.subdued.com" + newProducts)))

        let result = try await FeedSource(http: http).fetch(source, since: nil)
        #expect(result.items.map(\.title) == ["High-neck tank top", "Star hoodie"])
        let first = try #require(result.items.first)
        #expect(first.kind == .product)
        #expect(first.externalID == "feed:https://www.subdued.com/it_en/high-neck-tank-top-tp0tg3t")
        #expect(first.linkURL?.absoluteString == "https://www.subdued.com/it_en/high-neck-tank-top-tp0tg3t")
        #expect(first.imageURLStrings == ["https://www.subdued.com/media/catalog/product/t/p/tp0tg3tcol001-1_4.jpg"])
        #expect(!first.isTentative, "a feed of new products names products; only their pages are missing")
    }

    @Test("A blog's feed is still posts, and a feed titled for new arrivals is not")
    func namesProducts() throws {
        let blog = try #require(URL(string: "https://example.com/blogs/news.atom"))
        #expect(!FeedSource.announcesProducts(url: blog, title: "Example — News"))
        #expect(!FeedSource.announcesProducts(url: blog, title: "What's new at the studio"))
        #expect(FeedSource.announcesProducts(url: blog, title: "New Arrivals"))
        let magento = try #require(URL(string: "https://x.example/rss/feed/index/type/new_products/"))
        #expect(FeedSource.announcesProducts(url: magento))
    }

    @Test("A feed the homepage declares is tried first; a catalogue's or comments' Atom is not a feed")
    func declaredFeeds() async throws {
        let html = """
        <link rel="alternate" type="application/atom+xml" href="/collections/all.atom">
        <link rel="alternate" type="application/rss+xml" title="Comments" href="/comments/feed/">
        <link rel="alternate" type="application/rss+xml" title="Journal" href="/journal.rss">
        """
        let base = try #require(URL(string: "https://brand.example"))
        let declared = SiteAlternates.feeds(in: html, base: base)
        #expect(declared.map(\.path) == ["/journal.rss"])

        let http = MockHTTPClient()
        http.stub("/journal.rss", .init(body: Data("""
        <?xml version="1.0"?><rss version="2.0"><channel><title>Journal</title>
        <item><title>Studio visit</title><guid>a</guid></item></channel></rss>
        """.utf8)))
        let found = try #require(await FeedSource.find(at: base, declared: declared, http: http))
        #expect(found.url.path == "/journal.rss")
        #expect(!found.announcesProducts)
        #expect(http.requestedKeys == ["/journal.rss"], "declared first, so nothing conventional was asked")
    }
}

@Suite("hreflang")
struct HreflangTests {
    @Test("Subdued's homepage names twenty-five copies; the countries are read and the rest kept as they are")
    func readsSubdued() throws {
        let base = try #require(URL(string: "https://www.subdued.com/"))
        let alternates = SiteAlternates.languages(in: Fixtures.string("subdued_home.html"), base: base)
        #expect(alternates.count == 25)

        let us = try #require(alternates.first { $0.code == "en-us" })
        #expect(us.country == "US")
        #expect(us.language == "en")
        #expect(us.url.absoluteString == "https://us.subdued.com")

        let fallback = try #require(alternates.first { $0.isDefault })
        #expect(fallback.country == nil)
        #expect(alternates.first { $0.code == "en" }?.country == nil, "language-only")
        #expect(alternates.first { $0.code == "fr" }?.country == nil)
        #expect(alternates.first { $0.code == "it-ch" }?.country == "CH")
        #expect(alternates.filter { $0.country == "DE" }.map(\.url.path) == ["/de_de", "/de_en"])
        #expect(alternates.first { $0.code == "en-gb" }?.url.path == "/uk_en")
    }

    @Test("Codes are read whatever their spelling; a script or a UN region is not a country", arguments: [
        ("en_GB", "GB"), ("EN-us", "US"), ("zh-Hant-TW", "TW"), ("es-419", nil), ("de", nil), ("x-default", nil)
    ] as [(String, String?)])
    func readsCodes(code: String, country: String?) throws {
        let url = try #require(URL(string: "https://a.example"))
        let alternate = try #require(LanguageAlternate(code: code, url: url))
        #expect(alternate.country == country)
    }

    @Test("Something that is not a language code is not an alternate")
    func refusesNonsense() throws {
        let url = try #require(URL(string: "https://a.example"))
        #expect(LanguageAlternate(code: "", url: url) == nil)
        #expect(LanguageAlternate(code: "english", url: url) == nil)
    }
}

@Suite("Discovering a shop with a feed index")
struct FeedIndexDiscoveryTests {
    @Test("Subdued: the new-products feed and the page watch beside it, its country shops read from the homepage")
    func discoversSubdued() async throws {
        let http = MockHTTPClient()
        http.setDefault(.init(status: 404))
        http.stub("", fixture: "subdued_home.html")
        http.stub("/", fixture: "subdued_home.html")
        http.stub("/rss", fixture: "subdued_rss_index.html")
        http.stub("/it_en/rss/feed/index/type/new_products/", fixture: "subdued_rss_new_products.xml")

        let found = await BrandDiscovery.discover(website: "subdued.com", instagramHandle: nil, http: http)
        #expect(found.sources.map(\.kind) == [.feed, .page],
                "a feed of products does not replace the page watch, which is the only lock detector")
        #expect(found.sources.first?.url.path(percentEncoded: true) == "/it_en/rss/feed/index/type/new_products/")
        #expect(found.readsProducts)
        #expect(found.alternates.count == 25)
        #expect(found.suggestedName == "Subdued")
        #expect(!http.requestedKeys.contains { $0.contains("sitemap") },
                "a feed of products is the catalogue's news; a sitemap would name the same garments again")
    }

    @Test("A typed store view is watched at that view")
    func watchesTheStoreView() async throws {
        let http = MockHTTPClient()
        http.setDefault(.init(status: 404))
        let page = MockHTTPClient.Stub(body: Data("<html><body><p>Neue Kollektion</p></body></html>".utf8))
        http.stub("/de_en", page)
        let view = Fixtures.string("subdued_rss_index.html").replacingOccurrences(of: "/it_en/", with: "/de_en/")
        http.stub("/de_en/rss", .init(body: Data(view.utf8)))
        http.stub("/de_en/rss/feed/index/type/new_products/", fixture: "subdued_rss_new_products.xml")

        let found = await BrandDiscovery.discover(website: "https://www.subdued.com/de_en", instagramHandle: nil, http: http)
        #expect(found.sources.map { $0.url.path(percentEncoded: true) } == ["/de_en/rss/feed/index/type/new_products/", "/de_en"])
    }

    /// us.subdued.com, measured: Shopify, `/products.json` and the blog both answering 429
    /// `local_rate_limited`, and a UCP profile at `/.well-known/ucp` that answers a search.
    @Test("A Shopify store rate-limiting its catalogue is read through UCP, never a page watch")
    func rateLimitedCatalogueFallsToUCP() async throws {
        let http = MockHTTPClient()
        http.setDefault(.init(status: 429, body: Data("local_rate_limited".utf8)))
        http.stub("/.well-known/ucp", fixture: "ucp-profile.json")
        http.stubPost(fixture: "ucp-search-page1.json")

        let found = await BrandDiscovery.discover(website: "us.subdued.com", instagramHandle: nil, http: http)
        #expect(found.sources.map(\.kind) == [.ucp])
        #expect(found.readsProducts)
    }

    @Test("A blog feed no longer keeps a store's UCP catalogue out")
    func blogDoesNotBlockUCP() async throws {
        let http = MockHTTPClient()
        http.setDefault(.init(status: 404))
        http.stub("/blogs/news.atom", fixture: "feed_atom.xml")
        http.stub("/.well-known/ucp", fixture: "ucp-profile.json")
        http.stubPost(fixture: "ucp-search-page1.json")

        let found = await BrandDiscovery.discover(website: "closed.example", instagramHandle: nil, http: http)
        #expect(found.sources.map(\.kind) == [.feed, .ucp])
    }
}

import Foundation
import Testing

@testable import StreetwCore

/// The sitemaps three real retailers publish, trimmed from what they served on 2026-10-24.
/// Each one broke the adapter a different way: Hollister's lists no dates and no images,
/// Victoria's Secret's is two indexes deep with one instant on every entry, and Subdued's
/// is a 7 MB Magento file of products, categories and pages whose product URLs match no
/// pattern. All three are named only in robots.txt.
@Suite("Retailer sitemaps")
struct RetailerSitemapTests {
    private func read(_ http: MockHTTPClient, _ url: String, fingerprint: String? = nil) async throws -> FetchResult {
        var source = BrandSource(kind: .sitemap, url: URL(string: url)!)
        source.fingerprint = fingerprint
        return try await SitemapSource(http: http).fetch(source, since: nil)
    }

    // MARK: Hollister

    private func hollister() -> MockHTTPClient {
        let http = MockHTTPClient()
        http.stub("/robots.txt", fixture: "hollister_robots.txt")
        http.stub("/api/ecomm/util/sitemap/index/hol", fixture: "hollister_sitemap_index.xml")
        http.stub(
            "/api/ecomm/util/sitemap/product?targetStoreId=10251&targetLangId=-1",
            fixture: "hollister_sitemap_product.xml"
        )
        return http
    }

    /// robots.txt is the only place Hollister says where its sitemap is, at a path nobody
    /// would guess, and `/sitemap.xml` 404s. Sixteen product files differ only by a query
    /// naming the store — one catalogue sixteen times over — so one is chosen and the
    /// source is pinned to it rather than re-choosing every poll.
    @Test("Hollister: found through robots.txt and pinned to one store's product file")
    func detectsHollister() async throws {
        let http = hollister()
        let pinned = await SitemapSource.detect(at: URL(string: "https://www.hollisterco.com")!, http: http)

        #expect(pinned?.absoluteString
            == "https://www.hollisterco.com/api/ecomm/util/sitemap/product?targetStoreId=10251&targetLangId=-1")
        // The fifteen other stores' product files and every category file go unread.
        #expect(!http.requestedKeys.contains { $0.contains("targetStoreId=11205") })
        #expect(!http.requestedKeys.contains { $0.contains("/category") })
    }

    /// No `lastmod` on any of the 2,123: the rule that skipped such entries read none of it.
    @Test("Hollister: entries with no date and no photograph are products all the same")
    func readsHollister() async throws {
        let http = hollister()
        let result = try await read(
            http,
            "https://www.hollisterco.com/api/ecomm/util/sitemap/product?targetStoreId=10251&targetLangId=-1"
        )

        #expect(result.isBaseline)
        #expect(result.items.count == 5)
        #expect(result.items.allSatisfy { !$0.isTentative }, "a file named for products lists products")
        // The trailing catalogue number is not part of the name.
        #expect(result.items.first?.title == "Ultra Low Rise Dark Wash Denim Shortie Shorts")
    }

    // MARK: Subdued

    private func subdued(store: String = "us_en") -> MockHTTPClient {
        let http = MockHTTPClient()
        http.stub("/robots.txt", fixture: "subdued_robots.txt")
        http.stub("/media/sitemap/\(store)/sitemap.xml", fixture: "subdued_sitemap_us_en.xml", etag: "\"6ada88d1-6e0b1c\"")
        return http
    }

    /// Twenty-five per-store sitemaps in robots.txt and nothing at `/sitemap.xml`. With
    /// nothing typed to say otherwise, the US English store.
    @Test("Subdued: one storefront out of twenty-five, en-US by default")
    func detectsSubdued() async throws {
        let http = subdued()
        let pinned = await SitemapSource.detect(at: URL(string: "https://www.subdued.com")!, http: http)
        #expect(pinned?.path == "/media/sitemap/us_en/sitemap.xml")
        #expect(http.requestedKeys.filter { $0.hasPrefix("/media/sitemap/") } == ["/media/sitemap/us_en/sitemap.xml"])
    }

    /// The storefront somebody typed wins over the default.
    @Test("Subdued: the storefront in the typed URL is the one watched")
    func followsTheTypedStorefront() async throws {
        let http = subdued(store: "eu_en")
        let pinned = await SitemapSource.detect(
            at: URL(string: "https://www.subdued.com")!,
            preferring: URL(string: "https://www.subdued.com/eu_en/new-arrivals"),
            http: http
        )
        #expect(pinned?.path == "/media/sitemap/eu_en/sitemap.xml")
    }

    /// Products, categories and pages in one file, and the products' URLs match no path
    /// pattern. A photograph marks a product; a known section marks a page that is not one;
    /// what has neither is tentative, for its own page to decide.
    @Test("Subdued: products are told from categories by what the sitemap carries")
    func classifiesSubdued() async throws {
        let http = subdued()
        let result = try await read(http, "https://www.subdued.com/media/sitemap/us_en/sitemap.xml")
        let titles = result.items.map(\.title)

        #expect(result.isBaseline)
        // A baseline is context: only what is surely a product, newest first.
        #expect(titles == ["Tank top with ruffles", "Scoop neck top", "Bandana boyfriend jeans", "Subdued Girl sweatshirt"])
        #expect(!result.items.contains { $0.linkURL?.path.contains("/collection/") == true })
        #expect(result.items.first?.imageURLStrings.first?.contains("cn0avpycol001-1") == true)
        // Dates that mean something date the baseline rows.
        #expect(result.items.first?.publishedAt == DateParsing.any("2026-10-22T14:11:09+00:00"))
    }

    /// After the baseline: a product with no photograph, and a CMS page, are both unseen —
    /// and neither can be told from the other by the sitemap. Both are offered, tentatively.
    @Test("Subdued: an unmarked new URL is offered for its page to confirm")
    func offersUnmarkedURLsTentatively() async throws {
        let baseline = """
        <?xml version="1.0" encoding="UTF-8"?>
        <urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">
        <url><loc>https://www.subdued.com/us_en/collection/tops</loc></url>
        </urlset>
        """
        let http = MockHTTPClient()
        http.stub("/media/sitemap/us_en/sitemap.xml", .init(body: Data(baseline.utf8)))
        let first = try await read(http, "https://www.subdued.com/media/sitemap/us_en/sitemap.xml")

        http.stub("/media/sitemap/us_en/sitemap.xml", fixture: "subdued_sitemap_us_en.xml")
        let next = try await read(
            http,
            "https://www.subdued.com/media/sitemap/us_en/sitemap.xml",
            fingerprint: first.fingerprint
        )

        let tentative = next.items.filter(\.isTentative).compactMap { $0.linkURL?.lastPathComponent }
        #expect(Set(tentative) == ["blonde-sweater-mn078zr", "shipping-information-globale", "accessibilita"])
        #expect(next.items.filter { !$0.isTentative }.count == 4)
        // Categories and sale listings are never offered at all.
        #expect(!next.items.contains { $0.linkURL?.path.contains("/saldi/") == true })
    }

    /// 7.2 MB a read, and Subdued sends a validator: the second read is a 304.
    @Test("Subdued: an unchanged file costs a 304")
    func revalidatesSubdued() async throws {
        let http = subdued()
        var source = BrandSource(kind: .sitemap, url: URL(string: "https://www.subdued.com/media/sitemap/us_en/sitemap.xml")!)
        let first = try await SitemapSource(http: http).fetch(source, since: nil)
        source.etag = first.etag
        source.fingerprint = first.fingerprint

        let second = try await SitemapSource(http: http).fetch(source, since: nil)
        #expect(second.notModified)
    }

    // MARK: Victoria's Secret

    private func victoriasSecret() -> MockHTTPClient {
        let http = MockHTTPClient()
        http.stub("/robots.txt", fixture: "vs_robots.txt")
        http.stub("/sitemaps/index.xml", fixture: "vs_sitemap_index.xml")
        http.stub("/sitemaps/en/us/index.xml", fixture: "vs_sitemap_en_us.xml")
        http.stub("/sitemaps/en/us/product-1.xml", fixture: "vs_sitemap_product.xml", etag: "W/\"6adc1883-8b55c1\"")
        return http
    }

    /// An index of fifty-five locale indexes, nl/nl first and en/us twenty-third: the
    /// three-child cap read the Netherlands, Austria and Australia. Now one locale is
    /// chosen, and within it the one product file of twelve.
    @Test("Victoria's Secret: two levels down, to the US products and nothing else")
    func detectsVictoriasSecret() async throws {
        let http = victoriasSecret()
        let pinned = await SitemapSource.detect(at: URL(string: "https://www.victoriassecret.com")!, http: http)

        // Pinned to the storefront that was chosen, so a later product-2.xml is still found.
        #expect(pinned?.path == "/sitemaps/en/us/index.xml")
        #expect(!http.requestedKeys.contains("/sitemaps/nl/nl/index.xml"))
        #expect(!http.requestedKeys.contains("/sitemaps/en/us/collection-1.xml"))
    }

    /// Every garment is listed twice: a bare catalogue page and, beneath it, one page per
    /// colourway with the photographs. The parent is not a product of its own.
    @Test("Victoria's Secret: a page with others beneath it is the parent, not a product")
    func prunesParents() async throws {
        let http = victoriasSecret()
        let result = try await read(http, "https://www.victoriassecret.com/sitemaps/index.xml")

        #expect(result.items.count == 3)
        #expect(result.items.allSatisfy { $0.linkURL?.path.contains("/-/a/") == true })
        // One instant on every entry dates nothing: baseline rows are dated as first seen.
        #expect(result.items.allSatisfy { $0.publishedAt > Date().addingTimeInterval(-60) })
        #expect(result.items.first?.title == "Crosby Cloud Knit Sweater Blue")
    }

    /// The root index is re-read each time — it is small and its 304 says nothing about
    /// the files below it — and the product file carries its own validator.
    @Test("Victoria's Secret: the product file is revalidated on its own")
    func revalidatesTheChild() async throws {
        let http = victoriasSecret()
        let first = try await read(http, "https://www.victoriassecret.com/sitemaps/en/us/index.xml")
        let second = try await read(http, "https://www.victoriassecret.com/sitemaps/en/us/index.xml", fingerprint: first.fingerprint)

        #expect(second.items.isEmpty)
        #expect(second.fingerprint == nil, "nothing moved, so nothing is rewritten")
        let sent = http.requests.filter { $0.url.path == "/sitemaps/en/us/product-1.xml" }.map(\.etag)
        #expect(sent == [nil, "W/\"6adc1883-8b55c1\""])
    }
}

@Suite("Sitemap memory")
struct SitemapMemoryTests {
    private func sitemap(_ paths: [String]) -> String {
        let urls = paths.map { "<url><loc>https://brand.com/products/\($0)</loc></url>" }.joined()
        return "<urlset xmlns=\"http://www.sitemaps.org/schemas/sitemap/0.9\">\(urls)</urlset>"
    }

    private func read(_ body: String, fingerprint: String?) async throws -> FetchResult {
        let http = MockHTTPClient()
        http.stub("/sitemap.xml", .init(body: Data(body.utf8)))
        var source = BrandSource(kind: .sitemap, url: URL(string: "https://brand.com/sitemap.xml")!)
        source.fingerprint = fingerprint
        return try await SitemapSource(http: http).fetch(source, since: nil)
    }

    @Test("A URL seen for the first time after the baseline is news, once")
    func announcesNewURLsOnce() async throws {
        let first = try await read(sitemap(["a", "b"]), fingerprint: nil)
        #expect(first.isBaseline)

        let second = try await read(sitemap(["a", "b", "c"]), fingerprint: first.fingerprint)
        #expect(!second.isBaseline)
        #expect(second.items.map(\.externalID) == ["sitemap:https://brand.com/products/c"])
        // Dated as first seen.
        #expect(second.items.first.map { $0.publishedAt > Date().addingTimeInterval(-60) } == true)

        let third = try await read(sitemap(["a", "b", "c"]), fingerprint: second.fingerprint)
        #expect(third.items.isEmpty)
    }

    /// A product taken off the sitemap and put back is not new — the memory keeps it.
    @Test("A URL that leaves and comes back is remembered")
    func remembersWhatLeft() async throws {
        let first = try await read(sitemap(["a", "b"]), fingerprint: nil)
        let gone = try await read(sitemap(["a"]), fingerprint: first.fingerprint)
        let back = try await read(sitemap(["a", "b"]), fingerprint: gone.fingerprint ?? first.fingerprint)
        #expect(back.items.isEmpty)
    }

    /// A replatform makes every URL unseen at once. That is not a drop of the whole
    /// catalogue, and it is remembered silently.
    @Test("A rebuilt sitemap is a new baseline, not thousands of drops")
    func treatsARebuildAsABaseline() async throws {
        let old = (0..<300).map { "old-\($0)" }
        let first = try await read(sitemap(old), fingerprint: nil)
        let renamed = (0..<300).map { "new-\($0)" }
        let rebuilt = try await read(sitemap(renamed), fingerprint: first.fingerprint)

        #expect(rebuilt.isBaseline)
        #expect(rebuilt.items.isEmpty)
        let after = try await read(sitemap(renamed + ["genuinely-new"]), fingerprint: rebuilt.fingerprint)
        #expect(after.items.count == 1)
    }

    /// A big drop arrives over two reads rather than losing its tail to the cap.
    @Test("More new products than one read announces are held for the next")
    func defersTheOverflow() async throws {
        let old = (0..<600).map { "old-\($0)" }
        let first = try await read(sitemap(old), fingerprint: nil)
        let drop = (0..<260).map { "drop-\($0)" }

        let second = try await read(sitemap(old + drop), fingerprint: first.fingerprint)
        #expect(second.items.count == SitemapSource.maxNewItems)
        let third = try await read(sitemap(old + drop), fingerprint: second.fingerprint)
        #expect(third.items.count == 260 - SitemapSource.maxNewItems)
    }

    /// A source baselined under the old `<lastmod>` rules has no memory. Its first read now
    /// must not announce a poll's worth of long-listed products to everyone following it.
    @Test("A source with no memory reads as a baseline, whatever came before")
    func legacySourcesBaseline() async throws {
        let result = try await read(sitemap(["a", "b"]), fingerprint: "a page watch's hash")
        #expect(result.isBaseline)
    }

    @Test("The memory survives a round trip and refuses anything else")
    func encodesAndDecodes() {
        let memory = SitemapMemory(seen: [1, 0xDEADBEEF, 42], validators: ["https://a/x.xml": "W/\"1\""], rootIsIndex: true)
        #expect(SitemapMemory(fingerprint: memory.fingerprint) == memory)
        #expect(SitemapMemory(fingerprint: nil) == nil)
        #expect(SitemapMemory(fingerprint: "3f2a9c") == nil)
        #expect(SitemapMemory(fingerprint: SitemapMemory.prefix + "{not json") == nil)
        // Stable across processes, unlike `Hasher`.
        #expect(SitemapMemory.digest("https://brand.com/products/a") == SitemapMemory.digest("https://brand.com/products/a"))
        #expect(SitemapMemory.digest("") == 2_166_136_261)
    }

    /// A child that cannot be read is an error to report, not an empty catalogue to accept.
    @Test("An index whose every child fails is a failure")
    func reportsFailingChildren() async throws {
        let http = MockHTTPClient()
        http.stub("/sitemap.xml", .init(body: Data("""
        <sitemapindex><sitemap><loc>https://brand.com/sitemap_products_1.xml</loc></sitemap></sitemapindex>
        """.utf8)))
        http.stub("/sitemap_products_1.xml", .init(status: 503))
        let source = BrandSource(kind: .sitemap, url: URL(string: "https://brand.com/sitemap.xml")!)

        await #expect(throws: SourceError.badResponse(503)) {
            _ = try await SitemapSource(http: http).fetch(source, since: nil)
        }
    }

    /// An hour between reads on both ends — a sitemap is regenerated on a schedule.
    @Test("A sitemap is not read more often than its floor")
    func keepsTheFloor() {
        var source = BrandSource(kind: .sitemap, url: URL(string: "https://brand.com/sitemap.xml")!)
        source.lastCheckedAt = Date().addingTimeInterval(-600)
        #expect(!source.isReadyToCheck)
        source.lastCheckedAt = Date().addingTimeInterval(-SitemapSource.minimumInterval - 1)
        #expect(source.isReadyToCheck)
    }
}

@Suite("Choosing child sitemaps")
struct SitemapChoiceTests {
    @Test("Products win, unnamed files are a fallback, everything else is never read")
    func choosesByKind() {
        let woo = [
            "https://brand.com/post-sitemap.xml",
            "https://brand.com/product_cat-sitemap.xml",
            "https://brand.com/product-sitemap.xml",
            "https://brand.com/product-sitemap2.xml"
        ]
        // Both parts of the product sitemap; never the categories beside them.
        #expect(SitemapChoice.select(woo, preferring: .default).follow == [
            "https://brand.com/product-sitemap.xml",
            "https://brand.com/product-sitemap2.xml"
        ])
        #expect(SitemapChoice.select(["https://brand.com/blog/sitemap.xml"], preferring: .default).follow.isEmpty)
        #expect(SitemapChoice.select(["https://brand.com/sitemap_1.xml"], preferring: .default).follow.count == 1)
    }

    /// Shopify pages its product sitemap by query; those are parts of one file, not stores.
    @Test("Paging by query keeps every part")
    func keepsPagedParts() {
        let parts = [
            "https://brand.com/sitemap_products_1.xml?from=1&to=999",
            "https://brand.com/sitemap_products_2.xml?from=1000&to=1999"
        ]
        #expect(SitemapChoice.select(parts, preferring: .default).follow == parts)
        let sameFile = [
            "https://brand.com/sitemap.xml?page=1",
            "https://brand.com/sitemap.xml?page=2"
        ]
        #expect(SitemapChoice.select(sameFile, preferring: .default).follow == sameFile)
    }

    @Test("Storefronts are chosen by country, then language, then the default")
    func choosesTheStorefront() {
        let locales = ["nl/nl", "en/at", "en/gb", "en/us", "fr/fr"].map {
            "https://www.victoriassecret.com/sitemaps/\($0)/index.xml"
        }
        let pick = { (preference: LocalePreference) in
            SitemapChoice.select(locales, preferring: preference).follow
        }
        #expect(pick(.default) == ["https://www.victoriassecret.com/sitemaps/en/us/index.xml"])
        #expect(pick(LocalePreference(country: "gb", language: "en")) == ["https://www.victoriassecret.com/sitemaps/en/gb/index.xml"])
        #expect(pick(LocalePreference(country: "fr", language: "fr")) == ["https://www.victoriassecret.com/sitemaps/fr/fr/index.xml"])
        // No Japanese storefront: the default beats whichever sibling came first.
        #expect(pick(LocalePreference(country: "jp", language: "ja")) == ["https://www.victoriassecret.com/sitemaps/en/us/index.xml"])
        #expect(SitemapChoice.select(locales, preferring: .default).choseStorefront)
    }

    @Test("A storefront's URL says where it sells")
    func readsThePreference() {
        func of(_ url: String) -> LocalePreference { LocalePreference.of(URL(string: url)) }
        #expect(of("https://usa.palaceskateboards.com") == LocalePreference(country: "us", language: "en"))
        #expect(of("https://www.subdued.com/eu_en/new-arrivals") == LocalePreference(country: "eu", language: "en"))
        #expect(of("https://www.brand.co.uk") == LocalePreference(country: "gb", language: "en"))
        #expect(of("https://www.hollisterco.com/shop/uk") == LocalePreference(country: "gb", language: "en"))
        // A slug is not a locale, and a vanity domain is not a country.
        #expect(of("https://kith.com/products/it-bag") == .default)
        #expect(of("https://brand.co") == .default)
    }

    @Test("robots.txt's Sitemap lines are read, whatever their case")
    func readsRobotsSitemaps() {
        let hollister = RobotsRules.sitemaps(in: Fixtures.string("hollister_robots.txt"))
        #expect(hollister.map(\.absoluteString) == ["https://www.hollisterco.com/api/ecomm/util/sitemap/index/hol"])
        // Subdued lists it_it twice.
        #expect(RobotsRules.sitemaps(in: Fixtures.string("subdued_robots.txt")).count == 24)
        #expect(RobotsRules.sitemaps(in: "Sitemap: https://a.com/s.xml # main\nSitemap: ftp://a.com/x").count == 1)
    }

    /// A sitemap on somebody else's domain is somebody else's catalogue.
    @Test("A robots.txt sitemap on another domain is ignored")
    func refusesForeignSitemaps() async {
        let http = MockHTTPClient()
        http.stub("/robots.txt", .init(body: Data("Sitemap: https://elsewhere.example/sitemap.xml".utf8)))
        http.stub(host: "elsewhere.example", "/sitemap.xml", .init(body: Data("""
        <urlset><url><loc>https://elsewhere.example/products/a</loc></url></urlset>
        """.utf8)))
        let found = await SitemapSource.detect(at: URL(string: "https://brand.com")!, http: http)
        #expect(found == nil)
        #expect(!http.requests.contains { $0.url.host() == "elsewhere.example" })
    }

    @Test("A catalogue number is not part of a slug's name")
    func dropsCatalogueNumbers() {
        func title(_ path: String) -> String { SitemapSource.title(from: URL(string: "https://brand.com\(path)")!) }
        #expect(title("/shop/us/p/oversized-meet-me-poolside-graphic-tee-62609848") == "Oversized Meet Me Poolside Graphic Tee")
        #expect(title("/us_en/scoop-neck-top-cn01j79") == "Scoop Neck Top")
        // Kept: a season code, a three-digit style number, and a slug that is nothing else.
        #expect(title("/products/fw26-box-logo-hoodie") == "FW26 Box Logo Hoodie")
        #expect(title("/en-gb/p/skye-cap-cypress-wax-574") == "Skye Cap Cypress Wax 574")
        #expect(title("/products/62609848") == "62609848")
    }
}

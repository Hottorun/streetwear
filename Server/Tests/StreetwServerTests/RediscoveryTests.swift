import Fluent
import FluentPostgresDriver
import Foundation
import StreetwCore
import Testing
import Vapor
import VaporTesting

@testable import StreetwServer

// Subdued as measured on 2026-10-31, trimmed: the homepage's hreflang set (a selection of the
// real 25), Magento's `/rss` index, its new-products feed, a product page's JSON-LD, and the US
// Shopify store answering `/products.json` with 429 while its UCP endpoint answers a search.

private let subduedHome = """
<!doctype html><html lang="en"><head><title>Subdued | Shop Now</title>
<meta property="og:site_name" content="Subdued"/>
<link  rel="alternate" hreflang="en-IT" href="https://www.subdued.com/it_en" />
<link  rel="alternate" hreflang="en" href="https://www.subdued.com/eu_en" />
<link  rel="alternate" hreflang="x-default" href="https://www.subdued.com" />
<link  rel="alternate" hreflang="en-GB" href="https://www.subdued.com/uk_en" />
<link  rel="alternate" hreflang="en-US" href="https://us.subdued.com" />
<link  rel="alternate" hreflang="fr" href="https://www.subdued.com/ww_fr" />
<link  rel="alternate" hreflang="de" href="https://www.subdued.com/ww_de" />
<link  rel="alternate" hreflang="de-DE" href="https://www.subdued.com/de_de" />
<link  rel="alternate" hreflang="en-DE" href="https://www.subdued.com/de_en" />
</head><body><main>Shop the new collection</main></body></html>
"""

private let subduedIndex = """
<html><body><table class="data table rss"><tbody>
<th colspan="2" scope="col">Miscellaneous Feeds</th>
<tr><td class="col feed">New Products</td><td class="col action">
<a href="https://www.subdued.com/it_en/rss/feed/index/type/new_products/" class="action get"><span>Get Feed</span></a></td></tr>
<th colspan="2" scope="col">Categories</th>
<tr><td class="col feed">Best Sellers</td><td class="col action">
<a href="https://www.subdued.com/it_en/rss/feed/index/type/category/cid/372/" class="action get"><span>Get Feed</span></a></td></tr>
</tbody></table></body></html>
"""

private func newProducts(_ items: [(title: String, handle: String)]) -> String {
    let entries = items.map { item in
        """
        <item><title>\(item.title)</title>
        <description><![CDATA[<img src="https://www.subdued.com/media/catalog/product/\(item.handle).jpg?width=75&height=75&canvas=75,75&optimize=medium&fit=bounds">]]></description>
        <link>https://www.subdued.com/it_en/\(item.handle)</link><guid>https://www.subdued.com/it_en/\(item.handle)</guid></item>
        """
    }.joined()
    return """
    <?xml version="1.0" encoding="UTF-8"?><rss version="2.0"><channel>
    <title>New Products from Subdued</title>\(entries)</channel></rss>
    """
}

private func productPage(_ name: String, price: String) -> String {
    """
    <html><head><script type="application/ld+json">
    {"@context":"https://schema.org","@type":"Product","name":"\(name)",
     "image":["https://www.subdued.com/media/catalog/product/a.jpg","https://www.subdued.com/media/catalog/product/b.jpg"],
     "offers":{"@type":"Offer","price":"\(price)","priceCurrency":"EUR","availability":"https://schema.org/InStock"}}
    </script></head><body></body></html>
    """
}

private let usProfile = """
{"ucp":{"version":"2026-08-25","supported_versions":{"2026-04-08":"https://subdued-pos.myshopify.com/.well-known/ucp/2026-04-08"},
"services":{"dev.ucp.shopping":[{"version":"2026-08-25","transport":"mcp","endpoint":"https://subdued-pos.myshopify.com/api/ucp/mcp"}]},
"capabilities":{"dev.ucp.shopping.catalog.search":[{"version":"2026-08-25"}]}}}
"""

private let usSearch = """
{"jsonrpc":"2.0","id":1,"result":{"structuredContent":{"products":[{
 "id":"gid://shopify/Product/1","handle":"star-hoodie","title":"Star hoodie","url":"https://us.subdued.com/products/star-hoodie",
 "price_range":{"min":{"amount":6500,"currency":"USD"},"max":{"amount":6500,"currency":"USD"}},
 "variants":[{"id":"gid://shopify/ProductVariant/11","title":"S","price":{"amount":6500,"currency":"USD"},"availability":{"available":true},
   "options":[{"name":"Size","label":"S"}]}]}]}}}
"""

private let feedPath = "/it_en/rss/feed/index/type/new_products/"

/// Subdued's whole estate, answering as it did when measured.
private func subdued(feed items: [(title: String, handle: String)] = [("High-neck tank top", "high-neck-tank-top-tp0tg3t")]) -> HostHTTP {
    let http = HostHTTP()
    for host in ["www.subdued.com", "subdued.com"] {
        http.stub(host, "", body: subduedHome)
        http.stub(host, "/", body: subduedHome)
        http.stub(host, "/rss", body: subduedIndex)
        // `HostHTTP` keys on `URL.path`, which drops the trailing slash.
        http.stub(host, String(feedPath.dropLast()), body: newProducts(items))
    }
    for (title, handle) in items {
        http.stub("www.subdued.com", "/it_en/\(handle)", body: productPage(title, price: "27"))
    }
    http.stub("us.subdued.com", "/products.json?limit=250&page=1", status: 429, body: "local_rate_limited")
    http.stub("us.subdued.com", "/blogs/news.atom", status: 429, body: "local_rate_limited")
    http.stub("us.subdued.com", "/.well-known/ucp", body: usProfile)
    http.stub("subdued-pos.myshopify.com", "/api/ucp/mcp", body: usSearch)
    return http
}

/// Subdued as production holds it: a page watch and nothing else, read for weeks.
private func seedSubdued(_ app: Application) async throws -> (brandID: UUID, page: SourceModel) {
    let brand = BrandModel(
        name: "Subdued", slug: "www.subdued.com", website: "https://www.subdued.com",
        instagramHandle: nil, usesGeneratedName: false
    )
    try await brand.save(on: app.db)
    let brandID = try brand.requireID()
    let page = SourceModel(brandID: brandID, kind: .page, url: "https://www.subdued.com")
    page.baselinedAt = Date().addingTimeInterval(-30 * 86_400)
    page.fingerprint = "abc"
    // Not due during the test: a page watch's own read is not what is under test.
    page.nextCheckAt = Date().addingTimeInterval(86_400)
    try await page.save(on: app.db)
    return (brandID, page)
}

private func alternates(_ html: String = subduedHome) -> [LanguageAlternate] {
    SiteAlternates.languages(in: html, base: URL(string: "https://www.subdued.com/")!)
}

private func url(_ raw: String) -> URL { URL(string: raw)! }

@Suite("Country shops from hreflang")
struct CountryShopPlanTests {
    @Test("Only switched-on countries; x-default and language-only codes are never countries; English wins a tie")
    func plansSubdued() {
        let plan = CountryShops.plan(
            alternates: alternates(),
            enabled: ["US", "DE"],
            main: url("https://www.subdued.com"),
            mainSources: [(.page, url("https://www.subdued.com"))],
            served: []
        )
        #expect(plan.candidates == [
            .init(url: url("https://us.subdued.com"), countries: ["US"]),
            .init(url: url("https://www.subdued.com/de_en"), countries: ["DE"]),
        ])
        #expect(plan.skipped.isEmpty, "GB and IT are not switched on, and nothing is recorded for them")
    }

    @Test("A Shopify main shop's market subfolder and its own homepage are not a country's shop; one regional shop takes every country naming it")
    func plansKith() {
        let html = """
        <link rel="alternate" hreflang="en-US" href="https://kith.com/">
        <link rel="alternate" hreflang="en-GB" href="https://kith.com/en-gb">
        <link rel="alternate" hreflang="en-DE" href="https://eu.kith.com/">
        <link rel="alternate" hreflang="en-FR" href="https://eu.kith.com">
        """
        let plan = CountryShops.plan(
            alternates: SiteAlternates.languages(in: html, base: url("https://kith.com/")),
            enabled: ["US", "GB", "DE", "FR"],
            main: url("https://kith.com"),
            mainSources: [(.shopify, url("https://kith.com")), (.collections, url("https://kith.com"))],
            served: []
        )
        #expect(plan.candidates == [.init(url: url("https://eu.kith.com"), countries: ["DE", "FR"])])
        #expect(plan.skipped.map(\.reason) == [.mainShop, .marketSubfolder])
    }

    @Test("A country another shop of the brand serves is left to it")
    func leavesServedCountries() {
        let plan = CountryShops.plan(
            alternates: alternates(),
            enabled: ["US", "DE"],
            main: url("https://www.subdued.com"),
            mainSources: [],
            served: ["US"]
        )
        #expect(plan.candidates.map(\.countries) == [["DE"]])
        #expect(plan.skipped.map(\.reason) == [.served])
    }
}

@Suite("Attaching country shops automatically")
struct CountryShopAttachTests {
    @Test("us.subdued.com, whose catalogue answers 429, is attached for the US through UCP, un-baselined")
    func attachesSubduedUS() async throws {
        try await withServer { app in
            let http = subdued()
            let (brandID, _) = try await seedSubdued(app)

            let results = try await CountryShops.attach(
                brandID: brandID, alternates: alternates(), enabled: ["US"], http: http, on: app.db
            )
            #expect(results == [.attached(countries: ["US"], shop: "us.subdued.com", kinds: ["ucp"])])
            let shop = try #require(try await StorefrontModel.query(on: app.db).with(\.$countries).first())
            #expect(shop.countryCodes == ["US"])
            #expect(shop.url == "https://us.subdued.com")
            let sources = try await SourceModel.query(on: app.db).filter(\.$storefront.$id == shop.id).all()
            #expect(sources.map(\.kind) == ["ucp"])
            #expect(sources.allSatisfy { $0.baselinedAt == nil }, "its first read is a baseline")
        }
    }

    @Test("A shop behind a bot wall, or answering nothing, is not attached")
    func refusesUnverified() async throws {
        try await withServer { app in
            let http = HostHTTP()
            let wall = "<html><title>Access Denied</title>Reference #18.abc</html>"
            for path in ["", "/", "/products.json?limit=250&page=1", "/meta.json", "/.well-known/ucp", "/rss", "/feed",
                         "/blogs/news.atom", "/blogs/journal.atom", "/feed.xml", "/atom.xml", "/robots.txt", "/sitemap.xml",
                         "/sitemap_index.xml"] {
                http.stub("us.subdued.com", path, status: 403, body: wall)
            }
            let (brandID, _) = try await seedSubdued(app)
            let results = try await CountryShops.attach(
                brandID: brandID, alternates: alternates(), enabled: ["US"], http: http, on: app.db
            )
            #expect(results.count == 1)
            #expect(!(results.first?.isAttached ?? true))
            #expect(try await StorefrontModel.query(on: app.db).count() == 0)
        }
    }

    @Test("With no country switched on, nothing is fetched")
    func fetchesNothingWhenOff() async throws {
        try await withServer { app in
            let http = subdued()
            let (brandID, _) = try await seedSubdued(app)
            let results = try await CountryShops.attach(
                brandID: brandID, alternates: alternates(), enabled: [], http: http, on: app.db
            )
            #expect(results.isEmpty)
            #expect(http.requested.isEmpty)
        }
    }

    @Test("The main shop's own catalogue under a country's path is refused, not attached twice")
    func refusesTheMainCatalogue() async throws {
        try await withServer { app in
            let http = subdued()
            // en-IT is /it_en, which serves the same feed the main shop reads.
            http.stub("www.subdued.com", "/it_en/rss", body: subduedIndex)
            http.stub("www.subdued.com", "/it_en", body: subduedHome)
            let (brandID, _) = try await seedSubdued(app)
            try await SourceModel(brandID: brandID, kind: .feed, url: "https://www.subdued.com" + feedPath).save(on: app.db)

            let results = try await CountryShops.attach(
                brandID: brandID, alternates: alternates(), enabled: ["IT"], http: http, on: app.db
            )
            #expect(results.count == 1)
            #expect(results.first?.line.contains("already reads") == true)
            #expect(try await StorefrontModel.query(on: app.db).count() == 0)
        }
    }
}

@Suite("What rediscovery adds")
struct RediscoveryAdditionTests {
    private func found(_ sources: [(BrandSource.Kind, String)], productsFeed: Bool = false) -> DiscoveredSources {
        var found = DiscoveredSources()
        found.sources = sources.map { BrandSource(kind: $0.0, url: url($0.1)) }
        found.feedAnnouncesProducts = productsFeed
        return found
    }

    @Test("A page-watch brand gains the feed of new products and keeps its page watch")
    func addsTheFeed() {
        let additions = Rediscovery.additions(
            to: [.init(kind: .page, url: url("https://www.subdued.com"), isReading: true)],
            from: found([(.feed, "https://www.subdued.com" + feedPath), (.page, "https://www.subdued.com/")], productsFeed: true)
        )
        #expect(additions.sources.map(\.kind) == [.feed])
        #expect(additions.notes.isEmpty)
    }

    @Test("A second catalogue beside one that reads is said, not added")
    func neverDuplicatesACatalogue() {
        let additions = Rediscovery.additions(
            to: [.init(kind: .sitemap, url: url("https://shop.example/sitemap.xml"), isReading: true)],
            from: found([(.ucp, "https://shop.example")])
        )
        #expect(additions.sources.isEmpty)
        #expect(additions.notes.count == 1)
    }

    @Test("A dead apex catalogue gives way to the www. one, with its collections")
    func swapsToWWW() {
        let additions = Rediscovery.additions(
            to: [.init(kind: .shopify, url: url("https://palace.example"), isReading: false)],
            from: found([(.shopify, "https://www.palace.example"), (.collections, "https://www.palace.example")])
        )
        #expect(additions.sources.map(\.kind) == [.shopify, .collections])
    }

    @Test("A blog feed is added only where there is no feed; the same URL is never added twice")
    func blogFeed() {
        let shopify = Rediscovery.Held(kind: .shopify, url: url("https://kith.example"), isReading: true)
        let blog = found([(.shopify, "https://kith.example/"), (.feed, "https://kith.example/blogs/news.atom")])
        #expect(Rediscovery.additions(to: [shopify], from: blog).sources.map(\.kind) == [.feed])
        let held = [shopify, .init(kind: .feed, url: url("https://kith.example/blogs/journal.atom"), isReading: true)]
        #expect(Rediscovery.additions(to: held, from: blog).sources.isEmpty)
    }
}

@Suite("The rediscovery pass")
struct RediscoveryPassTests {
    @Test("A feed's new product waits for its page, as a sitemap's does; a blog post does not")
    func holdsFeedProducts() {
        let product = FetchedItem(externalID: "feed:a", title: "Star hoodie", publishedAt: Date(), kind: .product)
        let post = FetchedItem(externalID: "feed:b", title: "Store hours", publishedAt: Date(), kind: .post)
        #expect(Poller.isAnnouncedFromItsPage(product, kind: .feed))
        #expect(!Poller.isAnnouncedFromItsPage(post, kind: .feed))
        #expect(Poller.isAnnouncedFromItsPage(post, kind: .sitemap))
        #expect(!Poller.isAnnouncedFromItsPage(product, kind: .shopify))
    }

    @Test("Subdued gains its feed and its US shop, once; the feed's first read is silent and a new product is announced priced")
    func rediscoversSubdued() async throws {
        try await withServer { app in
            app.storefrontCountries = ["US", "DE"]
            let http = subdued()
            let (brandID, page) = try await seedSubdued(app)

            let row = try #require(try await Rediscovery.claimNext(on: app.db, countries: app.storefrontCountries))
            let line = await Rediscovery.look(at: row, app: app, http: http)
            #expect(line.hasPrefix("www.subdued.com: +feed new_products"))
            #expect(line.contains("+storefront US us.subdued.com (ucp)"))
            #expect(line.contains("storefront DE www.subdued.com/de_en not attached"),
                    "nothing answers at /de_en here, so its discovery lands on the main shop's own feed and is refused")
            #expect(try await Rediscovery.claimNext(on: app.db, countries: app.storefrontCountries) == nil, "once per pass")
            // Switching a country on is a new pass: every brand is looked at again for its shop there.
            let again = try await Rediscovery.claimNext(on: app.db, countries: ["US", "DE", "GB"])
            #expect(again?.$brand.id == brandID)
            if let again { try await again.delete(on: app.db) }

            let main = try await SourceModel.query(on: app.db)
                .filter(\.$brand.$id == brandID).filter(\.$storefront.$id == nil).all()
            #expect(Set(main.map(\.kind)) == ["page", "feed"])
            #expect(main.contains { $0.id == page.id }, "the page watch stays")
            let feed = try #require(main.first { $0.kind == "feed" })
            #expect(feed.baselinedAt == nil)

            // The first read: the back catalogue, stored, and nothing said.
            let poller = Poller(app: app, http: http)
            await poller.tick()
            await poller.enrich()
            #expect(try await SourceModel.find(feed.id, on: app.db)?.baselinedAt != nil)
            #expect(try await ProductModel.query(on: app.db).filter(\.$source.$id == feed.id).count() == 1)
            #expect(try await EventModel.query(on: app.db).count() == 0)

            // A new product: held for its page, then announced with the page's price.
            http.stub("www.subdued.com", String(feedPath.dropLast()), body: newProducts([
                ("Star hoodie", "star-hoodie-020exx4"), ("High-neck tank top", "high-neck-tank-top-tp0tg3t"),
            ]))
            http.stub("www.subdued.com", "/it_en/star-hoodie-020exx4", body: productPage("Star hoodie", price: "55"))
            let source = try #require(try await SourceModel.find(feed.id, on: app.db))
            source.nextCheckAt = Date().addingTimeInterval(-1)
            try await source.save(on: app.db)
            // One pass: the poll stores it with its event held, and `enrich` at the end of the
            // same tick reads the page and writes the event.
            await poller.tick()
            let hoodie = try #require(try await ProductModel.query(on: app.db).filter(\.$title == "Star hoodie").first())
            #expect(hoodie.kind == "product")
            #expect(hoodie.pendingAnnouncement == nil)
            #expect(hoodie.enrichedAt != nil, "announced from its page, not from the feed")
            let events = try await EventModel.query(on: app.db).all()
            #expect(events.map(\.kind) == ["product"])
            let read = try #require(try await ProductModel.find(hoodie.id, on: app.db))
            #expect(read.priceAmount == 55)
            #expect(read.currency == "EUR")

            var report = ""
            try await app.testing().test(.GET, "admin/rediscovery", headers: adminAuth) { res async throws in
                report = res.body.string
            }
            #expect(report.contains("1 of 1 brands looked at"))
            #expect(report.contains("+1 source(s), +1 storefront(s)"))
            #expect(report.contains("+storefront US us.subdued.com"))
        }
    }

    @Test("A brand a check adds is recorded, and its country shops attached in the background")
    func checksRecordAndAttach() async throws {
        try await withServer { app in
            app.storefrontCountries = ["US"]
            app.storage[FetcherKey.self] = subdued()
            let checks = try #require(app.brandChecks)
            let check = try await checks.start(url: "www.subdued.com", catalogueOnly: true)
            let id = try check.requireID()
            for _ in 0..<200 {
                if let row = try await BrandCheckModel.find(id, on: app.db), row.$brand.id != nil { break }
                try await Task.sleep(for: .milliseconds(20))
            }
            await checks.countryShopsSettled()

            let brand = try #require(try await BrandModel.query(on: app.db).with(\.$sources).first())
            #expect(Set(brand.sources.filter { $0.$storefront.id == nil }.map(\.kind)) == ["feed", "page"])
            let shop = try #require(try await StorefrontModel.query(on: app.db).with(\.$countries).first())
            #expect(shop.countryCodes == ["US"])
            #expect(try await Rediscovery.claimNext(on: app.db, countries: app.storefrontCountries) == nil, "discovered under these rules already")
        }
    }
}

/// The pass's ledger on a real Postgres: a dead look is taken again, and two instances
/// claiming at once never take the same brand. Runs only when `STREETW_TEST_POSTGRES_URL` names
/// a scratch database.
@Suite(
    "Rediscovery on Postgres",
    .enabled(if: ProcessInfo.processInfo.environment["STREETW_TEST_POSTGRES_URL"] != nil),
    .serialized
)
struct RediscoveryPostgresTests {
    private func withPostgres(_ body: (Application) async throws -> Void) async throws {
        let url = try #require(ProcessInfo.processInfo.environment["STREETW_TEST_POSTGRES_URL"])
        let app = try await Application.make(.testing)
        var config = try SQLPostgresConfiguration(url: url)
        config.coreConfiguration.tls = .disable
        app.databases.use(.postgres(configuration: config, maxConnectionsPerEventLoop: 8), as: .psql)
        addMigrations(to: app)
        do {
            try await app.autoMigrate()
            try await body(app)
            try await app.autoRevert()
        } catch {
            try? await app.autoRevert()
            try await app.asyncShutdown()
            throw error
        }
        try await app.asyncShutdown()
    }

    @Test("It resumes after a restart, takes a dead look again, and never claims one brand twice")
    func resumes() async throws {
        try await withPostgres { app in
            var ids: [UUID] = []
            for n in 0..<6 {
                let brand = BrandModel(name: "B\(n)", slug: "b\(n).example", website: "https://b\(n).example",
                                       instagramHandle: nil, usesGeneratedName: false)
                try await brand.save(on: app.db)
                ids.append(try brand.requireID())
            }

            // Two instances claiming at once take different brands.
            async let a = Rediscovery.claimNext(on: app.db)
            async let b = Rediscovery.claimNext(on: app.db)
            let (first, second) = try await (a, b)
            let claimed = [first, second].compactMap { $0?.$brand.id }
            #expect(claimed.count == 2)
            #expect(Set(claimed).count == 2)

            // The first finishes; the second's process dies mid-look.
            let done = try #require(first)
            done.finishedAt = Date()
            done.line = "b: nothing new"
            try await done.save(on: app.db)

            // After a restart, inside the grace, the next brand is taken, not the dead one.
            let next = try #require(try await Rediscovery.claimNext(on: app.db))
            #expect(!claimed.contains(next.$brand.id))
            next.finishedAt = Date()
            try await next.save(on: app.db)

            // Past the grace, the dead look is taken again before any new brand.
            let later = Date().addingTimeInterval(Rediscovery.abandonAfter + 60)
            let retaken = try #require(try await Rediscovery.claimNext(on: app.db, now: later))
            #expect(retaken.$brand.id == second?.$brand.id)
            retaken.finishedAt = later
            try await retaken.save(on: app.db)

            // Everything claimed, nothing claimed twice.
            var rest = 0
            while let row = try await Rediscovery.claimNext(on: app.db, now: later) {
                row.finishedAt = later
                try await row.save(on: app.db)
                rest += 1
                #expect(rest <= ids.count)
            }
            let rows = try await RediscoveryModel.query(on: app.db).all()
            #expect(rows.count == ids.count)
            #expect(Set(rows.map(\.$brand.id)) == Set(ids))
        }
    }
}

import Fluent
import Foundation
import StreetwCore
import Testing
import Vapor

@testable import StreetwServer

/// A sitemap with no dates — Hollister's shape — polled twice: what the source has seen is
/// what decides what is news.
@Suite("Sitemap polling")
struct SitemapPollingTests {
    private func sitemap(_ slugs: [String]) -> String {
        let urls = slugs.map { "<url><loc>https://shop.example/products/\($0)</loc></url>" }.joined()
        return "<urlset xmlns=\"http://www.sitemaps.org/schemas/sitemap/0.9\">\(urls)</urlset>"
    }

    private func seed(_ app: Application, baselinedAt: Date? = nil) async throws -> SourceModel {
        let brand = BrandModel(
            name: "Shop", slug: "shop.example", website: "https://shop.example",
            instagramHandle: nil, usesGeneratedName: false
        )
        try await brand.save(on: app.db)
        let source = SourceModel(brandID: try brand.requireID(), kind: .sitemap, url: "https://shop.example/sitemap.xml")
        source.baselinedAt = baselinedAt
        try await source.save(on: app.db)
        return source
    }

    private func makeDue(_ app: Application) async throws {
        let source = try #require(try await SourceModel.query(on: app.db).first())
        source.nextCheckAt = Date().addingTimeInterval(-1)
        try await source.save(on: app.db)
    }

    @Test("A URL that was not there at the baseline is a drop, and only once")
    func announcesFirstSeenURLs() async throws {
        try await withServer { app in
            let http = StubHTTP()
            http.stub("/sitemap.xml", body: sitemap(["hoodie", "tee"]))
            _ = try await seed(app)
            let poller = Poller(app: app, http: http)

            await poller.tick()
            #expect(try await ProductModel.query(on: app.db).count() == 2)
            #expect(try await EventModel.query(on: app.db).count() == 0)

            http.stub("/sitemap.xml", body: sitemap(["hoodie", "tee", "jacket"]))
            try await makeDue(app)
            await poller.tick()

            let events = try await EventModel.query(on: app.db).with(\.$product).all()
            #expect(events.count == 1)
            #expect(events.first?.product?.externalID == "sitemap:https://shop.example/products/jacket")

            try await makeDue(app)
            await poller.tick()
            #expect(try await EventModel.query(on: app.db).count() == 1, "seen once is seen")
        }
    }

    /// Production holds sitemap sources baselined under the `<lastmod>` rules, with no memory.
    /// Their first poll after this deploy has to stay quiet, or every follower is told about
    /// a poll's worth of long-listed products.
    @Test("A source baselined before the memory existed does not announce its catalogue")
    func legacySourceStaysQuiet() async throws {
        try await withServer { app in
            let http = StubHTTP()
            http.stub("/sitemap.xml", body: sitemap(["hoodie", "tee", "jacket"]))
            _ = try await seed(app, baselinedAt: Date().addingTimeInterval(-30 * 86_400))

            await Poller(app: app, http: http).tick()

            #expect(try await EventModel.query(on: app.db).count() == 0)
            let source = try #require(try await SourceModel.query(on: app.db).first())
            #expect(source.fingerprint?.hasPrefix("sitemap-memory/") == true)
        }
    }

    /// A product page as storefronts write it for search engines.
    private func page(name: String, price: Double, inStock: Bool) -> String {
        """
        <html><head><script type="application/ld+json">
        {"@context": "http://schema.org", "@type": "Product", "name": "\(name)",
         "image": "https://cdn.shop.example/\(name.lowercased().replacingOccurrences(of: " ", with: "-")).jpg",
         "offers": {"@type": "http://schema.org/Offer", "price": \(price), "priceCurrency": "USD",
                    "availability": "http://schema.org/\(inStock ? "InStock" : "OutOfStock")"}}
        </script></head><body></body></html>
        """
    }

    /// The event waits for the page, so the push and the card say what the thing is called
    /// and what it costs — not "New arrival" over a slug.
    @Test("A new sitemap product is announced from its page, with its price")
    func announcesFromThePage() async throws {
        try await withServer { app in
            let http = StubHTTP()
            http.stub("/sitemap.xml", body: sitemap(["hoodie"]))
            _ = try await seed(app)
            let poller = Poller(app: app, http: http)
            await poller.tick()

            http.stub("/sitemap.xml", body: sitemap(["hoodie", "box-logo-hoodie-62609848"]))
            http.stub("/products/box-logo-hoodie-62609848", body: page(name: "Box Logo Hoodie", price: 168, inStock: true))
            try await makeDue(app)
            await poller.tick()

            let events = try await EventModel.query(on: app.db).with(\.$product).all()
            #expect(events.count == 1)
            let product = try #require(events.first?.product)
            #expect(product.title == "Box Logo Hoodie")
            #expect(product.priceAmount == 168)
            #expect(product.isAvailable == true)
            #expect(product.imageURLs == ["https://cdn.shop.example/box-logo-hoodie.jpg"])
            #expect(product.pendingAnnouncement == nil)
            #expect(product.enrichedAt != nil)
        }
    }

    /// Subdued's categories and CMS pages sit in the same file as its products with nothing
    /// to mark them. One the page does not bear out is never announced and never kept.
    @Test("A tentative URL whose page is no product is dropped, unannounced")
    func dropsAnUnconfirmedGuess() async throws {
        try await withServer { app in
            let http = StubHTTP()
            let mixed = { (paths: [String]) in
                "<urlset>" + paths.map { "<url><loc>https://shop.example/en/\($0)</loc></url>" }.joined() + "</urlset>"
            }
            http.stub("/sitemap.xml", body: mixed(["shipping"]))
            _ = try await seed(app)
            let poller = Poller(app: app, http: http)
            await poller.tick()

            http.stub("/sitemap.xml", body: mixed(["shipping", "accessibility", "ruffle-top"]))
            http.stub("/en/accessibility", body: "<html><head><title>Accessibility</title></head></html>")
            http.stub("/en/ruffle-top", body: page(name: "Ruffle Top", price: 14, inStock: true))
            try await makeDue(app)
            await poller.tick()

            let products = try await ProductModel.query(on: app.db).all()
            #expect(products.map(\.title) == ["Ruffle Top"])
            #expect(try await EventModel.query(on: app.db).count() == 1)
        }
    }

    /// A page that cannot be read costs the announcement its details, never the
    /// announcement — and is not asked again.
    @Test("A product whose page fails is still announced, once")
    func announcesWhenThePageFails() async throws {
        try await withServer { app in
            let http = StubHTTP()
            http.stub("/sitemap.xml", body: sitemap(["hoodie"]))
            _ = try await seed(app)
            let poller = Poller(app: app, http: http)
            await poller.tick()

            http.stub("/sitemap.xml", body: sitemap(["hoodie", "jacket"]))
            try await makeDue(app)
            await poller.tick()
            await poller.enrich()

            #expect(try await EventModel.query(on: app.db).count() == 1)
            let jacket = try #require(try await ProductModel.query(on: app.db).filter(\.$title == "Jacket").first())
            #expect(jacket.enrichedAt != nil)
        }
    }

    /// The restock a watch waits for is only visible on the page, so a watched product is
    /// read again — through the poll's own `refresh`, which raises the event the watch fires on.
    @Test("A watched sitemap product is read again, and its restock is an event")
    func rereadsAWatchedProduct() async throws {
        try await withServer { app in
            let http = StubHTTP()
            http.stub("/sitemap.xml", body: sitemap(["hoodie"]))
            http.stub("/products/hoodie", body: page(name: "Hoodie", price: 90, inStock: false))
            let source = try await seed(app)
            let poller = Poller(app: app, http: http)
            await poller.tick()

            let product = try #require(try await ProductModel.query(on: app.db).first())
            #expect(product.isAvailable == false, "the baseline row was read for its stock")
            #expect(try await EventModel.query(on: app.db).count() == 0, "a first read is a baseline")

            let user = UserModel()
            try await user.save(on: app.db)
            try await WatchModel(
                userID: try user.requireID(), brandID: source.$brand.id, productID: try product.requireID(),
                size: nil, color: nil
            ).save(on: app.db)
            product.enrichedAt = Date().addingTimeInterval(-Poller.recheckAfter - 60)
            try await product.save(on: app.db)

            http.stub("/products/hoodie", body: page(name: "Hoodie", price: 90, inStock: true))
            await Poller(app: app, http: http).enrich()

            let events = try await EventModel.query(on: app.db).all()
            #expect(events.map(\.kind) == [UpdateKind.restock.rawValue])
        }
    }

    /// A sitemap is regenerated on a schedule and can be megabytes a read.
    @Test("A sitemap is not polled again within the hour, even in a drop window")
    func keepsTheFloor() async throws {
        try await withServer { app in
            let http = StubHTTP()
            http.stub("/sitemap.xml", body: sitemap(["hoodie"]))
            _ = try await seed(app)

            await Poller(app: app, http: http).tick()

            let source = try #require(try await SourceModel.query(on: app.db).first())
            #expect(source.nextCheckAt.timeIntervalSinceNow > SitemapSource.minimumInterval - 60)
        }
    }
}

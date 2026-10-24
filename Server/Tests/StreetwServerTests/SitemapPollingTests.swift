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

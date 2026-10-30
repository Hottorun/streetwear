import Fluent
import Foundation
import SQLKit
import StreetwCore
import Testing
import Vapor
import VaporTesting

@testable import StreetwServer

// A save from a shop the catalogue lacks sends the shop's domain, so search can recommend from
// it (`StartBrandCheck.catalogueOnly`). It adds the shop only if the check finds one whose
// products can be read, follows nobody, and keeps nothing about who asked.

/// Answers every request with Akamai's block page.
private struct BlockedFetcher: HTTPFetching {
    func get(_ url: URL, etag: String?) async throws -> HTTPResponse {
        HTTPResponse(
            data: Data("<HTML><HEAD><TITLE>Access Denied</TITLE></HEAD><BODY>Access Denied</BODY></HTML>".utf8),
            status: 403,
            finalURL: url
        )
    }

    func post(_ url: URL, json body: Data, accept: String) async throws -> HTTPResponse {
        try await get(url, etag: nil)
    }
}

@Suite("Catalogue-only checks")
struct CatalogueOnlyCheckTests {
    private func shopify() -> StubHTTP {
        let http = StubHTTP()
        http.stub("/products.json?limit=250&page=1", body: """
        {"products":[{"id":1,"title":"Chore Coat","handle":"chore-coat","published_at":"2026-08-01T10:00:00Z",
          "variants":[{"id":11,"title":"M","available":true,"price":"180.00"}]}]}
        """)
        http.stub("/meta.json", body: #"{"name":"Subdued","currency":"EUR"}"#)
        return http
    }

    private func start(
        _ app: Application, _ url: String, _ auth: HTTPHeaders, catalogueOnly: Bool = true
    ) async throws -> (status: HTTPStatus, check: BrandCheck?) {
        var result: (HTTPStatus, BrandCheck?) = (.internalServerError, nil)
        try await app.testing().test(.POST, "v1/brands/checks", headers: auth, beforeRequest: { req in
            try req.content.encode(StartBrandCheck(url: url, catalogueOnly: catalogueOnly ? true : nil))
        }, afterResponse: { res async throws in
            result = (res.status, res.status == .ok ? try res.content.decode(BrandCheck.self) : nil)
        })
        return result
    }

    private func finished(_ app: Application, _ id: UUID) async throws -> BrandCheckModel {
        for _ in 0..<50 {
            if let check = try await BrandCheckModel.find(id, on: app.db), check.finishedAt != nil {
                return check
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        Issue.record("the check never finished")
        return try #require(try await BrandCheckModel.find(id, on: app.db))
    }

    /// The catalogue write happens after the status is recorded, so it is waited for.
    private func brands(_ app: Application, becomes count: Int) async throws -> Int {
        for _ in 0..<50 {
            let now = try await BrandModel.query(on: app.db).count()
            if now == count { return now }
            try await Task.sleep(for: .milliseconds(100))
        }
        return try await BrandModel.query(on: app.db).count()
    }

    @Test("A real shop is added to the catalogue, and nobody follows it")
    func addsWithoutFollowing() async throws {
        try await withServer { app in
            app.storage[FetcherKey.self] = shopify()
            let auth = try await deviceAuth(app)

            let started = try #require(try await start(app, "https://subdued.com", auth).check)
            let check = try await finished(app, started.id)
            #expect(check.catalogueOnly == true)
            #expect(try await brands(app, becomes: 1) == 1)
            let brand = try #require(try await BrandModel.query(on: app.db).with(\.$sources).first())
            #expect(brand.sources.contains { $0.kind == BrandSource.Kind.shopify.rawValue })
            #expect(try await FollowModel.query(on: app.db).count() == 0)
            #expect(try await BrandCheckWatcherModel.query(on: app.db).count() == 0)
        }
    }

    /// The privacy half, held by the schema: a check has no column a requester could be kept
    /// in, and a catalogue-only one adds no watcher row either (above).
    @Test("A check row records no requester")
    func recordsNoRequester() async throws {
        try await withServer { app in
            let sql = try #require(app.db as? any SQLDatabase)
            let columns = try await sql.raw("PRAGMA table_info(brand_checks)").all()
                .map { try $0.decode(column: "name", as: String.self) }
            #expect(columns.contains("catalogue_only"))
            #expect(!columns.contains { $0.contains("user") || $0.contains("device") || $0.contains("account") })
        }
    }

    @Test("A shop that blocks readers adds nothing")
    func refusedAddsNothing() async throws {
        try await withServer { app in
            app.storage[FetcherKey.self] = BlockedFetcher()
            let auth = try await deviceAuth(app)
            let started = try #require(try await start(app, "https://www.bershka.com", auth).check)
            let check = try await finished(app, started.id)
            #expect(check.status == BrandCheck.Status.refused.rawValue)
            #expect(check.refusal == BrandCheck.Refusal.blocksReaders.rawValue)
            try await Task.sleep(for: .milliseconds(300))
            #expect(try await BrandModel.query(on: app.db).count() == 0)
        }
    }

    @Test("A shop that sells no clothes adds nothing, and fetches nothing")
    func noClothesAddsNothing() async throws {
        try await withServer { app in
            app.storage[FetcherKey.self] = BlockedFetcher()
            let auth = try await deviceAuth(app)
            let started = try #require(try await start(app, "https://www.chanel.com", auth).check)
            #expect(started.status == .refused)
            #expect(started.refusal == .sellsNoClothes)
            #expect(try await BrandModel.query(on: app.db).count() == 0)
        }
    }

    /// A page watch is enough to follow a shop — "something changed" can be worth a push — and
    /// nothing to search: it has no products to recommend.
    @Test("A site readable only as a page is not added")
    func pageWatchIsNotACatalogue() throws {
        func check(_ sources: [BrandProbe.Source], status: BrandCheck.Status = .ready) throws -> BrandCheckModel {
            let check = BrandCheckModel(domain: "lookbook.example", url: "https://lookbook.example", status: status)
            check.probe = String(decoding: try JSONEncoder().encode(BrandProbe(suggestedName: nil, sources: sources)), as: UTF8.self)
            return check
        }
        let page = BrandProbe.Source(kind: "page", url: "https://lookbook.example", isAutomatic: false)
        let feed = BrandProbe.Source(kind: "feed", url: "https://lookbook.example/feed", isAutomatic: true)
        let sitemap = BrandProbe.Source(kind: "sitemap", url: "https://lookbook.example/sitemap.xml", isAutomatic: true)

        #expect(!BrandChecks.addsToCatalogue(try check([page])))
        #expect(!BrandChecks.addsToCatalogue(try check([page, feed])))
        #expect(BrandChecks.addsToCatalogue(try check([page, sitemap])))
        // A refused check adds nothing, whatever its probe lists.
        #expect(!BrandChecks.addsToCatalogue(try check([sitemap], status: .refused)))
    }

    @Test("A shop the catalogue has already is not added again")
    func existingIsLeftAlone() async throws {
        try await withServer { app in
            app.storage[FetcherKey.self] = shopify()
            let existing = BrandModel(
                name: "Subdued", slug: "www.subdued.com", website: "https://www.subdued.com",
                instagramHandle: nil, usesGeneratedName: false
            )
            try await existing.save(on: app.db)
            let auth = try await deviceAuth(app)
            let started = try #require(try await start(app, "https://subdued.com", auth).check)
            #expect(started.status == .ready)
            #expect(started.brand?.id == existing.id)
            #expect(try await BrandModel.query(on: app.db).count() == 1)
            #expect(try await FollowModel.query(on: app.db).count() == 0)
        }
    }

    /// Somebody previewed the shop a minute ago; a save from it joins that check, and the
    /// preview's finished answer is enough to add it.
    @Test("Joining a finished preview adds the shop")
    func joinsAPreview() async throws {
        try await withServer { app in
            app.storage[FetcherKey.self] = shopify()
            let auth = try await deviceAuth(app)
            let preview = try #require(try await start(app, "https://subdued.com", auth, catalogueOnly: false).check)
            _ = try await finished(app, preview.id)
            #expect(try await BrandModel.query(on: app.db).count() == 0)

            let joined = try #require(try await start(app, "https://www.subdued.com", auth).check)
            #expect(joined.id == preview.id)
            #expect(try await brands(app, becomes: 1) == 1)
            #expect(try await FollowModel.query(on: app.db).count() == 0)
        }
    }

    @Test("Catalogue-only checks have a budget of their own")
    func rateLimited() async throws {
        try await withServer { app in
            app.storage[FetcherKey.self] = BlockedFetcher()
            let auth = try await deviceAuth(app)
            // A shop that sells no clothes is answered without fetching, so this spends only
            // the budget under test.
            for _ in 0..<10 {
                #expect(try await start(app, "https://www.chanel.com", auth).status == .ok)
            }
            #expect(try await start(app, "https://www.chanel.com", auth).status == .tooManyRequests)
            // An ordinary check from the same device is not refused by it.
            #expect(try await start(app, "https://www.chanel.com", auth, catalogueOnly: false).status == .ok)
            // And another device has its own.
            let other = try await deviceAuth(app)
            #expect(try await start(app, "https://www.chanel.com", other).status == .ok)
        }
    }
}

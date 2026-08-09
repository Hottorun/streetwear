import Fluent
import Foundation
import StreetwCore
import Testing
import Vapor
import VaporTesting

@testable import StreetwServer

/// Boots a real app against in-memory SQLite with the poll loop off.
///
/// Deliberately *not* named `withApp`: VaporTesting exports a generic `withApp<T>` that
/// does not run `configure`. With a single-statement test closure, Swift infers `T` from
/// `test(...)`'s discardable return and silently picks that one — the app comes up with
/// no routes and every request 404s, while multi-statement closures resolve to the local
/// overload and pass. A confusing failure worth never reintroducing.
private func withServer(_ body: (Application) async throws -> Void) async throws {
    setenv("SQLITE_PATH", ":memory:", 1)
    setenv("DISABLE_POLLER", "true", 1)

    let app = try await Application.make(.testing)
    do {
        try await configure(app)
        // Required: the responder's route cache is built at boot, so without this
        // every request 404s even though the routes are registered.
        try await app.asyncBoot()
        try await body(app)
    } catch {
        try await app.asyncShutdown()
        throw error
    }
    try await app.asyncShutdown()
}

/// Minimal canned-response client — the server target can't see StreetwCoreTests.
final class StubHTTP: HTTPFetching, @unchecked Sendable {
    private let lock = NSLock()
    private var responses: [String: (Int, Data, String?)] = [:]
    private(set) var sentETags: [String?] = []

    func stub(_ path: String, status: Int = 200, body: String, etag: String? = nil) {
        lock.withLock { responses[path] = (status, Data(body.utf8), etag) }
    }

    func get(_ url: URL, etag: String?) async throws -> HTTPResponse {
        let key = URLComponents(url: url, resolvingAgainstBaseURL: false).map {
            ($0.path) + ($0.query.map { q in "?\(q)" } ?? "")
        } ?? url.path
        let hit = lock.withLock { () -> (Int, Data, String?)? in
            sentETags.append(etag)
            return responses[key]
        }
        guard let hit else { return HTTPResponse(data: Data(), status: 404, finalURL: url) }
        if let etag, let stubbed = hit.2, etag == stubbed {
            return HTTPResponse(data: Data(), status: 304, finalURL: url, etag: stubbed)
        }
        return HTTPResponse(data: hit.1, status: hit.0, finalURL: url, etag: hit.2)
    }
}

/// A one-product Shopify catalog whose single variant's stock can be flipped.
private func catalog(available: Bool, size: String = "M") -> String {
    """
    {"products": [{
      "id": 1, "title": "Test Hoodie", "handle": "test-hoodie",
      "published_at": "2026-08-01T10:00:00-04:00", "created_at": "2026-08-01T10:00:00-04:00",
      "tags": ["hoodie"], "product_type": "Hoodies",
      "options": [{"name": "Size", "position": 1}],
      "variants": [{"id": 11, "title": "\(size)", "option1": "\(size)",
                    "available": \(available), "price": "180.00"}],
      "images": [{"src": "https://cdn.example.com/a.jpg"}]
    }]}
    """
}

@Suite("HTTP surface")
struct RouteTests {
    @Test("Health check responds")
    func health() async throws {
        try await withServer { app in
            try await app.testing().test(.GET, "health") { res in
                #expect(res.status == .ok)
                #expect(res.body.string == "ok")
            }
        }
    }

    @Test("Registering a device returns a bearer token")
    func registerDevice() async throws {
        try await withServer { app in
            try await app.testing().test(.POST, "v1/devices", beforeRequest: { req in
                try req.content.encode(["environment": "sandbox"])
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                let body = try res.content.decode(DeviceResponse.self)
                #expect(!body.token.isEmpty)
            })
        }
    }

    @Test("The feed refuses anonymous callers")
    func feedRequiresAuth() async throws {
        try await withServer { app in
            try await app.testing().test(.GET, "v1/feed") { res in
                #expect(res.status == .unauthorized)
            }
        }
    }

    @Test("Sizes are normalised on the way in, so duplicates can't be stored")
    func normalisesSizesOnRegister() async throws {
        try await withServer { app in
            try await app.testing().test(.POST, "v1/devices", beforeRequest: { req in
                try req.content.encode(RegisterDevice(
                    sizes: SizePayload(apparel: ["medium", "M", "large"], shoe: ["US 9", "9.0"])
                ))
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
            })

            let user = try #require(try await UserModel.query(on: app.db).first())
            #expect(Set(user.apparelSizes) == ["M", "L"])
            #expect(user.shoeSizes == ["9"])
        }
    }

    @Test("A followed brand's events come back in the feed")
    func feedReturnsFollowedEvents() async throws {
        try await withServer { app in
            let brand = BrandModel(
                name: "Test", slug: "test.com", website: "https://test.com",
                instagramHandle: nil, usesGeneratedName: false
            )
            try await brand.save(on: app.db)
            let brandID = try brand.requireID()
            try await EventModel(brandID: brandID, productID: nil, kind: .product).save(on: app.db)

            var token = ""
            try await app.testing().test(.POST, "v1/devices", beforeRequest: { req in
                try req.content.encode(RegisterDevice())
            }, afterResponse: { res async throws in
                token = try res.content.decode(DeviceResponse.self).token
            })

            let auth = HTTPHeaders([("Authorization", "Bearer \(token)")])

            // Nothing followed yet.
            try await app.testing().test(.GET, "v1/feed", headers: auth) { res async throws in
                let feed = try res.content.decode(FeedResponse.self)
                #expect(feed.items.isEmpty)
            }

            try await app.testing().test(.POST, "v1/follows", headers: auth, beforeRequest: { req in
                try req.content.encode(FollowBrand(brandID: brandID))
            }, afterResponse: { res async throws in
                #expect(res.status == .created)
            })

            try await app.testing().test(.GET, "v1/feed", headers: auth) { res async throws in
                let feed = try res.content.decode(FeedResponse.self)
                #expect(feed.items.count == 1)
                #expect(feed.items.first?.brandName == "Test")
            }
        }
    }
}

@Suite("Poller")
struct PollerTests {
    private func seedBrand(_ app: Application, http: StubHTTP) async throws -> (UUID, SourceModel) {
        let brand = BrandModel(
            name: "example.com", slug: "example.com", website: "https://example.com",
            instagramHandle: nil, usesGeneratedName: true
        )
        try await brand.save(on: app.db)
        let brandID = try brand.requireID()
        let source = SourceModel(brandID: brandID, kind: .shopify, url: "https://example.com")
        try await source.save(on: app.db)
        return (brandID, source)
    }

    /// The rule that keeps a new brand from firing thousands of notifications: a
    /// source's first poll records everything but announces nothing.
    @Test("The first poll is a baseline — products stored, no events")
    func firstPollIsBaseline() async throws {
        try await withServer { app in
            let http = StubHTTP()
            http.stub("/products.json?limit=250&page=1", body: catalog(available: true))
            http.stub("/meta.json", body: #"{"name": "Example", "currency": "EUR"}"#)
            _ = try await seedBrand(app, http: http)

            await Poller(app: app, http: http).tick()

            let products = try await ProductModel.query(on: app.db).count()
            let variants = try await VariantModel.query(on: app.db).count()
            let events = try await EventModel.query(on: app.db).count()
            #expect(products == 1)
            #expect(variants == 1)
            #expect(events == 0)

            // meta.json also supplies the real name and currency.
            let brand = try #require(try await BrandModel.query(on: app.db).first())
            #expect(brand.name == "Example")
            #expect(brand.currency == "EUR")
            #expect(brand.usesGeneratedName == false)
        }
    }

    @Test("A restock produces one event naming the size that returned")
    func restockProducesEvent() async throws {
        try await withServer { app in
            let http = StubHTTP()
            http.stub("/meta.json", body: #"{"name": "Example", "currency": "USD"}"#)
            http.stub("/products.json?limit=250&page=1", body: catalog(available: false))
            _ = try await seedBrand(app, http: http)

            let poller = Poller(app: app, http: http)
            await poller.tick()   // baseline: sold out
            let baselineEvents = try await EventModel.query(on: app.db).count()
            #expect(baselineEvents == 0)

            // Make the source due again, then restock it.
            let source = try #require(try await SourceModel.query(on: app.db).first())
            source.nextCheckAt = Date().addingTimeInterval(-1)
            try await source.save(on: app.db)
            http.stub("/products.json?limit=250&page=1", body: catalog(available: true))

            await poller.tick()

            let events = try await EventModel.query(on: app.db).all()
            #expect(events.count == 1)
            #expect(events.first?.kind == UpdateKind.restock.rawValue)
            #expect(events.first?.sizes == ["M"])
            let products = try await ProductModel.query(on: app.db).count()
            #expect(products == 1, "must not duplicate the product")
        }
    }

    @Test("An unchanged catalog produces nothing on a second poll")
    func unchangedProducesNothing() async throws {
        try await withServer { app in
            let http = StubHTTP()
            http.stub("/meta.json", body: #"{"name": "Example", "currency": "USD"}"#)
            http.stub("/products.json?limit=250&page=1", body: catalog(available: true))
            _ = try await seedBrand(app, http: http)

            let poller = Poller(app: app, http: http)
            await poller.tick()

            let source = try #require(try await SourceModel.query(on: app.db).first())
            source.nextCheckAt = Date().addingTimeInterval(-1)
            try await source.save(on: app.db)

            await poller.tick()

            let events = try await EventModel.query(on: app.db).count()
            let products = try await ProductModel.query(on: app.db).count()
            #expect(events == 0)
            #expect(products == 1)
        }
    }

    /// Without a stored validator every poll re-downloads the whole catalog, which is
    /// the single biggest cost in the whole system.
    @Test("The catalog's ETag is stored and replayed as If-None-Match")
    func storesAndReplaysETag() async throws {
        try await withServer { app in
            let http = StubHTTP()
            http.stub("/meta.json", body: #"{"name": "Example", "currency": "USD"}"#)
            http.stub("/products.json?limit=250&page=1", body: catalog(available: true), etag: #"W/"abc""#)
            _ = try await seedBrand(app, http: http)

            let poller = Poller(app: app, http: http)
            await poller.tick()

            let source = try #require(try await SourceModel.query(on: app.db).first())
            #expect(source.etag == #"W/"abc""#, "the validator must be persisted")

            source.nextCheckAt = Date().addingTimeInterval(-1)
            try await source.save(on: app.db)
            await poller.tick()

            #expect(http.sentETags.contains(#"W/"abc""#), "second poll must replay If-None-Match")
            let products = try await ProductModel.query(on: app.db).count()
            #expect(products == 1)
        }
    }

    @Test("A failing source backs off instead of being retried immediately")
    func failureBacksOff() async throws {
        try await withServer { app in
            let http = StubHTTP() // everything 404s
            _ = try await seedBrand(app, http: http)

            await Poller(app: app, http: http).tick()

            let source = try #require(try await SourceModel.query(on: app.db).first())
            #expect(source.failureCount == 1)
            #expect(source.lastError != nil)
            #expect(source.nextCheckAt > Date().addingTimeInterval(60))
        }
    }

    @Test("Cadence spends requests where something is happening")
    func cadence() {
        // A locked storefront is checked aggressively; a quiet one is left alone.
        #expect(Poller.Cadence.next(locked: true, hadRecentEvent: false, quietForAWeek: false, failures: 0) == 60)
        #expect(Poller.Cadence.next(locked: false, hadRecentEvent: true, quietForAWeek: false, failures: 0) == 300)
        #expect(Poller.Cadence.next(locked: false, hadRecentEvent: false, quietForAWeek: false, failures: 0) == 1200)
        #expect(Poller.Cadence.next(locked: false, hadRecentEvent: false, quietForAWeek: true, failures: 0) == 7200)
        // Failure backoff outranks everything and caps at six hours.
        #expect(Poller.Cadence.next(locked: true, hadRecentEvent: true, quietForAWeek: false, failures: 3) == 480)
        #expect(Poller.Cadence.next(locked: false, hadRecentEvent: false, quietForAWeek: false, failures: 99) == 21600)
    }
}

@Suite("Poller resilience")
struct PollerResilienceTests {
    /// A source that cannot be updated normally must still have its schedule pushed
    /// forward. Otherwise it stays "due" and every tick re-fetches the whole catalog.
    @Test("A source is never left due after a failed poll")
    func neverLeftDue() async throws {
        try await withServer { app in
            let http = StubHTTP()   // everything 404s -> fetch throws inside poll
            let brand = BrandModel(
                name: "example.com", slug: "example.com", website: "https://example.com",
                instagramHandle: nil, usesGeneratedName: true
            )
            try await brand.save(on: app.db)
            let source = SourceModel(brandID: try brand.requireID(), kind: .shopify, url: "https://example.com")
            try await source.save(on: app.db)

            let poller = Poller(app: app, http: http)
            await poller.tick()

            let after = try #require(try await SourceModel.query(on: app.db).first())
            #expect(after.nextCheckAt > Date(), "must not remain due for the next tick")
            #expect(after.lastCheckedAt != nil)
            #expect(after.failureCount >= 1)

            // A second tick must find nothing due rather than re-fetching immediately.
            let polled = await poller.tick()
            #expect(polled == 0)
        }
    }
}

@Suite("Status")
struct StatusTests {
    @Test("Status proves the database is reachable and reports counts")
    func statusReportsDatabase() async throws {
        try await withServer { app in
            let brand = BrandModel(
                name: "Test", slug: "test.com", website: nil,
                instagramHandle: nil, usesGeneratedName: false
            )
            try await brand.save(on: app.db)

            try await app.testing().test(.GET, "status") { res async throws in
                #expect(res.status == .ok)
                let status = try res.content.decode(StatusResponse.self)
                #expect(status.databaseConnected)
                #expect(status.databaseError == nil)
                #expect(status.brands == 1)
                // Tests run on SQLite; production must report postgres.
                #expect(status.database == "sqlite")
            }
        }
    }

    @Test("Health stays a cheap 200 so a database blip can't fail the deploy")
    func healthIsCheap() async throws {
        try await withServer { app in
            try await app.testing().test(.GET, "health") { res async in
                #expect(res.status == .ok)
            }
        }
    }
}

@Suite("Device updates")
struct DeviceUpdateTests {
    /// Regression: this route calls `authenticatedDevice()` but was registered outside
    /// the authenticated group, so the middleware never ran and it always 401'd —
    /// which broke the client's very first sync step.
    @Test("Updating sizes works with a bearer token")
    func patchDeviceIsAuthenticated() async throws {
        try await withServer { app in
            var token = ""
            try await app.testing().test(.POST, "v1/devices", beforeRequest: { req in
                try req.content.encode(RegisterDevice())
            }, afterResponse: { res async throws in
                token = try res.content.decode(DeviceResponse.self).token
            })

            let auth = HTTPHeaders([("Authorization", "Bearer \(token)")])
            try await app.testing().test(.PATCH, "v1/devices/me", headers: auth, beforeRequest: { req in
                try req.content.encode(UpdateDevice(sizes: SizePayload(apparel: ["M"], shoe: ["9"])))
            }, afterResponse: { res async throws in
                #expect(res.status == .noContent)
            })

            let user = try #require(try await UserModel.query(on: app.db).first())
            #expect(user.apparelSizes == ["M"])
        }
    }

    @Test("Updating sizes without a token is refused")
    func patchDeviceRequiresAuth() async throws {
        try await withServer { app in
            try await app.testing().test(.PATCH, "v1/devices/me", beforeRequest: { req in
                try req.content.encode(UpdateDevice())
            }, afterResponse: { res async throws in
                #expect(res.status == .unauthorized)
            })
        }
    }
}

@Suite("Database TLS")
struct DatabaseTLSTests {
    /// Regression: `.prefer` with default verification fails outright against managed
    /// Postgres, because the certificate is signed by the provider's own CA for a
    /// private hostname — the handshake errors rather than falling back.
    @Test("Provider-internal hosts use a plaintext private-network hop", arguments: [
        "postgres.railway.internal", "db.internal", "localhost", "127.0.0.1"
    ])
    func internalHostsDisableTLS(host: String) {
        #expect(Application.tlsMode(host: host, override: nil) == .disable)
    }

    @Test("Public hosts encrypt but skip verification by default", arguments: [
        "containers-us-west-1.railway.app", "ep-cool-name.eu-central-1.aws.neon.tech"
    ])
    func publicHostsSkipVerification(host: String) {
        #expect(Application.tlsMode(host: host, override: nil) == .noVerify)
    }

    @Test("DATABASE_TLS overrides the guess")
    func overrideWins() {
        #expect(Application.tlsMode(host: "postgres.railway.internal", override: "verify") == .verify)
        #expect(Application.tlsMode(host: "example.com", override: "disable") == .disable)
        #expect(Application.tlsMode(host: "example.com", override: "nonsense") == .noVerify,
                "an unrecognised value must fall back, not crash the boot")
    }
}

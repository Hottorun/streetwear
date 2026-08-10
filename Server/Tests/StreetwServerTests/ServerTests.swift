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

    /// Regression, and an expensive one: a poll that fails stamps `last_checked_at`
    /// anyway, so keying the baseline on that spends it on a poll that stored nothing.
    /// This is what happened in production while the JSONB/`TEXT[]` bug was live — Kith
    /// polled and stored nothing for hours, then the first working poll announced 250
    /// back-catalogue products as new drops.
    @Test("A failed poll doesn't spend the brand's baseline")
    func failedPollKeepsBaseline() async throws {
        try await withServer { app in
            let http = StubHTTP()
            http.stub("/meta.json", body: #"{"name": "Example", "currency": "USD"}"#)
            // Nothing stubbed for products.json yet: the fetch 404s and stores nothing.
            _ = try await seedBrand(app, http: http)

            let poller = Poller(app: app, http: http)
            await poller.tick()
            #expect(try await ProductModel.query(on: app.db).count() == 0)

            let source = try #require(try await SourceModel.query(on: app.db).first())
            #expect(source.lastCheckedAt != nil, "a failed poll still records the attempt")
            #expect(source.baselinedAt == nil, "but it must not count as a baseline")

            source.nextCheckAt = Date().addingTimeInterval(-1)
            try await source.save(on: app.db)
            http.stub("/products.json?limit=250&page=1", body: catalog(available: true))

            await poller.tick()

            #expect(try await ProductModel.query(on: app.db).count() == 1)
            #expect(try await EventModel.query(on: app.db).count() == 0,
                    "the first batch that actually stored is the baseline, not news")
        }
    }

    /// The other half: once a baseline exists, genuinely new products are news.
    @Test("A product appearing after the baseline is an event")
    func newProductAfterBaselineIsNews() async throws {
        try await withServer { app in
            let http = StubHTTP()
            http.stub("/meta.json", body: #"{"name": "Example", "currency": "USD"}"#)
            http.stub("/products.json?limit=250&page=1", body: catalog(available: true))
            _ = try await seedBrand(app, http: http)

            let poller = Poller(app: app, http: http)
            await poller.tick()
            #expect(try await EventModel.query(on: app.db).count() == 0)

            let source = try #require(try await SourceModel.query(on: app.db).first())
            source.nextCheckAt = Date().addingTimeInterval(-1)
            try await source.save(on: app.db)
            http.stub("/products.json?limit=250&page=1", body: """
                {"products": [{
                  "id": 2, "title": "Second Hoodie", "handle": "second-hoodie",
                  "published_at": "2026-08-02T10:00:00-04:00", "created_at": "2026-08-02T10:00:00-04:00",
                  "tags": [], "product_type": "Hoodies",
                  "options": [{"name": "Size", "position": 1}],
                  "variants": [{"id": 21, "title": "L", "option1": "L", "available": true, "price": "180.00"}],
                  "images": []
                }]}
                """)

            await poller.tick()

            let events = try await EventModel.query(on: app.db).all()
            #expect(events.count == 1)
            #expect(events.first?.kind == UpdateKind.product.rawValue)
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

/// Records what would have been sent instead of talking to Apple, and can be told to
/// reject a token the way APNs rejects a dead one.
final class RecordingSender: PushSending, @unchecked Sendable {
    private let lock = NSLock()
    private var _sent: [PushMessage] = []
    private var dead: Set<String> = []

    var sent: [PushMessage] { lock.withLock { _sent } }

    func markDead(_ token: String) { lock.withLock { _ = dead.insert(token) } }

    func send(_ message: PushMessage) async throws {
        try lock.withLock {
            if dead.contains(message.deviceToken) { throw PushDeliveryError.invalidToken }
            _sent.append(message)
        }
    }
}

@Suite("Notifications")
struct NotifierTests {
    /// A brand plus one follower holding `profile`, with a device token to push to.
    private func seed(
        _ app: Application,
        profile: SizeProfile = SizeProfile(),
        apnsToken: String? = "token-a"
    ) async throws -> (brandID: UUID, user: UserModel, device: DeviceModel) {
        let brand = BrandModel(
            name: "Kith", slug: "kith.com", website: "https://kith.com",
            instagramHandle: nil, usesGeneratedName: false
        )
        try await brand.save(on: app.db)
        let brandID = try brand.requireID()

        let user = UserModel()
        user.sizeProfile = profile
        try await user.save(on: app.db)
        let userID = try user.requireID()

        let device = DeviceModel(userID: userID, apnsToken: apnsToken, environment: "sandbox", locale: "en_US")
        try await device.save(on: app.db)
        try await FollowModel(userID: userID, brandID: brandID).save(on: app.db)

        return (brandID, user, device)
    }

    @discardableResult
    private func event(
        _ app: Application,
        brandID: UUID,
        kind: UpdateKind,
        sizes: [String] = [],
        productTitle: String? = nil,
        age: TimeInterval = 0
    ) async throws -> EventModel {
        var productID: UUID?
        if let productTitle {
            let product = ProductModel(
                brandID: brandID,
                sourceID: nil,
                item: FetchedItem(
                    externalID: "shopify:\(UUID().uuidString)",
                    title: productTitle,
                    publishedAt: Date(),
                    kind: .product
                )
            )
            try await product.save(on: app.db)
            productID = try product.requireID()
        }

        let event = EventModel(brandID: brandID, productID: productID, kind: kind, sizes: sizes)
        try await event.save(on: app.db)
        if age > 0 {
            // `@Timestamp(on: .create)` only fires on insert, so a second save is how a
            // test gets an event that looks old.
            event.createdAt = Date().addingTimeInterval(-age)
            try await event.save(on: app.db)
        }
        return event
    }

    @Test("A restock only reaches people who wear the size that came back")
    func restockIsSizeTargeted() async throws {
        try await withServer { app in
            var wearsM = SizeProfile()
            wearsM.apparel = ["M"]
            var wearsXL = SizeProfile()
            wearsXL.apparel = ["XL"]

            let (brandID, _, _) = try await seed(app, profile: wearsM, apnsToken: "wears-m")

            // A second follower of the same brand, wearing something else.
            let other = UserModel()
            other.sizeProfile = wearsXL
            try await other.save(on: app.db)
            let otherID = try other.requireID()
            try await DeviceModel(userID: otherID, apnsToken: "wears-xl", environment: "sandbox", locale: nil)
                .save(on: app.db)
            try await FollowModel(userID: otherID, brandID: brandID).save(on: app.db)

            try await event(app, brandID: brandID, kind: .restock, sizes: ["M"], productTitle: "Box Logo Hoodie")

            let sender = RecordingSender()
            let result = await Notifier(app: app, sender: sender).dispatch()

            #expect(result.sent == 1)
            #expect(sender.sent.map(\.deviceToken) == ["wears-m"])
            #expect(sender.sent.first?.title == "Kith")
            #expect(sender.sent.first?.body == "Back in M — Box Logo Hoodie")
        }
    }

    /// The rule that keeps this app installable: a brand dropping a collection writes
    /// hundreds of events in one poll, and that must be one notification.
    @Test("A batch of events is one push per device, not one per event")
    func batchCollapsesToOnePush() async throws {
        try await withServer { app in
            let (brandID, _, _) = try await seed(app)
            for index in 0..<40 {
                try await event(app, brandID: brandID, kind: .product, productTitle: "Item \(index)")
            }
            try await event(app, brandID: brandID, kind: .restock, sizes: ["L"], productTitle: "Old Item")

            let sender = RecordingSender()
            let result = await Notifier(app: app, sender: sender).dispatch()

            #expect(result.events == 41)
            #expect(result.sent == 1)
            #expect(sender.sent.first?.body == "40 new items and 1 restock")
        }
    }

    @Test("An event is never notified twice")
    func neverNotifiesTwice() async throws {
        try await withServer { app in
            let (brandID, _, _) = try await seed(app)
            try await event(app, brandID: brandID, kind: .product, productTitle: "Hoodie")

            let sender = RecordingSender()
            let notifier = Notifier(app: app, sender: sender)
            await notifier.dispatch()
            let second = await notifier.dispatch()

            #expect(sender.sent.count == 1)
            #expect(second.events == 0)

            let unsent = try await EventModel.query(on: app.db).filter(\.$notifiedAt == nil).count()
            #expect(unsent == 0)
        }
    }

    /// After an outage the backlog is history, not news. Firing it would notify people
    /// about drops that sold out hours ago.
    @Test("A stale event is marked notified without being sent")
    func staleEventsAreSkipped() async throws {
        try await withServer { app in
            let (brandID, _, _) = try await seed(app)
            try await event(app, brandID: brandID, kind: .product, productTitle: "Yesterday", age: 48 * 3600)

            let sender = RecordingSender()
            let result = await Notifier(app: app, sender: sender).dispatch()

            #expect(result.events == 1)
            #expect(result.sent == 0)
            #expect(sender.sent.isEmpty)

            let unsent = try await EventModel.query(on: app.db).filter(\.$notifiedAt == nil).count()
            #expect(unsent == 0, "a skipped event must still be marked, or it retries forever")
        }
    }

    @Test("A token APNs rejects is forgotten rather than retried")
    func deadTokensArePruned() async throws {
        try await withServer { app in
            let (brandID, _, device) = try await seed(app, apnsToken: "dead-token")
            try await event(app, brandID: brandID, kind: .product, productTitle: "Hoodie")

            let sender = RecordingSender()
            sender.markDead("dead-token")
            let result = await Notifier(app: app, sender: sender).dispatch()

            #expect(result.prunedTokens == 1)
            #expect(result.sent == 0)

            let stored = try await DeviceModel.find(device.id, on: app.db)
            #expect(stored?.apnsToken == nil)
            #expect(stored != nil, "the device row itself must survive — it owns the follows")
        }
    }

    @Test("With no APNs key the ledger still advances")
    func unconfiguredStillMarks() async throws {
        try await withServer { app in
            let (brandID, _, _) = try await seed(app)
            try await event(app, brandID: brandID, kind: .product, productTitle: "Hoodie")

            let result = await Notifier(app: app, sender: nil).dispatch()

            #expect(result.sent == 0)
            let unsent = try await EventModel.query(on: app.db).filter(\.$notifiedAt == nil).count()
            #expect(unsent == 0, "otherwise the first deploy with a key notifies all of history")
        }
    }

    @Test("Someone who doesn't follow the brand hears nothing")
    func onlyFollowersAreNotified() async throws {
        try await withServer { app in
            let (brandID, _, _) = try await seed(app, apnsToken: "follower")

            let stranger = UserModel()
            try await stranger.save(on: app.db)
            try await DeviceModel(
                userID: try stranger.requireID(), apnsToken: "stranger",
                environment: "sandbox", locale: nil
            ).save(on: app.db)

            try await event(app, brandID: brandID, kind: .product, productTitle: "Hoodie")

            let sender = RecordingSender()
            await Notifier(app: app, sender: sender).dispatch()

            #expect(sender.sent.map(\.deviceToken) == ["follower"])
        }
    }

    /// The shock-drop path: a lock isn't tied to a product or a size, so it goes to
    /// everyone following, regardless of profile.
    @Test("A drop lock reaches every follower whatever they wear")
    func dropLockIgnoresSizes() async throws {
        try await withServer { app in
            var narrow = SizeProfile()
            narrow.apparel = ["XXS"]
            let (brandID, _, _) = try await seed(app, profile: narrow)
            try await event(app, brandID: brandID, kind: .dropLock)

            let sender = RecordingSender()
            await Notifier(app: app, sender: sender).dispatch()

            #expect(sender.sent.count == 1)
            #expect(sender.sent.first?.body == "Storefront just locked — a drop looks imminent")
        }
    }

    @Test("The device's own environment decides which APNs host is used")
    func environmentIsPerDevice() async throws {
        try await withServer { app in
            let (brandID, _, device) = try await seed(app)
            device.environment = "production"
            try await device.save(on: app.db)
            try await event(app, brandID: brandID, kind: .product, productTitle: "Hoodie")

            let sender = RecordingSender()
            await Notifier(app: app, sender: sender).dispatch()

            #expect(sender.sent.first?.environment == "production")
        }
    }
}

@Suite("Retention")
struct RetentionTests {
    private func brand(_ app: Application) async throws -> UUID {
        let brand = BrandModel(
            name: "Kith", slug: "kith.com", website: "https://kith.com",
            instagramHandle: nil, usesGeneratedName: false
        )
        try await brand.save(on: app.db)
        return try brand.requireID()
    }

    private func product(_ app: Application, brandID: UUID, lastSeenDaysAgo: Double) async throws -> ProductModel {
        let product = ProductModel(
            brandID: brandID,
            sourceID: nil,
            item: FetchedItem(
                externalID: "shopify:\(UUID().uuidString)",
                title: "Hoodie",
                publishedAt: Date(),
                kind: .product
            )
        )
        product.lastSeenAt = Date().addingTimeInterval(-lastSeenDaysAgo * 86_400)
        try await product.save(on: app.db)
        return product
    }

    @Test("Old notified events are pruned, unnotified ones are left alone")
    func prunesOldEvents() async throws {
        try await withServer { app in
            let brandID = try await brand(app)

            let old = EventModel(brandID: brandID, productID: nil, kind: .product)
            try await old.save(on: app.db)
            old.createdAt = Date().addingTimeInterval(-60 * 86_400)
            old.notifiedAt = Date().addingTimeInterval(-60 * 86_400)
            try await old.save(on: app.db)

            // Same age, never notified: the notifier's ledger, not the reaper's, decides.
            let unsent = EventModel(brandID: brandID, productID: nil, kind: .product)
            try await unsent.save(on: app.db)
            unsent.createdAt = Date().addingTimeInterval(-60 * 86_400)
            try await unsent.save(on: app.db)

            let recent = EventModel(brandID: brandID, productID: nil, kind: .product)
            try await recent.save(on: app.db)
            recent.notifiedAt = Date()
            try await recent.save(on: app.db)

            let result = await Reaper(app: app, eventDays: 30, productDays: 180).sweep()

            #expect(result.events == 1)
            let remaining = try await EventModel.query(on: app.db).count()
            #expect(remaining == 2)
        }
    }

    /// `events.product_id` cascades, so pruning a product silently deletes feed history.
    /// A product is only ever eligible once its events have already aged out.
    @Test("A product with events is never pruned")
    func productWithEventsSurvives() async throws {
        try await withServer { app in
            let brandID = try await brand(app)
            let kept = try await product(app, brandID: brandID, lastSeenDaysAgo: 400)
            try await EventModel(brandID: brandID, productID: try kept.requireID(), kind: .product)
                .save(on: app.db)

            let result = await Reaper(app: app, eventDays: 30, productDays: 180).sweep()

            #expect(result.products == 0)
            #expect(try await ProductModel.query(on: app.db).count() == 1)
        }
    }

    /// Deleting a product the source still lists would make the next poll see an unknown
    /// external_id and announce it as new — retention inventing a drop.
    @Test("A product still being seen is never pruned, however old the catalog entry")
    func recentlySeenProductSurvives() async throws {
        try await withServer { app in
            let brandID = try await brand(app)
            _ = try await product(app, brandID: brandID, lastSeenDaysAgo: 1)

            let result = await Reaper(app: app, eventDays: 30, productDays: 180).sweep()

            #expect(result.products == 0)
            #expect(try await ProductModel.query(on: app.db).count() == 1)
        }
    }

    @Test("An unseen product with no events left is pruned, and takes its variants")
    func prunesDeadProduct() async throws {
        try await withServer { app in
            let brandID = try await brand(app)
            let doomed = try await product(app, brandID: brandID, lastSeenDaysAgo: 400)
            try await VariantModel(
                productID: try doomed.requireID(),
                info: VariantInfo(id: "11", title: "M", available: true, size: "M")
            ).save(on: app.db)

            let result = await Reaper(app: app, eventDays: 30, productDays: 180).sweep()

            #expect(result.products == 1)
            #expect(try await ProductModel.query(on: app.db).count() == 0)
            #expect(try await VariantModel.query(on: app.db).count() == 0, "orphaned variants must go too")
        }
    }
}

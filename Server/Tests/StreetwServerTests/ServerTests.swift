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

    /// Keyed by path like the gets, so a UCP catalogue read can be stubbed the same way.
    /// Nothing in the server suite exercises one yet — the adapter's own tests live in
    /// `StreetwCoreTests` — but a conformer that traps here would fail the *next* test to
    /// need it rather than this one.
    func post(_ url: URL, json body: Data, accept: String) async throws -> HTTPResponse {
        try await get(url, etag: nil)
    }
}

/// A one-product Shopify catalog whose single variant's stock can be flipped.
private func catalog(available: Bool, size: String = "M", price: String = "180.00") -> String {
    """
    {"products": [{
      "id": 1, "title": "Test Hoodie", "handle": "test-hoodie",
      "published_at": "2026-08-01T10:00:00-04:00", "created_at": "2026-08-01T10:00:00-04:00",
      "tags": ["hoodie"], "product_type": "Hoodies",
      "options": [{"name": "Size", "position": 1}],
      "variants": [{"id": 11, "title": "\(size)", "option1": "\(size)",
                    "available": \(available), "price": "\(price)"}],
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

    /// The poller cannot read a UCP catalogue unless this is publicly reachable — a
    /// business fetches it before answering, and without it every `search_catalog` call
    /// comes back `UCP discovery failed`. It has to be anonymous for the same reason.
    @Test("The agent profile is served, unauthenticated and cacheable")
    func servesTheAgentProfile() async throws {
        try await withServer { app in
            try await app.testing().test(.GET, ".well-known/ucp") { res async throws in
                #expect(res.status == .ok)
                #expect(res.headers.contentType == .json)
                // The spec asks for at least a minute; without it, every page we read
                // costs the merchant a round trip back to us.
                #expect(res.headers.cacheControl?.maxAge ?? 0 >= 60)

                let root = try JSONSerialization.jsonObject(with: Data(buffer: res.body)) as? [String: Any]
                let ucp = try #require(root?["ucp"] as? [String: Any])
                #expect(ucp["version"] as? String == UCPAgent.version)
                let capabilities = try #require(ucp["capabilities"] as? [String: Any])
                #expect(capabilities["dev.ucp.shopping.catalog.search"] != nil)
                // streetw has no cart and cannot check out. Saying otherwise to a merchant
                // would be claiming to be a shop.
                #expect(capabilities["dev.ucp.shopping.checkout"] == nil)
            }
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

    /// Following a brand the poller has watched for months used to hand over nothing: the
    /// feed is a cursor across every followed brand, and that brand's whole history sits
    /// behind it. The brand page opened empty and stayed empty until the next drop.
    @Test("A brand's catch-up reaches behind the feed cursor")
    func brandFeedReturnsHistoryTheCursorHasPassed() async throws {
        try await withServer { app in
            let brand = BrandModel(
                name: "Palace", slug: "palace.com", website: "https://palace.com",
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

            // Deliberately *before* the follow: the client fires both in one breath and the
            // order of two round trips must not decide whether the page has anything on it.
            try await app.testing().test(
                .GET, "v1/brands/\(brandID.uuidString)/feed", headers: auth
            ) { res async throws in
                let feed = try res.content.decode(FeedResponse.self)
                #expect(feed.items.count == 1)
                #expect(feed.items.first?.brandName == "Palace")
                // No cursor. Advancing the device's own feed position from a side query
                // about one brand would skip every other brand's events in the window.
                #expect(feed.nextCursor == nil)
            }
        }
    }

    /// The regression that made the whole size feature inert in the app's default mode.
    ///
    /// The feed used to send `availableInMySize` and nothing else. With no variants on the
    /// client, `isAvailable(in:)` returns true for everything — so the "my size" filter
    /// matched every item — and the size run had nothing to print, so the app's signature
    /// element rendered as blank space on every product that wasn't a restock.
    @Test("The feed ships variants and a gender, not just a badge")
    func feedCarriesVariantsAndGender() async throws {
        try await withServer { app in
            let brand = BrandModel(
                name: "Kith", slug: "kith.com", website: "https://kith.com",
                instagramHandle: nil, usesGeneratedName: false
            )
            try await brand.save(on: app.db)
            let brandID = try brand.requireID()

            let product = ProductModel(
                brandID: brandID,
                sourceID: nil,
                item: FetchedItem(
                    externalID: "shopify:1",
                    title: "Nathan Cargo Pant",
                    publishedAt: Date(),
                    kind: .product,
                    tags: ["mens"]
                )
            )
            try await product.save(on: app.db)
            let productID = try product.requireID()
            for (size, available) in [("S", true), ("M", false), ("L", true)] {
                try await VariantModel(
                    productID: productID,
                    info: VariantInfo(
                        id: "v-\(size)", title: size, available: available,
                        size: size, color: "Black"
                    )
                ).save(on: app.db)
            }
            try await EventModel(brandID: brandID, productID: productID, kind: .product)
                .save(on: app.db)

            var token = ""
            try await app.testing().test(.POST, "v1/devices", beforeRequest: { req in
                try req.content.encode(RegisterDevice())
            }, afterResponse: { res async throws in
                token = try res.content.decode(DeviceResponse.self).token
            })
            let auth = HTTPHeaders([("Authorization", "Bearer \(token)")])
            try await app.testing().test(.POST, "v1/follows", headers: auth, beforeRequest: { req in
                try req.content.encode(FollowBrand(brandID: brandID))
            }, afterResponse: { _ in })

            try await app.testing().test(.GET, "v1/feed", headers: auth) { res async throws in
                let item = try #require(try res.content.decode(FeedResponse.self).items.first)

                let variants = try #require(item.variants)
                #expect(variants.count == 3)
                #expect(variants.filter(\.available).map(\.displaySize) == ["S", "L"])
                #expect(item.itemGender == .mens)

                // What the garment is, beside what happened to it. A feed row is keyed by
                // its event and one product produces several, so without this a link
                // shared from Safari could never be recognised as something the app was
                // already showing — and minted a duplicate card every time.
                #expect(item.productExternalID == product.externalID)
            }
        }
    }

    /// The gender preference is stored in discrete columns rather than an encoded blob,
    /// so a new field on `SizeProfile` is not automatically a new field in the row — it
    /// round-trips through the accessor and is silently dropped. This catches that.
    @Test("A gender preference survives a round trip through the database")
    func genderPreferencePersists() async throws {
        try await withServer { app in
            var token = ""
            try await app.testing().test(.POST, "v1/devices", beforeRequest: { req in
                try req.content.encode(RegisterDevice(
                    sizes: SizePayload(apparel: ["M"], shoe: [], gender: "mens")
                ))
            }, afterResponse: { res async throws in
                token = try res.content.decode(DeviceResponse.self).token
            })

            let device = try #require(
                try await DeviceModel.query(on: app.db).filter(\.$authToken == token).first()
            )
            let user = try await device.$user.get(on: app.db)
            #expect(user.sizeProfile.gender == .mens)

            // And again through the update path, which is what a settings change uses.
            try await app.testing().test(
                .PATCH, "v1/devices/me",
                headers: HTTPHeaders([("Authorization", "Bearer \(token)")]),
                beforeRequest: { req in
                    try req.content.encode(UpdateDevice(
                        sizes: SizePayload(apparel: ["M"], shoe: [], gender: "womens")
                    ))
                }, afterResponse: { _ in }
            )

            let reloaded = try #require(try await UserModel.find(user.id, on: app.db))
            #expect(reloaded.sizeProfile.gender == .womens)
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

    /// Kith runs Shopify Flow automations that unpublish and republish stock in sweeps, and
    /// each sweep restamps `published_at` to now. A fifth of its 250 newest products were
    /// created more than three months before they were "published" — one Air Max 1 by
    /// 1,015 days — and the sold-out ones landed as a page of new clothes you could not
    /// buy. Nothing dropped, so nothing is said; the row is still stored, so a watch on it
    /// still works and a real restock still fires.
    @Test("Re-shelved sold-out stock is stored and not announced")
    func reshelvedSoldOutStockIsSilent() async throws {
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
            // Created in 2023, put back on the shelf today, every size gone.
            http.stub("/products.json?limit=250&page=1", body: """
                {"products": [{
                  "id": 2, "title": "Nike Air Max 1", "handle": "nike-air-max-1",
                  "published_at": "2026-08-11T15:41:05-04:00", "created_at": "2023-10-31T03:47:26-04:00",
                  "tags": [], "product_type": "Low Top Sneakers",
                  "options": [{"name": "Size", "position": 1}],
                  "variants": [{"id": 21, "title": "9", "option1": "9", "available": false, "price": "140.00"}],
                  "images": []
                }]}
                """)

            await poller.tick()

            #expect(try await EventModel.query(on: app.db).count() == 0, "a re-shelving is not a drop")
            let stored = try await ProductModel.query(on: app.db)
                .filter(\.$externalID == "shopify:2")
                .first()
            #expect(stored != nil, "it is still stored — a watch has to be able to reach it")
        }
    }

    /// The same sweep, but the shelf has something on it. That is a restock and not a
    /// discovery — and unlike the sold-out case there is something to act on.
    @Test("Re-shelved stock you can buy is a restock")
    func reshelvedAvailableStockIsARestock() async throws {
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
            http.stub("/products.json?limit=250&page=1", body: """
                {"products": [{
                  "id": 3, "title": "Nike Cortez", "handle": "nike-cortez",
                  "published_at": "2026-08-11T15:41:05-04:00", "created_at": "2023-02-13T03:47:26-04:00",
                  "tags": [], "product_type": "Low Top Sneakers",
                  "options": [{"name": "Size", "position": 1}],
                  "variants": [{"id": 31, "title": "9", "option1": "9", "available": true, "price": "90.00"}],
                  "images": []
                }]}
                """)

            await poller.tick()

            let events = try await EventModel.query(on: app.db).all()
            #expect(events.count == 1)
            #expect(events.first?.kind == UpdateKind.restock.rawValue, "back on the shelf, not new")
        }
    }

    /// Silent product edits are mostly noise, but a markdown on something you follow is
    /// the exception — and it is invisible in `published_at`, which does not change.
    @Test("A price cut produces one priceDrop event")
    func priceCutProducesEvent() async throws {
        try await withServer { app in
            let http = StubHTTP()
            http.stub("/meta.json", body: #"{"name": "Example", "currency": "USD"}"#)
            http.stub("/products.json?limit=250&page=1", body: catalog(available: true, price: "180.00"))
            _ = try await seedBrand(app, http: http)

            let poller = Poller(app: app, http: http)
            await poller.tick()
            #expect(try await EventModel.query(on: app.db).count() == 0)

            let source = try #require(try await SourceModel.query(on: app.db).first())
            source.nextCheckAt = Date().addingTimeInterval(-1)
            try await source.save(on: app.db)
            http.stub("/products.json?limit=250&page=1", body: catalog(available: true, price: "120.00"))

            await poller.tick()

            let events = try await EventModel.query(on: app.db).all()
            #expect(events.count == 1)
            #expect(events.first?.kind == UpdateKind.priceDrop.rawValue)
        }
    }

    /// Exchange-rate drift on a multi-currency storefront must not read as a sale.
    @Test("A trivial price wobble produces nothing")
    func priceWobbleIsIgnored() async throws {
        try await withServer { app in
            let http = StubHTTP()
            http.stub("/meta.json", body: #"{"name": "Example", "currency": "USD"}"#)
            http.stub("/products.json?limit=250&page=1", body: catalog(available: true, price: "180.00"))
            _ = try await seedBrand(app, http: http)

            let poller = Poller(app: app, http: http)
            await poller.tick()

            let source = try #require(try await SourceModel.query(on: app.db).first())
            source.nextCheckAt = Date().addingTimeInterval(-1)
            try await source.save(on: app.db)
            http.stub("/products.json?limit=250&page=1", body: catalog(available: true, price: "178.50"))

            await poller.tick()
            #expect(try await EventModel.query(on: app.db).count() == 0)
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

    /// Two sources on one brand, polled independently. The lock flag was assigned from
    /// inside each source's poll, so whichever ran last won — a genuine lock seen by the
    /// catalog was erased minutes later by the collections endpoint answering normally.
    @Test("One locked source keeps the brand locked, whatever the others say")
    func lockIsDerivedFromAllSources() async throws {
        try await withServer { app in
            let http = StubHTTP()
            let brand = BrandModel(
                name: "Example", slug: "example.com", website: "https://example.com",
                instagramHandle: nil, usesGeneratedName: false
            )
            try await brand.save(on: app.db)
            let brandID = try brand.requireID()

            let catalogSource = SourceModel(brandID: brandID, kind: .shopify, url: "https://example.com")
            try await catalogSource.save(on: app.db)
            let collections = SourceModel(
                brandID: brandID, kind: .collections, url: "https://example.com/collections.json?limit=250"
            )
            try await collections.save(on: app.db)

            // The catalog is locked; collections answers normally.
            http.stub("/products.json?limit=250&page=1", status: 401, body: "")
            http.stub("/collections.json?limit=250", body: #"{"collections": []}"#)
            http.stub("/meta.json", body: #"{"name": "Example", "currency": "USD"}"#)

            await Poller(app: app, http: http).tick()

            let after = try #require(try await BrandModel.find(brandID, on: app.db))
            #expect(after.lockedForDrop, "the open source must not erase the locked one")

            // The store reopens.
            for source in try await SourceModel.query(on: app.db).all() {
                source.nextCheckAt = Date().addingTimeInterval(-1)
                try await source.save(on: app.db)
            }
            http.stub("/products.json?limit=250&page=1", body: catalog(available: true))
            await Poller(app: app, http: http).tick()

            let reopened = try #require(try await BrandModel.find(brandID, on: app.db))
            #expect(!reopened.lockedForDrop)
        }
    }

    /// The Yeezy case. A permanent bot wall answered 403, which read as "drop imminent" —
    /// so the brand showed locked forever *and* the locked cadence retried it every 60
    /// seconds against a site that was already refusing us.
    @Test("A bot challenge is a failing source, not a locked brand")
    func challengeDoesNotLock() async throws {
        try await withServer { app in
            let http = StubHTTP()
            let brand = BrandModel(
                name: "Example", slug: "example.com", website: "https://example.com",
                instagramHandle: nil, usesGeneratedName: false
            )
            try await brand.save(on: app.db)
            let source = SourceModel(brandID: try brand.requireID(), kind: .shopify, url: "https://example.com")
            try await source.save(on: app.db)

            http.stub(
                "/products.json?limit=250&page=1",
                status: 403,
                body: "<!DOCTYPE html><html><head><title>Just a moment...</title></head></html>"
            )

            await Poller(app: app, http: http).tick()

            let after = try #require(try await BrandModel.query(on: app.db).first())
            #expect(!after.lockedForDrop)

            let polled = try #require(try await SourceModel.query(on: app.db).first())
            #expect(polled.failureCount == 1, "it is a failure, and must back off like one")
            #expect(polled.lockedAt == nil)
            // Not the 60-second locked cadence: the first failure backs off to two minutes.
            #expect(polled.nextCheckAt > Date().addingTimeInterval(90))
        }
    }

    /// Palace randomises its product handles until a drop is live, so a sitemap row can
    /// be stored with a hash for a name. Dedupe is on `externalID` and the merge only
    /// ever *refreshed* stock and price, so nothing revisited the title — a feed said
    /// "E7Anvz3I1Psy" for as long as the product existed.
    @Test("A product stored under a randomised handle takes its real name later")
    func provisionalTitleIsUpgraded() async throws {
        try await withServer { app in
            let http = StubHTTP()
            let brand = BrandModel(
                name: "Palace", slug: "example.com", website: "https://example.com",
                instagramHandle: nil, usesGeneratedName: false
            )
            try await brand.save(on: app.db)
            let source = SourceModel(
                brandID: try brand.requireID(), kind: .sitemap, url: "https://example.com/sitemap.xml"
            )
            try await source.save(on: app.db)

            // `lastmod` advances on the second poll, because `since` filtering is how
            // every adapter avoids resurfacing a catalogue — a row is only revisited when
            // the storefront says it moved, which is exactly when its name can change.
            func sitemap(withImage: Bool, modified: Date) -> String {
                let image = withImage ? """
                    <image:image>
                      <image:loc>https://cdn.example.com/avirex-1.png</image:loc>
                      <image:title>PALACE AVIREX JACKET BLACK</image:title>
                    </image:image>
                """ : ""
                return """
                <?xml version="1.0" encoding="UTF-8"?>
                <urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9"
                        xmlns:image="http://www.google.com/schemas/sitemap-image/1.1">
                  <url>
                    <loc>https://example.com/products/e7anvz3i1psy</loc>
                    <lastmod>\(ISO8601DateFormatter().string(from: modified))</lastmod>
                    \(image)
                  </url>
                </urlset>
                """
            }

            http.stub("/sitemap.xml", body: sitemap(withImage: false, modified: Date()))
            let poller = Poller(app: app, http: http)
            await poller.tick()

            var product = try #require(try await ProductModel.query(on: app.db).first())
            #expect(product.title == "New arrival", "a hash is never printed as a name")
            #expect(product.imageURLs.isEmpty)

            source.nextCheckAt = Date().addingTimeInterval(-1)
            try await source.save(on: app.db)
            http.stub("/sitemap.xml", body: sitemap(withImage: true, modified: Date().addingTimeInterval(600)))

            await poller.tick()

            product = try #require(try await ProductModel.query(on: app.db).first())
            #expect(product.title == "PALACE AVIREX JACKET BLACK")
            #expect(product.imageURLs == ["https://cdn.example.com/avirex-1.png"])
            // Renaming a product is not news — it is the same drop, better described.
            #expect(try await EventModel.query(on: app.db).count() == 0)
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

    /// The reported behaviour: "it sends me 2 items, then a bit later another 2 items".
    ///
    /// A storefront publishes a drop over several polls and the poller is on a five-minute
    /// cadence while something is happening, so one release used to arrive as a string of
    /// small pushes. The first sighting must still be immediate — being told late is the one
    /// failure this app cannot afford — and everything after it is held and consolidated.
    @Test("A drop is one alert and then one summary, not a trickle")
    func consolidatesABurstIntoOnePush() async throws {
        try await withServer { app in
            let (brandID, _, _) = try await seed(app)
            try await event(app, brandID: brandID, kind: .product, productTitle: "Chore Jacket")

            let sender = RecordingSender()
            let notifier = Notifier(app: app, sender: sender)

            // The drop is noticed. This goes out at once.
            #expect(await notifier.dispatch().sent == 1)
            #expect(sender.sent.count == 1)

            // The next two polls find more of the same drop. Neither may interrupt again.
            try await event(app, brandID: brandID, kind: .product, productTitle: "Chore Pant")
            #expect(await notifier.dispatch().sent == 0)
            try await event(app, brandID: brandID, kind: .restock, sizes: ["M"], productTitle: "Box Tee")
            #expect(await notifier.dispatch().sent == 0)
            #expect(sender.sent.count == 1)

            // Held, not thrown away: once the cooldown lifts they arrive as one summary.
            let brand = try #require(try await BrandModel.find(brandID, on: app.db))
            brand.lastNotifiedAt = Date().addingTimeInterval(-3600)
            try await brand.save(on: app.db)

            #expect(await notifier.dispatch().sent == 1)
            #expect(sender.sent.count == 2)
            #expect(sender.sent.last?.body == "1 new item and 1 restock")
        }
    }

    /// A brand every follower filters away has not interrupted anybody, and must not be
    /// muted for a quarter of an hour on the strength of it.
    @Test("A push nobody received doesn't start the cooldown")
    func filteredBrandIsNotCooledDown() async throws {
        try await withServer { app in
            var menswear = SizeProfile()
            menswear.gender = .mens
            let (brandID, _, _) = try await seed(app, profile: menswear)

            let product = ProductModel(
                brandID: brandID,
                sourceID: nil,
                item: FetchedItem(
                    externalID: "shopify:w1",
                    title: "Cargo Pant",
                    linkURL: URL(string: "https://kith.com/products/womens-cargo-pant"),
                    publishedAt: Date(),
                    kind: .product,
                    tags: ["womens"]
                )
            )
            try await product.save(on: app.db)
            try await EventModel(brandID: brandID, productID: try product.requireID(), kind: .product)
                .save(on: app.db)

            let sender = RecordingSender()
            let notifier = Notifier(app: app, sender: sender)
            #expect(await notifier.dispatch().sent == 0)

            let brand = try #require(try await BrandModel.find(brandID, on: app.db))
            #expect(brand.lastNotifiedAt == nil)

            // ...so the next thing it publishes, which does pass, goes out immediately.
            try await event(app, brandID: brandID, kind: .product, productTitle: "Chore Jacket")
            #expect(await notifier.dispatch().sent == 1)
        }
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

    /// Being woken at 7am for a women's hoodie is worse than merely seeing one in the
    /// feed, so the gender filter has to apply here first — and to every kind, not just
    /// to restocks the way size targeting does.
    @Test("A push respects the follower's gender preference")
    func pushIsGenderTargeted() async throws {
        try await withServer { app in
            var menswear = SizeProfile()
            menswear.gender = .mens
            let (brandID, _, _) = try await seed(app, profile: menswear)

            let product = ProductModel(
                brandID: brandID,
                sourceID: nil,
                item: FetchedItem(
                    externalID: "shopify:1",
                    title: "Cargo Pant",
                    linkURL: URL(string: "https://kith.com/products/womens-cargo-pant"),
                    publishedAt: Date(),
                    kind: .product,
                    tags: ["womens"]
                )
            )
            try await product.save(on: app.db)
            try await EventModel(
                brandID: brandID, productID: try product.requireID(), kind: .product, sizes: []
            ).save(on: app.db)

            let sender = RecordingSender()
            let result = await Notifier(app: app, sender: sender).dispatch()

            #expect(result.sent == 0)
            #expect(sender.sent.isEmpty)
        }
    }

    /// The other half, and the one that matters more: a brand whose tags say nothing must
    /// still get through, or the filter deletes most of the catalogue.
    @Test("An unclassifiable product is still pushed to a filtered follower")
    func unknownGenderStillPushes() async throws {
        try await withServer { app in
            var menswear = SizeProfile()
            menswear.gender = .mens
            let (brandID, _, _) = try await seed(app, profile: menswear)

            // Billionaire Boys Club's real tags: nothing here says who it is for.
            let product = ProductModel(
                brandID: brandID,
                sourceID: nil,
                item: FetchedItem(
                    externalID: "shopify:2",
                    title: "Arch Logo Hoodie",
                    publishedAt: Date(),
                    kind: .product,
                    tags: ["2026", "F26", "Final Sale"]
                )
            )
            try await product.save(on: app.db)
            try await EventModel(
                brandID: brandID, productID: try product.requireID(), kind: .product, sizes: []
            ).save(on: app.db)

            let sender = RecordingSender()
            #expect(await Notifier(app: app, sender: sender).dispatch().sent == 1)
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

@Suite("Discovery")
struct DiscoveryTests {
    private func brand(_ app: Application, name: String, slug: String) async throws -> UUID {
        let brand = BrandModel(
            name: name, slug: slug, website: "https://\(slug)",
            instagramHandle: nil, usesGeneratedName: false
        )
        try await brand.save(on: app.db)
        return try brand.requireID()
    }

    private func register(_ app: Application) async throws -> (token: String, headers: HTTPHeaders) {
        var token = ""
        try await app.testing().test(.POST, "v1/devices", beforeRequest: { req in
            try req.content.encode(RegisterDevice())
        }, afterResponse: { res async throws in
            token = try res.content.decode(DeviceResponse.self).token
        })
        return (token, HTTPHeaders([("Authorization", "Bearer \(token)")]))
    }

    /// One field takes a name or a link, because a person adding a brand has one of the
    /// two in hand and asking which is a question with no interesting answer.
    @Test("Search matches a name or a pasted URL", arguments: [
        "kith", "KITH", "kith.com", "https://www.kith.com/products/some-tee"
    ])
    func searchMatchesNameOrURL(query: String) async throws {
        try await withServer { app in
            _ = try await brand(app, name: "Kith", slug: "kith.com")
            _ = try await brand(app, name: "Noah", slug: "noahny.com")

            try await app.testing().test(.GET, "v1/brands?q=\(query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)!)") { res async throws in
                let found = try res.content.decode([BrandDTO].self)
                #expect(found.map(\.name) == ["Kith"], "\(query) should find Kith and only Kith")
            }
        }
    }

    /// The whole point of a shared catalog: the second person to add Kith follows the
    /// existing row rather than creating a duplicate.
    @Test("A URL for a brand already in the catalog finds it rather than proposing a new one")
    func searchDedupesByHost() async throws {
        try await withServer { app in
            _ = try await brand(app, name: "Billionaire Boys Club", slug: "bbcicecream.com")

            try await app.testing().test(.GET, "v1/brands?q=bbcicecream.com") { res async throws in
                #expect(try res.content.decode([BrandDTO].self).count == 1)
            }
        }
    }

    @Test("Popular brands are ranked by follower count")
    func popularIsRanked() async throws {
        try await withServer { app in
            let quiet = try await brand(app, name: "Quiet", slug: "quiet.com")
            let loud = try await brand(app, name: "Loud", slug: "loud.com")

            // Three followers for one, one for the other.
            for _ in 0..<3 {
                let user = UserModel()
                try await user.save(on: app.db)
                try await FollowModel(userID: try user.requireID(), brandID: loud).save(on: app.db)
            }
            let single = UserModel()
            try await single.save(on: app.db)
            try await FollowModel(userID: try single.requireID(), brandID: quiet).save(on: app.db)

            let auth = try await register(app).headers
            try await app.testing().test(.GET, "v1/brands/popular", headers: auth) { res async throws in
                let popular = try res.content.decode([PopularBrand].self)
                #expect(popular.map(\.brand.name) == ["Loud", "Quiet"])
                #expect(popular.first?.followers == 3)
            }
        }
    }

    /// The one thing this list must never do. Recommending someone a brand they already
    /// watch reads as broken, and it is the most likely thing to happen by accident
    /// because their own follows are what make a brand popular in the first place.
    @Test("Your own brands are never recommended back to you")
    func popularExcludesOwnFollows() async throws {
        try await withServer { app in
            let mine = try await brand(app, name: "Mine", slug: "mine.com")
            let theirs = try await brand(app, name: "Theirs", slug: "theirs.com")

            let auth = try await register(app)
            let device = try #require(
                try await DeviceModel.query(on: app.db).filter(\.$authToken == auth.token).first()
            )
            try await FollowModel(userID: device.$user.id, brandID: mine).save(on: app.db)

            let other = UserModel()
            try await other.save(on: app.db)
            try await FollowModel(userID: try other.requireID(), brandID: theirs).save(on: app.db)

            try await app.testing().test(.GET, "v1/brands/popular", headers: auth.headers) { res async throws in
                let popular = try res.content.decode([PopularBrand].self)
                #expect(popular.map(\.brand.name) == ["Theirs"])
            }
        }
    }

    /// A recommendation without clothes in it asks someone to judge a wordmark — and a
    /// recommendation whose only photograph is a delivery banner is worse than that.
    @Test("A recommendation carries recent images, and only of clothes")
    func popularCarriesPreviews() async throws {
        try await withServer { app in
            let brandID = try await brand(app, name: "Kith", slug: "kith.com")

            // A policy row among the garments, exactly as storefronts publish them: it has
            // a title, a price and an image, and `/products.json` cannot tell it apart.
            // This one led Represent's card in the real catalogue.
            let titles = ["Worry-Free Purchase", "Gift Card"] + (0..<20).map { "Cargo Pant \($0)" }
            for (index, title) in titles.enumerated() {
                let product = ProductModel(
                    brandID: brandID,
                    sourceID: nil,
                    item: FetchedItem(
                        externalID: "shopify:\(index)",
                        title: title,
                        imageURLStrings: ["https://cdn.shopify.com/\(index).jpg"],
                        publishedAt: Date(),
                        kind: .product
                    )
                )
                try await product.save(on: app.db)
            }

            let follower = UserModel()
            try await follower.save(on: app.db)
            try await FollowModel(userID: try follower.requireID(), brandID: brandID).save(on: app.db)

            let auth = try await register(app).headers
            try await app.testing().test(.GET, "v1/brands/popular", headers: auth) { res async throws in
                let popular = try res.content.decode([PopularBrand].self)
                let previews = try #require(popular.first?.previewImageURLs)

                // Twelve, not three: the brand preview is a grid, and three tiles is not a
                // look at a brand.
                #expect(previews.count == 12)
                // The first two rows are the policy ones. Neither may appear.
                #expect(!previews.contains("https://cdn.shopify.com/0.jpg"), "a policy row is not a garment")
                #expect(!previews.contains("https://cdn.shopify.com/1.jpg"), "a gift card is not a garment")
            }
        }
    }

    /// A prolific storefront must not take the photographs off the brands under it.
    ///
    /// The preview fetch used to be one date-sorted query with a global `LIMIT`, and the
    /// per-brand budget was applied afterwards while grouping the result — which is not a
    /// per-brand budget at all, because the cut already happened in SQL. A brand that
    /// publishes its whole catalogue in one sweep therefore owned the entire window and the
    /// quieter brands came back blank. Against production this cost fourteen of thirty-five
    /// recommendations every photograph they had, and left Represent showing a single
    /// delivery graphic: its garments were all older than the global cut, so the
    /// "everything here reads as promotional" fallback had nothing else left to choose.
    ///
    /// The tell was that a brand's picture count moved when `limit` moved, which a real
    /// per-brand budget can never do — so this asserts on both.
    @Test("A loud brand doesn't take the pictures off a quiet one")
    func popularBudgetsPreviewsPerBrand() async throws {
        try await withServer { app in
            let loud = try await brand(app, name: "Kith", slug: "kith.com")
            let quiet = try await brand(app, name: "Represent", slug: "representclo.com")

            // The quiet brand's garments are the *oldest* rows in the catalogue, which is
            // the whole point: under one global window they fall off the end.
            for index in 0..<12 {
                let product = ProductModel(
                    brandID: quiet,
                    sourceID: nil,
                    item: FetchedItem(
                        externalID: "shopify:quiet-\(index)",
                        title: "Cargo Pant \(index)",
                        imageURLStrings: ["https://cdn.shopify.com/quiet-\(index).jpg"],
                        publishedAt: Date().addingTimeInterval(-86_400 * 30),
                        kind: .product
                    )
                )
                try await product.save(on: app.db)
            }
            // …and its one recent row is a delivery graphic, exactly as Represent's was.
            let banner = ProductModel(
                brandID: quiet,
                sourceID: nil,
                item: FetchedItem(
                    externalID: "shopify:quiet-banner",
                    title: "Worry-Free Purchase",
                    imageURLStrings: ["https://cdn.shopify.com/quiet-banner.png"],
                    publishedAt: Date(),
                    kind: .product
                )
            )
            try await banner.save(on: app.db)

            for index in 0..<200 {
                let product = ProductModel(
                    brandID: loud,
                    sourceID: nil,
                    item: FetchedItem(
                        externalID: "shopify:loud-\(index)",
                        title: "Hoodie \(index)",
                        imageURLStrings: ["https://cdn.shopify.com/loud-\(index).jpg"],
                        publishedAt: Date(),
                        kind: .product
                    )
                )
                try await product.save(on: app.db)
            }

            let follower = UserModel()
            try await follower.save(on: app.db)
            try await FollowModel(userID: try follower.requireID(), brandID: loud).save(on: app.db)
            try await FollowModel(userID: try follower.requireID(), brandID: quiet).save(on: app.db)

            let auth = try await register(app).headers
            for limit in [2, 40] {
                try await app.testing().test(.GET, "v1/brands/popular?limit=\(limit)", headers: auth) { res async throws in
                    let popular = try res.content.decode([PopularBrand].self)
                    let previews = try #require(
                        popular.first { $0.brand.name == "Represent" }?.previewImageURLs
                    )
                    #expect(previews.count == 12, "a quiet brand's own catalogue is its own budget")
                    #expect(
                        !previews.contains("https://cdn.shopify.com/quiet-banner.png"),
                        "with garments in reach the promotional fallback must not fire"
                    )
                }
            }
        }
    }

    @Test("Popular refuses anonymous callers")
    func popularNeedsAuth() async throws {
        try await withServer { app in
            try await app.testing().test(.GET, "v1/brands/popular") { res async in
                #expect(res.status == .unauthorized)
            }
        }
    }

    /// The point of the whole vector machinery: someone who follows a skate brand should
    /// be shown the *other* skate brand ahead of a workwear label that more people follow.
    @Test("Recommendations follow taste, not only headcount")
    func recommendationsUseTaste() async throws {
        try await withServer { app in
            let skateA = try await brand(app, name: "Skate A", slug: "skatea.com")
            let skateB = try await brand(app, name: "Skate B", slug: "skateb.com")
            let workwear = try await brand(app, name: "Workwear", slug: "workwear.com")
            let shoes = try await brand(app, name: "Shoes", slug: "shoes.com")

            func stock(_ id: UUID, type: String, tags: [String], price: Double) async throws {
                for index in 0..<8 {
                    try await ProductModel(
                        brandID: id,
                        sourceID: nil,
                        item: FetchedItem(
                            externalID: "\(id)-\(index)",
                            title: "Item \(index)",
                            publishedAt: Date(),
                            kind: .product,
                            priceAmount: price,
                            tags: tags,
                            productType: type
                        )
                    ).save(on: app.db)
                }
            }
            try await stock(skateA, type: "T-Shirts", tags: ["skate", "graphic"], price: 45)
            try await stock(skateB, type: "T-Shirts", tags: ["skate", "deck"], price: 50)
            try await stock(workwear, type: "Jackets", tags: ["workwear", "utility"], price: 220)
            try await stock(shoes, type: "Footwear", tags: ["running"], price: 130)

            // Workwear is the most-followed brand by a distance, so a pure popularity
            // ranking would put it first.
            for _ in 0..<6 {
                let user = UserModel()
                try await user.save(on: app.db)
                try await FollowModel(userID: try user.requireID(), brandID: workwear).save(on: app.db)
            }
            for _ in 0..<2 {
                let user = UserModel()
                try await user.save(on: app.db)
                try await FollowModel(userID: try user.requireID(), brandID: skateB).save(on: app.db)
                try await FollowModel(userID: try user.requireID(), brandID: shoes).save(on: app.db)
            }

            // Our user follows the other skate brand and nothing else.
            let auth = try await register(app)
            let device = try #require(
                try await DeviceModel.query(on: app.db).filter(\.$authToken == auth.token).first()
            )
            try await FollowModel(userID: device.$user.id, brandID: skateA).save(on: app.db)

            try await app.testing().test(.GET, "v1/brands/popular", headers: auth.headers) { res async throws in
                let popular = try res.content.decode([PopularBrand].self)
                #expect(popular.first?.brand.name == "Skate B",
                        "taste should beat headcount — got \(popular.map(\.brand.name))")
                #expect(popular.first?.vector != nil, "the client needs the vector to re-rank")
                #expect(try #require(popular.first?.affinity) > 0)
            }
        }
    }

    /// Someone with no follows has no taste on record, and popularity is the correct
    /// answer for them rather than a degraded one.
    @Test("A user who follows nothing gets the popular list, not an empty one")
    func noFollowsFallsBackToPopularity() async throws {
        try await withServer { app in
            let loud = try await brand(app, name: "Loud", slug: "loud.com")
            for _ in 0..<3 {
                let user = UserModel()
                try await user.save(on: app.db)
                try await FollowModel(userID: try user.requireID(), brandID: loud).save(on: app.db)
            }

            let auth = try await register(app).headers
            try await app.testing().test(.GET, "v1/brands/popular", headers: auth) { res async throws in
                let popular = try res.content.decode([PopularBrand].self)
                #expect(popular.map(\.brand.name) == ["Loud"])
                #expect(popular.first?.affinity == nil, "no taste on record means no affinity claimed")
            }
        }
    }

    /// The client cannot work this out for itself.
    ///
    /// In server mode the phone never discovers anything and never polls, so the only way
    /// it can know a brand is watched at all is if the follow list says so. It didn't:
    /// `BrandDTO` carried no sources, `Brand.sources` stayed empty on every server-backed
    /// row, and the app then told the truth about its own empty array — "NOT WATCHED" on
    /// every brand in the list, "0 SOURCES" on every brand page, and an empty state
    /// claiming the site could not be watched automatically. All three about brands the
    /// poller was working through on schedule.
    @Test("The follow list says how each brand is watched")
    func followsCarrySources() async throws {
        try await withServer { app in
            let brandID = try await brand(app, name: "Kith", slug: "kith.com")
            try await SourceModel(brandID: brandID, kind: .shopify, url: "https://kith.com/products.json")
                .save(on: app.db)
            try await SourceModel(brandID: brandID, kind: .collections, url: "https://kith.com/collections.json")
                .save(on: app.db)

            let auth = try await register(app)
            let device = try #require(
                try await DeviceModel.query(on: app.db).filter(\.$authToken == auth.token).first()
            )
            try await FollowModel(userID: device.$user.id, brandID: brandID).save(on: app.db)

            try await app.testing().test(.GET, "v1/follows", headers: auth.headers) { res async throws in
                let follows = try res.content.decode([BrandDTO].self)
                let sources = try #require(follows.first).sources
                #expect(sources.map(\.kind).sorted() == ["collections", "shopify"])
                #expect(sources.allSatisfy { $0.isAutomatic })
                #expect(sources.allSatisfy { $0.lastError == nil })
            }
        }
    }

    /// A failing source is the only thing the brand page's "How it's watched" section is
    /// *for*, so the failure has to survive the wire — a source that reports healthy from
    /// the server is worse than one that reports nothing.
    @Test("A source's failure reaches the client")
    func followsCarrySourceFailures() async throws {
        try await withServer { app in
            let brandID = try await brand(app, name: "Kith", slug: "kith.com")
            let source = SourceModel(brandID: brandID, kind: .sitemap, url: "https://kith.com/sitemap.xml")
            source.lastError = "The request timed out."
            source.failureCount = 3
            try await source.save(on: app.db)

            let auth = try await register(app)
            let device = try #require(
                try await DeviceModel.query(on: app.db).filter(\.$authToken == auth.token).first()
            )
            try await FollowModel(userID: device.$user.id, brandID: brandID).save(on: app.db)

            try await app.testing().test(.GET, "v1/follows", headers: auth.headers) { res async throws in
                let brands = try res.content.decode([BrandDTO].self)
                let reported = try #require(brands.first?.sources.first)
                #expect(reported.lastError == "The request timed out.")
                #expect(reported.failureCount == 3)
            }
        }
    }

    /// Every route that hands over a brand hands over its sources, because the client
    /// stores one `Brand` row whichever of them it arrived on — a search result that is
    /// then followed must not overwrite a populated list with an empty one.
    @Test("Search and discovery carry sources too")
    func searchAndDiscoveryCarrySources() async throws {
        try await withServer { app in
            let brandID = try await brand(app, name: "Kith", slug: "kith.com")
            try await SourceModel(brandID: brandID, kind: .shopify, url: "https://kith.com/products.json")
                .save(on: app.db)

            try await app.testing().test(.GET, "v1/brands?q=kith") { res async throws in
                let brands = try res.content.decode([BrandDTO].self)
                let found = try #require(brands.first)
                #expect(found.sources.map(\.kind) == ["shopify"])
            }

            // Discovery of a brand already in the catalog returns the existing row, and it
            // is the same row with the same sources.
            try await app.testing().test(.POST, "v1/brands/discover", beforeRequest: { req in
                try req.content.encode(DiscoverBrand(url: "https://kith.com"))
            }, afterResponse: { res async throws in
                let found = try res.content.decode(BrandDTO.self)
                #expect(found.sources.map(\.kind) == ["shopify"])
            })
        }
    }
}

@Suite("Stock watches")
struct WatchTests {
    /// A brand, a product with variants, and a user following it with a device token.
    private func seed(
        _ app: Application,
        variants: [(size: String, color: String, available: Bool)]
    ) async throws -> (brandID: UUID, productID: UUID, userID: UUID) {
        let brand = BrandModel(
            name: "Kith", slug: "kith.com", website: "https://kith.com",
            instagramHandle: nil, usesGeneratedName: false
        )
        try await brand.save(on: app.db)
        let brandID = try brand.requireID()

        let product = ProductModel(
            brandID: brandID,
            sourceID: nil,
            item: FetchedItem(
                externalID: "shopify:1",
                title: "Nathan Cargo Pant",
                publishedAt: Date(),
                kind: .product
            )
        )
        try await product.save(on: app.db)
        let productID = try product.requireID()

        for variant in variants {
            try await VariantModel(
                productID: productID,
                info: VariantInfo(
                    id: "\(variant.color)-\(variant.size)",
                    title: "\(variant.color) / \(variant.size)",
                    available: variant.available,
                    size: variant.size,
                    color: variant.color
                )
            ).save(on: app.db)
        }

        let user = UserModel()
        try await user.save(on: app.db)
        let userID = try user.requireID()
        try await DeviceModel(userID: userID, apnsToken: "token-a", environment: "sandbox", locale: nil)
            .save(on: app.db)
        try await FollowModel(userID: userID, brandID: brandID).save(on: app.db)

        return (brandID, productID, userID)
    }

    @Test("A watch fires when its exact size and colour come back")
    func firesOnMatch() async throws {
        try await withServer { app in
            let seeded = try await seed(app, variants: [
                ("M", "Black", true), ("L", "Black", false)
            ])
            let watch = WatchModel(
                userID: seeded.userID, brandID: seeded.brandID, productID: seeded.productID,
                size: "M", color: "Black"
            )
            try await watch.save(on: app.db)
            try await EventModel(
                brandID: seeded.brandID, productID: seeded.productID, kind: .restock, sizes: ["M"]
            ).save(on: app.db)

            let sender = RecordingSender()
            let result = await Notifier(app: app, sender: sender).dispatch()

            #expect(result.sent == 1)
            #expect(sender.sent.first?.body == "Back in M — Nathan Cargo Pant")

            let reloaded = try #require(try await WatchModel.find(watch.requireID(), on: app.db))
            #expect(reloaded.firedAt != nil)
            #expect(reloaded.firedSizes == ["M"])
        }
    }

    /// The reason a watch is pinned at all. Watching "this product" on a garment that runs
    /// XS–XXL in four colourways fires on somebody else's size and trains you to ignore it.
    @Test("A watch does not fire on a size or colour it didn't ask for")
    func ignoresOtherVariants() async throws {
        try await withServer { app in
            let seeded = try await seed(app, variants: [
                ("M", "Black", false), ("XL", "Black", true), ("M", "Sand", true)
            ])
            try await WatchModel(
                userID: seeded.userID, brandID: seeded.brandID, productID: seeded.productID,
                size: "M", color: "Black"
            ).save(on: app.db)
            try await EventModel(
                brandID: seeded.brandID, productID: seeded.productID, kind: .restock, sizes: ["XL"]
            ).save(on: app.db)

            let sender = RecordingSender()
            await Notifier(app: app, sender: sender).dispatch()

            // The generic brand summary may still go out; what must not happen is a watch
            // alert claiming the watched variant is back.
            #expect(!sender.sent.contains { $0.body.contains("Back in M") })
        }
    }

    @Test("An unpinned watch fires on anything coming back")
    func anySizeAnyColor() async throws {
        try await withServer { app in
            let seeded = try await seed(app, variants: [("XL", "Sand", true)])
            try await WatchModel(
                userID: seeded.userID, brandID: seeded.brandID, productID: seeded.productID,
                size: nil, color: nil
            ).save(on: app.db)
            try await EventModel(
                brandID: seeded.brandID, productID: seeded.productID, kind: .restock, sizes: ["XL"]
            ).save(on: app.db)

            let sender = RecordingSender()
            #expect(await Notifier(app: app, sender: sender).dispatch().sent == 1)
            #expect(sender.sent.first?.body == "Back in XL — Nathan Cargo Pant")
        }
    }

    /// `fired_at` is the ledger, in the row for the same reason `events.notified_at` is:
    /// a restart or a second pass must not re-fire what already went out.
    @Test("A fired watch never fires again")
    func firesOnlyOnce() async throws {
        try await withServer { app in
            let seeded = try await seed(app, variants: [("M", "Black", true)])
            try await WatchModel(
                userID: seeded.userID, brandID: seeded.brandID, productID: seeded.productID,
                size: "M", color: "Black"
            ).save(on: app.db)
            try await EventModel(
                brandID: seeded.brandID, productID: seeded.productID, kind: .restock, sizes: ["M"]
            ).save(on: app.db)

            let watch = try #require(try await WatchModel.query(on: app.db).first())
            let first = RecordingSender()
            #expect(await Notifier(app: app, sender: first).dispatch().sent == 1)
            let firedAt = try #require(
                try await WatchModel.find(watch.requireID(), on: app.db)?.firedAt
            )

            // A second restock of the same product, with the watch already spent.
            try await EventModel(
                brandID: seeded.brandID, productID: seeded.productID, kind: .restock, sizes: ["M"]
            ).save(on: app.db)

            let second = RecordingSender()
            await Notifier(app: app, sender: second).dispatch()

            // The ordinary brand summary is still allowed through — a restock is real news
            // for a follower. What must not happen is a *watch* alert, and the two are
            // told apart by the collapse id: a summary collapses onto the brand, a watch
            // deliberately does not.
            #expect(!second.sent.contains { $0.collapseID == nil },
                    "the spent watch must not fire a second time")
            #expect(
                try await WatchModel.find(watch.requireID(), on: app.db)?.firedAt == firedAt,
                "the ledger entry must not be rewritten"
            )
        }
    }

    /// A watch is a much stronger statement than a follow. When both would fire, the user
    /// gets the specific one — not the item buried inside "3 restocks", and not both.
    @Test("A watch alert replaces the generic brand summary rather than doubling it")
    func watchSuppressesSummary() async throws {
        try await withServer { app in
            let seeded = try await seed(app, variants: [("M", "Black", true)])
            try await WatchModel(
                userID: seeded.userID, brandID: seeded.brandID, productID: seeded.productID,
                size: "M", color: "Black"
            ).save(on: app.db)
            try await EventModel(
                brandID: seeded.brandID, productID: seeded.productID, kind: .restock, sizes: ["M"]
            ).save(on: app.db)
            // Plenty of other noise from the same brand in the same pass.
            for index in 0..<5 {
                try await EventModel(
                    brandID: seeded.brandID, productID: nil, kind: .product, sizes: []
                ).save(on: app.db)
                _ = index
            }

            let sender = RecordingSender()
            let result = await Notifier(app: app, sender: sender).dispatch()

            #expect(result.sent == 1, "one push, and it should be the watch")
            #expect(sender.sent.first?.body.contains("Nathan Cargo Pant") == true)
        }
    }

    /// A user with no token must not bank a watch that fires the instant they register
    /// one, months after the restock sold out.
    @Test("A watch with no reachable device is still spent")
    func firesWithoutADevice() async throws {
        try await withServer { app in
            let seeded = try await seed(app, variants: [("M", "Black", true)])
            try await DeviceModel.query(on: app.db).delete()

            let watch = WatchModel(
                userID: seeded.userID, brandID: seeded.brandID, productID: seeded.productID,
                size: "M", color: "Black"
            )
            try await watch.save(on: app.db)
            try await EventModel(
                brandID: seeded.brandID, productID: seeded.productID, kind: .restock, sizes: ["M"]
            ).save(on: app.db)

            await Notifier(app: app, sender: RecordingSender()).dispatch()

            let reloaded = try #require(try await WatchModel.find(watch.requireID(), on: app.db))
            #expect(reloaded.firedAt != nil)
        }
    }

    @Test("Creating a watch is idempotent and implies a follow")
    func createIsIdempotent() async throws {
        try await withServer { app in
            let seeded = try await seed(app, variants: [("M", "Black", false)])
            try await FollowModel.query(on: app.db).delete()

            var token = ""
            try await app.testing().test(.POST, "v1/devices", beforeRequest: { req in
                try req.content.encode(RegisterDevice())
            }, afterResponse: { res async throws in
                token = try res.content.decode(DeviceResponse.self).token
            })
            let auth = HTTPHeaders([("Authorization", "Bearer \(token)")])

            let body = CreateWatch(
                brandID: seeded.brandID, productExternalID: "shopify:1", size: "M", color: "Black"
            )
            var firstID: UUID?
            for _ in 0..<2 {
                try await app.testing().test(.POST, "v1/watches", headers: auth, beforeRequest: { req in
                    try req.content.encode(body)
                }, afterResponse: { res async throws in
                    let dto = try res.content.decode(WatchDTO.self)
                    #expect(dto.productExternalID == "shopify:1")
                    if let firstID { #expect(dto.id == firstID) } else { firstID = dto.id }
                })
            }

            #expect(try await WatchModel.query(on: app.db).count() == 1, "a double tap is not two watches")
            // Watching implies following, or nothing ever polls the product.
            #expect(try await FollowModel.query(on: app.db).count() == 1)
        }
    }

    @Test("A watch cannot be deleted by someone who doesn't own it")
    func deleteIsScopedToOwner() async throws {
        try await withServer { app in
            let seeded = try await seed(app, variants: [("M", "Black", false)])
            let watch = WatchModel(
                userID: seeded.userID, brandID: seeded.brandID, productID: seeded.productID,
                size: "M", color: "Black"
            )
            try await watch.save(on: app.db)

            // A different device, i.e. a different user.
            var token = ""
            try await app.testing().test(.POST, "v1/devices", beforeRequest: { req in
                try req.content.encode(RegisterDevice())
            }, afterResponse: { res async throws in
                token = try res.content.decode(DeviceResponse.self).token
            })

            try await app.testing().test(
                .DELETE, "v1/watches/\(try watch.requireID())",
                headers: HTTPHeaders([("Authorization", "Bearer \(token)")])
            ) { res async in
                #expect(res.status == .noContent)
            }

            #expect(try await WatchModel.query(on: app.db).count() == 1,
                    "someone else's watch must survive")
        }
    }
}

/// The probe exists to answer "does push actually work" without waiting for a storefront
/// to restock something. These check it reports the *reason* rather than a count, since
/// "sent 0" is true for three unrelated failures and the whole point is telling them apart.
@Suite("Push probe")
struct ProbeTests {
    /// One device, optionally holding a token. No follows and no events: the probe must
    /// not need either.
    private func device(
        _ app: Application,
        apnsToken: String?,
        environment: String = "sandbox"
    ) async throws -> DeviceModel {
        let user = UserModel()
        try await user.save(on: app.db)
        let device = DeviceModel(
            userID: try user.requireID(),
            apnsToken: apnsToken,
            environment: environment,
            locale: nil
        )
        try await device.save(on: app.db)
        return device
    }

    @Test("A registered device with a token receives the test push")
    func sendsToRegisteredDevice() async throws {
        try await withServer { app in
            _ = try await device(app, apnsToken: "token-a")

            let sender = RecordingSender()
            let result = await Notifier(app: app, sender: sender).probe()

            #expect(result.sent == 1)
            #expect(sender.sent.map(\.deviceToken) == ["token-a"])
            #expect(sender.sent.first?.collapseID == nil,
                    "repeated tests must each be visible, not collapse onto each other")
        }
    }

    /// The failure this whole feature was built to diagnose. The app shipped without an
    /// `aps-environment` entitlement, so iOS refused to issue a token, so every device row
    /// carried a null one — and `/status` still reported `apnsConfigured: true` with a
    /// running poller and a filling feed.
    @Test("A device that never registered a token is reported as such, not as a failure")
    func distinguishesMissingTokenFromFailure() async throws {
        try await withServer { app in
            _ = try await device(app, apnsToken: nil)

            let sender = RecordingSender()
            let result = await Notifier(app: app, sender: sender).probe()

            #expect(result.sent == 0)
            #expect(result.withToken == 0)
            #expect(result.devices.map(\.outcome) == [.noToken])
            #expect(sender.sent.isEmpty)
            #expect(result.summary.contains("aps-environment"),
                    "the summary is the whole deliverable — it must name the actual cause")
        }
    }

    @Test("No APNs key is reported distinctly from having no devices")
    func distinguishesUnconfiguredFromEmpty() async throws {
        try await withServer { app in
            _ = try await device(app, apnsToken: "token-a")

            let unconfigured = await Notifier(app: app, sender: nil).probe()
            #expect(unconfigured.senderConfigured == false)
            #expect(unconfigured.summary.contains("apns not configured"))

            // Same summary shape, different cause: a key exists but nobody is registered.
            try await DeviceModel.query(on: app.db).delete()
            let empty = await Notifier(app: app, sender: RecordingSender()).probe()
            #expect(empty.senderConfigured == true)
            #expect(empty.summary.contains("no devices registered"))
        }
    }

    @Test("A token Apple rejects is forgotten, exactly as in a real pass")
    func prunesDeadToken() async throws {
        try await withServer { app in
            let row = try await device(app, apnsToken: "dead")

            let sender = RecordingSender()
            sender.markDead("dead")
            let result = await Notifier(app: app, sender: sender).probe()

            #expect(result.devices.map(\.outcome) == [.invalidToken])
            let reloaded = try await DeviceModel.find(row.requireID(), on: app.db)
            #expect(reloaded?.apnsToken == nil, "a dead token must not be retried forever")
        }
    }

    @Test("Probing one device leaves the others alone")
    func targetsASingleDevice() async throws {
        try await withServer { app in
            let wanted = try await device(app, apnsToken: "wanted")
            _ = try await device(app, apnsToken: "other")

            let sender = RecordingSender()
            let result = await Notifier(app: app, sender: sender)
                .probe(deviceID: try wanted.requireID())

            #expect(result.devices.count == 1)
            #expect(sender.sent.map(\.deviceToken) == ["wanted"])
        }
    }

    /// A probe must be runnable at any time, including mid-drop, without consequence.
    @Test("Probing writes nothing to the push ledger")
    func leavesPendingEventsAlone() async throws {
        try await withServer { app in
            _ = try await device(app, apnsToken: "token-a")

            let brand = BrandModel(
                name: "Kith", slug: "kith.com", website: "https://kith.com",
                instagramHandle: nil, usesGeneratedName: false
            )
            try await brand.save(on: app.db)
            let event = EventModel(
                brandID: try brand.requireID(), productID: nil, kind: .product, sizes: []
            )
            try await event.save(on: app.db)

            _ = await Notifier(app: app, sender: RecordingSender()).probe()

            let reloaded = try await EventModel.find(event.requireID(), on: app.db)
            #expect(reloaded?.notifiedAt == nil,
                    "a test push must never mark a real event as already notified")
        }
    }
}

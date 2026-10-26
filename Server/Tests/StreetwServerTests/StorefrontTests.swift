import Fluent
import FluentPostgresDriver
import Foundation
import StreetwCore
import Testing
import Vapor
import VaporTesting

@testable import StreetwServer

/// Canned responses keyed by host *and* path, recording every request — `StubHTTP` keys by
/// path alone, and the whole question here is which shop was asked.
final class HostHTTP: HTTPFetching, @unchecked Sendable {
    private let lock = NSLock()
    private var responses: [String: (Int, Data)] = [:]
    private var _requested: [String] = []

    /// Every request made, as "host/path?query", in order.
    var requested: [String] { lock.withLock { _requested } }

    func stub(_ host: String, _ path: String, status: Int = 200, body: String) {
        lock.withLock { responses[host + path] = (status, Data(body.utf8)) }
    }

    func get(_ url: URL, etag: String?) async throws -> HTTPResponse {
        let key = (url.host() ?? "") + url.path + (url.query.map { "?\($0)" } ?? "")
        let hit = lock.withLock { () -> (Int, Data)? in
            _requested.append(key)
            return responses[key]
        }
        guard let hit else { return HTTPResponse(data: Data(), status: 404, finalURL: url) }
        return HTTPResponse(data: hit.1, status: hit.0, finalURL: url)
    }

    func post(_ url: URL, json body: Data, accept: String) async throws -> HTTPResponse {
        try await get(url, etag: nil)
    }
}

/// One Shopify product, priced and in stock.
private func shopifyCatalog(id: Int, title: String, price: String = "180.00") -> String {
    """
    {"products": [{
      "id": \(id), "title": "\(title)", "handle": "item-\(id)",
      "published_at": "2026-08-01T10:00:00-04:00", "created_at": "2026-08-01T10:00:00-04:00",
      "tags": [], "product_type": "Tees",
      "options": [{"name": "Size", "position": 1}],
      "variants": [{"id": \(id * 10), "title": "M", "option1": "M", "available": true, "price": "\(price)"}],
      "images": [{"src": "https://cdn.example.com/\(id).jpg"}]
    }]}
    """
}

private func meta(currency: String, shipsTo: [String] = ["US", "GB", "DE"]) -> String {
    let ships = shipsTo.map { "\"\($0)\"" }.joined(separator: ",")
    return #"{"name": "Example", "currency": "\#(currency)", "ships_to_countries": [\#(ships)]}"#
}

private let catalogPath = "/products.json?limit=250&page=1"

/// A brand on `example.com`, and optionally its British shop on `uk.example.com`.
func seedBrand(
    _ app: Application,
    storefront: Bool,
    baselined: Bool = false
) async throws -> (brandID: UUID, main: SourceModel, shop: StorefrontModel?, shopSource: SourceModel?) {
    let brand = BrandModel(
        name: "Example", slug: "example.com", website: "https://example.com",
        instagramHandle: nil, usesGeneratedName: false
    )
    brand.currency = "USD"
    try await brand.save(on: app.db)
    let brandID = try brand.requireID()
    let main = SourceModel(brandID: brandID, kind: .shopify, url: "https://example.com")
    if baselined { main.baselinedAt = Date().addingTimeInterval(-86_400 * 3) }
    try await main.save(on: app.db)
    guard storefront else { return (brandID, main, nil, nil) }

    let shop = StorefrontModel(brandID: brandID, homeCountry: "GB", url: "https://uk.example.com", currency: "GBP")
    try await shop.save(on: app.db)
    try await Storefronts.add(["GB"], to: shop, on: app.db)
    let source = SourceModel(
        brandID: brandID, kind: .shopify, url: "https://uk.example.com", storefrontID: try shop.requireID()
    )
    if baselined { source.baselinedAt = Date().addingTimeInterval(-86_400 * 3) }
    try await source.save(on: app.db)
    return (brandID, main, shop, source)
}

/// A follower of the brand in `country`, with a device to push to.
@discardableResult
private func follower(
    _ app: Application,
    of brandID: UUID,
    country: String?,
    token: String? = nil
) async throws -> UUID {
    let user = UserModel()
    user.country = country
    try await user.save(on: app.db)
    let userID = try user.requireID()
    try await DeviceModel(userID: userID, apnsToken: token, environment: "sandbox", locale: nil).save(on: app.db)
    try await FollowModel(userID: userID, brandID: brandID).save(on: app.db)
    return userID
}

@Suite("Storefront polling")
struct PollerStorefrontTests {
    /// **The poller must not multiply work for the main shops.** Two otherwise identical
    /// deployments — one with no country switched on, one with Britain on and a British
    /// follower — poll a brand that has no British shop with the same requests, in the same
    /// order, and store the same thing.
    @Test("A brand with only a main shop polls exactly as before")
    func mainShopPollsAsBefore() async throws {
        struct Outcome: Equatable {
            var requests: [String]
            var products: Int
            var events: Int
            var baselined: Bool
        }

        func run(enabled: Set<String>, followerCountry: String?) async throws -> Outcome {
            var outcome = Outcome(requests: [], products: 0, events: 0, baselined: false)
            try await withServer { app in
                app.storefrontCountries = enabled
                let http = HostHTTP()
                http.stub("example.com", catalogPath, body: shopifyCatalog(id: 1, title: "First Tee"))
                http.stub("example.com", "/meta.json", body: meta(currency: "USD"))
                let (brandID, main, _, _) = try await seedBrand(app, storefront: false)
                try await follower(app, of: brandID, country: followerCountry)

                let poller = Poller(app: app, http: http)
                await poller.tick()

                // A second pass with something new in it, so the news path is covered too.
                main.nextCheckAt = Date().addingTimeInterval(-1)
                try await main.update(on: app.db)
                http.stub("example.com", catalogPath, body: shopifyCatalog(id: 2, title: "Second Tee"))
                await poller.tick()

                let source = try #require(try await SourceModel.find(main.id, on: app.db))
                outcome = Outcome(
                    requests: http.requested,
                    products: try await ProductModel.query(on: app.db).count(),
                    events: try await EventModel.query(on: app.db).count(),
                    baselined: source.baselinedAt != nil
                )
            }
            return outcome
        }

        let before = try await run(enabled: [], followerCountry: nil)
        let after = try await run(enabled: ["GB"], followerCountry: "GB")
        #expect(before == after)
        #expect(before.products == 2)
        #expect(before.events == 1, "the second product is news, the first was the baseline")
        #expect(!before.requests.isEmpty)
    }

    @Test("A country's shop is read only while somebody there follows the brand")
    func readOnlyWhileFollowedThere() async throws {
        try await withServer { app in
            app.storefrontCountries = ["GB"]
            let http = HostHTTP()
            http.stub("example.com", catalogPath, body: shopifyCatalog(id: 1, title: "US Tee"))
            http.stub("example.com", "/meta.json", body: meta(currency: "USD"))
            http.stub("uk.example.com", catalogPath, body: shopifyCatalog(id: 1, title: "UK Tee", price: "150.00"))
            http.stub("uk.example.com", "/meta.json", body: meta(currency: "GBP"))
            let (brandID, _, shop, shopSource) = try await seedBrand(app, storefront: true)
            try await follower(app, of: brandID, country: nil)

            let poller = Poller(app: app, http: http)
            await poller.tick()
            #expect(!http.requested.contains { $0.hasPrefix("uk.example.com") },
                    "nobody in Britain follows it, so the British shop is not read")
            #expect(try await SourceModel.find(shopSource?.id, on: app.db)?.lastCheckedAt == nil)

            try await follower(app, of: brandID, country: "GB")
            await poller.tick()
            #expect(http.requested.contains("uk.example.com" + catalogPath))

            let british = try await ProductModel.query(on: app.db).filter(\.$storefrontID == shop?.id).all()
            #expect(british.map(\.title) == ["UK Tee"])
            #expect(british.first?.currency == "GBP")
            #expect(try await EventModel.query(on: app.db).count() == 0, "a shop's first read is its baseline")

            // Its currency is its own, and the brand's is still the main shop's.
            #expect(try await StorefrontModel.find(shop?.id, on: app.db)?.currency == "GBP")
            #expect(try await BrandModel.find(brandID, on: app.db)?.currency == "USD")
        }
    }

    @Test("A country that is not switched on is never read, followed or not")
    func countryNotSwitchedOn() async throws {
        try await withServer { app in
            app.storefrontCountries = []
            let http = HostHTTP()
            http.stub("uk.example.com", catalogPath, body: shopifyCatalog(id: 1, title: "UK Tee"))
            let (brandID, _, _, _) = try await seedBrand(app, storefront: true)
            try await follower(app, of: brandID, country: "GB")

            await Poller(app: app, http: http).tick()
            #expect(!http.requested.contains { $0.hasPrefix("uk.example.com") })
        }
    }

    /// Nothing polls a paused shop, so what it knew is as old as its last follower — and
    /// comparing against it would announce everything since to the first one back.
    @Test("A shop back from a pause starts again from a baseline")
    func lapsedShopRebaselines() async throws {
        for (away, announced) in [(2 * 86_400.0, 0), (3600.0, 1)] {
            try await withServer { app in
                app.storefrontCountries = ["GB"]
                let http = HostHTTP()
                http.stub("uk.example.com", catalogPath, body: shopifyCatalog(id: 7, title: "UK Tee"))
                http.stub("uk.example.com", "/meta.json", body: meta(currency: "GBP"))
                let (brandID, main, _, shopSource) = try await seedBrand(app, storefront: true, baselined: true)
                main.nextCheckAt = Date().addingTimeInterval(3600)
                try await main.update(on: app.db)
                let source = try #require(shopSource)
                source.lastCheckedAt = Date().addingTimeInterval(-away)
                try await source.update(on: app.db)
                try await follower(app, of: brandID, country: "GB")

                await Poller(app: app, http: http).tick()

                #expect(try await EventModel.query(on: app.db).count() == announced,
                        "away \(away)s: \(announced == 0 ? "a baseline" : "news")")
                let after = try #require(try await SourceModel.find(source.id, on: app.db))
                #expect(after.baselinedAt != nil)
            }
        }
    }

    @Test("A price that changed currency between two reads is not a markdown")
    func noMarkdownAcrossCurrencies() async throws {
        try await withServer { app in
            let http = HostHTTP()
            http.stub("example.com", catalogPath, body: shopifyCatalog(id: 1, title: "Tee", price: "200.00"))
            http.stub("example.com", "/meta.json", body: meta(currency: "USD"))
            let (_, main, _, _) = try await seedBrand(app, storefront: false)
            let poller = Poller(app: app, http: http)
            await poller.tick()

            main.nextCheckAt = Date().addingTimeInterval(-1)
            try await main.update(on: app.db)
            http.stub("example.com", catalogPath, body: shopifyCatalog(id: 1, title: "Tee", price: "150.00"))
            http.stub("example.com", "/meta.json", body: meta(currency: "GBP"))
            await poller.tick()

            #expect(try await EventModel.query(on: app.db).count() == 0)
            let product = try #require(try await ProductModel.query(on: app.db).first())
            #expect(product.currency == "GBP")
            #expect(product.priceAmount == 150)
        }
    }
}

// MARK: - Serving

/// Registers a device in `country` over HTTP and follows the brand, returning its bearer header.
private func reader(_ app: Application, country: String?, follows brandID: UUID?) async throws -> HTTPHeaders {
    var token = ""
    try await app.testing().test(.POST, "v1/devices", beforeRequest: { req in
        try req.content.encode(RegisterDevice(country: country))
    }, afterResponse: { res async throws in
        token = try res.content.decode(DeviceResponse.self).token
    })
    let auth = HTTPHeaders([("Authorization", "Bearer \(token)")])
    if let brandID {
        try await app.testing().test(.POST, "v1/follows", headers: auth, beforeRequest: { req in
            try req.content.encode(FollowBrand(brandID: brandID))
        }, afterResponse: { _ in })
    }
    return auth
}

/// A brand with one product and one event in each shop: "US Tee" in the main shop, stored
/// before currencies were, and "UK Tee" in its British shop, in pounds.
func seedBothShops(_ app: Application, shopBaselined: Bool = true) async throws -> UUID {
    let (brandID, main, shop, shopSource) = try await seedBrand(app, storefront: true, baselined: true)
    if !shopBaselined, let shopSource {
        shopSource.baselinedAt = nil
        try await shopSource.update(on: app.db)
    }
    let us = ProductModel(
        brandID: brandID, sourceID: main.id,
        item: FetchedItem(
            externalID: "shopify:1", title: "US Tee", imageURLStrings: ["https://cdn.example.com/1.jpg"],
            publishedAt: Date(), kind: .product, priceText: "$180", priceAmount: 180
        )
    )
    us.currency = nil
    try await us.save(on: app.db)
    try await EventModel(brandID: brandID, productID: try us.requireID(), kind: .product).save(on: app.db)

    let uk = ProductModel(
        brandID: brandID, sourceID: shopSource?.id, storefrontID: shop?.id,
        item: FetchedItem(
            externalID: "shopify:1", title: "UK Tee", imageURLStrings: ["https://cdn.example.com/2.jpg"],
            publishedAt: Date(), kind: .product, priceText: "£150", priceAmount: 150, currency: "GBP"
        )
    )
    try await uk.save(on: app.db)
    try await EventModel(brandID: brandID, productID: try uk.requireID(), storefrontID: shop?.id, kind: .product)
        .save(on: app.db)
    return brandID
}

private func feedTitles(_ app: Application, _ auth: HTTPHeaders, path: String = "v1/feed") async throws -> [FeedItem] {
    var items: [FeedItem] = []
    try await app.testing().test(.GET, path, headers: auth) { res async throws in
        #expect(res.status == .ok)
        items = try res.content.decode(FeedResponse.self).items
    }
    return items
}

@Suite("Storefront serving")
struct StorefrontServingTests {
    @Test("Each reader is served one shop per brand: their country's where it is live, else the main one")
    func oneShopPerBrand() async throws {
        try await withServer { app in
            app.storefrontCountries = ["GB"]
            let brandID = try await seedBothShops(app)
            let american = try await reader(app, country: nil, follows: brandID)
            let british = try await reader(app, country: "gb", follows: brandID)
            let german = try await reader(app, country: "DE", follows: brandID)

            let us = try await feedTitles(app, american)
            #expect(us.map(\.title) == ["US Tee"])
            // Stored before currencies were, and the main shop's — so the brand's.
            #expect(us.first?.currency == "USD")

            let uk = try await feedTitles(app, british)
            #expect(uk.map(\.title) == ["UK Tee"])
            #expect(uk.first?.currency == "GBP")

            #expect(try await feedTitles(app, german).map(\.title) == ["US Tee"],
                    "no shop for Germany: the main shop, exactly as before")

            // A brand's own history, the same way.
            let path = "v1/brands/\(brandID)/feed"
            #expect(try await feedTitles(app, british, path: path).map(\.title) == ["UK Tee"])
            #expect(try await feedTitles(app, american, path: path).map(\.title) == ["US Tee"])

            // And the brand itself describes the shop it is showing.
            func follows(_ auth: HTTPHeaders) async throws -> BrandDTO? {
                var brands: [BrandDTO] = []
                try await app.testing().test(.GET, "v1/follows", headers: auth) { res async throws in
                    brands = try res.content.decode([BrandDTO].self)
                }
                return brands.first
            }
            let ukBrand = try #require(try await follows(british))
            #expect(ukBrand.storefront?.country == "GB")
            #expect(ukBrand.currency == "GBP")
            #expect(ukBrand.sources.map(\.url) == ["https://uk.example.com"])
            let usBrand = try #require(try await follows(american))
            #expect(usBrand.storefront == nil)
            #expect(usBrand.currency == "USD")
            #expect(usBrand.sources.map(\.url) == ["https://example.com"])
        }
    }

    @Test("A country not switched on is served the main shop")
    func notSwitchedOnIsMainShop() async throws {
        try await withServer { app in
            app.storefrontCountries = []
            let brandID = try await seedBothShops(app)
            let british = try await reader(app, country: "GB", follows: brandID)
            #expect(try await feedTitles(app, british).map(\.title) == ["US Tee"])
        }
    }

    @Test("A shop that has never been read is not served")
    func unreadShopIsNotServed() async throws {
        try await withServer { app in
            app.storefrontCountries = ["GB"]
            let brandID = try await seedBothShops(app, shopBaselined: false)
            let british = try await reader(app, country: "GB", follows: brandID)
            #expect(try await feedTitles(app, british).map(\.title) == ["US Tee"])
        }
    }

    /// Discover is about brands the caller does not follow, so "is the shop live" there means
    /// "does somebody else in that country follow it" — a shop nobody there follows is not
    /// being read, and its prices are as old as its last follower.
    @Test("Discover deals the caller's country's shop while somebody there keeps it read")
    func discoverServesTheLiveShop() async throws {
        try await withServer { app in
            app.storefrontCountries = ["GB"]
            let brandID = try await seedBothShops(app)

            func titles(_ auth: HTTPHeaders) async throws -> [String] {
                var cards: [DiscoverCard] = []
                try await app.testing().test(.GET, "v1/discover", headers: auth) { res async throws in
                    cards = try res.content.decode(DiscoverResponse.self).cards
                }
                return cards.map(\.title)
            }

            let browsing = try await reader(app, country: "GB", follows: nil)
            #expect(try await titles(browsing) == ["US Tee"], "nobody in Britain follows it yet")

            let follower = try await reader(app, country: "GB", follows: brandID)
            _ = follower
            #expect(try await titles(browsing) == ["UK Tee"])
            #expect(try await titles(try await reader(app, country: nil, follows: nil)) == ["US Tee"])
        }
    }

    @Test("A push comes from the shop serving each follower")
    func pushesFromTheServingShop() async throws {
        try await withServer { app in
            app.storefrontCountries = ["GB"]
            let brandID = try await seedBothShops(app)
            try await follower(app, of: brandID, country: nil, token: "american")
            try await follower(app, of: brandID, country: "GB", token: "british")

            let sender = RecordingSender()
            await Notifier(app: app, sender: sender).dispatch()

            let bodies = Dictionary(uniqueKeysWithValues: sender.sent.map { ($0.deviceToken, $0.body) })
            #expect(bodies["american"] == "New: US Tee")
            #expect(bodies["british"] == "New: UK Tee")
            #expect(sender.sent.count == 2, "one push each, never one per shop")
        }
    }
}

// MARK: - The user's country

@Suite("A user's country")
struct UserCountryTests {
    @Test("Registration and updates store it; empty clears it; anything else is ignored, never refused")
    func storesTheCountry() async throws {
        try await withServer { app in
            let auth = try await reader(app, country: "gb", follows: nil)
            func stored() async throws -> String? {
                try await UserModel.query(on: app.db).first()?.country
            }
            #expect(try await stored() == "GB")

            func patch(_ body: UpdateDevice) async throws {
                try await app.testing().test(.PATCH, "v1/devices/me", headers: auth, beforeRequest: { req in
                    try req.content.encode(body)
                }, afterResponse: { res async throws in
                    #expect(res.status == .noContent)
                })
            }
            try await patch(UpdateDevice(country: "de"))
            #expect(try await stored() == "DE")

            // The sizes push says nothing about the country, and must not clear it.
            try await patch(UpdateDevice(sizes: SizePayload(apparel: ["M"], shoe: [])))
            #expect(try await stored() == "DE")

            try await patch(UpdateDevice(country: "Deutschland"))
            #expect(try await stored() == "DE", "not a code: ignored, and the request still succeeds")

            try await patch(UpdateDevice(country: ""))
            #expect(try await stored() == nil)
        }
    }

    @Test("STOREFRONT_COUNTRIES is read as codes, and nonsense is dropped")
    func readsTheAllowList() {
        #expect(Storefronts.countries(from: "GB, de ,FR") == ["GB", "DE", "FR"])
        #expect(Storefronts.countries(from: "GB,United Kingdom,") == ["GB"])
        #expect(Storefronts.countries(from: nil).isEmpty)
    }

    @Test("The rule, without a database")
    func servingRule() {
        let on: Set<String> = ["GB"]
        let gb: Set<String> = ["GB"]
        #expect(Storefronts.serves(countries: gb, to: "gb", enabled: on, isRead: true, baselined: true))
        #expect(!Storefronts.serves(countries: gb, to: "GB", enabled: [], isRead: true, baselined: true))
        #expect(!Storefronts.serves(countries: gb, to: "GB", enabled: on, isRead: false, baselined: true))
        #expect(!Storefronts.serves(countries: gb, to: "GB", enabled: on, isRead: true, baselined: false))
        #expect(!Storefronts.serves(countries: gb, to: "DE", enabled: on, isRead: true, baselined: true))
        #expect(!Storefronts.serves(countries: gb, to: nil, enabled: on, isRead: true, baselined: true))

        // A regional shop serves each of its countries that is switched on, and no other.
        let europe: Set<String> = ["DE", "FR", "IT"]
        let some: Set<String> = ["DE", "FR"]
        #expect(Storefronts.serves(countries: europe, to: "DE", enabled: some, isRead: true, baselined: true))
        #expect(Storefronts.serves(countries: europe, to: "FR", enabled: some, isRead: true, baselined: true))
        #expect(!Storefronts.serves(countries: europe, to: "IT", enabled: some, isRead: true, baselined: true),
                "Italy is in the set and not switched on")
        #expect(!Storefronts.serves(countries: europe, to: "ES", enabled: ["ES"], isRead: true, baselined: true))
    }

    @Test("A shop is read while any of its switched-on countries has a follower")
    func readRule() {
        let brand = UUID()
        let followedInItaly: Set<Storefronts.Following> = [.init(brand: brand, country: "IT")]
        #expect(Storefronts.isRead(["DE", "IT"], brand: brand, enabled: ["DE", "IT"], followed: followedInItaly))
        #expect(!Storefronts.isRead(["DE", "IT"], brand: brand, enabled: ["DE"], followed: followedInItaly),
                "the only follower is in a country not switched on")
        #expect(!Storefronts.isRead(["DE", "IT"], brand: UUID(), enabled: ["DE", "IT"], followed: followedInItaly))
    }

    @Test("Countries are read from a list, `all`, or nothing — and nonsense refuses the whole request")
    func readsRequestedCountries() {
        #expect(Storefronts.requested([]) == .unnamed)
        #expect(Storefronts.requested([""]) == .unnamed)
        #expect(Storefronts.requested(["all"]) == .all)
        #expect(Storefronts.requested(["de, fr", "IT"]) == .these(["DE", "FR", "IT"]))
        #expect(Storefronts.requested(["DE,Deutschland"]) == .invalid(["Deutschland"]))
    }
}

// MARK: - Attaching a shop

@Suite("Attaching a country's shop")
struct StorefrontAdminTests {
    private func stubbedShops(_ app: Application, ukShipsTo: [String] = ["GB"]) -> HostHTTP {
        let http = HostHTTP()
        http.stub("example.com", catalogPath, body: shopifyCatalog(id: 1, title: "US Tee"))
        http.stub("example.com", "/meta.json", body: meta(currency: "USD"))
        http.stub("uk.example.com", catalogPath, body: shopifyCatalog(id: 1, title: "UK Tee"))
        http.stub("uk.example.com", "/meta.json", body: meta(currency: "GBP", shipsTo: ukShipsTo))
        app.storage[FetcherKey.self] = http
        return http
    }

    private func post(_ app: Application, _ path: String) async throws -> String {
        var body = ""
        try await app.testing().test(.POST, path, headers: adminAuth) { res async throws in
            #expect(res.status == .ok)
            body = res.body.string
        }
        return body
    }

    @Test("A shop is attached by URL, with its own sources and currency")
    func attaches() async throws {
        try await withServer { app in
            _ = stubbedShops(app)
            let (brandID, _, _, _) = try await seedBrand(app, storefront: false)

            let said = try await post(app, "admin/brands/\(brandID)/storefronts?country=gb&url=https://uk.example.com")
            #expect(said.contains("uk.example.com serves GB in GBP"))
            let shop = try #require(try await StorefrontModel.query(on: app.db).first())
            #expect(shop.homeCountry == "GB")
            #expect(shop.currency == "GBP")
            let sources = try await SourceModel.query(on: app.db).filter(\.$storefront.$id == shop.id).all()
            #expect(sources.map(\.url) == ["https://uk.example.com"])
            #expect(sources.allSatisfy { $0.baselinedAt == nil }, "its first read is a baseline")
        }
    }

    @Test("The catalogue the main shop already reads is refused")
    func refusesTheSameCatalogue() async throws {
        try await withServer { app in
            _ = stubbedShops(app)
            let (brandID, _, _, _) = try await seedBrand(app, storefront: false)
            let said = try await post(app, "admin/brands/\(brandID)/storefronts?country=GB&url=https://example.com")
            #expect(said.hasPrefix("refused"))
            #expect(try await StorefrontModel.query(on: app.db).count() == 0)
        }
    }

    @Test("A shop that says it does not ship there is refused unless forced")
    func refusesWhereItDoesNotShip() async throws {
        try await withServer { app in
            _ = stubbedShops(app, ukShipsTo: ["GB", "JE"])
            let (brandID, _, _, _) = try await seedBrand(app, storefront: false)
            let path = "admin/brands/\(brandID)/storefronts?country=DE&url=https://uk.example.com"
            #expect(try await post(app, path).hasPrefix("refused"))
            #expect(try await StorefrontModel.query(on: app.db).count() == 0)

            #expect(!(try await post(app, path + "&force=true")).hasPrefix("refused"))
            #expect(try await StorefrontModel.query(on: app.db).with(\.$countries).first()?.countryCodes == ["DE"])
        }
    }

    @Test("Removing a shop takes what was read from it, and repointing the brand leaves it alone")
    func removesAndSurvivesRepoint() async throws {
        try await withServer { app in
            _ = stubbedShops(app)
            app.storefrontCountries = ["GB"]
            let brandID = try await seedBothShops(app)

            _ = try await post(app, "admin/brands/\(brandID)/repoint?url=https://example.com")
            let shop = try #require(try await StorefrontModel.query(on: app.db).first())
            #expect(try await SourceModel.query(on: app.db).filter(\.$storefront.$id == shop.id).count() == 1)
            #expect(try await ProductModel.query(on: app.db).filter(\.$storefrontID == shop.id).count() == 1,
                    "repointing rebuilt the main shop and nothing else")

            let said = try await post(app, "admin/brands/\(brandID)/storefronts/gb/delete")
            #expect(said.contains("1 product"))
            #expect(try await StorefrontModel.query(on: app.db).count() == 0)
            #expect(try await SourceModel.query(on: app.db).filter(\.$storefront.$id != nil).count() == 0)
            #expect(try await ProductModel.query(on: app.db).filter(\.$storefrontID != nil).count() == 0)
            #expect(try await EventModel.query(on: app.db).filter(\.$storefrontID != nil).count() == 0)
        }
    }
}

// MARK: - One shop, several countries

/// A brand on `example.com` and its European shop on `eu.example.com`, serving `countries`,
/// with one event in each: "US Tee" in the main shop, "EU Tee" in euros in the European one.
private func seedEurope(
    _ app: Application,
    countries: Set<String> = ["DE", "FR", "IT"],
    baselined: Bool = true
) async throws -> (brandID: UUID, shop: StorefrontModel, shopSource: SourceModel) {
    let (brandID, main, _, _) = try await seedBrand(app, storefront: false, baselined: baselined)
    let shop = StorefrontModel(
        brandID: brandID, homeCountry: countries.sorted()[0], url: "https://eu.example.com", currency: "EUR"
    )
    try await shop.save(on: app.db)
    try await Storefronts.add(countries, to: shop, on: app.db)
    let source = SourceModel(
        brandID: brandID, kind: .shopify, url: "https://eu.example.com", storefrontID: try shop.requireID()
    )
    if baselined { source.baselinedAt = Date().addingTimeInterval(-86_400 * 3) }
    try await source.save(on: app.db)

    let us = ProductModel(
        brandID: brandID, sourceID: main.id,
        item: FetchedItem(
            externalID: "shopify:1", title: "US Tee", imageURLStrings: ["https://cdn.example.com/1.jpg"],
            publishedAt: Date(), kind: .product, priceText: "$180", priceAmount: 180, currency: "USD"
        )
    )
    try await us.save(on: app.db)
    try await EventModel(brandID: brandID, productID: try us.requireID(), kind: .product).save(on: app.db)
    let eu = ProductModel(
        brandID: brandID, sourceID: source.id, storefrontID: shop.id,
        item: FetchedItem(
            externalID: "shopify:1", title: "EU Tee", imageURLStrings: ["https://cdn.example.com/3.jpg"],
            publishedAt: Date(), kind: .product, priceText: "€170", priceAmount: 170, currency: "EUR"
        )
    )
    try await eu.save(on: app.db)
    try await EventModel(brandID: brandID, productID: try eu.requireID(), storefrontID: shop.id, kind: .product)
        .save(on: app.db)
    return (brandID, shop, source)
}

@Suite("A shop for several countries")
struct MultiCountryStorefrontTests {
    @Test("A German and a French follower are both served the European shop; Italy, not switched on, the main one")
    func servedAcrossItsCountries() async throws {
        try await withServer { app in
            app.storefrontCountries = ["DE", "FR"]
            let (brandID, _, _) = try await seedEurope(app)
            let german = try await reader(app, country: "DE", follows: brandID)
            let french = try await reader(app, country: "FR", follows: brandID)
            let italian = try await reader(app, country: "IT", follows: brandID)
            let american = try await reader(app, country: nil, follows: brandID)

            let de = try await feedTitles(app, german)
            #expect(de.map(\.title) == ["EU Tee"])
            #expect(de.first?.currency == "EUR")
            #expect(try await feedTitles(app, french).map(\.title) == ["EU Tee"])
            #expect(try await feedTitles(app, italian).map(\.title) == ["US Tee"],
                    "Italy is in the shop's set, but not switched on")
            #expect(try await feedTitles(app, american).map(\.title) == ["US Tee"])

            func follows(_ auth: HTTPHeaders) async throws -> BrandDTO? {
                var brands: [BrandDTO] = []
                try await app.testing().test(.GET, "v1/follows", headers: auth) { res async throws in
                    brands = try res.content.decode([BrandDTO].self)
                }
                return brands.first
            }
            let shop = try #require(try await follows(french)?.storefront)
            #expect(shop.url == "https://eu.example.com")
            #expect(shop.servedCountries == ["DE", "FR", "IT"])
            #expect(shop.country == "DE", "one of its countries, for a client that reads no set")
            #expect(try await follows(italian)?.storefront == nil)

            // And a push each, from the shop that serves them.
            try await follower(app, of: brandID, country: "DE", token: "german")
            try await follower(app, of: brandID, country: "FR", token: "french")
            try await follower(app, of: brandID, country: "IT", token: "italian")
            let sender = RecordingSender()
            await Notifier(app: app, sender: sender).dispatch()
            let bodies = Dictionary(uniqueKeysWithValues: sender.sent.map { ($0.deviceToken, $0.body) })
            #expect(bodies["german"] == "New: EU Tee")
            #expect(bodies["french"] == "New: EU Tee")
            #expect(bodies["italian"] == "New: US Tee")
        }
    }

    /// Discover is about brands the caller does not follow, so "is the shop read" may be on
    /// another of its countries' account.
    @Test("Somebody browsing from France is dealt the European shop a German follower keeps read")
    func discoverAcrossCountries() async throws {
        try await withServer { app in
            app.storefrontCountries = ["DE", "FR"]
            let (brandID, _, _) = try await seedEurope(app)
            func titles(_ auth: HTTPHeaders) async throws -> [String] {
                var cards: [DiscoverCard] = []
                try await app.testing().test(.GET, "v1/discover", headers: auth) { res async throws in
                    cards = try res.content.decode(DiscoverResponse.self).cards
                }
                return cards.map(\.title)
            }
            let browsing = try await reader(app, country: "FR", follows: nil)
            #expect(try await titles(browsing) == ["US Tee"], "nobody in any of its countries follows it")
            _ = try await reader(app, country: "IT", follows: brandID)
            #expect(try await titles(browsing) == ["US Tee"], "an Italian follower does not keep it read: Italy is off")
            _ = try await reader(app, country: "DE", follows: brandID)
            #expect(try await titles(browsing) == ["EU Tee"])
        }
    }

    @Test("A shop is polled once per tick, not once per country it serves")
    func polledOncePerTick() async throws {
        try await withServer { app in
            app.storefrontCountries = ["DE", "FR", "IT"]
            let http = HostHTTP()
            http.stub("example.com", catalogPath, body: shopifyCatalog(id: 1, title: "US Tee"))
            http.stub("example.com", "/meta.json", body: meta(currency: "USD"))
            http.stub("eu.example.com", catalogPath, body: shopifyCatalog(id: 1, title: "EU Tee", price: "170.00"))
            http.stub("eu.example.com", "/meta.json", body: meta(currency: "EUR"))
            let (brandID, shop, shopSource) = try await seedEurope(app, baselined: false)
            for country in ["DE", "FR", "IT"] { try await follower(app, of: brandID, country: country) }

            #expect(try await Storefronts.wanted(enabled: app.storefrontCountries, on: app.db) == [try shop.requireID()])
            await Poller(app: app, http: http).tick()
            #expect(http.requested.filter { $0 == "eu.example.com" + catalogPath }.count == 1)
            let after = try #require(try await SourceModel.find(shopSource.id, on: app.db))
            #expect(after.baselinedAt != nil)
        }
    }

    @Test("A shop with a follower only in a country not switched on is not read")
    func notReadForACountryThatIsOff() async throws {
        try await withServer { app in
            app.storefrontCountries = ["DE"]
            let http = HostHTTP()
            let (brandID, _, _) = try await seedEurope(app, baselined: false)
            try await follower(app, of: brandID, country: "IT")
            #expect(try await Storefronts.wanted(enabled: app.storefrontCountries, on: app.db).isEmpty)
            await Poller(app: app, http: http).tick()
            #expect(!http.requested.contains { $0.hasPrefix("eu.example.com") })
        }
    }

    @Test("A brand with only a main shop is served exactly as before with countries switched on")
    func mainShopOnly() async throws {
        try await withServer { app in
            app.storefrontCountries = ["DE", "FR"]
            let (brandID, main, _, _) = try await seedBrand(app, storefront: false, baselined: true)
            let product = ProductModel(
                brandID: brandID, sourceID: main.id,
                item: FetchedItem(
                    externalID: "shopify:1", title: "US Tee", imageURLStrings: ["https://cdn.example.com/1.jpg"],
                    publishedAt: Date(), kind: .product, priceText: "$180", priceAmount: 180
                )
            )
            try await product.save(on: app.db)
            try await EventModel(brandID: brandID, productID: try product.requireID(), kind: .product).save(on: app.db)
            let german = try await reader(app, country: "DE", follows: brandID)

            let items = try await feedTitles(app, german)
            #expect(items.map(\.title) == ["US Tee"])
            #expect(items.first?.currency == "USD")
            try await app.testing().test(.GET, "v1/follows", headers: german) { res async throws in
                let brand = try #require(try res.content.decode([BrandDTO].self).first)
                #expect(brand.storefront == nil)
                #expect(brand.sources.map(\.url) == ["https://example.com"])
            }
            #expect(try await Storefronts.wanted(enabled: app.storefrontCountries, on: app.db).isEmpty)
        }
    }

    /// phase-2's schema has `storefronts.country` and no `storefront_countries`; running the
    /// migration over it must serve everybody exactly what they were, and touch no source.
    @Test("The migration gives each existing shop its one country and leaves its sources alone")
    func migratesExistingShops() async throws {
        try await withServer { app in
            let (_, _, shop, shopSource) = try await seedBrand(app, storefront: true, baselined: true)
            let source = try #require(shopSource)
            source.lastCheckedAt = Date().addingTimeInterval(-600)
            try await source.update(on: app.db)
            let before = try #require(try await SourceModel.find(source.id, on: app.db))

            try await CreateStorefrontCountries().revert(on: app.db)
            try await CreateStorefrontCountries().prepare(on: app.db)

            let rows = try await StorefrontCountryModel.query(on: app.db).all()
            #expect(rows.map(\.country) == ["GB"])
            #expect(rows.first?.$storefront.id == shop?.id)
            #expect(rows.first?.brandID == shop?.$brand.id)
            let after = try #require(try await SourceModel.find(source.id, on: app.db))
            #expect(after.baselinedAt == before.baselinedAt)
            #expect(after.lastCheckedAt == before.lastCheckedAt)
            #expect(after.nextCheckAt == before.nextCheckAt)
        }
    }

    @Test("No two shops of one brand can serve one country")
    func uniquePerBrandAndCountry() async throws {
        try await withServer { app in
            let (brandID, _, _) = try await seedEurope(app, countries: ["DE", "FR"])
            let other = StorefrontModel(brandID: brandID, homeCountry: "GB", url: "https://uk.example.com", currency: "GBP")
            try await other.save(on: app.db)
            await #expect(throws: (any Error).self) {
                try await Storefronts.add(["FR"], to: other, on: app.db)
            }
        }
    }
}

/// The claim itself, which only Postgres runs: SQLite has neither `SKIP LOCKED` nor `= ANY`, so
/// on SQLite the poller takes `dueWithoutClaim` and the suites above never reach the statement
/// that decides which shops are fetched. Runs only when `STREETW_TEST_POSTGRES_URL` names a
/// scratch database — the whole migration chain is applied and reverted, as `CreditRaceTests`
/// does.
@Suite(
    "Storefront claims on Postgres",
    .enabled(if: ProcessInfo.processInfo.environment["STREETW_TEST_POSTGRES_URL"] != nil),
    .serialized
)
struct StorefrontPostgresClaimTests {
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

    @Test("The claim reads a regional shop once for all its followers, and never for a country that is off")
    func claimsTheShopOnce() async throws {
        try await withPostgres { app in
            app.storefrontCountries = ["DE", "FR"]
            let http = HostHTTP()
            http.stub("example.com", catalogPath, body: shopifyCatalog(id: 1, title: "US Tee"))
            http.stub("example.com", "/meta.json", body: meta(currency: "USD"))
            http.stub("eu.example.com", catalogPath, body: shopifyCatalog(id: 1, title: "EU Tee", price: "170.00"))
            http.stub("eu.example.com", "/meta.json", body: meta(currency: "EUR"))
            let (brandID, shop, shopSource) = try await seedEurope(app, baselined: false)

            // Only Italy follows, and Italy is off: the main shop is claimed, the European one not.
            try await follower(app, of: brandID, country: "IT")
            let poller = Poller(app: app, http: http)
            await poller.tick()
            #expect(http.requested.contains("example.com" + catalogPath))
            #expect(!http.requested.contains { $0.hasPrefix("eu.example.com") })
            #expect(try await SourceModel.find(shopSource.id, on: app.db)?.lastCheckedAt == nil)

            // Germany and France follow: one claim, one read.
            try await follower(app, of: brandID, country: "DE")
            try await follower(app, of: brandID, country: "FR")
            await poller.tick()
            #expect(http.requested.filter { $0 == "eu.example.com" + catalogPath }.count == 1)
            let read = try #require(try await SourceModel.find(shopSource.id, on: app.db))
            #expect(read.baselinedAt != nil)
            #expect(try await ProductModel.query(on: app.db).filter(\.$storefrontID == shop.id).count() == 1)
        }
    }
}

@Suite("Attaching a shop for several countries")
struct MultiCountryAdminTests {
    private func stubbed(_ app: Application) -> HostHTTP {
        let http = HostHTTP()
        http.stub("example.com", catalogPath, body: shopifyCatalog(id: 1, title: "US Tee"))
        http.stub("example.com", "/meta.json", body: meta(currency: "USD"))
        http.stub("eu.example.com", catalogPath, body: shopifyCatalog(id: 1, title: "EU Tee"))
        http.stub("eu.example.com", "/meta.json", body: meta(currency: "EUR", shipsTo: ["DE", "FR", "IT", "ES", "GB", "US"]))
        http.stub("uk.example.com", catalogPath, body: shopifyCatalog(id: 1, title: "UK Tee"))
        http.stub("uk.example.com", "/meta.json", body: meta(currency: "GBP", shipsTo: ["GB", "IE"]))
        app.storage[FetcherKey.self] = http
        return http
    }

    private func post(_ app: Application, _ path: String, json: [String]? = nil) async throws -> String {
        var body = ""
        try await app.testing().test(.POST, path, headers: adminAuth, beforeRequest: { req in
            if let json { try req.content.encode(StorefrontAdmin.CountriesBody(countries: json)) }
        }, afterResponse: { res async throws in
            #expect(res.status == .ok)
            body = res.body.string
        })
        return body
    }

    private func served(_ app: Application) async throws -> [String: [String]] {
        let shops = try await StorefrontModel.query(on: app.db).with(\.$countries).all()
        return Dictionary(uniqueKeysWithValues: shops.map { ($0.url, $0.countryCodes) })
    }

    @Test("One read, several countries — by query or by body")
    func attachesSeveral() async throws {
        try await withServer { app in
            _ = stubbed(app)
            let (brandID, _, _, _) = try await seedBrand(app, storefront: false)
            let said = try await post(app, "admin/brands/\(brandID)/storefronts?url=https://eu.example.com&countries=de,FR")
            #expect(said.contains("serves DE,FR in EUR"))
            #expect(try await served(app) == ["https://eu.example.com": ["DE", "FR"]])
            #expect(try await SourceModel.query(on: app.db).filter(\.$storefront.$id != nil).count() == 1,
                    "one shop, read once")

            // The same shop again is refused, and pointed at `add`.
            let again = try await post(app, "admin/brands/\(brandID)/storefronts?url=https://eu.example.com&countries=IT")
            #expect(again.hasPrefix("refused"))
            #expect(again.contains("/add?countries="))
        }
        try await withServer { app in
            _ = stubbed(app)
            let (brandID, _, _, _) = try await seedBrand(app, storefront: false)
            _ = try await post(app, "admin/brands/\(brandID)/storefronts?url=https://eu.example.com", json: ["DE", "IT"])
            #expect(try await served(app) == ["https://eu.example.com": ["DE", "IT"]])
        }
    }

    @Test("Naming nothing is the offer and writes nothing; `all` takes it, less what another shop serves")
    func offersWhatItShipsTo() async throws {
        try await withServer { app in
            _ = stubbed(app)
            let (brandID, _, _, _) = try await seedBrand(app, storefront: true)
            let offer = try await post(app, "admin/brands/\(brandID)/storefronts?url=https://eu.example.com")
            #expect(offer.hasPrefix("offer"))
            #expect(offer.contains("DE,ES,FR,IT,US"), "every country it ships to but Britain, which has a shop")
            #expect(offer.contains("Nothing was attached"))
            #expect(try await StorefrontModel.query(on: app.db).count() == 1)

            _ = try await post(app, "admin/brands/\(brandID)/storefronts?url=https://eu.example.com&countries=all")
            let shops = try await served(app)
            #expect(shops["https://eu.example.com"] == ["DE", "ES", "FR", "IT", "US"])
            #expect(shops["https://uk.example.com"] == ["GB"], "the British shop keeps Britain")
        }
    }

    @Test("Countries it does not ship to are refused unless forced")
    func refusesUnshipped() async throws {
        try await withServer { app in
            _ = stubbed(app)
            let (brandID, _, _, _) = try await seedBrand(app, storefront: false)
            let path = "admin/brands/\(brandID)/storefronts?url=https://eu.example.com&countries=DE,PL"
            let said = try await post(app, path)
            #expect(said.hasPrefix("refused"))
            #expect(said.contains("not PL"))
            #expect(try await StorefrontModel.query(on: app.db).count() == 0)
            _ = try await post(app, path + "&force=true")
            #expect(try await served(app) == ["https://eu.example.com": ["DE", "PL"]])
        }
    }

    @Test("Attaching for countries another shop serves takes them, and removes a shop left with none")
    func takesCountriesFromAnotherShop() async throws {
        try await withServer { app in
            _ = stubbed(app)
            let (brandID, _, _, _) = try await seedBrand(app, storefront: false)
            _ = try await post(app, "admin/brands/\(brandID)/storefronts?url=https://eu.example.com&countries=DE,GB")
            // Britain moves to its own shop; the European one keeps Germany and re-homes there.
            let said = try await post(app, "admin/brands/\(brandID)/storefronts?url=https://uk.example.com&countries=GB")
            #expect(said.contains("took GB from eu.example.com"))
            #expect(try await served(app) == ["https://eu.example.com": ["DE"], "https://uk.example.com": ["GB"]])
            let eu = try #require(try await StorefrontModel.query(on: app.db).filter(\.$url == "https://eu.example.com").first())
            #expect(eu.homeCountry == "DE")

            // A shop wholly taken over is replaced, history and all.
            let replaced = try await post(app, "admin/brands/\(brandID)/storefronts?url=https://uk.example.com&countries=GB,IE")
            #expect(replaced.contains("replaced uk.example.com"))
            #expect(try await served(app) == ["https://eu.example.com": ["DE"], "https://uk.example.com": ["GB", "IE"]])
        }
    }

    @Test("Countries are added to and removed from a shop by any country it serves")
    func addsAndRemoves() async throws {
        try await withServer { app in
            _ = stubbed(app)
            app.storefrontCountries = ["DE", "FR"]
            let (brandID, shop, _) = try await seedEurope(app, countries: ["DE"])
            let uk = StorefrontModel(brandID: brandID, homeCountry: "GB", url: "https://uk.example.com", currency: "GBP")
            try await uk.save(on: app.db)
            try await Storefronts.add(["GB"], to: uk, on: app.db)

            let added = try await post(app, "admin/brands/\(brandID)/storefronts/de/add?countries=FR,IT")
            #expect(added.contains("now serves DE,FR,IT"))
            #expect(added.contains("IT not in STOREFRONT_COUNTRIES"))
            #expect(try await post(app, "admin/brands/\(brandID)/storefronts/FR/add?countries=GB").hasPrefix("refused"),
                    "Britain is the British shop's")
            #expect(try await post(app, "admin/brands/\(brandID)/storefronts/FR/add?countries=PL").hasPrefix("refused"),
                    "it does not ship to Poland")
            _ = try await post(app, "admin/brands/\(brandID)/storefronts/FR/add?countries=all")
            #expect(try await served(app)["https://eu.example.com"] == ["DE", "ES", "FR", "IT", "US"])

            // Removing keeps what was read, and re-homes the shop when its home goes.
            let removed = try await post(app, "admin/brands/\(brandID)/storefronts/IT/remove?countries=DE,US")
            #expect(removed.contains("now serves ES,FR,IT"))
            let eu = try #require(try await StorefrontModel.find(shop.id, on: app.db))
            #expect(eu.homeCountry == "ES")
            #expect(try await ProductModel.query(on: app.db).filter(\.$storefrontID == shop.id).count() == 1)
            #expect(try await post(app, "admin/brands/\(brandID)/storefronts/FR/remove?countries=ES,FR,IT").hasPrefix("refused"),
                    "that is deleting the shop")

            // The catalogue shows the set.
            var catalog = ""
            try await app.testing().test(.GET, "admin/catalog", headers: adminAuth) { res async throws in
                catalog = res.body.string
            }
            #expect(catalog.contains("· ES,FR,IT eu.example.com shopify"))
            #expect(catalog.contains("· GB uk.example.com"))

            // And deleting it by any of its countries takes it whole.
            let deleted = try await post(app, "admin/brands/\(brandID)/storefronts/it/delete")
            #expect(deleted.contains("the shop for ES,FR,IT"))
            #expect(try await served(app) == ["https://uk.example.com": ["GB"]])
            #expect(try await StorefrontCountryModel.query(on: app.db).count() == 1)
        }
    }
}

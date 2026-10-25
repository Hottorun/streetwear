import Fluent
import Foundation
import StreetwCore
import Testing
import Vapor
import VaporTesting

@testable import StreetwServer

private func makeBrand(_ app: Application, slug: String = "shop.example") async throws -> UUID {
    let brand = BrandModel(
        name: "Shop", slug: slug, website: "https://\(slug)",
        instagramHandle: nil, usesGeneratedName: false
    )
    try await brand.save(on: app.db)
    return try brand.requireID()
}

/// A user following `brandID` in `mode`, with a device that can be pushed to.
@discardableResult
private func makeFollower(
    _ app: Application, brandID: UUID, mode: FollowMode = .everything, token: String = "token-a"
) async throws -> UUID {
    let user = UserModel()
    try await user.save(on: app.db)
    let userID = try user.requireID()
    try await DeviceModel(userID: userID, apnsToken: token, environment: "sandbox", locale: nil).save(on: app.db)
    try await FollowModel(userID: userID, brandID: brandID, mode: mode).save(on: app.db)
    return userID
}

/// `count` one-variant Shopify products, the first `markedDown` of them at `salePrice`.
private func catalogue(
    count: Int,
    markedDown: Int = 0,
    salePrice: String = "60.00",
    compareAt: Bool = true,
    createdDaysBeforePublication: Int = 0
) -> String {
    let products = (0..<count).map { index -> String in
        let onSale = index < markedDown
        let price = onSale ? salePrice : "100.00"
        let original = onSale && compareAt ? "\"100.00\"" : "null"
        let created = createdDaysBeforePublication == 0
            ? "2026-08-01T10:00:00Z"
            : ISO8601DateFormatter().string(
                from: Date(timeIntervalSince1970: 1_785_578_400).addingTimeInterval(-Double(createdDaysBeforePublication) * 86_400)
            )
        return """
        {"id": \(index + 1), "title": "Piece \(index + 1)", "handle": "piece-\(index + 1)",
         "published_at": "2026-08-01T10:00:00Z", "created_at": "\(created)",
         "tags": [], "product_type": "Tops",
         "options": [{"name": "Size", "position": 1}],
         "variants": [{"id": \(1000 + index), "title": "M", "option1": "M", "available": true,
                       "price": "\(price)", "compare_at_price": \(original)}],
         "images": [{"src": "https://cdn.example.com/\(index).jpg"}]}
        """
    }
    return "{\"products\": [\(products.joined(separator: ","))]}"
}

// MARK: - Feed kinds

/// The 1.0 app maps a kind it does not know onto a product. It must never be sent one.
@Suite("Sale feed kinds")
struct SaleFeedKindTests {
    private func follow(_ app: Application, _ brandID: UUID, auth: HTTPHeaders) async throws {
        try await app.testing().test(.POST, "v1/follows", headers: auth, beforeRequest: { req in
            try req.content.encode(FollowBrand(brandID: brandID))
        }, afterResponse: { _ in })
    }

    private func get(_ app: Application, _ path: String, auth: HTTPHeaders) async throws -> FeedResponse {
        var response = FeedResponse(items: [])
        try await app.testing().test(.GET, path, headers: auth) { res async throws in
            #expect(res.status == .ok)
            response = try res.content.decode(FeedResponse.self)
        }
        return response
    }

    private var understood: String {
        FeedKinds.understood.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
    }

    private func sale(_ app: Application, brandID: UUID) async throws {
        try await EventModel(
            brandID: brandID, productID: nil, kind: .sale,
            title: "25% OFF EVERYTHING · CODE AUTUMN", summary: "25% off everything with code AUTUMN"
        ).save(on: app.db)
    }

    @Test("A client that names no kinds never receives a sale")
    func legacyClientNeverSeesASale() async throws {
        try await withServer { app in
            let brandID = try await makeBrand(app)
            try await EventModel(brandID: brandID, productID: nil, kind: .product).save(on: app.db)
            try await sale(app, brandID: brandID)
            let auth = try await deviceAuth(app)
            try await follow(app, brandID, auth: auth)

            let legacy = try await get(app, "v1/feed?limit=200", auth: auth)
            #expect(legacy.items.map(\.kind) == [UpdateKind.product.rawValue])

            let current = try await get(app, "v1/feed?limit=200&kinds=\(understood)", auth: auth)
            let said = try #require(current.items.first { $0.kind == UpdateKind.sale.rawValue })
            #expect(current.items.count == 2)
            // A sale has no product to be named after: its own words, and the shop as its link.
            #expect(said.title == "25% OFF EVERYTHING · CODE AUTUMN")
            #expect(said.summary == "25% off everything with code AUTUMN")
            #expect(said.linkURL == "https://shop.example")
        }
    }

    /// A markdown is a claim about two numbers; the phone needs both, and the brand's tag.
    @Test("A markdown carries its price and the brand's original as numbers")
    func markdownNumbersOnTheWire() async throws {
        try await withServer { app in
            let brandID = try await makeBrand(app)
            let product = ProductModel(
                brandID: brandID, sourceID: nil,
                item: FetchedItem(
                    externalID: "shopify:1", title: "Sevila Dress", publishedAt: Date(), kind: .product,
                    priceText: "$40", priceAmount: 40, originalPriceAmount: 80, originalPriceText: "$80"
                )
            )
            try await product.save(on: app.db)
            try await EventModel(
                brandID: brandID, productID: try product.requireID(), kind: .priceDrop,
                previousPriceText: "$80", previousPriceAmount: 80
            ).save(on: app.db)
            let auth = try await deviceAuth(app)
            try await follow(app, brandID, auth: auth)

            let item = try #require(try await get(app, "v1/feed?limit=200", auth: auth).items.first)
            #expect(item.priceAmount == 40)
            #expect(item.originalPriceAmount == 80)
            #expect(item.originalPriceText == "$80")
        }
    }

    @Test("A brand's own history is held to the same contract")
    func brandFeedFiltersKinds() async throws {
        try await withServer { app in
            let brandID = try await makeBrand(app)
            try await sale(app, brandID: brandID)
            let auth = try await deviceAuth(app)

            let legacy = try await get(app, "v1/brands/\(brandID.uuidString)/feed", auth: auth)
            #expect(legacy.items.isEmpty)
            let current = try await get(app, "v1/brands/\(brandID.uuidString)/feed?kinds=\(understood)", auth: auth)
            #expect(current.items.map(\.kind) == [UpdateKind.sale.rawValue])
        }
    }

    /// A read is one window from its first page to its last: the kinds ride in the token.
    @Test("A continued read keeps the kinds it began with")
    func continuationKeepsItsKinds() async throws {
        try await withServer { app in
            let brandID = try await makeBrand(app)
            for _ in 0..<3 {
                try await EventModel(brandID: brandID, productID: nil, kind: .product).save(on: app.db)
                try await sale(app, brandID: brandID)
            }
            let auth = try await deviceAuth(app)
            try await follow(app, brandID, auth: auth)

            var pages = [try await get(app, "v1/feed?limit=2&kinds=\(understood)", auth: auth)]
            while let token = pages.last?.continuation, pages.count < 10 {
                // Asked without `kinds`: the token alone has to remember them.
                pages.append(try await get(app, "v1/feed?limit=2&continuation=\(token)", auth: auth))
            }
            #expect(pages.flatMap(\.items).count == 6)

            var legacy = [try await get(app, "v1/feed?limit=2", auth: auth)]
            while let token = legacy.last?.continuation, legacy.count < 10 {
                legacy.append(try await get(app, "v1/feed?limit=2&continuation=\(token)&kinds=\(understood)", auth: auth))
            }
            #expect(legacy.flatMap(\.items).map(\.kind) == Array(repeating: UpdateKind.product.rawValue, count: 3))
        }
    }

    /// A token written before kinds were filtered was a read of what 1.0 knows, and stays one.
    @Test("A continuation from before kinds existed reads 1.0's kinds")
    func oldTokenIsLegacy() async throws {
        let token = FeedContinuation(
            since: Date(timeIntervalSince1970: 0),
            until: Date(),
            after: FeedPaging.Position(rank: 0, createdAt: Date(), id: UUID())
        ).token
        let decoded = try #require(FeedContinuation(token: token))
        #expect(decoded.kinds == nil)
    }
}

// MARK: - Catalogue sales

@Suite("Catalogue sales")
struct CatalogueSalePollingTests {
    private func seed(_ app: Application, http: StubHTTP) async throws -> UUID {
        let brandID = try await makeBrand(app)
        try await SourceModel(brandID: brandID, kind: .shopify, url: "https://shop.example").save(on: app.db)
        http.stub("/meta.json", body: #"{"name": "Shop", "currency": "USD"}"#)
        return brandID
    }

    private func makeDue(_ app: Application) async throws {
        for source in try await SourceModel.query(on: app.db).all() {
            source.nextCheckAt = Date().addingTimeInterval(-1)
            try await source.save(on: app.db)
        }
    }

    private func sales(_ app: Application) async throws -> [EventModel] {
        try await EventModel.query(on: app.db).filter(\.$kind == UpdateKind.sale.rawValue).all()
    }

    /// A brand already halfway through a sale when it was first measured did not start one.
    @Test("The first measurement is a baseline, even of a brand on sale")
    func firstMeasurementIsBaseline() async throws {
        try await withServer { app in
            let http = StubHTTP()
            let brandID = try await seed(app, http: http)
            http.stub("/products.json?limit=250&page=1", body: catalogue(count: 20, markedDown: 20))

            await Poller(app: app, http: http).tick()

            #expect(try await sales(app).isEmpty)
            let brand = try #require(try await BrandModel.find(brandID, on: app.db))
            #expect(brand.saleMeasuredAt != nil)
            #expect(brand.saleSince != nil, "recorded as on sale, without saying so")
            // And the brand's own original is stored beside the price it belongs to.
            let product = try #require(try await ProductModel.query(on: app.db).filter(\.$externalID == "shopify:1").first())
            #expect(product.originalPriceAmount == 100)
            #expect(product.priceAmount == 60)
        }
    }

    /// The store-wide markdown with no compare-at: every product falls in one pass.
    @Test("A large share marked down in one pass is one sale, said once")
    func massMarkdownIsOneSale() async throws {
        try await withServer { app in
            let http = StubHTTP()
            let brandID = try await seed(app, http: http)
            http.stub("/products.json?limit=250&page=1", body: catalogue(count: 20))
            let poller = Poller(app: app, http: http)
            await poller.tick()

            http.stub("/products.json?limit=250&page=1", body: catalogue(count: 20, markedDown: 15, compareAt: false))
            try await makeDue(app)
            await poller.tick()

            let said = try await sales(app)
            #expect(said.count == 1)
            #expect(said.first?.title == "SALE · UP TO 40% OFF")
            #expect(said.first?.$product.id == nil)
            let drops = try await EventModel.query(on: app.db).filter(\.$kind == UpdateKind.priceDrop.rawValue).count()
            #expect(drops == 15, "each markdown is still its own event")
            #expect(try #require(try await BrandModel.find(brandID, on: app.db)).saleSince != nil)

            // Still on sale on the next pass — with the brand's tag now saying so — and
            // nothing new to say.
            http.stub("/products.json?limit=250&page=1", body: catalogue(count: 20, markedDown: 15))
            try await makeDue(app)
            await poller.tick()
            #expect(try await sales(app).count == 1)
        }
    }

    @Test("A few markdowns are not a sale")
    func fewMarkdowns() async throws {
        try await withServer { app in
            let http = StubHTTP()
            _ = try await seed(app, http: http)
            http.stub("/products.json?limit=250&page=1", body: catalogue(count: 40))
            let poller = Poller(app: app, http: http)
            await poller.tick()

            http.stub("/products.json?limit=250&page=1", body: catalogue(count: 40, markedDown: 5))
            try await makeDue(app)
            await poller.tick()

            #expect(try await sales(app).isEmpty)
            #expect(try await EventModel.query(on: app.db).filter(\.$kind == UpdateKind.priceDrop.rawValue).count() == 5)
        }
    }

    /// Two detectors, one sale: the bar said it first, so the catalogue does not say it again.
    @Test("A sale announced from the bar today is not announced again from the catalogue")
    func quietPeriod() async throws {
        try await withServer { app in
            let http = StubHTTP()
            let brandID = try await seed(app, http: http)
            http.stub("/products.json?limit=250&page=1", body: catalogue(count: 20))
            let poller = Poller(app: app, http: http)
            await poller.tick()
            try await EventModel(brandID: brandID, productID: nil, kind: .sale, title: "SALE NOW ON").save(on: app.db)

            http.stub("/products.json?limit=250&page=1", body: catalogue(count: 20, markedDown: 15))
            try await makeDue(app)
            await poller.tick()

            #expect(try await sales(app).count == 1)
            #expect(try #require(try await BrandModel.find(brandID, on: app.db)).saleSince != nil,
                    "the state is still recorded, so it cannot fire later either")
        }
    }

    /// Last season's stock moved onto the sale rail: a markdown, measured from the tag.
    @Test("Old stock first seen marked down is a price drop from the brand's original")
    func reshelvedOnSale() async throws {
        try await withServer { app in
            let http = StubHTTP()
            _ = try await seed(app, http: http)
            http.stub("/products.json?limit=250&page=1", body: catalogue(count: 1))
            let poller = Poller(app: app, http: http)
            await poller.tick()

            // A second product, created over a year before it was put out, at 60 from 100.
            http.stub(
                "/products.json?limit=250&page=1",
                body: catalogue(count: 2, markedDown: 2, createdDaysBeforePublication: 400)
            )
            try await makeDue(app)
            await poller.tick()

            let old = try #require(try await ProductModel.query(on: app.db).filter(\.$externalID == "shopify:2").first())
            let event = try #require(try await EventModel.query(on: app.db).filter(\.$product.$id == old.id).first())
            #expect(event.kind == UpdateKind.priceDrop.rawValue)
            // It had no earlier poll to fall from: what it fell from is the brand's tag.
            #expect(event.previousPriceAmount == 100)
            #expect(event.previousPriceText != nil)
        }
    }

    /// Compare-at comes back null when a sale ends; the original must go with it — and a
    /// poll that changes nothing must not rewrite the row.
    @Test("The original follows the price, and clears when the markdown ends")
    func originalClears() async throws {
        try await withServer { app in
            let http = StubHTTP()
            _ = try await seed(app, http: http)
            http.stub("/products.json?limit=250&page=1", body: catalogue(count: 1, markedDown: 1))
            let poller = Poller(app: app, http: http)
            await poller.tick()
            var product = try #require(try await ProductModel.query(on: app.db).first())
            #expect(product.originalPriceAmount == 100)

            http.stub("/products.json?limit=250&page=1", body: catalogue(count: 1, markedDown: 1, salePrice: "100.00", compareAt: false))
            try await makeDue(app)
            await poller.tick()
            product = try #require(try await ProductModel.query(on: app.db).first())
            #expect(product.originalPriceAmount == nil)
            #expect(product.originalPriceText == nil)
        }
    }
}

// MARK: - Banners

@Suite("Sale banners")
struct SaleBannerPollingTests {
    private let sale = """
        <html><body><div class="announcement-bar"><p>Free shipping over $100</p>
        <p><a href="/collections/all">25% off everything with code AUTUMN</a></p></div>
        <nav><a href="/collections/sale">Sale</a></nav></body></html>
        """
    private let shipping = """
        <html><body><div class="announcement-bar"><p>Free shipping over $100</p></div></body></html>
        """

    private func makeDue(_ app: Application, _ brandID: UUID) async throws {
        let brand = try #require(try await BrandModel.find(brandID, on: app.db))
        brand.bannerCheckAt = Date().addingTimeInterval(-1)
        try await brand.save(on: app.db)
    }

    private func sales(_ app: Application) async throws -> [EventModel] {
        try await EventModel.query(on: app.db).filter(\.$kind == UpdateKind.sale.rawValue).all()
    }

    /// A sale already in the bar the first time it is read did not just start.
    @Test("The first read is a baseline")
    func firstReadIsBaseline() async throws {
        try await withServer { app in
            let brandID = try await makeBrand(app)
            try await makeFollower(app, brandID: brandID)
            let http = StubHTTP()
            http.stub("/", body: sale)

            let read = await SaleBanners(app: app, http: http).checkDue()

            #expect(read == 1)
            #expect(try await sales(app).isEmpty)
            let brand = try #require(try await BrandModel.find(brandID, on: app.db))
            #expect(brand.saleBanner == "25% OFF EVERYTHING · CODE AUTUMN")
            let next = try #require(brand.bannerCheckAt).timeIntervalSinceNow
            #expect(next > 29 * 60 && next <= 60 * 60)
        }
    }

    @Test("A new sale in the bar is announced once, in its own words")
    func newBannerIsOneSale() async throws {
        try await withServer { app in
            let brandID = try await makeBrand(app)
            try await makeFollower(app, brandID: brandID)
            let http = StubHTTP()
            http.stub("/", body: shipping)
            let banners = SaleBanners(app: app, http: http)
            await banners.checkDue()

            http.stub("/", body: sale)
            try await makeDue(app, brandID)
            await banners.checkDue()
            let said = try await sales(app)
            #expect(said.count == 1)
            #expect(said.first?.title == "25% OFF EVERYTHING · CODE AUTUMN")
            #expect(said.first?.summary == "25% off everything with code AUTUMN")

            // The same bar on the next read is the same sale.
            try await makeDue(app, brandID)
            await banners.checkDue()
            #expect(try await sales(app).count == 1)
        }
    }

    /// A homepage is the heaviest page a shop serves; a brand nobody would hear from is not
    /// worth reading, and one that is not due is not read.
    @Test("Only due brands somebody would hear from are read")
    func whoIsRead() async throws {
        try await withServer { app in
            let quiet = try await makeBrand(app, slug: "quiet.example")
            try await makeFollower(app, brandID: quiet, mode: .quiet)
            _ = try await makeBrand(app, slug: "nobody.example")
            let waiting = try await makeBrand(app, slug: "waiting.example")
            try await makeFollower(app, brandID: waiting, token: "token-b")
            let brand = try #require(try await BrandModel.find(waiting, on: app.db))
            brand.bannerCheckAt = Date().addingTimeInterval(600)
            try await brand.save(on: app.db)

            let http = StubHTTP()
            http.stub("/", body: sale)
            #expect(await SaleBanners(app: app, http: http).checkDue() == 0)
            #expect(try #require(try await BrandModel.find(quiet, on: app.db)).bannerCheckAt == nil)
        }
    }

    /// Like a failed poll: the schedule moves whatever happened, or an unreadable homepage
    /// would be asked again on every pass.
    @Test("A homepage that does not answer is asked again at the next interval")
    func failureMovesTheSchedule() async throws {
        try await withServer { app in
            let brandID = try await makeBrand(app)
            try await makeFollower(app, brandID: brandID)
            let http = StubHTTP()  // nothing stubbed: the homepage 404s

            #expect(await SaleBanners(app: app, http: http).checkDue() == 0)
            let brand = try #require(try await BrandModel.find(brandID, on: app.db))
            #expect(try #require(brand.bannerCheckAt) > Date().addingTimeInterval(29 * 60))
            #expect(try await sales(app).isEmpty)
        }
    }

    @Test("Each brand reads its bar every thirty to sixty minutes")
    func intervalBounds() {
        for _ in 0..<200 {
            let interval = SaleBanners.interval(for: UUID())
            #expect(interval >= 30 * 60 && interval <= 60 * 60)
        }
        let brand = UUID()
        #expect(SaleBanners.interval(for: brand) == SaleBanners.interval(for: brand))
    }

    @Test("The homepage is the root of the brand's own host")
    func homepage() {
        #expect(SaleBanners.homepage(of: "https://usa.palaceskateboards.com/shop?x=1")?.absoluteString
                == "https://usa.palaceskateboards.com/")
        #expect(SaleBanners.homepage(of: nil) == nil)
        #expect(SaleBanners.homepage(of: "not a url") == nil)
    }
}

// MARK: - Pushes

@Suite("Sale pushes")
struct SalePushTests {
    /// The deliberate rule change: a sale is sudden, so it wakes Everything and Sales only,
    /// and the mode still only takes away — Quiet hears nothing.
    @Test("A sale wakes Everything and Sales only, never Quiet")
    func whoHearsASale() async throws {
        try await withServer { app in
            let brandID = try await makeBrand(app)
            try await makeFollower(app, brandID: brandID, mode: .everything, token: "everything")
            try await makeFollower(app, brandID: brandID, mode: .salesOnly, token: "sales")
            try await makeFollower(app, brandID: brandID, mode: .quiet, token: "quiet")
            try await EventModel(
                brandID: brandID, productID: nil, kind: .sale, title: "25% OFF EVERYTHING · CODE AUTUMN"
            ).save(on: app.db)

            let sender = RecordingSender()
            let result = await Notifier(app: app, sender: sender).dispatch()

            #expect(result.sent == 2)
            #expect(Set(sender.sent.map(\.deviceToken)) == ["everything", "sales"])
            #expect(sender.sent.allSatisfy { $0.body == "25% OFF EVERYTHING · CODE AUTUMN" })
            // About the whole shop: the tap opens the brand, not a product page.
            #expect(sender.sent.allSatisfy { $0.eventID == nil })
            // And it is subject to the cooldown like any brand push.
            #expect(try #require(try await BrandModel.find(brandID, on: app.db)).lastNotifiedAt != nil)
        }
    }

    @Test("A sale leads a mixed batch in its own words")
    func mixedBatch() throws {
        let brandID = UUID()
        let sale = EventModel(brandID: brandID, productID: nil, kind: .sale, title: "SALE · UP TO 50% OFF")
        let drop = EventModel(brandID: brandID, productID: nil, kind: .product)
        let copy = try #require(Notifier.summary(brand: "Kith", events: [drop, sale]))
        #expect(copy.body == "SALE · UP TO 50% OFF — and 1 new item")
    }

    private func watchedProduct(
        _ app: Application, brandID: UUID
    ) async throws -> (productID: UUID, event: EventModel) {
        let product = ProductModel(
            brandID: brandID, sourceID: nil,
            item: FetchedItem(
                externalID: "shopify:7", title: "Nathan Cargo Pant", publishedAt: Date(), kind: .product,
                priceText: "$120", priceAmount: 120, originalPriceAmount: 180, originalPriceText: "$180"
            )
        )
        try await product.save(on: app.db)
        let productID = try product.requireID()
        try await VariantModel(productID: productID, info: VariantInfo(id: "m", title: "M", available: false, size: "M"))
            .save(on: app.db)
        let event = EventModel(
            brandID: brandID, productID: productID, kind: .priceDrop,
            previousPriceText: "$150", previousPriceAmount: 150
        )
        try await event.save(on: app.db)
        return (productID, event)
    }

    /// The rule from 1.0 that changes on purpose: a markdown on the thing you asked about by
    /// name is news about you. Watch rules, not summary rules — and it does not spend the watch.
    @Test("A price drop on a watched product pushes, past the mode and the cooldown")
    func watchedPriceDrop() async throws {
        try await withServer { app in
            let brandID = try await makeBrand(app)
            let userID = try await makeFollower(app, brandID: brandID, mode: .quiet)
            let brand = try #require(try await BrandModel.find(brandID, on: app.db))
            brand.lastNotifiedAt = Date()  // mid-cooldown
            try await brand.save(on: app.db)
            let (productID, event) = try await watchedProduct(app, brandID: brandID)
            // Two watches on one product — one markdown, one push.
            for size in ["M", "L"] {
                try await WatchModel(userID: userID, brandID: brandID, productID: productID, size: size, color: nil)
                    .save(on: app.db)
            }

            let sender = RecordingSender()
            let result = await Notifier(app: app, sender: sender).dispatch()

            #expect(result.sent == 1)
            let message = try #require(sender.sent.first)
            // From the brand's tag, 180, not the last poll's 150.
            #expect(message.body == "Down 33% to $120 — Nathan Cargo Pant")
            #expect(message.eventID == event.id)
            #expect(message.collapseID == "price-\(productID.uuidString)")
            let watches = try await WatchModel.query(on: app.db).all()
            #expect(watches.allSatisfy { $0.firedAt == nil }, "a cheaper sold-out jacket is still being waited for")
        }
    }

    /// The cooldown held back a cooled brand's whole batch — the watched restock with it, so
    /// the alert somebody asked for by name waited out the brand's drop.
    @Test("A watched restock is not held back by the brand's cooldown")
    func restockWatchMidCooldown() async throws {
        try await withServer { app in
            let brandID = try await makeBrand(app)
            let userID = try await makeFollower(app, brandID: brandID)
            let brand = try #require(try await BrandModel.find(brandID, on: app.db))
            brand.lastNotifiedAt = Date()
            try await brand.save(on: app.db)
            let product = ProductModel(
                brandID: brandID, sourceID: nil,
                item: FetchedItem(externalID: "shopify:8", title: "Box Tee", publishedAt: Date(), kind: .product)
            )
            try await product.save(on: app.db)
            let productID = try product.requireID()
            try await VariantModel(productID: productID, info: VariantInfo(id: "m", title: "M", available: true, size: "M"))
                .save(on: app.db)
            try await WatchModel(userID: userID, brandID: brandID, productID: productID, size: "M", color: nil)
                .save(on: app.db)
            try await EventModel(brandID: brandID, productID: productID, kind: .restock, sizes: ["M"]).save(on: app.db)
            // And the drop the cooldown is holding, which must stay held.
            try await EventModel(brandID: brandID, productID: nil, kind: .product).save(on: app.db)

            let sender = RecordingSender()
            #expect(await Notifier(app: app, sender: sender).dispatch().sent == 1)
            #expect(sender.sent.first?.body == "Back in M — Box Tee")
            let held = try await EventModel.query(on: app.db)
                .filter(\.$notifiedAt == nil)
                .filter(\.$kind == UpdateKind.product.rawValue)
                .count()
            #expect(held == 1)
        }
    }

    @Test("A price drop nobody is watching stays silent, and so does an answered watch")
    func unwatchedDropIsSilent() async throws {
        try await withServer { app in
            let brandID = try await makeBrand(app)
            let userID = try await makeFollower(app, brandID: brandID)
            let (productID, _) = try await watchedProduct(app, brandID: brandID)
            let answered = WatchModel(userID: userID, brandID: brandID, productID: productID, size: "M", color: nil)
            answered.firedAt = Date()
            try await answered.save(on: app.db)

            let sender = RecordingSender()
            #expect(await Notifier(app: app, sender: sender).dispatch().sent == 0)
        }
    }
}

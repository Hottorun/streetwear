import Fluent
import FluentPostgresDriver
import Foundation
import StreetwCore
import Testing
import Vapor
import VaporTesting

@testable import StreetwServer

// Following only part of a brand, on the server's side: the follow row, the two routes, the
// notifier asking the same `FollowFilter` the phone stores rows by, and the categories a new
// follow is offered. And a refused brand check saying why.

private func brand(_ app: Application, slug: String = "carhartt-wip.com") async throws -> UUID {
    let brand = BrandModel(
        name: slug, slug: slug, website: "https://\(slug)",
        instagramHandle: nil, usesGeneratedName: false
    )
    try await brand.save(on: app.db)
    return try brand.requireID()
}

private func product(
    _ app: Application, brandID: UUID, title: String,
    type: String? = nil, tags: [String] = [], kind: UpdateKind = .product
) async throws -> ProductModel {
    let product = ProductModel(
        brandID: brandID,
        sourceID: nil,
        item: FetchedItem(
            externalID: "shopify:\(UUID().uuidString)", title: title, publishedAt: Date(),
            kind: kind, tags: tags, productType: type
        )
    )
    try await product.save(on: app.db)
    return product
}

private func follow(_ app: Application, _ brandID: UUID, auth: HTTPHeaders) async throws {
    try await app.testing().test(.POST, "v1/follows", headers: auth, beforeRequest: { req in
        try req.content.encode(FollowBrand(brandID: brandID))
    }, afterResponse: { res async throws in
        #expect(res.status == .created)
    })
}

private func patch(
    _ app: Application, _ brandID: UUID, _ body: UpdateFollow, auth: HTTPHeaders
) async throws -> HTTPStatus {
    var status = HTTPStatus.ok
    try await app.testing().test(
        .PATCH, "v1/follows/\(brandID.uuidString)", headers: auth,
        beforeRequest: { req in try req.content.encode(body) },
        afterResponse: { res async throws in status = res.status }
    )
    return status
}

private func listed(_ app: Application, auth: HTTPHeaders) async throws -> [BrandDTO] {
    var brands: [BrandDTO] = []
    try await app.testing().test(.GET, "v1/follows", headers: auth) { res async throws in
        #expect(res.status == .ok)
        brands = try res.content.decode([BrandDTO].self)
    }
    return brands
}

/// One follower with a device token, following `brandID` with `filter`.
@discardableResult
private func follower(
    _ app: Application, brandID: UUID, token: String, mode: FollowMode = .everything,
    filter: FollowFilter? = nil
) async throws -> UUID {
    let user = UserModel()
    try await user.save(on: app.db)
    let userID = try user.requireID()
    try await DeviceModel(userID: userID, apnsToken: token, environment: "sandbox", locale: nil).save(on: app.db)
    let follow = FollowModel(userID: userID, brandID: brandID, mode: mode)
    follow.filter = filter
    try await follow.save(on: app.db)
    return userID
}

@Suite("Follow filters on the server")
struct FollowFilterServerTests {
    private let jeansOnly = FollowFilter(categories: ["jeans"])

    @Test("A filter is set on the follow, read back on the follow list, and cleared by an empty one")
    func patchAndList() async throws {
        try await withServer { app in
            let brandID = try await brand(app)
            let auth = try await deviceAuth(app)
            try await follow(app, brandID, auth: auth)
            #expect(try await listed(app, auth: auth).first?.followFilter == nil)

            let set = UpdateFollow(mode: .everything, filter: FollowFilter(categories: ["Jeans", "jeans"], words: " no kids "))
            #expect(try await patch(app, brandID, set, auth: auth) == .noContent)
            let stored = try await listed(app, auth: auth).first?.followFilter
            #expect(stored == FollowFilter(categories: ["jeans"], words: "no kids"))

            // 1.3's body: a mode alone changes the mode and leaves the filter.
            #expect(try await patch(app, brandID, UpdateFollow(mode: .salesOnly), auth: auth) == .noContent)
            let after = try await listed(app, auth: auth).first
            #expect(after?.followMode == .salesOnly)
            #expect(after?.followFilter == stored)

            // *All* is an empty filter, and stores nothing.
            #expect(try await patch(app, brandID, UpdateFollow(mode: .salesOnly, filter: FollowFilter()), auth: auth) == .noContent)
            #expect(try await listed(app, auth: auth).first?.followFilter == nil)
            #expect(try await FollowModel.query(on: app.db).first()?.filterJSON == nil)
        }
    }

    /// The body 1.3 sends, as raw JSON, must still decode — the filter is the optional one.
    @Test("A 1.3 PATCH body still decodes and changes only the mode")
    func oldBodyDecodes() async throws {
        try await withServer { app in
            let brandID = try await brand(app)
            let auth = try await deviceAuth(app)
            try await follow(app, brandID, auth: auth)
            try await app.testing().test(
                .PATCH, "v1/follows/\(brandID.uuidString)", headers: auth,
                beforeRequest: { req in
                    req.headers.contentType = .json
                    req.body = ByteBuffer(string: #"{"mode":"quiet"}"#)
                },
                afterResponse: { res async throws in #expect(res.status == .noContent) }
            )
            #expect(try await listed(app, auth: auth).first?.followMode == .quiet)
        }
    }

    @Test("Only the follow list carries a filter")
    func searchCarriesNoFilter() async throws {
        try await withServer { app in
            let brandID = try await brand(app)
            let auth = try await deviceAuth(app)
            try await follow(app, brandID, auth: auth)
            _ = try await patch(app, brandID, UpdateFollow(mode: .everything, filter: jeansOnly), auth: auth)
            try await app.testing().test(.GET, "v1/brands?q=carhartt", headers: auth) { res async throws in
                let found = try res.content.decode([BrandDTO].self)
                #expect(found.first?.followFilter == nil)
            }
        }
    }

    @Test("A jeans-only follower hears about jeans and not about tees; the other follower hears both")
    func notifierAsksTheFilter() async throws {
        try await withServer { app in
            let brandID = try await brand(app)
            try await follower(app, brandID: brandID, token: "narrow", filter: jeansOnly)
            try await follower(app, brandID: brandID, token: "everything")
            let tee = try await product(app, brandID: brandID, title: "Script Logo Tee")
            try await EventModel(brandID: brandID, productID: try tee.requireID(), kind: .product).save(on: app.db)

            let sender = RecordingSender()
            _ = await Notifier(app: app, sender: sender).dispatch()
            #expect(sender.sent.map(\.deviceToken) == ["everything"])

            // The cooldown is the brand's; lift it to see the next pass on its own.
            try await BrandModel.query(on: app.db).set(\.$lastNotifiedAt, to: nil).update()
            let jeans = try await product(app, brandID: brandID, title: "Single Knee Pant Denim Jeans")
            try await EventModel(brandID: brandID, productID: try jeans.requireID(), kind: .product).save(on: app.db)
            let second = RecordingSender()
            _ = await Notifier(app: app, sender: second).dispatch()
            #expect(Set(second.sent.map(\.deviceToken)) == ["narrow", "everything"])
        }
    }

    @Test("A sale, and a garment nothing can place, reach a narrowed follow")
    func alwaysPasses() async throws {
        try await withServer { app in
            let brandID = try await brand(app)
            try await follower(app, brandID: brandID, token: "narrow", filter: FollowFilter(categories: ["bags"]))
            let sale = EventModel(brandID: brandID, productID: nil, kind: .sale)
            sale.title = "30% off everything"
            try await sale.save(on: app.db)

            let sender = RecordingSender()
            _ = await Notifier(app: app, sender: sender).dispatch()
            #expect(sender.sent.map(\.deviceToken) == ["narrow"])

            try await BrandModel.query(on: app.db).set(\.$lastNotifiedAt, to: nil).update()
            let code = try await product(app, brandID: brandID, title: "W2156", type: "For Her")
            try await EventModel(brandID: brandID, productID: try code.requireID(), kind: .product).save(on: app.db)
            let second = RecordingSender()
            _ = await Notifier(app: app, sender: second).dispatch()
            #expect(second.sent.map(\.deviceToken) == ["narrow"])
        }
    }

    /// The exemption every follow setting keeps: a watch is the alert somebody asked for by
    /// name, about one product, and narrowing the brand to bags must not swallow the restock
    /// of the jacket a watch was set on.
    @Test("A watch fires whatever the filter says")
    func watchIgnoresTheFilter() async throws {
        try await withServer { app in
            let brandID = try await brand(app)
            let jacket = try await product(app, brandID: brandID, title: "Detroit Jacket")
            let productID = try jacket.requireID()
            try await VariantModel(
                productID: productID, info: VariantInfo(id: "m", title: "M", available: true, size: "M")
            ).save(on: app.db)
            let userID = try await follower(app, brandID: brandID, token: "narrow", filter: FollowFilter(categories: ["bags"]))
            try await WatchModel(userID: userID, brandID: brandID, productID: productID, size: "M", color: nil).save(on: app.db)
            try await EventModel(brandID: brandID, productID: productID, kind: .restock, sizes: ["M"]).save(on: app.db)

            let sender = RecordingSender()
            let result = await Notifier(app: app, sender: sender).dispatch()
            #expect(result.sent == 1)
            #expect(sender.sent.first?.body == "Back in M — Detroit Jacket")
        }
    }

    /// The parity the whole design rests on: the notifier's answer for a row is the phone's
    /// answer for the same row — `FollowFilter` decides both, from the same four fields.
    @Test("The notifier and the phone answer the same row the same way")
    func parity() throws {
        let filters = [
            FollowFilter(categories: ["jeans"]), FollowFilter(categories: ["bags", "tees"]),
            FollowFilter(words: "no kids"), FollowFilter(words: "black jeans under 200"),
            FollowFilter(categories: ["footwear"], words: "no slides")
        ]
        let products: [(String, String?, [String], Double?)] = [
            ("Loose Jeans", nil, [], 120), ("Black Loose Jeans", "Denim", [], 180), ("Logo Tee", "T-Shirts", [], 40),
            ("Kids Hoodie", nil, ["kids"], 60), ("Canvas Tote", nil, [], 30), ("W2156", "For Her", [], 90),
            ("Pool Slides", "Footwear", [], 50), ("Chelsea Boot", nil, [], 300), ("Black Loose Jeans", nil, [], 260)
        ]
        let brandID = UUID()
        for filter in filters {
            let matcher = FollowFilter.Matcher(filter)
            for (title, type, tags, price) in products {
                let model = ProductModel(
                    brandID: brandID, sourceID: nil,
                    item: FetchedItem(
                        externalID: "x", title: title, publishedAt: Date(), kind: .product,
                        priceAmount: price, tags: tags, productType: type
                    )
                )
                for kind in UpdateKind.allCases {
                    let event = EventModel(brandID: brandID, productID: nil, kind: kind)
                    event.$product.value = model
                    let phone = FollowFilter.Item(title: title, productType: type, tags: tags, price: price)
                    let expected = kind.isSudden && filter.admits(kind, phone)
                    #expect(
                        Notifier.isRelevant(event, to: SizeProfile(), filter: matcher) == expected,
                        "\(filter.reading) · \(title) · \(kind)"
                    )
                }
            }
        }
    }

    @Test("A brand's biggest categories are counted from its own listed products")
    func categories() async throws {
        try await withServer { app in
            let brandID = try await brand(app)
            for title in ["Single Knee Jeans", "Double Knee Jeans", "Simple Pant Jeans",
                          "Chase Hoodie", "Hooded Chase Hoodie",
                          "Pocket Tee", "W2156"] {
                _ = try await product(app, brandID: brandID, title: title)
            }
            // A release is not a garment, and an unlisted product is not on the shelf.
            _ = try await product(app, brandID: brandID, title: "Bags Capsule", kind: .collection)
            let gone = try await product(app, brandID: brandID, title: "Tote Bag")
            gone.unlistedAt = Date()
            try await gone.save(on: app.db)

            let auth = try await deviceAuth(app)
            try await app.testing().test(.GET, "v1/brands/\(brandID)/categories", headers: auth) { res async throws in
                #expect(res.status == .ok)
                let answer = try res.content.decode(BrandCategories.self)
                #expect(answer.products == 7)
                #expect(answer.categories.map(\.category) == ["jeans", "hoodies", "tees"])
                #expect(answer.categories.map(\.count) == [3, 2, 1])
            }
            try await app.testing().test(.GET, "v1/brands/\(UUID())/categories", headers: auth) { res in
                #expect(res.status == .notFound)
            }
            try await app.testing().test(.GET, "v1/brands/\(brandID)/categories") { res in
                #expect(res.status == .unauthorized)
            }
        }
    }
}

// MARK: - Per profile

private struct SubjectVerifier: AppleIdentityVerifying {
    var isAvailable: Bool { true }

    func verify(identityToken: String, nonce: String, now: Date) async throws -> AppleIdentity {
        AppleIdentity(subject: identityToken)
    }
}

@Suite("Follow filters per profile")
struct FollowFilterProfileTests {
    /// Each profile has its own follows, so each has its own filter: Anna narrowing Kith to
    /// bags must not narrow the holder's Kith.
    @Test("A profile's filter is its own")
    func perProfile() async throws {
        try await withServer { app in
            app.appleSignIn = AppleSignInConfiguration(verifier: SubjectVerifier(), tokens: nil)
            let holder = try await deviceAuth(app)
            try await app.testing().test(.POST, "v1/account/apple", headers: holder, beforeRequest: { req in
                try req.content.encode(AppleSignIn(identityToken: "alice", authorizationCode: nil, nonce: "n"))
            }, afterResponse: { res async throws in #expect(res.status == .ok) })
            var anna: ProfileDTO?
            try await app.testing().test(.POST, "v1/account/profiles", headers: holder, beforeRequest: { req in
                try req.content.encode(CreateProfile(name: "Anna"))
            }, afterResponse: { res async throws in anna = try res.content.decode(ProfileDTO.self) })
            var annaHeaders = holder
            annaHeaders.replaceOrAdd(name: ProfileHeader.name, value: try #require(anna).id.uuidString)

            let brandID = try await brand(app, slug: "kith.com")
            try await follow(app, brandID, auth: holder)
            try await follow(app, brandID, auth: annaHeaders)
            let bags = FollowFilter(categories: ["bags"])
            #expect(try await patch(app, brandID, UpdateFollow(mode: .everything, filter: bags), auth: annaHeaders) == .noContent)

            #expect(try await listed(app, auth: annaHeaders).first?.followFilter == bags)
            #expect(try await listed(app, auth: holder).first?.followFilter == nil)
        }
    }
}

// MARK: - A refused check says why

/// Answers every request the same way: Akamai's block page, or a dropped connection.
private struct WallFetcher: HTTPFetching {
    var status = 403
    var body = """
    <HTML><HEAD><TITLE>Access Denied</TITLE></HEAD><BODY><H1>Access Denied</H1>
    You don't have permission to access "http&#58;&#47;&#47;www&#46;bershka&#46;com&#47;" on this server.<P>
    Reference&#32;&#35;18&#46;5c3b1402&#46;1761561600&#46;2a7f3e1</BODY></HTML>
    """
    var drops = false
    let asked = Counter()

    final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func add() { lock.withLock { value += 1 } }
        var count: Int { lock.withLock { value } }
    }

    func get(_ url: URL, etag: String?) async throws -> HTTPResponse {
        asked.add()
        if drops { throw URLError(.networkConnectionLost) }
        return HTTPResponse(data: Data(body.utf8), status: status, finalURL: url)
    }

    func post(_ url: URL, json body: Data, accept: String) async throws -> HTTPResponse {
        try await get(url, etag: nil)
    }
}

@Suite("Refused brand checks")
struct RefusedCheckTests {
    private func check(_ app: Application, _ url: String, _ auth: HTTPHeaders) async throws -> BrandCheck {
        var started: BrandCheck?
        try await app.testing().test(.POST, "v1/brands/checks", headers: auth, beforeRequest: { req in
            try req.content.encode(StartBrandCheck(url: url))
        }, afterResponse: { res async throws in started = try res.content.decode(BrandCheck.self) })
        var current = try #require(started)
        for _ in 0..<50 where current.status == .checking {
            try await Task.sleep(for: .milliseconds(100))
            try await app.testing().test(.GET, "v1/brands/checks/\(current.id)", headers: auth) { res async throws in
                current = try res.content.decode(BrandCheck.self)
            }
        }
        return current
    }

    @Test("A shop behind Akamai is refused as blocking readers, and nothing is added")
    func akamai() async throws {
        try await withServer { app in
            app.storage[FetcherKey.self] = WallFetcher()
            let auth = try await deviceAuth(app)
            let done = try await check(app, "https://www.bershka.com", auth)
            #expect(done.status == .refused)
            #expect(done.refusal == .blocksReaders)
            #expect(try await BrandModel.query(on: app.db).count() == 0)
        }
    }

    @Test("A shop that drops every connection is refused as blocking readers")
    func dropped() async throws {
        try await withServer { app in
            app.storage[FetcherKey.self] = WallFetcher(drops: true)
            let auth = try await deviceAuth(app)
            #expect(try await check(app, "https://www.asos.com", auth).refusal == .blocksReaders)
        }
    }

    @Test("A site that answers with nothing watchable is the generic refusal")
    func nothing() async throws {
        try await withServer { app in
            app.storage[FetcherKey.self] = WallFetcher(status: 404, body: "Not Found")
            let auth = try await deviceAuth(app)
            #expect(try await check(app, "https://nothing-here.example.com", auth).refusal == .nothingAnswered)
        }
    }

    @Test("Chanel is refused as selling no clothes online, without a request")
    func chanel() async throws {
        try await withServer { app in
            let wall = WallFetcher(status: 200, body: "<html><title>CHANEL</title></html>")
            app.storage[FetcherKey.self] = wall
            let auth = try await deviceAuth(app)
            let done = try await check(app, "https://www.chanel.com/us/", auth)
            #expect(done.status == .refused)
            #expect(done.refusal == .sellsNoClothes)
            #expect(wall.asked.count == 0)
        }
    }

    @Test("A ready check carries no refusal")
    func readyHasNone() async throws {
        try await withServer { app in
            app.storage[FetcherKey.self] = WallFetcher(status: 200, body: "<html><title>Shop</title><body>Hello</body></html>")
            let auth = try await deviceAuth(app)
            let done = try await check(app, "https://a-page.example.com", auth)
            #expect(done.status == .ready)
            #expect(done.refusal == nil)
        }
    }
}

// MARK: - The migration, on Postgres

/// The column is text on both databases, so SQLite already exercises every read and write —
/// but the migration itself has to apply and revert on the database production runs, behind
/// every migration before it. Runs only when `STREETW_TEST_POSTGRES_URL` names a scratch
/// database, like the other Postgres suites.
@Suite(
    "Follow filter migration on Postgres",
    .enabled(if: ProcessInfo.processInfo.environment["STREETW_TEST_POSTGRES_URL"] != nil),
    .serialized
)
struct FollowFilterPostgresTests {
    @Test("follows.filter and brand_checks.refusal apply, hold a value, and revert")
    func migration() async throws {
        let url = try #require(ProcessInfo.processInfo.environment["STREETW_TEST_POSTGRES_URL"])
        let app = try await Application.make(.testing)
        var config = try SQLPostgresConfiguration(url: url)
        config.coreConfiguration.tls = .disable
        app.databases.use(.postgres(configuration: config, maxConnectionsPerEventLoop: 4), as: .psql)
        addMigrations(to: app)
        do {
            try await app.autoMigrate()

            let user = UserModel()
            try await user.save(on: app.db)
            let brandID = try await brand(app)
            // A follow written the way every row before the migration was: no filter.
            let plain = FollowModel(userID: try user.requireID(), brandID: brandID)
            try await plain.save(on: app.db)
            #expect(try await FollowModel.find(plain.requireID(), on: app.db)?.filter == nil)

            plain.filter = FollowFilter(categories: ["jeans"], words: "no kids")
            try await plain.save(on: app.db)
            let read = try await FollowModel.find(plain.requireID(), on: app.db)
            #expect(read?.filter == FollowFilter(categories: ["jeans"], words: "no kids"))
            #expect(read?.mode == .everything)

            let check = BrandCheckModel(domain: "bershka.com", url: "https://www.bershka.com", status: .refused)
            check.refusal = BrandCheck.Refusal.blocksReaders.rawValue
            try await check.save(on: app.db)
            #expect(try await BrandCheckModel.find(check.requireID(), on: app.db)?.refusal == "blocksReaders")

            try await app.autoRevert()
        } catch {
            try? await app.autoRevert()
            try await app.asyncShutdown()
            throw error
        }
        try await app.asyncShutdown()
    }
}

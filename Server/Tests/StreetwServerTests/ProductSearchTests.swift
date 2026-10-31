import Fluent
import FluentPostgresDriver
import Foundation
import SQLKit
import StreetwCore
import Testing
import Vapor
import VaporTesting

@testable import StreetwServer

// MARK: - Fixtures

/// A brand with a main-shop source, for products to hang off.
private func shop(_ app: Application, _ name: String, slug: String) async throws -> (brand: UUID, source: UUID) {
    let brand = BrandModel(name: name, slug: slug, website: "https://\(slug)", instagramHandle: nil, usesGeneratedName: false)
    brand.currency = "USD"
    try await brand.save(on: app.db)
    let source = SourceModel(brandID: try brand.requireID(), kind: .shopify, url: "https://\(slug)")
    source.baselinedAt = Date().addingTimeInterval(-86_400)
    try await source.save(on: app.db)
    return (try brand.requireID(), try source.requireID())
}

/// A product, in stock in the sizes given unless they are listed as sold out.
@discardableResult
private func product(
    _ app: Application,
    _ owner: (brand: UUID, source: UUID),
    _ title: String,
    id: String? = nil,
    type: String? = nil,
    tags: [String] = [],
    price: Double? = 100,
    daysAgo: Double = 1,
    sizes: [String] = ["M"],
    soldOut: Set<String> = [],
    colours: [String] = [],
    kind: UpdateKind = .product,
    photographed: Bool = true,
    storefront: UUID? = nil
) async throws -> ProductModel {
    let external = id ?? "shopify:\(abs(title.hashValue))"
    let model = ProductModel(
        brandID: owner.brand,
        sourceID: owner.source,
        storefrontID: storefront,
        item: FetchedItem(
            externalID: external,
            title: title,
            linkURL: URL(string: "https://example.com/products/\(external)"),
            imageURLStrings: photographed ? ["https://cdn.example.com/\(external).jpg"] : [],
            publishedAt: Date(timeIntervalSince1970: 1_800_000_000 - daysAgo * 86_400),
            kind: kind,
            priceText: price.map { "$\(Int($0))" },
            priceAmount: price,
            tags: tags,
            productType: type
        )
    )
    try await model.save(on: app.db)
    let productID = try model.requireID()
    for (index, size) in sizes.enumerated() {
        let colour = colours.isEmpty ? nil : colours[index % colours.count]
        try await VariantModel(
            productID: productID,
            info: VariantInfo(id: "\(external)-\(index)", title: size, available: !soldOut.contains(size), size: size, color: colour)
        ).save(on: app.db)
    }
    return model
}

/// A registered device that follows `brands`, with optional sizes and country.
private func reader(
    _ app: Application,
    follows brands: [UUID],
    sizes: SizePayload? = nil,
    country: String? = nil
) async throws -> HTTPHeaders {
    var token = ""
    try await app.testing().test(.POST, "v1/devices", beforeRequest: { req in
        try req.content.encode(RegisterDevice(sizes: sizes, country: country))
    }, afterResponse: { res async throws in
        token = try res.content.decode(DeviceResponse.self).token
    })
    let auth = HTTPHeaders([("Authorization", "Bearer \(token)")])
    for brand in brands {
        try await app.testing().test(.POST, "v1/follows", headers: auth, beforeRequest: { req in
            try req.content.encode(FollowBrand(brandID: brand))
        }, afterResponse: { res async throws in
            #expect((200..<300).contains(res.status.code))
        })
    }
    return auth
}

private func search(
    _ app: Application,
    _ auth: HTTPHeaders,
    _ text: String,
    scope: ProductSearchScope? = nil,
    extra: String = ""
) async throws -> ProductSearchResponse {
    var path = "v1/products/search?q=\(text.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!)"
    if let scope { path += "&scope=\(scope.rawValue)" }
    path += extra
    var answer: ProductSearchResponse?
    try await app.testing().test(.GET, path, headers: auth) { res async throws in
        #expect(res.status == .ok, "\(res.body.string)")
        answer = try res.content.decode(ProductSearchResponse.self)
    }
    return try #require(answer)
}

/// One batch of the backfill. A free function because `#expect` cannot take an actor call
/// that throws in its expression.
private func embedded(_ backfill: EmbeddingBackfill, now: Date = Date()) async throws -> Int {
    try await backfill.runOnce(now: now).embedded
}

private extension ProductSearchResponse {
    var exactTitles: [String] { exact.map(\.card.title) }
    var partialTitles: [String] { partial.map(\.card.title) }
}

/// The store `ShopSearchTests` reasons over, in rows — so a query can be run through the
/// route and through the phone's own `ShopSearch` and the two compared.
private let tailoring: [(title: String, type: String, price: Double, daysAgo: Double)] = [
    ("Wool Suit Jacket — Black", "Blazers", 380, 1),
    ("Double Pleat Trouser — Black", "Pants", 168, 2),
    ("Heavy Boxy Tee — Off White", "T-Shirt", 65, 4),
    ("Black Suit", "Suits", 520, 3),
    ("Short Sleeve Shirt — Navy", "Shirts", 90, 5),
    ("Nylon Shorts — Black", "Shorts", 70, 6),
    ("Penny Loafer — Black Calf", "Footwear", 310, 7)
]

// MARK: - The route, on SQLite

@Suite("Product search")
struct ProductSearchTests {
    @Test("Your shops by default, every shop when asked, and the answer says which")
    func scopes() async throws {
        try await withServer { app in
            let kith = try await shop(app, "Kith", slug: "kith.com")
            let noah = try await shop(app, "Noah", slug: "noahny.com")
            try await product(app, kith, "Williams Hoodie", type: "Hoodies")
            try await product(app, noah, "Core Logo Hoodie", type: "Hoodies")
            let auth = try await reader(app, follows: [kith.brand])

            let mine = try await search(app, auth, "hoodie")
            #expect(mine.scope == .followed)
            #expect(mine.exactTitles == ["Williams Hoodie"])
            #expect(mine.shops == 1)
            #expect(mine.searched == 1)

            let every = try await search(app, auth, "hoodie", scope: .all)
            #expect(every.scope == .all)
            #expect(Set(every.exactTitles) == ["Williams Hoodie", "Core Logo Hoodie"])
            #expect(every.shops == 2)
        }
    }

    @Test("Following nothing is its own answer, not an empty search")
    func followsNothing() async throws {
        try await withServer { app in
            let kith = try await shop(app, "Kith", slug: "kith.com")
            try await product(app, kith, "Williams Hoodie", type: "Hoodies")
            let auth = try await reader(app, follows: [])
            let answer = try await search(app, auth, "hoodie")
            #expect(answer.shops == 0)
            #expect(answer.exact.isEmpty)
            #expect(answer.outcome == .nothingToSearch)
        }
    }

    /// The point of running `ShopSearch` here: the route and the phone give the same page for
    /// the same products and the same words.
    @Test("A query means the same on the server as on the phone", arguments: [
        "black suit under €400", "shorts", "short sleeve", "black suit for a wedding", "black shoes",
        "black cheaper", "black formal", "under 100", "suit under 100", "jacket no wool"
    ])
    func parity(text: String) async throws {
        try await withServer { app in
            let velmar = try await shop(app, "Velmar Studio", slug: "velmar.com")
            var listings: [ShopListing] = []
            for row in tailoring {
                let model = try await product(app, velmar, row.title, type: row.type, price: row.price, daysAgo: row.daysAgo)
                listings.append(ShopListing(
                    id: row.title, brandKey: "velmar", brandName: "Velmar Studio", title: row.title,
                    productType: row.type, price: row.price, publishedAt: model.publishedAt
                ))
            }
            let auth = try await reader(app, follows: [velmar.brand])

            let served = try await search(app, auth, text)
            let phone = ShopSearch.run(ShopQuery.parse(text), in: ShopIndex(listings), hasSizes: false, fits: { _ in true })
            #expect(served.exactTitles == phone.exact.map(\.id))
            #expect(served.partialTitles == phone.partial.map(\.id))
            #expect(served.partial.map { $0.matched ?? [] } == phone.partial.map(\.matched))
            #expect(served.unknown == phone.unknown)
            #expect(served.outcome == phone.outcome)
            #expect(served.cheaperThan == phone.cheaperThan)
        }
    }

    @Test("Each constraint that empties the list is named, as on the phone")
    func outcomes() async throws {
        try await withServer { app in
            let velmar = try await shop(app, "Velmar Studio", slug: "velmar.com")
            try await product(app, velmar, "Wool Suit Jacket", type: "Blazers", price: 380, sizes: ["M", "L"])
            try await product(app, velmar, "Black Suit", type: "Suits", price: 520, sizes: ["M"], soldOut: ["M"])
            try await product(app, velmar, "Women's Slip Dress", type: "Dresses", price: 200)

            let plain = try await reader(app, follows: [velmar.brand])
            #expect(try await search(app, plain, "suit under 100").outcome == .outsidePrice(count: 2, cheapest: 380))
            #expect(try await search(app, plain, "jacket no wool").outcome == .allRuledOut(["wool"]))
            #expect(try await search(app, plain, "suit in my size").outcome == .noSizes)
            #expect(try await search(app, plain, "tuxedo").outcome == .notInYourShops(["tuxedo"]))

            let mens = try await reader(
                app,
                follows: [velmar.brand],
                sizes: SizePayload(apparel: ["XS"], shoe: [], gender: GenderPreference.mens.rawValue)
            )
            #expect(try await search(app, mens, "dress").outcome == .hiddenByFilter(1))
            #expect(try await search(app, mens, "suit in my size").outcome == .noneInYourSize(2))

            // Somebody who wears an M: the jacket in stock in M is found, the sold-out suit is not.
            let medium = try await reader(app, follows: [velmar.brand], sizes: SizePayload(apparel: ["M"], shoe: []))
            let fits = try await search(app, medium, "suit in my size")
            #expect(fits.exactTitles == ["Wool Suit Jacket"])
        }
    }

    @Test("The chips set the same flags the words do")
    func chips() async throws {
        try await withServer { app in
            let velmar = try await shop(app, "Velmar Studio", slug: "velmar.com")
            for row in tailoring {
                try await product(app, velmar, row.title, type: row.type, price: row.price, daysAgo: row.daysAgo)
            }
            let auth = try await reader(app, follows: [velmar.brand])
            let typed = try await search(app, auth, "black cheaper")
            let tapped = try await search(app, auth, "black", extra: "&cheaper=true")
            #expect(typed.exactTitles == tapped.exactTitles)
            #expect(typed.cheaperThan == tapped.cheaperThan)
        }
    }

    @Test("Only announced garments with a photograph are searched")
    func whatIsSearched() async throws {
        try await withServer { app in
            let kith = try await shop(app, "Kith", slug: "kith.com")
            try await product(app, kith, "Williams Hoodie", type: "Hoodies")
            try await product(app, kith, "Hoodie Season", kind: .collection)
            try await product(app, kith, "Faceless Hoodie", type: "Hoodies", photographed: false)
            let pending = try await product(app, kith, "Pending Hoodie", type: "Hoodies")
            pending.pendingAnnouncement = PendingAnnouncement.confirm.rawValue
            try await pending.save(on: app.db)

            let auth = try await reader(app, follows: [kith.brand])
            let answer = try await search(app, auth, "hoodie")
            #expect(answer.exactTitles == ["Williams Hoodie"])
            #expect(answer.searched == 1)
        }
    }

    @Test("A product the scan found gone from its shop is not searched")
    func unlistedIsLeftOut() async throws {
        try await withServer { app in
            let sql = try #require(app.db as? any SQLDatabase)
            let kith = try await shop(app, "Kith", slug: "kith.com")
            try await product(app, kith, "Williams Hoodie", type: "Hoodies")
            let gone = try await product(app, kith, "Retired Hoodie", type: "Hoodies")
            try await sql.raw("UPDATE products SET unlisted_at = \(bind: Date()) WHERE id = \(bind: try gone.requireID())").run()

            let auth = try await reader(app, follows: [kith.brand])
            let answer = try await search(app, auth, "hoodie")
            #expect(answer.exactTitles == ["Williams Hoodie"])
            #expect(answer.searched == 1)
        }
    }

    /// A sitemap product's key is its whole URL, slashes and all; it is one path segment.
    @Test("More like this takes an external id holding a URL")
    func similarBySitemapID() async throws {
        try await withServer { app in
            let subdued = try await shop(app, "Subdued", slug: "subdued.com")
            let key = "sitemap:https://subdued.com/en/products/wool-coat"
            try await product(app, subdued, "Wool Coat", id: key, type: "Coats", tags: ["wool"])
            try await product(app, subdued, "Wool Long Coat", id: "sitemap:https://subdued.com/en/products/long", type: "Coats", tags: ["wool"])
            let auth = try await reader(app, follows: [subdued.brand])
            let segment = try #require(key.addingPercentEncoding(withAllowedCharacters: .alphanumerics))
            try await app.testing().test(.GET, "v1/products/\(segment)/similar?brand=\(subdued.brand)", headers: auth) { res async throws in
                #expect(res.status == .ok)
                let ids = try res.content.decode(SimilarProductsResponse.self).products.map(\.productExternalID)
                #expect(ids == ["sitemap:https://subdued.com/en/products/long"])
            }
        }
    }

    @Test("Sold out goes last, and is not hidden")
    func soldOutLast() async throws {
        try await withServer { app in
            let kith = try await shop(app, "Kith", slug: "kith.com")
            try await product(app, kith, "Black Hoodie", id: "gone", type: "Hoodies", daysAgo: 0, soldOut: ["M"])
            try await product(app, kith, "Black Hoodie", id: "here", type: "Hoodies", daysAgo: 5)
            let auth = try await reader(app, follows: [kith.brand])
            let answer = try await search(app, auth, "black hoodie")
            #expect(answer.exact.map(\.card.productExternalID) == ["here", "gone"])
        }
    }

    @Test("Pages walk the exact matches without repeating one")
    func paging() async throws {
        try await withServer { app in
            let kith = try await shop(app, "Kith", slug: "kith.com")
            for index in 0..<5 {
                try await product(app, kith, "Hoodie \(index)", id: "h\(index)", type: "Hoodies", daysAgo: Double(index))
            }
            let auth = try await reader(app, follows: [kith.brand])
            var seen: [String] = []
            var cursor: String?
            repeat {
                let page = try await search(app, auth, "hoodie", extra: "&limit=2" + (cursor.map { "&cursor=\($0)" } ?? ""))
                #expect(page.total == 5)
                seen += page.exact.map(\.card.productExternalID)
                cursor = page.nextCursor
            } while cursor != nil
            #expect(seen == ["h0", "h1", "h2", "h3", "h4"])
        }
    }

    @Test("A reader is searched in the shop that serves them, never both")
    func servingShop() async throws {
        try await withServer { app in
            app.storefrontCountries = ["GB"]
            let brandID = try await seedBothShops(app)
            let american = try await reader(app, follows: [brandID])
            let british = try await reader(app, follows: [brandID], country: "GB")
            #expect(try await search(app, american, "tee").exactTitles == ["US Tee"])
            #expect(try await search(app, british, "tee").exactTitles == ["UK Tee"])
            #expect(try await search(app, british, "tee", scope: .all).exactTitles == ["UK Tee"])
        }
    }

    @Test("A result carries its brand with the brand's sources")
    func cardsCarrySources() async throws {
        try await withServer { app in
            let kith = try await shop(app, "Kith", slug: "kith.com")
            try await product(app, kith, "Williams Hoodie", type: "Hoodies", sizes: ["S", "M"])
            let auth = try await reader(app, follows: [kith.brand])
            let card = try #require(try await search(app, auth, "hoodie").exact.first?.card)
            #expect(card.brand.name == "Kith")
            #expect(card.brand.sources.count == 1)
            #expect(card.variants?.count == 2)
        }
    }

    @Test("More like this, by the product's own words, from your shops")
    func similarByText() async throws {
        try await withServer { app in
            let kith = try await shop(app, "Kith", slug: "kith.com")
            let noah = try await shop(app, "Noah", slug: "noahny.com")
            let subject = try await product(app, kith, "Heavyweight Fleece Hoodie", id: "subject", type: "Hoodies", tags: ["fleece"])
            try await product(app, kith, "Fleece Zip Hoodie", id: "near", type: "Hoodies", tags: ["fleece"])
            try await product(app, kith, "Nylon Cargo Pant", id: "far", type: "Pants")
            try await product(app, noah, "Fleece Hoodie", id: "unfollowed", type: "Hoodies", tags: ["fleece"])
            let auth = try await reader(app, follows: [kith.brand])

            var answer: SimilarProductsResponse?
            try await app.testing().test(.GET, "v1/products/\(try subject.requireID())/similar", headers: auth) { res async throws in
                #expect(res.status == .ok)
                answer = try res.content.decode(SimilarProductsResponse.self)
            }
            #expect(answer?.basis == "text")
            #expect(answer?.products.map(\.productExternalID) == ["near"])

            // By the key the phone holds, every shop.
            try await app.testing().test(
                .GET, "v1/products/subject/similar?brand=\(kith.brand)&scope=all", headers: auth
            ) { res async throws in
                let ids = try res.content.decode(SimilarProductsResponse.self).products.map(\.productExternalID)
                #expect(Set(ids) == ["near", "unfollowed"])
            }
            try await app.testing().test(.GET, "v1/products/nothing/similar?brand=\(kith.brand)", headers: auth) { res async in
                #expect(res.status == .notFound)
            }
        }
    }

    // MARK: One list over every shop (Phase 5)

    @Test("Every shop, your own lifted — only when asked, so an older client gets what it got")
    func oneListLiftsYourShops() async throws {
        try await withServer { app in
            let kith = try await shop(app, "Kith", slug: "kith.com")
            let noah = try await shop(app, "Noah", slug: "noahny.com")
            try await product(app, kith, "Williams Hoodie", type: "Hoodies", daysAgo: 5)
            try await product(app, noah, "Core Logo Hoodie", type: "Hoodies", daysAgo: 1)
            let auth = try await reader(app, follows: [kith.brand])

            // 1.2 and 1.3: `all` is every shop, unlifted, newest first among equals.
            let plain = try await search(app, auth, "hoodie", scope: .all)
            #expect(plain.exactTitles == ["Core Logo Hoodie", "Williams Hoodie"])
            #expect(plain.boost == nil)
            #expect(plain.meaningSearched == nil)
            #expect(plain.exact.allSatisfy { $0.byMeaning == nil })

            let lifted = try await search(app, auth, "hoodie", scope: .all, extra: "&boost=standard")
            #expect(lifted.exactTitles == ["Williams Hoodie", "Core Logo Hoodie"])
            #expect(lifted.boost == .standard)
            #expect(lifted.scope == .all)
            #expect(try await search(app, auth, "hoodie", scope: .all, extra: "&boost=more").boost == .more)

            // "Only my brands" is the followed scope exactly as it was; a lift there is not said.
            let mine = try await search(app, auth, "hoodie", scope: .followed, extra: "&boost=more")
            #expect(mine.exactTitles == ["Williams Hoodie"])
            #expect(mine.boost == nil)

            // Without vectors there is nothing to compare by meaning, and the answer says so.
            #expect(try await search(app, auth, "hoodie", scope: .all, extra: "&boost=standard&meaning=true").meaningSearched == nil)
        }
    }

    /// Parity for the one list: the phone has no vectors, so it is defined for the word path —
    /// the same products, lifted the same way, give the same page through the route as through
    /// `ShopSearch` on the phone.
    @Test("The lifted list means the same on the server as on the phone", arguments: [
        "black", "black suit under €400", "shorts", "black cheaper", "black formal", "suit for a wedding"
    ])
    func parityWithTheLift(text: String) async throws {
        try await withServer { app in
            let velmar = try await shop(app, "Velmar Studio", slug: "velmar.com")
            let other = try await shop(app, "Ordo", slug: "ordo.com")
            var listings: [ShopListing] = []
            for (position, row) in tailoring.enumerated() {
                let owner = position.isMultiple(of: 2) ? velmar : other
                let model = try await product(app, owner, row.title, type: row.type, price: row.price, daysAgo: row.daysAgo)
                let isMine = owner.brand == velmar.brand
                listings.append(ShopListing(
                    id: row.title, brandKey: isMine ? "velmar" : "ordo", brandName: isMine ? "Velmar Studio" : "Ordo",
                    title: row.title, productType: row.type, price: row.price, publishedAt: model.publishedAt,
                    boost: isMine ? ProductSearch.lift(.standard) : 0
                ))
            }
            let auth = try await reader(app, follows: [velmar.brand])

            let served = try await search(app, auth, text, scope: .all, extra: "&boost=standard&meaning=true")
            let phone = ShopSearch.run(ShopQuery.parse(text), in: ShopIndex(listings), hasSizes: false, fits: { _ in true })
            #expect(served.exactTitles == phone.exact.map(\.id))
            #expect(served.partialTitles == phone.partial.map(\.id))
            #expect(served.unknown == phone.unknown)
            #expect(served.outcome == phone.outcome)
            #expect(served.cheaperThan == phone.cheaperThan)
        }
    }

    @Test("Search is behind the device token")
    func needsADevice() async throws {
        try await withServer { app in
            try await app.testing().test(.GET, "v1/products/search?q=hoodie") { res async in
                #expect(res.status == .unauthorized)
            }
        }
    }

    /// No pgvector on SQLite, so a provider has nowhere to write and the backfill does nothing.
    @Test("Without pgvector the backfill is idle, provider or not")
    func backfillIdleWithoutPgvector() async throws {
        try await withServer { app in
            app.embeddingProvider = FakeEmbeddingProvider()
            #expect(app.semanticSearch == nil)
            let done = try await embedded(EmbeddingBackfill(app: app))
            #expect(done == 0)
        }
    }

    @Test("Unset EMBEDDING_URL or EMBEDDING_TOKEN means no provider")
    func providerIsOffByDefault() async throws {
        try await withServer { app in
            #expect(SidecarEmbeddingProvider.make(for: app, environment: [:]) == nil)
            #expect(SidecarEmbeddingProvider.make(for: app, environment: ["EMBEDDING_URL": "http://embeddings:8080"]) == nil)
            #expect(SidecarEmbeddingProvider.make(for: app, environment: [
                "EMBEDDING_URL": "http://embeddings:8080", "EMBEDDING_TOKEN": "t",
            ]) != nil)
        }
    }

    @Test("A failed query embedding pauses semantic search for a while, not for good")
    func semanticRestsAfterAFailure() {
        let rest = SemanticRest()
        let now = Date(timeIntervalSince1970: 1_900_000_000)
        #expect(!rest.isResting(now: now))
        rest.rest(now: now)
        #expect(rest.isResting(now: now.addingTimeInterval(SemanticRest.interval - 1)))
        #expect(!rest.isResting(now: now.addingTimeInterval(SemanticRest.interval + 1)))
    }

    @Test("The admin kick says why it cannot embed")
    func adminEmbedSaysWhy() async throws {
        try await withServer { app in
            app.embeddingProvider = FakeEmbeddingProvider()
            try await app.testing().test(.POST, "admin/embed", headers: adminAuth) { res async in
                #expect(res.status == .ok)
                #expect(res.body.string == "semantic search unavailable (not Postgres)")
            }
        }
    }
}

// MARK: - A provider that needs no network

/// Deterministic vectors: each token hashed into one of `dimension` buckets, normalised — so
/// two texts sharing words are near, and a renamed model gives different vectors. A
/// photograph whose URL names `gone` or `unavailable` answers that way.
struct FakeEmbeddingProvider: EmbeddingProvider {
    var model = "fake-1"
    var dimension = 16
    var embedsImages = true
    var delay: Duration = .zero
    var fails = false

    var space: EmbeddingSpace {
        get async throws { EmbeddingSpace(model: model, dimension: dimension) }
    }

    func embed(texts: [String]) async throws -> [[Float]] {
        if delay != .zero { try await Task.sleep(for: delay) }
        if fails { throw Abort(.serviceUnavailable) }
        return texts.map(vector)
    }

    func embed(imageURLs: [URL]) async throws -> [ImageEmbedding] {
        imageURLs.map { url in
            if url.path.contains("gone") { return .gone("HTTP 404") }
            if url.path.contains("unavailable") { return .unavailable("timed out") }
            return .vector(vector(url.lastPathComponent))
        }
    }

    /// A photograph's bytes are read as text: the tests send the words of the product whose
    /// photograph it is meant to resemble, so its vector lands beside that product's image.
    func embed(photo: Data) async throws -> [Float] {
        if fails { throw Abort(.serviceUnavailable) }
        return vector(String(decoding: photo, as: UTF8.self))
    }

    func vector(_ text: String) -> [Float] {
        var out = [Float](repeating: 0, count: dimension)
        for token in ShopText.tokens(text + " " + model) {
            var hash: UInt64 = 0xcbf2_9ce4_8422_2325
            for byte in token.utf8 { hash = (hash ^ UInt64(byte)) &* 0x0000_0100_0000_01b3 }
            out[Int(hash % UInt64(dimension))] += 1
        }
        let norm = sqrt(out.reduce(0) { $0 + $1 * $1 })
        return norm == 0 ? out : out.map { $0 / norm }
    }
}

// MARK: - On a real Postgres

/// The tsvector, its ranking and pgvector are properties of Postgres alone, and none of it
/// can happen on SQLite. Runs only when `STREETW_TEST_POSTGRES_URL` names a scratch database;
/// the pgvector half runs only where that database has the extension, and asserts the
/// opposite where it does not — run it against both.
@Suite(
    "Product search on Postgres",
    .enabled(if: ProcessInfo.processInfo.environment["STREETW_TEST_POSTGRES_URL"] != nil),
    .serialized
)
struct ProductSearchPostgresTests {
    private func withPostgres(_ body: (Application) async throws -> Void) async throws {
        let url = try #require(ProcessInfo.processInfo.environment["STREETW_TEST_POSTGRES_URL"])
        setenv("ADMIN_TOKEN", testAdminToken, 1)
        let app = try await Application.make(.testing)
        var config = try SQLPostgresConfiguration(url: url)
        config.coreConfiguration.tls = .disable
        app.databases.use(.postgres(configuration: config, maxConnectionsPerEventLoop: 4), as: .psql)
        addMigrations(to: app)
        do {
            try await app.autoMigrate()
            app.semanticStatus = await SemanticIndex.prepare(on: app.db, logger: app.logger)
            try routes(app)
            try await app.asyncBoot()
            try await body(app)
            try await app.autoRevert()
        } catch {
            try? await app.autoRevert()
            try await app.asyncShutdown()
            throw error
        }
        try await app.asyncShutdown()
    }

    private func hasPgvector(_ app: Application) async throws -> Bool {
        let sql = try #require(app.db as? any SQLDatabase)
        return try await sql.raw("SELECT 1 AS one FROM pg_available_extensions WHERE name = 'vector'").first() != nil
    }

    @Test("The generated column ranks a title above a tag, and finds across spellings")
    func ranking() async throws {
        try await withPostgres { app in
            let stussy = try await shop(app, "Stüssy", slug: "stussy.com")
            try await product(app, stussy, "Basic Tee", id: "tagged", type: "Tees", tags: ["fleece"], daysAgo: 0)
            try await product(app, stussy, "Polar Fleece Crew", id: "named", type: "Sweatshirts", daysAgo: 9)
            try await product(app, stussy, "Dunk Low Retro", id: "dunk", type: "Sneakers")
            try await product(app, stussy, "Heavy T-Shirt", id: "tshirt", type: "Tops")
            try await product(app, stussy, "Café Racer Jacket", id: "cafe", type: "Outerwear")
            try await product(app, stussy, "Club Crewneck", id: "colourway", type: "Sweatshirts", sizes: ["M", "L"], colours: ["Vintage Black"])
            let auth = try await reader(app, follows: [stussy.brand])

            #expect(try await search(app, auth, "fleece").exact.map(\.card.productExternalID) == ["named", "tagged"])
            #expect(try await search(app, auth, "dunks").exact.map(\.card.productExternalID) == ["dunk"])
            // "T-Shirt" is two tokens in a title and one word to the grammar, whose synonym a
            // tee is — so both, and nothing else.
            #expect(Set(try await search(app, auth, "t-shirt").exact.map(\.card.productExternalID)) == ["tshirt", "tagged"])
            #expect(try await search(app, auth, "cafe").exact.map(\.card.productExternalID) == ["cafe"])
            #expect(try await search(app, auth, "black crewneck").exact.map(\.card.productExternalID) == ["colourway"])
            #expect(try await search(app, auth, "shoes").exact.map(\.card.productExternalID) == ["dunk"])
            // The shop's own name, which the column cannot hold, found through the brand.
            #expect(try await search(app, auth, "stussy").total == 6)
        }
    }

    /// The candidates are a few hundred of a catalogue; a rare word must still be required
    /// rather than called "not in your shops" because it was crowded out of them.
    @Test("What exists is asked of the whole scope, not of the candidates")
    func rareWordsAreRequired() async throws {
        try await withPostgres { app in
            let kith = try await shop(app, "Kith", slug: "kith.com")
            for index in 0..<(ProductSearch.pool + 20) {
                try await product(app, kith, "Black Hoodie \(index)", id: "b\(index)", type: "Hoodies", daysAgo: 0, sizes: [])
            }
            try await product(app, kith, "Zebra Socks", id: "zebra", type: "Socks", daysAgo: 400, sizes: [])
            let auth = try await reader(app, follows: [kith.brand])
            let answer = try await search(app, auth, "black hoodie zebra")
            #expect(answer.unknown.isEmpty)
            #expect(answer.outcome == .closest)
            #expect(answer.isCapped)
        }
    }

    @Test("pgvector where there is one: embedded once per model, and more like this by vector")
    func semantic() async throws {
        try await withPostgres { app in
            guard try await hasPgvector(app) else {
                // The other half of the proof: no extension, nothing semantic, search intact.
                guard case .unavailable = app.semanticStatus else {
                    Issue.record("pgvector unavailable but status is \(app.semanticStatus)")
                    return
                }
                app.embeddingProvider = FakeEmbeddingProvider()
                #expect(app.semanticSearch == nil)
                let kith = try await shop(app, "Kith", slug: "kith.com")
                try await product(app, kith, "Williams Hoodie", type: "Hoodies")
                let auth = try await reader(app, follows: [kith.brand])
                #expect(try await search(app, auth, "hoodie").exactTitles == ["Williams Hoodie"])
                #expect(try await embedded(EmbeddingBackfill(app: app)) == 0)
                return
            }
            guard case .installed = app.semanticStatus else {
                Issue.record("pgvector available but status is \(app.semanticStatus)")
                return
            }
            let sql = try #require(app.db as? any SQLDatabase)
            let kith = try await shop(app, "Kith", slug: "kith.com")
            let subject = try await product(app, kith, "Heavyweight Fleece Hoodie", id: "subject", type: "Hoodies")
            try await product(app, kith, "Fleece Hoodie Heavyweight", id: "near", type: "Hoodies")
            try await product(app, kith, "Nylon Cargo Pant", id: "far", type: "Pants")
            let auth = try await reader(app, follows: [kith.brand])

            app.embeddingProvider = FakeEmbeddingProvider()
            let backfill = EmbeddingBackfill(app: app, batch: 2)
            #expect(try await embedded(backfill) == 2)
            #expect(try await embedded(backfill) == 1)
            #expect(try await embedded(backfill) == 0)
            let index = SemanticIndex.indexName(for: EmbeddingSpace(model: "fake-1", dimension: 16))
            #expect(try await sql.raw("SELECT 1 AS one FROM pg_indexes WHERE indexname = \(bind: index)").first() != nil)

            var similar: SimilarProductsResponse?
            try await app.testing().test(.GET, "v1/products/\(try subject.requireID())/similar", headers: auth) { res async throws in
                similar = try res.content.decode(SimilarProductsResponse.self)
            }
            #expect(similar?.basis == "vectors")
            #expect(similar?.products.first?.productExternalID == "near")

            // A new model re-embeds everything, and its vectors are never compared with the old.
            app.embeddingProvider = FakeEmbeddingProvider(model: "fake-2", dimension: 24)
            #expect(try await embedded(EmbeddingBackfill(app: app, batch: 10)) == 3)
            let models = try await sql.raw("SELECT DISTINCT model FROM product_embeddings").all()
                .map { try $0.decode(column: "model", as: String.self) }
            #expect(models == ["fake-2"])

            // A provider that is down or slow costs the search nothing but the vectors.
            app.embeddingProvider = FakeEmbeddingProvider(model: "fake-2", dimension: 24, fails: true)
            #expect(try await search(app, auth, "fleece hoodie").exactTitles.count == 2)
            app.embeddingProvider = FakeEmbeddingProvider(model: "fake-2", dimension: 24, delay: .seconds(5))
            let started = Date()
            #expect(try await search(app, auth, "fleece hoodie").exactTitles.count == 2)
            #expect(Date().timeIntervalSince(started) < 4)
            // …and having timed out once, the next searches do not wait for it again.
            let again = Date()
            #expect(try await search(app, auth, "fleece hoodie").exactTitles.count == 2)
            #expect(Date().timeIntervalSince(again) < ProductSearch.embeddingTimeout)
        }
    }

    /// pgvector's HNSW scan returns at most `hnsw.ef_search` rows — forty by default — so the
    /// hundred `semanticPool` asks for came back as forty. `nearest` raises the setting for its
    /// own transaction; this holds it to the whole limit on a catalogue the planner reads
    /// through the index (checked, so a seq scan cannot pass the test for it — which is what
    /// the planner chooses under a few thousand rows, hence the catalogue's size here).
    @Test("The nearest neighbours are the whole limit, not pgvector's forty")
    func nearestIsTheWholeLimit() async throws {
        try await withPostgres { app in
            guard case .installed = app.semanticStatus else { return }
            let sql = try #require(app.db as? any SQLDatabase)
            let kith = try await shop(app, "Kith", slug: "kith.com")
            // Three tokens of its own per product, and a wide fake, so no two products hash to
            // one vector: pgvector's cap counts index *elements*, and identical vectors share
            // one, so duplicates would slip past it.
            for index in 0..<(ProductSearch.pool * 5) {
                try await product(app, kith, "Garment \(index) \(index * 7_919) \(index * 104_729)", id: "g\(index)", type: "Tees", daysAgo: 0, sizes: [])
            }
            let fake = FakeEmbeddingProvider(dimension: 256)
            app.embeddingProvider = fake
            let backfill = EmbeddingBackfill(app: app, batch: 500)
            while try await embedded(backfill) > 0 {}
            try await sql.raw("ANALYZE product_embeddings").run()
            try await sql.raw("ANALYZE products").run()
            let space = EmbeddingSpace(model: fake.model, dimension: fake.dimension)
            let scope: SQLQueryString = "p.kind = 'product'"
            let query = fake.vector("Garment 3 3 3")

            let plan = try await sql.raw("""
                EXPLAIN SELECT p.id FROM product_embeddings e JOIN products p ON p.id = e.product_id
                WHERE e.model = \(bind: space.model) AND \(scope)
                ORDER BY (e.text_embedding::vector(256)) <=> (\(bind: SemanticIndex.literal(query))::vector(256)) LIMIT \(literal: ProductSearch.semanticPool)
                """).all().map { try $0.decode(column: "QUERY PLAN", as: String.self) }.joined(separator: "\n")
            #expect(plan.contains(SemanticIndex.indexName(for: space)), "the planner must read the index for the cap to show: \(plan)")

            let near = try await SemanticIndex.nearest(to: query, in: space, scope: scope, limit: ProductSearch.semanticPool, on: sql)
            #expect(near.count == ProductSearch.semanticPool)
            #expect(try await SemanticIndex.nearest(to: query, in: space, scope: scope, limit: 10, on: sql).count == 10)
        }
    }

    @Test("A photograph that cannot be read costs only its image vector, and is not asked about forever")
    func unreadablePhotographs() async throws {
        try await withPostgres { app in
            guard try await hasPgvector(app) else { return }
            let sql = try #require(app.db as? any SQLDatabase)
            let kith = try await shop(app, "Kith", slug: "kith.com")
            // The fake answers by the photograph's URL, which the fixture builds from the id.
            try await product(app, kith, "Fleece Hoodie", id: "fine", type: "Hoodies", daysAgo: 1)
            let gone = try await product(app, kith, "Nylon Cargo Pant", id: "gone", type: "Pants", daysAgo: 2)
            try await product(app, kith, "Wool Overshirt", id: "unavailable", type: "Shirts", daysAgo: 3)
            app.embeddingProvider = FakeEmbeddingProvider()
            let backfill = EmbeddingBackfill(app: app, batch: 10)

            struct Row: Decodable {
                var hasImage: Bool
                var failure: String?
                var attempts: Int
                var retryAt: Date?
                var url: String?
            }
            func row(_ external: String) async throws -> Row {
                let found = try await sql.raw("""
                    SELECT e.image_embedding IS NOT NULL AS "hasImage", e.image_failure AS failure,
                           e.image_attempts AS attempts, e.image_retry_at AS "retryAt", e.image_url AS url
                    FROM product_embeddings e JOIN products p ON p.id = e.product_id
                    WHERE p.external_id = \(bind: external)
                    """).first(decoding: Row.self)
                guard let found else { throw Abort(.notFound, reason: "no embedding row for \(external)") }
                return found
            }

            let start = Date(timeIntervalSince1970: 1_900_000_000)
            let first = try await backfill.runOnce(now: start)
            #expect(first.embedded == 3 && first.images == 1 && first.gone == 1 && first.unavailable == 1)
            #expect(try await row("fine").hasImage)
            let written = try await row("gone")
            #expect(!written.hasImage && written.failure == "HTTP 404" && written.retryAt == nil)
            #expect(written.url == "https://cdn.example.com/gone.jpg")
            let waiting = try await row("unavailable")
            #expect(!waiting.hasImage && waiting.attempts == 1)
            #expect(waiting.retryAt.map { abs($0.timeIntervalSince(start) - 3_600) < 1 } == true)

            // Nothing is due again until the retry; the drain loop has nothing to spin on.
            #expect(try await embedded(backfill, now: start.addingTimeInterval(60)) == 0)

            // Each unavailable answer pushes the next further out, and the last writes it off.
            var clock = start
            for attempt in 2...EmbeddingBackfill.maxImageAttempts {
                clock = clock.addingTimeInterval(EmbeddingBackfill.retryDelay(afterAttempt: attempt - 1) + 1)
                #expect(try await embedded(backfill, now: clock) == 1)
                #expect(try await row("unavailable").attempts == attempt)
            }
            let writtenOff = try await row("unavailable")
            #expect(writtenOff.retryAt == nil)
            #expect(writtenOff.failure?.hasPrefix("unavailable \(EmbeddingBackfill.maxImageAttempts) times") == true)
            #expect(try await embedded(backfill, now: clock.addingTimeInterval(86_400 * 365)) == 0)

            // A different photograph is a different question.
            try await sql.raw("""
                UPDATE products SET image_urls = ARRAY['https://cdn.example.com/new.jpg']
                WHERE id = \(bind: try gone.requireID())
                """).run()
            #expect(try await embedded(backfill, now: clock) == 1)
            let replaced = try await row("gone")
            #expect(replaced.hasImage && replaced.failure == nil && replaced.url == "https://cdn.example.com/new.jpg")
        }
    }

    @Test("Close by meaning is a result without the words — when asked, and never past a \"no …\"")
    func meaningMatches() async throws {
        try await withPostgres { app in
            guard try await hasPgvector(app) else { return }
            let kith = try await shop(app, "Kith", slug: "kith.com")
            try await product(app, kith, "Linen Blazer", id: "blazer", type: "Tailoring", price: 400)
            try await product(app, kith, "Cotton Chore Jacket", id: "jacket", type: "Outerwear", price: 300)
            try await product(app, kith, "Wool Blazer", id: "wool", type: "Tailoring", tags: ["wool"], price: 500)
            let auth = try await reader(app, follows: [kith.brand])
            app.embeddingProvider = FakeEmbeddingProvider()
            #expect(try await embedded(EmbeddingBackfill(app: app, batch: 10)) == 3)

            // Nothing carries both words: the words alone give partial matches only.
            let words = try await search(app, auth, "linen jacket no wool", scope: .all, extra: "&boost=standard")
            #expect(words.exact.isEmpty)
            #expect(words.outcome == .closest)
            #expect(words.meaningSearched == nil)

            // An unmeasured model makes no meaning matches, asked or not.
            let unmeasured = try await search(app, auth, "linen jacket no wool", scope: .all, extra: "&boost=standard&meaning=true")
            #expect(unmeasured.exact.isEmpty)
            #expect(unmeasured.meaningSearched == nil)

            // Measured — here, everything the fake puts anywhere near counts — the two become
            // results, each labelled, and the wool blazer stays ruled out.
            app.meaningThresholds = ["fake-1": 0.0]
            let near = try await search(app, auth, "linen jacket no wool", scope: .all, extra: "&boost=standard&meaning=true")
            #expect(near.meaningSearched == true)
            #expect(Set(near.exact.map(\.card.productExternalID)) == ["blazer", "jacket"])
            #expect(near.exact.allSatisfy { $0.byMeaning == true })
            #expect(near.outcome == .found)
            // Still within the price the words set.
            let cheap = try await search(app, auth, "linen jacket under 350", scope: .all, extra: "&boost=standard&meaning=true")
            #expect(cheap.exact.map(\.card.productExternalID) == ["jacket"])

            // A bar nothing reaches is no meaning match at all.
            app.meaningThresholds = ["fake-1": 1.01]
            #expect(try await search(app, auth, "linen jacket no wool", scope: .all, extra: "&meaning=true").exact.isEmpty)
        }
    }

    @Test("The scan's photograph is matched against the products' photographs, else its words")
    func scanByPhotograph() async throws {
        try await withPostgres { app in
            guard try await hasPgvector(app) else { return }
            let kith = try await shop(app, "Kith", slug: "kith.com")
            // The fake embeds a photograph by its file name, so "near.jpg" is the near one.
            try await product(app, kith, "Canvas Chore Coat", id: "near", type: "Outerwear")
            try await product(app, kith, "Black Chore Jacket Canvas", id: "worded", type: "Outerwear")
            _ = try await reader(app, follows: [kith.brand])
            let user = try #require(try await UserModel.query(on: app.db).first())
            app.embeddingProvider = FakeEmbeddingProvider()
            #expect(try await embedded(EmbeddingBackfill(app: app, batch: 10)) == 2)

            let reading = AIScanReading(
                slot: "outerwear", type: "chore jacket", colours: ["Black"],
                description: "Black canvas chore jacket", searchText: "black chore jacket canvas"
            )
            let photo = Data([0xFF, 0xD8, 0xFF]) + Data("near.jpg".utf8)
            let byPhoto = await AIScanSimilar.cards(for: reading, photo: photo, user: user, app: app, on: app.db)
            #expect(byPhoto?.basis == .photograph)
            #expect(byPhoto?.cards.first?.productExternalID == "near")

            // A provider that cannot read photographs answers by the reading's words.
            app.embeddingProvider = FakeEmbeddingProvider(embedsImages: false)
            let byWords = await AIScanSimilar.cards(for: reading, photo: photo, user: user, app: app, on: app.db)
            #expect(byWords?.basis == .description)
            #expect(byWords?.cards.first?.productExternalID == "worded")
        }
    }

    @Test("Unlisted products are not embedded")
    func unlistedIsNotEmbedded() async throws {
        try await withPostgres { app in
            guard try await hasPgvector(app) else { return }
            let sql = try #require(app.db as? any SQLDatabase)
            let kith = try await shop(app, "Kith", slug: "kith.com")
            try await product(app, kith, "Williams Hoodie", type: "Hoodies")
            let retired = try await product(app, kith, "Retired Hoodie", type: "Hoodies")
            try await sql.raw("UPDATE products SET unlisted_at = now() WHERE id = \(bind: try retired.requireID())").run()
            app.embeddingProvider = FakeEmbeddingProvider()
            #expect(try await embedded(EmbeddingBackfill(app: app)) == 1)
            #expect(try await embedded(EmbeddingBackfill(app: app)) == 0)
        }
    }
}

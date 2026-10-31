import Crypto
import Fluent
import FluentPostgresDriver
import Foundation
import SQLKit
import StreetwCore
import Testing
import Vapor
import VaporTesting

@testable import StreetwServer

// MARK: - Vectors with a meaning

/// Eight directions, each standing for one thing the reader can be asked about.
private enum Axis: Int {
    case product = 0, person, detail, workwear, minimal, otherStyle, neutral
}

private func unit(_ parts: [(Axis, Float)]) -> [Float] {
    var out = [Float](repeating: 0, count: 8)
    for (axis, weight) in parts { out[axis.rawValue] += weight }
    return ZeroShot.normalised(out)
}

private let packshot = unit([(.product, 1), (.workwear, 0.6)])
private let person = unit([(.person, 1)])
/// A fabric close-up: nobody in it, and not the garment either.
private let detail = unit([(.detail, 1)])
/// A lead that could be either: on a person, but not clearly.
private let uncertain = unit([(.person, 1), (.product, 0.99)])
private let neutral = unit([(.neutral, 1)])

/// The fake model's bars: SigLIP's, which the vectors above were drawn to clear.
private let fakeBars = ZeroShot.Bars(personMargin: 0.02, shotMargin: 0.02, styleBar: 0.01)

/// Prompts as the reader would embed them, in the directions above.
private func prompts() -> ZeroShot.Prompts {
    ZeroShot.Prompts(
        model: "reading-fake",
        bars: fakeBars,
        product: [unit([(.product, 1)])],
        person: [unit([(.person, 1)])],
        detail: [unit([(.detail, 1)])],
        styles: [("workwear", unit([(.workwear, 1)])), ("minimal", unit([(.minimal, 1)])), ("vintage", unit([(.otherStyle, 1)]))]
    )
}

/// A provider that answers every prompt and photograph in those directions: a product prompt
/// and a photograph named `packshot` point one way, a person prompt and one named `person`
/// another, a detail prompt and one named `detail` a third, and a product called a chore coat
/// reads as workwear.
private struct ReadingFakeProvider: EmbeddingProvider {
    var model = "reading-fake"
    var embedsImages: Bool { true }
    /// Every photograph URL asked for, in order.
    let asked = Recorder()

    final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var urls: [URL] = []
        func add(_ more: [URL]) { lock.lock(); urls += more; lock.unlock() }
        var all: [URL] { lock.lock(); defer { lock.unlock() }; return urls }
    }

    var space: EmbeddingSpace {
        get async throws { EmbeddingSpace(model: model, dimension: 8) }
    }

    func embed(texts: [String]) async throws -> [[Float]] {
        texts.map { text in
            if ZeroShot.productPrompts.contains(text) { return unit([(.product, 1)]) }
            if ZeroShot.personPrompts.contains(text) { return unit([(.person, 1)]) }
            if ZeroShot.detailPrompts.contains(text) { return unit([(.detail, 1)]) }
            for (word, phrases) in ZeroShot.styleDescriptions where phrases.map(ZeroShot.stylePrompt).contains(text) {
                switch word {
                case "workwear": return unit([(.workwear, 1)])
                case "minimal": return unit([(.minimal, 1)])
                default: return unit([(.otherStyle, 1)])
                }
            }
            return text.contains("Chore") ? unit([(.workwear, 1), (.neutral, 1)]) : neutral
        }
    }

    func embed(imageURLs: [URL]) async throws -> [ImageEmbedding] {
        asked.add(imageURLs)
        return imageURLs.map { url in
            let name = url.lastPathComponent
            if name.contains("gone") { return .gone("HTTP 404") }
            if name.contains("unavailable") { return .unavailable("timed out") }
            if name.contains("packshot") { return .vector(packshot) }
            if name.contains("person") { return .vector(person) }
            if name.contains("detail") { return .vector(detail) }
            return .vector(neutral)
        }
    }

    func embed(photo: Data) async throws -> [Float] { packshot }
}

// MARK: - The reader

@Suite("The product photograph, zero-shot")
struct ZeroShotTests {
    private let calibration = ZeroShot.Calibration(offsets: [:])

    @Test("A lead photograph that is a product shot keeps the shop's choice, without a request")
    func leadAnswers() async throws {
        var calls = 0
        let outcome = try await ZeroShot.read(
            first: packshot, text: unit([(.workwear, 1), (.neutral, 1)]),
            others: [(1, "https://cdn.example.com/person.jpg")],
            prompts: prompts(), calibration: calibration
        ) { _ in calls += 1; return [] }
        #expect(outcome.verdict == ProductPhotoVerdict(shotIndex: nil, styleWords: ["workwear"]))
        #expect(calls == 0)
        #expect(outcome.shotVector == nil)
    }

    @Test("A lead that is not clearly on a person keeps the shop's choice, without a request")
    func uncertainLead() async throws {
        var calls = 0
        let outcome = try await ZeroShot.read(
            first: uncertain, text: neutral,
            others: [(1, "https://cdn.example.com/packshot.jpg")],
            prompts: prompts(), calibration: calibration
        ) { _ in calls += 1; return [] }
        #expect(outcome.verdict.shotIndex == nil)
        #expect(calls == 0)
        // And one that was written off says nothing at all.
        let unread = try await ZeroShot.read(
            first: nil, text: neutral, others: [(1, "https://cdn.example.com/packshot.jpg")],
            prompts: prompts(), calibration: calibration
        ) { _ in calls += 1; return [] }
        #expect(unread.verdict == ProductPhotoVerdict(shotIndex: nil, styleWords: []))
        #expect(calls == 0)
    }

    @Test("A model first: the others are asked a few at a time, and the search stops at a whole garment")
    func looksPast() async throws {
        var asked: [[String]] = []
        let others = ["person-2", "gone-3", "packshot-4", "person-5", "packshot-6", "person-7"].enumerated()
            .map { (index: $0.offset + 1, url: "https://cdn.example.com/\($0.element).jpg") }
        let fake = ReadingFakeProvider()
        let outcome = try await ZeroShot.read(
            first: person, text: neutral, others: others, prompts: prompts(), calibration: calibration
        ) { urls in
            asked.append(urls.map(\.lastPathComponent))
            return try await fake.embed(imageURLs: urls)
        }
        #expect(outcome.verdict.shotIndex == 3)
        #expect(outcome.shotVector == packshot)
        #expect(outcome.gone == ["https://cdn.example.com/gone-3.jpg"])
        // One request of `extraChunk`; the shot is in it, so the rest of the gallery is never fetched.
        #expect(asked == [["person-2.jpg", "gone-3.jpg", "packshot-4.jpg", "person-5.jpg"]])
        #expect(outcome.asked == ZeroShot.extraChunk)
        #expect(outcome.unavailable == 0)
    }

    @Test("A close-up is nobody and not the garment either: never a stand-in, and the walk goes past it")
    func closeUps() async throws {
        let fake = ReadingFakeProvider()
        // The swatch comes before the packshot, as Motel Rocks orders them.
        let found = try await ZeroShot.read(
            first: person, text: neutral,
            others: [(1, "https://cdn.example.com/detail.jpg"), (2, "https://cdn.example.com/person.jpg"), (3, "https://cdn.example.com/packshot.jpg")],
            prompts: prompts(), calibration: calibration
        ) { try await fake.embed(imageURLs: $0) }
        #expect(found.verdict.shotIndex == 3)
        // Models and swatches all the way down: the shop's choice stands.
        let none = try await ZeroShot.read(
            first: person, text: neutral,
            others: [(1, "https://cdn.example.com/detail.jpg"), (2, "https://cdn.example.com/person.jpg")],
            prompts: prompts(), calibration: calibration
        ) { try await fake.embed(imageURLs: $0) }
        #expect(none.verdict.shotIndex == nil && none.shotVector == nil)
    }

    @Test("Models all the way down is no stand-in; a photograph that may answer later leaves it open")
    func noShot() async throws {
        let fake = ReadingFakeProvider()
        let outcome = try await ZeroShot.read(
            first: person, text: neutral,
            others: [(1, "https://cdn.example.com/person.jpg"), (2, "https://cdn.example.com/unavailable.jpg"), (3, "not a url")],
            prompts: prompts(), calibration: calibration
        ) { try await fake.embed(imageURLs: $0) }
        #expect(outcome.verdict == ProductPhotoVerdict(shotIndex: nil, styleWords: []))
        #expect(outcome.unavailable == 1)
        // Never sent: an address that is not one is written off without a request.
        #expect(outcome.gone == ["not a url"])
        #expect(fake.asked.all.count == 2)
    }

    @Test("Style words: the catalogue's mean comes off first, a bar, and at most two")
    func styleWords() {
        let photo = unit([(.workwear, 1), (.minimal, 0.9), (.otherStyle, 0.8)])
        let p = prompts()
        #expect(ZeroShot.styleWords(photo: photo, text: nil, prompts: p, calibration: .init(offsets: [:])) == ["workwear", "minimal"])
        // A word that is near everything in this catalogue says nothing about this product.
        let offsets = ZeroShot.Calibration(offsets: ["workwear": 0.6])
        #expect(ZeroShot.styleWords(photo: photo, text: nil, prompts: p, calibration: offsets) == ["minimal", "vintage"])
        #expect(ZeroShot.styleWords(photo: neutral, text: nil, prompts: p, calibration: .init(offsets: [:])).isEmpty)
        // The calibration is the dot product with the mean vectors, weighted as a score is.
        let made = ZeroShot.calibration(meanImage: unit([(.workwear, 1)]), meanText: unit([(.minimal, 1)]), prompts: p)
        #expect(abs((made.offsets["workwear"] ?? 0) - ZeroShot.imageWeight) < 1e-6)
        #expect(abs((made.offsets["minimal"] ?? 0) - (1 - ZeroShot.imageWeight)) < 1e-6)
    }

    @Test("By the model: the photographs by URL, numbered from one, the words held to the vocabulary")
    func byTheModel() async throws {
        let reply = """
            {"id":"msg_01","type":"message","role":"assistant","model":"claude-haiku-4-5-20251001",
             "content":[{"type":"tool_use","id":"toolu_01","name":"read_photos",
               "input":{"product_shot":2,"style_words":["Workwear","goth","vintage","minimal"]}}],
             "stop_reason":"tool_use","stop_sequence":null,
             "usage":{"input_tokens":1500,"output_tokens":40,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}
            """
        let transport = ReplayTransport([(200, reply), (200, reply.replacingOccurrences(of: "\"product_shot\":2", with: "\"product_shot\":0"))])
        let provider = AnthropicProvider(transport: transport, models: .init(main: "claude-sonnet-5-5", fast: "claude-haiku-4-5-20251001"))
        let urls = [URL(string: "https://cdn.shopify.com/a.jpg?width=400")!, URL(string: "https://cdn.shopify.com/b.jpg?width=400")!]
        let answer = try await provider.readProductPhotos(imageURLs: urls, title: "Chore Coat")
        #expect(answer.value == AIPhotoReading(productShot: 1, styleWords: ["workwear", "vintage"]))
        #expect(answer.costs.map(\.action) == [.productReading])
        #expect(answer.costs.first?.costMicros == 1_700)
        let sent = try #require(transport.sent.first)
        #expect(sent["model"]?.string == "claude-haiku-4-5-20251001")
        let images = (sent["messages"]?.array?.first?["content"]?.array ?? []).filter { $0["type"]?.string == "image" }
        #expect(images.map { $0["source"]?["url"]?.string } == urls.map(\.absoluteString))
        // Nought keeps the first, and so does naming the first: it is never its own stand-in.
        #expect(try await provider.readProductPhotos(imageURLs: urls, title: "Chore Coat").value.productShot == nil)
        let first = ReplayTransport([(200, reply.replacingOccurrences(of: "\"product_shot\":2", with: "\"product_shot\":1"))])
        let named = AnthropicProvider(transport: first, models: .init(main: "claude-sonnet-5-5", fast: "claude-haiku-4-5-20251001"))
        #expect(try await named.readProductPhotos(imageURLs: urls, title: "Chore Coat").value.productShot == nil)
    }

    @Test("The bars are the model's: a model with none is refused, not read against another's")
    func barsAreTheModels() async throws {
        await #expect(throws: ZeroShot.Unmeasured.self) {
            try await ZeroShot.prompts(using: ReadingFakeProvider())
        }
        let given = try await ZeroShot.prompts(using: ReadingFakeProvider(), bars: fakeBars)
        #expect(given.bars == fakeBars && given.model == "reading-fake")
        // The models the sidecar can be built with (`Embeddings/download_model.py`), as it ids them.
        #expect(ZeroShot.measuredBars["Marqo/marqo-fashionSigLIP@c56244cc94f9"] != nil)
        #expect(ZeroShot.measuredBars["Marqo/marqo-fashionCLIP@44f4c655124e"] != nil)
        #expect(ZeroShot.measuredBars.keys.allSatisfy { ProductSearch.measuredThresholds[$0] != nil })
    }

    @Test("The method is SigLIP unless the owner names the model")
    func method() {
        #expect(ProductReadingMethod.from(environment: [:]) == .siglip)
        #expect(ProductReadingMethod.from(environment: ["PRODUCT_READING": "claude"]) == .siglip)
        #expect(ProductReadingMethod.from(environment: ["PRODUCT_READING": " Haiku "]) == .haiku)
        #expect(ProductReadingMethod.siglip.key(model: "m") != ProductReadingMethod.haiku.key(model: "m"))
    }
}

// MARK: - The wire and the routes, on SQLite

private func brand(_ app: Application, _ slug: String) async throws -> (brand: UUID, source: UUID) {
    let brand = BrandModel(name: slug, slug: slug, website: "https://\(slug)", instagramHandle: nil, usesGeneratedName: false)
    try await brand.save(on: app.db)
    let source = SourceModel(brandID: try brand.requireID(), kind: .shopify, url: "https://\(slug)")
    source.baselinedAt = Date().addingTimeInterval(-86_400)
    try await source.save(on: app.db)
    return (try brand.requireID(), try source.requireID())
}

@discardableResult
private func garment(
    _ app: Application, _ owner: (brand: UUID, source: UUID), _ id: String, title: String = "Chore Coat",
    photos: [String], daysAgo: Double = 1, shot: Int? = nil, words: [String]? = nil
) async throws -> ProductModel {
    let model = ProductModel(brandID: owner.brand, sourceID: owner.source, item: FetchedItem(
        externalID: id,
        title: title,
        linkURL: URL(string: "https://example.com/products/\(id)"),
        imageURLStrings: photos.map { "https://cdn.example.com/\($0).jpg" },
        publishedAt: Date(timeIntervalSince1970: 1_800_000_000 - daysAgo * 86_400),
        kind: .product,
        priceText: "$100",
        priceAmount: 100,
        productType: "Jackets"
    ))
    model.shotIndex = shot
    model.styleWords = words
    try await model.save(on: app.db)
    try await VariantModel(productID: try model.requireID(), info: VariantInfo(id: "\(id)-m", title: "M", available: true, size: "M")).save(on: app.db)
    return model
}

@Suite("The product photograph on the wire")
struct ProductReadingWireTests {
    @Test("A card carries the shot only while it points at a photograph, and the words as read")
    func card() throws {
        let product = ProductModel(brandID: UUID(), sourceID: nil, item: FetchedItem(
            externalID: "shopify:1", title: "Chore Coat",
            imageURLStrings: ["https://cdn.example.com/a.jpg", "https://cdn.example.com/b.jpg"],
            publishedAt: Date(), kind: .product
        ))
        let dto = BrandDTO(id: UUID(), name: "Shop", slug: "shop.com")
        func card() -> DiscoverCard {
            DiscoverCard(product, brand: dto, mainCurrency: "USD", variants: [], spread: [], vector: nil)
        }
        #expect(card().productShotIndex == nil && card().styleWords == nil)
        product.shotIndex = 1
        product.styleWords = ["workwear"]
        #expect(card().productShotIndex == 1 && card().styleWords == ["workwear"])
        product.shotIndex = 5
        #expect(card().productShotIndex == nil)
        // An older client's decoder never sees the keys; a newer one reads them back.
        let data = try JSONEncoder().encode(card())
        #expect(try JSONDecoder().decode(DiscoverCard.self, from: data).styleWords == ["workwear"])
    }

    @Test("Readings for products the phone holds: only those read, by brand and external id, as a URL")
    func readingsRoute() async throws {
        try await withServer { app in
            let shop = try await brand(app, "shop.com")
            let other = try await brand(app, "other.com")
            try await garment(app, shop, "shopify:1", photos: ["person", "packshot"], shot: 1, words: ["workwear"])
            try await garment(app, shop, "shopify:2", photos: ["person"], shot: nil, words: [])
            try await garment(app, shop, "shopify:3", photos: ["packshot"])
            try await garment(app, other, "shopify:4", photos: ["person", "packshot"], shot: 1, words: ["minimal"])
            let auth = try await deviceAuth(app)
            let ask = ProductReadingsRequest(items: [
                .init(brandID: shop.brand, externalID: "shopify:1"),
                .init(brandID: shop.brand, externalID: "shopify:2"),
                .init(brandID: shop.brand, externalID: "shopify:3"),
                // Another brand's key: not this product, whatever its id says.
                .init(brandID: shop.brand, externalID: "shopify:4"),
                // A save from a brand the phone does not follow: the key alone.
                .init(brandID: nil, externalID: "shopify:4"),
            ])
            try await app.testing().test(.POST, "v1/products/readings", headers: auth, beforeRequest: { req in
                try req.content.encode(ask)
            }) { res async throws in
                #expect(res.status == .ok, "\(res.body.string)")
                let answer = try res.content.decode(ProductReadingsResponse.self)
                #expect(answer.readings == [
                    .init(brandID: shop.brand, externalID: "shopify:1", productShotURL: "https://cdn.example.com/packshot.jpg", styleWords: ["workwear"]),
                    .init(brandID: shop.brand, externalID: "shopify:2", productShotURL: nil, styleWords: []),
                    .init(brandID: nil, externalID: "shopify:4", productShotURL: "https://cdn.example.com/packshot.jpg", styleWords: ["minimal"]),
                ])
            }
            let tooMany = ProductReadingsRequest(items: (0...ProductReadingsRequest.limit).map {
                .init(brandID: shop.brand, externalID: "shopify:\($0)")
            })
            try await app.testing().test(.POST, "v1/products/readings", headers: auth, beforeRequest: { req in
                try req.content.encode(tooMany)
            }) { res async in
                #expect(res.status == .payloadTooLarge)
            }
            try await app.testing().test(.POST, "v1/products/readings", beforeRequest: { req in
                try req.content.encode(ask)
            }) { res async in
                #expect(res.status == .unauthorized)
            }
        }
    }

    @Test("A style word is a word a search can match, at a tag's weight")
    func searchable() async throws {
        try await withServer { app in
            let shop = try await brand(app, "shop.com")
            try await garment(app, shop, "shopify:1", title: "Canvas Jacket", photos: ["packshot"], shot: 0, words: ["workwear"])
            try await garment(app, shop, "shopify:2", title: "Silk Dress", photos: ["packshot"], shot: 0, words: ["romantic"])
            var token = ""
            try await app.testing().test(.POST, "v1/devices", beforeRequest: { req in
                try req.content.encode(RegisterDevice())
            }, afterResponse: { res async throws in
                token = try res.content.decode(DeviceResponse.self).token
            })
            let auth = HTTPHeaders([("Authorization", "Bearer \(token)")])
            try await app.testing().test(.POST, "v1/follows", headers: auth, beforeRequest: { req in
                try req.content.encode(FollowBrand(brandID: shop.brand))
            })
            try await app.testing().test(.GET, "v1/products/search?q=workwear", headers: auth) { res async throws in
                let answer = try res.content.decode(ProductSearchResponse.self)
                #expect(answer.exact.map(\.card.title) == ["Canvas Jacket"])
                #expect(answer.exact.first?.card.styleWords == ["workwear"])
                #expect(answer.unknown.isEmpty)
            }
        }
    }
}

// MARK: - The backfill, on Postgres

/// The due query, the ledger and photo search's shot vector are Postgres (and pgvector) alone.
@Suite(
    "The product photograph on Postgres",
    .enabled(if: ProcessInfo.processInfo.environment["STREETW_TEST_POSTGRES_URL"] != nil),
    .serialized
)
struct ProductReadingPostgresTests {
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

    private struct Row: Decodable {
        var shot: Int?
        var words: [String]?
        var attempts: Int?
        var retryAt: Date?
        var gone: [String]?
        var hasShotVector: Bool?
    }

    private func row(_ app: Application, _ external: String) async throws -> Row {
        let sql = try #require(app.db as? any SQLDatabase)
        return try #require(try await sql.raw("""
            SELECT p.shot_index AS shot, p.style_words AS words, r.attempts AS attempts, r.retry_at AS "retryAt",
                   r.gone AS gone, e.shot_embedding IS NOT NULL AS "hasShotVector"
            FROM products p LEFT JOIN product_readings r ON r.product_id = p.id
            LEFT JOIN product_embeddings e ON e.product_id = p.id
            WHERE p.external_id = \(bind: external)
            """).first(decoding: Row.self))
    }

    @Test("Read once, from the stored lead vector; the rest only for a model first; resumable")
    func backfill() async throws {
        try await withPostgres { app in
            guard case .installed = app.semanticStatus else { return }
            let sql = try #require(app.db as? any SQLDatabase)
            let shop = try await brand(app, "shop.com")
            try await garment(app, shop, "a", photos: ["packshot-a", "person-a"], daysAgo: 1)
            try await garment(app, shop, "b", photos: ["person-b", "gone-b", "packshot-b"], daysAgo: 2)
            try await garment(app, shop, "c", title: "Plain Tee", photos: ["person-c", "unavailable-c"], daysAgo: 3)
            try await garment(app, shop, "d", title: "Plain Tee", photos: ["person-d"], daysAgo: 4)
            let fake = ReadingFakeProvider()
            app.embeddingProvider = fake
            app.styleCalibration = ZeroShot.Calibration(offsets: [:])

            let readings = ProductReadingBackfill(app: app, method: .siglip, batch: 10, minimumCalibration: 0, pause: .zero, bars: fakeBars)
            // Nothing is due before the lead photographs have been embedded.
            #expect(try await readings.runOnce().read == 0)
            #expect(try await EmbeddingBackfill(app: app, batch: 10).runOnce().embedded == 4)
            let leads = fake.asked.all.count

            // A model nobody has measured bars for is waited on, and said — never read against
            // another model's bars.
            let unmeasured = try await ProductReadingBackfill(app: app, method: .siglip, batch: 10, minimumCalibration: 0, pause: .zero).runOnce()
            #expect(unmeasured.read == 0 && unmeasured.waiting?.contains("no measured bars for reading-fake") == true)
            #expect(fake.asked.all.count == leads)

            let start = Date(timeIntervalSince1970: 1_900_000_000)
            let pass = try await readings.runOnce(now: start)
            #expect(pass.read == 4 && pass.movedShots == 1 && pass.noShot == 3 && pass.unsettled == 1)
            // Only b's and c's later photographs were asked: a's lead is a product shot, so the
            // shop's choice stands unasked.
            #expect(fake.asked.all.dropFirst(leads).map(\.lastPathComponent).sorted()
                    == ["gone-b.jpg", "packshot-b.jpg", "unavailable-c.jpg"])

            let a = try await row(app, "a")
            #expect(a.shot == nil && a.words == ["workwear"] && a.hasShotVector == false)
            let b = try await row(app, "b")
            #expect(b.shot == 2 && b.words == ["workwear"] && b.hasShotVector == true)
            #expect(b.gone == ["https://cdn.example.com/gone-b.jpg"] && b.retryAt == nil)
            let c = try await row(app, "c")
            #expect(c.shot == nil && c.words == [] && c.attempts == 1)
            #expect(c.retryAt.map { abs($0.timeIntervalSince(start) - 3_600) < 1 } == true)
            let d = try await row(app, "d")
            #expect(d.shot == nil && d.words == [] && d.retryAt == nil)

            // Resumable: nothing is due again until c's retry, and then c alone.
            #expect(try await readings.runOnce(now: start.addingTimeInterval(60)).read == 0)
            let retry = try await readings.runOnce(now: start.addingTimeInterval(3_601))
            #expect(retry.read == 1 && retry.unsettled == 1)
            #expect(try await row(app, "c").attempts == 2)

            // A new gallery is a new reading; a photograph written off in the old one is asked again.
            try await sql.raw("""
                UPDATE products SET image_urls = ARRAY['https://cdn.example.com/packshot-b2.jpg'] WHERE external_id = 'b'
                """).run()
            #expect(try await EmbeddingBackfill(app: app, batch: 10).runOnce().embedded == 1)
            #expect(try await readings.runOnce(now: start.addingTimeInterval(3_700)).read == 1)
            let moved = try await row(app, "b")
            #expect(moved.shot == nil && moved.gone == [] && moved.hasShotVector == false)
        }
    }

    @Test("Photo search compares with the product shot where the reading found one past the lead")
    func photoSearchUsesTheShot() async throws {
        try await withPostgres { app in
            guard case .installed = app.semanticStatus else { return }
            let sql = try #require(app.db as? any SQLDatabase)
            let shop = try await brand(app, "shop.com")
            let b = try await garment(app, shop, "b", photos: ["person-b", "packshot-b"])
            try await garment(app, shop, "c", photos: ["person-c"])
            app.embeddingProvider = ReadingFakeProvider()
            app.styleCalibration = ZeroShot.Calibration(offsets: [:])
            _ = try await EmbeddingBackfill(app: app, batch: 10).runOnce()
            let space = EmbeddingSpace(model: "reading-fake", dimension: 8)
            let scope: SQLQueryString = "p.kind = 'product'"
            // Before the reading, both leads are people: the jacket's packshot is nobody's neighbour.
            let before = try await SemanticIndex.nearest(to: packshot, in: space, column: .image, scope: scope, limit: 2, on: sql)
            #expect(before.allSatisfy { $0.similarity < 0.5 })
            _ = try await ProductReadingBackfill(app: app, method: .siglip, minimumCalibration: 0, pause: .zero, bars: fakeBars).runOnce()
            let after = try await SemanticIndex.nearest(to: packshot, in: space, column: .image, scope: scope, limit: 2, on: sql)
            #expect(after.first?.id == b.id)
            #expect((after.first?.similarity ?? 0) > 0.99)
        }
    }

    @Test("By the model: owner-paid, metered as a product reading, and stopped by the day's cap")
    func byTheModel() async throws {
        try await withPostgres { app in
            let shop = try await brand(app, "shop.com")
            try await garment(app, shop, "x", title: "Workwear Chore Coat", photos: ["person-x", "packshot-x"])
            let readings = ProductReadingBackfill(app: app, method: .haiku, batch: 10)
            #expect(try await readings.runOnce().waiting == "AI is off")

            app.ai = AIService(provider: FakeAIProvider(), threadKey: SymmetricKey(size: .bits256), backgroundDailyCapMicros: 5_000)
            let pass = try await readings.runOnce()
            #expect(pass.read == 1)
            let x = try await row(app, "x")
            #expect(x.shot == 1 && x.words == ["workwear"])
            let sql = try #require(app.db as? any SQLDatabase)
            let actions = try await sql.raw("SELECT action FROM ai_costs WHERE account_id IS NULL").all()
                .map { try $0.decode(column: "action", as: String.self) }
            #expect(actions == ["product_reading"])

            // A new photograph makes it due; a spent day leaves it for tomorrow.
            try await sql.raw("UPDATE products SET image_urls = ARRAY['https://cdn.example.com/packshot-y.jpg'] WHERE external_id = 'x'").run()
            let cost = MeteredCost(action: .productReading, model: "claude-haiku-4-5-20251001", inputTokens: 1, outputTokens: 1, costMicros: 5_000)
            try await CostMeter.record(cost, account: nil, user: nil, on: app.db)
            #expect(try await readings.runOnce().waiting == "today's owner-paid allowance is spent")
        }
    }
}

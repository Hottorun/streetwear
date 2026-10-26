import Fluent
import FluentPostgresDriver
import Foundation
import SQLKit
import StreetwCore
import Testing
import Vapor
import VaporTesting

@testable import StreetwServer

/// One product as `/products.json` writes it, with one variant.
private struct Piece {
    var id: Int
    var price = "100.00"
    var compareAt: String?
    var available = true
    /// How long before now it was put out. Every piece defaults to well over a day, which is
    /// old stock as far as the scan is concerned.
    var publishedDaysAgo = 30.0
}

private func json(_ pieces: some Collection<Piece>) -> String {
    let formatter = ISO8601DateFormatter()
    let products = pieces.map { piece -> String in
        let published = formatter.string(from: Date().addingTimeInterval(-piece.publishedDaysAgo * 86_400))
        let original = piece.compareAt.map { "\"\($0)\"" } ?? "null"
        return """
        {"id": \(piece.id), "title": "Piece \(piece.id)", "handle": "piece-\(piece.id)",
         "published_at": "\(published)", "created_at": "\(published)",
         "tags": [], "product_type": "Tops",
         "options": [{"name": "Size", "position": 1}],
         "variants": [{"id": \(100_000 + piece.id), "title": "M", "option1": "M",
                       "available": \(piece.available), "price": "\(piece.price)",
                       "compare_at_price": \(original)}],
         "images": [{"src": "https://cdn.example.com/\(piece.id).jpg"}]}
        """
    }
    return "{\"products\": [\(products.joined(separator: ","))]}"
}

/// Serves `pieces` as the whole catalogue, 250 a page, newest first as given — ending, as
/// Shopify does, with a page that is short or empty.
private func serve(_ http: StubHTTP, _ pieces: [Piece]) {
    let pages = pieces.count / ShopifySource.pageSize + 1
    for page in 1...(pages + 1) {
        let slice = pieces.dropFirst((page - 1) * ShopifySource.pageSize).prefix(ShopifySource.pageSize)
        http.stub("/products.json?limit=250&page=\(page)", body: json(slice))
    }
}

private func seed(_ app: Application, http: StubHTTP) async throws -> (brandID: UUID, sourceID: UUID) {
    let brand = BrandModel(
        name: "Shop", slug: "shop.example", website: "https://shop.example",
        instagramHandle: nil, usesGeneratedName: false
    )
    try await brand.save(on: app.db)
    let source = SourceModel(brandID: try brand.requireID(), kind: .shopify, url: "https://shop.example")
    try await source.save(on: app.db)
    http.stub("/meta.json", body: #"{"name": "Shop", "currency": "USD"}"#)
    return (try brand.requireID(), try source.requireID())
}

/// One poll of every source, due or not.
private func poll(_ poller: Poller, _ app: Application) async throws {
    for source in try await SourceModel.query(on: app.db).all() {
        source.nextCheckAt = Date().addingTimeInterval(-1)
        try await source.save(on: app.db)
    }
    await poller.tick()
}

/// Every scan made due and read to the end in one pass.
private func scan(_ poller: Poller, _ app: Application, pagesPerTurn: Int = 500) async throws {
    try await makeScansDue(poller, app)
    await poller.scanTick(limit: 10, pagesPerTurn: pagesPerTurn)
}

private func makeScansDue(_ poller: Poller, _ app: Application) async throws {
    try await poller.enrolScans()
    for row in try await CatalogueScanModel.query(on: app.db).all() {
        row.dueAt = Date().addingTimeInterval(-1)
        try await row.save(on: app.db)
    }
}

private func scanRow(_ app: Application) async throws -> CatalogueScanModel {
    try #require(try await CatalogueScanModel.query(on: app.db).first())
}

private func product(_ app: Application, _ id: Int) async throws -> ProductModel {
    try #require(try await ProductModel.query(on: app.db).filter(\.$externalID == "shopify:\(id)").first())
}

/// Every insert and update on the catalogue tables, from here on — how a test sees a rewrite,
/// which no row count can.
private func logWrites(_ app: Application) async throws {
    let sql = try #require(app.db as? any SQLDatabase)
    try await sql.raw("CREATE TABLE write_log (tbl TEXT, op TEXT)").run()
    for table in ["products", "variants"] {
        for op in ["INSERT", "UPDATE"] {
            try await sql.raw("""
                CREATE TRIGGER log_\(unsafeRaw: table)_\(unsafeRaw: op) AFTER \(unsafeRaw: op) ON \(unsafeRaw: table) \
                BEGIN INSERT INTO write_log VALUES ('\(unsafeRaw: table)', '\(unsafeRaw: op)'); END
                """).run()
        }
    }
}

private func writes(_ app: Application, _ table: String, _ op: String) async throws -> Int {
    let sql = try #require(app.db as? any SQLDatabase)
    return try await sql.raw(
        "SELECT COUNT(*) AS n FROM write_log WHERE tbl = \(bind: table) AND op = \(bind: op)"
    ).first(decodingColumn: "n", as: Int.self) ?? 0
}

@Suite("Catalogue scan")
struct CatalogueScanTests {
    /// The roadmap's 5,000-product shop: the poll's baseline holds the newest 2,500, the scan
    /// finds the rest and finds the stored state of the older half out of date. None of it is
    /// news. Then a markdown on old stock is, and only that.
    @Test("A first scan of a 5,000-product shop says nothing; a markdown on old stock later says exactly that")
    func firstScanIsSilentAndAMarkdownIsNot() async throws {
        try await withServer { app in
            let http = StubHTTP()
            let (brandID, _) = try await seed(app, http: http)
            var pieces = (1...5_000).map { Piece(id: $0, publishedDaysAgo: 2 + Double($0) / 10) }
            pieces[1_799].available = false
            serve(http, pieces)

            let poller = Poller(app: app, http: http)
            try await poll(poller, app)
            #expect(try await ProductModel.query(on: app.db).count() == 2_500, "the poll's baseline is the newest 2,500")

            // Between the baseline and the first scan, the deep end moved: a markdown on a
            // product the poll stored, a size back on another, and a markdown past the poll's
            // window. The first scan compares against months-old state and says none of it.
            pieces[1_999].price = "60.00"
            pieces[1_799].available = true
            pieces[2_999].price = "50.00"
            pieces[2_999].compareAt = "100.00"
            serve(http, pieces)
            try await scan(poller, app)

            #expect(try await EventModel.query(on: app.db).count() == 0)
            #expect(try await ProductModel.query(on: app.db).count() == 5_000)
            #expect(try await VariantModel.query(on: app.db).count() == 5_000)
            #expect(try await product(app, 2_000).priceAmount == 60, "state is written, silently")
            #expect(try await product(app, 1_800).isAvailable == true)
            let first = try await scanRow(app)
            #expect(first.completedAt != nil)
            #expect(first.lastProducts == 5_000)
            #expect(first.lastTruncated == false)
            #expect(first.startedAt == nil)
            let brand = try #require(try await BrandModel.find(brandID, on: app.db))
            #expect(brand.catalogueMeasuredAt != nil)

            // A day later: one old product marked down, everything else exactly as it was.
            try await logWrites(app)
            pieces[3_999].price = "70.00"
            serve(http, pieces)
            try await scan(poller, app)

            let events = try await EventModel.query(on: app.db).with(\.$product).all()
            #expect(events.count == 1)
            #expect(events.first?.kind == UpdateKind.priceDrop.rawValue)
            #expect(events.first?.product?.externalID == "shopify:4000")
            #expect(events.first?.previousPriceAmount == 100)
            // **The volume rule.** 4,999 unchanged products and their variants are not
            // rewritten; the one that changed is written once.
            #expect(try await writes(app, "products", "UPDATE") == 1)
            #expect(try await writes(app, "variants", "UPDATE") == 1)
            #expect(try await writes(app, "products", "INSERT") == 0)
            #expect(try await writes(app, "variants", "INSERT") == 0)
        }
    }

    /// A drop the poll has not read yet must not be stored by the scan, or the poll would find
    /// it already known and never announce it.
    @Test("A product published in the last day is left for the poll to announce")
    func newIsThePollsWord() async throws {
        try await withServer { app in
            let http = StubHTTP()
            _ = try await seed(app, http: http)
            let old = (1...3).map { Piece(id: $0) }
            serve(http, old)
            let poller = Poller(app: app, http: http)
            try await poll(poller, app)

            let fresh = Piece(id: 10, publishedDaysAgo: 1.0 / 24)
            let deep = Piece(id: 11, publishedDaysAgo: 400)
            serve(http, [fresh] + old + [deep])
            try await scan(poller, app)
            #expect(try await ProductModel.query(on: app.db).filter(\.$externalID == "shopify:10").count() == 0)
            #expect(try await product(app, 11).priceAmount == 100, "old stock the poll never reached is stored")
            #expect(try await EventModel.query(on: app.db).count() == 0)

            try await poll(poller, app)
            let events = try await EventModel.query(on: app.db).with(\.$product).all()
            #expect(events.map { $0.product?.externalID } == ["shopify:10"])
            #expect(events.first?.kind == UpdateKind.product.rawValue)
        }
    }

    @Test("While the poll is failing, the scan stores nothing new")
    func failingPollStoresNothingNew() async throws {
        try await withServer { app in
            let http = StubHTTP()
            let (_, sourceID) = try await seed(app, http: http)
            serve(http, [Piece(id: 1)])
            let poller = Poller(app: app, http: http)
            try await poll(poller, app)

            let source = try #require(try await SourceModel.find(sourceID, on: app.db))
            source.failureCount = 2
            try await source.save(on: app.db)
            serve(http, [Piece(id: 1), Piece(id: 2, publishedDaysAgo: 90)])
            try await scan(poller, app)
            #expect(try await ProductModel.query(on: app.db).count() == 1)
        }
    }

    @Test("A source the poll has not baselined is not scanned")
    func waitsForThePollsBaseline() async throws {
        try await withServer { app in
            let http = StubHTTP()
            _ = try await seed(app, http: http)
            serve(http, [Piece(id: 1)])
            let poller = Poller(app: app, http: http)
            try await scan(poller, app)
            #expect(try await ProductModel.query(on: app.db).count() == 0)
            #expect(try await scanRow(app).startedAt == nil)
        }
    }

    /// Paging a catalogue that changes under the reader can skip a row, so one miss is not a
    /// removal — two complete scans in a row are.
    @Test("Missing from one scan is missing; from two in a row, unlisted; seen again, listed")
    func twoMissesUnlist() async throws {
        try await withServer { app in
            let http = StubHTTP()
            _ = try await seed(app, http: http)
            let all = (1...6).map { Piece(id: $0) }
            serve(http, all)
            let poller = Poller(app: app, http: http)
            try await poll(poller, app)
            try await scan(poller, app)

            serve(http, Array(all.prefix(5)))
            try await scan(poller, app)
            var gone = try await product(app, 6)
            #expect(gone.missingSince != nil)
            #expect(gone.unlistedAt == nil)

            try await scan(poller, app)
            gone = try await product(app, 6)
            #expect(gone.unlistedAt != nil)
            #expect(try await product(app, 5).missingSince == nil)

            serve(http, all)
            try await scan(poller, app)
            gone = try await product(app, 6)
            #expect(gone.missingSince == nil)
            #expect(gone.unlistedAt == nil)
            #expect(try await EventModel.query(on: app.db).count() == 0)
        }
    }

    @Test("A scan that finds most of a shop gone is not believed")
    func massRemovalIsNotBelieved() async throws {
        try await withServer { app in
            let http = StubHTTP()
            _ = try await seed(app, http: http)
            let all = (1...60).map { Piece(id: $0) }
            serve(http, all)
            let poller = Poller(app: app, http: http)
            try await poll(poller, app)
            try await scan(poller, app)

            serve(http, Array(all.prefix(20)))
            try await scan(poller, app)
            try await scan(poller, app)
            #expect(try await ProductModel.query(on: app.db).filter(\.$missingSince != nil).count() == 0)
            #expect(try await ProductModel.query(on: app.db).filter(\.$unlistedAt != nil).count() == 0)
        }
    }

    /// A deploy in the middle of a scan: the next process carries on from the page and the
    /// memory the row holds, and removal is still decided over the whole catalogue.
    @Test("An interrupted scan resumes where it stopped, on a new process")
    func resumes() async throws {
        try await withServer { app in
            let http = StubHTTP()
            _ = try await seed(app, http: http)
            var pieces = (1...1_000).map { Piece(id: $0) }
            serve(http, pieces)
            try await poll(Poller(app: app, http: http), app)
            try await scan(Poller(app: app, http: http), app)

            pieces.remove(at: 998)
            serve(http, pieces)
            try await makeScansDue(Poller(app: app, http: http), app)
            await Poller(app: app, http: http).scanTick(pagesPerTurn: 2)
            var row = try await scanRow(app)
            #expect(row.startedAt != nil)
            #expect(row.nextPage == 3)
            #expect(row.dueAt <= Date(), "back in the queue at once")
            #expect(ScanDigests.decode(row.seen).count == 500)

            // Two more turns, each on a process that has never seen this scan.
            await Poller(app: app, http: http).scanTick(pagesPerTurn: 2)
            await Poller(app: app, http: http).scanTick(pagesPerTurn: 2)
            row = try await scanRow(app)
            #expect(row.startedAt == nil)
            #expect(row.lastPages == 4)
            #expect(row.lastProducts == 999)
            #expect(row.dueAt > Date().addingTimeInterval(11 * 3600), "the next is a slot at least twelve hours on")
            #expect(try await ProductModel.query(on: app.db).filter(\.$missingSince != nil).count() == 1)
            #expect(try await product(app, 999).missingSince != nil)
        }
    }

    /// Older stock going on sale is the sale the newest 250 cannot see — and once the scan has
    /// seen it, the poll's read of the newest stock must not end it.
    @Test("A sale on older stock is one sale, and the poll does not end it while the catalogue holds it")
    func saleOnOlderStock() async throws {
        try await withServer { app in
            let http = StubHTTP()
            let (brandID, _) = try await seed(app, http: http)
            var pieces = (1...600).map { Piece(id: $0, publishedDaysAgo: 2 + Double($0)) }
            serve(http, pieces)
            let poller = Poller(app: app, http: http)
            try await poll(poller, app)
            try await scan(poller, app)

            for index in 300..<600 {
                pieces[index].price = "60.00"
                pieces[index].compareAt = "100.00"
            }
            serve(http, pieces)
            try await scan(poller, app)

            let sales = try await EventModel.query(on: app.db).filter(\.$kind == UpdateKind.sale.rawValue).all()
            #expect(sales.count == 1)
            #expect(sales.first?.title == "SALE · UP TO 40% OFF")
            #expect(try await EventModel.query(on: app.db).filter(\.$kind == UpdateKind.priceDrop.rawValue).count() == 300)
            var brand = try #require(try await BrandModel.find(brandID, on: app.db))
            #expect(brand.catalogueShare == 0.5)
            #expect(brand.saleSince != nil)

            // Days on, the newest 250 are full price. The poll alone would end the sale.
            brand.saleSince = Date().addingTimeInterval(-5 * 86_400)
            try await brand.save(on: app.db)
            try await poll(poller, app)
            brand = try #require(try await BrandModel.find(brandID, on: app.db))
            #expect(brand.saleSince != nil, "the scan still says the catalogue is on sale")
            #expect(try await EventModel.query(on: app.db).filter(\.$kind == UpdateKind.sale.rawValue).count() == 1)
        }
    }

    /// A catalogue is mostly history, and its sold-out stock keeps the compare-at of a sale
    /// that ended long ago.
    @Test("Sold-out stock is not counted in the scan's share")
    func soldOutIsNotCounted() async throws {
        try await withServer { app in
            let http = StubHTTP()
            let (brandID, _) = try await seed(app, http: http)
            let pieces = (1...100).map { id in
                id > 50 ? Piece(id: id, price: "40.00", compareAt: "100.00", available: false) : Piece(id: id)
            }
            serve(http, pieces)
            let poller = Poller(app: app, http: http)
            try await poll(poller, app)
            try await scan(poller, app)
            let brand = try #require(try await BrandModel.find(brandID, on: app.db))
            #expect(brand.catalogueShare == 0)
        }
    }

    @Test("A country shop is scanned while somebody there follows the brand, and never while paused")
    func storefronts() async throws {
        try await withServer { app in
            app.storefrontCountries = ["GB"]
            let (brandID, main, _, shopSource) = try await seedBrand(app, storefront: true, baselined: true)
            let http = HostHTTP()
            for host in ["example.com", "uk.example.com"] {
                http.stub(host, "/products.json?limit=250&page=1", body: json([Piece(id: 1)]))
            }
            let poller = Poller(app: app, http: http)
            try await scan(poller, app)
            #expect(http.requested.contains("example.com/products.json?limit=250&page=1"))
            #expect(!http.requested.contains { $0.hasPrefix("uk.example.com") })
            let paused = try #require(try await CatalogueScanModel.query(on: app.db)
                .filter(\.$source.$id == shopSource!.requireID()).first())
            #expect(paused.lastStartedAt == nil)

            let user = UserModel()
            user.country = "GB"
            try await user.save(on: app.db)
            try await FollowModel(userID: try user.requireID(), brandID: brandID).save(on: app.db)
            try await scan(poller, app)
            #expect(http.requested.contains("uk.example.com/products.json?limit=250&page=1"))
            let shopProducts = try await ProductModel.query(on: app.db).filter(\.$source.$id == shopSource!.requireID()).all()
            #expect(shopProducts.count == 1)
            #expect(shopProducts.first?.storefrontID != nil)
            _ = main
        }
    }

    @Test("A locked shop waits an hour, keeping its place")
    func lockedWaits() async throws {
        try await withServer { app in
            let http = StubHTTP()
            _ = try await seed(app, http: http)
            serve(http, [Piece(id: 1)])
            let poller = Poller(app: app, http: http)
            try await poll(poller, app)
            http.stub("/products.json?limit=250&page=1", status: 401, body: "")
            try await scan(poller, app)
            let row = try await scanRow(app)
            #expect(row.dueAt > Date().addingTimeInterval(50 * 60))
            #expect(row.failureCount == 0)
            #expect(row.completedAt == nil)
        }
    }
}

@Suite("Catalogue scan schedule")
struct CatalogueScanScheduleTests {
    @Test("Slots spread across the day and the next scan is a day on")
    func slots() {
        var hours = Set<Int>()
        for _ in 0..<500 {
            let id = UUID()
            let slot = CatalogueScan.slot(for: id)
            #expect(slot >= 0 && slot < 86_400)
            hours.insert(Int(slot / 3600))

            let start = Date()
            let next = CatalogueScan.nextDue(afterStart: start, sourceID: id)
            #expect(next.timeIntervalSince(start) >= 12 * 3600)
            #expect(next.timeIntervalSince(start) < 36 * 3600)
            // A scan that started on its slot is next due exactly a day later.
            let onSlot = CatalogueScan.nextSlot(onOrAfter: start, sourceID: id)
            #expect(CatalogueScan.nextDue(afterStart: onSlot, sourceID: id) == onSlot.addingTimeInterval(86_400))
        }
        #expect(hours.count == 24, "not all at midnight")
    }

    @Test("A first scan, a lapse and a re-spent baseline are baselines")
    func baselines() {
        let now = Date()
        #expect(Poller.scanIsBaseline(completedAt: nil, sourceBaselinedAt: now, now: now))
        #expect(Poller.scanIsBaseline(completedAt: now.addingTimeInterval(-4 * 86_400), sourceBaselinedAt: nil, now: now))
        #expect(Poller.scanIsBaseline(completedAt: now.addingTimeInterval(-86_400), sourceBaselinedAt: now.addingTimeInterval(-3600), now: now))
        #expect(!Poller.scanIsBaseline(completedAt: now.addingTimeInterval(-86_400), sourceBaselinedAt: now.addingTimeInterval(-9 * 86_400), now: now))
    }

    @Test("Digests round-trip")
    func digests() {
        let seen: Set<UInt32> = Set((1...1_000).map { ScanDigests.digest("shopify:\($0)") })
        #expect(ScanDigests.decode(ScanDigests.encode(seen)) == seen)
        #expect(ScanDigests.decode(nil).isEmpty)
        #expect(ScanDigests.decode("not base64!").isEmpty)
    }
}

@Suite("Retention after a scan")
struct ScanRetentionTests {
    @Test("An unlisted product goes six months after it was unlisted; a listed one in a scanned shop never")
    func reaper() async throws {
        try await withServer { app in
            let http = StubHTTP()
            let (brandID, sourceID) = try await seed(app, http: http)
            let scanRow = CatalogueScanModel(sourceID: sourceID, dueAt: Date())
            scanRow.completedAt = Date()
            try await scanRow.save(on: app.db)
            let sitemap = SourceModel(brandID: brandID, kind: .sitemap, url: "https://shop.example/sitemap.xml")
            try await sitemap.save(on: app.db)

            let user = UserModel()
            try await user.save(on: app.db)
            func make(_ id: String, source: UUID, lastSeenDaysAgo: Double, unlistedDaysAgo: Double? = nil, watched: Bool = false) async throws {
                let product = ProductModel(
                    brandID: brandID, sourceID: source,
                    item: FetchedItem(externalID: id, title: id, publishedAt: Date(), kind: .product)
                )
                product.lastSeenAt = Date().addingTimeInterval(-lastSeenDaysAgo * 86_400)
                product.unlistedAt = unlistedDaysAgo.map { Date().addingTimeInterval(-$0 * 86_400) }
                try await product.save(on: app.db)
                if watched {
                    try await WatchModel(userID: try user.requireID(), brandID: brandID, productID: try product.requireID(),
                                         size: "M", color: nil).save(on: app.db)
                }
            }
            try await make("shopify:1", source: sourceID, lastSeenDaysAgo: 400, unlistedDaysAgo: 200)
            try await make("shopify:2", source: sourceID, lastSeenDaysAgo: 400)
            try await make("shopify:3", source: sourceID, lastSeenDaysAgo: 400, unlistedDaysAgo: 30)
            try await make("sitemap:4", source: try sitemap.requireID(), lastSeenDaysAgo: 400)
            try await make("ucp:5", source: try sitemap.requireID(), lastSeenDaysAgo: 400, watched: true)

            let result = await Reaper(app: app, eventDays: 30, productDays: 180).sweep()
            #expect(result.products == 2)
            let left = try await ProductModel.query(on: app.db).all().map(\.externalID).sorted()
            #expect(left == ["shopify:2", "shopify:3", "ucp:5"])
            #expect(try await WatchModel.query(on: app.db).count() == 1, "a watched product is not pruned out from under its watch")
        }
    }
}

@Suite("Per-item rechecks")
struct PerItemRecheckTests {
    @Test("Watched pages are re-read at most two per host a pass, never-read first")
    func perHost() async throws {
        try await withServer { app in
            let brand = BrandModel(name: "Shop", slug: "big.example", website: "https://big.example",
                                   instagramHandle: nil, usesGeneratedName: false)
            try await brand.save(on: app.db)
            let brandID = try brand.requireID()
            let user = UserModel()
            try await user.save(on: app.db)

            func watched(_ id: String, link: String, readHoursAgo: Double?, seenDaysAgo: Double = 0) async throws {
                let product = ProductModel(
                    brandID: brandID, sourceID: nil,
                    item: FetchedItem(externalID: id, title: id, linkURL: URL(string: link), publishedAt: Date(), kind: .product)
                )
                product.enrichedAt = readHoursAgo.map { Date().addingTimeInterval(-$0 * 3600) }
                product.lastSeenAt = Date().addingTimeInterval(-seenDaysAgo * 86_400)
                try await product.save(on: app.db)
                try await WatchModel(userID: try user.requireID(), brandID: brandID, productID: try product.requireID(),
                                     size: nil, color: nil).save(on: app.db)
            }
            for n in 1...5 {
                try await watched("sitemap:big-\(n)", link: "https://big.example/p/\(n)", readHoursAgo: n == 5 ? nil : Double(6 + n))
            }
            try await watched("ucp:gid://shopify/Product/9", link: "https://small.example/products/nine", readHoursAgo: nil, seenDaysAgo: 5)
            try await watched("ucp:gid://shopify/Product/8", link: "https://small.example/products/eight", readHoursAgo: nil)
            try await watched("sitemap:fresh", link: "https://small.example/p/fresh", readHoursAgo: 1)
            try await watched("shopify:7", link: "https://small.example/products/seven", readHoursAgo: nil)

            let chosen = try await Poller(app: app, http: StubHTTP()).watchedRechecks(limit: 6).map(\.externalID)
            #expect(chosen.filter { $0.hasPrefix("sitemap:big") } == ["sitemap:big-5", "sitemap:big-4"])
            #expect(chosen.contains("ucp:gid://shopify/Product/9"), "fallen out of the protocol's window")
            #expect(!chosen.contains("ucp:gid://shopify/Product/8"), "the protocol read it today")
            #expect(!chosen.contains("sitemap:fresh"), "read an hour ago")
            #expect(!chosen.contains("shopify:7"), "the poll's and the scan's")
            #expect(chosen.count == 3)
        }
    }

    /// A UCP product past the protocol's window: its page is the only thing left that can say
    /// a size came back, and it says so in the page's own variant names.
    @Test("A watched UCP product's page re-read raises the restock on the size held")
    func ucpRestockFromThePage() async throws {
        try await withServer { app in
            let brand = BrandModel(name: "Shop", slug: "shop.example", website: "https://shop.example",
                                   instagramHandle: nil, usesGeneratedName: false)
            try await brand.save(on: app.db)
            let brandID = try brand.requireID()
            let product = ProductModel(
                brandID: brandID, sourceID: nil,
                item: FetchedItem(
                    externalID: "ucp:gid://shopify/Product/9", title: "Cordura Shoulder Bag",
                    linkURL: URL(string: "https://shop.example/products/bag"), publishedAt: Date(), kind: .product,
                    priceText: "£198.00", priceAmount: 198, currency: "GBP", isAvailable: false
                )
            )
            product.enrichedAt = Date().addingTimeInterval(-Poller.recheckAfter - 60)
            product.lastSeenAt = Date().addingTimeInterval(-5 * 86_400)
            try await product.save(on: app.db)
            let productID = try product.requireID()
            for (id, size) in [("gid://shopify/ProductVariant/1", "M"), ("gid://shopify/ProductVariant/2", "L")] {
                try await VariantModel(productID: productID, info: VariantInfo(id: id, title: size, available: false, price: "£198.00", size: size))
                    .save(on: app.db)
            }
            let user = UserModel()
            try await user.save(on: app.db)
            try await WatchModel(userID: try user.requireID(), brandID: brandID, productID: productID, size: "M", color: nil)
                .save(on: app.db)

            let http = StubHTTP()
            http.stub("/products/bag", body: """
                <html><head><script type="application/ld+json">
                {"@context": "https://schema.org", "@type": "ProductGroup", "name": "Bag | Shop",
                 "hasVariant": [
                   {"@type": "Product", "sku": "SKU-M", "size": "M", "offers": {"@type": "Offer", "price": 198,
                    "priceCurrency": "GBP", "availability": "https://schema.org/InStock"}},
                   {"@type": "Product", "sku": "SKU-L", "size": "L", "offers": {"@type": "Offer", "price": 198,
                    "priceCurrency": "GBP", "availability": "https://schema.org/OutOfStock"}}]}
                </script></head><body></body></html>
                """)
            await Poller(app: app, http: http).enrich()

            let events = try await EventModel.query(on: app.db).all()
            #expect(events.map(\.kind) == [UpdateKind.restock.rawValue])
            #expect(events.first?.sizes == ["M"])
            let variants = try await VariantModel.query(on: app.db).all()
            #expect(variants.count == 2, "the page's names are not stored beside the protocol's")
            #expect(variants.first { $0.size == "M" }?.available == true)
            let reread = try #require(try await ProductModel.find(productID, on: app.db))
            #expect(reread.title == "Cordura Shoulder Bag", "a catalogue named it")
            #expect(reread.enrichedAt.map { Date().timeIntervalSince($0) < 60 } == true)
        }
    }

    @Test("A page's variants are renamed to the ones held, or dropped")
    func translation() {
        func held(_ id: String, size: String) -> VariantModel {
            let variant = VariantModel(productID: UUID(), info: VariantInfo(id: id, title: size, available: false, price: "£198", size: size))
            return variant
        }
        let stored = [held("gid://shopify/ProductVariant/1", size: "M"), held("gid://shopify/ProductVariant/2", size: "L")]
        let page = [
            VariantInfo(id: "SKU-M", title: "M", available: true, price: "£198.00", size: "m"),
            VariantInfo(id: "SKU-L", title: "L", available: false, price: "£198.00", size: "L"),
        ]
        let translated = Poller.translated(page, onto: stored)
        #expect(translated.map(\.id) == ["gid://shopify/ProductVariant/1", "gid://shopify/ProductVariant/2"])
        #expect(translated.map(\.available) == [true, false])
        #expect(translated.first?.price == "£198", "the held price text stays, so nothing is rewritten for it")

        let unknown = page + [VariantInfo(id: "SKU-XL", title: "XL", available: true, size: "XL")]
        #expect(Poller.translated(unknown, onto: stored).isEmpty)
        #expect(Poller.translated([VariantInfo(id: "x", title: "One", available: true)], onto: stored).isEmpty)
    }
}

/// The lease, which only Postgres runs. Enabled by `STREETW_TEST_POSTGRES_URL`, as the other
/// Postgres suites are.
@Suite(
    "Catalogue scan on Postgres",
    .enabled(if: ProcessInfo.processInfo.environment["STREETW_TEST_POSTGRES_URL"] != nil),
    .serialized
)
struct CatalogueScanPostgresTests {
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

    @Test("Two scanners at once never read one source, and each source is read once")
    func leaseIsExclusive() async throws {
        try await withPostgres { app in
            let http = StubHTTP()
            http.stub("/products.json?limit=250&page=1", body: json([Piece(id: 1)]))
            var sourceIDs: [UUID] = []
            for n in 0..<8 {
                let brand = BrandModel(name: "Shop \(n)", slug: "shop\(n).example", website: nil,
                                       instagramHandle: nil, usesGeneratedName: false)
                try await brand.save(on: app.db)
                let source = SourceModel(brandID: try brand.requireID(), kind: .shopify, url: "https://shop\(n).example")
                source.baselinedAt = Date()
                source.lastCheckedAt = Date()
                try await source.save(on: app.db)
                sourceIDs.append(try source.requireID())
            }
            let first = Poller(app: app, http: http)
            let second = Poller(app: app, http: http)
            try await first.enrolScans()
            try await second.enrolScans()
            #expect(try await CatalogueScanModel.query(on: app.db).count() == 8, "enrolled once, whoever got there")
            for row in try await CatalogueScanModel.query(on: app.db).all() {
                row.dueAt = Date().addingTimeInterval(-60)
                try await row.save(on: app.db)
            }

            async let a = first.scanTick(limit: 8)
            async let b = second.scanTick(limit: 8)
            let pages = await a + b
            #expect(pages == 8, "one page per shop, not two")
            let rows = try await CatalogueScanModel.query(on: app.db).all()
            #expect(rows.allSatisfy { $0.completedAt != nil })
            #expect(try await ProductModel.query(on: app.db).count() == 8)
            _ = sourceIDs
        }
    }
}

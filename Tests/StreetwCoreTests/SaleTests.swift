import Foundation
import Testing

@testable import StreetwCore

/// What a storefront's announcement bar is saying, read from bars as they were served.
@Suite("Sale banners")
struct SaleBannerTests {
    /// White Fox, a code sale: nothing in its catalogue moves, so this bar is the only
    /// place the sale exists. Its afterpay line hides inside an SVG `<title>`.
    @Test("A code sale is read with its percentage, its scope and its code")
    func codeSale() throws {
        let banner = try #require(SaleBanner.read(html: Fixtures.string("whitefox_home.html")))
        #expect(banner.title == "30% OFF EVERYTHING · CODE BDAY30")
        #expect(banner.percent == 30)
        #expect(banner.code == "BDAY30")
        #expect(banner.message.contains("BDAY30"))
    }

    /// Motel Rocks scrolls three messages twice: a student discount, a shipping threshold
    /// and a sale. Only the last is a sale, and only once.
    @Test("A student discount and free shipping beside a sale leave the sale")
    func marqueeWithOneSale() throws {
        let html = Fixtures.string("motelrocks_home.html")
        let messages = SaleBanner.messages(in: html)
        #expect(messages.count == 3, "the marquee's second loop is the same three messages")

        let banner = try #require(SaleBanner.read(html: html))
        #expect(banner.title == "UP TO 50% OFF DRESSES")
        #expect(banner.code == nil)
    }

    /// Princess Polly leads with "EXTRA 10% OFF SALE STUDENT DISCOUNT" — a percentage, the
    /// word sale, and an offer for somebody else entirely.
    @Test("Somebody else's discount is not a sale")
    func studentDiscountIsNotASale() {
        #expect(SaleBanner.read(html: Fixtures.string("princesspolly_home.html")) == nil)
    }

    @Test("Free shipping is not a sale, whatever the markup around it")
    func freeShippingIsNotASale() {
        #expect(SaleBanner.read(html: Fixtures.string("youngla_home.html")) == nil)
        // Petal & Pup's bar carries `cell-selector=".list > *"` — a tag read to its first
        // `>` spills its own attributes into the message.
        let petal = SaleBanner.messages(in: Fixtures.string("petalandpup_home.html"))
        #expect(petal == ["Free shipping on orders over $80*"])
        #expect(SaleBanner.read(html: Fixtures.string("petalandpup_home.html")) == nil)
    }

    /// Everything a page says outside its bar — the navigation's "Sale" link, analytics
    /// config naming `SALE_OF_DATA` — must never reach the reader.
    @Test("Only the bar is read, never the page")
    func onlyTheBar() {
        let page = """
        <html><head><script>{"privacyPurposes":["SALE_OF_DATA"]}</script></head><body>
        <nav class="site-nav"><a href="/collections/sale">Sale</a><a href="/new">New</a></nav>
        <div class="hero"><h2>END OF SEASON SALE — UP TO 70% OFF</h2></div>
        <div class="announcement-bar"><p>Free returns on every order</p></div>
        </body></html>
        """
        #expect(SaleBanner.read(html: page) == nil)
        #expect(SaleBanner.messages(in: page) == ["Free returns on every order"])
    }

    @Test("A page with no bar has nothing to say")
    func noBar() {
        #expect(SaleBanner.read(html: "<html><body><h1>Kith</h1><a href=/sale>Sale</a></body></html>") == nil)
    }

    @Test("Wordings that are sales")
    func sales() {
        let cases: [(String, String)] = [
            ("25% off everything with code AUTUMN", "25% OFF EVERYTHING · CODE AUTUMN"),
            ("END OF SEASON SALE — UP TO 50% OFF", "END OF SEASON SALE · UP TO 50% OFF"),
            ("Archive sale now on", "ARCHIVE SALE"),
            ("SALE NOW ON – 30% OFF EVERYTHING", "30% OFF EVERYTHING"),
            ("50-70% off sitewide", "UP TO 70% OFF SITEWIDE"),
            ("Black Friday: extra 20% off sale styles", "BLACK FRIDAY · EXTRA 20% OFF"),
            ("Save 15% on outerwear this weekend", "15% OFF"),
            ("FREE SHIPPING + 20% OFF WITH CODE FALL20", "20% OFF · CODE FALL20"),
        ]
        for (message, title) in cases {
            #expect(SaleBanner.reading(message)?.title == title, "\(message)")
        }
    }

    @Test("Wordings that are not")
    func notSales() {
        for message in [
            "Free shipping for US orders over $100",
            "10% off your first order when you sign up",
            "Students get 10% off everything*",
            "Get 15% off when you download the app",
            "New collection goes on sale Friday 11AM",
            "All sale items are final sale",
            "Pre-sale access for members",
            "100% organic cotton",
            "SAVE 3$ OFF BOXERS WHEN SPENDING $50+",
            "Wear now, pay later with Afterpay",
            "Sale",
        ] {
            #expect(SaleBanner.reading(message) == nil, "\(message)")
        }
    }

    /// A code is what a code looks like — "code at checkout" is not one.
    @Test("Only something shaped like a code is a code")
    func codeShape() {
        #expect(SaleBanner.reading("20% off with code at checkout")?.code == nil)
        #expect(SaleBanner.reading("20% OFF — USE CODE: FALL20")?.code == "FALL20")
    }
}

@Suite("Sale banner ledger")
struct SaleBannerLedgerTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private var autumn: SaleBanner { SaleBanner.reading("25% off everything with code AUTUMN")! }

    @Test("The first read is a baseline")
    func firstReadIsBaseline() {
        let outcome = SaleBannerLedger.decide(found: autumn, stored: nil, seenAt: nil, isFirstCheck: true, now: now)
        #expect(!outcome.announce)
        #expect(outcome.stored == autumn.title)
    }

    @Test("A new sale is announced once, and a reworded one is not new")
    func onceperSale() {
        let first = SaleBannerLedger.decide(found: autumn, stored: nil, seenAt: nil, isFirstCheck: false, now: now)
        #expect(first.announce)

        let reworded = SaleBanner.reading("Last day! 25% off everything — code AUTUMN")!
        let again = SaleBannerLedger.decide(
            found: reworded, stored: first.stored, seenAt: first.seenAt, isFirstCheck: false,
            now: now.addingTimeInterval(3_600)
        )
        #expect(!again.announce)

        let deeper = SaleBanner.reading("Now 40% off everything with code AUTUMN40")!
        #expect(SaleBannerLedger.decide(
            found: deeper, stored: again.stored, seenAt: again.seenAt, isFirstCheck: false,
            now: now.addingTimeInterval(7_200)
        ).announce)
    }

    /// Bars rotate and are A/B tested; a read without the sale must not re-arm it.
    @Test("A bar that briefly loses the sale does not announce it again")
    func flappingBar() {
        let missing = SaleBannerLedger.decide(
            found: nil, stored: autumn.title, seenAt: now, isFirstCheck: false, now: now.addingTimeInterval(3_600)
        )
        #expect(!missing.announce)
        #expect(missing.stored == autumn.title)
        #expect(missing.seenAt == now)

        let back = SaleBannerLedger.decide(
            found: autumn, stored: missing.stored, seenAt: missing.seenAt, isFirstCheck: false,
            now: now.addingTimeInterval(7_200)
        )
        #expect(!back.announce)
    }

    @Test("The same words after two weeks away are a new sale")
    func sameWordsLater() {
        #expect(SaleBannerLedger.decide(
            found: autumn, stored: autumn.title, seenAt: now, isFirstCheck: false,
            now: now.addingTimeInterval(SaleBannerLedger.forgetAfter + 60)
        ).announce)
    }
}

@Suite("Catalogue sales")
struct CatalogueSaleTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func reading(priced: Int, markedDown: Int, deepest: Int = 40) -> CatalogueSale.Reading {
        var reading = CatalogueSale.Reading()
        for index in 0..<priced {
            reading.count(now: index < markedDown ? Double(100 - deepest) : 100, original: 100, previous: nil)
        }
        return reading
    }

    @Test("A reading counts cuts from the original and from the last poll")
    func reads() {
        var reading = CatalogueSale.Reading()
        reading.count(now: 40, original: 80, previous: nil)     // the brand's own tag
        reading.count(now: 120, original: nil, previous: 150)   // fell since the last poll
        reading.count(now: 100, original: nil, previous: 100)   // full price
        reading.count(now: nil, original: nil, previous: nil)   // a sitemap row: not priced
        #expect(reading.priced == 3)
        #expect(reading.markedDown == 2)
        #expect(reading.deepest == 50)
    }

    /// A brand already on sale the first time its prices were measured did not start one —
    /// the same baseline rule as everything else on a first sight.
    @Test("The first measurement is a baseline")
    func firstMeasurementIsBaseline() {
        let decision = CatalogueSale.decide(reading(priced: 100, markedDown: 60), state: .init(), isBaseline: false, now: now)
        #expect(decision == .record(.init(measuredAt: now, since: now)))
    }

    @Test("Crossing into a sale is announced once")
    func startsOnce() {
        let measured = CatalogueSale.State(measuredAt: now.addingTimeInterval(-86_400), since: nil)
        let start = CatalogueSale.decide(reading(priced: 100, markedDown: 40), state: measured, isBaseline: false, now: now)
        guard case .started(let live) = start else {
            Issue.record("expected the sale to start, got \(start)")
            return
        }
        #expect(live.since == now)
        // Still on sale an hour later: nothing new to say.
        #expect(CatalogueSale.decide(
            reading(priced: 100, markedDown: 45), state: live, isBaseline: false, now: now.addingTimeInterval(3_600)
        ) == .unchanged)
    }

    /// Two markdowns in a five-product shop are 40% and are not a sale.
    @Test("A handful of markdowns is not a sale, however small the shop")
    func minimumCount() {
        let measured = CatalogueSale.State(measuredAt: now.addingTimeInterval(-86_400))
        #expect(CatalogueSale.decide(reading(priced: 5, markedDown: 2), state: measured, isBaseline: false, now: now) == .unchanged)
        #expect(CatalogueSale.decide(reading(priced: 250, markedDown: 11), state: measured, isBaseline: false, now: now) == .unchanged)
        // A busy brand's few markdowns: plenty of them, a small share.
        #expect(CatalogueSale.decide(reading(priced: 250, markedDown: 40), state: measured, isBaseline: false, now: now) == .unchanged)
    }

    /// Hovering around the line must not announce it every other poll, and a markdown
    /// taken in waves must not announce each wave.
    @Test("A sale ends only below the lower line and after its minimum length")
    func endsWithHysteresis() {
        let live = CatalogueSale.State(measuredAt: now.addingTimeInterval(-10 * 86_400), since: now)
        // Dipped under the start but not under the end.
        #expect(CatalogueSale.decide(reading(priced: 100, markedDown: 20), state: live, isBaseline: false,
                                     now: now.addingTimeInterval(4 * 86_400)) == .unchanged)
        // Under the end, but too soon — the pass after a mass markdown with no compare-at.
        #expect(CatalogueSale.decide(reading(priced: 100, markedDown: 0), state: live, isBaseline: false,
                                     now: now.addingTimeInterval(3_600)) == .unchanged)
        // Under the end and long enough: over, and re-armed.
        let over = CatalogueSale.decide(reading(priced: 100, markedDown: 2), state: live, isBaseline: false,
                                        now: now.addingTimeInterval(4 * 86_400))
        #expect(over == .record(.init(measuredAt: live.measuredAt, since: nil)))
    }

    @Test("A pass with no prices measures nothing")
    func unpricedPass() {
        #expect(CatalogueSale.decide(CatalogueSale.Reading(), state: .init(), isBaseline: false, now: now) == .unchanged)
    }

    @Test("The announcement says how deep and how much")
    func announcement() {
        let said = CatalogueSale.announcement(for: reading(priced: 120, markedDown: 42, deepest: 50))
        #expect(said.title == "SALE · UP TO 50% OFF")
        #expect(said.summary == "42 of the 120 pieces just checked are marked down.")
    }
}

/// Never sending a kind to a client that cannot draw it.
@Suite("Feed kinds")
struct FeedKindsTests {
    /// Every request 1.0 makes names nothing, and 1.0 maps an unknown kind onto a product.
    @Test("A request that names nothing gets 1.0's seven kinds")
    func legacyByDefault() {
        #expect(FeedKinds.accepted(nil) == FeedKinds.legacy.map(\.rawValue))
        #expect(FeedKinds.accepted("") == FeedKinds.legacy.map(\.rawValue))
        #expect(!FeedKinds.accepted(nil).contains(UpdateKind.sale.rawValue))
    }

    @Test("A client gets what it names, and only kinds that exist")
    func namedKinds() {
        #expect(Set(FeedKinds.accepted(FeedKinds.understood)) == Set(UpdateKind.allCases.map(\.rawValue)))
        #expect(FeedKinds.accepted("sale, restock,hologram") == ["restock", "sale"])
        // Nothing recognisable is the same as nothing named.
        #expect(FeedKinds.accepted("hologram") == FeedKinds.legacy.map(\.rawValue))
    }

    @Test("The legacy list is exactly what 1.0 shipped with")
    func legacyIsFrozen() {
        #expect(FeedKinds.legacy.count == 7)
        #expect(Set(UpdateKind.allCases).subtracting(FeedKinds.legacy) == [.sale])
    }

    /// The new client's own half: a kind it has never heard of is skipped, not drawn as a
    /// product the way 1.0 draws it.
    @Test("An unknown kind is unknown, not a product")
    func unknownKind() throws {
        let json = Data(#"{"eventID":"6F9619FF-8B86-D011-B42D-00C04FC964FF","kind":"hologram","createdAt":"2026-10-25T10:00:00Z","brandID":"6F9619FF-8B86-D011-B42D-00C04FC964FE","brandName":"Kith","title":"x","imageURLs":[],"restockedSizes":[],"availableInMySize":false}"#.utf8)
        let item = try APICoding.decoder.decode(FeedItem.self, from: json)
        #expect(item.knownKind == nil)
        #expect(item.updateKind == .product, "1.0's reading, kept for what already calls it")
        #expect(item.originalPriceAmount == nil, "a server that predates the field sends none")
    }

    @Test("A sale is sudden, is sale news, and leads after a lock")
    func saleKind() {
        #expect(UpdateKind.sale.isSudden)
        #expect(UpdateKind.sale.isSale)
        #expect(UpdateKind.sale.newsRank == UpdateKind.dropLock.newsRank + 1)
        #expect(Set(UpdateKind.allCases.map(\.newsRank)).count == UpdateKind.allCases.count)
    }
}

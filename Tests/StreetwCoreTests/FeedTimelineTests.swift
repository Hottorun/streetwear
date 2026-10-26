import Foundation
import Testing

@testable import StreetwCore

/// The Phase 1 feed: one card per event, newest first across every brand, a release and a
/// burst each one card, and a line where the last visit ended. Pinned here because the app
/// has no test target and these rules are the whole of the screen's order.
@Suite("Feed timeline")
struct FeedTimelineTests {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    private func at(_ minutesAgo: Double) -> Date { now.addingTimeInterval(-minutesAgo * 60) }

    private func entry(
        _ id: String,
        _ kind: UpdateKind = .product,
        brand: String = "kith",
        happened: Double,
        arrived: Double? = nil,
        product: String? = nil,
        isYours: Bool = false,
        members: Set<String> = []
    ) -> FeedTimeline.Entry {
        FeedTimeline.Entry(
            id: id,
            brand: brand,
            kind: kind,
            happenedAt: at(happened),
            arrivedAt: at(arrived ?? happened),
            product: product,
            isYours: isYours,
            releaseMembers: members
        )
    }

    // MARK: - Order

    @Test("Newest first across brands, not grouped by brand")
    func newestFirstAcrossBrands() {
        let result = FeedTimeline.build([
            entry("a", brand: "kith", happened: 300),
            entry("b", brand: "palace", happened: 100),
            entry("c", brand: "kith", happened: 200),
            entry("d", .restock, brand: "palace", happened: 50)
        ], since: nil, now: now)
        #expect(result.fresh.map(\.id) == ["d", "b", "c", "a"])
    }

    /// Storefronts stamp a drop with one second, so ties are the common case — and an order
    /// that reshuffles them on every render is a list moving under a thumb.
    @Test("Ties break on the id, so the order is total and stable")
    func tiesBreakOnID() {
        let rows = [
            entry("shopify:1", .restock, happened: 10),
            entry("shopify:3", .priceDrop, happened: 10),
            entry("shopify:2", .post, happened: 10)
        ]
        let once = FeedTimeline.build(rows, since: nil, now: now).fresh.map(\.id)
        let reversed = FeedTimeline.build(rows.reversed(), since: nil, now: now).fresh.map(\.id)
        #expect(once == ["shopify:3", "shopify:2", "shopify:1"])
        #expect(once == reversed)
    }

    @Test("One garment, one card: the newest event for a product is the one shown")
    func oncePerProduct() {
        let result = FeedTimeline.build([
            entry("event:drop", .product, happened: 600, product: "shopify:9"),
            entry("event:back", .restock, happened: 30, product: "shopify:9"),
            entry("event:other", .product, happened: 100, product: "shopify:8")
        ], since: nil, now: now)
        #expect(result.fresh.map(\.id) == ["event:back", "event:other"])
    }

    /// A lock is a state of the shop and is said by the line above the feed while it is true;
    /// a product dated ahead is Upcoming's. Neither is a card in the timeline.
    @Test("Locks and dates ahead are not timeline cards")
    func locksAndFutureAreNotCards() {
        let result = FeedTimeline.build([
            entry("lock", .dropLock, happened: 5),
            entry("ahead", .product, happened: -600),
            entry("now", .product, happened: 1)
        ], since: nil, now: now)
        #expect(result.fresh.map(\.id) == ["now"])
    }

    // MARK: - Since you were last here

    @Test("The line falls on arrival, and nothing is above it that arrived before the visit")
    func lineFallsOnArrival() {
        let boundary = at(120)
        let result = FeedTimeline.build([
            entry("old", happened: 500, arrived: 500),
            entry("seen", .restock, happened: 200, arrived: 190),
            // Published before the last visit, found by a poll after it: new to the reader.
            entry("late", .post, happened: 300, arrived: 60),
            entry("new", .priceDrop, happened: 10, arrived: 10)
        ], since: boundary, now: now)
        #expect(result.fresh.map(\.id) == ["new", "late"])
        #expect(result.earlier.map(\.id) == ["seen", "old"])
    }

    /// The migration from 1.0, and a fresh install's first visit: with nothing recorded,
    /// everything that arrived as news is new.
    @Test("With no visit recorded, every card is above the line")
    func noBoundaryMeansAllNew() {
        let result = FeedTimeline.build([entry("a", happened: 9000), entry("b", .restock, happened: 5)], since: nil, now: now)
        #expect(result.earlier.isEmpty)
        #expect(result.fresh.count == 2)
    }

    // MARK: - Bursts

    @Test("Three new products from one brand inside thirty minutes are one drop card")
    func burstIsOneCard() {
        let result = FeedTimeline.build([
            entry("p1", happened: 40),
            entry("p2", happened: 35),
            entry("p3", happened: 20),
            entry("p4", happened: 12),
            entry("other", brand: "palace", happened: 30)
        ], since: nil, now: now)
        let drop = result.fresh.first { $0.shape == .group }
        #expect(drop?.entries == ["p4", "p3", "p2", "p1"])
        #expect(drop?.kind == .product)
        #expect(result.fresh.map(\.shape) == [.group, .single])
        #expect(result.fresh.first?.id == drop?.id, "a card sits at its newest event")
    }

    @Test("Two products are two cards, and other brands never join a burst")
    func pairsAndOtherBrandsStaySingle() {
        let result = FeedTimeline.build([
            entry("p1", brand: "kith", happened: 10),
            entry("p2", brand: "kith", happened: 12),
            entry("q1", brand: "palace", happened: 11)
        ], since: nil, now: now)
        #expect(result.fresh.allSatisfy { $0.shape == .single })
        #expect(result.fresh.count == 3)
    }

    /// Anchored at the first event, so a brand trickling a product every twenty minutes does
    /// not become one card spanning the day.
    @Test("The window is anchored at the first event, not chained")
    func windowIsAnchored() {
        let trickle = (0..<6).map { entry("t\($0)", happened: Double(200 - $0 * 20)) }
        let result = FeedTimeline.build(trickle, since: nil, now: now)
        let groups = result.fresh.filter { $0.shape == .group }
        #expect(groups.count == 0)
        #expect(result.fresh.count == 6)
    }

    @Test("A burst keeps its id as it grows forward, so the card is not rebuilt")
    func burstIDIsStable() {
        let first = [entry("p1", happened: 40), entry("p2", happened: 39), entry("p3", happened: 38)]
        let before = FeedTimeline.build(first, since: nil, now: now).fresh.first
        let after = FeedTimeline.build(first + [entry("p4", happened: 15)], since: nil, now: now).fresh.first
        #expect(before?.id == after?.id)
        #expect(after?.entries.count == 4)
    }

    @Test("Restocks and markdowns in quantity group too; a restock in your size never does")
    func restocksAndMarkdownsGroup() {
        let result = FeedTimeline.build([
            entry("r1", .restock, happened: 30),
            entry("r2", .restock, happened: 29),
            entry("r3", .restock, happened: 28),
            entry("mine", .restock, happened: 27, isYours: true),
            entry("m1", .priceDrop, happened: 20),
            entry("m2", .priceDrop, happened: 19),
            entry("m3", .priceDrop, happened: 18)
        ], since: nil, now: now)
        let shapes = Dictionary(uniqueKeysWithValues: result.fresh.map { ($0.kind == .restock && $0.shape == .single ? "mine" : $0.kind.rawValue, $0) })
        #expect(shapes["restock"]?.shape == .group)
        #expect(shapes["restock"]?.entries.count == 3)
        #expect(shapes["mine"]?.entries == ["mine"])
        #expect(shapes["priceDrop"]?.shape == .group)
    }

    @Test("A burst that grew since the last visit is above the line")
    func grownBurstIsNew() {
        let result = FeedTimeline.build([
            entry("p1", happened: 300, arrived: 300),
            entry("p2", happened: 295, arrived: 300),
            entry("p3", happened: 290, arrived: 30)
        ], since: at(120), now: now)
        #expect(result.fresh.count == 1)
        #expect(result.earlier.isEmpty)
    }

    // MARK: - Releases

    @Test("A release absorbs its own garments, and they are not cards of their own")
    func releaseAbsorbsMembers() {
        let result = FeedTimeline.build([
            entry("collection:alpine", .collection, happened: 60, members: ["shopify:1", "shopify:2", "shopify:3"]),
            entry("shopify:1", happened: 61),
            entry("shopify:2", .restock, happened: 61),
            entry("shopify:3", happened: 62),
            entry("shopify:4", happened: 62),
            entry("palace:1", brand: "palace", happened: 61, product: "shopify:2")
        ], since: nil, now: now)
        let release = result.fresh.first { $0.shape == .release }
        #expect(release?.entries.first == "collection:alpine")
        #expect(Set(release?.entries.dropFirst() ?? []) == ["shopify:1", "shopify:2", "shopify:3"])
        // Not a member, and another brand's row with a colliding key, both stay.
        #expect(result.fresh.contains { $0.id == "shopify:4" })
        #expect(result.fresh.contains { $0.id == "palace:1" })
        #expect(!result.fresh.contains { $0.id == "shopify:1" })
    }

    /// The most specific thing the feed can say, and a markdown is news about a price rather
    /// than about the release: neither is folded away.
    @Test("A member back in your size, a member's markdown and a late restock stay cards")
    func releaseKeepsWhatIsNewsOfItsOwn() {
        let result = FeedTimeline.build([
            entry("collection", .collection, happened: 10_000, members: ["a", "b", "c"]),
            entry("a", .restock, happened: 9_990, isYours: true),
            entry("b", .priceDrop, happened: 9_990),
            entry("c", .restock, happened: 60)
        ], since: nil, now: now)
        #expect(Set(result.fresh.filter { $0.shape == .single }.map(\.id)) == ["a", "b", "c"])
        #expect(result.fresh.first { $0.shape == .release }?.entries == ["collection"])
    }

    // MARK: - Filters

    @Test("Each filter admits its own kinds; a post is All's alone; Upcoming admits nothing")
    func filters() {
        for kind in UpdateKind.allCases {
            #expect(FeedFilter.all.admits(kind))
            #expect(!FeedFilter.upcoming.admits(kind))
            let homes = [FeedFilter.drops, .restocks, .sales].filter { $0.admits(kind) }
            #expect(homes.count == (kind == .post ? 0 : 1), "\(kind) belongs under one narrowed filter")
        }
        #expect(FeedFilter.drops.admits(.pageChange))
        #expect(FeedFilter.sales.admits(.sale) && FeedFilter.sales.admits(.priceDrop))
    }

    @Test("Narrowing keeps both sides of the line and filters by brand")
    func narrowing() {
        let result = FeedTimeline.build([
            entry("a", .restock, brand: "kith", happened: 10, arrived: 10),
            entry("b", .restock, brand: "palace", happened: 500, arrived: 500),
            entry("c", .product, brand: "kith", happened: 400, arrived: 400)
        ], since: at(100), now: now)
        let restocks = result.narrowed(to: .restocks)
        #expect(restocks.fresh.map(\.id) == ["a"])
        #expect(restocks.earlier.map(\.id) == ["b"])
        let kith = result.narrowed(to: .all, brand: "kith")
        #expect((kith.fresh + kith.earlier).map(\.id) == ["a", "c"])
    }

    // MARK: - Labels

    @Test("One label per kind, and only your size and a lock are urgent")
    func labels() {
        #expect(FeedLabel.single(.product).text == "NEW")
        #expect(FeedLabel.single(.restock, isYours: true) == FeedLabel("BACK IN YOUR SIZE", isUrgent: true))
        #expect(FeedLabel.single(.restock) == FeedLabel("BACK IN STOCK"))
        #expect(FeedLabel.single(.priceDrop, percentOff: 30).text == "−30%")
        #expect(FeedLabel.single(.priceDrop).text == "PRICE CUT")
        #expect(FeedLabel.single(.dropLock).isUrgent)
        #expect(FeedLabel.single(.collection, title: "Alpine Capsule").text == "NEW · ALPINE CAPSULE")
        #expect(FeedLabel.group(.priceDrop, deepestCut: 40).text == "UP TO −40%")
        #expect(FeedLabel.group(.restock).text == "BACK IN STOCK")
        for kind in UpdateKind.allCases where kind != .restock && kind != .dropLock {
            #expect(!FeedLabel.single(kind).isUrgent, "\(kind) is not about the reader")
        }
    }

    @Test("A sale is said in the brand's own terms, as a sale")
    func saleLabel() {
        #expect(FeedLabel.single(.sale, title: "25% OFF · CODE AUTUMN").text == "SALE 25% OFF · CODE AUTUMN")
        #expect(FeedLabel.single(.sale, title: "SALE · UP TO 40% OFF").text == "SALE · UP TO 40% OFF")
        #expect(FeedLabel.single(.sale, title: "End of Season Sale · 20% off").text == "END OF SEASON SALE · 20% OFF")
        #expect(FeedLabel.single(.sale, title: "Wholesale prices").text == "SALE WHOLESALE PRICES")
        #expect(FeedLabel.single(.sale).text == "SALE")
    }

    @Test("A card of several pieces says how many, and the cheapest way in")
    func piecesLine() {
        #expect(FeedLabel.pieces(24, from: "$38") == "24 PIECES · FROM $38")
        #expect(FeedLabel.pieces(1) == "1 PIECE")
    }
}

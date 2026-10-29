import Foundation
import Testing

@testable import StreetwCore

/// What the feed reads of the store. The owner's report, replayed: the morning's drops were
/// scrolled, the afternoon and the evening each brought a daily scan's markdowns and restocks
/// on older stock, and the morning was gone from the feed — pushed out of a read of the newest
/// 500 arrivals by rows that drew as one card per shop.
@Suite("Feed window")
struct FeedWindowTests {
    private let morning = Date(timeIntervalSince1970: 1_790_000_000)
    private let brands = ["alpha", "bravo", "cobalt", "delta"]

    /// The store, newest arrival first — the order the feed's query reads it in.
    private struct Store {
        var rows: [FeedTimeline.Entry] = []

        mutating func sync(_ entries: [FeedTimeline.Entry]) {
            rows = (rows + entries).sorted {
                $0.arrivedAt == $1.arrivedAt ? $0.id > $1.id : $0.arrivedAt > $1.arrivedAt
            }
        }

        /// When the row at `offset` arrived — the one question the view asks the store.
        func edge(at offset: Int) -> Date? {
            rows.indices.contains(offset) ? rows[offset].arrivedAt : nil
        }

        func read(_ window: FeedWindow) -> [FeedTimeline.Entry] {
            rows.filter { window.admits(arrival: $0.arrivedAt) }
        }
    }

    /// Two new products and a restock per shop: twelve single cards, each its own garment.
    private func morningDrops() -> [FeedTimeline.Entry] {
        brands.enumerated().flatMap { index, brand in
            let at = morning.addingTimeInterval(Double(index) * 10)
            return [
                FeedTimeline.Entry(id: "m-\(brand)-1", brand: brand, kind: .product, happenedAt: at, arrivedAt: morning.addingTimeInterval(60)),
                FeedTimeline.Entry(id: "m-\(brand)-2", brand: brand, kind: .product, happenedAt: at.addingTimeInterval(4), arrivedAt: morning.addingTimeInterval(60)),
                FeedTimeline.Entry(id: "m-\(brand)-r", brand: brand, kind: .restock, happenedAt: at.addingTimeInterval(2), arrivedAt: morning.addingTimeInterval(60))
            ]
        }
    }

    /// A scan's worth per shop: 150 markdowns and 20 restocks on older stock, seconds apart.
    /// Each row is stamped as it is merged, so arrivals are a millisecond or so apart.
    private func scan(_ tag: String, hoursLater: Double) -> [FeedTimeline.Entry] {
        let at = morning.addingTimeInterval(hoursLater * 3600)
        return brands.enumerated().flatMap { index, brand in
            (0..<170).map { i in
                FeedTimeline.Entry(
                    id: "\(tag)-\(brand)-\(i)",
                    brand: brand,
                    kind: i < 150 ? .priceDrop : .restock,
                    happenedAt: at.addingTimeInterval(Double(i)),
                    arrivedAt: at.addingTimeInterval(60 + Double(index * 170 + i) / 1000)
                )
            }
        }
    }

    private func cardIDs(_ rows: [FeedTimeline.Entry]) -> Set<String> {
        let result = FeedTimeline.build(rows, since: nil, now: morning.addingTimeInterval(86_400))
        return Set((result.fresh + result.earlier).map(\.id))
    }

    /// Every row some card stands for. A burst is anchored at its oldest event, so reading
    /// further back can re-anchor a card the read cut in two — the card's id changes and its
    /// rows do not leave the screen.
    private func drawnRows(_ rows: [FeedTimeline.Entry]) -> Set<String> {
        let result = FeedTimeline.build(rows, since: nil, now: morning.addingTimeInterval(86_400))
        return Set((result.fresh + result.earlier).flatMap(\.entries))
    }

    private var morningIDs: Set<String> { Set(morningDrops().map(\.id)) }

    @Test("A sync never takes a row off the bottom of the read")
    func laterSyncsKeepTheMorning() {
        var store = Store()
        store.sync(morningDrops())
        let window = FeedWindow.opening(edge: store.edge(at: FeedWindow.openingOffset))
        #expect(cardIDs(store.read(window)).isSuperset(of: morningIDs))

        store.sync(scan("afternoon", hoursLater: 6))
        store.sync(scan("evening", hoursLater: 11))

        // What the feed read before: the newest 500 arrivals. 1,360 scan rows arrived after
        // the morning, and every one of its cards is gone.
        let capped = Array(store.rows.prefix(FeedWindow.page))
        #expect(cardIDs(capped).isDisjoint(with: morningIDs))
        // …while those rows drew as one markdown card and one restock card per shop per scan.
        #expect(cardIDs(capped).count <= 16)

        #expect(cardIDs(store.read(window)).isSuperset(of: morningIDs))
    }

    @Test("Opened on a deep store, reaching the end reads back to the morning")
    func extendingReachesEverything() {
        var store = Store()
        store.sync(morningDrops())
        store.sync(scan("afternoon", hoursLater: 6))
        store.sync(scan("evening", hoursLater: 11))

        var window = FeedWindow.opening(edge: store.edge(at: FeedWindow.openingOffset))
        #expect(store.read(window).count == FeedWindow.page)
        #expect(cardIDs(store.read(window)).isDisjoint(with: morningIDs))

        var shown = drawnRows(store.read(window))
        var reads = 0
        while window.hasMore(loaded: store.read(window).count, total: store.rows.count) {
            let loaded = store.read(window).count
            window = window.extended(to: store.edge(at: FeedWindow.extendingOffset(loaded: loaded)))
            let now = drawnRows(store.read(window))
            // Reading further back only adds: nothing on screen is taken away by it.
            #expect(now.isSuperset(of: shown))
            shown = now
            reads += 1
        }
        #expect(reads == 2)
        #expect(window.floor == nil)
        #expect(store.read(window).count == store.rows.count)
        #expect(cardIDs(store.read(window)).isSuperset(of: morningIDs))
    }

    @Test("Fewer arrivals than a page reads them all, and there is nothing more")
    func shallowStoreReadsEverything() {
        var store = Store()
        store.sync(morningDrops())
        let window = FeedWindow.opening(edge: store.edge(at: FeedWindow.openingOffset))
        #expect(window.floor == nil)
        #expect(!window.hasMore(loaded: store.rows.count, total: store.rows.count))
        store.sync(scan("afternoon", hoursLater: 6))
        #expect(store.read(window).count == store.rows.count)
    }

    @Test("The floor only ever moves back")
    func floorOnlyMovesBack() {
        let window = FeedWindow(floor: morning)
        #expect(window.extended(to: morning.addingTimeInterval(3600)).floor == morning)
        #expect(window.extended(to: morning.addingTimeInterval(-3600)).floor == morning.addingTimeInterval(-3600))
        #expect(window.extended(to: nil).floor == nil)
        #expect(FeedWindow(floor: nil).extended(to: morning).floor == nil)
    }

    @Test("A row arriving with the edge's own stamp is read")
    func tiesAtTheEdgeAreRead() {
        let window = FeedWindow(floor: morning)
        #expect(window.admits(arrival: morning))
        #expect(!window.admits(arrival: morning.addingTimeInterval(-0.001)))
    }
}

import Foundation
import Testing

@testable import StreetwCore

@Suite("Taste order")
struct TasteOrderTests {
    private struct Item: Equatable {
        var title: String
        var isAvailable = true
    }

    private func order(_ items: [Item], wardrobe: [Garment]) -> [String] {
        TasteOrder.order(
            items,
            wardrobe: wardrobe,
            garment: { Garment(id: $0.title, title: $0.title) },
            isAvailable: \.isAvailable
        ).map(\.title)
    }

    private let trousers = Garment(id: "owned:trousers", title: "Cargo Pant")

    @Test("Nothing owned leaves the server's order alone")
    func emptyWardrobeIsUntouched() {
        let items = [Item(title: "Denim Jean"), Item(title: "Boxy Tee"), Item(title: "Wool Coat")]
        #expect(order(items, wardrobe: []) == ["Denim Jean", "Boxy Tee", "Wool Coat"])
    }

    /// A second pair of trousers has nothing to pair with when trousers are all you own, so
    /// the tee you could wear with them rises above it — and the trousers stay on the page.
    @Test("What goes with what you own rises, and nothing is hidden")
    func pairingRises() {
        let items = [Item(title: "Denim Jean"), Item(title: "Boxy Tee")]
        #expect(order(items, wardrobe: [trousers]) == ["Boxy Tee", "Denim Jean"])
    }

    @Test("Sold out still goes last, whatever it goes with")
    func soldOutLast() {
        let items = [Item(title: "Boxy Tee", isAvailable: false), Item(title: "Denim Jean")]
        #expect(order(items, wardrobe: [trousers]) == ["Denim Jean", "Boxy Tee"])
    }

    /// Two tops that go equally well with the same trousers are not a statement about
    /// anybody: the server's order — the words — decides between them.
    @Test("Near-equals keep the server's order")
    func tiesKeepServerOrder() {
        let items = [Item(title: "Boxy Tee"), Item(title: "Pocket Tee"), Item(title: "Heavy Tee")]
        #expect(order(items, wardrobe: [trousers]) == ["Boxy Tee", "Pocket Tee", "Heavy Tee"])
    }
}

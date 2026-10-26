import Foundation
import Testing

@testable import StreetwCore

@Suite("Searching your shops")
struct ShopSearchTests {
    private static let day: TimeInterval = 86_400

    private func listing(
        _ id: String,
        _ title: String,
        type: String? = nil,
        brand: String = "Velmar Studio",
        tags: [String] = [],
        colourways: [String] = [],
        measured: [String] = [],
        price: Double? = nil,
        daysAgo: Double = 1,
        available: Bool = true,
        shown: Bool = true,
        relevance: Double = 0
    ) -> ShopListing {
        ShopListing(
            id: id,
            brandKey: brand,
            brandName: brand,
            title: title,
            productType: type,
            tags: tags,
            colourways: colourways,
            measuredColours: measured,
            price: price,
            publishedAt: Date(timeIntervalSince1970: 1_800_000_000 - daysAgo * Self.day),
            isAvailable: available,
            isShown: shown,
            relevance: relevance
        )
    }

    private var store: ShopIndex {
        ShopIndex([
            listing("suit-jacket", "Wool Suit Jacket — Black", type: "Blazers", price: 380),
            listing("trouser", "Double Pleat Trouser — Black", type: "Pants", price: 168),
            listing("tee", "Heavy Boxy Tee — Off White", type: "T-Shirt", price: 65),
            listing("suit", "Black Suit", type: "Suits", price: 520, daysAgo: 3),
            listing("sleeve", "Short Sleeve Shirt — Navy", type: "Shirts", price: 90),
            listing("shorts", "Nylon Shorts — Black", type: "Shorts", price: 70),
            listing("arrow", "Arrow Hoodie", type: "Hoodies", brand: "Off-White", price: 450),
            listing("loafer", "Penny Loafer — Black Calf", type: "Footwear", price: 310)
        ])
    }

    private func search(
        _ text: String,
        in index: ShopIndex? = nil,
        hasSizes: Bool = true,
        fits: (ShopListing) -> Bool = { _ in true }
    ) -> ShopSearch.Result {
        ShopSearch.run(ShopQuery.parse(text), in: index ?? store, hasSizes: hasSizes, fits: fits)
    }

    @Test("Everything asked for comes first; what carries part of it follows")
    func exactThenPartial() {
        let result = search("black suit under €400")
        #expect(result.outcome == .found)
        #expect(result.exact.map(\.id) == ["suit-jacket"])
        // Black, under 400, not a suit: shown below and labelled with what it matched.
        #expect(result.partial.map(\.id).contains("trouser"))
        #expect(result.partial.first { $0.id == "trouser" }?.matched == ["black"])
        // Over the bound, so nowhere at all — the price is a constraint, not a preference.
        #expect(!(result.exact + result.partial).contains { $0.id == "suit" })
    }

    /// Whole tokens, never substrings: "shorts" contains "short", and the contains-check
    /// version of this answered a short-sleeve shirt with a pair of shorts.
    @Test("Shorts are not a short sleeve, either way round")
    func wholeTokens() {
        #expect(search("shorts").exact.map(\.id) == ["shorts"])
        #expect(search("short sleeve").exact.map(\.id) == ["sleeve"])
    }

    /// "for a wedding" is in no product title anywhere, and requiring it would turn a
    /// perfectly good request for a suit into an empty page.
    @Test("A word nothing in the store carries is set aside and named")
    func unknownWordsAreSetAside() {
        let result = search("black suit for a wedding")
        #expect(result.unknown == ["wedding"])
        #expect(result.exact.map(\.id) == ["suit-jacket", "suit"])
    }

    @Test("When no word is anywhere, the answer says so")
    func nothingKnown() {
        #expect(search("tuxedo cummerbund").outcome == .notInYourShops(["tuxedo", "cummerbund"]))
        #expect(search("something nice").outcome == .nothingToSearch)
    }

    @Test("A price bound that empties the list says by how much")
    func priceEmptiesIt() {
        let result = search("suit under 100")
        #expect(result.exact.isEmpty)
        #expect(result.outcome == .outsidePrice(count: 2, cheapest: 380))
    }

    @Test("A gender filter that hides every match says it is the filter")
    func filterEmptiesIt() {
        let index = ShopIndex([listing("dress", "Slip Dress", type: "Dresses", shown: false)])
        #expect(search("dress", in: index).outcome == .hiddenByFilter(1))
    }

    /// Three different fixes, so three different answers.
    @Test("No sizes, no match in your size, and in your size are different answers")
    func sizeOutcomes() {
        #expect(search("black in my size", hasSizes: false).outcome == .noSizes)
        let none = search("black trouser in my size", fits: { _ in false })
        #expect(none.outcome == .noneInYourSize(1))
        let yours = search("black in my size", fits: { $0.id == "loafer" })
        #expect(yours.exact.map(\.id) == ["loafer"])
    }

    @Test("A \"no …\" that rules out everything names the word")
    func exclusionEmptiesIt() {
        #expect(search("jacket no wool").outcome == .allRuledOut(["wool"]))
        #expect(!search("black no wool").exact.contains { $0.id == "suit-jacket" })
    }

    /// A colour is a property of the garment, never of the shop — "white" must not answer
    /// with everything Off-White makes.
    @Test("A colour word does not match a shop's name")
    func colourIgnoresTheBrand() {
        #expect(search("white").exact.map(\.id) == ["tee"])
        // A shop's name is still a word to find.
        #expect(search("off-white hoodie").exact.map(\.id) == ["arrow"])
    }

    @Test("A measured colour and a colourway count as the colour")
    func measuredColour() {
        let index = ShopIndex([
            listing("measured", "Nocturne Crewneck", type: "Sweatshirts", measured: ["Black"]),
            listing("colourway", "Club Crewneck", type: "Sweatshirts", colourways: ["Vintage Black", "Ash"]),
            listing("cream", "Logo Crewneck", type: "Sweatshirts", colourways: ["Cream"])
        ])
        #expect(Set(search("black sweatshirt", in: index).exact.map(\.id)) == ["measured", "colourway"])
        #expect(search("ecru sweatshirt", in: index).exact.map(\.id) == ["cream"])
    }

    @Test("A category word finds what the classifier placed there")
    func categoryFindsBySlot() {
        #expect(search("black shoes").exact.map(\.id) == ["loafer"])
    }

    /// A sold-out size is a restock tomorrow, so it is shown — after what can be bought.
    @Test("Sold out goes last, and is not hidden")
    func soldOutLast() {
        let index = ShopIndex([
            listing("gone", "Black Hoodie", type: "Hoodies", daysAgo: 0, available: false),
            listing("here", "Black Hoodie", type: "Hoodies", daysAgo: 5)
        ])
        #expect(search("black hoodie", in: index).exact.map(\.id) == ["here", "gone"])
    }

    @Test("Cheaper is the cheaper half, said as a number")
    func cheaperHalves() {
        let result = search("black cheaper")
        #expect(result.cheaperThan == 310)
        #expect(result.exact.map(\.id) == ["shorts", "trouser", "loafer"])
    }

    @Test("More formal reorders and never hides")
    func formalReorders() {
        let plain = search("black")
        let dressy = search("black formal")
        #expect(Set(plain.exact.map(\.id)) == Set(dressy.exact.map(\.id)))
        #expect(dressy.exact.first?.id == "suit-jacket" || dressy.exact.first?.id == "suit")
        #expect(dressy.exact.last?.id == "shorts")
    }

    @Test("A query of constraints alone is a browse")
    func constraintsOnly() {
        #expect(Set(search("under 100").exact.map(\.id)) == ["tee", "sleeve", "shorts"])
    }

    /// The same page typed twice is the same page twice — ties break on recency, then id.
    @Test("Results are a total order")
    func deterministic() {
        let index = ShopIndex([
            listing("b", "Black Cap", type: "Hats", daysAgo: 2),
            listing("a", "Black Cap", type: "Hats", daysAgo: 2),
            listing("c", "Black Cap", type: "Hats", daysAgo: 1)
        ])
        #expect(search("black cap", in: index).exact.map(\.id) == ["c", "a", "b"])
    }

    @Test("A title match outranks a tag")
    func fieldsWeigh() {
        let index = ShopIndex([
            listing("tagged", "Nocturne Crewneck", type: "Sweatshirts", tags: ["fleece"], daysAgo: 0),
            listing("named", "Polar Fleece", type: "Sweatshirts", daysAgo: 4)
        ])
        #expect(search("fleece", in: index).exact.map(\.id) == ["named", "tagged"])
    }

    // MARK: - The server's half

    /// The server hands over the best few hundred candidates out of a catalogue it cannot
    /// load, so a rare word may be in none of them. What exists is the database's answer, and
    /// it must decide what is required exactly as the phone's whole-store vocabulary does.
    @Test("What exists is the caller's to say when the index holds part of the store")
    func knowsOverridesThePool() {
        let pool = ShopIndex([listing("tee", "Heavy Boxy Tee — Black", type: "T-Shirt")])
        let query = ShopQuery.parse("black tee zebra")
        // Read off the pool, "zebra" is nowhere and is set aside.
        let local = ShopSearch.run(query, in: pool, hasSizes: true, fits: { _ in true })
        #expect(local.unknown == ["zebra"])
        #expect(local.outcome == .found)
        // The catalogue says it exists: it is required, nothing in the pool has all three,
        // and the tee is the closest — the answer the phone gives holding the whole store.
        let served = ShopSearch.run(query, in: pool, hasSizes: true, fits: { _ in true }, knows: { _ in true })
        #expect(served.unknown.isEmpty)
        #expect(served.outcome == .closest)
        #expect(served.partial.first?.matched == ["black", "tee"])
    }

    /// The index's rank only settles what the grammar calls equal — never outranks it.
    @Test("Full-text relevance breaks a tie after the score, before recency")
    func relevanceBreaksTies() {
        let index = ShopIndex([
            listing("newer", "Black Cap", type: "Hats", daysAgo: 0, relevance: 0.1),
            listing("closer", "Black Cap", type: "Hats", daysAgo: 9, relevance: 0.6),
            listing("tagged", "Logo Cap", type: "Hats", tags: ["black"], daysAgo: 0, relevance: 0.9)
        ])
        #expect(search("black cap", in: index).exact.map(\.id) == ["closer", "newer", "tagged"])
    }

    @Test("An outcome survives the wire")
    func outcomeRoundTrips() throws {
        let outcomes: [ShopSearch.Outcome] = [
            .found, .closest, .nothingToSearch, .notInYourShops(["tuxedo"]), .allRuledOut(["wool"]),
            .hiddenByFilter(3), .outsidePrice(count: 2, cheapest: 380), .outsidePrice(count: 1, cheapest: nil),
            .noSizes, .noneInYourSize(4)
        ]
        for outcome in outcomes {
            let data = try APICoding.encoder.encode(outcome)
            #expect(try APICoding.decoder.decode(ShopSearch.Outcome.self, from: data) == outcome)
        }
    }

    /// The server finds a category word through this list before `classify` decides it, so
    /// anything the classifier places in a slot must carry one of its words.
    @Test("A slot's vocabulary covers everything the classifier places there", arguments: [
        ("Penny Loafer — Black Calf", "Footwear", GarmentSlot.footwear),
        ("Dunk Low Retro", "Sneakers", .footwear),
        ("Running Shoe 2", nil, .footwear),
        ("P3 Hood", nil, .top),
        ("Heavy T-Shirt", nil, .top),
        ("Nylon Tracksuit", nil, .top),
        ("Shirt Jacket", nil, .outerwear),
        ("Logo Beanies", nil, .headwear),
        ("Cargo Pants", "Bottoms", .bottom)
    ] as [(String, String?, GarmentSlot)])
    func vocabularyCoversTheClassifier(title: String, type: String?, slot: GarmentSlot) {
        #expect(GarmentClassifier.classify(title: title, productType: type) == slot)
        let tokens = Set(ShopText.tokens([title, type ?? ""].joined(separator: " ")))
        #expect(!tokens.isDisjoint(with: GarmentClassifier.vocabulary(for: slot)))
    }
}

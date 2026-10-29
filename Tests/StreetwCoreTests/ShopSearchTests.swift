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

    // MARK: - One list over every shop (Phase 5)

    @Test("A followed shop's lift decides between equal matches, and never more than the words")
    func followedLift() {
        func store(lift: Double) -> ShopIndex {
            ShopIndex([
                // Every one a title match for "hoodie"; the newest first by default.
                ShopListing(id: "theirs", brandKey: "noah", brandName: "Noah", title: "Core Hoodie", publishedAt: Date(timeIntervalSince1970: 3)),
                ShopListing(id: "mine", brandKey: "kith", brandName: "Kith", title: "Williams Hoodie", publishedAt: Date(timeIntervalSince1970: 2), boost: lift),
                // Only a tag says it — weaker than any title, unless lifted far enough.
                ShopListing(id: "tagged", brandKey: "kith", brandName: "Kith", title: "Fleece Crew", tags: ["hoodie"], publishedAt: Date(timeIntervalSince1970: 1), boost: lift),
                // Sold out stays last whatever the lift.
                ShopListing(id: "gone", brandKey: "kith", brandName: "Kith", title: "Box Hoodie", isAvailable: false, boost: lift)
            ])
        }
        let none = ShopSearch.run(ShopQuery.parse("hoodie"), in: store(lift: 0), hasSizes: false, fits: { _ in true })
        #expect(none.exact.map(\.id) == ["theirs", "mine", "tagged", "gone"])
        let standard = ShopSearch.run(ShopQuery.parse("hoodie"), in: store(lift: 1), hasSizes: false, fits: { _ in true })
        #expect(standard.exact.map(\.id) == ["mine", "theirs", "tagged", "gone"])
        let more = ShopSearch.run(ShopQuery.parse("hoodie"), in: store(lift: 3), hasSizes: false, fits: { _ in true })
        #expect(more.exact.map(\.id) == ["mine", "tagged", "theirs", "gone"])
    }

    @Test("Close by meaning is a result without the words, and says so")
    func meaningMatches() {
        let index = ShopIndex([
            listing("jacket", "Cotton Chore Jacket", type: "Outerwear", price: 300),
            listing("blazer", "Linen Blazer — Sand", type: "Tailoring", price: 450),
            listing("wool", "Wool Blazer", type: "Tailoring", tags: ["wool"], price: 600),
            listing("tee", "Heavy Tee", type: "T-Shirt", price: 60)
        ])
        let query = ShopQuery.parse("summer jacket")
        // Without vectors, the words alone — "summer" is in no product, so it is set aside.
        let words = ShopSearch.run(query, in: index, hasSizes: false, fits: { _ in true })
        #expect(words.exact.map(\.id) == ["jacket"])
        #expect(words.unknown == ["summer"])

        let near = ShopSearch.run(query, in: index, hasSizes: false, fits: { _ in true }, meaning: ["blazer", "jacket"])
        // The word match first, then the one found by meaning, labelled.
        #expect(near.exact.map(\.id) == ["jacket", "blazer"])
        #expect(near.exact.map(\.byMeaning) == [false, true])
        #expect(near.exact.map(\.isExact) == [true, false])
        #expect(near.outcome == .found)
    }

    @Test("Meaning only joins a search the words found little for")
    func meaningOnlyWhereWordsFoundLittle() {
        // A dozen jackets by their words, and a blazer only the embedding found.
        let jackets = (0..<ShopSearch.partialBelow).map { listing("j\($0)", "Chore Jacket \($0)", type: "Outerwear") }
        let index = ShopIndex(jackets + [listing("blazer", "Linen Blazer", type: "Tailoring")])
        let full = ShopSearch.run(ShopQuery.parse("jacket"), in: index, hasSizes: false, fits: { _ in true }, meaning: ["blazer"])
        #expect(!full.exact.contains { $0.id == "blazer" })
        #expect(full.exact.allSatisfy { !$0.byMeaning })
        // One jacket fewer and the words found little: the blazer is a result again.
        let thin = ShopIndex(Array(jackets.dropFirst()) + [listing("blazer", "Linen Blazer", type: "Tailoring")])
        let few = ShopSearch.run(ShopQuery.parse("jacket"), in: thin, hasSizes: false, fits: { _ in true }, meaning: ["blazer"])
        #expect(few.exact.last?.id == "blazer")
        #expect(few.exact.last?.byMeaning == true)
    }

    @Test("A meaning match still meets every constraint the words set")
    func meaningMeetsTheConstraints() {
        let index = ShopIndex([
            listing("blazer", "Linen Blazer", type: "Tailoring", price: 450),
            listing("wool", "Wool Blazer", type: "Tailoring", tags: ["wool"], price: 300),
            listing("hidden", "Seersucker Jacket", type: "Outerwear", price: 200, shown: false),
            listing("dear", "Silk Jacket", type: "Outerwear", price: 900)
        ])
        let near: Set<String> = ["blazer", "wool", "hidden", "dear"]
        func run(_ text: String, fits: @escaping (ShopListing) -> Bool = { _ in true }) -> [String] {
            ShopSearch.run(ShopQuery.parse(text), in: index, hasSizes: true, fits: fits, meaning: near).exact.map(\.id)
        }
        // "no wool" rules the wool blazer out, however close it is.
        #expect(run("smart wedding no wool").contains("wool") == false)
        // The gender filter, the price and "in my size" all still apply.
        #expect(run("wedding").contains("hidden") == false)
        #expect(run("wedding under 500") == ["blazer", "wool"])
        #expect(run("wedding in my size", fits: { $0.id == "blazer" }) == ["blazer"])
    }

    @Test("Every word unknown: what is close by meaning answers, or the words are said to be missing")
    func meaningWhenNoWordExists() {
        let index = ShopIndex([
            listing("blazer", "Linen Blazer", type: "Tailoring", price: 450),
            listing("tee", "Heavy Tee", type: "T-Shirt", price: 60)
        ])
        let query = ShopQuery.parse("wedding")
        let empty = ShopSearch.run(query, in: index, hasSizes: false, fits: { _ in true })
        #expect(empty.outcome == .notInYourShops(["wedding"]))
        let near = ShopSearch.run(query, in: index, hasSizes: false, fits: { _ in true }, meaning: ["blazer"])
        #expect(near.exact.map(\.id) == ["blazer"])
        #expect(near.exact.first?.byMeaning == true)
        // The word is still in no product, and is still said to be.
        #expect(near.unknown == ["wedding"])
        #expect(near.outcome == .found)
    }

    @Test("A wire answer from an older server, with no lift and no meaning, still decodes")
    func olderAnswersDecode() throws {
        let old = #"{"scope":"all","exact":[],"partial":[],"unknown":[],"outcome":{"found":{}},"total":0,"isCapped":false,"searched":3,"shops":2}"#
        let response = try APICoding.decoder.decode(ProductSearchResponse.self, from: Data(old.utf8))
        #expect(response.boost == nil)
        #expect(response.meaningSearched == nil)
        // A lift a newer server names is read as the standard one, not a failure.
        let newer = #"{"scope":"all","exact":[],"partial":[],"unknown":[],"outcome":{"found":{}},"total":0,"isCapped":false,"searched":3,"shops":2,"boost":"enormous"}"#
        #expect(try APICoding.decoder.decode(ProductSearchResponse.self, from: Data(newer.utf8)).boost == .standard)
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

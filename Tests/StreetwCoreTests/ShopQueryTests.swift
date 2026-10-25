import Foundation
import Testing

@testable import StreetwCore

@Suite("Shop's field, read as a grammar")
struct ShopQueryTests {
    /// The sentence on the field's own placeholder, and the reading the owner signed off.
    @Test("The placeholder reads as words and a ceiling")
    func readsThePlaceholder() {
        let query = ShopQuery.parse("A black suit under €400")
        #expect(query.terms.map(\.word) == ["black", "suit"])
        #expect(query.ceiling == 400)
        #expect(query.floor == nil)
        #expect(query.reading == ["black", "suit", "under 400"])
    }

    /// Each shop is compared in its own currency and nothing is converted, so printing the
    /// euro sign back would claim a conversion that never happened.
    @Test("The reading never prints a currency")
    func readingDropsTheCurrency() {
        #expect(ShopQuery.parse("hoodie under $80").reading == ["hoodie", "under 80"])
        #expect(ShopQuery.parse("hoodie below 80 eur").reading == ["hoodie", "under 80"])
    }

    @Test("Every shape of a price bound", arguments: [
        ("below 100", nil, 100.0),
        ("under 400 euros", nil, 400.0),
        ("up to £250", nil, 250.0),
        ("no more than 200", nil, 200.0),
        ("over 50", 50.0, nil),
        ("at least 120", 120.0, nil),
        ("between 100 and 200", 100.0, 200.0),
        ("100-200", 100.0, 200.0),
        ("from 100 to 200", 100.0, 200.0),
        ("jacket €1,200", nil, 1200.0),
        ("jacket 1.200€", nil, 1200.0),
        ("under 1.5k", nil, 1500.0),
        ("under 149,99", nil, 149.99)
    ] as [(String, Double?, Double?)])
    func readsPrices(text: String, floor: Double?, ceiling: Double?) {
        let query = ShopQuery.parse(text)
        #expect(query.floor == floor)
        #expect(query.ceiling == ceiling)
    }

    /// "990" and "1017" are names. Reading a bare number as a budget would answer "990
    /// sneakers" with every sneaker under 990.
    @Test("A bare number is a word, not a price")
    func bareNumberIsAName() {
        let query = ShopQuery.parse("990 sneakers")
        #expect(query.ceiling == nil)
        #expect(query.terms.map(\.word) == ["990", "sneakers"])
    }

    /// "no more than" starts with "no", and must not rule out a garment called "more".
    @Test("A price cue that starts with a negation is still a price")
    func noMoreThanIsAPrice() {
        let query = ShopQuery.parse("no more than 200")
        #expect(query.ceiling == 200)
        #expect(query.excluded.isEmpty)
    }

    @Test("\"in my size\" is a flag, not three words")
    func readsInMySize() {
        let query = ShopQuery.parse("a black hoodie in my size")
        #expect(query.inMySize)
        #expect(query.terms.map(\.word) == ["black", "hoodie"])
        #expect(query.reading.last == "in your size")
        #expect(ShopQuery.parse("something that fits me").inMySize)
    }

    @Test("A negation rules out the next word that means something")
    func readsExclusions() {
        let query = ShopQuery.parse("black jacket, no wool")
        #expect(query.terms.map(\.word) == ["black", "jacket"])
        #expect(query.excluded.map(\.word) == ["wool"])
        #expect(query.reading == ["black", "jacket", "not wool"])

        // "big" is how much, not what.
        #expect(ShopQuery.parse("tee without big logos").excluded.map(\.word) == ["logos"])
    }

    /// The same precedence `StyleStatement` gives a dislike: the ruling out is the later,
    /// sharper statement.
    @Test("A word both wanted and ruled out is ruled out")
    func exclusionWins() {
        let query = ShopQuery.parse("black hoodie, not black")
        #expect(query.terms.map(\.word) == ["hoodie"])
        #expect(query.excluded.map(\.word) == ["black"])
    }

    /// Whole tokens, never substrings — and folding "shorts" to "short" would be the
    /// substring bug by another route: "short sleeve" is a top.
    @Test("Shorts are not a short sleeve")
    func shortsKeepTheirNumber() {
        let shorts = ShopQuery.parse("shorts").terms.first
        #expect(shorts?.forms == ["shorts"])
        let sleeve = ShopQuery.parse("short sleeve shirt").terms.map(\.word)
        #expect(sleeve == ["short-sleeve", "shirt"])
    }

    @Test("A word's other number and true synonyms count")
    func formsAndSynonyms() {
        let jacket = ShopQuery.parse("jackets").terms.first
        #expect(jacket?.forms.contains("jacket") == true)
        let trousers = ShopQuery.parse("trousers").terms.first
        #expect(trousers?.forms.isSuperset(of: ["trouser", "pants", "pant"]) == true)
        let tee = ShopQuery.parse("t-shirt").terms
        #expect(tee.map(\.word) == ["t-shirt"])
        #expect(tee.first?.forms.isSuperset(of: ["tshirt", "tee"]) == true)
        // A coat query finds an overcoat; an overcoat query does not find every coat.
        #expect(ShopQuery.parse("coat").terms.first?.forms.contains("overcoat") == true)
        #expect(ShopQuery.parse("overcoat").terms.first?.forms.contains("coat") == false)
    }

    @Test("A colour is canonical, with its other spellings")
    func readsColours() {
        let grey = ShopQuery.parse("gray hoodie").terms.first
        #expect(grey?.colour == "Grey")
        #expect(grey?.forms.isSuperset(of: ["gray", "grey"]) == true)
        #expect(ShopQuery.parse("ecru knit").terms.first?.colour == "Cream")
    }

    @Test("A category word is answered by the slot classifier")
    func readsCategories() {
        #expect(ShopQuery.parse("shoes").terms.first?.slot == .footwear)
        #expect(ShopQuery.parse("outerwear").terms.first?.slot == .outerwear)
        #expect(ShopQuery.parse("loafers").terms.first?.slot == nil)
    }

    /// The same flags the chips set, so typing it and tapping it cannot disagree.
    @Test("Cheap and formal are leanings, not words")
    func readsLeanings() {
        let query = ShopQuery.parse("cheap formal shoes")
        #expect(query.cheaper)
        #expect(query.formal)
        #expect(query.terms.map(\.word) == ["shoes"])
        #expect(query.reading == ["shoes", "more formal", "cheaper"])
    }

    @Test("Chips fold into the same query")
    func chipsRefine() {
        let typed = ShopQuery.parse("cheap black hoodie")
        let tapped = ShopQuery.parse("black hoodie").refined(cheaper: true, formal: false, inMySize: false)
        #expect(typed.reading == tapped.reading)
        #expect(tapped.refined(cheaper: false, formal: false, inMySize: true).inMySize)
    }

    /// The only size this can read is the reader's own, on each garment's own ladder. A
    /// named size is said back as ignored rather than searched for as the word "10".
    @Test("A named size is set aside and said")
    func namedSizeIsIgnored() {
        let query = ShopQuery.parse("size 10 boots")
        #expect(query.ignored == ["size 10"])
        #expect(query.terms.map(\.word) == ["boots"])
        #expect(ShopQuery.parse("hoodie in size m").ignored == ["size M"])
    }

    @Test("A sentence of filler asks for nothing")
    func fillerIsEmpty() {
        #expect(ShopQuery.parse("something nice please").isEmpty)
        #expect(ShopQuery.parse("").isEmpty)
        // A cue with no amount after it is only a word, and a meaningless one.
        #expect(ShopQuery.parse("under").isEmpty)
    }

    @Test("Accents fold, so a shop's own spelling is found")
    func accentsFold() {
        #expect(ShopQuery.parse("Stüssy").terms.first?.word == "stussy")
        #expect(ShopText.tokens("STÜSSY Basic Tee").contains("stussy"))
    }

    @Test("A typo'd range is read the right way round")
    func swappedRange() {
        let query = ShopQuery.parse("over 300 under 100")
        #expect(query.floor == 100)
        #expect(query.ceiling == 300)
    }
}

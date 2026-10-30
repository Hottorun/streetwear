import Foundation
import Testing

@testable import StreetwCore

/// The one rule a filtered follow is decided by, on the phone and in `Notifier` alike. The app
/// has no test target, and both ends call `FollowFilter.Matcher.admits` — so this is where the
/// two are held to one answer, including on the rows that must always pass.
@Suite("Follow filters")
struct FollowFilterTests {
    private func item(_ title: String, type: String? = nil, tags: [String] = [], price: Double? = nil) -> FollowFilter.Item {
        FollowFilter.Item(title: title, productType: type, tags: tags, price: price)
    }

    private let jeans = FollowFilter(categories: ["jeans"])

    @Test("No filter, and an empty one, admit everything")
    func emptyAdmitsAll() {
        for kind in UpdateKind.allCases {
            #expect(FollowFilter.Matcher(nil).admits(kind, item("Logo Tee")))
            #expect(FollowFilter().admits(kind, item("Logo Tee")))
            #expect(FollowFilter(categories: [" "], words: "  ").admits(kind, item("Logo Tee")))
        }
        #expect(FollowFilter(words: "in my size").isEmpty)
        #expect(FollowFilter(categories: [], words: " ").normalized == nil)
    }

    @Test("A chip admits its own kind and turns away other placed garments")
    func chipAdmitsItsKind() {
        #expect(jeans.admits(.product, item("Straight Leg Jeans")))
        #expect(jeans.admits(.restock, item("Baggy Jean", type: "Denim")))
        #expect(jeans.admits(.priceDrop, item("501 Original", type: "Jeans")))
        #expect(!jeans.admits(.product, item("Logo Tee")))
        #expect(!jeans.admits(.restock, item("Nylon Track Jacket")))
        // A jean jacket is a jacket: the chip asks the shelf as well as the word.
        #expect(!jeans.admits(.product, item("Washed Jean Jacket")))
    }

    @Test("Several chips admit any of them")
    func chipsAreAlternatives() {
        let filter = FollowFilter(categories: ["jeans", "bags"])
        #expect(filter.admits(.product, item("Loose Jeans")))
        #expect(filter.admits(.product, item("Canvas Tote Bag")))
        #expect(filter.admits(.product, item("Nylon Backpack")))
        #expect(!filter.admits(.product, item("Wool Beanie")))
    }

    @Test("A slot chip admits what the classifier put on that shelf")
    func slotChip() {
        let footwear = FollowFilter(categories: ["footwear"])
        #expect(footwear.admits(.product, item("Air Max 1", type: "Sneakers")))
        #expect(footwear.admits(.product, item("Chelsea Boot")))
        #expect(!footwear.admits(.product, item("Chelsea Hoodie")))
    }

    /// The rule the whole project runs on. YoungLA files womenswear as "For Her" and names it
    /// W2156; a follow narrowed to jeans must not hide that drop because its title is a code.
    @Test("A garment nothing can place always passes the chips and the words")
    func unknownAlwaysPasses() {
        #expect(jeans.admits(.product, item("W2156")))
        #expect(FollowFilter(words: "black jeans").admits(.product, item("W2156", type: "For Her")))
    }

    @Test("A brand-wide sale, a lock, a post and a page change always pass")
    func brandLevelKindsPass() {
        let narrow = FollowFilter(categories: ["bags"], words: "no kids under 50")
        for kind in [UpdateKind.sale, .dropLock, .post, .pageChange] {
            #expect(narrow.admits(kind, item("Kids Sale — 40% off everything")))
        }
    }

    @Test("A release passes the chips, and only an exclusion reaches it")
    func releaseOnlyHearsExclusions() {
        // "Denim Tears FW26" reads as bottoms to the classifier and is a whole season.
        #expect(FollowFilter(categories: ["bags"]).admits(.collection, item("Denim Tears FW26")))
        #expect(FollowFilter(words: "jackets").admits(.collection, item("Alpine Capsule")))
        #expect(!FollowFilter(words: "no kids").admits(.collection, item("Kith Kids Fall 2026")))
    }

    @Test("Own words are Shop's grammar: every word carried, synonyms and numbers counted")
    func wordsAreTheGrammar() {
        let black = FollowFilter(words: "black jeans")
        #expect(black.admits(.product, item("Black Selvedge Jeans")))
        #expect(!black.admits(.product, item("Indigo Selvedge Jeans")))
        #expect(!black.admits(.product, item("Black Logo Tee")))
        // "tees" finds a T-shirt — the synonym, and the compound across the hyphen.
        #expect(FollowFilter(words: "tees").admits(.product, item("Box Logo T-Shirt")))
        // Whole tokens: "shorts" must not admit a short-sleeve shirt.
        #expect(!FollowFilter(words: "shorts").admits(.product, item("Short Sleeve Shirt")))
    }

    @Test("An exclusion hides what carries the word, placed or not")
    func exclusionHides() {
        let noKids = FollowFilter(words: "no kids")
        #expect(!noKids.admits(.product, item("Kids Logo Hoodie")))
        #expect(!noKids.admits(.restock, item("Mystery Box", tags: ["kids"])))
        #expect(noKids.admits(.product, item("Logo Hoodie")))
        #expect(noKids.admits(.product, item("W2156")))
    }

    @Test("A price bound hides only a row that has a price outside it")
    func priceBound() {
        let cheap = FollowFilter(words: "under 100")
        #expect(cheap.admits(.product, item("Logo Tee", price: 60)))
        #expect(!cheap.admits(.product, item("Wool Coat", price: 480)))
        #expect(cheap.admits(.product, item("Wool Coat", price: nil)))
    }

    @Test("What a follow cannot act on is read back as unused, never applied")
    func unusedWords() {
        let filter = FollowFilter(words: "cheap jeans in my size")
        #expect(filter.reading == ["jeans"])
        #expect(filter.unused.contains("in your size"))
        #expect(filter.unused.contains("cheaper"))
        // Not applied: a pair of jeans at any price still passes.
        #expect(filter.admits(.product, item("Loose Jeans", price: 400)))
    }

    @Test("The reading prints the chips by name, then the words")
    func reading() {
        let filter = FollowFilter(categories: ["tees", "bags"], words: "no kids")
        #expect(filter.reading == ["t-shirts", "bags", "not kids"])
    }

    @Test("Normalising tidies the chips and stores All as nothing")
    func normalising() {
        let filter = FollowFilter(categories: ["Jeans", "jeans ", "", "BAGS"], words: "  no kids  ")
        #expect(filter.normalized == FollowFilter(categories: ["jeans", "bags"], words: "no kids"))
        let long = FollowFilter(categories: (0..<40).map { "word\($0)" }, words: String(repeating: "a ", count: 500))
        #expect(long.normalized?.categories.count == FollowFilter.maxCategories)
        #expect((long.normalized?.words?.count ?? 0) <= FollowFilter.maxWords)
    }

    @Test("A chip this build does not offer still means its word")
    func unknownChipIsAWord() {
        let filter = FollowFilter(categories: ["loafers"])
        #expect(filter.admits(.product, item("Penny Loafers")))
        #expect(!filter.admits(.product, item("Running Sneakers")))
    }

    @Test("Each product counts once, as the finest category it belongs to")
    func tally() {
        let items = [
            item("Loose Jeans"), item("Straight Jeans"), item("Carpenter Jean", type: "Denim"),
            item("Logo Tee"), item("Box T-Shirt"),
            item("Canvas Tote"),
            item("Work Trousers"), item("Pleated Trousers"),
            item("W2156"), item("Gift Card")
        ]
        let top = FollowCategory.biggest(in: items)
        #expect(top.map(\.category) == ["jeans", "trousers", "tees"])
        #expect(top.map(\.count) == [3, 2, 2])
        #expect(top.first?.label == "Jeans")
        // A garment on a shelf with no finer kind counts for the shelf.
        #expect(FollowCategory.of(item("Rugby Polo")) == FollowCategory.named("tops"))
        #expect(FollowCategory.of(item("W2156")) == nil)
    }

    /// The other direction of the tally: a chip offered because it counted N products admits
    /// exactly those N, or the dialog would offer a chip that lets through something else.
    @Test("A chip admits what the tally counted for it")
    func chipMatchesTally() {
        let items = [
            item("Loose Jeans"), item("Logo Tee"), item("Washed Jean Jacket"),
            item("Canvas Tote"), item("Leather Belt"), item("Chelsea Boot"), item("Rugby Polo")
        ]
        for category in FollowCategory.all {
            let filter = FollowFilter.Matcher(FollowFilter(categories: [category.id]))
            for item in items where FollowCategory.of(item) == category {
                #expect(filter.admits(.product, item), "\(category.id) should admit \(item.title)")
            }
        }
    }

    // MARK: - The wire

    @Test("A filter decodes leniently and travels only when there is one")
    func wire() throws {
        let partial = try APICoding.decoder.decode(FollowFilter.self, from: Data(#"{"words":"bags"}"#.utf8))
        #expect(partial == FollowFilter(words: "bags"))
        let wrong = try APICoding.decoder.decode(FollowFilter.self, from: Data(#"{"categories":7,"words":["x"]}"#.utf8))
        #expect(wrong == FollowFilter())

        // 1.3's body and 1.3's reading of the new one.
        let old = try APICoding.encoder.encode(UpdateFollow(mode: .salesOnly))
        #expect(String(decoding: old, as: UTF8.self) == #"{"mode":"sales"}"#)
        let new = try APICoding.encoder.encode(UpdateFollow(mode: .everything, filter: FollowFilter(categories: ["jeans"])))
        let decoded = try APICoding.decoder.decode(UpdateFollow.self, from: new)
        #expect(decoded.filter == FollowFilter(categories: ["jeans"]))
        #expect(try APICoding.decoder.decode(UpdateFollow.self, from: old).filter == nil)
    }

    @Test("A brand from a server that predates filters carries none")
    func brandWithoutFilter() throws {
        let json = Data(#"{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","name":"Kith","slug":"kith.com","lockedForDrop":false,"sources":[],"followMode":"everything"}"#.utf8)
        #expect(try APICoding.decoder.decode(BrandDTO.self, from: json).followFilter == nil)
        let filtered = Data(#"{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","name":"Kith","slug":"kith.com","lockedForDrop":false,"sources":[],"followMode":"everything","followFilter":{"categories":["jeans"]}}"#.utf8)
        #expect(try APICoding.decoder.decode(BrandDTO.self, from: filtered).followFilter == FollowFilter(categories: ["jeans"]))
    }
}

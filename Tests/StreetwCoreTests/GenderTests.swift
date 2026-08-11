import Foundation
import Testing

@testable import StreetwCore

@Suite("Gender classification")
struct GenderClassifierTests {
    /// The trap that makes substring matching unusable: "womens" contains "mens", so a
    /// naive `contains` classifies every women's product as menswear — precisely
    /// backwards, and precisely the complaint this feature exists to fix.
    @Test("A women's product is never read as men's")
    func womensIsNotMens() {
        #expect(GenderClassifier.classify(title: "Women's Box Logo Hoodie") == .womens)
        #expect(GenderClassifier.classify(tags: ["womens"]) == .womens)
        #expect(GenderClassifier.classify(tags: ["wmns"]) == .womens)
        #expect(GenderClassifier.classify(handle: "womens-cargo-pant") == .womens)
    }

    @Test("Men's markers read as men's", arguments: [
        ["mens"], ["m-apparel"], ["menswear"], ["mens", "fall-24"]
    ])
    func mens(tags: [String]) {
        #expect(GenderClassifier.classify(tags: tags) == .mens)
    }

    /// Real Kith data: a product filed under both, named neither. It is for everyone, and
    /// calling it either one would hide it from half the users who want it.
    @Test("Both markers at the same level means unisex, not a coin flip")
    func bothIsUnisex() {
        #expect(GenderClassifier.classify(tags: ["mens", "wmns"]) == .unisex)
        #expect(GenderClassifier.classify(title: "Men's and Women's Tee") == .unisex)
    }

    /// The bug: a WMNS sneaker filed in a men's department kept showing up for someone
    /// who had asked for menswear only. Weighing a merchandising tag equally against the
    /// product's own name resolved it to unisex, and unisex is never hidden.
    ///
    /// "WMNS Dunk Low" *is* the women's cut — that is Nike's own designation. A retailer
    /// filing it under `mens` is a shelf decision, and one product routinely sits on
    /// several shelves.
    @Test("A name outranks the department it's filed under")
    func nameBeatsFiling() {
        #expect(GenderClassifier.classify(
            title: "Nike WMNS Air Force 1 '07",
            tags: ["mens"]
        ) == .womens)

        #expect(GenderClassifier.classify(
            title: "WMNS Dunk Low",
            productType: "Footwear",
            tags: ["mens", "footwear", "new-arrivals"]
        ) == .womens)

        // And the mirror image, so the rule isn't secretly "women's always wins".
        #expect(GenderClassifier.classify(
            title: "Men's Nathan Cargo Pant",
            tags: ["womens", "wmns"]
        ) == .mens)

        // A handle counts as a name too — it is derived from one.
        #expect(GenderClassifier.classify(
            tags: ["mens"],
            handle: "wmns-air-force-1"
        ) == .womens)
    }

    /// The precedence must not become "ignore tags". When the name says nothing — which is
    /// the common case — tags are the only evidence there is.
    @Test("Tags still decide when the name is silent")
    func tagsDecideWhenNameIsSilent() {
        #expect(GenderClassifier.classify(title: "Dunk Low", tags: ["wmns"]) == .womens)
        #expect(GenderClassifier.classify(title: "Cargo Pant", tags: ["mens"]) == .mens)
    }

    @Test("An explicit unisex marker wins outright")
    func explicitUnisex() {
        #expect(GenderClassifier.classify(tags: ["unisex", "mens"]) == .unisex)
    }

    /// Billionaire Boys Club's real tags. Nothing here says anything about who it is for,
    /// and inventing an answer would filter a real drop out of the feed.
    @Test("Catalogue noise yields unknown rather than a guess")
    func noiseIsUnknown() {
        #expect(GenderClassifier.classify(
            title: "Arch Logo Hoodie",
            productType: "Footwear",
            tags: ["2026", "F26", "Final Sale"]
        ) == .unknown)
    }

    /// Kith's tag list is 130 entries of internal merchandising codes. None of them may
    /// accidentally trip a gender signal.
    @Test("Merchandising codes don't accidentally signal a gender")
    func merchandisingCodesAreInert() {
        let kithNoise = [
            "020626", "kithclassics", "final-sale", "flow_tagged:types", "low_stock",
            "primary", "new-arrivals", "tee-program-2020", "limit-quantity-two",
            "model-measurements:kith-winter-2022", "specificSC", "httpr15"
        ]
        #expect(GenderClassifier.classify(tags: kithNoise) == .unknown)
    }

    @Test("Kids markers are recognised separately")
    func kids() {
        #expect(GenderClassifier.classify(title: "Kids Box Logo Tee") == .kids)
        #expect(GenderClassifier.classify(tags: ["youth"]) == .kids)
        #expect(GenderClassifier.classify(handle: "toddler-hoodie") == .kids)
    }

    @Test("Every field is read, not just tags")
    func readsEveryField() {
        #expect(GenderClassifier.classify(productType: "Women's Tops") == .womens)
        #expect(GenderClassifier.classify(handle: "mens-fall-jacket") == .mens)
    }

    /// A `FetchedItem`'s link is `/products/<handle>`, and the handle is often the only
    /// place the distinction survives — the visible title is frequently just "Cargo Pant".
    @Test("A fetched item is classified from its handle when the title is silent")
    func classifiesFetchedItemFromHandle() {
        let item = FetchedItem(
            externalID: "shopify:1",
            title: "Cargo Pant",
            linkURL: URL(string: "https://kith.com/products/womens-nathan-cargo-pant"),
            publishedAt: Date(),
            kind: .product
        )
        #expect(GenderClassifier.classify(item) == .womens)
    }
}

/// Run against the actual trimmed payloads rather than hand-written examples, for the
/// same reason the adapter tests are: real tag lists are far messier than anything you
/// would invent, and that mess is exactly what the classifier has to survive.
@Suite("Gender against real catalogues")
struct GenderFixtureTests {
    private func items(_ fixture: String, host: String) async throws -> [FetchedItem] {
        let http = MockHTTPClient()
        http.stub("/products.json?limit=250&page=1", fixture: fixture)
        http.stub("/meta.json", fixture: "shopify_meta.json")
        let source = BrandSource(kind: .shopify, url: URL(string: host)!)
        return try await ShopifySource(http: http).fetch(source, since: nil).items
    }

    @Test("Kith's men's staples classify as men's")
    func kithMens() async throws {
        let items = try await items("shopify_kith.json", host: "https://kith.com")
        let undershirts = items.filter { $0.productType == "Undershirts" }

        #expect(!undershirts.isEmpty, "fixture should still contain the undershirts")
        for item in undershirts {
            #expect(GenderClassifier.classify(item) == .mens, "\(item.title)")
        }
    }

    /// This one is real: Kith files it under both `mens` and `wmns`. Resolving it to
    /// either would hide it from half the people who want it.
    @Test("A product Kith files under both genders is unisex")
    func kithUnisex() async throws {
        let items = try await items("shopify_kith.json", host: "https://kith.com")
        let both = items.filter { $0.tags.contains("mens") && $0.tags.contains("wmns") }

        #expect(!both.isEmpty, "fixture should still contain a dual-tagged product")
        for item in both {
            #expect(GenderClassifier.classify(item) == .unisex, "\(item.title)")
        }
    }

    /// BBC tags everything `2026` / `F26` / `Final Sale`. There is genuinely no answer
    /// here, and the classifier must say so instead of guessing — a wrong guess deletes
    /// the brand from a filtered feed.
    @Test("Billionaire Boys Club yields unknown, and is therefore never filtered out")
    func bbcIsUnknown() async throws {
        let items = try await items("shopify_bbc.json", host: "https://bbcicecream.com")

        #expect(!items.isEmpty)
        for item in items {
            let gender = GenderClassifier.classify(item)
            #expect(gender == .unknown, "\(item.title) — tags \(item.tags)")
            #expect(GenderPreference.mens.allows(gender))
            #expect(GenderPreference.womens.allows(gender))
        }
    }
}

@Suite("Gender preference")
struct GenderPreferenceTests {
    /// Picking a gender means adult clothing in that cut. The opposite gender goes, and so
    /// does kids' — a children's hoodie in a menswear feed is the same annoyance as a
    /// women's one.
    @Test("Choosing a gender hides the opposite one and kids")
    func hidesOppositeAndKids() {
        let mens = GenderPreference.mens
        #expect(!mens.allows(.womens))
        #expect(!mens.allows(.kids))
        #expect(mens.allows(.mens))
        #expect(mens.allows(.unisex))
        #expect(mens.allows(.unknown), "an unclassifiable product must never be hidden")

        let womens = GenderPreference.womens
        #expect(!womens.allows(.mens))
        #expect(!womens.allows(.kids))
        #expect(womens.allows(.womens))
        #expect(womens.allows(.unisex))
        #expect(womens.allows(.unknown))
    }

    /// The one thing never traded away, whatever else the filter does: a brand whose tags
    /// say nothing — which is most of them — must not silently disappear.
    @Test("An unclassifiable product survives every preference")
    func unknownAlwaysSurvives() {
        for preference in GenderPreference.allCases {
            #expect(preference.allows(.unknown))
            #expect(preference.allows(.unisex))
        }
    }

    @Test("Everything allows everything")
    func everythingIsPermissive() {
        for gender in Gender.allCases {
            #expect(GenderPreference.everything.allows(gender))
        }
    }
}

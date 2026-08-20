import Foundation
import Testing

@testable import StreetwCore

@Suite("Style in your own words")
struct StyleStatementTests {
    private func garment(
        _ title: String,
        type: String? = nil,
        tags: [String] = [],
        color: String? = nil
    ) -> Garment {
        Garment(id: title, title: title, productType: type, tags: tags, color: color)
    }

    /// The sentence the whole feature was asked for.
    @Test("\"with\" states a pairing, not two preferences")
    func readsAPairing() {
        let statement = StyleStatement.parse("I like wearing checkered pattern with black shorts")

        #expect(statement.likes.contains("checkered"))
        #expect(statement.likes.contains("shorts"))
        #expect(statement.pairings.count == 1)

        let shirt = garment("Checkered Overshirt", type: "Shirts")
        let shorts = garment("Nylon Short", type: "Shorts", color: "Black")
        #expect(statement.statedPairing(between: shirt, and: shorts))
        // ...and it is a statement about *those two*, not a blessing on everything.
        #expect(!statement.statedPairing(between: shirt, and: garment("Wool Beanie", type: "Hats")))
    }

    /// "like" and "wear" are the two most common words in a sentence about clothes and say
    /// nothing about any of them. Left in, they match every garment in the wardrobe.
    @Test("Filler words never become preferences")
    func dropsFiller() {
        let statement = StyleStatement.parse("I usually like wearing my own stuff")
        #expect(statement.likes.isDisjoint(with: ["like", "wear", "wearing", "usually", "stuff", "own"]))
    }

    /// The only negative signal about *clothes* the app has ever had.
    @Test("A negated clause reads the other way")
    func readsDislikes() {
        let statement = StyleStatement.parse("Mostly workwear. No big logos.")
        #expect(statement.likes.contains("workwear"))
        #expect(statement.dislikes.contains("logos"))
        #expect(!statement.likes.contains("logos"))

        let loud = garment("Logos All Over Hoodie", tags: ["logos"])
        #expect(statement.affinity(for: loud) < 0)
    }

    /// "but" is how somebody corrects themselves mid-sentence, so it has to end a clause as
    /// hard as a full stop does — otherwise the correction is read as another preference.
    @Test("A correction after \"but\" wins")
    func laterNegationOverridesEarlierLike() {
        let statement = StyleStatement.parse("I wear a lot of denim but never skinny")
        #expect(statement.likes.contains("denim"))
        #expect(statement.dislikes.contains("skinny"))
        #expect(!statement.likes.contains("skinny"))
    }

    /// Colours are matched against what the photograph measured, not against the product
    /// name — plenty of black garments never say so in their title.
    @Test("A stated colour matches the colour that was measured")
    func matchesMeasuredColour() {
        let statement = StyleStatement.parse("mostly olive and black")
        let unnamed = garment("P3 Hood", color: "Olive")
        #expect(statement.affinity(for: unnamed) > 0)
    }

    /// A stated pairing is evidence; the colour wheel is a guess. When they disagree the
    /// person wins — an app that refuses the outfit somebody just described is arguing with
    /// its user.
    @Test("A stated pairing overrules the colour veto")
    func statementRescuesAClash() {
        let top = garment("Graphic Tee", type: "T-Shirt", color: "Red")
        let bottom = garment("Track Pant", type: "Pants", color: "Green")
        #expect(ColorHarmony.isClash("Red", "Green"))
        #expect(Pairing.score(top, with: bottom).isRefused)

        let statement = StyleStatement.parse("I wear red tees with green track pants")
        let rescued = Pairing.score(top, with: bottom, statement: statement)
        #expect(!rescued.isRefused)
        #expect(rescued.reason == "You wear these together")
    }

    /// It reorders; it never invents. Two tops are not an outfit however they were described.
    @Test("A statement cannot beat the slot gate")
    func statementNeverBreaksTheGate() {
        let one = garment("Boxy Tee", type: "T-Shirt")
        let two = garment("Long Sleeve Tee", type: "T-Shirt")
        let statement = StyleStatement.parse("I wear boxy tees with long sleeve tees")
        #expect(Pairing.score(one, with: two, statement: statement).isRefused)
    }

    /// Empty in, unchanged out — everybody who writes nothing must get exactly the ranking
    /// they got before this existed.
    @Test("Saying nothing changes nothing")
    func emptyStatementIsInert() {
        let empty = StyleStatement.parse("   ")
        #expect(empty.isEmpty)

        let top = garment("Hoodie", type: "Hoodie", color: "Black")
        let bottom = garment("Cargo Pant", type: "Pants", color: "Cream")
        #expect(Pairing.score(top, with: bottom, statement: empty).score
            == Pairing.score(top, with: bottom).score)
    }

    /// A word no catalogue uses can never contribute to a cosine and would only distort the
    /// norm — the same rule the taste vector applies to saves.
    @Test("Only words the catalogue uses reach the taste vector")
    func blendsOnlyKnownTerms() {
        let statement = StyleStatement.parse("workwear and unobtanium")
        let taste = BrandVector(vocabulary: ["denim": 1])
        let blended = statement.blended(into: taste, known: ["workwear", "denim"])

        #expect(blended.vocabulary["workwear"] != nil)
        #expect(blended.vocabulary["unobtanium"] == nil)
        // Still a taste profile: what was saved outweighs what was claimed.
        #expect((blended.vocabulary["denim"] ?? 0) > (blended.vocabulary["workwear"] ?? 0))
    }
}

@Suite("HTML entities")
struct HTMLEntityTests {
    /// The one that shipped: GV Gallery writes its Open Graph price this way, and a saved
    /// item was captioned with the markup. Note the leading zero — a table of `&#36;` would
    /// have missed it too.
    @Test("A numeric reference with a leading zero is still a dollar sign")
    func decodesPaddedNumericEntity() {
        #expect(HTMLEntities.decode("&#036;190.00") == "$190.00")
        #expect(HTMLEntities.decode("&#36;190.00") == "$190.00")
        #expect(HTMLEntities.decode("&#x24;190.00") == "$190.00")
    }

    @Test("Named references still decode")
    func decodesNamedEntities() {
        #expect(HTMLEntities.decode("Nike Dunk &amp; Co &#8211; Kith") == "Nike Dunk & Co – Kith")
        #expect(HTMLEntities.decode("&pound;180") == "£180")
    }

    /// A bare ampersand is legal markup and `&foo;` is more likely a product name than an
    /// entity. Deleting what cannot be read would lose real characters.
    @Test("Anything unrecognised is left exactly as it was")
    func leavesUnknownTextAlone() {
        #expect(HTMLEntities.decode("Fear & Loathing") == "Fear & Loathing")
        #expect(HTMLEntities.decode("&notanentity;") == "&notanentity;")
        #expect(HTMLEntities.decode("100% cotton") == "100% cotton")
    }

    @Test("A price read off a page comes out as a price")
    func metadataDecodesPrice() {
        let html = """
        <html><head>
        <meta property="og:title" content="Relaxed Hoodie">
        <meta property="twitter:data1" content="&#036;190.00">
        </head></html>
        """
        let metadata = PageMetadataParser.parse(html, base: URL(string: "https://gvgallery.com")!)
        #expect(metadata.price == "$190.00")
    }
}

@Suite("Printable traits")
struct TraitTests {
    /// "LIKE YOUR ITP", printed under a brand the block is trying to make attractive. The
    /// vocabulary keeps merchandising codes on purpose — IDF is what decides whether they
    /// mean anything — but they must never reach a caption.
    @Test("A merchandising code is never a reason")
    func rejectsCodes() {
        #expect(!Trait.isPrintable("itp"))
        #expect(!Trait.isPrintable("f26"))
        #expect(!Trait.isPrintable("sscw"))
    }

    @Test("Words that describe the shop rather than the clothes are refused")
    func rejectsUninformativeWords() {
        #expect(!Trait.isPrintable("sale"))
        #expect(!Trait.isPrintable("mens"))
        #expect(!Trait.isPrintable("accessories"))
    }

    @Test("The words worth printing still are")
    func keepsRealVocabulary() {
        for term in ["workwear", "denim", "japanese", "military", "skate", "knitwear"] {
            #expect(Trait.isPrintable(term), "\(term) should survive")
        }
    }

    @Test("A code shared with the taste profile does not become the card's line")
    func sharedTraitsSkipCodes() {
        let candidate = BrandVector(vocabulary: ["itp": 0.9, "denim": 0.4])
        let mine = BrandVector(vocabulary: ["itp": 0.9, "denim": 0.4])
        #expect(candidate.sharedTraits(with: mine) == ["denim"])
    }
}

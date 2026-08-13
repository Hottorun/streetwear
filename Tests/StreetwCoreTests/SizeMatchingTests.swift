import Foundation
import Testing

@testable import StreetwCore

@Suite("Size normalisation")
struct SizeNormalizerTests {
    @Test(
        "Apparel words and abbreviations fold together",
        arguments: [
            ("M", "M"), ("m", "M"), ("medium", "M"),
            ("L", "L"), ("large", "L"),
            ("XXL", "XXL"), ("2XL", "XXL"), ("xxl", "XXL"),
            ("XS", "XS"), ("extra small", "XS")
        ]
    )
    func apparel(raw: String, token: String) {
        let size = SizeNormalizer.normalize(raw)
        #expect(size?.kind == .apparel)
        #expect(size?.token == token)
    }

    /// Half a brand's run being readable is worse than none of it, because nothing
    /// announces the failure. YoungLA writes its whole catalogue this way and only the
    /// three bare words were understood — so on every product they make, the extremities
    /// were the tokens that could never be ruled in as somebody's size.
    @Test(
        "A size spelled out in full is the same size",
        arguments: [
            ("XSmall", "XS"), ("xsmall", "XS"), ("X Small", "XS"), ("x-small", "XS"),
            ("XXSmall", "XXS"),
            ("XLarge", "XL"), ("X Large", "XL"), ("extra large", "XL"),
            ("XXLarge", "XXL"), ("2XLarge", "XXL"), ("2X Large", "XXL"),
            ("XXXLarge", "XXXL"), ("3XLarge", "XXXL"),
            ("4XLarge", "4XL")
        ]
    )
    func spelledOutApparel(raw: String, token: String) {
        let size = SizeNormalizer.normalize(raw)
        #expect(size?.kind == .apparel, "\(raw) should read as apparel")
        #expect(size?.token == token)
    }

    /// The prefix has to be X's and nothing else. A "petite small" is not an S, and
    /// matching it to one would put the wrong garment in somebody's size-filtered feed —
    /// which is the one failure this whole layer exists to avoid.
    @Test(
        "A qualifier that isn't a multiplier is not folded away",
        arguments: ["petite small", "junior large", "tall medium", "kids small"]
    )
    func qualifiedSizesStayOther(raw: String) {
        #expect(SizeNormalizer.normalize(raw)?.kind == .other)
    }

    @Test(
        "Waists in inches read as waists",
        arguments: [
            ("32", "32"), ("W32", "32"), ("w 34", "34"), ("34W", "34"),
            ("Waist 36", "36"), ("32x30", "32"), ("32 X 30", "32"), ("34/32", "34"),
            ("W44", "44"), ("waist 46", "46")
        ]
    )
    func waists(raw: String, token: String) {
        let size = SizeNormalizer.normalize(raw)
        #expect(size?.kind == .waist, "\(raw) should read as a waist")
        #expect(size?.token == token)
    }

    /// A bare number from 38 up is as likely a European shoe as a pair of trousers, and
    /// reading it wrong would hide a product. Only a string that names itself a waist is
    /// trusted that far up; the rest stays exactly where it already was.
    @Test(
        "An ambiguous bare number is still nobody's size",
        arguments: ["38", "40", "42", "44", "48"]
    )
    func ambiguousNumbersStayOther(raw: String) {
        #expect(SizeNormalizer.normalize(raw)?.kind == .other)
    }

    /// The women's-shoe marker is the same letter as the waist marker. "W 9" has to come
    /// out of the waist reader untouched and land on the shoe ladder.
    @Test("A women's shoe marker is not a waist")
    func womensMarkerIsNotAWaist() {
        #expect(SizeNormalizer.normalize("W 9")?.kind == .shoe)
        #expect(SizeNormalizer.normalize("women's 9")?.kind == .shoe)
        #expect(SizeNormalizer.normalize("W 9")?.token == "9")
    }

    @Test(
        "US shoe sizes normalise regardless of prefix or trailing zero",
        arguments: [
            ("9", "9"), ("9.0", "9"), ("9.5", "9.5"),
            ("US 9", "9"), ("US9", "9"), ("us 9.5", "9.5"), ("9 US", "9")
        ]
    )
    func shoes(raw: String, token: String) {
        let size = SizeNormalizer.normalize(raw)
        #expect(size?.kind == .shoe)
        #expect(size?.token == token)
    }

    @Test("One-size markers collapse, including Shopify's placeholder", arguments: [
        "OS", "O/S", "One Size", "one size fits all", "Default Title"
    ])
    func oneSize(raw: String) {
        #expect(SizeNormalizer.normalize(raw)?.kind == .oneSize)
    }

    /// The important one. Classing an *unlabelled* number as a US shoe size would let a
    /// US-9 profile hide every EU-sized or waist-sized product — the one failure mode a
    /// drop tracker must never have.
    ///
    /// A bare number in the waist band now reads as a waist rather than as nothing, but
    /// the invariant asserted here is unchanged and is the one that matters: an unlabelled
    /// number is **never** a shoe. Above the band it is still `.other`, because there it
    /// is as likely an EU shoe as a pair of trousers.
    @Test("Unlabelled numeric sizing is not mistaken for a shoe size", arguments: [
        "44", "32", "28", "2", "50"
    ])
    func outOfRangeNumbersAreNotShoes(raw: String) {
        #expect(SizeNormalizer.normalize(raw)?.kind != .shoe)
    }

    /// A size that *names* its scale is a different matter: there is nothing to guess, so
    /// converting it is strictly better than treating it as unknown.
    @Test("An explicitly regioned size converts to its US equivalent", arguments: [
        ("EU 44", "10"), ("eu 42.5", "9"), ("EUR 43", "9.5"), ("44 EU", "10"),
        ("UK 8", "9"), ("uk 9", "10"), ("UK 10.5", "11.5")
    ])
    func regionedSizesConvert(raw: String, token: String) {
        let size = SizeNormalizer.normalize(raw)
        #expect(size?.kind == .shoe)
        #expect(size?.token == token, "\(raw) should be US \(token)")
        #expect(size?.isConverted == true)
    }

    /// The bug this fixes: both region codes used to be stripped and the remainder read
    /// as US, so a UK 9 — a US 10 — was highlighted as the user's US 9.
    @Test("A UK size is not read as the same number in US")
    func ukIsNotUS() {
        #expect(SizeNormalizer.normalize("UK 9")?.token == "10")
        #expect(SizeNormalizer.normalize("US 9")?.token == "9")
        #expect(SizeNormalizer.normalize("9")?.token == "9")
    }

    /// A region code is only a region code where a size actually is one — otherwise a
    /// colourway called "Ukiyo" or a fabric named "Eucalyptus" changes the scale.
    @Test("A region code is only read next to a number")
    func regionCodeNeedsANumber() {
        #expect(SizeNormalizer.normalize("Ukiyo")?.scale == .us)
        #expect(SizeNormalizer.normalize("Eucalyptus")?.scale == .us)
    }

    @Test("Empty input yields nothing")
    func empty() {
        #expect(SizeNormalizer.normalize("") == nil)
        #expect(SizeNormalizer.normalize("   ") == nil)
    }
}

@Suite("Size profile matching")
struct SizeProfileTests {
    private var profile: SizeProfile {
        var p = SizeProfile()
        p.apparel = ["M", "L"]
        p.shoe = ["9", "9.5"]
        return p
    }

    @Test("An empty profile matches everything")
    func emptyMatchesAll() {
        let empty = SizeProfile()
        #expect(empty.isEmpty)
        for raw in ["M", "XXL", "9", "44", "OS"] {
            #expect(empty.matches(raw), "empty profile should not filter \(raw)")
        }
    }

    @Test("Matches only the chosen apparel and shoe sizes")
    func matchesChosen() {
        #expect(profile.matches("M"))
        #expect(profile.matches("medium"))
        #expect(profile.matches("9.5"))
        #expect(profile.matches("US 9"))
        #expect(!profile.matches("S"))
        #expect(!profile.matches("XXL"))
        #expect(!profile.matches("10"))
    }

    /// A one-size item fits everyone by definition, so it is never filtered out. The
    /// toggle that could exclude them was one more thing to explain in exchange for
    /// hiding most of the accessories in the feed.
    @Test("One-size items always match")
    func oneSizeAlwaysMatches() {
        for raw in ["OS", "O/S", "One Size", "Default Title"] {
            #expect(profile.matches(raw))
        }
    }

    @Test("Unrecognised sizing is shown, never hidden")
    func unknownIsPermissive() {
        #expect(profile.matches("44"))
        #expect(profile.matches("Youth L"))
        #expect(profile.matches("32"))
    }

    /// Bottoms are sized by the inch and used to normalise to `.other` — never hidden,
    /// never matched — so on denim and workwear the whole feature was inert.
    @Test("Waists match once a waist is set")
    func matchesWaist() {
        var p = profile
        p.waist = ["32", "34"]
        #expect(p.matches("32"))
        #expect(p.matches("W34"))
        #expect(p.matches("32x30"))
        #expect(!p.matches("36"))
        #expect(!p.matches("W 28"))
    }

    /// The failure this would otherwise have introduced: somebody enters a waist, and
    /// every shirt in the app disappears because they never filled in a letter.
    @Test("A ladder that has not been filled in does not filter")
    func laddersAreIndependent() {
        var waistOnly = SizeProfile()
        waistOnly.waist = ["32"]
        #expect(!waistOnly.isEmpty)
        #expect(waistOnly.matches("M"), "clothing must not vanish because only a waist was set")
        #expect(waistOnly.matches("9.5"), "shoes must not vanish either")
        #expect(!waistOnly.matches("36"))

        var shoesOnly = SizeProfile()
        shoesOnly.shoe = ["9"]
        #expect(shoesOnly.matches("M"))
        #expect(shoesOnly.matches("32"))
        #expect(!shoesOnly.matches("11"))
    }

    @Test("The summary names the waist ladder")
    func summaryIncludesWaist() {
        var p = SizeProfile()
        p.waist = ["32", "34"]
        #expect(p.summary == "W 32, 34")
    }

    /// A converted size is a good estimate, not a fact — Nike and adidas disagree by half
    /// a size on the same foot — so it matches within one rung of the ladder. Without the
    /// tolerance this filter would start hiding real results, which is exactly what the
    /// permissive rules above exist to prevent.
    @Test("A converted shoe size matches within half a size")
    func convertedSizesAreTolerant() {
        // Profile is US 9 and 9.5.
        #expect(profile.matches("EU 42.5"), "EU 42.5 is US 9 exactly")
        #expect(profile.matches("EU 43"), "EU 43 is US 9.5 exactly")
        #expect(profile.matches("EU 44"), "EU 44 is US 10 — within half a size of the owned 9.5")
        #expect(!profile.matches("EU 45"), "EU 45 is US 11 — genuinely not this foot")
        #expect(!profile.matches("EU 40"), "EU 40 is US 7 — genuinely not this foot")
    }

    /// The tolerance must not leak into sizes that were never converted, or the whole
    /// profile becomes a size wider than the user asked for.
    @Test("An exact US size gets no tolerance")
    func nativeSizesAreExact() {
        #expect(!profile.matches("10"))
        #expect(!profile.matches("US 10"))
        #expect(!profile.matches("8.5"))
    }

    @Test("Shoe sizes are stored in US and displayed in the chosen scale")
    func scaleIsDisplayOnly() {
        var european = profile
        european.shoeScale = .eu

        #expect(european.shoe == ["9", "9.5"], "changing scale must not rewrite storage")
        #expect(european.summary.contains("EU"))
        #expect(european.summary.contains("42.5"))
        // Matching is unaffected: the scale is a reading preference, not a filter.
        #expect(european.matches("US 9"))
        #expect(!european.matches("US 11"))
    }

    /// A profile written before `shoeScale` existed is sitting in UserDefaults on a real
    /// phone. SwiftData/JSON decoding of a missing non-optional key throws.
    @Test("A profile stored before the scale existed still decodes")
    func decodesLegacyProfile() throws {
        let legacy = #"{"apparel":["M"],"shoe":["9"],"includeOneSize":true}"#
        let decoded = try JSONDecoder().decode(SizeProfile.self, from: Data(legacy.utf8))

        #expect(decoded.apparel == ["M"])
        #expect(decoded.shoe == ["9"])
        #expect(decoded.shoeScale == .us)
    }

    @Test("Matching a variant uses the size axis, not the joined title")
    func matchesVariant() {
        let variant = VariantInfo(
            id: "1",
            title: "WHITE/OWHITE/CBROWN / 9",
            available: true,
            size: "9",
            color: "WHITE/OWHITE/CBROWN"
        )
        #expect(profile.matches(variant))

        let wrongSize = VariantInfo(id: "2", title: "BLACK / 11", available: true, size: "11")
        #expect(!profile.matches(wrongSize))
    }

    @Test("Summary lists sizes in canonical order")
    func summary() {
        var p = SizeProfile()
        p.apparel = ["XL", "M", "L"]
        p.shoe = ["9.5", "9"]
        #expect(p.summary == "M, L, XL · US 9, 9.5")
        #expect(SizeProfile().summary == "Not set")
    }
}

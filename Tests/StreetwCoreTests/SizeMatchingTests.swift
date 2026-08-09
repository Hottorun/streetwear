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

    /// The important one. Classing these as US shoe sizes would let a US-9 profile
    /// *hide* every EU-sized or waist-sized product — the one failure mode a drop
    /// tracker must never have.
    @Test("Non-US numeric sizing is not mistaken for a shoe size", arguments: [
        "44", "EU 44", "32", "28", "2"
    ])
    func outOfRangeNumbersAreNotShoes(raw: String) {
        #expect(SizeNormalizer.normalize(raw)?.kind == .other)
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

    @Test("One-size items follow the toggle")
    func oneSizeToggle() {
        var p = profile
        #expect(p.includeOneSize)
        #expect(p.matches("OS"))
        p.includeOneSize = false
        #expect(!p.matches("OS"))
    }

    @Test("Unrecognised sizing is shown, never hidden")
    func unknownIsPermissive() {
        #expect(profile.matches("44"))
        #expect(profile.matches("Youth L"))
        #expect(profile.matches("32"))
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

import Foundation
import Testing

@testable import StreetwCore

@Suite("Watch matching")
struct WatchMatchingTests {
    private func variant(
        _ size: String,
        _ color: String? = nil,
        available: Bool = true
    ) -> VariantInfo {
        VariantInfo(
            id: "\(color ?? "-")-\(size)",
            title: color.map { "\($0) / \(size)" } ?? size,
            available: available,
            size: size,
            color: color
        )
    }

    @Test("Both pins must agree")
    func bothPins() {
        let target = WatchTarget(size: "M", color: "Black")

        #expect(target.matches(variant("M", "Black")))
        #expect(!target.matches(variant("L", "Black")))
        #expect(!target.matches(variant("M", "Sand")))
    }

    @Test("An absent pin matches anything on that axis")
    func absentPins() {
        #expect(WatchTarget(size: "M").matches(variant("M", "Sand")))
        #expect(WatchTarget(color: "Black").matches(variant("XL", "Black")))
        #expect(WatchTarget().matches(variant("XL", "Sand")))
    }

    /// An empty string is what a UI hands over for "no selection", and treating it as a
    /// pin would produce a watch that can never match anything.
    @Test("An empty pin is the same as no pin")
    func emptyStringIsNoPin() {
        let target = WatchTarget(size: "", color: "")
        #expect(target.isAnySize)
        #expect(target.isAnyColor)
        #expect(target.matches(variant("M", "Black")))
    }

    /// Sizes go through the normaliser, so a watch survives the catalogue changing how it
    /// spells the same size — which storefronts do, between "M" and "Medium".
    @Test("Size pins are normalised, not compared as text")
    func sizesNormalise() {
        #expect(WatchTarget(size: "M").matches(variant("Medium")))
        #expect(WatchTarget(size: "medium").matches(variant("M")))
        #expect(WatchTarget(size: "9.5").matches(variant("US 9.5")))
        #expect(WatchTarget(size: "9").matches(variant("9.0")))
    }

    /// Colourway names are brand vocabulary with no canonical form, so they are compared
    /// case-insensitively and otherwise literally. "Vintage Black" is genuinely not
    /// "Black" — they are different products on the shelf.
    @Test("Colour pins are case-insensitive but not fuzzy")
    func coloursAreLiteral() {
        #expect(WatchTarget(color: "black").matches(variant("M", "BLACK")))
        #expect(!WatchTarget(color: "Black").matches(variant("M", "Vintage Black")))
    }

    @Test("A watch is satisfied only by a variant that is both matching and buyable")
    func satisfaction() {
        let target = WatchTarget(size: "M", color: "Black")

        #expect(!target.isSatisfied(by: [variant("M", "Black", available: false)]))
        #expect(!target.isSatisfied(by: [variant("L", "Black", available: true)]))
        #expect(target.isSatisfied(by: [
            variant("M", "Black", available: false),
            variant("M", "Black", available: true)
        ]))
    }

    @Test("Only the matching, buyable sizes are named in an alert")
    func availableSizesForCopy() {
        let target = WatchTarget(color: "Black")
        let sizes = target.availableSizes(in: [
            variant("S", "Black", available: true),
            variant("M", "Black", available: false),
            variant("L", "Black", available: true),
            variant("XL", "Sand", available: true)
        ])

        #expect(sizes == ["S", "L"])
    }

    @Test("Shopify's placeholder size is never named in an alert")
    func ignoresDefaultTitle() {
        let target = WatchTarget()
        let sizes = target.availableSizes(in: [
            VariantInfo(id: "1", title: "Default Title", available: true, size: "Default Title")
        ])
        #expect(sizes.isEmpty)
    }

    @Test("The summary reads as a size, not as a data structure")
    func summary() {
        #expect(WatchTarget(size: "M", color: "Black").summary == "M · Black")
        #expect(WatchTarget(size: "US 9").summary == "US 9")
        #expect(WatchTarget().summary == "Any size or colour")
    }
}

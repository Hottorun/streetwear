import Foundation
import Testing

@testable import StreetwCore

@Suite("Garment slotting")
struct GarmentSlotTests {
    @Test("Common streetwear lands in the right slot", arguments: [
        ("Box Logo Hoodie", GarmentSlot.top),
        ("Nathan Cargo Pant", .bottom),
        ("Dunk Low", .unknown),
        ("Puffer Jacket", .outerwear),
        ("5-Panel Cap", .headwear),
        ("Leather Tote", .accessory)
    ])
    func titles(title: String, slot: GarmentSlot) {
        #expect(GarmentClassifier.classify(title: title) == slot)
    }

    /// The catalogue's own category beats the title, because the title is where marketing
    /// language lives. "Nocturne Crewneck" is a top because the shop filed it under
    /// Sweatshirts, not because of the word in the name.
    @Test("Product type outranks the title")
    func productTypeWins() {
        #expect(GarmentClassifier.classify(
            title: "Nocturne",
            productType: "Sweatshirts"
        ) == .top)

        #expect(GarmentClassifier.classify(
            title: "Something Jacket-ish",
            productType: "Footwear"
        ) == .footwear)
    }

    /// A word appearing inside another word must not place a garment. "Short sleeve" is a
    /// top; "shorts" is a bottom; substring matching gets both wrong.
    @Test("Slotting is by token, not substring")
    func tokensNotSubstrings() {
        #expect(GarmentClassifier.classify(title: "Short Sleeve Shirt") == .top)
        #expect(GarmentClassifier.classify(title: "Cargo Shorts") == .bottom)
    }

    @Test("Vision's own labels are used when the catalogue is vague")
    func visionCategories() {
        #expect(GarmentClassifier.classify(
            title: "Nocturne",
            visionCategories: ["Footwear"]
        ) == .footwear)
    }

    /// An item we can't place is left out of a fit rather than forced into a slot where
    /// it would look like a mistake.
    @Test("Anything unplaceable stays unknown")
    func unknownStaysUnknown() {
        #expect(GarmentClassifier.classify(title: "Chapter 3") == .unknown)
        #expect(GarmentClassifier.classify(title: "") == .unknown)
    }

    /// A collage that puts the shoes above the jacket reads as a grid of products rather
    /// than as an outfit.
    @Test("Slots stack top of the body down")
    func stackOrder() {
        let ordered = GarmentSlot.allCases.sorted { $0.stackOrder < $1.stackOrder }
        #expect(ordered.prefix(5) == [.headwear, .outerwear, .top, .bottom, .footwear])
    }

    /// A "fit" that is a cap and a tote is not an outfit.
    @Test("Essential slots exclude headwear and accessories")
    func essentialSlots() {
        #expect(GarmentSlot.essential == [.outerwear, .top, .bottom, .footwear])
    }
}

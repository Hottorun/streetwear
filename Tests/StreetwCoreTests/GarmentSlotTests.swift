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

/// Which tops need something under them.
///
/// `GarmentSlot` cannot answer this — it files a t-shirt and a hoodie in the same box —
/// and without it a suggestion could be a hoodie over bare skin, or a jacket over a hoodie
/// over nothing. See `GarmentLayer`.
@Suite("Layering")
struct GarmentLayerTests {
    @Test("A mid layer is recognised by name", arguments: [
        "Box Logo Hoodie", "P3 HOOD", "Nocturne Crewneck", "Cable Knit Jumper",
        "Half Zip Fleece", "Merino Cardigan", "Turtleneck"
    ])
    func midLayers(_ title: String) {
        #expect(LayerClassifier.layer(title: title) == .mid)
    }

    @Test("Anything worn against the skin is a base layer", arguments: [
        "Small Box Tee", "Oxford Shirt", "Pique Polo", "Ribbed Tank", "Long Sleeve Henley"
    ])
    func baseLayers(_ title: String) {
        #expect(LayerClassifier.layer(title: title) == .base)
    }

    /// A football shirt sits beside "sweater" in the slot table and is worn on its own. It
    /// is one of the most common things these brands make, so reading it as a mid layer
    /// would drag an unnecessary t-shirt into a large share of all suggestions.
    @Test("A jersey is worn on its own")
    func jerseyIsBase() {
        #expect(LayerClassifier.layer(title: "Velour Soccer Jersey") == .base)
    }

    /// Whole tokens, never substrings — the rule the rest of the codebase runs on. A
    /// sweatband is not a sweater and a hooded jacket's slot is decided before this is
    /// ever asked.
    @Test("A sweatband is not a sweater")
    func wholeTokensOnly() {
        #expect(LayerClassifier.layer(title: "Terry Sweatband") == .base)
    }

    @Test("Outerwear and mid layers ask for something underneath")
    func whatNeedsABase() {
        #expect(Garment(id: "1", title: "Box Logo Hoodie").needsBaseLayer)
        #expect(Garment(id: "2", title: "Puffer Jacket").needsBaseLayer)
        #expect(!Garment(id: "3", title: "Small Box Tee").needsBaseLayer)
        // A bottom is never asked this, and must not claim it.
        #expect(!Garment(id: "4", title: "Cargo Pant").needsBaseLayer)
    }
}

/// "Accessories" is a shelf, not a garment — and it used to outrank the product's own name.
@Suite("Filed under accessories")
struct AccessoryShelfTests {
    /// Measured on a real collection: a cap named "ACW* x Rally Cap Optic" was filed by its
    /// storefront under Accessories, so it was placed there — never proposed as headwear, and
    /// drawn down at shoe level on the fit canvas, where an accessory sits.
    @Test("A cap filed under accessories is still headwear")
    func capBeatsTheShelf() {
        let slot = GarmentClassifier.classify(
            title: "ACW* x Rally Cap Optic",
            productType: "Accessories"
        )
        #expect(slot == .headwear)
    }

    @Test("A three-pack of tees filed under accessories is still a top")
    func teesBeatTheShelf() {
        #expect(GarmentClassifier.classify(title: "TEES 3 PACK", productType: "ACCESSORIES") == .top)
    }

    /// The provisional reading is still the answer when nothing more specific speaks, which
    /// is the ordinary case: a bag's title names no other slot.
    @Test("A genuine accessory is unaffected")
    func realAccessoryStands() {
        #expect(GarmentClassifier.classify(title: "Kith Monday Program", productType: "Accessories") == .accessory)
    }

    /// The rule it is carved out of: a category that names a garment still outranks a title,
    /// which is what makes "Nocturne Crewneck" a top because the shop filed it that way.
    @Test("A category that names a garment still leads")
    func namedCategoryStillLeads() {
        #expect(GarmentClassifier.classify(title: "Nocturne", productType: "Sweatshirts") == .top)
    }
}

/// One row, two positions on the body — see `GarmentClassifier.isSet`.
@Suite("Sets")
struct SetTests {
    @Test("A tracksuit is a set", arguments: [
        "Corteiz Superior Royale Tracksuit",
        "Nike Two-Piece Set",
        "Velour Co-Ord"
    ])
    func namesASet(_ title: String) {
        #expect(GarmentClassifier.isSet(title: title))
    }

    /// The cost of a false positive is higher than a miss: it takes a whole position out of
    /// the wardrobe. So a bare "set" is deliberately not a word this reads.
    @Test("A pin set and a three-pack are not outfits", arguments: [
        "Kith for BMW Set of 5 Pin Set",
        "TEES 3 PACK",
        "Sunset Wash Hoodie"
    ])
    func doesNotOverreach(_ title: String) {
        #expect(!GarmentClassifier.isSet(title: title))
    }

    /// A set naming neither half would otherwise be `.unknown`, which every gate in the fit
    /// engine refuses — so the one garment that is a whole outfit could never be in one.
    @Test("A bare tracksuit is placed rather than left unplaceable")
    func bareSetIsPlaced() {
        let garment = Garment(id: "1", title: "Corteiz Superior Royale Tracksuit")
        #expect(garment.slot != .unknown)
        #expect(garment.occupied.contains(.top))
        #expect(garment.occupied.contains(.bottom))
    }

    @Test("Tracksuit bottoms are bottoms, and still a set")
    func namedHalfIsPlacedThere() {
        let garment = Garment(id: "1", title: "Tracksuit Bottoms")
        #expect(garment.slot == .bottom)
        #expect(garment.isSet)
    }
}

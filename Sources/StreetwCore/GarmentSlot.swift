// GarmentSlot.swift
// Which part of an outfit a garment occupies.
//
// An outfit is not an arbitrary pile of clothes — it is roughly one thing per layer, and
// two pairs of trousers is not a fit. So composing one, or checking whether a wardrobe
// *can* compose one, needs to know what each saved item is. Nobody publishes that either,
// so this reads the same catalogue text `GenderClassifier` does.
//
// Same two rules apply, for the same reasons: whole-token matching (never substrings), and
// an honest `.unknown` rather than a guess. An item we can't place simply doesn't get put
// in a fit — it is not forced into a slot where it would look like a mistake.

import Foundation

public enum GarmentSlot: String, Codable, Sendable, CaseIterable, Identifiable {
    case outerwear
    case top
    case bottom
    case footwear
    case headwear
    case accessory
    case unknown

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .outerwear: "Outerwear"
        case .top: "Top"
        case .bottom: "Bottom"
        case .footwear: "Footwear"
        case .headwear: "Headwear"
        case .accessory: "Accessory"
        case .unknown: "Other"
        }
    }

    /// The order a fit is read in, top of the body down. A collage that puts the shoes
    /// above the jacket reads as a grid of products rather than as an outfit.
    public var stackOrder: Int {
        switch self {
        case .headwear: 0
        case .outerwear: 1
        case .top: 2
        case .bottom: 3
        case .footwear: 4
        case .accessory: 5
        case .unknown: 6
        }
    }

    /// The slots a fit is built from, in order. Headwear and accessories are deliberately
    /// excluded: they are optional in a way a top isn't, and a "fit" that is a cap and a
    /// tote is not an outfit.
    public static let essential: [GarmentSlot] = [.outerwear, .top, .bottom, .footwear]
}

public enum GarmentClassifier {
    /// Longest phrase first within each slot, and slots checked in a fixed order, because
    /// several words legitimately appear in more than one garment — "jacket" in "jacket"
    /// and in "shirt jacket", "shorts" in "shorts" and in "short sleeve".
    private static let table: [(slot: GarmentSlot, words: [String])] = [
        (.footwear, [
            "sneaker", "sneakers", "trainer", "trainers", "shoe", "shoes", "boot", "boots",
            "sandal", "sandals", "slide", "slides", "clog", "clogs", "loafer", "loafers",
            "footwear", "runner", "runners", "mule", "mules"
        ]),
        (.headwear, [
            "cap", "caps", "hat", "hats", "beanie", "beanies", "bucket", "balaclava", "visor"
        ]),
        (.outerwear, [
            "jacket", "jackets", "coat", "coats", "parka", "parkas", "anorak", "windbreaker",
            "outerwear", "puffer", "bomber", "trench", "raincoat", "overcoat", "gilet", "vest"
        ]),
        (.bottom, [
            // "shorts" but never a bare "short" — "Short Sleeve Shirt" is a top, and the
            // singular is vanishingly rare as a garment name.
            "pant", "pants", "trouser", "trousers", "jean", "jeans", "denim",
            "shorts", "sweatpant", "sweatpants", "jogger", "joggers", "cargo", "cargos",
            "chino", "chinos", "skirt", "skirts", "legging", "leggings", "bottoms"
        ]),
        (.top, [
            "tee", "tshirt", "shirt", "shirts", "hoodie", "hoodies", "hoody",
            "sweatshirt", "sweater", "sweaters", "crewneck", "knit", "knitwear", "jumper",
            "polo", "longsleeve", "top", "tops", "tank", "jersey", "cardigan"
        ]),
        (.accessory, [
            "bag", "bags", "tote", "backpack", "belt", "belts", "sock", "socks", "scarf",
            "glove", "gloves", "wallet", "keychain", "sunglasses", "jewelry", "jewellery",
            "necklace", "ring", "bracelet", "accessory", "accessories"
        ])
    ]

    /// Places a garment, reading the fields most likely to name it first.
    ///
    /// `productType` outranks the title for the same reason a tag doesn't outrank a name
    /// in `GenderClassifier` — but inverted, because here the storefront's *category* is
    /// the more reliable signal and the title is where marketing language lives. "Nocturne
    /// Crewneck" is a top because the catalogue filed it under Sweatshirts, not because
    /// the word "crewneck" happens to be in the name.
    public static func classify(
        title: String = "",
        productType: String? = nil,
        tags: [String] = [],
        visionCategories: [String] = []
    ) -> GarmentSlot {
        if let productType {
            let slot = match(productType)
            if slot != .unknown { return slot }
        }
        // Vision's own labels next: they describe the photograph rather than the copy.
        for category in visionCategories {
            let slot = match(category)
            if slot != .unknown { return slot }
        }
        let fromTitle = match(title)
        if fromTitle != .unknown { return fromTitle }
        for tag in tags {
            let slot = match(tag)
            if slot != .unknown { return slot }
        }
        return .unknown
    }

    /// Phrases that name a slot and would be mis-slotted token by token. Checked across
    /// *every* slot before any single-token matching, because "short sleeve" contains a
    /// word that belongs to a different slot and whichever slot is tested first would
    /// otherwise win.
    private static let phrases: [(slot: GarmentSlot, phrase: String)] = [
        (.top, "short sleeve"),
        (.top, "long sleeve"),
        (.top, "t-shirt"),
        (.outerwear, "shirt jacket"),
        (.footwear, "running shoe")
    ]

    private static func match(_ text: String) -> GarmentSlot {
        let lowered = text.lowercased()
        for entry in phrases where lowered.contains(entry.phrase) { return entry.slot }

        let tokens = text.lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
        guard !tokens.isEmpty else { return .unknown }

        for entry in table {
            let words = Set(entry.words)
            // Raw token first, then a de-pluralised form, so a catalogue category of
            // "Sweatshirts" places the same as "Sweatshirt". Matching the raw token first
            // matters: "shorts" must stay a bottom rather than being reduced to the bare
            // "short" that is deliberately not in the list.
            if tokens.contains(where: { words.contains($0) || words.contains(singular($0)) }) {
                return entry.slot
            }
        }
        return .unknown
    }

    /// Crude on purpose — it only ever has to undo a trailing plural on a garment noun.
    private static func singular(_ token: String) -> String {
        guard token.count > 3, token.hasSuffix("s"), !token.hasSuffix("ss") else { return token }
        return String(token.dropLast())
    }
}

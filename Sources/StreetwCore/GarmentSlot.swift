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

/// Turning two measurements of a garment's outline into a word.
///
/// The measuring is done on the device, off the cutout mask, and cannot live here —
/// `StreetwCore` compiles on Linux and CoreGraphics does not. The *judgement* can, and
/// should: which band a proportion falls into is the part with an opinion in it, the part
/// most likely to be wrong, and the only part that can be tested without a photograph.
///
/// All three inputs are ratios within the outline, so they survive brands shooting at
/// different distances:
///
/// - **breadth** — the widest row divided by the outline's height.
/// - **taper** — the hem's width divided by the widest row.
/// - **bodyBreadth** — the hem's width divided by the outline's height.
///
/// The third exists because of a wrong answer on a real wardrobe. A top laid flat has its
/// sleeves out to the sides, so its *widest row* is the sleeve span — which says nothing
/// whatever about the garment's cut. Read on `breadth`, a funnel-neck fleece and a hoodie
/// both came back "Cropped", which is not a word either of them deserves. The hem is the
/// body, and the body is what "boxy" and "longline" are about.
public enum SilhouetteBands {
    /// The word for this outline, or **nil**, which is the common answer.
    ///
    /// There is deliberately a gap between every band where nothing is reported. Most
    /// garments are unremarkable in shape, and a profile that labels all of them "Regular"
    /// has said nothing at length — the same reason `GenderClassifier` answers `.unknown`
    /// rather than guessing. Only an outline clearly at one end earns a word.
    ///
    /// Slots other than tops, bottoms and outerwear return nil outright. A shoe has a
    /// perfectly good outline and its shape is a fact about shoes rather than about the
    /// person wearing them; "Wide" under every sneaker in a collection is a facet nobody
    /// would open.
    public static func label(
        breadth: Double,
        taper: Double,
        bodyBreadth: Double,
        slot: GarmentSlot
    ) -> String? {
        // Nothing wearable is this shape.
        //
        // The last line of defence, and it exists because the ones before it were not
        // enough. Measured against a real collection, tops came back with a body 1.29 times
        // their own height — a hoodie wider at the hem than it is long, which no garment is.
        // Every guard before this one asks whether the *outline* looks like an outline;
        // this one asks whether the answer is a garment, and refuses when it plainly is
        // not. A refused reading costs a facet nobody sees. A reading like that one, kept,
        // is a wrong word printed under somebody's own wardrobe.
        guard bodyBreadth <= Self.impossible(for: slot) else { return nil }

        switch slot {
        case .bottom:
            // A leg is read at the hem: that is the whole difference between a wide leg and
            // a tapered one, and it is invisible in the overall proportions.
            if taper >= 0.9 && breadth >= 0.42 { return "Wide" }
            if taper <= 0.62 { return "Tapered" }
            if breadth <= 0.3 { return "Slim" }
            return nil

        case .top, .outerwear:
            // The body, not the wingspan. Note there is no "Cropped": a cropped top and a
            // boxy one both widen the body relative to the length and these two numbers
            // cannot tell them apart, so claiming to would be a guess dressed as a
            // measurement. Two words that are true beat three where one is invented.
            if bodyBreadth >= 0.86 { return "Boxy" }
            if bodyBreadth <= 0.62 { return "Longline" }
            return nil

        default:
            return nil
        }
    }

    /// Whether an outline is worth measuring at all for this slot.
    public static func speaks(for slot: GarmentSlot) -> Bool {
        slot == .top || slot == .bottom || slot == .outerwear
    }

    /// The widest a garment's hem can plausibly be relative to its own length.
    ///
    /// Generous, because this is only meant to catch answers that are not about clothes at
    /// all. A cropped tee is a real garment and comes close to square; a hoodie a third
    /// wider than it is long is a photograph being measured instead of a garment. Trousers
    /// get a tighter bound because they cannot approach square in any cut.
    private static func impossible(for slot: GarmentSlot) -> Double {
        slot == .bottom ? 0.85 : 1.05
    }
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
            "outerwear", "puffer", "bomber", "trench", "raincoat", "overcoat", "gilet", "vest",
            // Found by the pairing tests: a blazer resolved to `.unknown`, which meant it
            // could never be put in a fit, never be suggested against anything, and never
            // count towards the wardrobe's outerwear. `overshirt` and `shacket` are the
            // same omission one layer down — both are outerwear whatever the name says, and
            // "shirt jacket" was already handled as a phrase for exactly this reason.
            "blazer", "blazers", "overshirt", "shacket", "varsity", "peacoat", "shearling"
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
            "polo", "longsleeve", "top", "tops", "tank", "jersey", "cardigan",
            // Read off a real wardrobe rather than guessed at. Palace names its hoodies
            // "P3 HOOD", and "fleece" — one of the most common things a streetwear brand
            // sells — was in no list at all, so both resolved to `.unknown` and were
            // invisible to fits, pairings and the wardrobe's own slot counts. A bare
            // "fleece" lands here; "Fleece Jacket" still lands on outerwear, because the
            // table is checked in slot order and outerwear comes first.
            "fleece", "fleeces", "hood", "henley", "rugby", "turtleneck", "thermal"
        ]),
        (.accessory, [
            "bag", "bags", "tote", "backpack", "belt", "belts", "sock", "socks", "scarf",
            "glove", "gloves", "wallet", "keychain", "sunglasses", "jewelry", "jewellery",
            "necklace", "ring", "bracelet", "accessory", "accessories",
            "crossbody", "pouch", "duffel", "duffle", "holdall", "cardholder"
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

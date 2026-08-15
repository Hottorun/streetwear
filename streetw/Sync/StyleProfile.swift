// StyleProfile.swift
// Derives a style profile from what the user has saved.
//
// Two sources, in a deliberate order. **What the photograph says wins** — `ImageTagger`
// reads a dominant colour and categories off the product shot, and that is a fact about
// the garment. The text vocabulary below is the fallback for anything not yet analysed,
// and it is genuinely a guess: a brand naming a shoe "Triple White" is describing a
// colourway, "Nocturne" describes nothing, and a link shared in from elsewhere may have
// a two-word title and no tags at all.
//
// The fallback stays because it works from save #1, before any image has been fetched.

import Foundation

struct StyleFacet: Identifiable, Hashable {
    var id: String { label }
    var label: String
    var count: Int
    var share: Double
}

/// One facet of the taste summary, as something you can *open*.
///
/// The taste block used to be four lines of nouns and a dead end — the app's own reading
/// of what you like, with nothing to do about it. A facet is really a query over the
/// collection, so it should behave like one.
///
/// The matching here deliberately mirrors how `StyleProfile.build` counted, including the
/// two-source order: what the photograph said, then the text vocabulary as the fallback.
/// If the two ever drift, a facet reading "Black · 12" opens onto nine items, which reads
/// as the count being wrong rather than as two different questions being asked.
struct CollectionFacet: Hashable, Identifiable {
    enum Axis: Hashable {
        case colour, category, silhouette, brand, pattern, tone
    }

    var axis: Axis
    var value: String

    var id: String { "\(axis)-\(value)" }

    func matches(_ save: SavedItem) -> Bool {
        guard let update = save.update else { return false }

        switch axis {
        case .brand:
            return update.brand?.name.caseInsensitiveCompare(value) == .orderedSame

        case .colour:
            // The accent counts as well as the dominant, matching how it was counted: a
            // collection filtered to "Red" that hides the black jacket with the red panel
            // has answered a narrower question than the one that was asked.
            if let seen = update.visionColor {
                return [seen, update.visionSecondaryColor]
                    .contains { $0?.caseInsensitiveCompare(value) == .orderedSame }
            }
            return haystack(of: update).contains(value.lowercased())

        case .category:
            if !update.visionCategories.isEmpty {
                return update.visionCategories.contains { $0.caseInsensitiveCompare(value) == .orderedSame }
            }
            let text = haystack(of: update)
            return Vocabulary.categories.contains { term, label in
                label.caseInsensitiveCompare(value) == .orderedSame && text.contains(term)
            }

        case .silhouette:
            // What the outline said, then the catalogue's own adjective. Same two-source
            // order as colour and category, and for the same reason: the photograph is a
            // fact and "relaxed fit" in a product title is a marketing decision.
            if let measured = update.visionSilhouette {
                return measured.caseInsensitiveCompare(value) == .orderedSame
            }
            return haystack(of: update).contains(value.lowercased())

        case .pattern:
            return StyleReading.pattern(of: update)?.caseInsensitiveCompare(value) == .orderedSame

        case .tone:
            return StyleReading.tones(of: update).contains {
                $0.caseInsensitiveCompare(value) == .orderedSame
            }
        }
    }

    private func haystack(of update: BrandUpdate) -> String {
        ([update.title, update.productType ?? ""] + update.tags)
            .joined(separator: " ")
            .lowercased()
    }
}

/// Turning `VisualReading`'s numbers into the words a profile is written in.
///
/// **One place, because two would drift**, and the symptom of drift here is specific and
/// bad: a facet reading "Graphic · 12" that opens onto nine items, which reads as the count
/// being broken rather than as two functions disagreeing about a threshold. `StyleProfile`
/// counts with these and `CollectionFacet` filters with these.
///
/// Every threshold below declines in the middle. Most garments are unremarkable on most
/// axes, and a profile that labels all of them has said nothing at length — the same
/// argument as `GenderClassifier.unknown` and `Silhouette`'s refusal band.
enum StyleReading {
    /// Whether this is doing any talking, and what kind.
    ///
    /// Text outranks busyness, because they answer different questions and the text answer
    /// is the more specific one: a chest wordmark on a plain hoodie is *logo*, not
    /// *graphic*, and calling it graphic would put it beside the all-over prints where it
    /// does not belong. Only one label per item, so nothing double-counts.
    static func pattern(of update: BrandUpdate) -> String? {
        guard update.visionVersion == VisualReading.version else { return nil }
        if update.visionTextCoverage >= logoCoverage { return "Logo" }
        if update.visionBusyness >= graphicBusyness { return "Graphic" }
        if update.visionBusyness <= plainBusyness && update.visionTextCoverage < logoCoverage {
            return "Plain"
        }
        return nil
    }

    /// How dark and how colourful, as words. An item can be both or neither.
    static func tones(of update: BrandUpdate) -> [String] {
        guard update.visionVersion == VisualReading.version else { return [] }
        var found: [String] = []
        if update.visionLightness <= darkLightness { found.append("Dark") }
        if update.visionLightness >= lightLightness { found.append("Light") }
        if update.visionSaturation <= mutedSaturation { found.append("Muted") }
        if update.visionSaturation >= vividSaturation { found.append("Vivid") }
        return found
    }

    /// Roughly a fifteenth of the frame given over to lettering. A chest print clears this
    /// comfortably; a small sleeve hit does not, and should not — a discreet logo is not
    /// what anybody means by logo-heavy.
    private static let logoCoverage = 0.07
    private static let graphicBusyness = 0.55
    private static let plainBusyness = 0.25

    private static let darkLightness = 0.3
    private static let lightLightness = 0.75
    private static let mutedSaturation = 0.18
    private static let vividSaturation = 0.45
}

struct StyleProfile {
    var colors: [StyleFacet] = []
    var categories: [StyleFacet] = []
    var silhouettes: [StyleFacet] = []
    var brands: [StyleFacet] = []
    /// Graphic, Logo, Plain — how loud the things you keep are.
    var patterns: [StyleFacet] = []
    /// Dark, Light, Muted, Vivid — the register a list of colour names cannot express.
    var tones: [StyleFacet] = []
    var totalSaves: Int = 0

    var isEmpty: Bool { totalSaves == 0 }

    static func build(from saves: [SavedItem]) -> StyleProfile {
        var profile = StyleProfile()
        profile.totalSaves = saves.count
        guard !saves.isEmpty else { return profile }

        var colors: [String: Int] = [:]
        var categories: [String: Int] = [:]
        var silhouettes: [String: Int] = [:]
        var brands: [String: Int] = [:]
        var patterns: [String: Int] = [:]
        var tones: [String: Int] = [:]

        for save in saves {
            guard let update = save.update else { continue }
            let haystack = ([update.title, update.productType ?? ""] + update.tags)
                .joined(separator: " ")
                .lowercased()

            // One colour per item either way, so an analysed save doesn't outvote an
            // unanalysed one purely by having a longer title. The accent counts too where
            // there is one — a black jacket with a red panel is a fact about both colours —
            // and `CollectionFacet.colour` matches on either for the same reason.
            if let seen = update.visionColor {
                colors[seen, default: 0] += 1
                if let accent = update.visionSecondaryColor, accent != seen {
                    colors[accent, default: 0] += 1
                }
            } else {
                for term in Vocabulary.colors where haystack.contains(term) {
                    colors[term.capitalized, default: 0] += 1
                }
            }

            if !update.visionCategories.isEmpty {
                for label in update.visionCategories {
                    categories[label, default: 0] += 1
                }
            } else {
                for (term, label) in Vocabulary.categories where haystack.contains(term) {
                    categories[label, default: 0] += 1
                }
            }

            // The outline first, the catalogue's adjective as the fallback — the same
            // two-source order as colour and category. A brand writes "relaxed" on
            // everything it makes; the photograph does not.
            if let measured = update.visionSilhouette {
                silhouettes[measured, default: 0] += 1
            } else {
                for term in Vocabulary.silhouettes where haystack.contains(term) {
                    silhouettes[term.capitalized, default: 0] += 1
                }
            }

            if let pattern = StyleReading.pattern(of: update) {
                patterns[pattern, default: 0] += 1
            }
            for tone in StyleReading.tones(of: update) {
                tones[tone, default: 0] += 1
            }

            if let name = update.brand?.name {
                brands[name, default: 0] += 1
            }
        }

        profile.colors = facets(from: colors)
        profile.categories = facets(from: categories)
        profile.silhouettes = facets(from: silhouettes)
        profile.brands = facets(from: brands)
        profile.patterns = facets(from: patterns)
        profile.tones = facets(from: tones)
        return profile
    }

    private static func facets(from counts: [String: Int]) -> [StyleFacet] {
        let total = counts.values.reduce(0, +)
        guard total > 0 else { return [] }
        return counts
            .map { StyleFacet(label: $0.key, count: $0.value, share: Double($0.value) / Double(total)) }
            .sorted { ($0.count, $1.label) > ($1.count, $0.label) }
    }
}

enum Vocabulary {
    static let colors = [
        "black", "white", "cream", "ecru", "bone", "grey", "gray", "charcoal",
        "navy", "blue", "indigo", "denim", "brown", "tan", "khaki", "olive",
        "green", "red", "burgundy", "maroon", "orange", "yellow", "pink",
        "purple", "beige", "sage", "washed", "tie-dye"
    ]

    /// Maps catalog vocabulary onto the categories a person actually thinks in.
    static let categories: [(String, String)] = [
        ("tee", "T-shirts"), ("t-shirt", "T-shirts"), ("shirt", "Shirts"),
        ("hoodie", "Hoodies"), ("sweat", "Sweats"), ("crewneck", "Sweats"),
        ("jacket", "Jackets"), ("coat", "Outerwear"), ("vest", "Outerwear"),
        ("pant", "Pants"), ("trouser", "Pants"), ("jean", "Denim"), ("denim", "Denim"),
        ("short", "Shorts"), ("cap", "Headwear"), ("hat", "Headwear"), ("beanie", "Headwear"),
        ("sneaker", "Sneakers"), ("shoe", "Footwear"), ("boot", "Footwear"),
        ("bag", "Bags"), ("accessor", "Accessories"), ("knit", "Knitwear"), ("sweater", "Knitwear")
    ]

    static let silhouettes = [
        "oversized", "relaxed", "straight", "slim", "baggy", "wide", "cropped",
        "boxy", "tapered", "regular"
    ]
}

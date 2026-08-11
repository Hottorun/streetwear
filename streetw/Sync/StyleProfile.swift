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

struct StyleProfile {
    var colors: [StyleFacet] = []
    var categories: [StyleFacet] = []
    var silhouettes: [StyleFacet] = []
    var brands: [StyleFacet] = []
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

        for save in saves {
            guard let update = save.update else { continue }
            let haystack = ([update.title, update.productType ?? ""] + update.tags)
                .joined(separator: " ")
                .lowercased()

            // One colour per item either way, so an analysed save doesn't outvote an
            // unanalysed one purely by having a longer title.
            if let seen = update.visionColor {
                colors[seen, default: 0] += 1
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
            for term in Vocabulary.silhouettes where haystack.contains(term) {
                silhouettes[term.capitalized, default: 0] += 1
            }
            if let name = update.brand?.name {
                brands[name, default: 0] += 1
            }
        }

        profile.colors = facets(from: colors)
        profile.categories = facets(from: categories)
        profile.silhouettes = facets(from: silhouettes)
        profile.brands = facets(from: brands)
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

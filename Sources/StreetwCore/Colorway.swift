// Colorway.swift
// The colour axis, which the catalogue has always carried and the app has always thrown
// away.
//
// `ShopifySource` already reads the option axis actually named "Color" into
// `VariantInfo.color` — from the axis, not parsed out of a joined title like
// "WHITE/OWHITE/CBROWN / 9". Nothing has ever displayed it. Grouping by it costs no
// extra fetching and answers the question a product shot can't: does this come in black.
//
// The swatch table is deliberately approximate. It exists so a row of colourways reads as
// colour at a glance; the *name* underneath is the authority, and anything unrecognised
// renders as a named chip rather than as a wrong colour.

import Foundation

/// One colour a product comes in, with what's buyable in it.
public struct Colorway: Hashable, Sendable, Identifiable {
    /// As the storefront writes it — "Vintage Black", "WHITE/OWHITE/CBROWN".
    public var name: String
    /// Buyable in at least one size.
    public var isAvailable: Bool
    /// Sizes currently in stock in this colour, in the order the catalogue listed them.
    public var availableSizes: [String]
    /// Every size this colour is cut in, in stock or not.
    public var allSizes: [String]

    public var id: String { name }

    public init(name: String, isAvailable: Bool, availableSizes: [String], allSizes: [String]) {
        self.name = name
        self.isAvailable = isAvailable
        self.availableSizes = availableSizes
        self.allSizes = allSizes
    }
}

public enum Colorways {
    /// Groups variants by their colour axis, preserving catalogue order.
    ///
    /// Returns empty for a product with no colour axis, which is most of them — a single
    /// colourway is not information, and a row showing one swatch is worse than no row.
    public static func from(_ variants: [VariantInfo]) -> [Colorway] {
        var order: [String] = []
        var grouped: [String: [VariantInfo]] = [:]

        for variant in variants {
            guard let color = variant.color?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !color.isEmpty,
                  color != "Default Title"
            else { continue }
            if grouped[color] == nil { order.append(color) }
            grouped[color, default: []].append(variant)
        }

        guard order.count > 1 else { return [] }

        return order.compactMap { name in
            guard let group = grouped[name] else { return nil }
            let sized = group.filter(\.isMeaningfulSize)
            return Colorway(
                name: name,
                isAvailable: group.contains { $0.available },
                availableSizes: sized.filter(\.available).map(\.displaySize),
                allSizes: sized.map(\.displaySize)
            )
        }
    }
}

/// An approximate RGB for a colour name, so a colourway can be shown as a colour.
public struct SwatchColor: Hashable, Sendable {
    public var red: Double
    public var green: Double
    public var blue: Double

    public init(_ red: Double, _ green: Double, _ blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    /// Very light swatches need an outline or they vanish against the paper background.
    public var isPale: Bool { (red + green + blue) / 3 > 0.85 }
}

public enum ColorSwatch {
    /// Ordered longest-first so "off white" is tested before "white" and "vintage black"
    /// resolves on "black" rather than tripping over a shorter accidental match.
    private static let table: [(name: String, color: SwatchColor)] = [
        ("off white", SwatchColor(0.94, 0.93, 0.89)),
        ("offwhite", SwatchColor(0.94, 0.93, 0.89)),
        ("owhite", SwatchColor(0.94, 0.93, 0.89)),
        ("turquoise", SwatchColor(0.25, 0.71, 0.68)),
        ("burgundy", SwatchColor(0.40, 0.10, 0.16)),
        ("charcoal", SwatchColor(0.24, 0.24, 0.25)),
        ("lavender", SwatchColor(0.71, 0.64, 0.82)),
        ("mustard", SwatchColor(0.83, 0.65, 0.16)),
        ("magenta", SwatchColor(0.78, 0.16, 0.52)),
        ("crimson", SwatchColor(0.72, 0.11, 0.19)),
        ("natural", SwatchColor(0.90, 0.86, 0.78)),
        ("oatmeal", SwatchColor(0.85, 0.80, 0.71)),
        ("emerald", SwatchColor(0.14, 0.54, 0.35)),
        ("scarlet", SwatchColor(0.85, 0.16, 0.14)),
        ("mahogany", SwatchColor(0.35, 0.18, 0.13)),
        ("chocolate", SwatchColor(0.29, 0.19, 0.14)),
        ("espresso", SwatchColor(0.23, 0.16, 0.13)),
        ("burnt", SwatchColor(0.60, 0.28, 0.13)),
        ("maroon", SwatchColor(0.40, 0.12, 0.18)),
        ("indigo", SwatchColor(0.22, 0.24, 0.44)),
        ("orange", SwatchColor(0.88, 0.45, 0.13)),
        ("purple", SwatchColor(0.44, 0.28, 0.60)),
        ("yellow", SwatchColor(0.92, 0.79, 0.22)),
        ("silver", SwatchColor(0.75, 0.75, 0.76)),
        ("forest", SwatchColor(0.13, 0.29, 0.19)),
        ("cherry", SwatchColor(0.71, 0.13, 0.20)),
        ("copper", SwatchColor(0.72, 0.45, 0.20)),
        ("walnut", SwatchColor(0.36, 0.25, 0.18)),
        ("violet", SwatchColor(0.55, 0.36, 0.72)),
        ("cobalt", SwatchColor(0.13, 0.31, 0.66)),
        ("denim", SwatchColor(0.33, 0.42, 0.55)),
        ("khaki", SwatchColor(0.68, 0.63, 0.47)),
        ("beige", SwatchColor(0.85, 0.79, 0.68)),
        ("brown", SwatchColor(0.42, 0.29, 0.20)),
        ("cream", SwatchColor(0.95, 0.92, 0.84)),
        ("olive", SwatchColor(0.42, 0.42, 0.24)),
        ("green", SwatchColor(0.24, 0.50, 0.30)),
        ("black", SwatchColor(0.09, 0.09, 0.09)),
        ("white", SwatchColor(0.97, 0.97, 0.96)),
        ("ivory", SwatchColor(0.95, 0.93, 0.87)),
        ("camel", SwatchColor(0.76, 0.60, 0.42)),
        ("stone", SwatchColor(0.78, 0.75, 0.69)),
        ("slate", SwatchColor(0.42, 0.46, 0.51)),
        ("navy", SwatchColor(0.11, 0.16, 0.31)),
        ("royal", SwatchColor(0.16, 0.28, 0.66)),
        ("sand", SwatchColor(0.84, 0.77, 0.63)),
        ("taupe", SwatchColor(0.63, 0.57, 0.51)),
        ("wine", SwatchColor(0.40, 0.13, 0.21)),
        ("rust", SwatchColor(0.65, 0.32, 0.16)),
        ("sage", SwatchColor(0.62, 0.68, 0.57)),
        ("mint", SwatchColor(0.65, 0.85, 0.75)),
        ("teal", SwatchColor(0.18, 0.49, 0.51)),
        ("gold", SwatchColor(0.80, 0.66, 0.29)),
        ("rose", SwatchColor(0.85, 0.60, 0.62)),
        ("lilac", SwatchColor(0.78, 0.70, 0.85)),
        ("bone", SwatchColor(0.91, 0.88, 0.81)),
        ("ecru", SwatchColor(0.90, 0.87, 0.79)),
        ("grey", SwatchColor(0.55, 0.55, 0.54)),
        ("gray", SwatchColor(0.55, 0.55, 0.54)),
        ("pink", SwatchColor(0.90, 0.68, 0.74)),
        ("blue", SwatchColor(0.24, 0.42, 0.72)),
        ("red", SwatchColor(0.75, 0.16, 0.16)),
        ("tan", SwatchColor(0.78, 0.66, 0.50))
    ]

    /// Best-effort RGB for a colourway name, or nil when nothing is recognisable.
    ///
    /// Nil is a normal outcome and must stay one: brands name colourways things like
    /// "Nocturne" or "Chapter 3", and a made-up swatch is worse than none — it asserts a
    /// colour the garment may not be. Callers render the name instead.
    public static func rgb(for name: String) -> SwatchColor? {
        let lowered = name.lowercased()

        // Multi-colour names ("WHITE/OWHITE/CBROWN") describe a colourway with a leading
        // colour. Take the first segment that resolves, which is the one a shop would
        // print first and the one the garment mostly is.
        for segment in lowered.split(whereSeparator: { "/,&+".contains($0) }) {
            if let match = firstMatch(in: String(segment)) { return match }
        }
        return firstMatch(in: lowered)
    }

    private static func firstMatch(in text: String) -> SwatchColor? {
        table.first { text.contains($0.name) }?.color
    }
}

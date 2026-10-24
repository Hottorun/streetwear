// WatchMatching.swift
// Deciding whether a restock is the one somebody asked to be told about.
//
// In the portable layer for the same reason `SizeMatching` is: both ends need exactly
// this answer. The phone evaluates it against its own SwiftData copy so a watch still
// works in standalone mode, and the server evaluates it against Postgres so the alert
// arrives when the app is closed — which is the whole point of a watch. Two
// implementations of "does this variant satisfy this watch" would drift, and the symptom
// would be an alert that fires on one path and not the other.

import Foundation

/// A watch's pins. Nil means "don't care", which is the default on both axes.
public struct WatchTarget: Hashable, Sendable, Codable {
    /// Raw catalogue text rather than a normalised token, so the UI can echo back exactly
    /// what the storefront calls it. Normalisation happens at comparison time.
    public var size: String?
    public var color: String?

    public init(size: String? = nil, color: String? = nil) {
        self.size = size?.isEmpty == true ? nil : size
        self.color = color?.isEmpty == true ? nil : color
    }

    public var isAnySize: Bool { size == nil }
    public var isAnyColor: Bool { color == nil }

    /// How the watch reads in a list: "M · Black", "US 9", "Any size or colour".
    public var summary: String {
        let parts = [size, color].compactMap { $0 }
        return parts.isEmpty ? "Any size or colour" : parts.joined(separator: " · ")
    }

    /// Whether one variant satisfies both pins.
    ///
    /// Size goes through `SizeNormalizer`, so a watch on "M" matches a variant the
    /// catalogue writes as "Medium", a watch on "9.5" matches "US 9.5" and one on "40R"
    /// matches "40 Regular". Colour is compared case-insensitively on the raw string —
    /// colourway names are brand vocabulary with no canonical form to normalise to, and
    /// "Vintage Black" is genuinely not "Black".
    ///
    /// Compared on the **label**, not the token. Both sides are sizes of the same product,
    /// printed in the same scale, so there is nothing to convert — and converting anyway
    /// is lossy: "EU 41" and "EU 41.5" both land on a US 8, so a watch on one fired when
    /// the other came back.
    ///
    /// - Parameter context: the product's, so a "38" is read on the same ladder the size
    ///   run reads it on.
    public func matches(_ variant: VariantInfo, in context: SizeContext) -> Bool {
        if let size {
            guard let wanted = SizeNormalizer.normalize(size, in: context),
                  let actual = SizeNormalizer.normalize(variant.displaySize, in: context),
                  wanted.kind == actual.kind,
                  wanted.label == actual.label
            else { return false }
        }
        if let color {
            guard variant.color?.caseInsensitiveCompare(color) == .orderedSame else { return false }
        }
        return true
    }

    /// The variants this watch is about, in stock or not.
    public func matching(_ variants: [VariantInfo], in context: SizeContext) -> [VariantInfo] {
        variants.filter { matches($0, in: context) }
    }

    /// Whether anything this watch cares about is buyable right now.
    public func isSatisfied(by variants: [VariantInfo], in context: SizeContext) -> Bool {
        variants.contains { $0.available && matches($0, in: context) }
    }

    /// The sizes that are actually buyable and match — what a notification should name.
    public func availableSizes(in variants: [VariantInfo], context: SizeContext) -> [String] {
        matching(variants, in: context)
            .filter(\.available)
            .map(\.displaySize)
            .filter { $0 != "Default Title" && !$0.isEmpty }
    }
}

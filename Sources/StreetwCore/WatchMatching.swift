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
    /// catalogue writes as "Medium" and a watch on "9.5" matches "US 9.5". Colour is
    /// compared case-insensitively on the raw string — colourway names are brand
    /// vocabulary with no canonical form to normalise to, and "Vintage Black" is genuinely
    /// not "Black".
    public func matches(_ variant: VariantInfo) -> Bool {
        if let size {
            guard let wanted = SizeNormalizer.normalize(size),
                  let actual = SizeNormalizer.normalize(variant.displaySize),
                  wanted.token == actual.token
            else { return false }
        }
        if let color {
            guard variant.color?.caseInsensitiveCompare(color) == .orderedSame else { return false }
        }
        return true
    }

    /// The variants this watch is about, in stock or not.
    public func matching(_ variants: [VariantInfo]) -> [VariantInfo] {
        variants.filter(matches)
    }

    /// Whether anything this watch cares about is buyable right now.
    public func isSatisfied(by variants: [VariantInfo]) -> Bool {
        variants.contains { $0.available && matches($0) }
    }

    /// The sizes that are actually buyable and match — what a notification should name.
    public func availableSizes(in variants: [VariantInfo]) -> [String] {
        matching(variants)
            .filter(\.available)
            .map(\.displaySize)
            .filter { $0 != "Default Title" && !$0.isEmpty }
    }
}

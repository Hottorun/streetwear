// SizeMatching.swift
// Normalising the mess of real-world size strings, and deciding whether a variant
// is one the user could actually wear.
//
// Lives in the portable layer on purpose: the server needs exactly this logic to
// decide who a restock notification should go to.

import Foundation

public enum SizeKind: String, Codable, Sendable, CaseIterable {
    case apparel
    case shoe
    case oneSize
    case other
}

public struct NormalizedSize: Hashable, Sendable {
    public var kind: SizeKind
    /// Canonical form: "M", "XXL", "9.5". Compare on this, never on the raw string.
    public var token: String
}

public enum SizeNormalizer {
    private static let apparelWords: [String: String] = [
        "xxs": "XXS", "xs": "XS", "extra small": "XS",
        "s": "S", "small": "S",
        "m": "M", "medium": "M",
        "l": "L", "large": "L",
        "xl": "XL", "extra large": "XL",
        "xxl": "XXL", "2xl": "XXL",
        "xxxl": "XXXL", "3xl": "XXXL",
        "4xl": "4XL"
    ]

    private static let oneSizeWords: Set<String> = [
        "os", "o/s", "one size", "onesize", "os fits all", "default title", "one size fits all"
    ]

    public static func normalize(_ raw: String) -> NormalizedSize? {
        let cleaned = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !cleaned.isEmpty else { return nil }

        if oneSizeWords.contains(cleaned) {
            return NormalizedSize(kind: .oneSize, token: "OS")
        }
        if let apparel = apparelWords[cleaned] {
            return NormalizedSize(kind: .apparel, token: apparel)
        }

        // Shoes: "9", "9.5", "US 9", "9 US", "US9". No word boundary after the region
        // code — "us9" is common and would otherwise fall through.
        let stripped = cleaned
            .replacingOccurrences(
                of: #"(^|\s)(us|uk|eu|eur|men'?s|women'?s|w)\s*"#,
                with: "",
                options: .regularExpression
            )
            .replacingOccurrences(of: #"\s*(us|uk|eu|eur)$"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)

        if let value = Double(stripped) {
            // Only plausible US sizes count as shoes. EU sizing ("44") and waist sizes
            // ("32") must fall through to `.other` — classing them as US shoes would let
            // a US-9 profile *hide* them, which is the one outcome the filter must never
            // produce.
            guard (3.0...18.0).contains(value) else {
                return NormalizedSize(kind: .other, token: stripped)
            }
            let token = value == value.rounded()
                ? String(Int(value))
                : String(format: "%.1f", value)
            return NormalizedSize(kind: .shoe, token: token)
        }

        return NormalizedSize(kind: .other, token: cleaned.uppercased())
    }
}

/// The sizes a person actually wears. Empty means "no preference" — everything matches,
/// so the feature stays invisible until it's filled in.
public struct SizeProfile: Codable, Hashable, Sendable {
    public var apparel: Set<String> = []
    public var shoe: Set<String> = []
    /// One-size items fit everyone; excluding them would hide most accessories.
    public var includeOneSize: Bool = true

    public init() {}

    public static let apparelOptions = ["XXS", "XS", "S", "M", "L", "XL", "XXL", "XXXL"]
    public static let shoeOptions: [String] = stride(from: 6.0, through: 14.0, by: 0.5).map {
        $0 == $0.rounded() ? String(Int($0)) : String(format: "%.1f", $0)
    }

    public var isEmpty: Bool { apparel.isEmpty && shoe.isEmpty }

    public var summary: String {
        var parts: [String] = []
        if !apparel.isEmpty {
            parts.append(SizeProfile.apparelOptions.filter(apparel.contains).joined(separator: ", "))
        }
        if !shoe.isEmpty {
            parts.append("US " + SizeProfile.shoeOptions.filter(shoe.contains).joined(separator: ", "))
        }
        return parts.isEmpty ? "Not set" : parts.joined(separator: " · ")
    }

    public func matches(_ raw: String) -> Bool {
        guard !isEmpty else { return true }
        guard let size = SizeNormalizer.normalize(raw) else { return true }

        switch size.kind {
        case .apparel: return apparel.contains(size.token)
        case .shoe: return shoe.contains(size.token)
        case .oneSize: return includeOneSize
        // Unrecognised sizing (a brand's own scale, "44", "Youth L"): don't hide it,
        // a false positive is much cheaper than a missed drop.
        case .other: return true
        }
    }

    public func matches(_ variant: VariantInfo) -> Bool {
        matches(variant.displaySize)
    }
}

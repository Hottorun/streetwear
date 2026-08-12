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

/// The regional scale a size was written in.
///
/// Only meaningful for shoes. Storage stays canonically US everywhere — the profile, the
/// wire format and every comparison — and this exists so a European can *read and pick*
/// sizes in the scale they actually wear without the stored value becoming ambiguous.
public enum SizeScale: String, Codable, Sendable, CaseIterable, Identifiable {
    case us
    case uk
    case eu

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .us: "US"
        case .uk: "UK"
        case .eu: "EU"
        }
    }
}

public struct NormalizedSize: Hashable, Sendable {
    public var kind: SizeKind
    /// Canonical form: "M", "XXL", "9.5". Compare on this, never on the raw string.
    /// Shoe tokens are **always US**, whatever scale the raw string used.
    public var token: String
    /// The scale the raw string was written in, before conversion.
    public var scale: SizeScale = .us

    /// True when `token` came out of a scale conversion rather than being read directly.
    ///
    /// Worth carrying because conversion tables are brand-specific — Nike and adidas
    /// disagree by half a size on the same foot — so a converted size is a *good
    /// estimate*, not a fact, and matching treats it with a tolerance that an exact US
    /// size doesn't get.
    public var isConverted: Bool { kind == .shoe && scale != .us }
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
        // `shortened` spells a digit multiplier out as that many X's, so the long form
        // "4XLarge" arrives here as "xxxxl" rather than as "4xl".
        "4xl": "4XL", "xxxxl": "4XL"
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
        if let apparel = apparelWords[cleaned] ?? apparelWords[shortened(cleaned)] {
            return NormalizedSize(kind: .apparel, token: apparel)
        }

        // Which scale did the string announce? Read *before* stripping, because the
        // region code is the entire difference between a UK 9 and a US 9 — two sizes
        // that are a full size apart on the same foot. Previously both codes were
        // stripped and the remainder taken as US, so a UK 9 was highlighted as the
        // user's US 9 when it is really a US 10.
        let scale = declaredScale(in: cleaned)

        // Shoes: "9", "9.5", "US 9", "9 US", "US9". No word boundary after the region
        // code — "us9" is common and would otherwise fall through.
        // Longest alternative first, always. Regex alternation takes the first branch
        // that matches, so with `eu` ahead of `eur` the string "eur 43" loses only the
        // "eu" and the leftover "r 43" parses as nothing — silently demoting a size we
        // can read perfectly well to `.other`.
        let stripped = cleaned
            .replacingOccurrences(
                of: #"(^|\s)(eur|us|uk|eu|men'?s|women'?s|w)\s*"#,
                with: "",
                options: .regularExpression
            )
            .replacingOccurrences(of: #"\s*(eur|us|uk|eu)$"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)

        if let value = Double(stripped) {
            // A number with no region code is only a shoe if it falls in the US range.
            // A bare "44" stays `.other`: it is just as likely an EU shoe, an EU jacket
            // or a waist measurement, and guessing wrong here would *hide* a product,
            // which is the one outcome this filter must never produce. Only an explicit
            // "EU 44" is converted, because only then do we actually know the scale.
            guard let us = ShoeSizes.toUS(value, from: scale) else {
                return NormalizedSize(kind: .other, token: stripped, scale: scale)
            }
            return NormalizedSize(kind: .shoe, token: ShoeSizes.token(us), scale: scale)
        }

        return NormalizedSize(kind: .other, token: cleaned.uppercased(), scale: scale)
    }

    /// "XXLarge" → "xxl", so the table above only has to know the short forms.
    ///
    /// Half a brand's run being readable is worse than none of it, because the failure is
    /// invisible: YoungLA writes `XXSmall, XSmall, Small, Medium, Large, XLarge, XXLarge`,
    /// and only the three bare words were in the table. Every extremity fell through to
    /// `.other` — never hidden, per the rule, but never *matched* either, so someone whose
    /// profile says XL saw a run in which their size was the one token not ruled in
    /// vermilion, on every product the brand makes.
    ///
    /// Only an all-`x` prefix (or the `2x`/`3x` shorthand for one) is accepted. A prefix
    /// this doesn't recognise — "petite small", "junior large" — falls through unchanged
    /// and stays `.other`, which is the right answer: those are not the same garment as an
    /// S, and quietly matching them to one would put the wrong size in somebody's feed.
    private static func shortened(_ cleaned: String) -> String {
        let compact = cleaned
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "-", with: "")
            // "extra large" and "xlarge" are the same garment spelled two ways, and both
            // turn up in the same catalogue.
            .replacingOccurrences(of: "extra", with: "x")

        guard let base = ["small": "s", "medium": "m", "large": "l"]
            .first(where: { compact.hasSuffix($0.key) })
        else { return cleaned }

        var prefix = String(compact.dropLast(base.key.count))

        // "2xlarge" is two X's, "3xlarge" is three — the digit is a count, not a size.
        if let first = prefix.first, let count = Int(String(first)), prefix.dropFirst() == "x" {
            prefix = String(repeating: "x", count: count)
        }

        guard prefix.allSatisfy({ $0 == "x" }) else { return cleaned }
        return prefix + base.value
    }

    /// The scale a raw size string names, if it names one at all.
    private static func declaredScale(in cleaned: String) -> SizeScale {
        // Anchored to a word boundary or the start so a stray "uk" inside a colourway
        // ("Ukiyo") can't be read as a region code.
        func mentions(_ pattern: String) -> Bool {
            cleaned.range(of: pattern, options: .regularExpression) != nil
        }
        if mentions(#"(^|\s)(eur?)\s*\d"#) || mentions(#"\d\s*(eur?)($|\s)"#) { return .eu }
        if mentions(#"(^|\s)uk\s*\d"#) || mentions(#"\d\s*uk($|\s)"#) { return .uk }
        return .us
    }
}

/// Converting between shoe scales.
///
/// The table is the one Nike publishes, which is also what most of the storefronts we
/// watch use. It is *not* universal — adidas runs half a size off it — which is why
/// `NormalizedSize.isConverted` exists and why matching gives converted sizes a half-size
/// tolerance rather than pretending the arithmetic is exact.
public enum ShoeSizes {
    /// (US, UK, EU), men's.
    static let table: [(us: Double, uk: Double, eu: Double)] = [
        (6, 5, 38.5), (6.5, 5.5, 39), (7, 6, 40), (7.5, 6.5, 40.5),
        (8, 7, 41), (8.5, 7.5, 42), (9, 8, 42.5), (9.5, 8.5, 43),
        (10, 9, 44), (10.5, 9.5, 44.5), (11, 10, 45), (11.5, 10.5, 45.5),
        (12, 11, 46), (12.5, 11.5, 47), (13, 12, 47.5), (14, 13, 48.5)
    ]

    /// Plausible US sizes. Anything outside is not a shoe size at all.
    static let usRange = 3.0...18.0

    /// Converts a raw number in `scale` to its US equivalent, or nil when the number
    /// cannot be a shoe size on that scale.
    public static func toUS(_ value: Double, from scale: SizeScale) -> Double? {
        switch scale {
        case .us:
            return usRange.contains(value) ? value : nil
        case .uk:
            // UK runs a full size below US on this table, including outside it.
            let us = value + 1
            return usRange.contains(us) ? us : nil
        case .eu:
            guard let nearest = table.min(by: {
                abs($0.eu - value) < abs($1.eu - value)
            }) else { return nil }
            // Off the end of the table, extrapolate rather than clamping — clamping
            // would silently call an EU 52 a US 14.
            if abs(nearest.eu - value) > 1 {
                let us = value - 33.5
                return usRange.contains(us) ? us : nil
            }
            return nearest.us
        }
    }

    /// Converts a canonical US size into `scale`, for display.
    public static func fromUS(_ us: Double, to scale: SizeScale) -> Double {
        switch scale {
        case .us: return us
        case .uk: return us - 1
        case .eu:
            guard let nearest = table.min(by: { abs($0.us - us) < abs($1.us - us) }),
                  abs(nearest.us - us) <= 0.5
            else { return us + 33.5 }
            return nearest.eu
        }
    }

    /// "9" not "9.0", "9.5" not "9.50" — the way a size run is printed.
    public static func token(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(format: "%.1f", value)
    }
}

/// The sizes a person actually wears. Empty means "no preference" — everything matches,
/// so the feature stays invisible until it's filled in.
public struct SizeProfile: Codable, Hashable, Sendable {
    public var apparel: Set<String> = []
    /// Always stored as **US** tokens, whatever scale the user picks to read them in.
    /// One canonical form means `shoeScale` is a display preference that can be changed
    /// at any time without rewriting what is stored or re-sending anything to the server.
    public var shoe: Set<String> = []
    /// The scale the user reads and picks shoe sizes in. Display only.
    public var shoeScale: SizeScale = .us
    /// Which genders belong in this person's feed. Lives here rather than in its own
    /// store because it travels with the sizes everywhere they already go — the wire
    /// payload, the server's targeting, the feed filter — and splitting it would mean
    /// duplicating all three.
    public var gender: GenderPreference = .everything

    public init() {}

    /// Decodes leniently for the same reason `BrandSource` does: a profile written
    /// before `shoeScale` existed is sitting in `UserDefaults` on a real phone, and a
    /// non-optional decode of a missing key throws rather than defaulting.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        apparel = try container.decodeIfPresent(Set<String>.self, forKey: .apparel) ?? []
        shoe = try container.decodeIfPresent(Set<String>.self, forKey: .shoe) ?? []
        shoeScale = try container.decodeIfPresent(SizeScale.self, forKey: .shoeScale) ?? .us
        gender = try container.decodeIfPresent(GenderPreference.self, forKey: .gender) ?? .everything
    }

    /// Whether `gender` would hide this item. Separate from `matches` because the two
    /// filters answer different questions and an empty size profile must not disable the
    /// gender one.
    public func allows(_ gender: Gender) -> Bool {
        self.gender.allows(gender)
    }

    public static let apparelOptions = ["XXS", "XS", "S", "M", "L", "XL", "XXL", "XXXL"]
    /// The canonical US ladder. Everything stored in `shoe` is one of these.
    public static let shoeOptions: [String] = stride(from: 6.0, through: 14.0, by: 0.5)
        .map(ShoeSizes.token)

    /// The ladder as `scale` prints it, paired with the US token each entry stores.
    /// The picker walks this so a European taps "43" and the profile records "9.5".
    public static func shoeOptions(in scale: SizeScale) -> [(display: String, stored: String)] {
        stride(from: 6.0, through: 14.0, by: 0.5).map { us in
            (ShoeSizes.token(ShoeSizes.fromUS(us, to: scale)), ShoeSizes.token(us))
        }
    }

    public var isEmpty: Bool { apparel.isEmpty && shoe.isEmpty }

    public var summary: String {
        var parts: [String] = []
        if !apparel.isEmpty {
            parts.append(SizeProfile.apparelOptions.filter(apparel.contains).joined(separator: ", "))
        }
        if !shoe.isEmpty {
            // Printed in the user's own scale — "EU 43" reads as a size to someone who
            // wears it, where "US 9.5" is a sum they have to do.
            let shown = SizeProfile.shoeOptions(in: shoeScale)
                .filter { shoe.contains($0.stored) }
                .map(\.display)
            parts.append("\(shoeScale.label) " + shown.joined(separator: ", "))
        }
        return parts.isEmpty ? "Not set" : parts.joined(separator: " · ")
    }

    public func matches(_ raw: String) -> Bool {
        guard !isEmpty else { return true }
        guard let size = SizeNormalizer.normalize(raw) else { return true }

        switch size.kind {
        case .apparel: return apparel.contains(size.token)
        case .shoe:
            guard !size.isConverted else { return matchesConvertedShoe(size.token) }
            return shoe.contains(size.token)
        // A one-size item fits everyone by definition, so there was never a real reason to
        // exclude it — and the toggle that could was one more thing to explain in exchange
        // for hiding most of the accessories in the feed.
        case .oneSize: return true
        // Unrecognised sizing (a brand's own scale, a bare "44", "Youth L"): don't hide
        // it, a false positive is much cheaper than a missed drop.
        case .other: return true
        }
    }

    /// A converted size matches anything within half a size.
    ///
    /// Brand conversion tables genuinely disagree by that much — a foot that is a US 9
    /// in Nike is a US 8.5 in adidas — so demanding an exact hit after a conversion would
    /// hide real results, and this filter is built to never do that. Half a size is the
    /// width of the disagreement, not a guess: it is one rung of the ladder.
    private func matchesConvertedShoe(_ token: String) -> Bool {
        guard let value = Double(token) else { return true }
        return shoe.contains { mine in
            guard let owned = Double(mine) else { return false }
            return abs(owned - value) <= 0.5
        }
    }

    public func matches(_ variant: VariantInfo) -> Bool {
        matches(variant.displaySize)
    }
}

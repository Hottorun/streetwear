// SizeMatching.swift
// Normalising the mess of real-world size strings, and deciding whether a variant
// is one the user could actually wear.
//
// Lives in the portable layer on purpose: the server needs exactly this logic to
// decide who a restock notification should go to.

import Foundation
import Synchronization

public enum SizeKind: String, Codable, Sendable, CaseIterable {
    case apparel
    case shoe
    /// Bottoms sized by the inch: "32", "W34", "32x30".
    ///
    /// Its own kind rather than a flavour of `apparel` because the ladders don't meet — a
    /// 32 is not an M, no table converts between them, and a person wears one of each.
    /// Without it, every pair of trousers in the app normalised to `.other`, which is
    /// never hidden *and never matched*: on denim and workwear — half of what these
    /// brands make — the size feature was simply switched off.
    case waist
    /// Women's numeric clothing — "dress size", which is what the ladder is called on a
    /// blouse or a skirt as much as on a dress. Stored as US tokens, the way shoes are.
    ///
    /// Read only where the garment says it is one. Before it existed a US 4–18 was taken
    /// for a US shoe and "UK 10" for a UK shoe, so somebody who had entered a shoe size had
    /// dresses ruled in vermilion as hers by a ladder that had nothing to do with them.
    case dress
    /// Men's tailoring: a chest in inches, with the jacket's length when the run names one
    /// ("40R", "42 Long"). European and Italian jacket sizes convert onto it.
    case suit
    case oneSize
    case other
}

/// The regional scale a size was written in.
///
/// Meaningful for shoes, dress sizes and suits. Storage stays canonical everywhere — US for
/// shoes and dresses, chest inches for suits — in the profile, the wire format and every
/// comparison, and this exists so a European can *read and pick* sizes in the scale they
/// actually wear without the stored value becoming ambiguous.
public enum SizeScale: String, Codable, Sendable, CaseIterable, Identifiable {
    case us
    case uk
    /// European, which for women's clothing is the French ladder ("FR" is read as this).
    case eu
    /// Italian. A ladder of its own for women's clothing, two rungs above French; for
    /// tailoring it is the European ladder under another name.
    case it

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .us: "US"
        case .uk: "UK"
        case .eu: "EU"
        case .it: "IT"
        }
    }

    /// Nobody sells a shoe in Italian sizes that are not the European ones, so the shoe
    /// picker offers only the three that differ.
    public static let shoeScales: [SizeScale] = [.us, .uk, .eu]
    public static let dressScales: [SizeScale] = [.us, .uk, .eu, .it]
    /// Two, because a US and a UK chest are the same number of inches and an Italian
    /// jacket is a European one.
    public static let suitScales: [SizeScale] = [.us, .eu]

    /// How the suit picker names a scale — each choice stands for two of them.
    public var suitLabel: String {
        switch self {
        case .us, .uk: "US · UK"
        case .eu, .it: "EU · IT"
        }
    }
}

public struct NormalizedSize: Hashable, Sendable {
    public var kind: SizeKind
    /// Canonical form: "M", "XXL", "9.5", "40R". Compare a size against a *profile* on
    /// this, never on the raw string. Shoe and dress tokens are **always US**, and a suit's
    /// is the chest in inches, whatever scale the raw string used.
    public var token: String
    /// The scale the raw string was written in, before conversion.
    public var scale: SizeScale = .us
    /// The number in the shop's own scale, when `token` had to be converted away from it:
    /// "44" for "EU 44". Nil when the token already is what the shop printed.
    public var written: String?
    /// A suit's length — "S", "R" or "L" — when the run names one. Already part of `token`.
    public var length: String?

    public init(
        kind: SizeKind,
        token: String,
        scale: SizeScale = .us,
        written: String? = nil,
        length: String? = nil
    ) {
        self.kind = kind
        self.token = token
        self.scale = scale
        self.written = written
        self.length = length
    }

    /// True when `token` came out of a scale conversion rather than being read directly.
    ///
    /// Worth carrying because conversion tables are brand-specific — Nike and adidas
    /// disagree by half a size on the same foot — so a converted size is a *good
    /// estimate*, not a fact, and matching treats it with a tolerance that an exact US
    /// size doesn't get. A UK chest is not a conversion: it is the same number of inches.
    public var isConverted: Bool {
        switch kind {
        case .shoe, .dress: scale != .us
        case .suit: scale == .eu || scale == .it
        case .apparel, .waist, .oneSize, .other: false
        }
    }

    /// The size the way the shop printed it, tidied: the canonical token when nothing was
    /// converted, the number in the shop's own scale when something was.
    ///
    /// **What a size run prints, and what two sizes of one product are compared on.** The
    /// token is for comparing against a person; the label is for comparing a product's
    /// sizes with each other. Converting both sides of "EU 41" and "EU 41.5" lands them on
    /// the same US 8, so a run keyed on the token printed one of them and dropped the other,
    /// and a watch on the 41.5 fired when the 41 came back.
    public var label: String { written ?? token }

    /// A suit's chest without its length: "40" for "40R".
    var chest: String { length == nil ? token : String(token.dropLast()) }
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

    /// Answers already worked out, keyed on the cleaned string.
    ///
    /// **This is the hot path of the whole app and it is regular expressions all the way
    /// down.** Measured: an apparel size costs 0.3µs because the word table answers it
    /// before any regex runs, while a shoe size costs 17µs and a multi-axis variant title
    /// ("WHITE/OWHITE/CBROWN / 5", which is what `displaySize` returns whenever a source
    /// publishes no size axis) costs 26µs — up to eight `NSRegularExpression`s compiled
    /// from scratch per call, since `range(of:options:.regularExpression)` builds a new one
    /// every time.
    ///
    /// Nothing would notice that once. It is called twice per variant by `SizeRun.entries`
    /// and again per variant by `SizeProfile.matches`, on a sneaker that runs 48 variants,
    /// for every card on screen, on **every evaluation of a view body** — and SwiftUI
    /// evaluates bodies for reasons that have nothing to do with sizes. One 48-variant card
    /// measured 3.2ms on a Mac, so a feed of seven spreads was spending a large fraction of
    /// a second inside this function before it could draw a frame. That is the lag reported
    /// when a brand is marked read.
    ///
    /// A cache is close to free here because the input space is tiny and repeats
    /// relentlessly: a store holds thousands of variants and a few hundred distinct size
    /// strings, and "M" appears on every product in the catalogue. Bounded so a pathological
    /// storefront cannot grow it without limit — dropping the whole table is fine, since
    /// every entry is derivable again.
    ///
    /// Keyed on the context as well as the string, because "38" is a different answer on a
    /// sneaker and on a dress. The context adds a handful of keys per string, not a
    /// multiple: a store holds a few garment kinds, not a few hundred.
    private static let cache = Mutex<[CacheKey: NormalizedSize?]>([:])
    private static let cacheLimit = 8_192

    private struct CacheKey: Hashable, Sendable {
        var cleaned: String
        var context: SizeContext
    }

    /// Reads one size string, as printed on a garment described by `context`.
    ///
    /// The context defaults to `.unknown`, which reads every string exactly as it was read
    /// before contexts existed. That is the right answer for a string with no garment
    /// behind it and the wrong one for a product: `SizeProfile.matches` and `claims` take
    /// the context without a default for that reason.
    public static func normalize(_ raw: String, in context: SizeContext = .unknown) -> NormalizedSize? {
        let cleaned = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !cleaned.isEmpty else { return nil }

        let key = CacheKey(cleaned: cleaned, context: context)
        if let hit = cache.withLock({ $0[key] }) { return hit }
        let answer = derive(cleaned, in: context)
        cache.withLock {
            if $0.count >= cacheLimit { $0.removeAll(keepingCapacity: true) }
            $0[key] = answer
        }
        return answer
    }

    /// The rules themselves, over an already-cleaned string. Only ever reached on a miss.
    ///
    /// Letters and one-size markers are read before the context is consulted, and the same
    /// way in every context: an M is an M on a shoe and on a dress. Only a number needs to
    /// know what it was printed on — which is what lets a caller skip building a context
    /// for a run that has no numbers in it.
    private static func derive(_ cleaned: String, in context: SizeContext) -> NormalizedSize? {
        if oneSizeWords.contains(cleaned) {
            return NormalizedSize(kind: .oneSize, token: "OS")
        }
        if let apparel = apparelWords[cleaned] ?? apparelWords[shortened(cleaned)] {
            return NormalizedSize(kind: .apparel, token: apparel)
        }
        switch context.garment {
        case .unknown: return unplaced(cleaned)
        case .footwear: return footwear(cleaned)
        case .bottoms: return bottoms(cleaned, in: context)
        case .upper: return upper(cleaned, in: context)
        // A fitted cap's "7" is a hat size. Read as a shoe it was claimed for anybody who
        // wears a US 7, and no ladder in the profile holds a hat.
        case .headwear: return unread(cleaned)
        }
    }

    /// Nothing known about the garment: the rules from before context existed, untouched.
    ///
    /// Untouched on purpose rather than improved. A product the classifiers cannot place
    /// has no answer to "which ladder is this 38 on", and the guards below — a bare number
    /// is only a waist up to 37 and only a shoe inside the US range — are the ones that kept
    /// that ignorance from hiding anything.
    private static func unplaced(_ cleaned: String) -> NormalizedSize? {
        // Before the shoe path, which strips a leading "w" as the women's marker and would
        // read "W32" as a US 32.
        if let waist = waistToken(in: cleaned) {
            return NormalizedSize(kind: .waist, token: waist)
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
        let stripped = trailingScale
            .strippedFrom(leadingScale.strippedFrom(cleaned))
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
            return NormalizedSize(
                kind: .shoe,
                token: ShoeSizes.token(us),
                scale: scale,
                // What the reading is, unchanged; what the shop printed, now recorded.
                written: scale == .us ? nil : ShoeSizes.token(value)
            )
        }

        return NormalizedSize(kind: .other, token: cleaned.uppercased(), scale: scale)
    }

    /// A size that cannot be placed. It stays `.other` and is never hidden.
    private static func unread(_ cleaned: String) -> NormalizedSize {
        NormalizedSize(kind: .other, token: cleaned.uppercased())
    }

    // MARK: - Reading by garment

    /// On a shoe a number is a shoe size, whatever its range.
    ///
    /// The guard `unplaced` keeps — a bare number is only a shoe inside the US range — was
    /// there because a bare "44" could as easily be a waist or a jacket. On a sneaker it can
    /// only be European, so a run printed 40–46 is finally readable, and a bare "32" on a
    /// sneaker is no longer read as a waist.
    private static func footwear(_ cleaned: String) -> NormalizedSize {
        // "W 9" is the women's-shoe marker, and on a shoe it cannot be a waist.
        let text = womensShoeMarker.strippedFrom(cleaned)
        // A length is tailoring's; on a shoe a trailing letter is a width nobody reads.
        guard let reading = reading(text), reading.length == nil else { return unread(cleaned) }

        let scale: SizeScale
        switch reading.scale {
        case .us?: scale = .us
        case .uk?: scale = .uk
        // An Italian shoe is sized on the European ladder.
        case .eu?, .it?: scale = .eu
        case nil: scale = ShoeSizes.usRange.contains(reading.value) ? .us : .eu
        }
        guard let us = ShoeSizes.toUS(reading.value, from: scale) else { return unread(cleaned) }
        return NormalizedSize(
            kind: .shoe,
            token: ShoeSizes.token(us),
            scale: scale,
            written: scale == .us ? nil : ShoeSizes.token(reading.value)
        )
    }

    /// On trousers a number is a waist, unless it names a scale that says otherwise.
    ///
    /// The bare band `unplaced` stops at 37 because a bare 38 might be a European shoe. No
    /// shoe is printed on a pair of trousers, so here a bare number is read across the whole
    /// range a declared waist is.
    private static func bottoms(_ cleaned: String, in context: SizeContext) -> NormalizedSize {
        let cut = context.cut
        // A child's "8" is an age.
        guard cut != .kids else { return unread(cleaned) }
        // A run that can only be the US dress ladder is read whole as one, its 20s included:
        // "14 16 18 20 22" is one plus-size run, not three dress sizes and two waists.
        if context.isDressRun, let reading = reading(cleaned), reading.scale == nil, reading.length == nil,
           let dress = DressSizes.reading(reading.value, in: .us) {
            return dress
        }
        if let waist = waistToken(in: cleaned, bareRange: waistRange) {
            return NormalizedSize(kind: .waist, token: waist)
        }
        guard let reading = reading(cleaned) else { return unread(cleaned) }
        let value = reading.value

        // "32R" on trousers is a 32 waist with a regular leg. The leg is dropped for the
        // reason the inseam of "32x30" is: nothing asks about it, and keeping it would stop
        // a profile of 32 matching the same trousers spelled longer.
        if reading.length != nil, reading.scale == nil, let waist = inches(value, in: waistRange) {
            return NormalizedSize(kind: .waist, token: waist)
        }

        let asDress = DressSizes.reading(value, in: reading.scale ?? .us)
        switch reading.scale {
        case .us?, .uk?:
            // US and UK trousers are sized by the inch, so in the range where both readings
            // exist ("UK 24") the cut decides: a women's UK 24 is a dress size.
            if cut == .womens, let asDress { return asDress }
            if let waist = inches(value, in: waistRange) {
                return NormalizedSize(kind: .waist, token: waist)
            }
            if cut != .mens, let asDress { return asDress }
        case .eu?, .it?:
            // Men's European trousers run 44 upwards on a ladder each brand maps to a waist
            // its own way. Only the women's ladder is read, and on an unlabelled pair only
            // below the band where the two meet.
            if let asDress, cut == .womens || (cut == .unspecified && value < SuitSizes.europeanStart) {
                return asDress
            }
        case nil:
            // Everything from 20 up was a waist above; what is left of a bare number on a
            // pair of women's trousers is a US dress size.
            if cut == .womens, let asDress { return asDress }
        }
        return unread(cleaned)
    }

    /// On a top, a dress or a jacket a number is a women's dress size or a man's chest, and
    /// the cut says which.
    ///
    /// The two ladders barely meet in US and UK numbers — a women's UK runs 4–32 and a chest
    /// 32 up — so a code usually settles it. In European numbers they overlap from 44 to 60,
    /// and there only the cut, or the garment naming itself tailoring, can.
    private static func upper(_ cleaned: String, in context: SizeContext) -> NormalizedSize {
        let cut = context.cut
        guard cut != .kids, let reading = reading(cleaned) else { return unread(cleaned) }
        let value = reading.value

        // A length is tailoring's own notation, printed after a US or UK chest — never after
        // a European one, so a suffixed number is inches whatever its size.
        if let length = reading.length {
            if reading.scale != .eu, reading.scale != .it,
               let chest = SuitSizes.chest(value, from: reading.scale ?? .us) {
                return SuitSizes.size(chest: chest, length: length, scale: reading.scale ?? .us)
            }
            // "10 Long": a women's size with a length, and the size is what a profile holds.
            if cut != .mens, let dress = DressSizes.reading(value, in: reading.scale ?? .us) {
                return dress
            }
            return unread(cleaned)
        }

        guard let scale = reading.scale else {
            switch cut {
            // A women's bare number is on one ladder or the other by its range alone: the US
            // stops at 28 and the French starts at 30 (its 00).
            case .womens:
                if let dress = DressSizes.reading(value, in: .us) ?? DressSizes.reading(value, in: .eu) {
                    return dress
                }
            // A man's only when the run has said which system it is in.
            case .mens:
                if let runScale = context.runScale, let chest = SuitSizes.chest(value, from: runScale) {
                    return SuitSizes.size(chest: chest, scale: runScale, written: value)
                }
            // Unlabelled, a bare 40 is a chest, a French 40 and an Italian 40 at once — read
            // only when the run is one nothing but the US dress ladder prints.
            case .unspecified:
                if context.isDressRun, let dress = DressSizes.reading(value, in: .us) {
                    return dress
                }
            case .kids:
                break
            }
            return unread(cleaned)
        }

        let asDress = cut == .mens ? nil : DressSizes.reading(value, in: scale)
        let asSuit = cut == .womens ? nil : SuitSizes.chest(value, from: scale)
            .map { SuitSizes.size(chest: $0, scale: scale, written: value) }
        switch (asDress, asSuit) {
        case let (dress?, nil): return dress
        case let (nil, suit?): return suit
        case let (_?, suit?) where context.isTailored: return suit
        default: return unread(cleaned)
        }
    }

    /// A whole number of inches inside `range`, as a token.
    private static func inches(_ value: Double, in range: ClosedRange<Double>) -> String? {
        guard value == value.rounded(), range.contains(value) else { return nil }
        return String(Int(value))
    }

    /// What a size string says, when it is nothing more than a number with a scale code on
    /// either side and a tailoring length after it.
    ///
    /// Strict on purpose. Anything else — "34B", "32DD", "7 1/4", "10-12" — is not read,
    /// so it stays `.other` and is never hidden. A bra's band and cup in particular look
    /// like a chest and a length to anything looser than this.
    private struct Reading {
        var value: Double
        var scale: SizeScale?
        var length: String?
    }

    private static func reading(_ text: String) -> Reading? {
        let stripped = department.strippedFrom(text)
        guard let groups = numeral.captures(stripped),
              let number = groups[1],
              let value = number == "00" ? DressSizes.doubleZero : Double(number)
        else { return nil }

        let leading = groups[0].flatMap(scale(named:))
        let trailing = groups[2].flatMap(scale(named:))
        // "EU 40 UK": two scales, and no way to know which one the number is in.
        if leading != nil, trailing != nil { return nil }

        return Reading(
            value: value,
            scale: leading ?? trailing,
            length: groups[3].map { $0.prefix(1).uppercased() }
        )
    }

    private static func scale(named code: String) -> SizeScale? {
        switch code {
        case "us": .us
        case "uk": .uk
        case "eu", "eur", "fr": .eu
        case "it": .it
        default: nil
        }
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

    /// A waist measurement in inches, if the string is one.
    ///
    /// Two bands, and the difference between them is the whole care taken here. A string
    /// that **names** itself a waist — "W34", "34W", "waist 34", "32x30" — is read across
    /// the full human range. A **bare** number is only read as a waist up to 37, because
    /// from 38 up it collides with the EU shoe ladder, and a bare "44" is as likely a
    /// sneaker as a pair of trousers. Guessing wrong there would *hide* a product from
    /// somebody's feed, which is the one outcome this whole layer exists to prevent — so
    /// the ambiguous band stays `.other`, exactly where it already was.
    ///
    /// "32x30" is waist by inseam. The inseam is dropped rather than stored: nothing in
    /// the app asks about leg length, and keeping it would mean a profile of "32" failed
    /// to match a variant of "32x30" — the same trousers, spelled longer.
    ///
    /// `bareRange` is how far up a bare number is trusted. The 37 is the collision with the
    /// shoe ladder, so it applies only where a shoe is possible — `bottoms` passes the full
    /// range, because nobody prints a shoe size on a pair of trousers.
    private static let waistRange = 20.0...60.0
    private static let bareWaistRange = 20.0...37.0

    private static func waistToken(
        in cleaned: String,
        bareRange: ClosedRange<Double> = SizeNormalizer.bareWaistRange
    ) -> String? {
        var text = cleaned
        var isDeclared = false

        if text.contains("waist") {
            isDeclared = true
            text = text.replacingOccurrences(of: "waist", with: "")
        }
        // Drop the inseam half of "32x30", "32 x 30", "32/30".
        text = inseam.strippedFrom(text).trimmingCharacters(in: .whitespaces)

        // A "w" on either end. Note this is also the women's-shoe marker: "w 9" arrives
        // here, is read as a declared 9, and is refused by the range — so it falls through
        // to the shoe path with nothing lost.
        if text.hasPrefix("w") {
            isDeclared = true
            text = String(text.dropFirst())
        } else if text.hasSuffix("w") {
            isDeclared = true
            text = String(text.dropLast())
        }

        // Whole inches only. A "32.5" is not a waist anybody's trousers are cut to, and
        // admitting halves here would start swallowing shoe sizes.
        guard let value = Double(text.trimmingCharacters(in: .whitespaces)),
              value == value.rounded(),
              (isDeclared ? waistRange : bareRange).contains(value)
        else { return nil }

        return String(Int(value))
    }

    /// The scale a raw size string names, if it names one at all.
    private static func declaredScale(in cleaned: String) -> SizeScale {
        // Every code this looks for — eu, eur, uk — contains a "u", so a string without
        // one cannot name a scale and needs no regex at all. That is the common case: a
        // plain "9.5" or "M" skips four pattern matches on this line alone.
        guard cleaned.contains("u") else { return .us }
        // Anchored to a word boundary or the start so a stray "uk" inside a colourway
        // ("Ukiyo") can't be read as a region code.
        if euLeading.matches(cleaned) || euTrailing.matches(cleaned) { return .eu }
        if ukLeading.matches(cleaned) || ukTrailing.matches(cleaned) { return .uk }
        return .us
    }

    // MARK: - Patterns, compiled once
    //
    // `String.range(of:options:.regularExpression)` and the matching
    // `replacingOccurrences` build a fresh `NSRegularExpression` on every call — which is
    // most of what made a cache miss cost 26µs. These are the same patterns, compiled at
    // first use and kept.

    private static let inseam = Pattern(#"\s*[x×/]\s*\d{2}(\.\d)?\s*$"#)
    private static let leadingScale = Pattern(#"(^|\s)(eur|us|uk|eu|men'?s|women'?s|w)\s*"#)
    private static let trailingScale = Pattern(#"\s*(eur|us|uk|eu)$"#)
    private static let euLeading = Pattern(#"(^|\s)(eur?)\s*\d"#)
    private static let euTrailing = Pattern(#"\d\s*(eur?)($|\s)"#)
    private static let ukLeading = Pattern(#"(^|\s)uk\s*\d"#)
    private static let ukTrailing = Pattern(#"\d\s*uk($|\s)"#)

    /// The readers' grammar: an optional code, a number, an optional code, an optional
    /// length. Longest alternative first in every group, for the reason `leadingScale` gives.
    /// No other leading zero is a number: "00" is a dress size, and "05" is nothing.
    private static let numeral = Pattern(
        #"^(?:(eur|eu|fr|uk|us|it)\s*)?(00|0(?:\.\d)?|[1-9]\d?(?:\.\d)?)\s*(eur|eu|fr|uk|us|it)?\s*(regular|reg|short|long|r|s|l)?$"#
    )
    /// "Men's 10", "Women's 8": a department, not a scale.
    private static let department = Pattern(#"^(men'?s|women'?s)\s*"#)
    private static let womensShoeMarker = Pattern(#"^w\s*(?=\d)"#)
}

/// A regular expression compiled once and reused.
///
/// Deliberately not `Regex` literals: this file compiles on Linux against
/// swift-corelibs-foundation for the server, and `NSRegularExpression` behaves identically
/// there — which is the property that matters, since the patterns above decide what a size
/// *is* and the two platforms must never disagree about that.
private struct Pattern: Sendable {
    private let expression: NSRegularExpression

    init(_ pattern: String) {
        // The patterns are literals in this file. A failure here is a typo, not a runtime
        // condition, and there is no sensible way to carry on without the expression.
        expression = try! NSRegularExpression(pattern: pattern)
    }

    func matches(_ text: String) -> Bool {
        expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    /// Every capture group of the first match, nil where a group took no part in it. Nil
    /// altogether when nothing matched.
    func captures(_ text: String) -> [String?]? {
        guard let match = expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text))
        else { return nil }
        return (1..<match.numberOfRanges).map { index in
            Range(match.range(at: index), in: text).map { String(text[$0]) }
        }
    }

    func strippedFrom(_ text: String) -> String {
        expression.stringByReplacingMatches(
            in: text,
            range: NSRange(text.startIndex..., in: text),
            withTemplate: ""
        )
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
        // An Italian shoe is sized on the European ladder.
        case .eu, .it:
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
        case .eu, .it:
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

/// Converting between women's dress-size scales.
///
/// | US | UK | EU (FR) | IT |
/// |----|----|---------|----|
/// | 00 | 2  | 30      | 34 |
/// | 0  | 4  | 32      | 36 |
/// | 2  | 6  | 34      | 38 |
/// | 4  | 8  | 36      | 40 |
/// | 6  | 10 | 38      | 42 |
/// | …  | …  | …       | …  |
/// | 28 | 32 | 60      | 64 |
///
/// One rung is two sizes on every scale, and the scales are fixed offsets from each other:
/// UK = US + 4, EU = US + 32, IT = US + 36. That is the table the large multi-brand shops
/// publish, and it is *not* universal — German shops label their own ladder "EUR", which
/// sits one rung below the French one (an H&M EUR 38 is a US 8, not a 6), and plenty of US
/// brands print a UK 10 as a US 8. So a converted dress size matches within **one rung**,
/// for exactly the reason a converted shoe matches within half a size: that is the width of
/// the disagreement, and demanding an exact hit after a conversion would hide real results.
///
/// Only even sizes. The odd US numbers are the juniors' ladder, cut for a different body,
/// and reading a 5 as a size between a 4 and a 6 would match somebody to the wrong garment.
public enum DressSizes {
    /// US "00", which is a rung of its own below 0 on every table — and which a number
    /// cannot spell. Read as zero it collapsed into the 0 beside it: the size run printed
    /// one of them and a profile of 0 claimed both. Carried as −2 so the offsets hold.
    static let doubleZero = -2.0

    /// The canonical US ladder, 00–28. Everything stored in `SizeProfile.dress` is on it.
    static let usRange = doubleZero...28.0

    /// How far a converted size may sit from an owned one and still match: one rung.
    static let tolerance = 2.0

    /// A US value as the ladder prints it: "00", "0", "2" … "28".
    static func token(_ us: Double) -> String {
        us == doubleZero ? "00" : ShoeSizes.token(us)
    }

    /// The other way: the US value of a stored token.
    static func value(of token: String) -> Double? {
        token == "00" ? doubleZero : Double(token)
    }

    private static func offset(_ scale: SizeScale) -> Double {
        switch scale {
        case .us: 0
        case .uk: 4
        case .eu: 32
        case .it: 36
        }
    }

    /// Converts a number in `scale` to its US equivalent, or nil when it cannot be a dress
    /// size on that scale.
    public static func toUS(_ value: Double, from scale: SizeScale) -> Double? {
        let us = value - offset(scale)
        guard value == value.rounded(), Int(value) % 2 == 0, usRange.contains(us) else { return nil }
        return us
    }

    /// Converts a canonical US size into `scale`, for display.
    public static func fromUS(_ us: Double, to scale: SizeScale) -> Double { us + offset(scale) }

    /// The number read as a dress size, or nil.
    static func reading(_ value: Double, in scale: SizeScale) -> NormalizedSize? {
        guard let us = toUS(value, from: scale) else { return nil }
        return NormalizedSize(
            kind: .dress,
            token: token(us),
            scale: scale,
            written: scale == .us ? nil : ShoeSizes.token(value)
        )
    }
}

/// Converting between men's jacket scales.
///
/// A US and a UK suit are both sized by the chest in inches, and a European or Italian one
/// by a number ten higher: EU 48 = 38, EU 50 = 40, EU 52 = 42. Unlike shoes and dresses,
/// **every table agrees on that**, so a converted chest gets no tolerance — one rung of the
/// ladder is two inches, and a jacket two inches off does not button.
///
/// A length ("40R", "42 Long") is part of the size when the run prints one, and a profile
/// holds lengths separately from chests — see `SizeProfile.suitLength`.
public enum SuitSizes {
    /// Chests in inches.
    static let chestRange = 32.0...60.0
    /// Where the European ladder starts. Below it a European number is only ever a women's
    /// size, which is how "EU 38" on an unlabelled top is still readable.
    static let europeanStart = 44.0
    /// Bare numbers that only a chest-in-inches ladder prints, and only a European one —
    /// the ends of the two ladders, which is what `SizeContext.runScale` reads a run by.
    static let inchesOnly = 32...41
    static let europeanOnly = 50...64

    /// A number in `scale` as a chest in inches, or nil when it cannot be one.
    static func chest(_ value: Double, from scale: SizeScale) -> Double? {
        guard value == value.rounded() else { return nil }
        switch scale {
        case .us, .uk:
            return chestRange.contains(value) ? value : nil
        case .eu, .it:
            // The European ladder is even numbers only.
            guard Int(value) % 2 == 0, value >= europeanStart else { return nil }
            let chest = value - 10
            return chestRange.contains(chest) ? chest : nil
        }
    }

    /// Converts a chest into `scale`, for display.
    public static func fromChest(_ chest: Double, to scale: SizeScale) -> Double {
        switch scale {
        case .us, .uk: chest
        case .eu, .it: chest + 10
        }
    }

    static func size(chest: Double, length: String? = nil, scale: SizeScale, written: Double? = nil) -> NormalizedSize {
        let isEuropean = scale == .eu || scale == .it
        return NormalizedSize(
            kind: .suit,
            token: String(Int(chest)) + (length ?? ""),
            scale: scale,
            written: isEuropean ? written.map(ShoeSizes.token) : nil,
            length: length
        )
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
    /// Waists in inches, as bare numbers: "32", "34". Bottoms are the one garment these
    /// brands size numerically, and until this existed they matched nothing at all.
    public var waist: Set<String> = []
    /// The scale the user reads and picks shoe sizes in. Display only.
    public var shoeScale: SizeScale = .us
    /// Women's dress sizes, always as **US** tokens ("4", "6"), for the reason `shoe` is.
    public var dress: Set<String> = []
    /// The scale the user reads and picks dress sizes in. Display only.
    public var dressScale: SizeScale = .us
    /// Jacket chests in inches ("38", "40").
    ///
    /// Held apart from `suitLength` because a length is a fact about a person's height and
    /// a chest about their build: somebody who wears a 40 and a 42 wears both in Regular.
    /// Stored as "40R"-style tokens instead, the ladder would be thirty-six chips long and a
    /// profile of "40R" would silently stop matching a European 50, which has no length.
    public var suit: Set<String> = []
    /// "S", "R", "L". Only narrows the suit ladder, and only where a run prints a length —
    /// on its own it says nothing about which jacket.
    public var suitLength: Set<String> = []
    /// The scale the user reads and picks suit chests in: `.us` (inches) or `.eu`. Display only.
    public var suitScale: SizeScale = .us
    /// Which genders belong in this person's feed. Lives here rather than in its own
    /// store because it travels with the sizes everywhere they already go — the wire
    /// payload, the server's targeting, the feed filter — and splitting it would mean
    /// duplicating all three.
    public var gender: GenderPreference = .everything

    public init() {}

    /// Decodes leniently for the same reason `BrandSource` does: a profile written
    /// before `shoeScale` existed is sitting in `UserDefaults` on a real phone, and a
    /// non-optional decode of a missing key throws rather than defaulting. Every profile
    /// stored before the dress and suit ladders existed is one of those, so each new field
    /// defaults the same way.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        apparel = try container.decodeIfPresent(Set<String>.self, forKey: .apparel) ?? []
        shoe = try container.decodeIfPresent(Set<String>.self, forKey: .shoe) ?? []
        waist = try container.decodeIfPresent(Set<String>.self, forKey: .waist) ?? []
        shoeScale = try container.decodeIfPresent(SizeScale.self, forKey: .shoeScale) ?? .us
        dress = try container.decodeIfPresent(Set<String>.self, forKey: .dress) ?? []
        dressScale = try container.decodeIfPresent(SizeScale.self, forKey: .dressScale) ?? .us
        suit = try container.decodeIfPresent(Set<String>.self, forKey: .suit) ?? []
        suitLength = try container.decodeIfPresent(Set<String>.self, forKey: .suitLength) ?? []
        suitScale = try container.decodeIfPresent(SizeScale.self, forKey: .suitScale) ?? .us
        gender = try container.decodeIfPresent(GenderPreference.self, forKey: .gender) ?? .everything
    }

    /// Whether `gender` would hide this item. Separate from `matches` because the two
    /// filters answer different questions and an empty size profile must not disable the
    /// gender one.
    public func allows(_ gender: Gender) -> Bool {
        self.gender.allows(gender)
    }

    public static let apparelOptions = ["XXS", "XS", "S", "M", "L", "XL", "XXL", "XXXL"]
    /// Every inch from 26 to 44. Odd waists are rarer than even ones but real — Levi's
    /// cuts them — and a ladder that skipped them would leave those people unable to say
    /// what they wear at all.
    public static let waistOptions: [String] = (26...44).map(String.init)
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

    /// The canonical US dress ladder, 00–28. Everything stored in `dress` is one of these.
    /// Both ends are on it for the reason odd waists are on theirs: a ladder that stops
    /// short leaves the people past its end unable to say what they wear.
    public static let dressOptions: [String] = SizeProfile.dressOptions(in: .us).map(\.stored)

    /// The dress ladder as `scale` prints it, paired with the US token each entry stores.
    public static func dressOptions(in scale: SizeScale) -> [(display: String, stored: String)] {
        stride(from: DressSizes.doubleZero, through: 28.0, by: 2.0).map { us in
            let shown = DressSizes.fromUS(us, to: scale)
            return (scale == .us ? DressSizes.token(us) : ShoeSizes.token(shown), DressSizes.token(us))
        }
    }

    /// Jacket chests, 34–56 inches. Everything stored in `suit` is one of these.
    public static let suitOptions: [String] = stride(from: 34.0, through: 56.0, by: 2.0)
        .map(ShoeSizes.token)

    /// The chest ladder as `scale` prints it — a European taps "50" and the profile
    /// records "40".
    public static func suitOptions(in scale: SizeScale) -> [(display: String, stored: String)] {
        stride(from: 34.0, through: 56.0, by: 2.0).map { chest in
            (ShoeSizes.token(SuitSizes.fromChest(chest, to: scale)), ShoeSizes.token(chest))
        }
    }

    public static let suitLengthOptions: [(display: String, stored: String)] = [
        ("Short", "S"), ("Regular", "R"), ("Long", "L")
    ]

    // MARK: - Canonical tokens, for anything arriving from outside

    /// A dress size as `dress` stores it, or nil when the string is not one.
    ///
    /// Strict, unlike the older ladders' `normalize(...)?.token`, which keeps a `.other`
    /// token — that is how a bare "44" came to sit in somebody's shoe ladder and mark every
    /// unreadable size in the app as theirs. A token that is not a dress size is dropped.
    public static func dressToken(_ raw: String) -> String? {
        let size = SizeNormalizer.normalize(raw, in: SizeContext(garment: .upper, cut: .womens))
        return size?.kind == .dress ? size?.token : nil
    }

    /// A chest as `suit` stores it — "40" for "40", "40R" or "EU 50" — or nil.
    public static func suitToken(_ raw: String) -> String? {
        let context = SizeContext(garment: .upper, cut: .mens, isTailored: true, runScale: .us)
        guard let size = SizeNormalizer.normalize(raw, in: context), size.kind == .suit else { return nil }
        return size.chest
    }

    /// A length as `suitLength` stores it: "S", "R" or "L", or nil.
    public static func suitLengthToken(_ raw: String) -> String? {
        switch raw.trimmingCharacters(in: .whitespaces).lowercased() {
        case "s", "short": "S"
        case "r", "reg", "regular": "R"
        case "l", "long": "L"
        default: nil
        }
    }

    /// No ladder filled in. A length alone does not count: with no chest it says nothing
    /// about which jacket, and is not a preference anything can act on.
    public var isEmpty: Bool {
        apparel.isEmpty && shoe.isEmpty && waist.isEmpty && dress.isEmpty && suit.isEmpty
    }

    public var summary: String {
        var parts: [String] = []
        if !apparel.isEmpty {
            parts.append(SizeProfile.apparelOptions.filter(apparel.contains).joined(separator: ", "))
        }
        if !waist.isEmpty {
            // "W 32, 34" — the W marks the ladder, because a bare "32, 34" beside "M, L"
            // reads as a continuation of the same run.
            parts.append("W " + SizeProfile.waistOptions.filter(waist.contains).joined(separator: ", "))
        }
        if !shoe.isEmpty {
            // Printed in the user's own scale — "EU 43" reads as a size to someone who
            // wears it, where "US 9.5" is a sum they have to do.
            let shown = SizeProfile.shoeOptions(in: shoeScale)
                .filter { shoe.contains($0.stored) }
                .map(\.display)
            parts.append("\(shoeScale.label) " + shown.joined(separator: ", "))
        }
        if !dress.isEmpty {
            // Named, because "US 4, 6" beside "US 9, 9.5" reads as more shoes.
            let shown = SizeProfile.dressOptions(in: dressScale)
                .filter { dress.contains($0.stored) }
                .map(\.display)
            parts.append("Dress \(dressScale.label) " + shown.joined(separator: ", "))
        }
        if !suit.isEmpty {
            let shown = SizeProfile.suitOptions(in: suitScale)
                .filter { suit.contains($0.stored) }
                .map(\.display)
            let scale = suitScale == .eu || suitScale == .it ? "EU " : ""
            let lengths = SizeProfile.suitLengthOptions
                .map(\.stored)
                .filter(suitLength.contains)
                .joined(separator: "/")
            parts.append("Suit \(scale)" + shown.joined(separator: ", ") + (lengths.isEmpty ? "" : " \(lengths)"))
        }
        return parts.isEmpty ? "Not set" : parts.joined(separator: " · ")
    }

    /// Whether this is a size the user wears.
    ///
    /// **Each ladder filters only once it has been filled in.** They are separate
    /// questions — knowing somebody's shoe size says nothing about their waist — and the
    /// profile-wide `isEmpty` guard could not express that: it meant a person who had
    /// entered shoe sizes and nothing else had *every garment in the app* hidden, because
    /// an empty `apparel` set matched no letter. Adding a third ladder made that failure
    /// three times as likely to be reached, and the first person to enter a waist would
    /// have lost their whole feed to it. The dress and suit ladders follow the same rule:
    /// a woman who has entered a shoe size has nothing hidden on a dress because of it.
    ///
    /// - Parameter context: what the size was printed on. **No default**, on purpose: the
    ///   bug this fixes was a call site that had no garment to go on, and a default would
    ///   let every new call site be one. Pass `.unknown` only when there genuinely is no
    ///   product behind the string.
    public func matches(_ raw: String, in context: SizeContext) -> Bool {
        guard !isEmpty else { return true }
        guard let size = SizeNormalizer.normalize(raw, in: context) else { return true }

        switch size.kind {
        case .apparel: return apparel.isEmpty || apparel.contains(size.token)
        case .waist: return waist.isEmpty || waist.contains(size.token)
        case .shoe:
            guard !shoe.isEmpty else { return true }
            guard !size.isConverted else { return matchesConvertedShoe(size.token) }
            return shoe.contains(size.token)
        case .dress: return dress.isEmpty || wearsDress(size)
        case .suit: return suit.isEmpty || wearsSuit(size)
        // A one-size item fits everyone by definition, so there was never a real reason to
        // exclude it — and the toggle that could was one more thing to explain in exchange
        // for hiding most of the accessories in the feed.
        case .oneSize: return true
        // Unrecognised sizing (a brand's own scale, a bare "44", "Youth L"): don't hide
        // it, a false positive is much cheaper than a missed drop.
        case .other: return true
        }
    }

    /// Whether this is a size the wearer actually told us they wear.
    ///
    /// **The strict half of a pair, and the half that was missing.** `matches` above answers
    /// "may this be shown", and it answers *true* whenever it does not know — an
    /// unrecognised scale, a ladder nobody has filled in, no profile at all — because
    /// hiding a real drop is the one outcome that filter must never produce. That is right
    /// for a filter and wrong for a label, and every caller wanting a label was using it:
    /// "IN YOUR SIZE", the vermilion rule under a token, "BACK IN L, S", the accent bar on
    /// a tile and `availableInMySize` on the wire are all **claims about the reader**, and
    /// answering them with the filter's optimism turns "we cannot read this size" into
    /// "yes, that is yours".
    ///
    /// What that looked like: a profile holding a bare "44" — which is `.other`, since 44
    /// is as likely an EU shoe, an EU jacket or a waist, and only "EU 44" says which — had
    /// every unreadable size in the app ruled in vermilion, so a run of 38 40 42 came back
    /// as *your* sizes to somebody who wears none of them. An empty profile was worse
    /// still: `isEmpty` returns true from `matches`, so the whole feed was marked as the
    /// reader's size before they had entered one.
    ///
    /// Silent rather than optimistic on every "don't know", which is the opposite default
    /// from `matches` and deliberately so: an unmarked size costs a glance at the run, and
    /// a wrongly marked one costs the accent all its meaning.
    public func claims(_ raw: String, in context: SizeContext) -> Bool {
        guard let size = SizeNormalizer.normalize(raw, in: context) else { return false }
        switch size.kind {
        case .apparel: return apparel.contains(size.token)
        case .waist: return waist.contains(size.token)
        case .shoe:
            guard !shoe.isEmpty else { return false }
            return size.isConverted ? matchesConvertedShoe(size.token) : shoe.contains(size.token)
        case .dress: return wearsDress(size)
        case .suit: return wearsSuit(size)
        // A one-size item fits everybody, which is why `matches` admits it — but "fits
        // everybody" is not a fact about *this* reader, and printing IN YOUR SIZE over a
        // beanie that says nothing about them is the accent spent on nothing.
        case .oneSize: return false
        // The whole point. We could not read it, so we cannot claim it.
        case .other: return false
        }
    }

    public func claims(_ variant: VariantInfo, in context: SizeContext) -> Bool {
        claims(variant.displaySize, in: context)
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

    /// A dress size read natively matches exactly; a converted one within a rung. See
    /// `DressSizes` for why the tolerance is that wide and no wider.
    private func wearsDress(_ size: NormalizedSize) -> Bool {
        guard size.isConverted else { return dress.contains(size.token) }
        guard let value = DressSizes.value(of: size.token) else { return false }
        return dress.contains { mine in
            guard let owned = DressSizes.value(of: mine) else { return false }
            return abs(owned - value) <= DressSizes.tolerance
        }
    }

    /// The chest must be one the wearer named — exactly, converted or not, because the
    /// tables agree (see `SuitSizes`). The length narrows only when both sides have one: a
    /// run that prints none is one jacket per chest, which is the wearer's whatever their
    /// height, and a wearer who named none has not said.
    private func wearsSuit(_ size: NormalizedSize) -> Bool {
        guard suit.contains(size.chest) else { return false }
        guard let length = size.length, !suitLength.isEmpty else { return true }
        return suitLength.contains(length)
    }

    public func matches(_ variant: VariantInfo, in context: SizeContext) -> Bool {
        matches(variant.displaySize, in: context)
    }
}

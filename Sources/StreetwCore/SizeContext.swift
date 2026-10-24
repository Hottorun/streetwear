// SizeContext.swift
// What a size string was printed on — the one fact that decides which ladder a bare number
// belongs to.
//
// A "38" is three different sizes depending on the garment: on a sneaker it is a European
// shoe, on a pair of trousers it is a waist, on a dress it is a French 38 (a US 6). Read
// without knowing which, the only safe answer was `.other` — and the readings that *were*
// attempted were the wrong ones: a US dress size 4–18 was taken for a US shoe size, "UK 10"
// for a UK shoe, a bare "34" for a waist and "EU 48" on a suit for a size 14 sneaker. So a
// woman who had entered a shoe size had dresses ruled in vermilion as hers, or not, by a
// ladder that had nothing to do with them.
//
// Built once per product, never per variant, and read off the same catalogue text the slot
// and the gender already are. Lives here rather than in the app because the server targets
// restock alerts with the same reading the phone draws, and two copies would drift.

import Foundation

public struct SizeContext: Hashable, Sendable {
    /// Where on the body the garment goes, as far as sizing is concerned.
    public enum Garment: String, Hashable, Sendable {
        /// A number is a shoe size, in whatever scale the run is printed in.
        case footwear
        /// A number is a waist, unless it names a scale that says otherwise.
        case bottoms
        /// Tops, outerwear, dresses, tailoring: a number is a women's dress size or a chest.
        case upper
        /// A number is a hat size, which no ladder holds.
        case headwear
        /// Nothing known. The rules from before context existed, unchanged.
        case unknown
    }

    /// Whose sizing system the numbers are printed in. Not the feed filter's gender — a
    /// unisex hoodie and an unlabelled one are the same question here: nobody has said
    /// whether "40" is a chest or a European women's 40.
    public enum Cut: String, Hashable, Sendable {
        case womens
        case mens
        /// Children's numbers are ages, and no ladder in the profile holds an age.
        case kids
        case unspecified
    }

    public var garment: Garment
    public var cut: Cut
    /// A blazer, a suit, a sport coat. Settles the one collision codes cannot: "EU 48" is
    /// both a women's 16 and a men's 38 chest, and a garment that names itself tailoring
    /// with no gender to go on is far more often the second.
    public var isTailored: Bool
    /// Which system a man's run of bare numbers is printed in, when the run itself says.
    ///
    /// The two systems print the same numbers for different people: European sizes run
    /// 42–56 and chest sizes 34–48, so a bare 44 is an XS in Milan and an XL in London. No
    /// single number in the overlap can be read — but **a run is printed in one system**,
    /// and a run that contains a 36 is in inches while one that contains a 52 is European.
    /// Reading a number on its own would be worse than leaving it: the ends of a run become
    /// readable and the middle does not, which is the half-readable run YoungLA's spelled-out
    /// sizes produced, where the extremities could never be ruled in as anybody's size.
    /// Nil whenever the run does not settle it, and then every bare number stays `.other`.
    public var runScale: SizeScale?
    /// Whether the run can only be the US women's ladder, which settles what no label did.
    ///
    /// Plenty of womenswear brands tag nothing — every one of Staud's four hundred products
    /// classifies as `.unknown` — so on their tops and trousers a bare "6" had no cut to be
    /// read by, and only the dresses, which name themselves, were readable. But a run of
    /// `00 0 2 4 … 16` is not anything else: a Japanese 0–5 run has odd numbers in it, a
    /// waist run sits from 20 up, and a European or chest run is past 28. Read whole, for
    /// the reason `runScale` is.
    public var isDressRun: Bool

    public init(
        garment: Garment,
        cut: Cut = .unspecified,
        isTailored: Bool = false,
        runScale: SizeScale? = nil,
        isDressRun: Bool = false
    ) {
        self.garment = garment
        self.cut = cut
        self.isTailored = isTailored
        self.runScale = runScale
        self.isDressRun = isDressRun
    }

    /// No idea what the garment is: every size reads exactly as it did before context existed.
    public static let unknown = SizeContext(garment: .unknown)

    /// The context for one product.
    ///
    /// - Parameters:
    ///   - slot: the product's `GarmentSlot`. Decides the garment for everything it places;
    ///     a dress and a suit are two things it does not place, so their words are read here.
    ///   - gender: the product's own gender, which decides the cut.
    ///   - sizes: the product's whole run — every variant's size, not a colourway's or a
    ///     restock's subset — read only to settle `runScale`.
    public static func of(
        slot: GarmentSlot,
        gender: Gender,
        title: String,
        productType: String? = nil,
        tags: [String] = [],
        sizes: [String] = []
    ) -> SizeContext {
        let words = ([title, productType ?? ""] + tags).map {
            $0.lowercased()
                .split { !$0.isLetter && !$0.isNumber }
                .map(String.init)
        }

        // Bras are sized band-and-cup, which is a ladder of its own and later work. Reading
        // one as anything else would put "34L" on the suit ladder, so the whole product
        // stays where it already was: unread, and never hidden.
        if words.contains(where: { $0.contains(where: braWords.contains) }) { return .unknown }

        let isDress = words.contains(where: namesDress)
        let isTailored = words.contains(where: namesTailoring)

        var cut: Cut
        switch gender {
        case .mens: cut = .mens
        case .womens: cut = .womens
        case .kids: cut = .kids
        case .unisex, .unknown: cut = .unspecified
        }
        // A dress is cut for women whether or not anybody tagged it — but a girl's dress is
        // still sized by age, so kids is left alone.
        if isDress && cut != .kids { cut = .womens }

        let garment: Garment
        switch slot {
        case .footwear: garment = .footwear
        case .bottom: garment = .bottoms
        case .top, .outerwear: garment = .upper
        case .headwear: garment = .headwear
        // `GarmentClassifier` places neither a dress nor a suit, and leaving them unplaced
        // here is exactly the bug: their sizes would be read as shoes.
        case .accessory, .unknown: garment = isDress || isTailored ? .upper : .unknown
        }

        var context = SizeContext(garment: garment, cut: cut, isTailored: isTailored)
        if garment == .upper, cut == .mens { context.runScale = menswearScale(of: sizes) }
        if garment == .upper || garment == .bottoms, cut == .womens || cut == .unspecified {
            context.isDressRun = isDressRun(sizes)
        }
        return context
    }

    /// The same, placing the garment from its text — for a caller holding no slot.
    public static func of(
        gender: Gender,
        title: String,
        productType: String? = nil,
        tags: [String] = [],
        sizes: [String] = []
    ) -> SizeContext {
        of(
            slot: GarmentClassifier.classify(title: title, productType: productType, tags: tags),
            gender: gender,
            title: title,
            productType: productType,
            tags: tags,
            sizes: sizes
        )
    }

    /// Whether any of these sizes could read differently on another garment.
    ///
    /// Only a number can: letters and one-size markers are read before the context is
    /// consulted, the same way everywhere. So a run of S M L needs no context at all, and
    /// building one for it would run the slot and gender classifiers for nothing — once per
    /// card, per body evaluation, in every list of a brand's output.
    public static func matters(for sizes: some Sequence<String>) -> Bool {
        sizes.contains { $0.contains(where: \.isNumber) }
    }

    // MARK: - The run

    /// Inches if the run holds a bare chest no European ladder prints, European if it holds
    /// a bare number no chest is, nil if it holds both or neither.
    static func menswearScale(of sizes: [String]) -> SizeScale? {
        var inches = false
        var european = false
        for size in sizes {
            guard let value = Int(size.trimmingCharacters(in: .whitespaces)) else { continue }
            if SuitSizes.inchesOnly.contains(value) { inches = true }
            if SuitSizes.europeanOnly.contains(value) { european = true }
        }
        switch (inches, european) {
        case (true, false): return .us
        case (false, true): return .eu
        default: return nil
        }
    }

    /// Every bare number even and on the US dress ladder, at least one below where waists
    /// start, and at least two of them — one number alone says nothing about a system.
    /// Counted in distinct sizes, because a colour axis repeats every size once per colour.
    static func isDressRun(_ sizes: [String]) -> Bool {
        var seen: Set<Int> = []
        for size in sizes {
            let text = size.trimmingCharacters(in: .whitespaces)
            guard let value = text == "00" ? Int(DressSizes.doubleZero) : Int(text) else { continue }
            guard value % 2 == 0, DressSizes.usRange.contains(Double(value)) else { return false }
            seen.insert(value)
        }
        return seen.count >= 2 && seen.contains { $0 < 20 }
    }

    // MARK: - Words

    private static let braWords: Set<String> = [
        "bra", "bras", "bralette", "bralettes", "brassiere"
    ]

    private static let dressWords: Set<String> = [
        "dress", "dresses", "gown", "gowns", "jumpsuit", "jumpsuits",
        "playsuit", "playsuits", "romper", "rompers"
    ]

    /// The nouns a "dress" can be modifying. English puts the head noun last, so a "dress
    /// shirt" is a shirt — a man's, sized by the collar — and a "shirt dress" is a dress.
    private static let modifiedByDress: Set<String> = [
        "shirt", "shirts", "shoe", "shoes", "boot", "boots", "pant", "pants",
        "trouser", "trousers", "sock", "socks"
    ]

    private static func namesDress(_ tokens: [String]) -> Bool {
        for (index, token) in tokens.enumerated() where dressWords.contains(token) {
            let next = tokens.index(after: index)
            if next < tokens.endIndex, modifiedByDress.contains(tokens[next]) { continue }
            return true
        }
        return false
    }

    private static let tailoringWords: Set<String> = [
        "blazer", "blazers", "suit", "suits", "tuxedo", "tuxedos", "sportcoat", "sportcoats",
        "waistcoat", "waistcoats"
    ]

    /// Whatever turns a "suit" into something that is not tailoring. A boiler suit is
    /// workwear, a snow suit is outerwear sized by letter, and a track suit is a set.
    /// Deliberately not `GarmentClassifier.isSet`: its "two piece" is also how a tailor
    /// sells a suit, and the one-word spellings ("tracksuit") are already a different token.
    private static let notTailoring: Set<String> = [
        "track", "sweat", "swim", "boiler", "snow", "jump", "body", "flight", "rain", "ski",
        "play", "wet", "space"
    ]

    private static func namesTailoring(_ tokens: [String]) -> Bool {
        for (index, token) in tokens.enumerated() where tailoringWords.contains(token) {
            if token.hasPrefix("suit"), index > tokens.startIndex,
               notTailoring.contains(tokens[tokens.index(before: index)]) {
                continue
            }
            return true
        }
        // "Sport coat" and "dinner jacket" are two words each, and neither half names
        // tailoring on its own.
        for (first, second) in zip(tokens, tokens.dropFirst()) {
            if (first == "sport" && second == "coat") || (first == "dinner" && second == "jacket") {
                return true
            }
        }
        return false
    }
}

extension DiscoverCard {
    /// What this garment's sizes are printed on. See `SizeContext`.
    public var sizeContext: SizeContext {
        let sizes = (variants ?? []).map(\.displaySize)
        guard SizeContext.matters(for: sizes) else { return .unknown }
        return .of(gender: itemGender, title: title, productType: productType, tags: tags, sizes: sizes)
    }
}

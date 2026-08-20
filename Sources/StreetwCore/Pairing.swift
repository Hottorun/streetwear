// Pairing.swift
// Whether one garment goes with another — asked about a single thing rather than about a
// whole outfit.
//
// `FitSuggestions` already composes outfits from the wardrobe, and `ColorHarmony` already
// says whether two colours fight. What neither could answer is the question a product page
// raises: *I am looking at this jacket — what that I already own would I wear it with?*
// That is the same machinery pointed the other way, and it is the one thing an archive can
// say that a catalogue cannot.
//
// Four rules, and the interesting part is which ones are **not** here.
//
// - **Slots have to complement.** Two tops is not an outfit and never becomes one. This is
//   a gate rather than a score: no amount of colour agreement rescues a second pair of
//   trousers.
// - **Colour**, via `ColorHarmony`, unchanged and shared — a second copy of that vocabulary
//   would drift from the one the fit row uses, and the symptom would be the product page
//   and the suggestion row disagreeing about the same two garments.
// - **Weight has to agree.** A down parka over swim shorts is wrong in every subculture
//   there is, which is exactly why it is safe to encode.
// - **One statement piece.** Two all-over prints fight. A soft penalty, not a refusal —
//   people do wear print on print, and this is meant to rank rather than to police.
//
// Deliberately absent: **formality**. A blazer with track pants and a suit with sneakers
// are not mistakes in streetwear, they are the house style — so a dressy/sporty distance
// penalty, which is the first rule anyone reaches for and which works fine for a
// department store, would spend most of its time refusing the best answers this app has.
// The rule that is clever and wrong is worse than the rule that is obvious and right; the
// same argument that keeps `BrandVector` off collaborative filtering applies here.
//
// Text-only and on-device, over the catalogue copy the classifiers already read, plus the
// dominant colour `ImageTagger` stored. Nothing here needs a model and nothing here leaves
// the phone.

import Foundation

/// One garment, in the terms this can reason about.
///
/// A value type rather than a model reference because both a saved item and a product
/// nobody has kept get scored by the same code — the whole point of the feature is
/// comparing the thing on screen against the things in the wardrobe, and only one of them
/// is a `SavedItem`.
public struct Garment: Sendable, Hashable {
    public var id: String
    public var title: String
    public var productType: String?
    public var tags: [String]
    public var visionCategories: [String]
    /// The dominant colour `ImageTagger` measured, where it has run. Nil is ordinary —
    /// Vision does not run in the Simulator at all — and scores neutral rather than badly.
    public var color: String?
    /// The accent, where the photograph had a real one. A garment's second colour can clash
    /// with another garment's first, and reading only the dominant misses it entirely.
    public var secondaryColor: String?
    /// How much is going on in the photograph, 0…1, measured rather than inferred from
    /// words. See `BrandUpdate.visionBusyness`. Zero means "nothing measured" as well as
    /// "completely plain", which is safe here because both should be scored as quiet.
    public var busyness: Double
    /// How much of the garment is lettering, 0…1.
    public var textCoverage: Double

    public init(
        id: String,
        title: String,
        productType: String? = nil,
        tags: [String] = [],
        visionCategories: [String] = [],
        color: String? = nil,
        secondaryColor: String? = nil,
        busyness: Double = 0,
        textCoverage: Double = 0
    ) {
        self.id = id
        self.title = title
        self.productType = productType
        self.tags = tags
        self.visionCategories = visionCategories
        self.color = color
        self.secondaryColor = secondaryColor
        self.busyness = busyness
        self.textCoverage = textCoverage
    }

    /// Whether this piece is doing the talking.
    ///
    /// Measured first, and the words only when nothing has been measured. The vocabulary
    /// was always a stand-in for looking — "camo" in a title is a guess that the picture is
    /// busy — so where the picture has actually been read, the guess has nothing to add.
    /// Both a dense print and a chest-wide wordmark count: they compete for the same
    /// attention when worn together, which is the only thing this is used to decide.
    var isStatement: Bool {
        if busyness > 0 || textCoverage > 0 {
            return busyness >= Pairing.statementBusyness
                || textCoverage >= Pairing.statementTextCoverage
        }
        return !vocabulary.isDisjoint(with: Pairing.statementWords)
    }

    public var slot: GarmentSlot {
        GarmentClassifier.classify(
            title: title,
            productType: productType,
            tags: tags,
            visionCategories: visionCategories
        )
    }

    /// Every word this garment is described by, lowercased and whole.
    ///
    /// Whole tokens, never substrings — the rule the whole codebase runs on. "shorts"
    /// contains "short" and "sweatshirt" contains "sweat", and a `contains` check here
    /// would read a sweatshirt as gym kit and a pair of shorts as summer-only.
    var vocabulary: Set<String> {
        let source = [title, productType ?? ""] + tags + visionCategories
        return Set(
            source
                .flatMap { $0.lowercased().split { !$0.isLetter && !$0.isNumber } }
                .map(String.init)
        )
    }
}

public enum Pairing {
    public struct Verdict: Sendable, Hashable {
        /// 0…1. Only meaningful against other verdicts — this ranks, it does not grade.
        public var score: Double
        /// The line a card prints, in the few words that fit under one. Nil when nothing
        /// has been analysed and there is honestly nothing to say, which is a real state
        /// and not a failure.
        public var reason: String?
        /// Pairs that would read as a bug rather than a suggestion.
        public var isRefused: Bool

        public init(score: Double, reason: String?, isRefused: Bool = false) {
            self.score = score
            self.reason = reason
            self.isRefused = isRefused
        }
    }

    /// Below this, proposing the pair does more harm than saying nothing.
    static let bar = 0.4

    /// - Parameter statement: what the wearer has said about their own style, where they
    ///   have said anything. It can raise or lower a score and can rescue a pair the colour
    ///   rules refused — a stated preference is *evidence*, and every other input here is an
    ///   inference. It can never introduce a pair the slot gate rejected: two pairs of
    ///   trousers do not become an outfit because somebody typed "trousers".
    public static func score(
        _ one: Garment,
        with other: Garment,
        statement: StyleStatement? = nil
    ) -> Verdict {
        let mine = one.slot, theirs = other.slot

        // The gate. `.unknown` is the classifier declining to answer, and it is a large
        // share of most catalogues — putting a garment we could not place next to one we
        // could is a guess wearing the clothes of a suggestion.
        guard mine != .unknown, theirs != .unknown, mine != theirs else {
            return Verdict(score: 0, reason: nil, isRefused: true)
        }
        // An accessory sits with anything by construction, so pairing two of them says
        // nothing; and headwear plus a bag is not an outfit anybody was asking about.
        guard GarmentSlot.essential.contains(mine) || GarmentSlot.essential.contains(theirs) else {
            return Verdict(score: 0, reason: nil, isRefused: true)
        }

        // Asked before the colour veto, and allowed to overrule it. Somebody who has written
        // that they wear a checkered shirt with black shorts has settled the question that
        // the wheel is guessing at, and a suggestion refused on a rule while the person has
        // said the opposite in words is the app arguing with its user.
        let stated = statement.map { $0.statedPairing(between: one, and: other) } ?? false

        let colour = ColorHarmony.score(one.color, other.color)
        if !stated, ColorHarmony.isClash(one.color, other.color) {
            return Verdict(score: colour.score, reason: nil, isRefused: true)
        }

        let a = one.vocabulary, b = other.vocabulary

        // Weight. Refused outright rather than scored down: this is the one pairing here
        // that is wrong on its face, and ranking it low would still let it surface in a
        // thin wardrobe — which is precisely where a bad suggestion does the most damage.
        if isSeasonalMismatch(a, b) {
            return Verdict(score: 0, reason: nil, isRefused: true)
        }

        var score = colour.score
        var reason = colour.reason

        // An accent against the other garment's dominant. A penalty and never a veto: the
        // accent is by definition the smaller part of the garment, so a red flash against
        // olive trousers is a decision rather than a mistake — but it is a louder pairing
        // than the dominant colours alone report, and the ranking should know.
        if ColorHarmony.isClash(one.secondaryColor, other.color)
            || ColorHarmony.isClash(one.color, other.secondaryColor) {
            score -= 0.15
        }

        // Two loud pieces. A penalty rather than a veto — print on print is a real thing
        // people wear, it is just rarely the suggestion to lead with. Now measured off the
        // photographs where they have been read, rather than guessed from the titles.
        if one.isStatement && other.isStatement { score -= 0.2 }

        // A layer over a top is the most reliable pairing there is, and the one somebody
        // looking at outerwear is actually asking about. Says so when the colours had
        // nothing to add.
        if isLayering(mine, theirs) {
            score += 0.05
            reason = reason ?? "Layers over it"
        }

        // Last, and loudest. A statement is the only input here that was not inferred from
        // something, so it moves the score further than any of the rules above and takes the
        // line over from them — "you wear these together" is a better reason than "black
        // with cream", and it is the one the ranking actually used.
        if let statement {
            if stated {
                score += 0.35
                reason = "You wear these together"
            } else {
                let affinity = statement.affinity(for: one) + statement.affinity(for: other)
                score += 0.12 * affinity
            }
        }

        return Verdict(
            score: min(max(score, 0), 1),
            reason: reason,
            isRefused: score < bar
        )
    }

    /// The wardrobe's best answers for one garment, best first.
    ///
    /// Ties break on `id` so a page redrawn twice proposes the same things in the same
    /// order. A row that reshuffles on every render reads as a shuffle, which is the exact
    /// complaint that put `ColorHarmony` in front of `FitSuggestions` in the first place.
    public static func best(
        for garment: Garment,
        from wardrobe: [Garment],
        limit: Int = 4,
        statement: StyleStatement? = nil
    ) -> [(garment: Garment, verdict: Verdict)] {
        var scored: [(garment: Garment, verdict: Verdict)] = []
        for candidate in wardrobe where candidate.id != garment.id {
            let verdict = score(garment, with: candidate, statement: statement)
            guard !verdict.isRefused else { continue }
            scored.append((garment: candidate, verdict: verdict))
        }
        scored.sort { first, second in
            first.verdict.score == second.verdict.score
                ? first.garment.id < second.garment.id
                : first.verdict.score > second.verdict.score
        }
        return Array(scored.prefix(limit))
    }

    // MARK: - The vocabulary

    /// Pieces that only work in the cold, and pieces that only work in the heat.
    ///
    /// Kept short and kept obvious. Every word here names a garment whose season is not a
    /// matter of taste — a shearling is not a summer coat in any city — and anything
    /// arguable is deliberately left out, because **a wrong refusal is invisible**: the
    /// suggestion never appears and nobody can tell it was suppressed.
    ///
    /// These lists started longer and the tests took them apart, which is the argument for
    /// having them. `wool` and `cashmere` were in the cold list: a wool blazer is a
    /// three-season garment and merino is worn all year, so they refused pairings nobody
    /// would object to. `linen`, `tank` and `mesh` were in the warm list for the same bad
    /// reason — a tank is a base layer, and mesh is what a basketball jersey is made of.
    /// What is left names a *garment*, not a fabric, which is the line worth holding: a
    /// fabric turns up in every season and a parka does not.
    private static let cold: Set<String> = [
        "puffer", "parka", "shearling", "down", "fleece", "thermal",
        "insulated", "quilted", "sherpa", "overcoat", "peacoat", "duffle", "balaclava"
    ]

    private static let warm: Set<String> = [
        "swim", "swimsuit", "boardshort", "boardshorts", "bikini",
        "sandal", "sandals", "flipflop"
    ]

    private static func isSeasonalMismatch(_ a: Set<String>, _ b: Set<String>) -> Bool {
        (!a.isDisjoint(with: cold) && !b.isDisjoint(with: warm))
            || (!a.isDisjoint(with: warm) && !b.isDisjoint(with: cold))
    }

    /// Where a measured photograph starts counting as a loud piece.
    ///
    /// Deliberately looser than the thresholds the *profile* prints at: saying somebody
    /// keeps graphic things is a claim about them and should be sure, while declining to
    /// lead with two busy pieces together costs nothing but a reordering.
    static let statementBusyness = 0.5
    static let statementTextCoverage = 0.06

    /// The words that stood in for looking, before anything looked.
    ///
    /// Still here, and still used — for products nobody has saved, which is most of the
    /// catalogue. `ImageTagger` only runs over the collection, so the subject of a "wear it
    /// with" row on a product page has usually never been measured and this is all there is.
    static let statementWords: Set<String> = [
        "graphic", "print", "printed", "camo", "camouflage", "leopard", "zebra", "paisley",
        "floral", "tartan", "plaid", "argyle", "tiedye", "allover", "patchwork", "jacquard"
    ]

    private static func isLayering(_ one: GarmentSlot, _ other: GarmentSlot) -> Bool {
        let pair = Set([one, other])
        return pair == Set([.outerwear, .top])
    }
}

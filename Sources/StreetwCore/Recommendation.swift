// Recommendation.swift
// Turning a pile of vectors into an ordered list, and saying why.
//
// `BrandVector` answers "how alike are these two". That is the hard half and it was
// already good. This file is the half that was missing, and it is where the visible
// problems actually were:
//
// - **Popularity drowned taste at small numbers.** The ranking blended affinity with
//   `followers / mostFollowed`. With a handful of users the denominator is 2, so following
//   one extra person is worth 0.5 of a normalised unit — larger than the entire spread of
//   affinity across candidates, because every streetwear catalogue resembles every other
//   and similarities bunch in a narrow band. The list was therefore "whatever two people
//   follow", wearing the clothes of a taste engine. `Popularity.confidence` fixes the
//   arithmetic rather than the weight: a headcount nobody has voted in yet carries almost
//   no weight, and earns it as the counts grow.
//
// - **There was no way to say no.** Every signal in the app was positive — follows and
//   saves. A recommendation you reject is the cheapest, clearest signal a person can give,
//   and it was thrown away, so the same wrong brand came back every time the list
//   refreshed. `dismissed` is the other half of the taste vector.
//
// - **Nothing could say why.** A suggestion nobody can account for is indistinguishable
//   from a shuffle, which is exactly how the block read. `reasons(for:)` reports the terms
//   and categories the candidate actually shares with your taste, so the card can print a
//   line instead of a follower count.
//
// Kept here rather than in a view for the usual reason: the server ranks the candidate set
// and the phone re-ranks it against a taste profile that never leaves the device, so both
// ends need the same arithmetic and two copies would drift.

import Foundation

/// How much a raw follower count should be trusted.
public enum Popularity {
    /// Where a headcount starts being evidence rather than noise.
    ///
    /// Below this, "most followed" is one or two people and the normalised score is an
    /// artefact of the denominator, not a fact about the brand.
    public static let meaningfulFollowers = 8.0

    /// 0…1. Multiplies popularity's weight in the blend.
    ///
    /// Deliberately smooth rather than a threshold: a switch that flips at eight followers
    /// would reorder the whole list the day one person joined.
    public static func confidence(mostFollowed: Int) -> Double {
        guard mostFollowed > 0 else { return 0 }
        return min(1, Double(mostFollowed) / meaningfulFollowers)
    }

    /// A candidate's popularity, 0…1, or nil when there is nothing to measure against.
    public static func normalised(followers: Int, mostFollowed: Int) -> Double? {
        guard mostFollowed > 0 else { return nil }
        return min(1, Double(followers) / Double(mostFollowed))
    }
}

/// Ranks candidate brands against what somebody has kept and what they have refused.
public struct Recommender: Sendable {
    /// The centroid of what this person likes. Empty means no opinion on record.
    public var taste: BrandVector
    /// Brands explicitly rejected. Not merely filtered out — a candidate that *looks like*
    /// one of these is demoted too, which is the entire value of a negative signal. One
    /// dismissal of a technical-outdoor label should quiet the other four.
    public var dismissed: [BrandVector]

    /// How hard a resemblance to something refused counts against a candidate.
    ///
    /// Below the weight taste carries, on purpose. A dismissal is a smaller statement than
    /// a save — people reject things for reasons that have nothing to do with the clothes
    /// (they already own it, they know the brand, they were scrolling) — and treating it as
    /// equal and opposite would let one impatient tap hollow out the list.
    public var aversion: Double

    public init(taste: BrandVector = BrandVector(), dismissed: [BrandVector] = [], aversion: Double = 0.45) {
        self.taste = taste
        self.dismissed = dismissed
        self.aversion = aversion
    }

    /// The final ordering value for one candidate.
    ///
    /// - `affinity` is the server's own view — similarity to the brands already followed.
    /// - `popularity` is the normalised headcount, damped by `confidence`.
    ///
    /// Every term is optional and a missing one redistributes its weight rather than
    /// scoring zero, so a brand with no vector is ranked on what is known about it instead
    /// of being punished for a gap in the data.
    public func score(
        candidate: BrandVector?,
        affinity: Double?,
        popularity: Double?,
        confidence: Double = 1
    ) -> Double {
        var total = 0.0
        var weight = 0.0

        func add(_ value: Double?, _ w: Double) {
            guard let value, w > 0 else { return }
            total += value * w
            weight += w
        }

        if let candidate, !taste.isEmpty {
            add(taste.similarity(to: candidate), 0.5)
        }
        add(affinity, 0.3)
        add(popularity, 0.2 * max(0, min(1, confidence)))

        let base = weight > 0 ? total / weight : 0
        guard let candidate else { return base }

        // Subtracted after the mean rather than folded into it: this is a penalty, not
        // another opinion to average, and it has to be able to push a close match below a
        // mediocre one.
        return base - aversion * repulsion(from: candidate)
    }

    /// How much a candidate resembles the *nearest* thing that was refused.
    ///
    /// The nearest, not the average. Rejecting one loud graphic label says nothing about
    /// the quiet Japanese one also on the list, and averaging would spread the objection
    /// evenly over both.
    public func repulsion(from candidate: BrandVector) -> Double {
        dismissed.map { $0.similarity(to: candidate) }.max() ?? 0
    }
}

/// Whether a term from a brand's vocabulary is fit to be *printed* at somebody.
///
/// The vocabulary is deliberately unfiltered: `BrandVectorBuilder` keeps every token a
/// merchandiser wrote because IDF is what decides whether it means anything, and a code
/// nobody else uses is genuinely distinctive to the brand that uses it. That is right for
/// the *arithmetic* and wrong for the *caption* — a card that reads "LIKE YOUR ITP" is
/// telling somebody they have a taste for a three-letter internal code, under a brand it is
/// trying to sell them.
///
/// So this gate sits between the score and the sentence, and nowhere else. Nothing about
/// the ranking changes; a brand whose only shared terms are unreadable simply falls through
/// to the category line, which is the fallback that already exists for a brand with no
/// usable tags at all.
enum Trait {
    /// Words too short to say anything about a wardrobe, or that describe the shop rather
    /// than the clothes.
    ///
    /// A three-letter floor is the crude half and it is worth the cost: "tee", "cap" and
    /// "bag" are real losses, but they are also words that describe half of streetwear and
    /// so persuade nobody, while every three-letter token seen in real catalogue data —
    /// `itp`, `f26`, `rtv` — is an internal code. The named list is the part that matters:
    /// these are ordinary English words that pass every structural test and still say
    /// nothing ("LIKE YOUR SALE").
    private static let uninformative: Set<String> = [
        "new", "sale", "final", "shop", "all", "the", "and", "for", "with",
        "mens", "men", "womens", "women", "unisex", "kids", "youth", "adult",
        "size", "sizes", "color", "colour", "colors", "colours", "style", "styles",
        "product", "products", "item", "items", "collection", "collections",
        "featured", "restock", "restocked", "online", "exclusive", "available",
        "spring", "summer", "autumn", "winter", "season", "arrival", "arrivals",
        "clothing", "apparel", "accessories", "everything", "other", "misc"
    ]

    static func isPrintable(_ term: String) -> Bool {
        // Four letters, not three. See above — the loss is words that were never
        // persuasive; the gain is that no card advertises a merchandising code.
        guard term.count >= 4 else { return false }
        guard !uninformative.contains(term) else { return false }
        // A word has both kinds of letter in it. This is what catches the longer codes
        // that clear the length test — "sscw", "fwdrop" without its digits.
        let vowels: Set<Character> = ["a", "e", "i", "o", "u", "y"]
        let letters = Set(term)
        return !letters.isDisjoint(with: vowels) && !letters.isSubset(of: vowels)
    }
}

public extension BrandVector {
    /// What this brand and a taste profile actually have in common, most distinctive first.
    ///
    /// Reads off the vectors that already exist — the terms contributing most to the dot
    /// product, and the strongest shared category — so the reason a card prints is the
    /// reason the ranking used, not a sentence written next to it that could drift.
    ///
    /// Terms are the storefront's own words. That is a feature: "workwear", "japanese",
    /// "military" are how the brand describes itself, and a person reading them can tell
    /// instantly whether the match is right. It is also the limitation — a brand that tags
    /// nothing useful produces no reason, and the caller must be prepared to print none
    /// rather than inventing one.
    func sharedTraits(with other: BrandVector, limit: Int = 3) -> [String] {
        var scored: [(term: String, weight: Double)] = []

        for (term, weight) in vocabulary {
            guard let mine = other.vocabulary[term], Trait.isPrintable(term) else { continue }
            scored.append((term, weight * mine))
        }

        var out = scored
            .sorted { $0.weight > $1.weight }
            .prefix(limit)
            .map(\.term)

        // A category is a weaker statement than a word, so it only speaks when the words
        // are silent — which is the common case for a brand with a thin tag set, and
        // exactly when a card would otherwise have nothing to say for itself.
        //
        // **`unknown` is not a category.** It is the classifier declining to answer, and
        // most catalogues have a good share of it — so it is both a frequent match and a
        // meaningless one. Left in, the card read "LIKE YOUR UNKNOWN" on four suggestions
        // out of five, which is worse than the follower count it replaced.
        if out.isEmpty {
            let shared = categories
                .filter { $0.key != GarmentSlot.unknown.rawValue && other.categories[$0.key] != nil }
                .sorted { $0.value > $1.value }
            if let best = shared.first, best.value > 0.15 {
                out = [best.key]
            }
        }

        return out
    }
}

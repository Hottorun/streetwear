import Foundation
import Testing

@testable import StreetwCore

@Suite("Recommendation ranking")
struct RecommendationTests {
    /// Two brands that share a vocabulary, and one that shares nothing with either.
    private func vector(_ terms: [String: Double], categories: [String: Double] = [:]) -> BrandVector {
        BrandVector(categories: categories, vocabulary: terms)
    }

    private var workwear: BrandVector {
        vector(["workwear": 0.7, "denim": 0.5, "chore": 0.5], categories: ["bottom": 0.6, "outerwear": 0.4])
    }

    private var similarWorkwear: BrandVector {
        vector(["workwear": 0.6, "denim": 0.6, "canvas": 0.5], categories: ["bottom": 0.5, "outerwear": 0.5])
    }

    private var technical: BrandVector {
        vector(["gore": 0.7, "technical": 0.6, "shell": 0.4], categories: ["outerwear": 0.9])
    }

    /// The failure that made the list look arbitrary. With a handful of users the
    /// most-followed brand has two followers, so the normalised headcount swings by half a
    /// unit between brands nobody has really voted on — a bigger gap than the entire spread
    /// of affinity, which bunches because every streetwear catalogue resembles every other.
    @Test("A headcount nobody has voted in carries almost no weight")
    func popularityIsDampedWhenTiny() {
        #expect(Popularity.confidence(mostFollowed: 0) == 0)
        #expect(Popularity.confidence(mostFollowed: 2) < 0.3)
        #expect(Popularity.confidence(mostFollowed: 8) == 1)
        #expect(Popularity.confidence(mostFollowed: 400) == 1)

        let recommender = Recommender(taste: workwear)

        // Same taste match, wildly different follower counts, at a scale where the counts
        // mean nothing: the ordering must come from the clothes.
        let tiny = Popularity.confidence(mostFollowed: 2)
        let close = recommender.score(candidate: similarWorkwear, affinity: 0.5, popularity: 0.0, confidence: tiny)
        let far = recommender.score(candidate: technical, affinity: 0.5, popularity: 1.0, confidence: tiny)
        #expect(close > far, "taste must beat a two-person headcount")

        // And once the counts are real, popularity is allowed to matter again.
        let real = Popularity.confidence(mostFollowed: 200)
        let popular = recommender.score(candidate: technical, affinity: 0.5, popularity: 1.0, confidence: real)
        let unpopular = recommender.score(candidate: technical, affinity: 0.5, popularity: 0.0, confidence: real)
        #expect(popular > unpopular)
    }

    /// The signal the app had none of.
    @Test("A brand like one you refused is demoted")
    func dismissalDemotesLookalikes() {
        let neutral = Recommender(taste: workwear)
        let burned = Recommender(taste: workwear, dismissed: [technical])

        let before = neutral.score(candidate: technical, affinity: 0.6, popularity: 0.5)
        let after = burned.score(candidate: technical, affinity: 0.6, popularity: 0.5)
        #expect(after < before)

        // And it must not quietly punish everything else on the list.
        let unrelatedBefore = neutral.score(candidate: similarWorkwear, affinity: 0.6, popularity: 0.5)
        let unrelatedAfter = burned.score(candidate: similarWorkwear, affinity: 0.6, popularity: 0.5)
        #expect(abs(unrelatedAfter - unrelatedBefore) < 0.15, "one dismissal must not hollow out the list")
    }

    /// The nearest refusal, not the average of them — rejecting a loud graphic label says
    /// nothing about the quiet Japanese one further down the same list.
    @Test("Repulsion measures the nearest refusal")
    func repulsionUsesNearest() {
        let recommender = Recommender(taste: workwear, dismissed: [technical, similarWorkwear])
        let near = recommender.repulsion(from: similarWorkwear)
        let far = recommender.repulsion(from: vector(["knitwear": 0.9]))
        #expect(near > 0.5)
        #expect(far < 0.2)
    }

    @Test("A candidate with no vector is ranked on what is known, not dropped")
    func missingVectorIsNotPunished() {
        let recommender = Recommender(taste: workwear)
        let scored = recommender.score(candidate: nil, affinity: 0.8, popularity: 0.2)
        #expect(scored > 0.4, "a gap in the data is not a reason to bury a brand")
    }

    /// A suggestion nobody can account for is indistinguishable from a shuffle.
    @Test("The reason a card prints is the reason the ranking used")
    func reportsSharedTraits() {
        let shared = similarWorkwear.sharedTraits(with: workwear)
        #expect(shared.contains("workwear"))
        #expect(shared.contains("denim"))
        #expect(!shared.contains("gore"))
        #expect(shared.count <= 3)
    }

    /// A brand that tags nothing useful still has a category, and a card with nothing to
    /// say for itself is the thing being fixed.
    @Test("A category speaks when the words are silent")
    func fallsBackToCategory() {
        let untagged = BrandVector(categories: ["outerwear": 0.8])
        let mine = BrandVector(categories: ["outerwear": 0.6, "top": 0.4])
        #expect(untagged.sharedTraits(with: mine) == ["outerwear"])
    }

    /// ...and when there is genuinely nothing in common, it says nothing rather than
    /// inventing a reason.
    @Test("No shared ground means no claim")
    func staysSilentWhenNothingMatches() {
        #expect(technical.sharedTraits(with: vector(["knitwear": 0.9])).isEmpty)
    }

    /// "Unknown" is the classifier declining to answer, not a kind of garment — and it is
    /// a large share of most catalogues, so it matches constantly and means nothing. Left
    /// in, every card read "LIKE YOUR UNKNOWN".
    @Test("The classifier's shrug is never a reason")
    func neverReportsUnknownAsATrait() {
        let vague = BrandVector(categories: [GarmentSlot.unknown.rawValue: 0.9])
        let mine = BrandVector(categories: [GarmentSlot.unknown.rawValue: 0.8, "top": 0.2])
        #expect(vague.sharedTraits(with: mine).isEmpty)

        // ...but a real category alongside it still speaks.
        let mixed = BrandVector(categories: [GarmentSlot.unknown.rawValue: 0.6, "bottom": 0.4])
        let alsoBottoms = BrandVector(categories: [GarmentSlot.unknown.rawValue: 0.5, "bottom": 0.5])
        #expect(mixed.sharedTraits(with: alsoBottoms) == ["bottom"])
    }
}

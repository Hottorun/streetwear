import Foundation
import Testing

@testable import StreetwCore

@Suite("Which saves count for taste")
struct TasteRuleTests {
    @Test("A save on no board, or only on ordinary boards, counts")
    func defaultCounts() {
        #expect(TasteRule.role(isExcluded: false, boards: []) == .counts)
        #expect(TasteRule.role(isExcluded: false, boards: [.counts]) == .counts)
    }

    /// The most specific statement anybody can make about one garment.
    @Test("The save's own exclusion beats every board, the mood included")
    func exclusionWins() {
        #expect(TasteRule.role(isExcluded: true, boards: []) == .ignored)
        #expect(TasteRule.role(isExcluded: true, boards: [.mood]) == .ignored)
        #expect(TasteRule.role(isExcluded: true, boards: [.mood, .counts]) == .ignored)
    }

    /// `.counts` is what every board is until somebody says otherwise, so it is not a vote.
    @Test("A board that doesn't count outvotes an ordinary one")
    func ignoredBeatsDefault() {
        #expect(TasteRule.role(isExcluded: false, boards: [.ignored]) == .ignored)
        #expect(TasteRule.role(isExcluded: false, boards: [.ignored, .counts]) == .ignored)
    }

    /// Put on the mood board on purpose, which is the current intent.
    @Test("The mood outvotes a board that doesn't count")
    func moodBeatsIgnored() {
        #expect(TasteRule.role(isExcluded: false, boards: [.mood]) == .mood)
        #expect(TasteRule.role(isExcluded: false, boards: [.mood, .ignored]) == .mood)
    }

    @Test("Without a mood, a save weighs one and an ignored one nothing")
    func plainWeights() {
        #expect(TasteRule.weights([.counts, .ignored, .counts]) == [1, 0, 1])
        #expect(TasteRule.weights([]).isEmpty)
    }

    /// Six suits against two hundred saves at a fixed multiplier is a mood that does nothing.
    @Test("A small mood board still carries half the vector")
    func moodIsHalf() {
        let roles = Array(repeating: TasteRule.Role.counts, count: 200)
            + Array(repeating: .mood, count: 4)
        let weights = TasteRule.weights(roles)
        let mood = weights.suffix(4).reduce(0, +)
        let rest = weights.prefix(200).reduce(0, +)
        #expect(mood == rest)
        #expect(weights.last == 50)
    }

    /// A lean, not an inflation: when the mood is already most of the collection it is
    /// simply counted, never weighted below one.
    @Test("A mood bigger than the rest weighs one each")
    func largeMoodIsNotDiscounted() {
        let weights = TasteRule.weights([.mood, .mood, .mood, .counts])
        #expect(weights == [1, 1, 1, 1])
        #expect(TasteRule.weights([.mood, .ignored]) == [1, 0])
    }
}

@Suite("A taste vector with weights")
struct WeightedTasteTests {
    private func product(_ title: String, type: String, tags: [String]) -> ProductSummary {
        ProductSummary(title: title, productType: type, tags: tags, priceAmount: nil, publishedAt: nil)
    }

    private var reference: [BrandVector] {
        Array(BrandVectorBuilder.vectors(for: [
            UUID(): (0..<6).map { product("Tee \($0)", type: "T-Shirts", tags: ["skate", "graphic"]) },
            UUID(): (0..<6).map { product("Blazer \($0)", type: "Blazers", tags: ["tailoring", "wool"]) }
        ]).values)
    }

    @Test("Weighing a product nothing is the same as leaving it out")
    func zeroIsAbsent() {
        let tee = product("Tee", type: "T-Shirts", tags: ["skate", "graphic"])
        let blazer = product("Blazer", type: "Blazers", tags: ["tailoring", "wool"])
        let reference = self.reference

        let weighted = BrandVectorBuilder.taste(from: [tee, blazer], weights: [1, 0], comparedWith: reference)
        let alone = BrandVectorBuilder.taste(from: [tee], comparedWith: reference)
        #expect(weighted == alone)
        #expect(BrandVectorBuilder.taste(from: [tee], weights: [0], comparedWith: reference).isEmpty)
    }

    @Test("A weight of two is the same as the product twice")
    func weightIsRepetition() {
        let tee = product("Tee", type: "T-Shirts", tags: ["skate", "graphic"])
        let blazer = product("Blazer", type: "Blazers", tags: ["tailoring", "wool"])
        let reference = self.reference

        let weighted = BrandVectorBuilder.taste(from: [tee, blazer], weights: [1, 2], comparedWith: reference)
        let repeated = BrandVectorBuilder.taste(from: [tee, blazer, blazer], comparedWith: reference)
        #expect(weighted.vocabulary.keys == repeated.vocabulary.keys)
        for (term, value) in weighted.vocabulary {
            #expect(abs(value - (repeated.vocabulary[term] ?? 0)) < 1e-9)
        }
        #expect(weighted.categories == repeated.categories)
    }

    /// The point of the mood: the vector moves towards the board without forgetting the rest.
    @Test("Leaning on the mood moves the vector towards it")
    func moodLeans() {
        let tees = (0..<10).map { product("Tee \($0)", type: "T-Shirts", tags: ["skate", "graphic"]) }
        let blazers = (0..<2).map { product("Blazer \($0)", type: "Blazers", tags: ["tailoring", "wool"]) }
        let reference = self.reference
        let tailored = reference.first { $0.vocabulary["tailoring"] != nil }!

        let roles = Array(repeating: TasteRule.Role.counts, count: 10) + [.mood, .mood]
        let leaning = BrandVectorBuilder.taste(
            from: tees + blazers,
            weights: TasteRule.weights(roles),
            comparedWith: reference
        )
        let plain = BrandVectorBuilder.taste(from: tees + blazers, comparedWith: reference)
        #expect(leaning.similarity(to: tailored) > plain.similarity(to: tailored))
    }
}

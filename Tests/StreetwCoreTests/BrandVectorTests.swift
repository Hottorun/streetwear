import Foundation
import Testing

@testable import StreetwCore

@Suite("Brand vectors")
struct BrandVectorTests {
    private func product(
        _ title: String,
        type: String? = nil,
        tags: [String] = [],
        price: Double? = nil,
        daysAgo: Double? = nil
    ) -> ProductSummary {
        ProductSummary(
            title: title,
            productType: type,
            tags: tags,
            priceAmount: price,
            publishedAt: daysAgo.map { Date().addingTimeInterval(-$0 * 86_400) }
        )
    }

    /// Four brands: two skate labels, a workwear label, a footwear label. The two that
    /// share a vocabulary should come out closest.
    private var catalog: [UUID: [ProductSummary]] {
        [
            skateA: (0..<8).map { product("Tee \($0)", type: "T-Shirts", tags: ["skate", "graphic"], price: 45) },
            skateB: (0..<8).map { product("Tee \($0)", type: "T-Shirts", tags: ["skate", "deck"], price: 50) },
            workwear: (0..<8).map { product("Chore \($0)", type: "Jackets", tags: ["workwear", "utility"], price: 220) },
            shoes: (0..<8).map { product("Runner \($0)", type: "Footwear", tags: ["running", "performance"], price: 130) }
        ]
    }

    private let skateA = UUID()
    private let skateB = UUID()
    private let workwear = UUID()
    private let shoes = UUID()

    @Test("Brands sharing a vocabulary and a category score closest")
    func similarBrandsScoreHighest() {
        let vectors = BrandVectorBuilder.vectors(for: catalog)
        let a = try! #require(vectors[skateA])

        let toSkateB = a.similarity(to: try! #require(vectors[skateB]))
        let toWorkwear = a.similarity(to: try! #require(vectors[workwear]))
        let toShoes = a.similarity(to: try! #require(vectors[shoes]))

        #expect(toSkateB > toWorkwear)
        #expect(toSkateB > toShoes)
    }

    @Test("A brand is maximally similar to itself")
    func selfSimilarity() {
        let vectors = BrandVectorBuilder.vectors(for: catalog)
        let a = try! #require(vectors[skateA])
        #expect(a.similarity(to: a) > 0.99)
    }

    /// Brands store their own currency and this system has no exchange rates anywhere, so
    /// price is only ever compared as a rank.
    @Test("Price is compared by rank, never by amount")
    func priceIsRanked() {
        let cheap = UUID(), dear = UUID()
        let vectors = BrandVectorBuilder.vectors(for: [
            cheap: [product("Tee", type: "T-Shirts", tags: ["a"], price: 30)],
            dear: [product("Tee", type: "T-Shirts", tags: ["a"], price: 3000)]
        ])

        #expect(vectors[cheap]?.pricePercentile == 0)
        #expect(vectors[dear]?.pricePercentile == 1)
    }

    /// A brand that publishes no prices must be compared on everything else rather than
    /// penalised for the gap.
    @Test("A missing component is skipped, not scored as a mismatch")
    func missingComponentsAreSkipped() {
        let withPrice = BrandVector(
            categories: ["top": 1], genders: ["mens": 1],
            vocabulary: ["skate": 1], pricePercentile: 0.2
        )
        let without = BrandVector(
            categories: ["top": 1], genders: ["mens": 1],
            vocabulary: ["skate": 1], pricePercentile: nil
        )

        #expect(withPrice.similarity(to: without) > 0.99, "identical on every shared axis")
    }

    /// The mechanism that stops Kith's 130 internal merchandising codes from dominating:
    /// a term every brand uses carries no information and is dropped.
    @Test("Terms common to every brand are discarded")
    func universalTermsAreDropped() {
        var withNoise = catalog
        for (id, products) in withNoise {
            withNoise[id] = products.map {
                ProductSummary(
                    title: $0.title,
                    productType: $0.productType,
                    tags: $0.tags + ["final", "sale", "primary"],
                    priceAmount: $0.priceAmount
                )
            }
        }

        let vectors = BrandVectorBuilder.vectors(for: withNoise)
        let vocabulary = try! #require(vectors[skateA]).vocabulary

        #expect(vocabulary["final"] == nil)
        #expect(vocabulary["sale"] == nil)
        #expect(vocabulary["skate"] != nil, "a term that distinguishes must survive")
    }

    /// Product names are unique to one brand, so IDF would treat them as maximally
    /// distinctive — the opposite of useful.
    @Test("Product names don't enter the vocabulary")
    func titlesAreExcluded() {
        let terms = BrandVectorBuilder.terms(
            in: product("Nocturne Nathan", type: "Pants", tags: ["workwear"])
        )
        #expect(!terms.contains("nocturne"))
        #expect(!terms.contains("nathan"))
        #expect(terms.contains("workwear"))
        #expect(terms.contains("pants"))
    }

    @Test("An empty catalog produces an empty vector rather than crashing")
    func emptyCatalog() {
        #expect(BrandVectorBuilder.vectors(for: [:]).isEmpty)

        let id = UUID()
        let vectors = BrandVectorBuilder.vectors(for: [id: []])
        #expect(vectors[id]?.isEmpty == true)
    }

    /// A taste profile built on the phone from saves, never sent anywhere, still has to
    /// rank the same candidates the server sent.
    @Test("A locally-built taste vector ranks candidates sensibly")
    func localTasteVector() {
        let vectors = BrandVectorBuilder.vectors(for: catalog)
        let candidates = [vectors[skateB]!, vectors[workwear]!, vectors[shoes]!]

        // Someone whose saves are all skate tees.
        let taste = BrandVectorBuilder.taste(
            from: (0..<5).map { product("Tee \($0)", type: "T-Shirts", tags: ["skate", "graphic"]) },
            comparedWith: candidates
        )

        let ranked = candidates
            .map { (vector: $0, score: taste.similarity(to: $0)) }
            .sorted { $0.score > $1.score }

        #expect(ranked.first?.vector == vectors[skateB], "the other skate brand should win")
    }

    @Test("The mean of several vectors is a usable centroid")
    func meanVector() {
        let vectors = BrandVectorBuilder.vectors(for: catalog)
        let centroid = BrandVector.mean(of: [vectors[skateA]!, vectors[skateB]!])

        #expect(!centroid.isEmpty)
        // Closer to the skate brands it averages than to the ones it doesn't.
        #expect(centroid.similarity(to: vectors[skateA]!) > centroid.similarity(to: vectors[shoes]!))
    }

    @Test("Averaging nothing is empty rather than a crash")
    func meanOfNothing() {
        #expect(BrandVector.mean(of: []).isEmpty)
        #expect(BrandVector.mean(of: [BrandVector()]).isEmpty)
    }

    /// A brand publishing constantly and one publishing twice a year are different things
    /// to follow even when they sell the same clothes.
    @Test("Cadence separates a weekly brand from a seasonal one")
    func cadenceSeparates() {
        let weekly = UUID(), seasonal = UUID()
        let vectors = BrandVectorBuilder.vectors(for: [
            weekly: (0..<40).map { product("Item \($0)", type: "T-Shirts", tags: ["a"], daysAgo: Double($0)) },
            seasonal: (0..<4).map { product("Item \($0)", type: "T-Shirts", tags: ["a"], daysAgo: Double($0) * 60) }
        ])

        let fast = vectors[weekly]?.cadence
        let slow = vectors[seasonal]?.cadence
        #expect(fast != nil && slow != nil)
        #expect((fast ?? 0) > (slow ?? 0))
    }
}

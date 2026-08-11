// BrandVector.swift
// What a brand is *like*, as numbers, so "brands similar to the ones you follow" is a
// calculation rather than an opinion.
//
// Built entirely from the catalog already stored — titles, product types, tags and
// prices. No taxonomy to maintain, no editorial list, nothing to keep up to date as
// brands come and go.
//
// Five components, each chosen because it is a real axis along which streetwear brands
// differ and because it can be computed from data we have:
//
// - **Categories** — a footwear brand and an outerwear brand are not alternatives to each
//   other however similar their prices.
// - **Vocabulary** — the strongest aesthetic signal there is. "Workwear", "skate",
//   "military", "japanese" tell you more than any number does. Weighted by inverse
//   document frequency so a term every brand uses counts for nothing, which is what
//   flattens Kith's 130 internal merchandising codes.
// - **Gender mix** — a womenswear label is not a substitute for a menswear one.
// - **Price position** — as a *percentile across brands*, never as an amount. Brands store
//   their own currency and there are no exchange rates anywhere in this system; ranking
//   sidesteps the conversion entirely and a €200 hoodie brand lands beside a $220 one.
// - **Cadence** — how often it publishes. A weekly-drop brand and a two-collections-a-year
//   brand are different things to follow even when they sell the same clothes.
//
// The honest limitation: this measures *catalog composition*, which is a proxy for
// aesthetic rather than the thing itself. Two brands can both sell mid-price black hoodies
// and look nothing alike. Vocabulary carries most of the real signal, and it is weakest
// exactly where tags are weakest — which is why callers should keep a popularity floor
// rather than trusting this alone.

import Foundation

/// The minimum a product contributes. Deliberately not a model type: the server passes
/// rows, the app passes saved items, and neither has to know about the other.
public struct ProductSummary: Sendable, Hashable {
    public var title: String
    public var productType: String?
    public var tags: [String]
    /// In the brand's own currency, which is why only its *rank* is ever used.
    public var priceAmount: Double?
    public var publishedAt: Date?

    public init(
        title: String,
        productType: String? = nil,
        tags: [String] = [],
        priceAmount: Double? = nil,
        publishedAt: Date? = nil
    ) {
        self.title = title
        self.productType = productType
        self.tags = tags
        self.priceAmount = priceAmount
        self.publishedAt = publishedAt
    }
}

public struct BrandVector: Codable, Sendable, Hashable {
    /// `GarmentSlot.rawValue` → share of the catalog. Sums to 1 when non-empty.
    public var categories: [String: Double]
    /// `Gender.rawValue` → share.
    public var genders: [String: Double]
    /// TF-IDF weighted terms, L2-normalised.
    public var vocabulary: [String: Double]
    /// 0 (cheapest brand) … 1 (dearest). Nil when the brand publishes no prices.
    public var pricePercentile: Double?
    /// Products per week, squashed to 0…1 so a firehose can't dominate the distance.
    public var cadence: Double?

    public init(
        categories: [String: Double] = [:],
        genders: [String: Double] = [:],
        vocabulary: [String: Double] = [:],
        pricePercentile: Double? = nil,
        cadence: Double? = nil
    ) {
        self.categories = categories
        self.genders = genders
        self.vocabulary = vocabulary
        self.pricePercentile = pricePercentile
        self.cadence = cadence
    }

    public var isEmpty: Bool {
        categories.isEmpty && genders.isEmpty && vocabulary.isEmpty
    }

    /// How alike two brands are, 0…1.
    ///
    /// A weighted mean of per-component similarities rather than one cosine over a
    /// concatenated vector, so each axis contributes what it is worth regardless of how
    /// many dimensions it happens to occupy — vocabulary has hundreds of terms and gender
    /// has five, and a single cosine would let the former drown the latter by sheer count.
    ///
    /// Components missing on either side are skipped and their weight redistributed, so a
    /// brand with no prices is compared on everything else rather than being penalised for
    /// a gap in the data.
    public func similarity(to other: BrandVector) -> Double {
        var total = 0.0
        var weight = 0.0

        func add(_ value: Double?, _ w: Double) {
            guard let value else { return }
            total += value * w
            weight += w
        }

        add(Self.cosine(vocabulary, other.vocabulary), 0.35)
        add(Self.cosine(categories, other.categories), 0.30)
        add(Self.cosine(genders, other.genders), 0.15)
        add(Self.closeness(pricePercentile, other.pricePercentile), 0.10)
        add(Self.closeness(cadence, other.cadence), 0.10)

        guard weight > 0 else { return 0 }
        return total / weight
    }

    /// Nil when either side is absent — an unknown is not a mismatch.
    static func closeness(_ a: Double?, _ b: Double?) -> Double? {
        guard let a, let b else { return nil }
        return 1 - abs(a - b)
    }

    static func cosine(_ a: [String: Double], _ b: [String: Double]) -> Double? {
        guard !a.isEmpty, !b.isEmpty else { return nil }

        var dot = 0.0
        // Walk the smaller side; the intersection is what matters and these are sparse.
        let (small, large) = a.count <= b.count ? (a, b) : (b, a)
        for (key, value) in small {
            if let other = large[key] { dot += value * other }
        }

        let normA = sqrt(a.values.reduce(0) { $0 + $1 * $1 })
        let normB = sqrt(b.values.reduce(0) { $0 + $1 * $1 })
        guard normA > 0, normB > 0 else { return nil }
        return min(1, max(0, dot / (normA * normB)))
    }

    /// The centroid of several brands — a person's taste, as the average of what they
    /// already follow or save.
    public static func mean(of vectors: [BrandVector]) -> BrandVector {
        let usable = vectors.filter { !$0.isEmpty }
        guard !usable.isEmpty else { return BrandVector() }

        func average(_ maps: [[String: Double]]) -> [String: Double] {
            var sum: [String: Double] = [:]
            for map in maps {
                for (key, value) in map { sum[key, default: 0] += value }
            }
            let count = Double(max(1, maps.count))
            return sum.mapValues { $0 / count }
        }

        let prices = usable.compactMap(\.pricePercentile)
        let cadences = usable.compactMap(\.cadence)

        return BrandVector(
            categories: average(usable.map(\.categories)),
            genders: average(usable.map(\.genders)),
            vocabulary: average(usable.map(\.vocabulary)),
            pricePercentile: prices.isEmpty ? nil : prices.reduce(0, +) / Double(prices.count),
            cadence: cadences.isEmpty ? nil : cadences.reduce(0, +) / Double(cadences.count)
        )
    }
}

public enum BrandVectorBuilder {
    /// Terms this common across brands carry no information and are dropped outright.
    private static let maxDocumentFrequency = 0.6
    /// Below this many brands, IDF is meaningless — with three brands every term is either
    /// in one third or all of them.
    private static let minimumBrandsForIDF = 4
    /// Vocabulary is truncated to the most distinctive terms per brand, so one brand with
    /// a huge catalog doesn't get a longer vector than everyone else.
    private static let vocabularyLimit = 40

    /// Builds a vector per brand. Takes every brand at once because two of the components
    /// — inverse document frequency and price percentile — are defined *relative to the
    /// others* and cannot be computed one brand at a time.
    public static func vectors(for catalogs: [UUID: [ProductSummary]]) -> [UUID: BrandVector] {
        guard !catalogs.isEmpty else { return [:] }

        // Term frequency per brand, and how many brands each term appears in.
        var termFrequency: [UUID: [String: Double]] = [:]
        var documentCount: [String: Int] = [:]

        for (id, products) in catalogs {
            var counts: [String: Double] = [:]
            for product in products {
                for term in terms(in: product) { counts[term, default: 0] += 1 }
            }
            termFrequency[id] = counts
            for term in counts.keys { documentCount[term, default: 0] += 1 }
        }

        let brandCount = catalogs.count
        let medians = catalogs.mapValues { median($0.compactMap(\.priceAmount)) }
        let ranks = percentileRanks(of: medians)

        var result: [UUID: BrandVector] = [:]
        for (id, products) in catalogs {
            result[id] = BrandVector(
                categories: distribution(products.map { product in
                    GarmentClassifier.classify(
                        title: product.title,
                        productType: product.productType,
                        tags: product.tags
                    ).rawValue
                }),
                genders: distribution(products.map { product in
                    GenderClassifier.classify(
                        title: product.title,
                        productType: product.productType,
                        tags: product.tags
                    ).rawValue
                }),
                vocabulary: weighted(
                    termFrequency[id] ?? [:],
                    documentCount: documentCount,
                    brandCount: brandCount
                ),
                pricePercentile: ranks[id] ?? nil,
                cadence: cadence(of: products)
            )
        }
        return result
    }

    /// A vector for an arbitrary bag of products — one person's saves, say — scored
    /// against the same vocabulary weighting as the brands it will be compared with.
    ///
    /// This is what lets the phone build a taste profile from things it has never sent
    /// anywhere: the saves stay local, and only the comparison crosses the boundary.
    public static func taste(
        from products: [ProductSummary],
        comparedWith reference: [BrandVector]
    ) -> BrandVector {
        guard !products.isEmpty else { return BrandVector() }

        // The reference vectors are already IDF-weighted, so rather than recompute
        // document frequencies the local side simply scores terms by raw frequency and
        // lets the cosine do the rest. Over-weighting a common term costs a little
        // precision; inventing a different weighting scheme would cost correctness.
        var counts: [String: Double] = [:]
        for product in products {
            for term in terms(in: product) { counts[term, default: 0] += 1 }
        }

        // Keep only terms the reference set actually uses — anything else can never
        // contribute to a similarity and would only distort the norm.
        let known = Set(reference.flatMap(\.vocabulary.keys))
        if !known.isEmpty { counts = counts.filter { known.contains($0.key) } }

        return BrandVector(
            categories: distribution(products.map {
                GarmentClassifier.classify(
                    title: $0.title, productType: $0.productType, tags: $0.tags
                ).rawValue
            }),
            genders: distribution(products.map {
                GenderClassifier.classify(
                    title: $0.title, productType: $0.productType, tags: $0.tags
                ).rawValue
            }),
            vocabulary: normalise(Array(counts.sorted { $0.value > $1.value }.prefix(vocabularyLimit))),
            pricePercentile: nil,
            cadence: nil
        )
    }

    // MARK: - Components

    /// Tags and product type, tokenised. Titles are excluded on purpose: they are
    /// product names — "Nathan", "Nocturne" — and contribute noise that is unique to one
    /// brand, which IDF would then treat as maximally distinctive.
    static func terms(in product: ProductSummary) -> [String] {
        var out: [String] = []
        for tag in product.tags { out.append(contentsOf: tokens(tag)) }
        if let type = product.productType { out.append(contentsOf: tokens(type)) }
        return out
    }

    private static func tokens(_ text: String) -> [String] {
        text.lowercased()
            .split { !$0.isLetter }
            .map(String.init)
            // Two-letter fragments and pure noise carry nothing; numbers are dropped by
            // splitting on non-letters, which also removes date-shaped merchandising
            // codes like "020626kith".
            .filter { $0.count > 2 }
    }

    private static func distribution(_ values: [String]) -> [String: Double] {
        guard !values.isEmpty else { return [:] }
        var counts: [String: Double] = [:]
        for value in values { counts[value, default: 0] += 1 }
        let total = Double(values.count)
        return counts.mapValues { $0 / total }
    }

    private static func weighted(
        _ frequencies: [String: Double],
        documentCount: [String: Int],
        brandCount: Int
    ) -> [String: Double] {
        guard !frequencies.isEmpty else { return [:] }
        let total = frequencies.values.reduce(0, +)
        guard total > 0 else { return [:] }

        let scored: [(String, Double)] = frequencies.compactMap { term, count in
            let appearances = documentCount[term] ?? 1
            let share = Double(appearances) / Double(brandCount)

            // With too few brands, IDF is noise — fall back to plain frequency rather
            // than a weighting derived from a sample that can't support one.
            guard brandCount >= minimumBrandsForIDF else {
                return (term, count / total)
            }
            guard share <= maxDocumentFrequency else { return nil }

            let idf = log(Double(brandCount) / Double(appearances))
            return (term, (count / total) * idf)
        }

        return normalise(Array(scored.sorted { $0.1 > $1.1 }.prefix(vocabularyLimit)))
    }

    /// L2 normalisation, so a brand with a big catalog isn't automatically "more" of
    /// everything than a small one.
    private static func normalise(_ pairs: [(String, Double)]) -> [String: Double] {
        let norm = sqrt(pairs.reduce(0) { $0 + $1.1 * $1.1 })
        guard norm > 0 else { return [:] }
        return Dictionary(pairs.map { ($0.0, $0.1 / norm) }, uniquingKeysWith: { a, _ in a })
    }

    private static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        return sorted.count.isMultiple(of: 2)
            ? (sorted[middle - 1] + sorted[middle]) / 2
            : sorted[middle]
    }

    /// Rank rather than value, which is what makes this currency-blind.
    private static func percentileRanks(of medians: [UUID: Double?]) -> [UUID: Double?] {
        let priced = medians.compactMap { key, value in value.map { (key, $0) } }
        guard priced.count > 1 else {
            return medians.mapValues { $0 == nil ? nil : 0.5 }
        }

        let sorted = priced.sorted { $0.1 < $1.1 }
        var ranks: [UUID: Double?] = [:]
        for (index, entry) in sorted.enumerated() {
            ranks[entry.0] = Double(index) / Double(sorted.count - 1)
        }
        for (key, value) in medians where value == nil { ranks[key] = Double?.none }
        return ranks
    }

    /// Products per week over the window the catalog covers, squashed so a firehose can't
    /// dominate the distance.
    private static func cadence(of products: [ProductSummary]) -> Double? {
        let dates = products.compactMap(\.publishedAt).sorted()
        guard let first = dates.first, let last = dates.last, dates.count > 1 else { return nil }

        let weeks = max(1, last.timeIntervalSince(first) / (7 * 86_400))
        let perWeek = Double(dates.count) / weeks
        // 20+ products a week is already "constant", so everything above saturates.
        return min(1, perWeek / 20)
    }
}

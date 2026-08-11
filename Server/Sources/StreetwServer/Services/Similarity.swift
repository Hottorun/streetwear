// Similarity.swift
// Keeping a vector per brand, so "brands like the ones you follow" is a lookup.
//
// Rebuilt on a schedule rather than per request. Two of the components — inverse document
// frequency and price percentile — are defined relative to *every other brand*, so the
// unit of work is the whole catalog and not one brand; doing that inside a request would
// mean scanning every product to answer a single call.
//
// The build is pure arithmetic over rows already in memory, so it is cheap at this scale.
// It is cached with a TTL rather than persisted because it is entirely derived: a stale
// vector is worse than a missing one, and a restart recomputing it costs one pass.

import Fluent
import Foundation
import StreetwCore
import Vapor

actor BrandSimilarity {
    private let app: Application
    /// Long, because the inputs barely move — a brand's character does not change between
    /// polls, and a term entering the vocabulary is a weeks-long process.
    private let ttl: TimeInterval

    private var vectors: [UUID: BrandVector] = [:]
    private var builtAt: Date?
    private var isBuilding = false

    init(app: Application, ttl: TimeInterval = 6 * 3600) {
        self.app = app
        self.ttl = ttl
    }

    /// Every brand's vector, rebuilding if the cache has expired.
    func all() async -> [UUID: BrandVector] {
        if let builtAt, Date().timeIntervalSince(builtAt) < ttl, !vectors.isEmpty {
            return vectors
        }
        await rebuild()
        return vectors
    }

    /// Ranks `candidates` by how close they are to the centroid of `followed`.
    ///
    /// Returns an affinity per candidate rather than a sorted list, so the caller can
    /// blend it with popularity — this signal measures *catalog composition*, which is a
    /// proxy for aesthetic rather than the thing itself, and it should never be the only
    /// vote.
    func affinities(for candidates: [UUID], followed: [UUID]) async -> [UUID: Double] {
        let vectors = await all()
        let mine = followed.compactMap { vectors[$0] }
        guard !mine.isEmpty else { return [:] }

        let taste = BrandVector.mean(of: mine)
        guard !taste.isEmpty else { return [:] }

        var result: [UUID: Double] = [:]
        for id in candidates {
            guard let vector = vectors[id], !vector.isEmpty else { continue }
            result[id] = taste.similarity(to: vector)
        }
        return result
    }

    func vector(for id: UUID) async -> BrandVector? {
        await all()[id]
    }

    private func rebuild() async {
        guard !isBuilding else { return }
        isBuilding = true
        defer { isBuilding = false }

        do {
            // Only what the vector actually reads. The full product rows would be several
            // hundred megabytes of image URLs and descriptions for a calculation that
            // needs four fields.
            let products = try await ProductModel.query(on: app.db)
                .field(\.$brand.$id)
                .field(\.$title)
                .field(\.$productType)
                .field(\.$tags)
                .field(\.$priceAmount)
                .field(\.$publishedAt)
                .all()

            var catalogs: [UUID: [ProductSummary]] = [:]
            for product in products {
                catalogs[product.$brand.id, default: []].append(
                    ProductSummary(
                        title: product.title,
                        productType: product.productType,
                        tags: product.tags,
                        priceAmount: product.priceAmount,
                        publishedAt: product.publishedAt
                    )
                )
            }

            vectors = BrandVectorBuilder.vectors(for: catalogs)
            builtAt = Date()
            app.logger.info("similarity: built vectors for \(vectors.count) brands")
        } catch {
            app.logger.error("similarity: could not build vectors: \(error)")
        }
    }
}

extension Application {
    private struct SimilarityKey: StorageKey {
        typealias Value = BrandSimilarity
    }

    var similarity: BrandSimilarity? {
        get { storage[SimilarityKey.self] }
        set { storage[SimilarityKey.self] = newValue }
    }
}

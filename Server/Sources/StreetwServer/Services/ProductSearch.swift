// ProductSearch.swift
// Shop's field, answered over the whole catalogue the server holds.
//
// **One grammar, both ends.** The phone searches the few hundred products per shop it keeps;
// this searches everything the poller has stored. A query must not mean something different
// on the two, so the text is parsed here by the same `ShopQuery` the phone parses it with,
// and matched, constrained, ranked and explained by the same `ShopSearch.run` — price bounds,
// "no …", "in my size" through `SizeProfile.claims` in each product's `SizeContext`, the
// gender filter, sold-out-last, the six failures. What the server adds is only the part a
// phone does not need: an index to find the candidates in a catalogue too large to load
// (`CatalogueTextIndex`), and the database's answer to which words exist at all.
//
// The order, then:
//
// 1. **Find**: the index hands over the best `pool` candidates — every word first, then the
//    full-text rank — with what can be said in SQL (a price bound, a ruled-out word) already
//    applied, so the candidates are spent on what can survive. A second, smaller read without
//    those is taken when they applied, so a search that the price empties can still say how
//    many matched and what the cheapest was.
// 2. **Ask** which words exist anywhere in scope (`existing`), so a rare word crowded out of
//    the candidates is required exactly as it would be on a phone holding the whole store.
// 3. **Match**, by `ShopSearch.run`: the grammar's filters in their fixed order, then its
//    ranking — available first, the leanings, the field-weighted score, **then the index's
//    rank**, recency and the id. Total, and no randomness: the same query is the same page.
// 4. **Page**, by offset into that order, and hydrate only the page.
//
// Semantic retrieval, where it is switched on (`Application.semanticSearch`), adds the
// query's nearest neighbours to the candidates and to their rank; it never adds a match the
// grammar would not make. With the provider down or slow the full-text answer stands.

import Fluent
import Foundation
import SQLKit
import StreetwCore
import Vapor

enum ProductSearch {
    /// Candidates read for the answer. Enough that `ShopSearch.limit` (200) exact matches
    /// survive the gender filter and "in my size" on most queries; reaching it is said as
    /// `isCapped`, and the screen prints "200+".
    static let pool = 600
    /// Candidates read without the SQL narrowing, to say why a narrowed search came back empty.
    static let diagnosticPool = 200
    static let semanticPool = 100
    /// How long a search waits for its query to be embedded before answering without it.
    static let embeddingTimeout = 1.5
    static let defaultLimit = 40
    static let maxLimit = 100

    struct Ask: Sendable {
        var text: String
        var scope: ProductSearchScope
        var cheaper = false
        var formal = false
        var inMySize = false
        var limit = ProductSearch.defaultLimit
        var offset = 0
    }

    // MARK: - Scope

    /// The brands a caller's search covers and the shop serving each.
    static func scope(
        _ kind: ProductSearchScope,
        for user: UserModel,
        app: Application,
        on db: any Database
    ) async throws -> CatalogueScope {
        let dialect = (db as? any SQLDatabase)?.dialect.name ?? "unknown"
        let brands: [BrandModel]
        switch kind {
        case .followed:
            // Every follow, whatever its mode: a quiet brand is out of the feed and the alerts,
            // and still one of your shops.
            let userID = try user.requireID()
            let ids = try await FollowModel.query(on: db)
                .filter(\.$user.$id == userID)
                .all()
                .map(\.$brand.id)
            brands = ids.isEmpty ? [] : try await BrandModel.query(on: db).filter(\.$id ~~ ids).all()
        case .all:
            brands = try await BrandModel.query(on: db).all()
        }
        let ids = brands.compactMap(\.id)
        let serving = try await Storefronts.serving(
            country: user.country,
            enabled: app.storefrontCountries,
            brandIDs: kind == .followed ? ids : nil,
            on: db
        )
        return CatalogueScope(
            kind: kind,
            brands: Dictionary(brands.compactMap { brand in brand.id.map { ($0, brand.name) } }, uniquingKeysWith: { a, _ in a }),
            serving: serving,
            dialect: dialect
        )
    }

    // MARK: - Search

    static func run(_ ask: Ask, for user: UserModel, app: Application, on db: any Database) async throws -> ProductSearchResponse {
        guard let sql = db as? any SQLDatabase else { throw Abort(.internalServerError) }
        let query = ShopQuery.parse(ask.text).refined(cheaper: ask.cheaper, formal: ask.formal, inMySize: ask.inMySize)
        let scope = try await scope(ask.scope, for: user, app: app, on: db)

        var response = ProductSearchResponse(scope: ask.scope, shops: scope.brands.count)
        guard !scope.brands.isEmpty else { return response }
        response.searched = try await count(in: scope, on: sql)
        guard !query.isEmpty else { return response }

        let brandTokens = scope.brands.mapValues(IndexWord.tokens(ofBrand:))
        let words = query.terms.map { IndexWord($0, brandTokens: brandTokens) }
        let ruledOut = query.excluded.map { IndexWord($0, brandTokens: brandTokens) }
        let index = scope.index

        // 1. Find.
        let narrowing = priceBound(query)
        var found = try await index.candidates(
            for: words, narrowing: narrowing, ruledOut: ruledOut, scope: scope, limit: pool, on: sql
        )
        response.isCapped = found.count >= pool
        if narrowing != nil || !ruledOut.isEmpty {
            found += try await index.candidates(
                for: words, narrowing: nil, ruledOut: [], scope: scope, limit: diagnosticPool, on: sql
            )
        }
        if !words.isEmpty {
            found += await semanticCandidates(for: query, scope: scope, app: app, on: sql)
        }

        // 2. Ask what exists.
        let existing = try await index.existing(words, scope: scope, on: sql)

        // 3. Match.
        let listings = try await load(found, scope: scope, profile: user.sizeProfile, on: db)
        let profile = user.sizeProfile
        let byID = Dictionary(listings.map { ($0.listing.id, $0) }, uniquingKeysWith: { a, _ in a })
        let result = ShopSearch.run(
            query,
            in: ShopIndex(listings.map(\.listing)),
            hasSizes: !profile.isEmpty,
            fits: { byID[$0.id]?.fits(profile) ?? false },
            knows: existing.map { known in { known.contains($0.word) } }
        )

        // 4. Page.
        let limit = min(max(ask.limit, 1), maxLimit)
        let offset = max(ask.offset, 0)
        let exact = Array(result.exact.dropFirst(offset).prefix(limit))
        let partial = offset == 0 ? result.partial : []
        let cards = try await cards(for: (exact + partial).compactMap { byID[$0.id] }, scope: scope, on: db)

        response.exact = exact.compactMap { hit in cards[hit.id].map { ProductSearchHit(card: $0) } }
        response.partial = partial.compactMap { hit in cards[hit.id].map { ProductSearchHit(card: $0, matched: hit.matched) } }
        response.unknown = result.unknown
        response.outcome = result.outcome
        response.cheaperThan = result.cheaperThan
        response.total = result.total
        response.nextCursor = offset + limit < result.exact.count ? String(offset + limit) : nil
        return response
    }

    /// A price bound, in SQL, exactly as `ShopSearch` applies it: inclusive, and a product
    /// with no price is outside any bound.
    static func priceBound(_ query: ShopQuery) -> SQLQueryString? {
        var parts: [SQLQueryString] = []
        if let ceiling = query.ceiling { parts.append("p.price_amount <= \(bind: ceiling)") }
        if let floor = query.floor { parts.append("p.price_amount >= \(bind: floor)") }
        guard !parts.isEmpty else { return nil }
        return "p.price_amount IS NOT NULL AND " + parts.joined(separator: " AND ")
    }

    static func count(in scope: CatalogueScope, on sql: any SQLDatabase) async throws -> Int {
        try await sql.raw("SELECT count(*) AS n FROM products p WHERE \(scope.predicate)")
            .first()?.decode(column: "n", as: Int.self) ?? 0
    }

    /// The query's nearest products, where vectors exist and the provider answers in time.
    /// Never a reason for the search to fail.
    static func semanticCandidates(
        for query: ShopQuery,
        scope: CatalogueScope,
        app: Application,
        on sql: any SQLDatabase
    ) async -> [IndexCandidate] {
        guard let provider = app.semanticSearch else { return [] }
        let text = query.terms.map(\.word).joined(separator: " ")
        do {
            let vectors = try await withTimeout(embeddingTimeout) { try await provider.embed(texts: [text]) }
            guard let vector = vectors.first, vector.count == provider.dimension else { return [] }
            return try await SemanticIndex.nearest(
                to: vector, provider: provider, scope: scope.predicate, limit: semanticPool, on: sql
            ).map { IndexCandidate(id: $0.id, relevance: $0.similarity) }
        } catch {
            app.logger.warning("search: semantic retrieval skipped: \(String(describing: error))")
            return []
        }
    }

    // MARK: - Reading the candidates

    /// One candidate, read once: the listing the grammar reasons about, and what the size
    /// question and the card need.
    struct Loaded: Sendable {
        var listing: ShopListing
        var product: ProductModel
        var variants: [VariantModel]
        var context: SizeContext

        /// Buyable in a size the reader wears — `claims`, never `matches`, for the reason
        /// `ShopCatalogue.fits` gives: "in my size" is a statement about the reader.
        func fits(_ profile: SizeProfile) -> Bool {
            variants.contains { $0.available && profile.claims($0.asVariantInfo, in: context) }
        }
    }

    /// The candidates as listings, the way `ShopCatalogue` builds them on the phone.
    static func load(
        _ candidates: [IndexCandidate],
        scope: CatalogueScope,
        profile: SizeProfile,
        on db: any Database
    ) async throws -> [Loaded] {
        var relevance: [UUID: Double] = [:]
        for candidate in candidates { relevance[candidate.id, default: 0] += candidate.relevance }
        let ids = Array(relevance.keys)
        guard !ids.isEmpty else { return [] }

        let products = try await ProductModel.query(on: db).filter(\.$id ~~ ids).all()
        let variants = Dictionary(
            grouping: try await VariantModel.query(on: db).filter(\.$product.$id ~~ ids).all(),
            by: { $0.$product.id }
        )
        return products.compactMap { product in
            guard let id = product.id, let brandName = scope.brands[product.$brand.id] else { return nil }
            let own = variants[id] ?? []
            var colourways: [String] = []
            for variant in own {
                guard let colour = variant.color, !colour.isEmpty, colour != "Default Title",
                      !colourways.contains(colour) else { continue }
                colourways.append(colour)
            }
            let infos = own.map(\.asVariantInfo)
            // Shown by the reader's gender filter, and clothing at all — `BrandUpdate.passes`:
            // a gift card is not a garment. Carried rather than applied, so the answer can say
            // "your filter hides these" instead of claiming there are none.
            let isGarment = PreviewImages.isGarment(title: product.title, imageURL: product.imageURLs.first)
            let shown = isGarment && (profile.gender == .everything || profile.allows(product.gender))
            return Loaded(
                listing: ShopListing(
                    id: id.uuidString,
                    brandKey: product.$brand.id.uuidString,
                    brandName: brandName,
                    title: product.title,
                    productType: product.productType,
                    tags: product.tags,
                    colourways: colourways,
                    price: product.priceAmount,
                    publishedAt: product.publishedAt,
                    isAvailable: own.isEmpty ? (product.isAvailable ?? true) : own.contains(where: \.available),
                    isShown: shown,
                    relevance: relevance[id] ?? 0
                ),
                product: product,
                variants: own,
                context: product.sizeContext(sizes: infos.map(\.displaySize))
            )
        }
    }

    /// The page, as cards: each product with its brand, its sources and the shop serving it.
    static func cards(for page: [Loaded], scope: CatalogueScope, on db: any Database) async throws -> [String: DiscoverCard] {
        let brandIDs = Array(Set(page.map { $0.product.$brand.id }))
        guard !brandIDs.isEmpty else { return [:] }
        let brands = Dictionary(
            try await BrandModel.query(on: db).filter(\.$id ~~ brandIDs).with(\.$sources).all()
                .compactMap { brand in brand.id.map { ($0, brand) } },
            uniquingKeysWith: { a, _ in a }
        )
        var out: [String: DiscoverCard] = [:]
        for loaded in page {
            guard let brand = brands[loaded.product.$brand.id] else { continue }
            let shop = scope.serving[loaded.product.$brand.id]
            out[loaded.listing.id] = DiscoverCard(
                loaded.product,
                brand: BrandDTO(brand, sources: brand.sources, storefront: shop),
                mainCurrency: brand.currency,
                variants: loaded.variants,
                spread: [],
                vector: nil
            )
        }
        return out
    }

    // MARK: - More like this

    static let similarLimit = 8
    /// Below this the resemblance is coincidence — the threshold `SimilarItems` uses on the
    /// phone, for the same reason: two products that share the word "cotton" are not
    /// alternatives.
    static let minimumResemblance = 2.0

    /// Products like `subject`, from the caller's scope.
    ///
    /// By vector where this product and its neighbours have been embedded under the current
    /// model; otherwise by its own words — its title, type and tags, read by the same grammar
    /// as a query — scored the way the phone's `SimilarItems` scores: the same slot, each
    /// shared word, a little for the same shop.
    static func similar(
        to subject: ProductModel,
        scope kind: ProductSearchScope,
        limit: Int,
        for user: UserModel,
        app: Application,
        on db: any Database
    ) async throws -> SimilarProductsResponse {
        guard let sql = db as? any SQLDatabase, let subjectID = subject.id else { throw Abort(.internalServerError) }
        let scope = try await scope(kind, for: user, app: app, on: db)
        let limit = min(max(limit, 1), 24)
        guard !scope.brands.isEmpty else { return SimilarProductsResponse(products: [], basis: "text") }
        let profile = user.sizeProfile

        if let provider = app.semanticSearch,
           let vector = try await SemanticIndex.vector(of: subjectID, provider: provider, on: sql) {
            let near = try await SemanticIndex.nearest(
                to: vector, provider: provider, scope: scope.predicate, excluding: subjectID, limit: 60, on: sql
            )
            let loaded = try await load(near.map { IndexCandidate(id: $0.id, relevance: $0.similarity) }, scope: scope, profile: profile, on: db)
                .filter(\.listing.isShown)
                .sorted { a, b in
                    a.listing.relevance != b.listing.relevance
                        ? a.listing.relevance > b.listing.relevance
                        : a.listing.id < b.listing.id
                }
            if !loaded.isEmpty {
                let page = Array(loaded.prefix(limit))
                let cards = try await cards(for: page, scope: scope, on: db)
                return SimilarProductsResponse(products: page.compactMap { cards[$0.listing.id] }, basis: "vectors")
            }
        }

        // The product's own words, as a query.
        let own = ShopQuery.parse(([subject.title, subject.productType ?? ""] + subject.tags).joined(separator: " "))
        // Not by brand name: a product's own shop is a tie-break below, not a reason.
        let words = own.terms.map { IndexWord($0, brandTokens: [:]) }
        guard !words.isEmpty else { return SimilarProductsResponse(products: [], basis: "text") }
        let found = try await scope.index.candidates(
            for: words, narrowing: "p.id <> \(bind: subjectID)", ruledOut: [], scope: scope, limit: 300, on: sql
        )
        let loaded = try await load(found, scope: scope, profile: profile, on: db).filter(\.listing.isShown)
        let index = ShopIndex(loaded.map(\.listing))
        let slot = GarmentClassifier.classify(title: subject.title, productType: subject.productType, tags: subject.tags)

        var scored: [(loaded: Loaded, score: Double)] = []
        for (position, candidate) in loaded.enumerated() {
            var score = 0.0
            if slot != .unknown, candidate.listing.slot == slot { score += 1.5 }
            score += Double(own.terms.count { index.carries($0, at: position) })
            if candidate.product.$brand.id == subject.$brand.id { score += 0.5 }
            if score >= minimumResemblance { scored.append((candidate, score)) }
        }
        scored.sort { a, b in
            if a.score != b.score { return a.score > b.score }
            if a.loaded.listing.relevance != b.loaded.listing.relevance {
                return a.loaded.listing.relevance > b.loaded.listing.relevance
            }
            if a.loaded.listing.publishedAt != b.loaded.listing.publishedAt {
                return a.loaded.listing.publishedAt > b.loaded.listing.publishedAt
            }
            return a.loaded.listing.id < b.loaded.listing.id
        }
        let page = scored.prefix(limit).map(\.loaded)
        let cards = try await cards(for: Array(page), scope: scope, on: db)
        return SimilarProductsResponse(products: page.compactMap { cards[$0.listing.id] }, basis: "text")
    }
}

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
// query's nearest neighbours to the candidates and to their rank. **Where the request asks for
// it (`meaning=true`, Phase 5), a neighbour close enough (`meaningThreshold`) is a result even
// without the typed words**, labelled as one (`ProductSearchHit.byMeaning`) — and still has to
// pass every constraint the grammar read: "no …", the price, the gender filter, "in my size".
// Without the flag it never adds a match the grammar would not make, which is what 1.2 and 1.3
// get. With the provider down or slow the full-text answer stands.
//
// **One list over every shop** (Phase 5) is `scope=all` with `boost=`: the reader's own shops
// are lifted by a fixed amount of score (`lift`), "More from my brands" lifts them further, and
// "Only my brands" is `scope=followed`, exactly as it always was. Without `boost=`, `all` is
// the unlifted search 1.2 and 1.3 ask for under "Also look in every shop we watch".

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
    /// How close, by cosine similarity of text vectors, a product must be to the query to be a
    /// result without its words — per model id, because a threshold is a property of the model
    /// as much as of the catalogue: two models put the same pair of texts at different
    /// distances. Measured on the search eval (`Server/SearchEval`, `docs/server.md`, *The
    /// search eval*). **A model missing here makes no meaning matches at all** — its vectors
    /// still widen and order the candidates, and a model switched to without being measured
    /// cannot start putting unmeasured guesses on the page.
    static let measuredThresholds: [String: Double] = [
        "Marqo/marqo-fashionSigLIP@c56244cc94f9": 0.66,
    ]

    /// The followed shops' lift, in the grammar's own score: a tag's weight for every search
    /// over every shop, a title's for "More from my brands" — enough to decide between equal
    /// matches, or, for "more", to put a followed shop's tag match beside another shop's title
    /// match. Never enough to put a sold-out piece above a buyable one, or a partial match in
    /// the main list: those are decided before the score is read.
    static func lift(_ boost: FollowedBoost) -> Double {
        switch boost {
        case .standard: 1
        case .more: 3
        }
    }
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
        /// The lift for the reader's own shops, honoured only for `scope` `all`.
        var boost: FollowedBoost?
        /// Whether a product close by meaning may be a result without its words.
        var meaning = false
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
        // Every follow, whatever its mode: a quiet brand is out of the feed and the alerts,
        // and still one of your shops.
        let userID = try user.requireID()
        let followed = try await FollowModel.query(on: db)
            .filter(\.$user.$id == userID)
            .all()
            .map(\.$brand.id)
        let brands: [BrandModel]
        switch kind {
        case .followed:
            brands = followed.isEmpty ? [] : try await BrandModel.query(on: db).filter(\.$id ~~ followed).all()
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
            dialect: dialect,
            followed: Set(followed)
        )
    }

    // MARK: - Search

    static func run(_ ask: Ask, for user: UserModel, app: Application, on db: any Database) async throws -> ProductSearchResponse {
        guard let sql = db as? any SQLDatabase else { throw Abort(.internalServerError) }
        let query = ShopQuery.parse(ask.text).refined(cheaper: ask.cheaper, formal: ask.formal, inMySize: ask.inMySize)
        let scope = try await scope(ask.scope, for: user, app: app, on: db)

        var response = ProductSearchResponse(scope: ask.scope, shops: scope.brands.count)
        // Said only where it was done: a lift over your own shops alone would order nothing.
        let lift = ask.scope == .all ? ask.boost.map(lift) : nil
        if lift != nil { response.boost = ask.boost }
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
        var meaning: Set<String> = []
        // Narrowed by the price only where meaning is asked for, so the plain search an older
        // client asks for reads exactly the candidates it always read.
        if !words.isEmpty, let near = await semanticCandidates(
            for: query, scope: scope, narrowing: ask.meaning ? narrowing : nil, meaning: ask.meaning, app: app, on: sql
        ) {
            found += near.candidates
            if ask.meaning, let threshold = app.meaningThresholds[near.model] {
                response.meaningSearched = true
                meaning = Set(near.candidates.filter { $0.relevance >= threshold }.map(\.id.uuidString))
            }
        }

        // 2. Ask what exists.
        let existing = try await index.existing(words, scope: scope, on: sql)

        // 3. Match.
        let listings = try await load(found, scope: scope, profile: user.sizeProfile, lift: lift ?? 0, on: sql)
        let profile = user.sizeProfile
        let byID = Dictionary(listings.map { ($0.listing.id, $0) }, uniquingKeysWith: { a, _ in a })
        let result = ShopSearch.run(
            query,
            in: ShopIndex(listings.map(\.listing)),
            hasSizes: !profile.isEmpty,
            fits: { byID[$0.id]?.fits(profile) ?? false },
            knows: existing.map { known in { known.contains($0.word) } },
            meaning: meaning
        )

        // 4. Page.
        let limit = min(max(ask.limit, 1), maxLimit)
        let offset = max(ask.offset, 0)
        let exact = Array(result.exact.dropFirst(offset).prefix(limit))
        let partial = offset == 0 ? result.partial : []
        let cards = try await cards(for: (exact + partial).compactMap { byID[$0.id] }, scope: scope, on: db)

        response.exact = exact.compactMap { hit in
            cards[hit.id].map { hit.byMeaning ? ProductSearchHit(card: $0, matched: hit.matched, byMeaning: true) : ProductSearchHit(card: $0) }
        }
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

    /// The query's nearest products, where vectors exist and the provider answers in time —
    /// nil when they were not asked, so a caller can tell "compared by meaning, nothing near"
    /// from "not compared". Never a reason for the search to fail.
    ///
    /// The price bound narrows them, as it narrows the full-text candidates, so the hundred are
    /// spent on what can survive it.
    static func semanticCandidates(
        for query: ShopQuery,
        scope: CatalogueScope,
        narrowing: SQLQueryString? = nil,
        meaning: Bool = false,
        app: Application,
        on sql: any SQLDatabase
    ) async -> (candidates: [IndexCandidate], model: String)? {
        guard let provider = app.semanticSearch, app.semanticRest?.isResting() != true else { return nil }
        let text = embeddingText(for: query, meaning: meaning)
        let space: EmbeddingSpace
        let vectors: [[Float]]
        do {
            // The space is read inside the deadline: on a cold sidecar it is a `/health` call.
            (space, vectors) = try await withTimeout(embeddingTimeout) {
                (try await provider.space, try await provider.embed(texts: [text]))
            }
        } catch {
            app.semanticRest?.rest()
            app.logger.warning("search: semantic retrieval skipped for \(Int(SemanticRest.interval))s: \(String(describing: error))")
            return nil
        }
        guard let vector = vectors.first, vector.count == space.dimension else { return nil }
        let within: SQLQueryString = narrowing.map { scope.predicate + " AND " + $0 } ?? scope.predicate
        do {
            let near = try await SemanticIndex.nearest(
                to: vector, in: space, scope: within, limit: semanticPool, on: sql
            ).map { IndexCandidate(id: $0.id, relevance: $0.similarity) }
            return (near, space.model)
        } catch {
            app.logger.warning("search: semantic retrieval skipped: \(String(describing: error))")
            return nil
        }
    }

    /// What a query is embedded as: the words to find, in the order typed — never a ruled-out
    /// word, which would pull the vector *towards* wool for "no wool", and never a price. Where
    /// meaning is asked for, "formal" too when the query leans that way: "smart" is read as the
    /// leaning and is not a word to find, and "smart summer jacket" embedded as "summer jacket"
    /// would lose the one word that makes it a blazer. `Server/SearchEval` embeds its queries the
    /// same way to choose the threshold.
    static func embeddingText(for query: ShopQuery, meaning: Bool = false) -> String {
        (query.terms.map(\.word) + (meaning && query.formal ? ["formal"] : [])).joined(separator: " ")
    }

    private static func space(of provider: any EmbeddingProvider, app: Application) async -> EmbeddingSpace? {
        do {
            return try await withTimeout(embeddingTimeout) { try await provider.space }
        } catch {
            app.semanticRest?.rest()
            app.logger.warning("search: vectors skipped for \(Int(SemanticRest.interval))s: \(String(describing: error))")
            return nil
        }
    }

    // MARK: - Reading the candidates

    /// One candidate, read once into values: the listing the grammar reasons about, and what
    /// the size question needs. The card is built later, for the page alone.
    struct Loaded: Sendable {
        var listing: ShopListing
        var productID: UUID
        var brandID: UUID
        var title: String
        var productType: String?
        var tags: [String]
        var linkURL: String?
        var variants: [VariantInfo]

        /// Buyable in a size the reader wears — `claims`, never `matches`, for the reason
        /// `ShopCatalogue.fits` gives: "in my size" is a statement about the reader. The size
        /// context costs two classifier runs, so it is worked out here, where only the
        /// listings that survived every other constraint are asked.
        func fits(_ profile: SizeProfile) -> Bool {
            let context = ProductModel.sizeContext(
                title: title, productType: productType, tags: tags, linkURL: linkURL,
                sizes: variants.map(\.displaySize)
            )
            return variants.contains { $0.available && profile.claims($0, in: context) }
        }
    }

    /// The candidates as listings, the way `ShopCatalogue` builds them on the phone.
    ///
    /// **Columns, not models.** Hydrating six hundred `ProductModel`s and their four thousand
    /// `VariantModel`s through Fluent was most of a search — 380ms of 650 measured on eight
    /// thousand products, in release — for a page that shows forty. The candidates are read
    /// as rows into values, and only the page becomes models (`cards`).
    ///
    /// - Parameter lift: added to the score of every listing from a shop the reader follows.
    static func load(
        _ candidates: [IndexCandidate],
        scope: CatalogueScope,
        profile: SizeProfile,
        lift: Double = 0,
        on sql: any SQLDatabase
    ) async throws -> [Loaded] {
        var relevance: [UUID: Double] = [:]
        for candidate in candidates { relevance[candidate.id, default: 0] += candidate.relevance }
        let ids = Array(relevance.keys)
        guard !ids.isEmpty else { return [] }

        var variants: [UUID: [VariantInfo]] = [:]
        for row in try await sql.raw("""
            SELECT product_id, external_id, title, size, color, available, price, image_index
            FROM variants WHERE product_id IN (\(binds: ids))
            """).all() {
            variants[try row.decode(column: "product_id", as: UUID.self), default: []].append(VariantInfo(
                id: try row.decode(column: "external_id", as: String.self),
                title: try row.decode(column: "title", as: String.self),
                available: try row.decode(column: "available", as: Bool.self),
                price: try row.decode(column: "price", as: String?.self),
                size: try row.decode(column: "size", as: String?.self),
                color: try row.decode(column: "color", as: String?.self),
                imageIndex: try row.decode(column: "image_index", as: Int?.self)
            ))
        }

        let rows = try await sql.raw("""
            SELECT id, brand_id, title, product_type, tags, price_amount, published_at, is_available,
                   image_urls, link_url, style_words
            FROM products WHERE id IN (\(binds: ids))
            """).all()
        return try rows.compactMap { row in
            let id = try row.decode(column: "id", as: UUID.self)
            let brandID = try row.decode(column: "brand_id", as: UUID.self)
            guard let brandName = scope.brands[brandID] else { return nil }
            let title = try row.decode(column: "title", as: String.self)
            let productType = try row.decode(column: "product_type", as: String?.self)
            let tags = try row.decode(column: "tags", as: [String].self)
            let linkURL = try row.decode(column: "link_url", as: String?.self)
            let own = variants[id] ?? []
            var colourways: [String] = []
            for variant in own {
                guard let colour = variant.color, !colour.isEmpty, colour != "Default Title",
                      !colourways.contains(colour) else { continue }
                colourways.append(colour)
            }
            // Shown by the reader's gender filter, and clothing at all — `BrandUpdate.passes`,
            // which does not run the classifier when the filter is off. Carried rather than
            // applied, so the answer can say "your filter hides these" instead of claiming
            // there are none.
            let image = try row.decode(column: "image_urls", as: [String].self).first
            let shown = PreviewImages.isGarment(title: title, imageURL: image)
                && (profile.gender == .everything
                    || profile.allows(ProductModel.gender(title: title, productType: productType, tags: tags, linkURL: linkURL)))
            return Loaded(
                listing: ShopListing(
                    id: id.uuidString,
                    brandKey: brandID.uuidString,
                    brandName: brandName,
                    title: title,
                    productType: productType,
                    tags: tags,
                    colourways: colourways,
                    styleWords: try row.decode(column: "style_words", as: [String]?.self) ?? [],
                    price: try row.decode(column: "price_amount", as: Double?.self),
                    publishedAt: try row.decode(column: "published_at", as: Date.self),
                    isAvailable: own.isEmpty
                        ? (try row.decode(column: "is_available", as: Bool?.self) ?? true)
                        : own.contains(where: \.available),
                    isShown: shown,
                    relevance: relevance[id] ?? 0,
                    boost: lift != 0 && scope.followed.contains(brandID) ? lift : 0
                ),
                productID: id,
                brandID: brandID,
                title: title,
                productType: productType,
                tags: tags,
                linkURL: linkURL,
                variants: own
            )
        }
    }

    /// The page, as cards: each product with its brand, its sources and the shop serving it.
    static func cards(for page: [Loaded], scope: CatalogueScope, on db: any Database) async throws -> [String: DiscoverCard] {
        guard !page.isEmpty else { return [:] }
        let ids = page.map(\.productID)
        let products = Dictionary(
            try await ProductModel.query(on: db).filter(\.$id ~~ ids).all().compactMap { product in product.id.map { ($0, product) } },
            uniquingKeysWith: { a, _ in a }
        )
        let variants = Dictionary(
            grouping: try await VariantModel.query(on: db).filter(\.$product.$id ~~ ids).all(),
            by: { $0.$product.id }
        )
        let brandIDs = Array(Set(page.map(\.brandID)))
        let brands = Dictionary(
            try await BrandModel.query(on: db).filter(\.$id ~~ brandIDs).with(\.$sources).all()
                .compactMap { brand in brand.id.map { ($0, brand) } },
            uniquingKeysWith: { a, _ in a }
        )
        var out: [String: DiscoverCard] = [:]
        for loaded in page {
            guard let product = products[loaded.productID], let brand = brands[loaded.brandID] else { continue }
            out[loaded.listing.id] = DiscoverCard(
                product,
                brand: BrandDTO(brand, sources: brand.sources, storefront: scope.serving[loaded.brandID]),
                mainCurrency: brand.currency,
                variants: variants[loaded.productID] ?? [],
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

        // The space is only read, never embedded with, and is cached once the sidecar has
        // answered — so a sidecar that is down usually costs nothing here. When it has never
        // answered, the basis is the text one below, and searches rest as after a failed query.
        if let provider = app.semanticSearch, app.semanticRest?.isResting() != true,
           let space = await Self.space(of: provider, app: app),
           let vector = try await SemanticIndex.vector(of: subjectID, in: space, on: sql) {
            let near = try await SemanticIndex.nearest(
                to: vector, in: space, scope: scope.predicate, excluding: subjectID, limit: 60, on: sql
            )
            let loaded = try await load(near.map { IndexCandidate(id: $0.id, relevance: $0.similarity) }, scope: scope, profile: profile, on: sql)
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
        let loaded = try await load(found, scope: scope, profile: profile, on: sql).filter(\.listing.isShown)
        let index = ShopIndex(loaded.map(\.listing))
        let slot = GarmentClassifier.classify(title: subject.title, productType: subject.productType, tags: subject.tags)

        var scored: [(loaded: Loaded, score: Double)] = []
        for (position, candidate) in loaded.enumerated() {
            var score = 0.0
            if slot != .unknown, candidate.listing.slot == slot { score += 1.5 }
            score += Double(own.terms.count { index.carries($0, at: position) })
            if candidate.brandID == subject.$brand.id { score += 0.5 }
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

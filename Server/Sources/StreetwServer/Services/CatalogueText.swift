// CatalogueText.swift
// The part of product search that depends on the database: which products to look at.
//
// **This finds; it does not decide.** Whether a product matches a query is `ShopSearch`'s
// whole-token rule, run in Swift over what this hands back, the same code the phone runs
// over its own store — so "a black suit under 400" means one thing on both ends. The index
// only has to make sure the products that *would* match are among the few hundred it
// returns, best first. A candidate it returns that does not match costs nothing; one it
// misses is lost. So everything here errs wide.
//
// Two implementations behind one protocol:
//
// - **`PostgresTextIndex`**, the deployment: the generated `products.search` vector and the
//   colour index from `AddProductSearch`, ranked by `ts_rank_cd`. Ranking quality is a
//   property of this one.
// - **`PortableTextIndex`**, SQLite: `LIKE` over the same fields, newest first, no rank. It
//   exists so the tests drive the route, the scope rules and the grammar end to end; it is
//   not a search engine and nothing should be tuned against it.

import Fluent
import Foundation
import SQLKit
import StreetwCore

/// Which products one caller's search may see.
struct CatalogueScope: Sendable {
    var kind: ProductSearchScope
    /// Every brand in scope, with its name — the name is matched in Swift, because it lives
    /// in another table and a generated column cannot reach it.
    var brands: [UUID: String]
    /// The country shop serving the caller, per brand that has one; every other brand is
    /// served its main shop. One shop per brand, never both — the rule the feed keeps.
    var serving: [UUID: StorefrontModel]
    var dialect: String

    /// The products this caller may be shown, as a predicate on `p`.
    ///
    /// Garments only (`kind = 'product'`: not a collection, a post or a page), with a
    /// photograph, from the shop that serves them, and **announced** — a sitemap row still
    /// waiting for its page (`pending_announcement`) may not be a product at all, and has no
    /// price or stock to search on until it is read.
    var predicate: SQLQueryString {
        let photographed: SQLQueryString = dialect == "postgresql"
            ? "cardinality(p.image_urls) > 0"
            : "p.image_urls <> '[]'"
        let shops = serving.values.compactMap(\.id)
        let elsewhere = Array(serving.keys)

        var served: [SQLQueryString] = []
        switch kind {
        case .followed:
            let main = brands.keys.filter { serving[$0] == nil }
            if !main.isEmpty { served.append("(p.storefront_id IS NULL AND p.brand_id IN (\(binds: main)))") }
        case .all:
            served.append(elsewhere.isEmpty
                ? "p.storefront_id IS NULL"
                : "(p.storefront_id IS NULL AND p.brand_id NOT IN (\(binds: elsewhere)))")
        }
        if !shops.isEmpty { served.append("p.storefront_id IN (\(binds: shops))") }
        let shop: SQLQueryString = served.isEmpty ? "1 = 0" : "(" + served.joined(separator: " OR ") + ")"
        return "p.kind = 'product' AND p.pending_announcement IS NULL AND \(photographed) AND \(shop)"
    }
}

/// One query word, as the index looks for it.
struct IndexWord: Sendable {
    /// As the grammar prints it, which is what `existing` answers with.
    var word: String
    /// Whole tokens that find it: its forms, and for a category word every token that can
    /// place a garment there (`GarmentClassifier.vocabulary`). Letters and digits only.
    var lexemes: [String]
    /// A compound the grammar joins ("tshirt") is two tokens in a title ("T-Shirt"), so it
    /// is also looked for as its parts, in order.
    var phrases: [[String]]
    /// Brands whose own name carries the word.
    var brands: [UUID]

    init(_ term: ShopQuery.Term, brandTokens: [UUID: Set<String>]) {
        word = term.word
        var lexemes = term.forms
        if let slot = term.slot { lexemes.formUnion(GarmentClassifier.vocabulary(for: slot)) }
        self.lexemes = lexemes.map(Self.clean).filter { !$0.isEmpty }.sorted()
        phrases = Self.parts.compactMap { lexemes.contains($0.key) ? $0.value : nil }.sorted { $0.joined() < $1.joined() }
        brands = brandTokens.compactMap { !$0.value.isDisjoint(with: term.forms) ? $0.key : nil }
    }

    /// `ShopQuery.compounds` turned round: "tshirt" → ["t", "shirt"].
    static let parts: [String: [String]] = {
        var out: [String: [String]] = [:]
        for (phrase, joined) in ShopQuery.compounds {
            out[joined] = phrase.split(separator: " ").map(String.init)
        }
        return out
    }()

    static func clean(_ token: String) -> String {
        String(token.lowercased().filter { $0.isLetter || $0.isNumber })
    }

    /// The tokens one brand's name answers to: its words, and the whole name as one run of
    /// letters, the way `ShopIndex` reads a shop's name ("offwhite").
    static func tokens(ofBrand name: String) -> Set<String> {
        var out = Set(ShopText.tokens(name))
        out.insert(
            name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
                .lowercased()
                .filter { $0.isLetter || $0.isNumber }
        )
        return out
    }
}

struct IndexCandidate: Sendable, Hashable {
    var id: UUID
    /// The index's own rank, for `ShopListing.relevance`.
    var relevance: Double
}

protocol CatalogueTextIndex: Sendable {
    /// Products in scope carrying any of `words` — or, with none, the newest — best first.
    ///
    /// - Parameter narrowing: an extra condition on `p` the caller can state in SQL (a price
    ///   bound, a ruled-out word) so the candidates are spent on what can survive it. Always a
    ///   subset of what `ShopSearch` will itself rule out, never a different rule.
    func candidates(
        for words: [IndexWord],
        narrowing: SQLQueryString?,
        ruledOut: [IndexWord],
        scope: CatalogueScope,
        limit: Int,
        on sql: any SQLDatabase
    ) async throws -> [IndexCandidate]

    /// Which words anything in scope carries at all, or nil when the candidates' own
    /// vocabulary has to stand in for the answer.
    func existing(_ words: [IndexWord], scope: CatalogueScope, on sql: any SQLDatabase) async throws -> Set<String>?
}

extension CatalogueScope {
    /// The text index for this database.
    var index: any CatalogueTextIndex {
        dialect == "postgresql" ? PostgresTextIndex() : PortableTextIndex()
    }
}

struct PostgresTextIndex: CatalogueTextIndex {
    /// Exactly the expression `idx_variants_color_search` is built on, or the index is not used.
    static let colourVector: SQLQueryString = "to_tsvector('simple', streetw_fold(v.color))"

    /// A tsquery for one word: any lexeme, or any phrase of parts.
    static func tsquery(_ word: IndexWord) -> String {
        let singles = word.lexemes.map { "'\($0)'" }
        let phrases = word.phrases.map { "(" + $0.map { "'\(IndexWord.clean($0))'" }.joined(separator: " <-> ") + ")" }
        return (singles + phrases).joined(separator: " | ")
    }

    static func tsquery(_ words: [IndexWord]) -> String {
        words.map { "(" + tsquery($0) + ")" }.joined(separator: " | ")
    }

    func candidates(
        for words: [IndexWord],
        narrowing: SQLQueryString?,
        ruledOut: [IndexWord],
        scope: CatalogueScope,
        limit: Int,
        on sql: any SQLDatabase
    ) async throws -> [IndexCandidate] {
        let extra: SQLQueryString = narrowing.map { " AND \($0)" } ?? ""
        // A ruled-out word is taken out here only where the vector says it — the title, type
        // or tags. One ruled out by a colourway or a shop's name is still handed over, and
        // `ShopSearch` takes it out; this only saves the candidates for what can survive.
        let excluded: SQLQueryString = ruledOut.isEmpty
            ? ""
            : " AND NOT (p.search @@ to_tsquery('simple', \(bind: Self.tsquery(ruledOut))))"

        let words = words.filter { !$0.lexemes.isEmpty || !$0.brands.isEmpty }
        guard !words.isEmpty else {
            // A browse — "under 100", "in my size" — is the scope's newest.
            let rows = try await sql.raw("""
                SELECT p.id AS id FROM products p
                WHERE \(scope.predicate)\(extra)\(excluded)
                ORDER BY p.published_at DESC, p.id LIMIT \(literal: limit)
                """).all()
            return try rows.map { IndexCandidate(id: try $0.decode(column: "id", as: UUID.self), relevance: 0) }
        }

        let any = Self.tsquery(words)
        // Per word: does the row carry it anywhere — the vector, the shop's name, a colourway.
        // Summed, so what carries every word is ranked before what carries some, which is the
        // order `ShopSearch` reads them in: the exact matches must not be crowded out by rows
        // that rank well on one word.
        //
        // The colourways are one index scan per word, each a set of product ids. Asking every
        // word of one aggregate over the variants instead recomputed the colour vector per
        // variant per word: 68ms of an 80ms query for "black hoodie" on eight thousand
        // products, against 34ms this way.
        var colours: [SQLQueryString] = []
        var joins: [SQLQueryString] = []
        var anyColour: [SQLQueryString] = []
        var hits: [SQLQueryString] = []
        var brands = Set<UUID>()
        for (index, word) in words.enumerated() {
            let column = "c\(index)"
            colours.append("""
                \(ident: column) AS (SELECT DISTINCT v.product_id FROM variants v \
                WHERE \(Self.colourVector) @@ to_tsquery('simple', \(bind: Self.tsquery(word))))
                """)
            joins.append("LEFT JOIN \(ident: column) ON \(ident: column).product_id = p.id")
            anyColour.append("\(ident: column).product_id IS NOT NULL")
            var carried: [SQLQueryString] = [
                "p.search @@ to_tsquery('simple', \(bind: Self.tsquery(word)))",
                "\(ident: column).product_id IS NOT NULL"
            ]
            if !word.brands.isEmpty { carried.append("p.brand_id IN (\(binds: word.brands))") }
            hits.append("(" + carried.joined(separator: " OR ") + ")::int")
            brands.formUnion(word.brands)
        }
        let byBrand: SQLQueryString = brands.isEmpty ? "" : " OR p.brand_id IN (\(binds: Array(brands)))"

        let rows = try await sql.raw("""
            WITH \(colours.joined(separator: ", "))
            SELECT p.id AS id,
                   ts_rank_cd(p.search, to_tsquery('simple', \(bind: any))) AS rank,
                   \(hits.joined(separator: " + ")) AS hits
            FROM products p \(joins.joined(separator: " "))
            WHERE \(scope.predicate)\(extra)\(excluded)
              AND (p.search @@ to_tsquery('simple', \(bind: any)) OR \(anyColour.joined(separator: " OR "))\(byBrand))
            ORDER BY hits DESC, rank DESC, p.published_at DESC, p.id
            LIMIT \(literal: limit)
            """).all()
        return try rows.map {
            IndexCandidate(
                id: try $0.decode(column: "id", as: UUID.self),
                relevance: Double(try $0.decode(column: "rank", as: Float.self))
            )
        }
    }

    func existing(_ words: [IndexWord], scope: CatalogueScope, on sql: any SQLDatabase) async throws -> Set<String>? {
        guard !words.isEmpty else { return [] }
        var columns: [SQLQueryString] = []
        for (index, word) in words.enumerated() {
            var found: [SQLQueryString] = []
            if !word.lexemes.isEmpty || !word.phrases.isEmpty {
                let query = Self.tsquery(word)
                found.append("EXISTS (SELECT 1 FROM products p WHERE \(scope.predicate) AND p.search @@ to_tsquery('simple', \(bind: query)))")
                found.append("""
                    EXISTS (SELECT 1 FROM variants v JOIN products p ON p.id = v.product_id \
                    WHERE \(Self.colourVector) @@ to_tsquery('simple', \(bind: query)) AND \(scope.predicate))
                    """)
            }
            if !word.brands.isEmpty {
                found.append("EXISTS (SELECT 1 FROM products p WHERE \(scope.predicate) AND p.brand_id IN (\(binds: word.brands)))")
            }
            let expression: SQLQueryString = found.isEmpty ? "false" : found.joined(separator: " OR ")
            columns.append("(\(expression)) AS \(ident: "k\(index)")")
        }
        guard let row = try await sql.raw("SELECT \(columns.joined(separator: ", "))").first() else { return [] }
        var out: Set<String> = []
        for (index, word) in words.enumerated() where try row.decode(column: "k\(index)", as: Bool.self) {
            out.insert(word.word)
        }
        return out
    }
}

struct PortableTextIndex: CatalogueTextIndex {
    func candidates(
        for words: [IndexWord],
        narrowing: SQLQueryString?,
        ruledOut: [IndexWord],
        scope: CatalogueScope,
        limit: Int,
        on sql: any SQLDatabase
    ) async throws -> [IndexCandidate] {
        var any: [SQLQueryString] = []
        for word in words {
            for lexeme in word.lexemes {
                any.append(Self.like(lexeme))
            }
            // A compound's last part is enough to find it; the grammar decides the rest.
            for phrase in word.phrases {
                if let last = phrase.last { any.append(Self.like(last)) }
            }
            if !word.brands.isEmpty { any.append("p.brand_id IN (\(binds: word.brands))") }
        }
        let extra: SQLQueryString = narrowing.map { " AND \($0)" } ?? ""
        let text: SQLQueryString = any.isEmpty ? "" : " AND (" + any.joined(separator: " OR ") + ")"
        let rows = try await sql.raw("""
            SELECT p.id AS id FROM products p
            WHERE \(scope.predicate)\(extra)\(text)
            ORDER BY p.published_at DESC, p.id LIMIT \(literal: limit)
            """).all()
        return try rows.map { IndexCandidate(id: try $0.decode(column: "id", as: UUID.self), relevance: 0) }
    }

    /// The candidates' vocabulary answers, which on a test-sized store is the whole store.
    func existing(_ words: [IndexWord], scope: CatalogueScope, on sql: any SQLDatabase) async throws -> Set<String>? {
        nil
    }

    private static func like(_ lexeme: String) -> SQLQueryString {
        let pattern = "%\(lexeme)%"
        return """
            (lower(p.title) LIKE \(bind: pattern) OR lower(coalesce(p.product_type, '')) LIKE \(bind: pattern) \
            OR lower(p.tags) LIKE \(bind: pattern) \
            OR EXISTS (SELECT 1 FROM variants v WHERE v.product_id = p.id AND lower(coalesce(v.color, '')) LIKE \(bind: pattern)))
            """
    }
}

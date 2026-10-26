// AddProductSearch.swift
// A weighted full-text column on `products`, and the two indexes product search reads.
//
// Postgres only. SQLite has nothing to add — `PortableTextIndex` reads the plain columns with
// `LIKE` — so the tests exercise the route and the grammar there, and ranking quality is a
// property of the deployment's Postgres alone.
//
// **`simple`, not `english`.** Product names are not prose, and every thing the English
// configuration does to prose is wrong here: it drops "on", "off" and "all" as stop words,
// which takes On Running, Off-White and All Saints apart; it stems "Vans" to "van" and "boxy"
// to "boxi"; and a stem that lands two garments on one lexeme is the substring bug by another
// route. `simple` lowercases and splits and nothing else. The grammar already knows a word's
// other number and its true synonyms (`ShopQuery.Term.forms`) and spells them out in the
// query, the same on the phone and here — so a stemmer would only add matches the phone
// would never make, and the final say is `ShopSearch`'s whole-token match in Swift anyway.
// This index decides what is *found*; the grammar decides what *matches*.
//
// **Generated, so nothing that writes a product changes.** The poller writes `products` and
// is not touched by this: Postgres recomputes the column on every insert and update. It does
// make each row wider, and every rewrite `Poller.refresh` does not avoid now writes the
// vector too — another reason those guards matter.
//
// Three things the column cannot hold, because a generated column sees one row of one table:
// the brand's name (a join — `ProductSearch` matches names in Swift, there are hundreds), the
// colourways (variants, indexed below by expression) and a measured colour (phone only).
//
// Weights: the title is `A`, the product type `B` and the tags `D` — the order `ShopIndex`
// weighs them in, with `C` left for the colourways it puts between them, which are ranked
// from their own index.

import Fluent
import SQLKit

struct AddProductSearch: AsyncMigration {
    func prepare(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase, sql.dialect.name == "postgresql" else { return }

        // Accents folded the way `ShopText.folded` folds them, so "Stüssy" in a title is found
        // by "stussy" typed. `unaccent` would be the obvious tool and is a contrib extension
        // that is not `IMMUTABLE`, which a generated column requires; `translate` is both
        // built in and immutable. A letter folded here that Swift does not fold (ø) costs a
        // candidate the grammar then turns away; the reverse would lose one, so it errs wide.
        try await sql.raw("""
            CREATE OR REPLACE FUNCTION streetw_fold(text) RETURNS text
            LANGUAGE sql IMMUTABLE PARALLEL SAFE AS $$
              SELECT translate(coalesce($1, ''),
                'ÀÁÂÃÄÅàáâãäåÈÉÊËèéêëÌÍÎÏìíîïÒÓÔÕÖØòóôõöøÙÚÛÜùúûüÝýÿÑñÇç',
                'AAAAAAaaaaaaEEEEeeeeIIIIiiiiOOOOOOooooooUUUUuuuuYyyNnCc')
            $$
            """).run()
        // `array_to_string` is only `STABLE`, because some element types print differently
        // under different settings. Text does not, and a generated column needs the promise.
        try await sql.raw("""
            CREATE OR REPLACE FUNCTION streetw_join(text[]) RETURNS text
            LANGUAGE sql IMMUTABLE PARALLEL SAFE AS $$
              SELECT coalesce(array_to_string($1, ' '), '')
            $$
            """).run()
        try await sql.raw("""
            ALTER TABLE products ADD COLUMN IF NOT EXISTS search tsvector
            GENERATED ALWAYS AS (
              setweight(to_tsvector('simple', streetw_fold(title)), 'A') ||
              setweight(to_tsvector('simple', streetw_fold(product_type)), 'B') ||
              setweight(to_tsvector('simple', streetw_fold(streetw_join(tags))), 'D')
            ) STORED
            """).run()
        try await sql.raw("CREATE INDEX IF NOT EXISTS idx_products_search ON products USING GIN (search)").run()
        // An expression index rather than a column, so `variants` — written on every stock
        // change — is not made wider for a field read only by search. A query uses it only if
        // it spells the expression exactly this way: `PostgresTextIndex.colourVector`.
        try await sql.raw("""
            CREATE INDEX IF NOT EXISTS idx_variants_color_search ON variants
            USING GIN (to_tsvector('simple', streetw_fold(color)))
            """).run()
    }

    func revert(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase, sql.dialect.name == "postgresql" else { return }
        try await sql.raw("DROP INDEX IF EXISTS idx_variants_color_search").run()
        try await sql.raw("DROP INDEX IF EXISTS idx_products_search").run()
        try await sql.raw("ALTER TABLE products DROP COLUMN IF EXISTS search").run()
        try await sql.raw("DROP FUNCTION IF EXISTS streetw_join(text[])").run()
        try await sql.raw("DROP FUNCTION IF EXISTS streetw_fold(text)").run()
    }
}

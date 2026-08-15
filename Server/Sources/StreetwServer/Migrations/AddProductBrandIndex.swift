// AddProductBrandIndex.swift
// `products (brand_id, published_at DESC)` — one brand's catalogue, newest first.
//
// `/v1/brands/popular` now asks that question once per recommendation rather than once for
// all of them, because a single date-sorted query with a global `LIMIT` is not a per-brand
// budget: the prolific storefronts take the whole window and the brands under them come
// back with no photographs at all. Per-brand is the correct shape and it is up to forty
// small queries, so it wants an index — `products.brand_id` is a foreign key, and Postgres
// does not index the referencing side on its own. Eighteen thousand rows sequentially
// scanned forty times is exactly the kind of thing that is fine in a local SQLite fixture
// and slow on the deployment.
//
// `AddIndexes` is left alone for the same reason `CreateSchema` is: it has already been
// applied in production, so editing it would change nothing there while letting the two
// diverge.

import Fluent
import SQLKit

struct AddProductBrandIndex: AsyncMigration {
    func prepare(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else { return }
        try await sql.raw("""
            CREATE INDEX IF NOT EXISTS idx_products_brand_published \
            ON products (brand_id, published_at DESC)
            """).run()
    }

    func revert(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else { return }
        try await sql.raw("DROP INDEX IF EXISTS idx_products_brand_published").run()
    }
}

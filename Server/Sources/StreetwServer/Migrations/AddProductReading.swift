// AddProductReading.swift
// `products.shot_index` and `products.style_words` — the product shot and the style words, read
// once per product off its photographs (`ProductReading`, Phase 5) — and `product_readings`, the
// reading's own ledger.
//
// **The answer on `products`, the bookkeeping beside it.** The feed, Discover and search all
// build their rows from `ProductModel`, so the two values every one of them sends live on the row
// they already read: no route needs a join to say them. What the reading needs to know about
// itself — what it read, when to ask again, which photographs were written off — is nobody
// else's business and lives in `product_readings`, so the poller's rewrites of `products` never
// carry it and the backfill's writes never touch a row the poller is holding.
//
// - **Both nullable, no backfill.** Nil `style_words` is "not read", which is every existing
//   row, honestly; an empty array is "read, and nothing was clear enough to say". Nil
//   `shot_index` is "no clean product shot" once read.
// - **`TEXT[]` on Postgres, not JSONB** — the trap `AddUserDressAndSuitSizes` documents, which
//   SQLite cannot reproduce. And a GIN index on it, because search asks `style_words && ARRAY[…]`
//   of the whole scope (`PostgresTextIndex`).
// - **`product_readings` exists on Postgres only.** The backfill that writes it is Postgres-only
//   (it compares slices of `image_urls`, and its SigLIP half needs pgvector), so a SQLite table
//   would be one nothing ever wrote.
// - **One column per `update()`**, for the reason `AddSaleLedgers` gives.

import Fluent
import SQLKit

struct AddProductReading: AsyncMigration {
    func prepare(on database: any Database) async throws {
        let isPostgres = (database as? any SQLDatabase)?.dialect.name == "postgresql"
        try await database.schema(ProductModel.schema)
            .field("shot_index", .int)
            .update()
        try await database.schema(ProductModel.schema)
            .field("style_words", isPostgres ? .custom(SQLRaw("TEXT[]")) : .array(of: .string))
            .update()

        guard isPostgres, let sql = database as? any SQLDatabase else { return }
        try await sql.raw("CREATE INDEX IF NOT EXISTS idx_products_style_words ON products USING GIN (style_words)").run()
        try await sql.raw("""
            CREATE TABLE IF NOT EXISTS product_readings (
              product_id UUID PRIMARY KEY REFERENCES products(id) ON DELETE CASCADE,
              method TEXT NOT NULL,
              photographs TEXT NOT NULL,
              read_at TIMESTAMPTZ NOT NULL DEFAULT now(),
              attempts INTEGER NOT NULL DEFAULT 0,
              retry_at TIMESTAMPTZ,
              gone TEXT[] NOT NULL DEFAULT '{}'
            )
            """).run()
    }

    func revert(on database: any Database) async throws {
        if let sql = database as? any SQLDatabase, sql.dialect.name == "postgresql" {
            try await sql.raw("DROP TABLE IF EXISTS product_readings").run()
            try await sql.raw("DROP INDEX IF EXISTS idx_products_style_words").run()
        }
        try await database.schema(ProductModel.schema).deleteField("style_words").update()
        try await database.schema(ProductModel.schema).deleteField("shot_index").update()
    }
}

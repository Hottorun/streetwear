// AddProductEnrichment.swift
// `products.enriched_at` and `products.pending_announcement` — reading a sitemap product's
// own page, once.
//
// A sitemap gives a URL and at best a photograph, so every sitemap brand's products had no
// price, no stock and no sizes: no size run, no price drop, nothing to set a watch on.
// `Poller.enrich` now reads each new product's page for its schema.org `Product` data and
// holds the product's announcement until it has. These are its ledger, in the row for the
// same reason `events.notified_at` is: a restart must not read every page again, nor
// announce a product twice.
//
// Both nullable with no backfill. Every existing row is honestly "never read" and "owed
// nothing" — sitemap rows already announced the old way keep their events, and the pass
// reads their pages from the back of its queue.
//
// **One column per `update()`.** Fluent renders two `.field`s as one `ALTER TABLE … ADD
// COLUMN a, ADD COLUMN b`, which Postgres accepts and SQLite rejects.

import Fluent

struct AddProductEnrichment: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(ProductModel.schema)
            .field("enriched_at", .datetime)
            .update()
        try await database.schema(ProductModel.schema)
            .field("pending_announcement", .string)
            .update()
    }

    func revert(on database: any Database) async throws {
        try await database.schema(ProductModel.schema)
            .deleteField("pending_announcement")
            .update()
        try await database.schema(ProductModel.schema)
            .deleteField("enriched_at")
            .update()
    }
}

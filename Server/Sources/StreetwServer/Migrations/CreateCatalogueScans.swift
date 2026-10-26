// CreateCatalogueScans.swift
// What the daily full scan needs stored — see `Poller.scanTick` and `docs/server.md`.
//
// - `catalogue_scans` — one row per Shopify source: its schedule (`due_at`, which is also the
//   lease), the scan in progress (the page to read next, the products it has seen as digests,
//   the sale reading so far) and what the last one found. Its own table rather than columns on
//   `sources`, because the poll claims `sources` rows with `FOR UPDATE SKIP LOCKED` on every
//   tick and a scan holding the same row would make the poll skip it. Created empty: the
//   scanner adds a row for each Shopify source it finds without one, each due at its own slot
//   in the day, so nothing is scanned at the moment of the deploy.
// - `products.missing_since`, `products.unlisted_at` — a product a complete scan did not find,
//   and one that two in a row did not. Nullable with no backfill: nothing is missing until a
//   scan says so.
// - `brands.catalogue_share`, `brands.catalogue_measured_at` — the last complete scan's sale
//   reading (`CatalogueSale.State`).
//
// **One column per `update()`**, for the reason `AddSaleLedgers` gives.

import Fluent
import SQLKit

struct CreateCatalogueScans: AsyncMigration {
    private static var productColumns: [(String, DatabaseSchema.DataType)] {
        [("missing_since", .datetime), ("unlisted_at", .datetime)]
    }

    private static var brandColumns: [(String, DatabaseSchema.DataType)] {
        [("catalogue_share", .double), ("catalogue_measured_at", .datetime)]
    }

    func prepare(on database: any Database) async throws {
        try await database.schema(CatalogueScanModel.schema)
            .id()
            .field("source_id", .uuid, .required, .references(SourceModel.schema, "id", onDelete: .cascade))
            .field("due_at", .datetime, .required)
            .field("started_at", .datetime)
            .field("next_page", .int, .required, .sql(.default(1)))
            .field("is_baseline", .bool, .required, .sql(.default(false)))
            .field("seen", .string)
            .field("priced", .int, .required, .sql(.default(0)))
            .field("marked_down", .int, .required, .sql(.default(0)))
            .field("deepest", .int)
            .field("failure_count", .int, .required, .sql(.default(0)))
            .field("last_error", .string)
            .field("completed_at", .datetime)
            .field("last_started_at", .datetime)
            .field("finished_at", .datetime)
            .field("last_pages", .int)
            .field("last_products", .int)
            .field("last_truncated", .bool)
            .unique(on: "source_id")
            .create()

        if let sql = database as? any SQLDatabase {
            try await sql.raw("CREATE INDEX IF NOT EXISTS idx_catalogue_scans_due ON catalogue_scans (due_at)").run()
        }

        for (name, type) in Self.productColumns {
            try await database.schema(ProductModel.schema).field(.string(name), type).update()
        }
        for (name, type) in Self.brandColumns {
            try await database.schema(BrandModel.schema).field(.string(name), type).update()
        }
    }

    func revert(on database: any Database) async throws {
        for (name, _) in Self.brandColumns.reversed() {
            try await database.schema(BrandModel.schema).deleteField(.string(name)).update()
        }
        for (name, _) in Self.productColumns.reversed() {
            try await database.schema(ProductModel.schema).deleteField(.string(name)).update()
        }
        try await database.schema(CatalogueScanModel.schema).delete()
    }
}

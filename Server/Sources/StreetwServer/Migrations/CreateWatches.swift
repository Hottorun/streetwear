// CreateWatches.swift
// `watches` — a person's standing request to be told when one product comes back.
//
// The `fired_sizes` column is **TEXT[]**, not JSONB. Fluent binds a Swift `[String]` as a
// native Postgres array, so a column declared `.json` renders as JSONB and rejects every
// insert with `column is of type jsonb but expression is of type text[]`. SQLite has no
// array type and JSON-encodes instead, which is why that class of bug cannot reproduce
// locally — it only appears against the deployed Postgres, where production
// `ErrorMiddleware` reduces it to "Something went wrong". `CreateSchema` shipped with
// exactly this mistake and needed `FixPostgresArrayColumns` to undo it; new tables get it
// right the first time.
//
// `.cascade` on both parents is load-bearing in opposite directions. A deleted product
// must take its watches, because a watch on a row that no longer exists can never fire and
// would strand the poller's join. A deleted user must take theirs, because a watch is
// meaningless without someone to notify.

import Fluent
import SQLKit

struct CreateWatches: AsyncMigration {
    func prepare(on database: any Database) async throws {
        let isPostgres = (database as? any SQLDatabase)?.dialect.name == "postgresql"
        let sizes: DatabaseSchema.DataType = isPostgres
            ? .custom(SQLRaw("TEXT[]"))
            : .array(of: .string)

        try await database.schema(WatchModel.schema)
            .id()
            .field("user_id", .uuid, .required, .references(UserModel.schema, "id", onDelete: .cascade))
            .field("brand_id", .uuid, .required, .references(BrandModel.schema, "id", onDelete: .cascade))
            .field("product_id", .uuid, .required, .references(ProductModel.schema, "id", onDelete: .cascade))
            .field("size", .string)
            .field("color", .string)
            .field("created_at", .datetime)
            .field("fired_at", .datetime)
            .field("fired_sizes", sizes, .required)
            // One watch per user per product per size/colour pair. Tapping the button
            // twice is a mis-tap, not a request for two notifications.
            .unique(on: "user_id", "product_id", "size", "color")
            .create()

        // The poller's hot path is "does this product have any unfired watches", once per
        // restocked product per pass. Without this it is a sequential scan of the table
        // on every restock.
        guard let sql = database as? any SQLDatabase else { return }
        try await sql.raw(
            "CREATE INDEX IF NOT EXISTS watches_product_pending ON watches (product_id) WHERE fired_at IS NULL"
        ).run()
    }

    func revert(on database: any Database) async throws {
        try await database.schema(WatchModel.schema).delete()
    }
}

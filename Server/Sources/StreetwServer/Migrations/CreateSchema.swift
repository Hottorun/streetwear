// CreateSchema.swift
// One migration for the initial schema. Array columns are declared `.json` rather than
// `.array(of:)` so the same migration runs on Postgres (jsonb) in production and on
// SQLite locally — nothing queries inside them server-side yet.

import Fluent
import SQLKit

struct CreateSchema: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(BrandModel.schema)
            .id()
            .field("name", .string, .required)
            .field("slug", .string, .required)
            .field("website", .string)
            .field("instagram_handle", .string)
            .field("currency", .string)
            .field("locked_for_drop", .bool, .required, .sql(.default(false)))
            .field("uses_generated_name", .bool, .required, .sql(.default(false)))
            .field("created_at", .datetime)
            .unique(on: "slug")
            .create()

        try await database.schema(SourceModel.schema)
            .id()
            .field("brand_id", .uuid, .required, .references(BrandModel.schema, "id", onDelete: .cascade))
            .field("kind", .string, .required)
            .field("url", .string, .required)
            .field("enabled", .bool, .required, .sql(.default(true)))
            .field("etag", .string)
            .field("fingerprint", .string)
            .field("failure_count", .int, .required, .sql(.default(0)))
            .field("last_error", .string)
            .field("last_checked_at", .datetime)
            .field("next_check_at", .datetime, .required)
            .unique(on: "brand_id", "kind", "url")
            .create()

        try await database.schema(ProductModel.schema)
            .id()
            .field("brand_id", .uuid, .required, .references(BrandModel.schema, "id", onDelete: .cascade))
            .field("source_id", .uuid, .references(SourceModel.schema, "id", onDelete: .setNull))
            .field("external_id", .string, .required)
            .field("title", .string, .required)
            .field("summary", .string)
            .field("link_url", .string)
            .field("image_urls", .json, .required)
            .field("kind", .string, .required)
            .field("price_text", .string)
            .field("is_available", .bool)
            .field("tags", .json, .required)
            .field("product_type", .string)
            .field("published_at", .datetime, .required)
            .field("first_seen_at", .datetime)
            .field("last_seen_at", .datetime, .required)
            // The dedupe key. Same product from the same source is one row, forever.
            .unique(on: "source_id", "external_id")
            .create()

        try await database.schema(VariantModel.schema)
            .id()
            .field("product_id", .uuid, .required, .references(ProductModel.schema, "id", onDelete: .cascade))
            .field("external_id", .string, .required)
            .field("title", .string, .required)
            .field("size", .string)
            .field("color", .string)
            .field("available", .bool, .required)
            .field("price", .string)
            .field("available_changed_at", .datetime)
            .unique(on: "product_id", "external_id")
            .create()

        try await database.schema(EventModel.schema)
            .id()
            .field("brand_id", .uuid, .required, .references(BrandModel.schema, "id", onDelete: .cascade))
            .field("product_id", .uuid, .references(ProductModel.schema, "id", onDelete: .cascade))
            .field("kind", .string, .required)
            .field("sizes", .json, .required)
            .field("created_at", .datetime)
            .create()

        try await database.schema(UserModel.schema)
            .id()
            .field("created_at", .datetime)
            .field("apparel_sizes", .json, .required)
            .field("shoe_sizes", .json, .required)
            .field("include_one_size", .bool, .required, .sql(.default(true)))
            .create()

        try await database.schema(DeviceModel.schema)
            .id()
            .field("user_id", .uuid, .required, .references(UserModel.schema, "id", onDelete: .cascade))
            .field("apns_token", .string)
            .field("auth_token", .string, .required)
            .field("environment", .string, .required)
            .field("locale", .string)
            .field("updated_at", .datetime)
            .unique(on: "auth_token")
            .create()

        try await database.schema(FollowModel.schema)
            .id()
            .field("user_id", .uuid, .required, .references(UserModel.schema, "id", onDelete: .cascade))
            .field("brand_id", .uuid, .required, .references(BrandModel.schema, "id", onDelete: .cascade))
            .field("created_at", .datetime)
            .unique(on: "user_id", "brand_id")
            .create()
    }

    func revert(on database: any Database) async throws {
        for schema in [
            FollowModel.schema, DeviceModel.schema, UserModel.schema,
            EventModel.schema, VariantModel.schema, ProductModel.schema,
            SourceModel.schema, BrandModel.schema
        ] {
            try await database.schema(schema).delete()
        }
    }
}

/// Indexes the poll queue and the feed depend on. Kept separate so it can be tuned
/// without touching the table definitions.
struct AddIndexes: AsyncMigration {
    func prepare(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else { return }
        // The poller's hot query: due sources, oldest first.
        try await sql.raw("CREATE INDEX IF NOT EXISTS idx_sources_next_check ON sources (next_check_at)").run()
        // Feed reads: a brand's recent events.
        try await sql.raw("CREATE INDEX IF NOT EXISTS idx_events_brand_created ON events (brand_id, created_at)").run()
        try await sql.raw("CREATE INDEX IF NOT EXISTS idx_events_created ON events (created_at)").run()
        try await sql.raw("CREATE INDEX IF NOT EXISTS idx_variants_product ON variants (product_id)").run()
        try await sql.raw("CREATE INDEX IF NOT EXISTS idx_follows_brand ON follows (brand_id)").run()
    }

    func revert(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else { return }
        for name in [
            "idx_sources_next_check", "idx_events_brand_created", "idx_events_created",
            "idx_variants_product", "idx_follows_brand"
        ] {
            try await sql.raw("DROP INDEX IF EXISTS \(unsafeRaw: name)").run()
        }
    }
}

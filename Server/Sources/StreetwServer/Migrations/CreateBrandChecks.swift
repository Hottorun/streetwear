// CreateBrandChecks.swift
// `brand_checks` and `brand_check_watchers` — discovery, run off the request.
//
// `brand_id` is `.setNull`, not `.cascade`: deleting a brand must not delete the record
// that somebody asked about it, and a check whose brand is gone simply reads as one that
// has not created one yet. Watchers cascade from both parents — a deleted user has nobody
// left to follow anything for, and a pruned check takes the requests that hung off it.

import Fluent
import SQLKit

struct CreateBrandChecks: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(BrandCheckModel.schema)
            .id()
            .field("domain", .string, .required)
            .field("url", .string, .required)
            .field("status", .string, .required)
            .field("probe", .string)
            .field("logo_url", .string)
            .field("brand_id", .uuid, .references(BrandModel.schema, "id", onDelete: .setNull))
            .field("created_at", .datetime)
            .field("finished_at", .datetime)
            .create()

        try await database.schema(BrandCheckWatcherModel.schema)
            .id()
            .field("check_id", .uuid, .required, .references(BrandCheckModel.schema, "id", onDelete: .cascade))
            .field("user_id", .uuid, .required, .references(UserModel.schema, "id", onDelete: .cascade))
            .field("instagram", .string)
            .field("settled_at", .datetime)
            .field("created_at", .datetime)
            .unique(on: "check_id", "user_id")
            .create()

        // Every start asks "is somebody already checking this shop", by domain.
        guard let sql = database as? any SQLDatabase else { return }
        try await sql.raw(
            "CREATE INDEX IF NOT EXISTS brand_checks_domain ON brand_checks (domain, created_at)"
        ).run()
    }

    func revert(on database: any Database) async throws {
        try await database.schema(BrandCheckWatcherModel.schema).delete()
        try await database.schema(BrandCheckModel.schema).delete()
    }
}

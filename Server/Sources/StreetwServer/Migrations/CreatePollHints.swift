// CreatePollHints.swift
// `poll_hints` — one person's "this brand drops at eleven", worth exactly one hour of
// faster polling.
//
// `.cascade` on both parents, in opposite directions and for the same reasons `watches`
// has it. A deleted user must take their hints: a window nobody is waiting on is the
// server polling a storefront hard for no one. A deleted brand must take them too, or the
// queue join walks into a row with no sources behind it.
//
// The unique constraint is the schema-level half of "one hint per brand". The route
// replaces the caller's whole set and de-duplicates before writing, so this is the guard
// rather than the mechanism — but it is the guard that survives a future second writer.

import Fluent
import SQLKit

struct CreatePollHints: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(PollHintModel.schema)
            .id()
            .field("user_id", .uuid, .required, .references(UserModel.schema, "id", onDelete: .cascade))
            .field("brand_id", .uuid, .required, .references(BrandModel.schema, "id", onDelete: .cascade))
            .field("release_at", .datetime, .required)
            .field("created_at", .datetime)
            .unique(on: "user_id", "brand_id")
            .create()

        // The poll queue asks one question of this table, once per tick: *which brands are
        // inside a hint window right now*. That is a plain range scan over `release_at`
        // — `PollHintPolicy.activeRange` exists precisely so it stays one — and without an
        // index it is a sequential scan on the hot path of the poller, every thirty
        // seconds, forever.
        guard let sql = database as? any SQLDatabase else { return }
        try await sql.raw(
            "CREATE INDEX IF NOT EXISTS poll_hints_release_at ON poll_hints (release_at)"
        ).run()
    }

    func revert(on database: any Database) async throws {
        try await database.schema(PollHintModel.schema).delete()
    }
}

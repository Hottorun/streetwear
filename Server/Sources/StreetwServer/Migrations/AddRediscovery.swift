// AddRediscovery.swift
// What looking at every brand again needs stored — see `Rediscovery` and `docs/server.md`.
//
// - `rediscoveries` — one row per brand per `Rediscovery.pass` (the rules' version and the
//   countries switched on): the ledger that makes the
//   pass run once and resume after a restart, and what each look found, for
//   `GET /admin/rediscovery`. Created empty, so the pass starts from the first brand.
// - `brand_checks.alternates` — the homepage's `hreflang` alternates a check read, so the
//   brand it makes can have its country shops found without the homepage being fetched again.
//   Nullable: no check before this read them.

import Fluent
import SQLKit

struct AddRediscovery: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(RediscoveryModel.schema)
            .id()
            .field("brand_id", .uuid, .required, .references(BrandModel.schema, "id", onDelete: .cascade))
            .field("pass", .string, .required)
            .field("started_at", .datetime, .required)
            .field("finished_at", .datetime)
            .field("line", .string)
            .field("added", .int, .required, .sql(.default(0)))
            .field("storefronts", .int, .required, .sql(.default(0)))
            .unique(on: "brand_id", "pass")
            .create()

        try await database.schema(BrandCheckModel.schema)
            .field("alternates", .string)
            .update()
    }

    func revert(on database: any Database) async throws {
        try await database.schema(BrandCheckModel.schema)
            .deleteField("alternates")
            .update()
        try await database.schema(RediscoveryModel.schema).delete()
    }
}

// AddBrandLogo.swift
// `brands.logo_url` — the icon a brand's own site publishes.
//
// Nullable and not backfilled: brands added before this simply have no mark until
// something refreshes them, and the client falls back to a monogram. Not worth a
// migration that re-fetches every homepage on deploy.

import Fluent

struct AddBrandLogo: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(BrandModel.schema)
            .field("logo_url", .string)
            .update()
    }

    func revert(on database: any Database) async throws {
        try await database.schema(BrandModel.schema)
            .deleteField("logo_url")
            .update()
    }
}

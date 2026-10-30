// AddCatalogueOnlyCheck.swift
// `brand_checks.catalogue_only` — the check was asked for by a save from a shop the catalogue
// did not have, to add the shop to search, and follows nobody (`BrandChecks.start`). Nullable:
// every check before this, and every check made to follow a shop, has none. A flag on the row
// and nothing else — no column records who asked, which is the point (see `docs/server.md`).

import Fluent

struct AddCatalogueOnlyCheck: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(BrandCheckModel.schema)
            .field("catalogue_only", .bool)
            .update()
    }

    func revert(on database: any Database) async throws {
        try await database.schema(BrandCheckModel.schema)
            .deleteField("catalogue_only")
            .update()
    }
}

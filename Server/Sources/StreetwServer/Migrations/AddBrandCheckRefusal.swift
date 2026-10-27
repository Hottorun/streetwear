// AddBrandCheckRefusal.swift
// `brand_checks.refusal` — why a refused check was refused (`BrandCheck.Refusal`): a shop that
// blocks automated readers, one that sells no clothes online, or nothing answered. Nullable:
// every check before this, and every one that was not refused, has none, and the app reads a
// missing reason as the generic refusal it always printed. A string, like `status`, so a
// reason a later deploy writes still reads here.

import Fluent

struct AddBrandCheckRefusal: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(BrandCheckModel.schema)
            .field("refusal", .string)
            .update()
    }

    func revert(on database: any Database) async throws {
        try await database.schema(BrandCheckModel.schema)
            .deleteField("refusal")
            .update()
    }
}

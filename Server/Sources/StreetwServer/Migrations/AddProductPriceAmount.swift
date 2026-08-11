// AddProductPriceAmount.swift
// `products.price_amount` — the price as a number rather than as display text.
//
// Nullable with no backfill: `price_text` is formatted ("€180") and locale-dependent, so
// parsing the existing column back into a number would be guesswork. Every product picks
// up an amount on its next poll, and until it has one no drop can be detected for it —
// which is correct, because there is nothing to compare against.

import Fluent

struct AddProductPriceAmount: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(ProductModel.schema)
            .field("price_amount", .double)
            .update()
    }

    func revert(on database: any Database) async throws {
        try await database.schema(ProductModel.schema)
            .deleteField("price_amount")
            .update()
    }
}

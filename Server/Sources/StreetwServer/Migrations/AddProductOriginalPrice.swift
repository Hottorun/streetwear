// AddProductOriginalPrice.swift
// `products.original_price_text` / `products.original_price_amount` — what the brand says a
// product cost before it was marked down, from Shopify's `compare_at_price`.
//
// A markdown was only ever a fall between two polls, so a product first seen already on sale
// — last season's stock moved onto the sale rail, which is most of what a sale is — had no
// "was" at all: no "−30%", nothing for the markdowns list to rank it by, and nothing for a
// brand-wide sale to be counted from.
//
// On the *product*, beside `price_text`, not on the event: it describes the product as it is
// now, and the two travel together on the wire so they always agree. An event still keeps
// the price it fell from in `previous_price_*`.
//
// Both nullable with no backfill: a product stored before this is filled in by its next
// poll, and the poller writes the row only when the value actually changed.
//
// **One column per `update()`.** Fluent renders two `.field`s as one `ALTER TABLE … ADD
// COLUMN a, ADD COLUMN b`, which Postgres accepts and SQLite rejects.

import Fluent

struct AddProductOriginalPrice: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(ProductModel.schema)
            .field("original_price_text", .string)
            .update()
        try await database.schema(ProductModel.schema)
            .field("original_price_amount", .double)
            .update()
    }

    func revert(on database: any Database) async throws {
        try await database.schema(ProductModel.schema)
            .deleteField("original_price_amount")
            .update()
        try await database.schema(ProductModel.schema)
            .deleteField("original_price_text")
            .update()
    }
}

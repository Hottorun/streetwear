// AddStorefrontColumns.swift
// Where each row came from, and what its price is in.
//
// - `sources.storefront_id` — the country shop a source reads, null for the main shop. A real
//   foreign key with `.cascade`, so removing a storefront takes its sources, and through them
//   (`products.source_id` → `events.product_id`, both cascading) everything read from it.
// - `products.storefront_id`, `events.storefront_id` — the same fact copied onto the rows the
//   feed, Discover and `Notifier` read, so none of them joins through `sources` to ask which
//   shop a row is. Plain columns: the source is the truth and the cascade above runs through
//   it.
// - `products.currency` — what the row's prices are in. Every stored price carries its
//   currency from now on; a row from before has none and is the main shop's, whose currency
//   is `brands.currency`.
// - `users.country` — which country's shops somebody is served.
//
// All nullable, none backfilled. **Null is the main shop, and every existing row is the main
// shop's**, so the true value of every one of these columns on every existing row is already
// null. A backfill would be a rewrite of every product and event row — the volume problem in
// `docs/server.md` — to write down what null says.
//
// **One column per `update()`.** Fluent renders several `.field`s as one `ALTER TABLE … ADD
// COLUMN a, ADD COLUMN b`, which Postgres accepts and SQLite rejects.

import Fluent

struct AddStorefrontColumns: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(SourceModel.schema)
            .field("storefront_id", .uuid, .references(StorefrontModel.schema, "id", onDelete: .cascade))
            .update()
        try await database.schema(ProductModel.schema).field("storefront_id", .uuid).update()
        try await database.schema(ProductModel.schema).field("currency", .string).update()
        try await database.schema(EventModel.schema).field("storefront_id", .uuid).update()
        try await database.schema(UserModel.schema).field("country", .string).update()
    }

    func revert(on database: any Database) async throws {
        try await database.schema(UserModel.schema).deleteField("country").update()
        try await database.schema(EventModel.schema).deleteField("storefront_id").update()
        try await database.schema(ProductModel.schema).deleteField("currency").update()
        try await database.schema(ProductModel.schema).deleteField("storefront_id").update()
        try await database.schema(SourceModel.schema).deleteField("storefront_id").update()
    }
}

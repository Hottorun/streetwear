// AddEventPrice.swift
// `events.previous_price_text` / `events.previous_price_amount` — what a thing cost before
// it was marked down.
//
// The price *drop* was already detected carefully — only downwards, only past 5%, and a
// restock outranks it so one product writes at most one event per poll. What was never
// recorded is the number it dropped from, so the event said "this got cheaper" and could
// not say by how much, or from what. On the client that meant a markdown card with no
// "was", and a list of markdowns that could not be ordered by the only thing that makes
// one more interesting than another.
//
// On the *event*, not on the product. `products` holds what is currently true and is
// overwritten by the next poll; an event is the record of what happened, and the price in
// it has to be what was true when it fired — the same rule that keeps `sizes` on the event
// rather than reading today's stock.
//
// Both nullable with no backfill: rows written before this genuinely have no history, and
// filling one in would be inventing a discount.

import Fluent

struct AddEventPrice: AsyncMigration {
    /// **One column per `update()`.** Fluent renders several `.field`s on an update as a
    /// single `ALTER TABLE … ADD COLUMN a, ADD COLUMN b`, which Postgres accepts and SQLite
    /// rejects outright — `near ",": syntax error`. Since local runs and the test suite are
    /// SQLite and the deployment is Postgres, writing it the other way round would have
    /// passed everywhere except production.
    func prepare(on database: any Database) async throws {
        try await database.schema(EventModel.schema)
            .field("previous_price_text", .string)
            .update()
        try await database.schema(EventModel.schema)
            .field("previous_price_amount", .double)
            .update()
    }

    func revert(on database: any Database) async throws {
        try await database.schema(EventModel.schema)
            .deleteField("previous_price_text")
            .update()
        try await database.schema(EventModel.schema)
            .deleteField("previous_price_amount")
            .update()
    }
}

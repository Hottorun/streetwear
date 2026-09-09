// AddProductMembers.swift
// `products.member_external_ids` — the garments a collection actually holds.
//
// A collection row is a product row with `kind = "collection"`, and it has never carried
// what is *in* it: `/collections.json` names a release and does not list it, so both ends
// guessed. The client matched a distinctive word from the title and fell back to whatever
// published within a day and a half; the server's Discover route does the same. Checked
// against live storefronts the guess was wrong every time — Corteiz's ISLAND PUFF PRINT
// TRUCKER HAT holds six colourways of that hat, and the release page listed five board
// shorts and a bag.
//
// `CollectionsSource` reads the real membership now, once, at the poll where the
// collection is first seen. This is where it lands so the phone can be told.
//
// **TEXT[] on Postgres, not JSONB** — Fluent binds a Swift `[String]` as a native Postgres
// array, so a `.json` column rejects every insert with "column is of type jsonb but
// expression is of type text[]". SQLite JSON-encodes and cannot reproduce it, which is why
// `CreateSchema` shipped that mistake and needed `FixPostgresArrayColumns` to undo it.
//
// `.required` with an empty default: every existing row honestly holds none, and an empty
// list already means "we were not told" everywhere it is read.

import Fluent
import SQLKit

struct AddProductMembers: AsyncMigration {
    func prepare(on database: any Database) async throws {
        let isPostgres = (database as? any SQLDatabase)?.dialect.name == "postgresql"
        let ids: DatabaseSchema.DataType = isPostgres
            ? .custom(SQLRaw("TEXT[]"))
            : .array(of: .string)

        try await database.schema(ProductModel.schema)
            .field("member_external_ids", ids, .required, .sql(.default(SQLLiteral.string("{}"))))
            .update()
    }

    func revert(on database: any Database) async throws {
        try await database.schema(ProductModel.schema)
            .deleteField("member_external_ids")
            .update()
    }
}

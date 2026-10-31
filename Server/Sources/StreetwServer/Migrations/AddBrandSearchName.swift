// AddBrandSearchName.swift
// `brands.search_name` — the name as it is searched: `BrandNaming.searchKey`, accents off.
//
// "stussy" did not find "Stüssy", so Add a brand said the shop was not in the catalogue and
// offered to add it again. Folding in the database would need `unaccent`, which is an
// extension a managed Postgres may not have and SQLite never does; a column the server fills
// itself means the same on both. Kept current by `BrandSearchName` on every create and update,
// whichever of the places that name a brand wrote it.
//
// Backfilled here, through SQL on two columns rather than through `BrandModel`, so the
// migration keeps working on an empty database after later migrations add brand columns.

import Fluent
import Foundation
import SQLKit
import StreetwCore

struct AddBrandSearchName: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(BrandModel.schema)
            .field("search_name", .string)
            .update()

        guard let sql = database as? any SQLDatabase else { return }
        try await Self.backfill(sql)
    }

    /// Every row's key, from its name. Also what a test runs to check it.
    static func backfill(_ sql: any SQLDatabase) async throws {
        let rows = try await sql.select().column("id").column("name").from(BrandModel.schema).all()
        for row in rows {
            let id = try row.decode(column: "id", as: UUID.self)
            let name = try row.decode(column: "name", as: String.self)
            try await sql.update(BrandModel.schema)
                .set("search_name", to: BrandNaming.searchKey(name))
                .where("id", .equal, id)
                .run()
        }
    }

    func revert(on database: any Database) async throws {
        try await database.schema(BrandModel.schema)
            .deleteField("search_name")
            .update()
    }
}

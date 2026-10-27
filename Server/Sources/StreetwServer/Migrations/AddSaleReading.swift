// AddSaleReading.swift
// What the model read off a sale banner beyond the pattern's percentage and code: the last
// day of the sale and its fine print (`AIBackgroundReading.readSale`). On the `.sale` event,
// because that is the one row the reading is about and the feed already sends it; nil on every
// other event and on any sale announced while AI was off.
//
// One column per `update()`, for the reason given in `AddSaleLedgers`.

import Fluent

struct AddSaleReading: AsyncMigration {
    private static var columns: [(String, DatabaseSchema.DataType)] {
        [("sale_ends_at", .datetime), ("sale_terms", .string)]
    }

    func prepare(on database: any Database) async throws {
        for (name, type) in Self.columns {
            try await database.schema(EventModel.schema).field(.string(name), type).update()
        }
    }

    func revert(on database: any Database) async throws {
        for (name, _) in Self.columns.reversed() {
            try await database.schema(EventModel.schema).deleteField(.string(name)).update()
        }
    }
}

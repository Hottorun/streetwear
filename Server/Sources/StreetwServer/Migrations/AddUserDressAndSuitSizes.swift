// AddUserDressAndSuitSizes.swift
// `users.dress_sizes`, `users.suit_sizes`, `users.suit_lengths` — the women's dress ladder
// and the men's tailoring ladder, beside the letters, the waist and the shoe.
//
// The same reason `AddUserWaistSizes` and `AddUserGender` exist: `UserModel.sizeProfile` is
// discrete columns rather than an encoded blob, so a new field on `SizeProfile` round-trips
// through the accessor and is silently dropped on write until it has a column of its own.
// The phone would store a dress size, send it up, and the server would go on targeting
// alerts as if it had never been entered — while the screen, which matches locally, looked
// right the whole time. That is exactly how the waist ladder was lost.
//
// **TEXT[] on Postgres, not JSONB.** Fluent binds a Swift `[String]` as a native Postgres
// array, so a `.json` column rejects every insert with "column is of type jsonb but
// expression is of type text[]". SQLite has no array type and JSON-encodes instead, so this
// cannot reproduce locally.
//
// **One column per `update()`.** Fluent renders several `.field`s as one `ALTER TABLE … ADD
// COLUMN a, ADD COLUMN b`, which Postgres accepts and SQLite rejects.
//
// `.required` with an empty default, like the other size columns: every existing row
// honestly holds none, and an empty ladder filters nothing. The default is spelled per
// dialect — `{}` is Postgres's empty array, while SQLite stores the JSON the driver will
// decode, and `{}` is not a JSON array.

import Fluent
import SQLKit

struct AddUserDressAndSuitSizes: AsyncMigration {
    static let columns = ["dress_sizes", "suit_sizes", "suit_lengths"]

    func prepare(on database: any Database) async throws {
        let isPostgres = (database as? any SQLDatabase)?.dialect.name == "postgresql"
        let sizes: DatabaseSchema.DataType = isPostgres
            ? .custom(SQLRaw("TEXT[]"))
            : .array(of: .string)
        let empty = SQLLiteral.string(isPostgres ? "{}" : "[]")

        for column in Self.columns {
            try await database.schema(UserModel.schema)
                .field(.string(column), sizes, .required, .sql(.default(empty)))
                .update()
        }
    }

    func revert(on database: any Database) async throws {
        for column in Self.columns.reversed() {
            try await database.schema(UserModel.schema)
                .deleteField(.string(column))
                .update()
        }
    }
}

// AddUserWaistSizes.swift
// `users.waist_sizes` — the inches a person wears, beside the letters and the shoe ladder.
//
// The same reason `AddUserGender` exists: `UserModel.sizeProfile` is three discrete columns
// rather than an encoded blob, so a new field on `SizeProfile` round-trips through the
// accessor and is silently dropped on write until it has a column of its own. The symptom
// would be a phone that stores a waist locally, sends it up, and gets nothing back — and a
// server that then targets restock pushes on a profile missing the one ladder that decides
// whether a pair of trousers is news.
//
// **TEXT[] on Postgres, not JSONB.** Fluent binds a Swift `[String]` as a native Postgres
// array, so a column declared `.json` renders as JSONB and rejects every insert with
// `column is of type jsonb but expression is of type text[]`. SQLite has no array type and
// JSON-encodes instead, so this cannot reproduce locally — it only appears against the
// deployed database, where production `ErrorMiddleware` reduces it to "Something went
// wrong". `CreateSchema` shipped with that mistake and needed `FixPostgresArrayColumns` to
// undo it; anything new declares the type per dialect from the start.
//
// `.required` with an empty default, matching `apparel_sizes` and `shoe_sizes`: an empty
// set means "no preference", which is what every existing row honestly holds, and it keeps
// the getter from having to distinguish null from empty.

import Fluent
import SQLKit

struct AddUserWaistSizes: AsyncMigration {
    func prepare(on database: any Database) async throws {
        let isPostgres = (database as? any SQLDatabase)?.dialect.name == "postgresql"
        let sizes: DatabaseSchema.DataType = isPostgres
            ? .custom(SQLRaw("TEXT[]"))
            : .array(of: .string)

        try await database.schema(UserModel.schema)
            .field("waist_sizes", sizes, .required, .sql(.default(SQLLiteral.string("{}"))))
            .update()
    }

    func revert(on database: any Database) async throws {
        try await database.schema(UserModel.schema)
            .deleteField("waist_sizes")
            .update()
    }
}

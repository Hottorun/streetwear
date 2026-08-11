// AddUserGender.swift
// `users.gender` — which genders a person wants to hear about.
//
// It belongs beside the size columns for exactly the same reason those are server-side:
// the server decides whether a drop is news for this particular person, and it can only
// do that if it knows. Without the column, `SizeProfile.gender` round-trips through
// `UserModel.sizeProfile` and is silently dropped on write — the profile is stored as
// three discrete columns rather than an encoded blob, so a new field on the struct is not
// automatically a new field in the row.
//
// Nullable with no backfill on purpose: absent means "everything", which is both the
// default for a new profile and the correct reading of a user who has never expressed a
// preference. Backfilling a literal would be indistinguishable from a real choice.

import Fluent

struct AddUserGender: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(UserModel.schema)
            .field("gender", .string)
            .update()
    }

    func revert(on database: any Database) async throws {
        try await database.schema(UserModel.schema)
            .deleteField("gender")
            .update()
    }
}

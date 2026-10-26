// CreateAccounts.swift
// `accounts` — the identity that survives a reinstall — and `users.account_id`.
//
// Until now every install was a new user, and that was fine while nothing on the server was
// worth keeping past one phone. Credits change that: StoreKit cannot restore a consumable, so
// a balance has to live under something Apple will hand back after the app is deleted, which
// is the Sign in with Apple subject. The `users` row was kept apart from `devices` from the
// start so this could be hung off it without migrating everything else (`BACKEND.md`).
//
// **An account owns users, not the other way round.** "A profile is a person"
// (`ROADMAP.md`): Phase 2's profiles are one server user each under one account, so
// `users.account_id` is a plain index, never unique. Today an account has exactly one user.
//
// **Nullable, and null is the normal case.** Every user that exists was made anonymously,
// and signing in stays optional — 1.0 and 1.1 never call the account routes, so their users
// keep a null here for as long as they exist, and nothing that reads a user may assume one.
//
// **`ON DELETE CASCADE`** from the account to its users, and from a user (already) to its
// devices, follows, watches and poll hints. Deleting an account is a promise to delete
// everything personal under it; the route deletes those rows explicitly in one transaction
// too, and the cascade is the guard that holds for a later writer that forgets one.
//
// `monthly_cost_cap_micros` is a `BIGINT`: a cost in millionths of a dollar passes 2^31 at
// $2,147, which one month of a heavy account could reach. `unlimited_credits` is
// `NOT NULL DEFAULT false` for the reason `follows.mode` is not nullable — a filter written
// the obvious way (`unlimited_credits = false`) is NULL, not true, on a NULL row.
//
// `apple_refresh_token` is what `/auth/revoke` needs when the account is deleted. It is the
// only secret in the table; it is never logged and never sent back to anybody.
//
// One column per `update()`, as everywhere else — see `AddEventPrice`.

import Fluent
import SQLKit

struct CreateAccounts: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(AccountModel.schema)
            .id()
            .field("apple_subject", .string, .required)
            .field("created_at", .datetime)
            .field("unlimited_credits", .bool, .required, .sql(.default(false)))
            .field("monthly_cost_cap_micros", .int64)
            .field("apple_refresh_token", .string)
            .unique(on: "apple_subject")
            .create()

        try await database.schema(UserModel.schema)
            .field("account_id", .uuid, .references(AccountModel.schema, "id", onDelete: .cascade))
            .update()

        // Every account route starts from "the users under this account", and the admin list
        // counts them per account.
        guard let sql = database as? any SQLDatabase else { return }
        try await sql.raw(
            "CREATE INDEX IF NOT EXISTS users_account_id ON users (account_id)"
        ).run()
    }

    func revert(on database: any Database) async throws {
        if let sql = database as? any SQLDatabase {
            try await sql.raw("DROP INDEX IF EXISTS users_account_id").run()
        }
        try await database.schema(UserModel.schema)
            .deleteField("account_id")
            .update()
        try await database.schema(AccountModel.schema).delete()
    }
}

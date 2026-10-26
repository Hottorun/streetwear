// AddUserProfiles.swift
// `users.display_name` and `users.alerts_enabled` — what makes a user under an account a
// profile. See `docs/profiles.md`.
//
// A profile is not a new table. It is a `users` row with an `account_id`, which is what every
// signed-in user already is, so its follows, watches, poll hints and sizes need no migration
// at all: they were always per user. What a second person on one account needs on top is a
// name to label their alerts with and a switch to turn those alerts off.
//
// **`display_name` is nullable** and null is the normal case: every anonymous user, and the
// holder until they name themselves.
//
// **`alerts_enabled` is `NOT NULL DEFAULT true`**, for the reason `follows.mode` is not
// nullable: every user that exists today gets alerts, and `alerts_enabled = false` is NULL,
// not true, for a NULL row — a filter written the obvious way would have silenced every user
// older than this migration.
//
// One column per `update()`, as everywhere else — see `AddEventPrice`.

import Fluent
import SQLKit

struct AddUserProfiles: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(UserModel.schema)
            .field("display_name", .string)
            .update()
        try await database.schema(UserModel.schema)
            .field("alerts_enabled", .bool, .required, .sql(.default(true)))
            .update()
    }

    func revert(on database: any Database) async throws {
        try await database.schema(UserModel.schema)
            .deleteField("alerts_enabled")
            .update()
        try await database.schema(UserModel.schema)
            .deleteField("display_name")
            .update()
    }
}

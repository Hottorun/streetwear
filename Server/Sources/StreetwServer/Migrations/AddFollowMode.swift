// AddFollowMode.swift
// `follows.mode` — how much of a followed brand reaches this person. See `FollowMode`.
//
// On the follow rather than the user or the brand, because it is neither a fact about the
// person nor about the shop: it is one person's relationship with one shop, which is what a
// follow row already is. The catalogue stays impersonal; `brands` gains nothing.
//
// **`NOT NULL DEFAULT 'everything'`, not nullable.** Every row that exists today was made by
// somebody who had no way to choose and was getting everything, so the default is the true
// reading of all of them — unlike `users.gender`, where a literal would have been
// indistinguishable from a choice nobody made. And a nullable column here is a trap the
// notifier would walk into: `mode != 'quiet'` is NULL, not true, for a NULL row, so a filter
// written the obvious way would have silenced every follow that predates this migration.
//
// Default also covers every follow the 1.0 app creates from now on — it sends no mode and
// has no way to show one, so it must keep getting exactly what it got.

import Fluent
import SQLKit
import StreetwCore

struct AddFollowMode: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(FollowModel.schema)
            .field("mode", .string, .required, .sql(.default(FollowMode.everything.rawValue)))
            .update()
    }

    func revert(on database: any Database) async throws {
        try await database.schema(FollowModel.schema)
            .deleteField("mode")
            .update()
    }
}

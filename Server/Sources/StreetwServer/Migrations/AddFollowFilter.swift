// AddFollowFilter.swift
// `follows.filter` — which part of a followed brand reaches this person. See `FollowFilter`.
//
// On the follow, beside `mode`, for the reason `AddFollowMode` gives: it is one person's
// relationship with one shop, so it belongs on the row that already is that, and the
// catalogue gains nothing.
//
// **Nullable, and null is *All*.** Unlike the mode there is no value every existing row truly
// holds except "no filter", and a column that is null for every follow made before this
// migration — and every follow 1.0 to 1.3 will ever make — says exactly that.
//
// **One JSON text column, not `TEXT[]` and not discrete columns.** The filter is read in Swift
// alone — `Notifier` and the follow list decode it, nothing ever asks SQL about it — so it has
// no use for a native type, and an array column is the one thing that cannot be reproduced on
// SQLite (see *A `[String]` column must be `TEXT[]` on Postgres* in `docs/server.md`). Text is
// text on both, so every test of it means the same on either. A filter a newer client writes
// that this build does not understand decodes leniently (`FollowFilter.init(from:)`).

import Fluent

struct AddFollowFilter: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(FollowModel.schema)
            .field("filter", .string)
            .update()
    }

    func revert(on database: any Database) async throws {
        try await database.schema(FollowModel.schema)
            .deleteField("filter")
            .update()
    }
}

// AddBrandNotifyLedger.swift
// `brands.last_notified_at` — when a brand last interrupted anybody.
//
// The ledger behind `Notifier.cooldown`. In the row rather than in memory for exactly the
// same reason `events.notified_at` and `sources.next_check_at` are: a restart must not
// reopen the floodgate, and a second instance must reach the same conclusion as the first.
//
// Nullable with no backfill. Every existing brand reads as "has never notified", so the
// first pass after this lands behaves precisely as it did before — the cooldown only ever
// begins from a push that actually happened.

import Fluent

struct AddBrandNotifyLedger: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(BrandModel.schema)
            .field("last_notified_at", .datetime)
            .update()
    }

    func revert(on database: any Database) async throws {
        try await database.schema(BrandModel.schema)
            .deleteField("last_notified_at")
            .update()
    }
}

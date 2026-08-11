// AddSourceLock.swift
// `sources.locked_at` — which source is seeing a lock, rather than a flag on the brand
// that whichever source polled last happens to have written.
//
// `brands.locked_for_drop` was being set from inside the per-source poll:
//
//     if brand.lockedForDrop != result.isLocked { brand.lockedForDrop = result.isLocked }
//
// Sources are polled independently and on their own schedules, so for a brand with a
// catalog *and* a collections source, the two take turns overwriting each other — a
// genuine lock seen by one is erased minutes later by the other reporting normally. And
// because the line sits inside the `do` block, a source that locks and then starts
// failing leaves the brand locked forever, since the code that would clear it never runs.
//
// The state belongs in the row of the thing that observed it, exactly as `baselined_at`,
// `fired_at` and `notified_at` do. The brand's flag becomes derived: locked if any of its
// sources is currently locked, which is also the rule the app's `SyncEngine` already used.

import Fluent

struct AddSourceLock: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(SourceModel.schema)
            .field("locked_at", .datetime)
            .update()
    }

    func revert(on database: any Database) async throws {
        try await database.schema(SourceModel.schema)
            .deleteField("locked_at")
            .update()
    }
}

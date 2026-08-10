// AddPushLedger.swift
// `events.notified_at` — the record of what has already been pushed.
//
// Nullable with no backfill on purpose. Every existing event reads as "not yet
// notified", and `Notifier` refuses to send anything older than its freshness window,
// so the first pass after this lands marks the backlog as seen without firing a burst
// of notifications about drops that are long gone.

import Fluent
import SQLKit

struct AddPushLedger: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(EventModel.schema)
            .field("notified_at", .datetime)
            .update()

        guard let sql = database as? any SQLDatabase else { return }
        // The notifier's hot query: unsent events, oldest first.
        try await sql.raw(
            "CREATE INDEX IF NOT EXISTS idx_events_notified ON events (notified_at, created_at)"
        ).run()
    }

    func revert(on database: any Database) async throws {
        if let sql = database as? any SQLDatabase {
            try await sql.raw("DROP INDEX IF EXISTS idx_events_notified").run()
        }
        try await database.schema(EventModel.schema)
            .deleteField("notified_at")
            .update()
    }
}

// AddSourceBaseline.swift
// `sources.baselined_at` — proof that a source has actually stored a first batch.
//
// The baseline rule ("a brand's first poll records everything and announces nothing")
// keyed off `last_checked_at == nil`. But `last_checked_at` is stamped at the *start* of
// a poll and survives a failure, so any source whose first successful store was preceded
// by a failed poll had already spent its baseline — and the entire first batch went out
// as news.
//
// This is not hypothetical. While the `[String]`/JSONB bug was live, Kith polled
// repeatedly, stamped `last_checked_at` every time, and stored nothing. The first poll
// after the fix therefore looked like an ordinary incremental one and wrote 250 "new
// product" events for a back catalogue.

import Fluent
import SQLKit

struct AddSourceBaseline: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(SourceModel.schema)
            .field("baselined_at", .datetime)
            .update()

        // Anything already polling is past its baseline; without this backfill every
        // existing source would take a *second* silent baseline and swallow a real batch
        // of updates.
        guard let sql = database as? any SQLDatabase else { return }
        try await sql.raw(
            "UPDATE sources SET baselined_at = last_checked_at WHERE last_checked_at IS NOT NULL"
        ).run()
    }

    func revert(on database: any Database) async throws {
        try await database.schema(SourceModel.schema)
            .deleteField("baselined_at")
            .update()
    }
}

// FixPostgresArrayColumns.swift
// Converts the `[String]` columns from JSONB to native TEXT[] on Postgres.
//
// `CreateSchema` declares them `.json`, which Postgres renders as JSONB — but Fluent
// binds a Swift `[String]` as a *native* Postgres array, not as JSON. Postgres then
// rejects the insert ("column is of type jsonb but expression is of type text[]"), so
// every write touching one of these columns fails: device registration (users) and the
// poller storing products and events. Tables with no array column — brands, sources —
// wrote fine, which is why the deploy looked healthy.
//
// SQLite has no array type, so Fluent JSON-encodes there and the original declaration
// is already correct; this migration is a no-op off Postgres.
//
// `CreateSchema` is deliberately left as it was. It has already been applied in
// production, so editing it would change nothing there while letting the two diverge —
// on a fresh database this runs straight after it and lands in the same place.

import Fluent
import SQLKit

struct FixPostgresArrayColumns: AsyncMigration {
    /// `table.column` pairs holding a `[String]`.
    private static let columns = [
        ("products", "image_urls"),
        ("products", "tags"),
        ("events", "sizes"),
        ("users", "apparel_sizes"),
        ("users", "shoe_sizes"),
    ]

    func prepare(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase, sql.dialect.name == "postgresql" else { return }
        for (table, column) in Self.columns {
            // The USING clause converts any rows already stored as JSON rather than
            // failing on them; an empty array covers a NULL or a non-array value.
            try await sql.raw("""
                ALTER TABLE \(unsafeRaw: table) ALTER COLUMN \(unsafeRaw: column) \
                TYPE TEXT[] USING COALESCE( \
                    (SELECT array_agg(value) FROM jsonb_array_elements_text(\(unsafeRaw: column)) AS value), \
                    '{}'::TEXT[] \
                )
                """).run()
        }
    }

    func revert(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase, sql.dialect.name == "postgresql" else { return }
        for (table, column) in Self.columns {
            try await sql.raw("""
                ALTER TABLE \(unsafeRaw: table) ALTER COLUMN \(unsafeRaw: column) \
                TYPE JSONB USING to_jsonb(\(unsafeRaw: column))
                """).run()
        }
    }
}

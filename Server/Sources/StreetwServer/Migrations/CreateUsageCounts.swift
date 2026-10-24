// CreateUsageCounts.swift
// `usage_counts` — one total per day per counted thing, shared by everybody.
//
// The unique constraint is not a guard here, it is the mechanism: `UsageLedger.add` is an
// `INSERT … ON CONFLICT (day, event) DO UPDATE`, which needs exactly this constraint to have
// something to conflict on, and is what lets two reports arriving at once add to the same
// row rather than racing to create it.
//
// No foreign keys, on purpose. Nothing in this table refers to a user, a device or a brand.

import Fluent

struct CreateUsageCounts: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(UsageCountModel.schema)
            .id()
            .field("day", .string, .required)
            .field("event", .string, .required)
            .field("total", .int, .required)
            .unique(on: "day", "event")
            .create()
    }

    func revert(on database: any Database) async throws {
        try await database.schema(UsageCountModel.schema).delete()
    }
}

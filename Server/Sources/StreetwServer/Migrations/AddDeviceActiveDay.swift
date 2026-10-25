// AddDeviceActiveDay.swift
// `devices.active_on` — the UTC day a device last reported its usage counts.
//
// Nullable with no backfill: every existing device, and every install of 1.0, which never
// reports, reads as "not seen reporting", which is true. A string day rather than a
// timestamp, because a day is the finest thing the question needs and anything finer would
// be a record of when somebody opened the app.

import Fluent

struct AddDeviceActiveDay: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(DeviceModel.schema)
            .field("active_on", .string)
            .update()
    }

    func revert(on database: any Database) async throws {
        try await database.schema(DeviceModel.schema)
            .deleteField("active_on")
            .update()
    }
}

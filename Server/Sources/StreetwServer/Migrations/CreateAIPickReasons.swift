// CreateAIPickReasons.swift
// `ai_pick_reasons` — a daily pick's sentence, cached by what it was written from.
//
// The key is `sha256(productExternalID|anchor|basis)`: the pick, the short description of the
// wardrobe partner and the rule that chose it. **No user and no device column**, on purpose —
// a hundred people with a black chore jacket are one row and one model call, and the row says
// nothing about any of them. Pruned after thirty days (`Reaper`), which also lets a better
// model reword what it once wrote.

import Fluent

struct CreateAIPickReasons: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(AIPickReasonModel.schema)
            .id()
            .field("key", .string, .required)
            .field("reason", .string, .required)
            .field("model", .string, .required)
            .field("created_at", .datetime, .required)
            .unique(on: "key")
            .create()
    }

    func revert(on database: any Database) async throws {
        try await database.schema(AIPickReasonModel.schema).delete()
    }
}

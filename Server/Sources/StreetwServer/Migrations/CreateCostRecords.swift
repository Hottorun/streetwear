// CreateCostRecords.swift
// `ai_costs` — what every AI action really cost, and nothing about what it was asked.
//
// One row per provider call: the action, the model, the tokens each way and the cost in
// millionths of a dollar. No prompt, no reply, no photograph, no product — the roadmap's
// prices are set from these rows, and that needs only numbers.
//
// Every count is a `BIGINT`. `cost_micros` because a month of one account passes 2^31 at
// $2,147 (see `CreateAccounts`) and a sum over everybody far sooner; the token counts because
// a long context is six figures of tokens a call, and they are summed too.
//
// **`ON DELETE SET NULL`, not cascade**, on both keys. Deleting an account must take the
// person out of the table, and it does — the row stops naming anybody. Cascading would also
// take the measurement with it, and with it the evidence a price was set from. A row with
// neither key is also how work done for everybody (a cached reason on a daily pick) is
// recorded.
//
// Two indexes, for the two readers: the operator's summary is a range over time across
// everybody, and the monthly cap is one account's range.

import Fluent
import SQLKit

struct CreateCostRecords: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(CostRecordModel.schema)
            .id()
            .field("account_id", .uuid, .references(AccountModel.schema, "id", onDelete: .setNull))
            .field("user_id", .uuid, .references(UserModel.schema, "id", onDelete: .setNull))
            .field("action", .string, .required)
            .field("model", .string, .required)
            .field("input_tokens", .int64, .required)
            .field("output_tokens", .int64, .required)
            .field("cost_micros", .int64, .required)
            .field("created_at", .datetime, .required)
            .create()

        guard let sql = database as? any SQLDatabase else { return }
        try await sql.raw("CREATE INDEX IF NOT EXISTS ai_costs_time ON ai_costs (created_at)").run()
        try await sql.raw(
            "CREATE INDEX IF NOT EXISTS ai_costs_account_time ON ai_costs (account_id, created_at)"
        ).run()
    }

    func revert(on database: any Database) async throws {
        if let sql = database as? any SQLDatabase {
            try await sql.raw("DROP INDEX IF EXISTS ai_costs_account_time").run()
            try await sql.raw("DROP INDEX IF EXISTS ai_costs_time").run()
        }
        try await database.schema(CostRecordModel.schema).delete()
    }
}

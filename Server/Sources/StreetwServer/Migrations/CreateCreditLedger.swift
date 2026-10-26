// CreateCreditLedger.swift
// `credit_ledger` — every change to an account's credits, and the balance is their sum.
//
// **The two unique constraints are the mechanism, not a guard.**
//
// - `(apple_transaction_id, reason)`: a purchase can be credited once and refunded once,
//   whoever posts it and however often. A replayed receipt, a retry after a lost reply, and
//   `Transaction.updates` re-delivering an old transaction all land on the same row.
// - `(account_id, allowance_month)`: one free allowance per account per month.
//
// Both columns are NULL on every row they do not apply to, and NULLs never collide in a
// unique constraint on Postgres or SQLite — so spends and grants are unconstrained by them.
//
// `delta` is a `BIGINT` like every other number in this money path. No credit amount comes
// near 2^31, and choosing the narrow type to save four bytes a row is how one does one day.
//
// The index is the ledger's one query shape: one account's rows, by time — the balance is a
// sum over the first column, and this month's usage a range over the second.
//
// `ON DELETE CASCADE` from the account: a balance is meaningless without somebody to spend
// it. Deleting an account forfeits its credits, which the deletion screen has to say.

import Fluent
import SQLKit

struct CreateCreditLedger: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(CreditEntryModel.schema)
            .id()
            .field("account_id", .uuid, .required, .references(AccountModel.schema, "id", onDelete: .cascade))
            .field("delta", .int64, .required)
            .field("reason", .string, .required)
            .field("action", .string)
            .field("apple_transaction_id", .string)
            .field("product_id", .string)
            .field("store_environment", .string)
            .field("allowance_month", .string)
            .field("created_at", .datetime, .required)
            .unique(on: "apple_transaction_id", "reason")
            .unique(on: "account_id", "allowance_month")
            .create()

        guard let sql = database as? any SQLDatabase else { return }
        try await sql.raw(
            "CREATE INDEX IF NOT EXISTS credit_ledger_account_time ON credit_ledger (account_id, created_at)"
        ).run()
    }

    func revert(on database: any Database) async throws {
        if let sql = database as? any SQLDatabase {
            try await sql.raw("DROP INDEX IF EXISTS credit_ledger_account_time").run()
        }
        try await database.schema(CreditEntryModel.schema).delete()
    }
}

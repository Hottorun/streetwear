// CostMeter.swift
// What every AI action really cost — the measurement the prices are set from.
//
// The roadmap's rule is that prices come from measured costs, not guesses: AI launches on a
// generous allowance while this records the real cost of every provider call, and after a
// few weeks `GET /admin/costs` says what an action costs at the median and at the tail. A
// credit price set from the mean alone undercharges the tail, which is where a long thread
// or a big photograph lives.
//
// Only numbers are kept: the action, the model, tokens each way, cost in millionths of a
// dollar. See `CreateCostRecords`.

import Fluent
import Foundation
import SQLKit
import StreetwCore
import Vapor

/// One provider call's bill, as the provider layer reports it.
struct MeteredCost: Sendable, Equatable {
    var action: CreditAction
    /// The provider's model id, as billed.
    var model: String
    var inputTokens: Int
    var outputTokens: Int
    /// Millionths of a dollar, worked out by the provider layer from its own price table.
    var costMicros: Int64
}

enum CostMeter {
    /// Records one call. **Always** — on an unlimited account, on a refused-later action,
    /// and on a call whose result was thrown away: what it cost is a fact about the provider
    /// bill, not about whether anybody was charged for it.
    ///
    /// - Parameters:
    ///   - account: the account, when the user has one.
    ///   - user: the user, so an anonymous user's call is still somebody's — and a profile's
    ///     calls can be told apart once an account has several. Nil for both is work done for
    ///     everybody.
    static func record(
        _ cost: MeteredCost,
        account: UUID?,
        user: UUID?,
        at date: Date = Date(),
        on db: any Database
    ) async throws {
        // A negative number is a bug in the provider layer's arithmetic, and summed into the
        // measurement it would hide a real cost behind it.
        guard cost.inputTokens >= 0, cost.outputTokens >= 0, cost.costMicros >= 0 else {
            throw Abort(.internalServerError, reason: "A metered cost cannot be negative")
        }
        let row = CostRecordModel()
        row.$account.id = account
        row.$user.id = user
        row.action = cost.action.rawValue
        row.model = cost.model
        row.inputTokens = cost.inputTokens
        row.outputTokens = cost.outputTokens
        row.costMicros = cost.costMicros
        row.createdAt = date
        try await row.save(on: db)
    }

    /// The same, keyed off the user the request came from.
    static func record(_ cost: MeteredCost, for user: UserModel, at date: Date = Date(), on db: any Database) async throws {
        try await record(cost, account: user.$account.id, user: user.id, at: date, on: db)
    }

    /// This UTC month's metered cost for one account, which the monthly cap is checked against.
    static func monthCost(account accountID: UUID, now: Date, on db: any Database) async throws -> Int64 {
        guard let sql = db as? any SQLDatabase else { return 0 }
        let row = try await sql.raw("""
            SELECT CAST(COALESCE(SUM(cost_micros), 0) AS BIGINT) AS total FROM ai_costs \
            WHERE account_id = \(bind: accountID) AND created_at >= \(bind: CreditMonth.start(of: now))
            """).first()
        return try row?.decode(column: "total", as: Int64.self) ?? 0
    }

    /// `GET /admin/costs` — per action, how many calls and what they cost.
    ///
    /// The percentiles are worked out here rather than in SQL: SQLite has no
    /// `percentile_cont`, and at measurement scale — weeks of a small app — the window is
    /// thousands of rows of four numbers each. When it is not, this becomes `percentile_cont`
    /// on Postgres; the shape of the answer does not change.
    static func summary(since: Date, now: Date = Date(), on db: any Database) async throws -> CostSummary {
        let rows = try await CostRecordModel.query(on: db)
            .filter(\.$createdAt >= since)
            .all()

        let byAction = Dictionary(grouping: rows, by: \.action)
        let actions = byAction.map { action, rows -> CostSummary.Action in
            let costs = rows.map(\.costMicros).sorted()
            let total = costs.reduce(0, +)
            return CostSummary.Action(
                action: action,
                count: rows.count,
                totalMicros: total,
                meanMicros: total / Int64(rows.count),
                p50Micros: percentile(0.5, of: costs),
                p90Micros: percentile(0.9, of: costs),
                maxMicros: costs.last ?? 0,
                inputTokens: rows.reduce(0) { $0 + $1.inputTokens },
                outputTokens: rows.reduce(0) { $0 + $1.outputTokens },
                models: Dictionary(grouping: rows, by: \.model).mapValues(\.count)
            )
        }

        return CostSummary(
            since: since,
            until: now,
            totalMicros: rows.reduce(0) { $0 + $1.costMicros },
            actions: actions.sorted { $0.totalMicros > $1.totalMicros }
        )
    }

    /// Nearest-rank: the smallest value at least `p` of the sample is at or below. Always one
    /// of the measured costs, never an interpolation between two — a price is set against a
    /// call that happened.
    static func percentile(_ p: Double, of sorted: [Int64]) -> Int64 {
        guard !sorted.isEmpty else { return 0 }
        let rank = Int((p * Double(sorted.count)).rounded(.up))
        return sorted[min(max(rank, 1), sorted.count) - 1]
    }
}

/// `GET /admin/costs`. Server-only like `UsageSummary`: no client decodes it.
struct CostSummary: Content {
    struct Action: Content {
        var action: String
        var count: Int
        var totalMicros: Int64
        var meanMicros: Int64
        var p50Micros: Int64
        var p90Micros: Int64
        var maxMicros: Int64
        var inputTokens: Int
        var outputTokens: Int
        /// Model id → calls, so a price is not set from a mix of two models without knowing.
        var models: [String: Int]
    }

    var since: Date
    var until: Date
    var totalMicros: Int64
    /// Most expensive first.
    var actions: [Action]
}

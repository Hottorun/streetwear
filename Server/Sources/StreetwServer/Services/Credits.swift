// Credits.swift
// The credit ledger: what an account holds, spending it, and the free monthly allowance.
//
// **The ledger is the truth and the balance is its sum.** There is no stored balance to
// drift from the rows that explain it, so a balance can always be accounted for line by
// line — which is what anybody asking "where did my credits go" is owed. The cost of a sum
// per spend is one indexed range over one account's rows (`credit_ledger_account_time`),
// tens a month; the day that is measurably slow, a maintained column goes *beside* the
// ledger, written in the same transaction, and the ledger stays what it is checked against.
//
// **A spend is serialised per account by a row lock**, on Postgres: `SELECT … FOR UPDATE`
// on the account row, then the sum, the decision and the insert in the same transaction.
// Two concurrent spends of the last five credits otherwise both read five and both insert
// minus five. Under READ COMMITTED the second waits on the lock and its sum, a new statement,
// sees the first's committed row. SQLite has no `FOR UPDATE` and cannot show the race at
// all — see `CreditRaceTests`, which runs against a real Postgres when one is given.
//
// See `docs/credits.md`.

import Fluent
import Foundation
import SQLKit
import StreetwCore
import Vapor

/// The numbers somebody will one day set from measurement. Every one is a placeholder.
enum CreditPolicy {
    /// Credits a signed-in account gets each month it uses any, free. **A placeholder until
    /// the cost meter has a few weeks of real actions** — the roadmap's "generous allowance
    /// while the server records what every action really cost".
    static let monthlyAllowance = 50

    /// Credits per action. Fixed per action, never the measured cost of the call — an exact
    /// cost is a different price every time (`ROADMAP.md`, *Decided*). **Placeholders**, like
    /// the allowance: the scan is two because the roadmap says two; the rest are one until
    /// `GET /admin/costs` says otherwise.
    static func credits(for action: CreditAction) -> Int {
        switch action {
        case .scan: return 2
        default: return 1
        }
    }
}

/// The packs on sale, and what each adds. **The only table of them** — the App Store
/// products are created to match it, and a product it does not list is refused rather than
/// credited, so a pack added in App Store Connect and forgotten here cannot mint anything.
///
/// The ids end in the credit count by convention only; the count is read from here, never
/// parsed out of the id.
enum CreditPacks {
    static let all: [CreditPackDTO] = [
        CreditPackDTO(productID: "com.kern.functional.streetw.credits.50", credits: 50),
        CreditPackDTO(productID: "com.kern.functional.streetw.credits.150", credits: 150),
        CreditPackDTO(productID: "com.kern.functional.streetw.credits.500", credits: 500)
    ]

    static func pack(for productID: String) -> CreditPackDTO? {
        all.first { $0.productID == productID }
    }
}

/// Why a spend was refused, said the way the phone will print it.
enum CreditRefusal: AbortError, Equatable {
    /// The device's user has no account. Credits live under an account because StoreKit
    /// cannot restore a consumable (`CreateAccounts`), so an anonymous balance would be lost
    /// with the app.
    case signInRequired
    case insufficient(balance: Int, needed: Int)
    /// This month's metered cost has reached the account's `monthly_cost_cap_micros`. A guard
    /// against a looping bug spending real money, not a price.
    case monthlyCostCap

    var status: HTTPResponseStatus {
        switch self {
        case .signInRequired: .forbidden
        case .insufficient: .paymentRequired
        case .monthlyCostCap: .tooManyRequests
        }
    }

    var reason: String {
        switch self {
        case .signInRequired:
            "Sign in to use credits"
        case .insufficient(let balance, let needed):
            "Not enough credits: this needs \(needed) and the balance is \(balance)"
        case .monthlyCostCap:
            "This account has reached its monthly limit"
        }
    }
}

/// A spend that went through, so the action that paid for it can give it back if it fails.
struct CreditCharge: Sendable, Equatable {
    var entryID: UUID
    var accountID: UUID
    var action: CreditAction
    /// What was taken: zero on an unlimited account.
    var credits: Int
}

enum CreditLedger {
    enum Decision: Equatable {
        /// Take this many — zero for an unlimited account, which is still a row.
        case charge(Int)
        case refuse(CreditRefusal)
    }

    /// The whole rule, apart from the database. In order: the cost cap first, because it
    /// guards real money and applies to an unlimited account too — that is the account it
    /// exists for; then unlimited, which never refuses; then the balance.
    ///
    /// `balance >= credits` with `credits >= 1` is also the rule for a balance a refund took
    /// negative: nothing can be spent until it is positive again.
    static func decide(
        credits: Int,
        balance: Int,
        unlimited: Bool,
        monthCostMicros: Int64,
        capMicros: Int64?
    ) -> Decision {
        if let capMicros, monthCostMicros >= capMicros { return .refuse(.monthlyCostCap) }
        if unlimited { return .charge(0) }
        guard balance >= credits else { return .refuse(.insufficient(balance: balance, needed: credits)) }
        return .charge(credits)
    }

    /// The account a user's credits live under — or the refusal that says to sign in.
    static func accountID(of user: UserModel) throws -> UUID {
        guard let id = user.$account.id else { throw CreditRefusal.signInRequired }
        return id
    }

    /// Takes `credits` for `action`, or refuses. **The one way credits are spent.**
    ///
    /// Call it *before* the provider call, and `undo` the charge if the action then fails —
    /// see `docs/credits.md` for the whole sequence Phase 4 follows.
    static func spend(
        credits: Int,
        for action: CreditAction,
        account accountID: UUID,
        now: Date = Date(),
        on db: any Database
    ) async throws -> CreditCharge {
        guard credits >= 1 else { throw Abort(.internalServerError, reason: "A spend must be at least one credit") }
        return try await db.transaction { tx in
            try await lock(accountID, on: tx)
            guard let account = try await AccountModel.find(accountID, on: tx) else {
                throw CreditRefusal.signInRequired
            }
            if !account.unlimitedCredits {
                try await grantAllowanceIfDue(accountID, now: now, on: tx)
            }
            let decision = decide(
                credits: credits,
                balance: try await balance(of: accountID, on: tx),
                unlimited: account.unlimitedCredits,
                monthCostMicros: try await CostMeter.monthCost(account: accountID, now: now, on: tx),
                capMicros: account.monthlyCostCapMicros
            )
            switch decision {
            case .refuse(let refusal):
                throw refusal
            case .charge(let taken):
                let entry = CreditEntryModel(accountID: accountID, delta: -taken, reason: .spend, at: now)
                entry.action = action.rawValue
                try await entry.save(on: tx)
                return CreditCharge(entryID: try entry.requireID(), accountID: accountID, action: action, credits: taken)
            }
        }
    }

    /// Gives a spend back, because the action it paid for never produced anything. A row of
    /// its own rather than deleting the spend, so the ledger still says what happened — and
    /// usage counts a spend and its reversal as nothing.
    static func undo(_ charge: CreditCharge, now: Date = Date(), on db: any Database) async throws {
        let entry = CreditEntryModel(accountID: charge.accountID, delta: charge.credits, reason: .reversal, at: now)
        entry.action = charge.action.rawValue
        try await entry.save(on: db)
    }

    /// The operator's grant. Negative takes credits away, for credits minted by mistake.
    static func grant(credits: Int, account accountID: UUID, now: Date = Date(), on db: any Database) async throws {
        try await db.transaction { tx in
            try await lock(accountID, on: tx)
            try await CreditEntryModel(accountID: accountID, delta: credits, reason: .grant, at: now).save(on: tx)
        }
    }

    // MARK: Reading

    /// The sum of the ledger. Nothing pending is included — see `summary` for that.
    static func balance(of accountID: UUID, on db: any Database) async throws -> Int {
        guard let sql = db as? any SQLDatabase else { return 0 }
        // `CAST` because Postgres sums a `BIGINT` into a `NUMERIC`, which does not decode as
        // an `Int`; SQLite accepts the same cast and changes nothing.
        let row = try await sql.raw("""
            SELECT CAST(COALESCE(SUM(delta), 0) AS BIGINT) AS total FROM credit_ledger \
            WHERE account_id = \(bind: accountID)
            """).first()
        return try row?.decode(column: "total", as: Int.self) ?? 0
    }

    /// Whether this month's allowance is still to be granted.
    static func allowanceDue(_ accountID: UUID, now: Date, on db: any Database) async throws -> Bool {
        try await CreditEntryModel.query(on: db)
            .filter(\.$account.$id == accountID)
            .filter(\.$allowanceMonth == CreditMonth.key(of: now))
            .first() == nil
    }

    /// **Lazily, on the first spend of a month**, rather than by a job on the first: an
    /// account that does not use credits in a month is granted nothing for it, so there is no
    /// sweep over every account and nothing accrues for somebody who has left. Granted
    /// credits never expire, like bought ones — nothing is taken back at the month's end.
    ///
    /// Only ever called under `lock`, so the check-then-insert cannot race; the unique
    /// `(account_id, allowance_month)` is the backstop for a writer that forgets.
    static func grantAllowanceIfDue(_ accountID: UUID, now: Date, on db: any Database) async throws {
        guard try await allowanceDue(accountID, now: now, on: db) else { return }
        let entry = CreditEntryModel(accountID: accountID, delta: CreditPolicy.monthlyAllowance, reason: .allowance, at: now)
        entry.allowanceMonth = CreditMonth.key(of: now)
        try await entry.save(on: db)
    }

    /// What `GET /v1/credits` answers. **Writes nothing**: this month's allowance is counted
    /// into the balance when it is still due, rather than granted by reading — so opening
    /// the You page every month and never using anything accrues nothing.
    static func summary(for user: UserModel, now: Date = Date(), on db: any Database) async throws -> CreditsSummary {
        guard let accountID = user.$account.id,
              let account = try await AccountModel.find(accountID, on: db)
        else { return CreditsSummary(signedIn: false) }

        var balance = try await balance(of: accountID, on: db)
        if !account.unlimitedCredits, try await allowanceDue(accountID, now: now, on: db) {
            balance += CreditPolicy.monthlyAllowance
        }

        return CreditsSummary(
            signedIn: true,
            balance: balance,
            unlimited: account.unlimitedCredits,
            monthlyAllowance: CreditPolicy.monthlyAllowance,
            month: CreditMonth.key(of: now),
            thisMonth: try await usage(of: accountID, now: now, on: db),
            // An unlimited account is sold nothing.
            packs: account.unlimitedCredits ? [] : CreditPacks.all,
            accountToken: accountID
        )
    }

    /// This month's actions, per action: spends less their reversals. From the ledger rather
    /// than the cost meter, because one action may be several provider calls and the line
    /// says "23 searches", not "41 model calls".
    static func usage(of accountID: UUID, now: Date, on db: any Database) async throws -> [CreditUsage] {
        let rows = try await CreditEntryModel.query(on: db)
            .filter(\.$account.$id == accountID)
            .filter(\.$createdAt >= CreditMonth.start(of: now))
            .filter(\.$reason ~~ [CreditReason.spend.rawValue, CreditReason.reversal.rawValue])
            .all()
        var counts: [String: Int] = [:]
        for row in rows {
            guard let action = row.action else { continue }
            counts[action, default: 0] += row.reason == CreditReason.spend.rawValue ? 1 : -1
        }
        return counts
            .filter { $0.value > 0 }
            .map { CreditUsage(action: $0.key, count: $0.value) }
            .sorted { ($0.count, $1.action) > ($1.count, $0.action) }
    }

    // MARK: Locking

    /// Holds the account row until the transaction ends. Postgres only; SQLite takes no row
    /// locks, which is why the race tests need a real Postgres.
    static func lock(_ accountID: UUID, on db: any Database) async throws {
        guard let sql = db as? any SQLDatabase, sql.dialect.name == "postgresql" else { return }
        try await sql.raw("SELECT id FROM accounts WHERE id = \(bind: accountID) FOR UPDATE").run()
    }
}

// AIAction.swift
// The one shape every paid action takes — spend, call, record, undo — and the signed token
// that holds a search thread on the phone.
//
// See `docs/ai.md` and `docs/credits.md` (*What Phase 4 calls*).

import Crypto
import Fluent
import Foundation
import StreetwCore
import Vapor

/// Collects what every provider call in one action cost, so the action records all of them
/// whether it succeeds or fails.
struct AIMeter: Sendable {
    private(set) var costs: [MeteredCost] = []

    /// The answer's value, with its costs kept.
    mutating func take<T>(_ answer: AIAnswer<T>) -> T {
        costs += answer.costs
        return answer.value
    }

    mutating func add(_ more: [MeteredCost]) {
        costs += more
    }
}

enum AIAction {
    /// Spends, calls, records and — when the action produced nothing — undoes.
    ///
    /// 1. **The spend comes first** (`CreditLedger.spend`), because it is the only place a
    ///    refusal can happen: 403 signed out, 402 not enough, 429 the monthly cost cap. A
    ///    provider bill already run up cannot be refused. With `charge: false` — a follow-up
    ///    inside a paid thread — nothing is spent, but the account and its cap still apply.
    /// 2. **The work runs outside the spend's transaction**, which would otherwise hold the
    ///    account's row lock for a network call.
    /// 3. **Every provider call is recorded**, on success and on failure, including the ones
    ///    whose answer is thrown away.
    /// 4. **A failure gives the credits back** (`CreditLedger.undo`) and is said as a status
    ///    the phone can print, never with the model's words in it.
    ///
    /// `work` throws `AIFailure` for a provider failure; anything else it throws — a database
    /// error in the search that follows the model call — undoes the spend the same way.
    static func run<T: Sendable>(
        _ action: CreditAction,
        credits: Int? = nil,
        charge: Bool = true,
        for user: UserModel,
        on db: any Database,
        logger: Logger,
        now: Date = Date(),
        producedNothing: ((T) -> Bool)? = nil,
        _ work: (inout AIMeter) async throws -> T
    ) async throws -> (value: T, charge: AICharge) {
        let accountID = try CreditLedger.accountID(of: user)
        var spent: CreditCharge?
        if charge {
            spent = try await CreditLedger.spend(
                credits: credits ?? CreditPolicy.credits(for: action), for: action, account: accountID, now: now, on: db
            )
        } else {
            try await checkCap(accountID, now: now, on: db)
        }

        var meter = AIMeter()
        let value: T
        do {
            value = try await work(&meter)
        } catch {
            if let failure = error as? AIFailure { meter.add(failure.costs) }
            await record(meter.costs, for: user, on: db, logger: logger)
            if let spent { try? await CreditLedger.undo(spent, on: db) }
            logger.warning("ai: \(action.rawValue) failed: \(String(describing: error))")
            throw abort(for: error)
        }
        await record(meter.costs, for: user, on: db, logger: logger)

        // An answer with nothing in it for the reader — no page found on the web, a
        // photograph with no garment — is returned as it is, and not paid for.
        if let spent, producedNothing?(value) == true {
            try await CreditLedger.undo(spent, on: db)
            let account = try await AccountModel.find(accountID, on: db)
            let unlimited = account?.unlimitedCredits ?? false
            return (value, AICharge(credits: 0, balance: unlimited ? nil : try await CreditLedger.balance(of: accountID, on: db)))
        }

        let account = try await AccountModel.find(accountID, on: db)
        let unlimited = account?.unlimitedCredits ?? false
        return (value, AICharge(
            credits: spent?.credits ?? 0,
            balance: unlimited ? nil : try await CreditLedger.balance(of: accountID, on: db)
        ))
    }

    /// A free turn still answers to the account's monthly cost cap: it is a provider call
    /// like any other, and the cap is a guard against a looping bug spending real money.
    static func checkCap(_ accountID: UUID, now: Date, on db: any Database) async throws {
        guard let account = try await AccountModel.find(accountID, on: db) else { throw CreditRefusal.signInRequired }
        if let cap = account.monthlyCostCapMicros,
           try await CostMeter.monthCost(account: accountID, now: now, on: db) >= cap {
            throw CreditRefusal.monthlyCostCap
        }
    }

    /// A failed record is logged and not thrown: the reader's answer is already paid for.
    private static func record(_ costs: [MeteredCost], for user: UserModel, on db: any Database, logger: Logger) async {
        for cost in costs {
            do {
                try await CostMeter.record(cost, for: user, on: db)
            } catch {
                logger.error("ai: could not meter a \(cost.action.rawValue) call: \(error)")
            }
        }
    }

    /// What the phone is told. A refusal it can act on passes through; a provider failure is
    /// one of three sentences, none of which repeats anything the model said.
    static func abort(for error: any Error) -> any Error {
        if error is CreditRefusal || error is Abort { return error }
        guard let failure = error as? AIFailure else {
            return Abort(.internalServerError, reason: "That didn't work. Your credits were not used.")
        }
        switch failure.error {
        case .unavailable:
            return Abort(.serviceUnavailable, reason: "The assistant is busy. Try again in a moment — your credits were not used.")
        case .declined:
            return Abort(.unprocessableEntity, reason: "The assistant couldn't answer that. Your credits were not used.")
        case .refused, .malformed:
            return Abort(.badGateway, reason: "The assistant answered in a way we couldn't read. Your credits were not used.")
        }
    }
}

// MARK: - Search threads

/// A search thread, held by the phone and signed by the server.
///
/// **Nothing anybody typed is stored here or anywhere.** The phone sends the earlier turns back
/// with each new one; the token only says that a thread was paid for, by whom, when, and how
/// many turns it has had — so a follow-up inside it is not charged again, and nothing else is.
///
/// `base64url(payload).base64url(HMAC-SHA256(payload))`, keyed by `AI_THREAD_SECRET` (a key made
/// at boot when unset). Thirty minutes from the first turn, six turns.
struct AIThreadToken: Codable, Sendable, Equatable {
    static let lifetime: TimeInterval = 30 * 60
    static let maxTurns = 6

    /// The account that paid.
    var account: UUID
    /// The profile it was paid for: another profile on the same account starts its own thread.
    var profile: UUID
    /// When the paid turn was taken. The lifetime runs from here, not from the latest turn.
    var issuedAt: Date
    /// Turns taken so far, the paid one included.
    var turns: Int

    var turnsLeft: Int { max(Self.maxTurns - turns, 0) }

    private enum CodingKeys: String, CodingKey {
        case account = "a", profile = "p", issuedAt = "i", turns = "t"
    }

    func signed(with key: SymmetricKey) throws -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        let payload = try encoder.encode(self)
        let mac = HMAC<SHA256>.authenticationCode(for: payload, using: key)
        return payload.base64URLEncodedString() + "." + Data(mac).base64URLEncodedString()
    }

    enum Rejection: Error, Equatable {
        case malformed, forged, expired, spent, otherAccount, otherProfile
    }

    /// The thread this token continues, or why it does not. Any rejection means the turn
    /// starts — and pays for — a new thread; none of them is an error to the phone.
    static func verify(
        _ token: String,
        key: SymmetricKey,
        account: UUID,
        profile: UUID,
        now: Date = Date()
    ) -> Result<AIThreadToken, Rejection> {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 2,
              let payload = Data(base64URL: String(parts[0])),
              let mac = Data(base64URL: String(parts[1]))
        else { return .failure(.malformed) }
        guard HMAC<SHA256>.isValidAuthenticationCode(mac, authenticating: payload, using: key) else {
            return .failure(.forged)
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        guard let thread = try? decoder.decode(AIThreadToken.self, from: payload) else { return .failure(.malformed) }
        guard thread.account == account else { return .failure(.otherAccount) }
        guard thread.profile == profile else { return .failure(.otherProfile) }
        guard now.timeIntervalSince(thread.issuedAt) < lifetime, thread.issuedAt <= now.addingTimeInterval(60) else {
            return .failure(.expired)
        }
        guard thread.turns < maxTurns else { return .failure(.spent) }
        return .success(thread)
    }
}

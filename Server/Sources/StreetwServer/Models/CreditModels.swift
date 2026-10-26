// CreditModels.swift
// The credit ledger and the cost meter's rows. Their own file rather than the tail of
// `Models.swift`, because the account routes are being written beside them and both would
// otherwise be appending to the same lines. See `docs/credits.md`.

import Fluent
import Foundation

/// One change to an account's credits. **The ledger is the balance**: there is no stored
/// total to drift from it, and the balance is the sum of `delta` — see `CreditLedger`.
///
/// Personal, under the account, and cascaded away with it: a balance means nothing without
/// somebody to spend it.
final class CreditEntryModel: Model, @unchecked Sendable {
    static let schema = "credit_ledger"

    @ID(key: .id) var id: UUID?
    @Parent(key: "account_id") var account: AccountModel
    /// Signed. A purchase, a grant and the allowance add; a spend and a refund take away. An
    /// unlimited account's spend is a row of zero, so its usage is counted like anybody's.
    @Field(key: "delta") var delta: Int
    /// A `CreditReason` raw value.
    @Field(key: "reason") var reason: String
    /// The `CreditAction` a spend (or its reversal) was for.
    @OptionalField(key: "action") var action: String?
    /// For a purchase and anything that follows from one — its refund, a reversed refund.
    /// Unique together with `reason`, which is the whole defence against a replayed receipt.
    @OptionalField(key: "apple_transaction_id") var appleTransactionID: String?
    @OptionalField(key: "product_id") var productID: String?
    /// The App Store environment the transaction came from — `Production`, `Sandbox`,
    /// `Xcode` — so credits minted by a test purchase can be found and taken back.
    @OptionalField(key: "store_environment") var storeEnvironment: String?
    /// The `CreditMonth` an allowance row grants. Unique together with the account, so a
    /// month can only ever be granted once.
    @OptionalField(key: "allowance_month") var allowanceMonth: String?
    /// Set by the writer rather than by `@Timestamp`, which would always say "now": which
    /// month a row falls in decides the allowance and the usage line, and that has to be
    /// testable on either side of a month's end.
    @Field(key: "created_at") var createdAt: Date

    init() {}

    init(accountID: UUID, delta: Int, reason: CreditReason, at date: Date) {
        self.$account.id = accountID
        self.delta = delta
        self.reason = reason.rawValue
        self.createdAt = date
    }
}

/// Why a ledger row exists.
enum CreditReason: String, Codable, CaseIterable {
    case purchase
    /// The free monthly allowance, granted lazily on the first spend of a month.
    case allowance
    case spend
    /// The operator's own grant (`POST /admin/accounts/:id/grants`).
    case grant
    /// Apple refunded or revoked a purchase.
    case refund
    /// Apple reversed a refund it had made.
    case refundReversed = "refund_reversed"
    /// A spend given back because the action it paid for failed (`CreditLedger.undo`).
    case reversal
}

/// What one AI action really cost. **Numbers only**: no prompt, no reply, no photograph and
/// no product — nothing that says what anybody asked for, only how much answering it cost.
///
/// Keyed to the account when there is one and to the user when there is not, and to neither
/// for work done for everybody (a cached daily-pick reason). Both keys are `ON DELETE SET
/// NULL`, not cascade: deleting an account must take the person out of these rows, and
/// leaving the numbers is what keeps the measurement the prices are set from.
final class CostRecordModel: Model, @unchecked Sendable {
    static let schema = "ai_costs"

    @ID(key: .id) var id: UUID?
    @OptionalParent(key: "account_id") var account: AccountModel?
    @OptionalParent(key: "user_id") var user: UserModel?
    /// A `CreditAction` raw value.
    @Field(key: "action") var action: String
    /// The provider's model id, as billed.
    @Field(key: "model") var model: String
    @Field(key: "input_tokens") var inputTokens: Int
    @Field(key: "output_tokens") var outputTokens: Int
    /// Millionths of a dollar. `BIGINT`, for the reason `monthly_cost_cap_micros` is.
    @Field(key: "cost_micros") var costMicros: Int64
    /// Set by the writer, as on the ledger — the monthly cap reads it.
    @Field(key: "created_at") var createdAt: Date

    init() {}
}

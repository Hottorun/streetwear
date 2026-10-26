// AppStore.swift
// Believing a StoreKit purchase, and hearing about its refund.
//
// **Nothing the phone says about a purchase is believed.** It hands over the transaction
// exactly as StoreKit 2 signed it — a JWS whose header carries an `x5c` certificate chain —
// and the credit depends on that signature, not on the request. Four things are checked,
// and only the first is crypto:
//
// 1. The signature, against a chain that ends at Apple Root CA G3 (`SignedTransactionVerifying`).
// 2. The bundle id is this app's, or any app's purchase could be replayed here.
// 3. The environment: a sandbox or Xcode transaction costs nobody anything, so it is only
//    believed where that cannot mint credits that matter (`PurchasePolicy`).
// 4. The product is a pack in `CreditPacks`, which says how many credits it is.
//
// The signature is `AppStoreVerifier` (`AppStoreSignature.swift`); everything after it is
// here, and is tested through a double that believes any well-formed JWS. See
// `docs/credits.md`.

import Fluent
import Foundation
import StreetwCore
import Vapor

/// The crypto half of believing a StoreKit transaction, behind a seam.
protocol SignedTransactionVerifying: Sendable {
    /// The payload of `jws` — only once its signature is proven Apple's.
    ///
    /// What `AppStoreVerifier` checks, and nothing else (everything after is
    /// `AppStorePurchases`): the header's `alg` is `ES256`; its `x5c` is three certificates
    /// whose chain verifies to Apple Root CA G3, held by this server rather than taken from
    /// the token; each is valid at the token's `signedDate`; the leaf carries the Mac App
    /// Store receipt-signing extension (OID 1.2.840.113635.100.6.11.1) and the intermediate
    /// Apple's WWDR one (1.2.840.113635.100.6.2.1); and the ES256 signature over
    /// `header.payload` verifies against the leaf's key.
    func verifiedPayload(of jws: String) async throws -> Data
}

enum SignedPayloadError: AbortError, Equatable {
    /// Not three dot-separated base64url segments, or the payload is not JSON we read.
    case malformed
    /// Well-formed, and the signature or the chain did not verify.
    case untrusted

    var status: HTTPResponseStatus { .badRequest }

    var reason: String {
        switch self {
        case .malformed: "That isn't a signed App Store transaction"
        case .untrusted: "That transaction's signature doesn't verify"
        }
    }
}

/// **Believes any well-formed JWS.** For a local server and the test suite only, so a
/// simulated purchase from the StoreKit configuration file can be followed end to end.
///
/// It cannot be reached on production: `PurchasePolicy.make` will not choose it on a server
/// running `--env production`, whatever the environment says.
struct UnverifiedLocalVerifier: SignedTransactionVerifying {
    func verifiedPayload(of jws: String) async throws -> Data {
        try JWS.payload(of: jws)
    }
}

enum JWS {
    /// The middle segment, decoded. Says nothing about whether it is genuine.
    static func payload(of token: String) throws -> Data {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, let data = base64URLDecoded(parts[1]) else {
            throw SignedPayloadError.malformed
        }
        return data
    }

    static func base64URLDecoded(_ segment: Substring) -> Data? {
        var base64 = segment.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64.append("=") }
        return Data(base64Encoded: base64)
    }

    static func base64URLEncoded(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// `JWSTransactionDecodedPayload`: the fields read, of the many Apple sends.
struct AppStoreTransaction: Decodable, Sendable, Equatable {
    var transactionId: String
    var originalTransactionId: String?
    var bundleId: String
    var productId: String
    /// "Consumable" for every pack.
    var type: String?
    /// "Production", "Sandbox" or "Xcode".
    var environment: String
    /// A consumable can be bought several at once (`Product.PurchaseOption.quantity`).
    var quantity: Int?
    /// Milliseconds since 1970, as Apple writes every date.
    var purchaseDate: Double?
    var revocationDate: Double?
    /// The `appAccountToken` the phone set: the account the purchase was made for.
    var appAccountToken: UUID?

    enum CodingKeys: String, CodingKey {
        case transactionId, originalTransactionId, bundleId, productId, type, environment
        case quantity, purchaseDate, revocationDate, appAccountToken
    }

    init(
        transactionId: String,
        bundleId: String,
        productId: String,
        environment: String,
        quantity: Int? = 1,
        revocationDate: Double? = nil,
        appAccountToken: UUID? = nil
    ) {
        self.transactionId = transactionId
        self.bundleId = bundleId
        self.productId = productId
        self.type = "Consumable"
        self.environment = environment
        self.quantity = quantity
        self.revocationDate = revocationDate
        self.appAccountToken = appAccountToken
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        transactionId = try container.decode(String.self, forKey: .transactionId)
        originalTransactionId = try container.decodeIfPresent(String.self, forKey: .originalTransactionId)
        bundleId = try container.decode(String.self, forKey: .bundleId)
        productId = try container.decode(String.self, forKey: .productId)
        type = try container.decodeIfPresent(String.self, forKey: .type)
        environment = try container.decode(String.self, forKey: .environment)
        quantity = try container.decodeIfPresent(Int.self, forKey: .quantity)
        purchaseDate = try container.decodeIfPresent(Double.self, forKey: .purchaseDate)
        revocationDate = try container.decodeIfPresent(Double.self, forKey: .revocationDate)
        // Read as a string and parsed, so an empty or odd token is "none" rather than a
        // transaction that cannot be decoded at all.
        appAccountToken = (try? container.decodeIfPresent(String.self, forKey: .appAccountToken))
            .flatMap { $0 }
            .flatMap(UUID.init(uuidString:))
    }
}

/// App Store Server Notifications V2's `responseBodyV2DecodedPayload`.
struct AppStoreNotification: Decodable, Sendable {
    struct Payload: Decodable, Sendable {
        var bundleId: String?
        var environment: String?
        /// Itself a JWS, verified separately.
        var signedTransactionInfo: String?
        /// A JWS too. Only subscriptions have one, so no pack ever does; verified when present
        /// all the same, because a notification is only as genuine as everything inside it.
        var signedRenewalInfo: String?
    }

    /// "REFUND", "REVOKE", "REFUND_REVERSED", "CONSUMPTION_REQUEST", "TEST", …
    var notificationType: String
    var subtype: String?
    var notificationUUID: String?
    var data: Payload?
}

/// Which signed transactions this deployment believes, and how it checks the signature.
struct PurchasePolicy: Sendable {
    var verifier: any SignedTransactionVerifying
    var isProductionServer: Bool
    /// `CREDITS_ALLOW_SANDBOX=true`. Needed on production while App Review and TestFlight
    /// buy packs — both are sandbox purchases against the production server.
    var allowsSandbox: Bool

    /// - Production: always. It is real money on any server.
    /// - Sandbox: off production, or with the flag. A sandbox purchase costs nothing, so with
    ///   the flag on, a TestFlight tester can mint credits; the rows carry
    ///   `store_environment` so they can be found and taken back.
    /// - Xcode: **never on production, flag or no flag.** Those transactions are signed by a
    ///   certificate any developer's Xcode makes for itself, and there is no reason one should
    ///   ever reach the real server.
    func accepts(environment: String) -> Bool {
        switch environment {
        case "Production": true
        case "Sandbox": !isProductionServer || allowsSandbox
        case "Xcode": !isProductionServer
        default: false
        }
    }

    /// Read once, at boot. The unverified double needs **both** a non-production server and
    /// `CREDITS_UNVERIFIED_TRANSACTIONS=true`: set on production, the flag is refused out loud
    /// and the real verifier is used.
    ///
    /// The two flags are parameters rather than reads inside, for the reason
    /// `Application.tlsMode` takes its override that way: the suite runs in parallel, and a
    /// test that set the variable would change every other test's server.
    static func make(
        environment: Vapor.Environment,
        logger: Logger,
        unverifiedFlag: String? = Vapor.Environment.get("CREDITS_UNVERIFIED_TRANSACTIONS"),
        sandboxFlag: String? = Vapor.Environment.get("CREDITS_ALLOW_SANDBOX")
    ) -> PurchasePolicy {
        let isProduction = environment == .production
        let wantsUnverified = unverifiedFlag == "true"
        var verifier: any SignedTransactionVerifying = AppStoreVerifier()
        if wantsUnverified, isProduction {
            logger.critical("credits: CREDITS_UNVERIFIED_TRANSACTIONS is ignored on a production server")
        } else if wantsUnverified {
            logger.warning("credits: believing UNVERIFIED App Store transactions — local testing only")
            verifier = UnverifiedLocalVerifier()
        } else {
            logger.notice("credits: App Store transactions verified against Apple Root CA - G3")
        }
        return PurchasePolicy(
            verifier: verifier,
            isProductionServer: isProduction,
            allowsSandbox: sandboxFlag == "true"
        )
    }
}

extension Application {
    private struct PurchasePolicyKey: StorageKey {
        typealias Value = PurchasePolicy
    }

    /// Settable so the test suite can put the double in; nothing else writes it.
    var purchasePolicy: PurchasePolicy {
        get {
            storage[PurchasePolicyKey.self]
                ?? PurchasePolicy(verifier: AppStoreVerifier(), isProductionServer: true, allowsSandbox: false)
        }
        set { storage[PurchasePolicyKey.self] = newValue }
    }
}

enum AppStorePurchases {
    /// The only app whose purchases this server credits.
    static let bundleID = "com.kern.functional.streetw"

    /// Verifies, checks and credits one transaction for one account. Idempotent per
    /// transaction id: a second post answers `.alreadyCredited` and adds nothing.
    static func credit(
        signed jws: String,
        account accountID: UUID,
        policy: PurchasePolicy,
        now: Date = Date(),
        on db: any Database
    ) async throws -> CreditPurchaseReceipt {
        let transaction = try await verifiedTransaction(jws, policy: policy)
        guard let pack = CreditPacks.pack(for: transaction.productId) else {
            // Left unfinished on the phone: a pack on sale that this server does not list is
            // a deploy behind App Store Connect, and the next deploy can still credit it.
            throw Abort(.unprocessableEntity, reason: "\(transaction.productId) isn't a credit pack this server sells")
        }
        // A purchase made for one account is not credited to another. Nil is allowed: the
        // token is the phone's to set, and a purchase interrupted before an account existed
        // on this install may carry none.
        if let token = transaction.appAccountToken, token != accountID {
            throw Abort(.conflict, reason: "This purchase was made for a different account")
        }
        if transaction.revocationDate != nil {
            return CreditPurchaseReceipt(
                transactionID: transaction.transactionId,
                outcome: .revoked,
                credited: 0,
                balance: try await CreditLedger.balance(of: accountID, on: db)
            )
        }

        do {
            return try await db.transaction { tx in
                try await CreditLedger.lock(accountID, on: tx)
                let existing = try await CreditEntryModel.query(on: tx)
                    .filter(\.$appleTransactionID == transaction.transactionId)
                    .all()
                if let purchase = existing.first(where: { $0.reason == CreditReason.purchase.rawValue }) {
                    guard purchase.$account.id == accountID else {
                        throw Abort(.conflict, reason: "This purchase was credited to a different account")
                    }
                    return CreditPurchaseReceipt(
                        transactionID: transaction.transactionId,
                        outcome: .alreadyCredited,
                        credited: 0,
                        balance: try await CreditLedger.balance(of: accountID, on: tx)
                    )
                }
                // A refund that arrived before the purchase was ever posted — see `refund`.
                if existing.contains(where: { $0.reason == CreditReason.refund.rawValue }) {
                    return CreditPurchaseReceipt(
                        transactionID: transaction.transactionId,
                        outcome: .revoked,
                        credited: 0,
                        balance: try await CreditLedger.balance(of: accountID, on: tx)
                    )
                }

                let credits = pack.credits * max(1, transaction.quantity ?? 1)
                let entry = CreditEntryModel(accountID: accountID, delta: credits, reason: .purchase, at: now)
                entry.appleTransactionID = transaction.transactionId
                entry.productID = transaction.productId
                entry.storeEnvironment = transaction.environment
                try await entry.save(on: tx)
                return CreditPurchaseReceipt(
                    transactionID: transaction.transactionId,
                    outcome: .credited,
                    credited: credits,
                    balance: try await CreditLedger.balance(of: accountID, on: tx)
                )
            }
        } catch let error as any DatabaseError where error.isConstraintFailure {
            // The same transaction credited to another account in the same instant: the
            // per-account lock cannot see that, and the unique constraint is what caught it.
            throw Abort(.conflict, reason: "This purchase was credited to a different account")
        }
    }

    /// What a notification asked for, for the test suite and the log line.
    enum NotificationOutcome: Equatable {
        case refunded(credits: Int)
        /// A refund for a purchase never credited, recorded so a later post of it credits
        /// nothing.
        case refundRecordedBeforePurchase
        case refundReversed(credits: Int)
        /// Nothing to do: already handled, a type this server does not act on, another
        /// app's, or an environment it does not believe.
        case ignored(String)
    }

    /// App Store Server Notifications V2. Verified the same way as a purchase — both the
    /// notification and the transaction inside it — because this route is public and is the
    /// one way credits are taken away.
    static func handle(
        notification signedPayload: String,
        policy: PurchasePolicy,
        now: Date = Date(),
        on db: any Database
    ) async throws -> NotificationOutcome {
        let payload = try await policy.verifier.verifiedPayload(of: signedPayload)
        guard let notification = try? JSONDecoder().decode(AppStoreNotification.self, from: payload) else {
            throw SignedPayloadError.malformed
        }

        let kind = notification.notificationType
        guard ["REFUND", "REVOKE", "REFUND_REVERSED"].contains(kind) else {
            // CONSUMPTION_REQUEST is Apple asking how much of a consumable was used before it
            // decides a refund. Answering it is an App Store Server API call this server
            // cannot make yet; not answering is allowed, and Apple decides without it.
            return .ignored(kind)
        }
        guard notification.data?.bundleId == bundleID else { return .ignored("another app") }
        guard let signedTransaction = notification.data?.signedTransactionInfo else {
            throw SignedPayloadError.malformed
        }
        let transaction: AppStoreTransaction
        do {
            transaction = try await verifiedTransaction(signedTransaction, policy: policy)
        } catch let refusal as Abort where refusal.status == .forbidden {
            return .ignored("environment")
        }
        if let renewal = notification.data?.signedRenewalInfo {
            _ = try await policy.verifier.verifiedPayload(of: renewal)
        }

        let existing = try await CreditEntryModel.query(on: db)
            .filter(\.$appleTransactionID == transaction.transactionId)
            .all()
        let purchase = existing.first { $0.reason == CreditReason.purchase.rawValue }

        if kind == "REFUND_REVERSED" {
            return try await reverseRefund(transaction, purchase: purchase, existing: existing, now: now, on: db)
        }
        return try await refund(transaction, purchase: purchase, existing: existing, now: now, on: db)
    }

    /// Takes back exactly what the purchase added — the ledger's row, not the pack table,
    /// which may have changed since. **The balance may go negative**: the credits were spent
    /// and the money returned, and a negative balance refuses every spend until something
    /// brings it back above zero.
    private static func refund(
        _ transaction: AppStoreTransaction,
        purchase: CreditEntryModel?,
        existing: [CreditEntryModel],
        now: Date,
        on db: any Database
    ) async throws -> NotificationOutcome {
        if existing.contains(where: { $0.reason == CreditReason.refund.rawValue }) {
            return .ignored("already refunded") // Apple retries until it hears a 200.
        }
        guard let purchase else {
            // Refunded before the phone ever posted it — an interrupted purchase, refunded.
            // A zero row under the account the purchase named, so that post credits nothing
            // when it does arrive. With no account named there is nowhere to write it, and
            // a stale copy of the transaction posted later would be credited once.
            guard let token = transaction.appAccountToken,
                  try await AccountModel.find(token, on: db) != nil
            else { return .ignored("refund for a purchase never credited, and no account named") }
            try await insertOnce(
                accountID: token, delta: 0, reason: .refund, transaction: transaction, now: now, on: db
            )
            return .refundRecordedBeforePurchase
        }
        try await insertOnce(
            accountID: purchase.$account.id, delta: -purchase.delta, reason: .refund,
            transaction: transaction, now: now, on: db
        )
        return .refunded(credits: purchase.delta)
    }

    private static func reverseRefund(
        _ transaction: AppStoreTransaction,
        purchase: CreditEntryModel?,
        existing: [CreditEntryModel],
        now: Date,
        on db: any Database
    ) async throws -> NotificationOutcome {
        guard let purchase,
              existing.contains(where: { $0.reason == CreditReason.refund.rawValue && $0.delta != 0 }),
              !existing.contains(where: { $0.reason == CreditReason.refundReversed.rawValue })
        else { return .ignored("no refund to reverse") }
        try await insertOnce(
            accountID: purchase.$account.id, delta: purchase.delta, reason: .refundReversed,
            transaction: transaction, now: now, on: db
        )
        return .refundReversed(credits: purchase.delta)
    }

    /// One row per (transaction, reason), under the account's lock; a constraint failure is
    /// a concurrent delivery of the same notification having won, which is the outcome wanted.
    private static func insertOnce(
        accountID: UUID,
        delta: Int,
        reason: CreditReason,
        transaction: AppStoreTransaction,
        now: Date,
        on db: any Database
    ) async throws {
        do {
            try await db.transaction { tx in
                try await CreditLedger.lock(accountID, on: tx)
                let entry = CreditEntryModel(accountID: accountID, delta: delta, reason: reason, at: now)
                entry.appleTransactionID = transaction.transactionId
                entry.productID = transaction.productId
                entry.storeEnvironment = transaction.environment
                try await entry.save(on: tx)
            }
        } catch let error as any DatabaseError where error.isConstraintFailure {
            return
        }
    }

    /// Signature, decode, bundle, environment — the checks every signed transaction passes
    /// before anything reads its product.
    static func verifiedTransaction(_ jws: String, policy: PurchasePolicy) async throws -> AppStoreTransaction {
        let payload = try await policy.verifier.verifiedPayload(of: jws)
        guard let transaction = try? JSONDecoder().decode(AppStoreTransaction.self, from: payload) else {
            throw SignedPayloadError.malformed
        }
        guard transaction.bundleId == bundleID else {
            throw Abort(.badRequest, reason: "That transaction belongs to another app")
        }
        guard policy.accepts(environment: transaction.environment) else {
            throw Abort(.forbidden, reason: "\(transaction.environment) purchases aren't accepted by this server")
        }
        return transaction
    }
}

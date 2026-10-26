// CreditRoutes.swift
// The credit routes: the phone's balance, its purchases, Apple's refunds, and the operator's
// read-back of what AI actually costs. In their own file so `routes.swift` gains one line.
// See `docs/credits.md`.

import Fluent
import Foundation
import StreetwCore
import Vapor

extension CreditsSummary: @retroactive Content {}
extension CreditPurchase: @retroactive Content {}
extension CreditPurchaseReceipt: @retroactive Content {}

/// `POST /v1/app-store/notifications`'s body, as Apple sends it.
private struct SignedNotification: Content {
    var signedPayload: String
}

func creditRoutes(
    _ app: Application,
    v1: any RoutesBuilder,
    authed: any RoutesBuilder,
    admin: any RoutesBuilder
) throws {
    app.purchasePolicy = PurchasePolicy.make(environment: app.environment, logger: app.logger)

    /// A signed transaction is three certificates and a payload, about 4KB; a notification
    /// carries one inside another. Refused at the door well above both.
    let signedBodyLimit: ByteCount = "64kb"

    /// Everything the You page's Credits section prints, or `signedIn: false` and nothing
    /// else — which is how the phone knows to draw no section at all. Writes nothing.
    authed.get("credits") { req async throws -> CreditsSummary in
        let device = try await req.authenticatedDevice()
        let user = try await device.$user.get(on: req.db)
        return try await CreditLedger.summary(for: user, on: req.db)
    }

    /// One StoreKit 2 transaction, credited once. Every 2xx is final and the phone finishes
    /// the transaction on it; every refusal leaves it unfinished, to be posted again on a
    /// later launch — which is how a purchase made while this server could not verify it is
    /// still credited once one can.
    authed.grouped(RateLimit(store: app.rateLimits.purchases, identity: .device, name: "purchases"))
        .on(.POST, "credits", "purchases", body: .collect(maxSize: signedBodyLimit)) { req async throws -> CreditPurchaseReceipt in
        // Checked here as well, for the reason `POST /v1/usage` does: a body that arrives in
        // one read is never measured against the route's limit.
        guard (req.body.data?.readableBytes ?? 0) <= signedBodyLimit.value else {
            throw Abort(.payloadTooLarge)
        }
        let device = try await req.authenticatedDevice()
        let user = try await device.$user.get(on: req.db)
        let accountID = try CreditLedger.accountID(of: user)
        let body = try req.content.decode(CreditPurchase.self)
        let receipt = try await AppStorePurchases.credit(
            signed: body.signedTransaction,
            account: accountID,
            policy: req.application.purchasePolicy,
            on: req.db
        )
        req.logger.notice("credits: \(receipt.outcome.rawValue) \(receipt.credited) for transaction \(receipt.transactionID)")
        return receipt
    }

    /// App Store Server Notifications V2 — the URL App Store Connect is given, for both
    /// environments. **Public, and authenticated by Apple's signature alone**: Apple holds no
    /// device token. Answers 200 for anything handled or deliberately ignored, so Apple stops
    /// retrying; a 503 while no verifier is deployed, so Apple retries — for a while.
    v1.grouped(RateLimit(store: app.rateLimits.storeNotifications, identity: .address, name: "store-notifications"))
        .on(.POST, "app-store", "notifications", body: .collect(maxSize: signedBodyLimit)) { req async throws -> HTTPStatus in
        guard (req.body.data?.readableBytes ?? 0) <= signedBodyLimit.value else {
            throw Abort(.payloadTooLarge)
        }
        let body = try req.content.decode(SignedNotification.self)
        let outcome = try await AppStorePurchases.handle(
            notification: body.signedPayload,
            policy: req.application.purchasePolicy,
            on: req.db
        )
        req.logger.notice("credits: App Store notification — \(outcome)")
        return .ok
    }

    /// What every AI action cost since `?since=` (ISO-8601; default thirty days, at most a
    /// year): per action, count, total, mean, median, p90 and max, in millionths of a
    /// dollar. This is what credit prices are set from.
    admin.get("costs") { req async throws -> CostSummary in
        let now = Date()
        let floor = now.addingTimeInterval(-366 * 86_400)
        let asked = (try? req.query.get(Date.self, at: "since")) ?? now.addingTimeInterval(-30 * 86_400)
        return try await CostMeter.summary(since: max(asked, floor), now: now, on: req.db)
    }

    /// The operator's grant: `?credits=` to add, negative to take back. For somebody owed
    /// credits, and for taking back what a sandbox purchase minted. Not the unlimited switch,
    /// which is the account routes' (`POST /admin/accounts/:id/credits`).
    admin.post("accounts", ":accountID", "grants") { req async throws -> String in
        guard let accountID = req.parameters.get("accountID", as: UUID.self),
              let credits = try? req.query.get(Int.self, at: "credits"),
              credits != 0, abs(credits) <= 100_000
        else { throw Abort(.badRequest, reason: "Name an account and ?credits= between -100000 and 100000") }
        guard try await AccountModel.find(accountID, on: req.db) != nil else { throw Abort(.notFound) }
        try await CreditLedger.grant(credits: credits, account: accountID, on: req.db)
        let balance = try await CreditLedger.balance(of: accountID, on: req.db)
        return "granted \(credits); balance \(balance)"
    }
}

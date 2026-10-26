import Fluent
import FluentPostgresDriver
import Foundation
import Logging
import StreetwCore
import Testing
import Vapor
import VaporTesting

@testable import StreetwServer

// MARK: - Helpers

/// A test JWS: a real-shaped token whose signature nobody checks. Only ever read through
/// `UnverifiedLocalVerifier`, which is the point of the seam.
private func signed(_ object: [String: Any]) throws -> String {
    let header = JWS.base64URLEncoded(Data(#"{"alg":"ES256","x5c":[]}"#.utf8))
    let payload = JWS.base64URLEncoded(try JSONSerialization.data(withJSONObject: object))
    return "\(header).\(payload).c2lnbmF0dXJl"
}

private func transaction(
    id: String = "2000000123",
    product: String = "com.kern.functional.streetw.credits.50",
    bundle: String = AppStorePurchases.bundleID,
    environment: String = "Production",
    quantity: Int = 1,
    revoked: Bool = false,
    account: UUID? = nil
) throws -> String {
    var object: [String: Any] = [
        "transactionId": id,
        "originalTransactionId": id,
        "bundleId": bundle,
        "productId": product,
        "type": "Consumable",
        "environment": environment,
        "quantity": quantity,
        "purchaseDate": 1_792_843_200_000.0
    ]
    if revoked { object["revocationDate"] = 1_792_929_600_000.0 }
    if let account { object["appAccountToken"] = account.uuidString.lowercased() }
    return try signed(object)
}

private func notification(_ type: String, transaction inner: String, bundle: String = AppStorePurchases.bundleID) throws -> String {
    try signed([
        "notificationType": type,
        "notificationUUID": UUID().uuidString,
        "data": ["bundleId": bundle, "environment": "Production", "signedTransactionInfo": inner]
    ])
}

/// The double, on a server that is not production.
private let localPolicy = PurchasePolicy(verifier: UnverifiedLocalVerifier(), isProductionServer: false, allowsSandbox: false)

private func makeAccount(
    _ app: Application,
    unlimited: Bool = false,
    capMicros: Int64? = nil
) async throws -> UUID {
    let account = AccountModel(appleSubject: "subject-\(UUID().uuidString)")
    account.unlimitedCredits = unlimited
    account.monthlyCostCapMicros = capMicros
    try await account.save(on: app.db)
    return try account.requireID()
}

/// Registers a device through the route, then hangs its user off a new account — what
/// signing in will do, done directly because the sign-in route is not this suite's.
private func signedInDevice(
    _ app: Application,
    unlimited: Bool = false
) async throws -> (headers: HTTPHeaders, account: UUID, user: UserModel) {
    let headers = try await deviceAuth(app)
    let token = headers.bearerAuthorization!.token
    let device = try #require(try await DeviceModel.query(on: app.db).filter(\.$authToken == token).first())
    let user = try await device.$user.get(on: app.db)
    let account = try await makeAccount(app, unlimited: unlimited)
    user.$account.id = account
    try await user.save(on: app.db)
    return (headers, account, user)
}

private func post(
    _ app: Application,
    _ jws: String,
    headers: HTTPHeaders
) async throws -> (HTTPStatus, CreditPurchaseReceipt?, String) {
    var outcome: (HTTPStatus, CreditPurchaseReceipt?, String) = (.internalServerError, nil, "")
    try await app.testing().test(.POST, "v1/credits/purchases", headers: headers, beforeRequest: { req in
        try req.content.encode(CreditPurchase(signedTransaction: jws))
    }, afterResponse: { res async throws in
        outcome = (res.status, res.status == .ok ? try res.content.decode(CreditPurchaseReceipt.self) : nil, res.body.string)
    })
    return outcome
}

private func notify(_ app: Application, _ signedPayload: String) async throws -> HTTPStatus {
    var status = HTTPStatus.internalServerError
    try await app.testing().test(.POST, "v1/app-store/notifications", beforeRequest: { req in
        try req.content.encode(["signedPayload": signedPayload])
    }, afterResponse: { res in
        status = res.status
    })
    return status
}

private func summary(_ app: Application, headers: HTTPHeaders) async throws -> CreditsSummary {
    var decoded = CreditsSummary(signedIn: false)
    try await app.testing().test(.GET, "v1/credits", headers: headers) { res async throws in
        #expect(res.status == .ok)
        decoded = try res.content.decode(CreditsSummary.self)
    }
    return decoded
}

/// 2026-10-24 12:00 UTC.
private let october = Date(timeIntervalSince1970: 1_792_843_200)
/// 2026-11-03 12:00 UTC.
private let november = october.addingTimeInterval(10 * 86_400)

// MARK: - The rule

@Suite("Credits: the spend rule")
struct CreditRuleTests {
    @Test("The cost cap is checked first, and binds an unlimited account too")
    func capFirst() {
        #expect(CreditLedger.decide(credits: 1, balance: 500, unlimited: true, monthCostMicros: 5_000_000, capMicros: 5_000_000)
            == .refuse(.monthlyCostCap))
        #expect(CreditLedger.decide(credits: 1, balance: 500, unlimited: false, monthCostMicros: 6_000_000, capMicros: 5_000_000)
            == .refuse(.monthlyCostCap))
        #expect(CreditLedger.decide(credits: 1, balance: 500, unlimited: false, monthCostMicros: 4_999_999, capMicros: 5_000_000)
            == .charge(1))
    }

    @Test("Unlimited never decrements and never refuses")
    func unlimited() {
        #expect(CreditLedger.decide(credits: 2, balance: -40, unlimited: true, monthCostMicros: 0, capMicros: nil) == .charge(0))
    }

    @Test("Short is refused, and so is a balance a refund took negative")
    func balance() {
        #expect(CreditLedger.decide(credits: 2, balance: 2, unlimited: false, monthCostMicros: 0, capMicros: nil) == .charge(2))
        #expect(CreditLedger.decide(credits: 2, balance: 1, unlimited: false, monthCostMicros: 0, capMicros: nil)
            == .refuse(.insufficient(balance: 1, needed: 2)))
        #expect(CreditLedger.decide(credits: 1, balance: -3, unlimited: false, monthCostMicros: 0, capMicros: nil)
            == .refuse(.insufficient(balance: -3, needed: 1)))
    }

    @Test("Percentiles are nearest-rank: always a cost that was measured")
    func percentiles() {
        let costs: [Int64] = [10, 20, 30, 40, 50, 60, 70, 80, 90, 1000]
        #expect(CostMeter.percentile(0.5, of: costs) == 50)
        #expect(CostMeter.percentile(0.9, of: costs) == 90)
        #expect(CostMeter.percentile(0.9, of: [7]) == 7)
        #expect(CostMeter.percentile(0.5, of: []) == 0)
    }

    @Test("Xcode purchases are never believed on production; sandbox only with the flag")
    func environments() {
        let production = PurchasePolicy(verifier: AppStoreVerifier(), isProductionServer: true, allowsSandbox: false)
        #expect(production.accepts(environment: "Production"))
        #expect(!production.accepts(environment: "Sandbox"))
        #expect(!production.accepts(environment: "Xcode"))
        #expect(!production.accepts(environment: "Something"))

        let review = PurchasePolicy(verifier: AppStoreVerifier(), isProductionServer: true, allowsSandbox: true)
        #expect(review.accepts(environment: "Sandbox"))
        #expect(!review.accepts(environment: "Xcode"))

        #expect(localPolicy.accepts(environment: "Xcode"))
        #expect(localPolicy.accepts(environment: "Sandbox"))
    }

    @Test("The unverified double cannot be switched on in production")
    func noDoubleInProduction() async throws {
        let logger = Logger(label: "test")
        let production = PurchasePolicy.make(environment: .production, logger: logger, unverifiedFlag: "true", sandboxFlag: nil)
        #expect(production.verifier is AppStoreVerifier)
        let local = PurchasePolicy.make(environment: .development, logger: logger, unverifiedFlag: "true", sandboxFlag: nil)
        #expect(local.verifier is UnverifiedLocalVerifier)
        let unset = PurchasePolicy.make(environment: .development, logger: logger, unverifiedFlag: nil, sandboxFlag: nil)
        #expect(unset.verifier is AppStoreVerifier)

        // And the production verifier does not believe what the double does.
        await #expect(throws: SignedPayloadError.untrusted) {
            try await AppStoreVerifier().verifiedPayload(of: try transaction())
        }
    }
}

// MARK: - The ledger

@Suite("Credits: the ledger")
struct CreditLedgerTests {
    @Test("The allowance is granted once, on the first spend of a month")
    func allowanceIsLazy() async throws {
        try await withServer { app in
            let account = try await makeAccount(app)
            #expect(try await CreditLedger.balance(of: account, on: app.db) == 0)

            _ = try await CreditLedger.spend(credits: 1, for: .search, account: account, now: october, on: app.db)
            _ = try await CreditLedger.spend(credits: 2, for: .scan, account: account, now: october, on: app.db)
            #expect(try await CreditLedger.balance(of: account, on: app.db) == CreditPolicy.monthlyAllowance - 3)

            // The next month's is added on top — granted credits never expire either.
            _ = try await CreditLedger.spend(credits: 1, for: .search, account: account, now: november, on: app.db)
            #expect(try await CreditLedger.balance(of: account, on: app.db) == 2 * CreditPolicy.monthlyAllowance - 4)
            let grants = try await CreditEntryModel.query(on: app.db).filter(\.$reason == "allowance").count()
            #expect(grants == 2)
        }
    }

    @Test("Reading the balance writes nothing, and still counts the allowance due")
    func summaryWritesNothing() async throws {
        try await withServer { app in
            let (_, account, user) = try await signedInDevice(app)
            let read = try await CreditLedger.summary(for: user, now: october, on: app.db)
            #expect(read.signedIn)
            #expect(read.balance == CreditPolicy.monthlyAllowance)
            #expect(read.accountToken == account)
            #expect(read.packs == CreditPacks.all)
            #expect(try await CreditEntryModel.query(on: app.db).count() == 0)

            _ = try await CreditLedger.spend(credits: 1, for: .search, account: account, now: october, on: app.db)
            let after = try await CreditLedger.summary(for: user, now: october, on: app.db)
            #expect(after.balance == CreditPolicy.monthlyAllowance - 1)
            #expect(after.thisMonth == [CreditUsage(action: "search", count: 1)])
        }
    }

    @Test("A short spend is refused and writes nothing — not even the allowance")
    func refusedSpendWritesNothing() async throws {
        try await withServer { app in
            let account = try await makeAccount(app)
            await #expect(throws: CreditRefusal.insufficient(balance: CreditPolicy.monthlyAllowance, needed: 999)) {
                try await CreditLedger.spend(credits: 999, for: .search, account: account, now: october, on: app.db)
            }
            #expect(try await CreditEntryModel.query(on: app.db).count() == 0)
        }
    }

    @Test("Unlimited: never charged, never refused, still counted and still metered")
    func unlimitedAccount() async throws {
        try await withServer { app in
            let account = try await makeAccount(app, unlimited: true)
            for _ in 0..<5 {
                let charge = try await CreditLedger.spend(credits: 2, for: .scan, account: account, now: october, on: app.db)
                #expect(charge.credits == 0)
                try await CostMeter.record(
                    MeteredCost(action: .scan, model: "m", inputTokens: 100, outputTokens: 20, costMicros: 1_500),
                    account: account, user: nil, at: october, on: app.db
                )
            }
            #expect(try await CreditLedger.balance(of: account, on: app.db) == 0)
            #expect(try await CreditLedger.usage(of: account, now: october, on: app.db) == [CreditUsage(action: "scan", count: 5)])
            #expect(try await CostMeter.monthCost(account: account, now: october, on: app.db) == 7_500)
            // No allowance for an account that is never charged.
            #expect(try await CreditEntryModel.query(on: app.db).filter(\.$reason == "allowance").count() == 0)
        }
    }

    @Test("The monthly cost cap refuses once passed, and lifts with the month")
    func costCap() async throws {
        try await withServer { app in
            let account = try await makeAccount(app, unlimited: true, capMicros: 10_000)
            let call = MeteredCost(action: .search, model: "m", inputTokens: 1, outputTokens: 1, costMicros: 6_000)

            _ = try await CreditLedger.spend(credits: 1, for: .search, account: account, now: october, on: app.db)
            try await CostMeter.record(call, account: account, user: nil, at: october, on: app.db)
            _ = try await CreditLedger.spend(credits: 1, for: .search, account: account, now: october, on: app.db)
            try await CostMeter.record(call, account: account, user: nil, at: october, on: app.db)

            await #expect(throws: CreditRefusal.monthlyCostCap) {
                try await CreditLedger.spend(credits: 1, for: .search, account: account, now: october, on: app.db)
            }
            _ = try await CreditLedger.spend(credits: 1, for: .search, account: account, now: november, on: app.db)
        }
    }

    @Test("A spend undone is given back and counts as no action")
    func undo() async throws {
        try await withServer { app in
            let account = try await makeAccount(app)
            let charge = try await CreditLedger.spend(credits: 2, for: .scan, account: account, now: october, on: app.db)
            _ = try await CreditLedger.spend(credits: 1, for: .search, account: account, now: october, on: app.db)
            try await CreditLedger.undo(charge, now: october, on: app.db)
            #expect(try await CreditLedger.balance(of: account, on: app.db) == CreditPolicy.monthlyAllowance - 1)
            #expect(try await CreditLedger.usage(of: account, now: october, on: app.db) == [CreditUsage(action: "search", count: 1)])
        }
    }

    @Test("No account: a clear answer to sign in, everywhere")
    func signInRequired() async throws {
        try await withServer { app in
            app.purchasePolicy = localPolicy
            let headers = try await deviceAuth(app)
            #expect(try await summary(app, headers: headers) == CreditsSummary(signedIn: false))

            let (status, _, body) = try await post(app, try transaction(), headers: headers)
            #expect(status == .forbidden)
            #expect(body.contains("Sign in to use credits"))

            let user = try #require(try await UserModel.query(on: app.db).first())
            #expect(throws: CreditRefusal.signInRequired) { try CreditLedger.accountID(of: user) }
            #expect(try await CreditEntryModel.query(on: app.db).count() == 0)
        }
    }

    @Test("Deleting an account takes its ledger and leaves its costs, unnamed")
    func accountDeletion() async throws {
        try await withServer { app in
            let account = try await makeAccount(app)
            _ = try await CreditLedger.spend(credits: 1, for: .search, account: account, now: october, on: app.db)
            try await CostMeter.record(
                MeteredCost(action: .search, model: "m", inputTokens: 1, outputTokens: 1, costMicros: 900),
                account: account, user: nil, at: october, on: app.db
            )
            try await AccountModel.find(account, on: app.db)?.delete(on: app.db)

            #expect(try await CreditEntryModel.query(on: app.db).count() == 0)
            let cost = try #require(try await CostRecordModel.query(on: app.db).first())
            #expect(cost.$account.id == nil)
            #expect(cost.costMicros == 900)
        }
    }

    @Test("The operator can grant, behind the admin key")
    func adminGrant() async throws {
        try await withServer { app in
            let account = try await makeAccount(app)
            try await app.testing().test(.POST, "admin/accounts/\(account)/grants?credits=25") { res in
                #expect(res.status == .unauthorized)
            }
            try await app.testing().test(.POST, "admin/accounts/\(account)/grants?credits=25", headers: adminAuth) { res in
                #expect(res.status == .ok)
            }
            try await app.testing().test(.POST, "admin/accounts/\(UUID())/grants?credits=25", headers: adminAuth) { res in
                #expect(res.status == .notFound)
            }
            #expect(try await CreditLedger.balance(of: account, on: app.db) == 25)
        }
    }
}

// MARK: - Purchases

@Suite("Credits: purchases")
struct CreditPurchaseTests {
    @Test("A purchase is credited once, however often it is posted")
    func creditedOnce() async throws {
        try await withServer { app in
            app.purchasePolicy = localPolicy
            let (headers, account, _) = try await signedInDevice(app)
            let jws = try transaction(account: account)

            let (first, receipt, _) = try await post(app, jws, headers: headers)
            #expect(first == .ok)
            #expect(receipt?.outcome == .credited)
            #expect(receipt?.credited == 50)
            #expect(receipt?.balance == 50)

            let (again, replay, _) = try await post(app, jws, headers: headers)
            #expect(again == .ok)
            #expect(replay?.outcome == .alreadyCredited)
            #expect(replay?.credited == 0)
            #expect(try await CreditLedger.balance(of: account, on: app.db) == 50)

            // The summary adds this month's allowance, still due, on top.
            #expect(try await summary(app, headers: headers).balance == 50 + CreditPolicy.monthlyAllowance)
        }
    }

    @Test("Quantity multiplies the pack")
    func quantity() async throws {
        try await withServer { app in
            app.purchasePolicy = localPolicy
            let (headers, _, _) = try await signedInDevice(app)
            let (_, receipt, _) = try await post(app, try transaction(product: "com.kern.functional.streetw.credits.150", quantity: 3), headers: headers)
            #expect(receipt?.credited == 450)
        }
    }

    @Test("Another app's, an unknown product, and a malformed token are refused")
    func refusals() async throws {
        try await withServer { app in
            app.purchasePolicy = localPolicy
            let (headers, account, _) = try await signedInDevice(app)

            #expect(try await post(app, try transaction(bundle: "com.example.other"), headers: headers).0 == .badRequest)
            #expect(try await post(app, try transaction(product: "com.kern.functional.streetw.credits.9999"), headers: headers).0
                == .unprocessableEntity)
            #expect(try await post(app, "not-a-jws", headers: headers).0 == .badRequest)
            #expect(try await CreditLedger.balance(of: account, on: app.db) == 0)
        }
    }

    @Test("Test purchases are refused by a production server")
    func environmentOnProduction() async throws {
        try await withServer { app in
            app.purchasePolicy = PurchasePolicy(verifier: UnverifiedLocalVerifier(), isProductionServer: true, allowsSandbox: false)
            let (headers, account, _) = try await signedInDevice(app)
            #expect(try await post(app, try transaction(id: "1", environment: "Xcode"), headers: headers).0 == .forbidden)
            #expect(try await post(app, try transaction(id: "2", environment: "Sandbox"), headers: headers).0 == .forbidden)
            #expect(try await post(app, try transaction(id: "3", environment: "Production"), headers: headers).0 == .ok)
            #expect(try await CreditLedger.balance(of: account, on: app.db) == 50)
        }
    }

    @Test("A purchase made for one account is not credited to another")
    func otherAccounts() async throws {
        try await withServer { app in
            app.purchasePolicy = localPolicy
            let first = try await signedInDevice(app)
            let second = try await signedInDevice(app)

            // Named for the first account, posted by the second.
            #expect(try await post(app, try transaction(id: "a", account: first.account), headers: second.headers).0 == .conflict)

            // Naming nobody, credited to the first, then replayed by the second.
            let unnamed = try transaction(id: "b")
            #expect(try await post(app, unnamed, headers: first.headers).0 == .ok)
            #expect(try await post(app, unnamed, headers: second.headers).0 == .conflict)
            #expect(try await CreditLedger.balance(of: second.account, on: app.db) == 0)
        }
    }

    @Test("A revoked transaction is final and credits nothing")
    func revoked() async throws {
        try await withServer { app in
            app.purchasePolicy = localPolicy
            let (headers, account, _) = try await signedInDevice(app)
            let (status, receipt, _) = try await post(app, try transaction(revoked: true), headers: headers)
            #expect(status == .ok)
            #expect(receipt?.outcome == .revoked)
            #expect(try await CreditLedger.balance(of: account, on: app.db) == 0)
        }
    }

    @Test("A transaction Apple did not sign is refused with a reason, and credits nothing")
    func verifierRefuses() async throws {
        try await withServer { app in
            // What every server gets without the local flag.
            #expect(app.purchasePolicy.verifier is AppStoreVerifier)
            let (headers, account, _) = try await signedInDevice(app)
            let (status, _, body) = try await post(app, try transaction(), headers: headers)
            #expect(status == .badRequest)
            #expect(body.contains("That transaction's signature doesn't verify"))
            #expect(try await CreditLedger.balance(of: account, on: app.db) == 0)

            #expect(try await notify(app, try notification("REFUND", transaction: try transaction())) == .badRequest)
        }
    }

    @Test("Signed end to end: a purchase credits, and its refund takes the credits back")
    func signedEndToEnd() async throws {
        try await withServer { app in
            let chain = try TestStoreChain()
            app.purchasePolicy = PurchasePolicy(verifier: chain.verifier, isProductionServer: true, allowsSandbox: false)
            let (headers, account, _) = try await signedInDevice(app)
            let purchase: [String: Any] = [
                "transactionId": "9000",
                "originalTransactionId": "9000",
                "bundleId": AppStorePurchases.bundleID,
                "productId": "com.kern.functional.streetw.credits.50",
                "type": "Consumable",
                "environment": "Production",
                "quantity": 1,
                "signedDate": storeSignedDate.timeIntervalSince1970 * 1000,
                "appAccountToken": account.uuidString.lowercased()
            ]
            let signedPurchase = try chain.sign(purchase)
            let (status, receipt, _) = try await post(app, signedPurchase, headers: headers)
            #expect(status == .ok)
            #expect(receipt?.credited == 50)

            func refund(renewal: String?) throws -> String {
                var data: [String: Any] = [
                    "bundleId": AppStorePurchases.bundleID,
                    "environment": "Production",
                    "signedTransactionInfo": signedPurchase
                ]
                if let renewal { data["signedRenewalInfo"] = renewal }
                return try chain.sign([
                    "notificationType": "REFUND",
                    "notificationUUID": UUID().uuidString,
                    "signedDate": storeSignedDate.timeIntervalSince1970 * 1000,
                    "data": data
                ])
            }

            // Renewal info inside is verified too: one Apple did not sign spoils the whole
            // notification, however genuine its envelope.
            let forged = try TestStoreChain().sign(["signedDate": storeSignedDate.timeIntervalSince1970 * 1000])
            #expect(try await notify(app, try refund(renewal: forged)) == .badRequest)
            #expect(try await CreditLedger.balance(of: account, on: app.db) == 50)

            // An envelope Apple did not sign, around a transaction it did.
            let unsignedEnvelope = try notification("REFUND", transaction: signedPurchase)
            #expect(try await notify(app, unsignedEnvelope) == .badRequest)

            let genuineRenewal = try chain.sign(["signedDate": storeSignedDate.timeIntervalSince1970 * 1000])
            #expect(try await notify(app, try refund(renewal: genuineRenewal)) == .ok)
            #expect(try await CreditLedger.balance(of: account, on: app.db) == 0)
        }
    }
}

// MARK: - Refunds

@Suite("Credits: App Store notifications")
struct CreditNotificationTests {
    @Test("A refund takes back what was credited, once, and may leave the balance negative")
    func refund() async throws {
        try await withServer { app in
            app.purchasePolicy = localPolicy
            let (headers, account, _) = try await signedInDevice(app)
            let jws = try transaction(account: account)
            _ = try await post(app, jws, headers: headers)
            // Spent all fifty bought, and the month's allowance with them.
            _ = try await CreditLedger.spend(credits: 50 + CreditPolicy.monthlyAllowance, for: .search, account: account, on: app.db)

            #expect(try await notify(app, try notification("REFUND", transaction: jws)) == .ok)
            // Apple retries until it hears a 200, and may deliver twice anyway.
            #expect(try await notify(app, try notification("REFUND", transaction: jws)) == .ok)
            #expect(try await CreditLedger.balance(of: account, on: app.db) == -50)

            await #expect(throws: CreditRefusal.insufficient(balance: -50, needed: 1)) {
                try await CreditLedger.spend(credits: 1, for: .search, account: account, on: app.db)
            }
        }
    }

    @Test("A refund that arrives first stops the later post from crediting")
    func refundBeforePurchase() async throws {
        try await withServer { app in
            app.purchasePolicy = localPolicy
            let (headers, account, _) = try await signedInDevice(app)
            let jws = try transaction(account: account)

            let outcome = try await AppStorePurchases.handle(
                notification: try notification("REFUND", transaction: jws), policy: localPolicy, on: app.db
            )
            #expect(outcome == .refundRecordedBeforePurchase)

            let (status, receipt, _) = try await post(app, jws, headers: headers)
            #expect(status == .ok)
            #expect(receipt?.outcome == .revoked)
            #expect(try await CreditLedger.balance(of: account, on: app.db) == 0)
        }
    }

    @Test("A reversed refund gives the credits back, once")
    func refundReversed() async throws {
        try await withServer { app in
            app.purchasePolicy = localPolicy
            let (headers, account, _) = try await signedInDevice(app)
            let jws = try transaction(account: account)
            _ = try await post(app, jws, headers: headers)
            _ = try await notify(app, try notification("REFUND", transaction: jws))
            #expect(try await CreditLedger.balance(of: account, on: app.db) == 0)

            #expect(try await notify(app, try notification("REFUND_REVERSED", transaction: jws)) == .ok)
            #expect(try await notify(app, try notification("REFUND_REVERSED", transaction: jws)) == .ok)
            #expect(try await CreditLedger.balance(of: account, on: app.db) == 50)
        }
    }

    @Test("Anything else is acknowledged and changes nothing")
    func ignored() async throws {
        try await withServer { app in
            app.purchasePolicy = localPolicy
            let (headers, account, _) = try await signedInDevice(app)
            let jws = try transaction(account: account)
            _ = try await post(app, jws, headers: headers)

            #expect(try await notify(app, try notification("CONSUMPTION_REQUEST", transaction: jws)) == .ok)
            #expect(try await notify(app, try notification("TEST", transaction: jws)) == .ok)
            #expect(try await notify(app, try notification("REFUND", transaction: jws, bundle: "com.example.other")) == .ok)
            #expect(try await notify(app, "garbage") == .badRequest)
            #expect(try await CreditLedger.balance(of: account, on: app.db) == 50)
        }
    }
}

// MARK: - Metering

@Suite("Credits: cost metering")
struct CostMeterTests {
    @Test("The summary is per action: count, total, mean and the tail")
    func summary() async throws {
        try await withServer { app in
            let account = try await makeAccount(app)
            for cost in [100, 200, 300, 400, 5_000] as [Int64] {
                try await CostMeter.record(
                    MeteredCost(action: .search, model: "claude-x", inputTokens: 1_000, outputTokens: 200, costMicros: cost),
                    account: account, user: nil, at: october, on: app.db
                )
            }
            try await CostMeter.record(
                MeteredCost(action: .scan, model: "claude-y", inputTokens: 3_000, outputTokens: 400, costMicros: 9_000),
                account: nil, user: nil, at: october, on: app.db
            )
            // Outside the window.
            try await CostMeter.record(
                MeteredCost(action: .search, model: "claude-x", inputTokens: 1, outputTokens: 1, costMicros: 1_000_000),
                account: nil, user: nil, at: october.addingTimeInterval(-40 * 86_400), on: app.db
            )

            let read = try await CostMeter.summary(since: october.addingTimeInterval(-86_400), now: october, on: app.db)
            #expect(read.totalMicros == 15_000)
            let search = try #require(read.actions.first { $0.action == "search" })
            #expect(search.count == 5)
            #expect(search.totalMicros == 6_000)
            #expect(search.meanMicros == 1_200)
            #expect(search.p50Micros == 300)
            #expect(search.p90Micros == 5_000)
            #expect(search.inputTokens == 5_000)
            #expect(search.models == ["claude-x": 5])
            #expect(read.actions.first?.action == "scan") // most expensive first
        }
    }

    @Test("A negative cost is refused rather than summed")
    func negative() async throws {
        try await withServer { app in
            await #expect(throws: Abort.self) {
                try await CostMeter.record(
                    MeteredCost(action: .search, model: "m", inputTokens: 1, outputTokens: 1, costMicros: -5),
                    account: nil, user: nil, on: app.db
                )
            }
        }
    }

    @Test("The read-back is behind the admin key")
    func adminRoute() async throws {
        try await withServer { app in
            try await CostMeter.record(
                MeteredCost(action: .search, model: "m", inputTokens: 10, outputTokens: 5, costMicros: 250),
                account: nil, user: nil, on: app.db
            )
            try await app.testing().test(.GET, "admin/costs") { res in
                #expect(res.status == .unauthorized)
            }
            try await app.testing().test(.GET, "admin/costs", headers: adminAuth) { res async throws in
                #expect(res.status == .ok)
                let body = try res.content.decode(CostSummary.self)
                #expect(body.actions.map(\.action) == ["search"])
                #expect(body.totalMicros == 250)
            }
        }
    }
}

// MARK: - Races, on a real Postgres

/// SQLite takes no row locks and serialises every writer, so a race between two spends cannot
/// happen there and these tests would prove nothing on it. They run only when
/// `STREETW_TEST_POSTGRES_URL` names a scratch database — its tables are created and dropped.
@Suite(
    "Credits: concurrency on Postgres",
    .enabled(if: ProcessInfo.processInfo.environment["STREETW_TEST_POSTGRES_URL"] != nil),
    .serialized
)
struct CreditRaceTests {
    private func withPostgres(_ body: (Application) async throws -> Void) async throws {
        let url = try #require(ProcessInfo.processInfo.environment["STREETW_TEST_POSTGRES_URL"])
        let app = try await Application.make(.testing)
        var config = try SQLPostgresConfiguration(url: url)
        config.coreConfiguration.tls = .disable
        app.databases.use(.postgres(configuration: config, maxConnectionsPerEventLoop: 8), as: .psql)
        app.migrations.add(CreateSchema())
        app.migrations.add(CreateAccounts())
        app.migrations.add(CreateCreditLedger())
        app.migrations.add(CreateCostRecords())
        do {
            try await app.autoMigrate()
            try await body(app)
            try await app.autoRevert()
        } catch {
            try? await app.autoRevert()
            try await app.asyncShutdown()
            throw error
        }
        try await app.asyncShutdown()
    }

    @Test("Concurrent spends never take more than the balance")
    func concurrentSpends() async throws {
        try await withPostgres { app in
            let account = try await makeAccount(app)
            // The allowance is the whole balance: fifty, so five spends of ten fit.
            let outcomes = await withTaskGroup(of: Bool.self) { group in
                for _ in 0..<20 {
                    group.addTask {
                        (try? await CreditLedger.spend(credits: 10, for: .search, account: account, on: app.db)) != nil
                    }
                }
                return await group.reduce(into: [Bool]()) { $0.append($1) }
            }
            #expect(outcomes.count { $0 } == CreditPolicy.monthlyAllowance / 10)
            #expect(try await CreditLedger.balance(of: account, on: app.db) == 0)
            #expect(try await CreditEntryModel.query(on: app.db).filter(\.$reason == "allowance").count() == 1)
        }
    }

    @Test("One transaction posted at once from everywhere is credited once")
    func concurrentReplays() async throws {
        try await withPostgres { app in
            let account = try await makeAccount(app)
            let jws = try transaction(id: "race-1")
            let receipts = await withTaskGroup(of: CreditPurchaseReceipt?.self) { group in
                for _ in 0..<12 {
                    group.addTask {
                        try? await AppStorePurchases.credit(signed: jws, account: account, policy: localPolicy, on: app.db)
                    }
                }
                return await group.reduce(into: [CreditPurchaseReceipt?]()) { $0.append($1) }
            }
            #expect(receipts.count { $0?.outcome == .credited } == 1)
            #expect(receipts.count { $0?.outcome == .alreadyCredited } == 11)
            #expect(try await CreditLedger.balance(of: account, on: app.db) == 50)
        }
    }

    @Test("Two accounts racing for one transaction: one is credited, the other refused")
    func concurrentAccounts() async throws {
        try await withPostgres { app in
            let first = try await makeAccount(app)
            let second = try await makeAccount(app)
            let jws = try transaction(id: "race-2")
            let results = await withTaskGroup(of: Bool.self) { group in
                for account in [first, second, first, second] {
                    group.addTask {
                        (try? await AppStorePurchases.credit(signed: jws, account: account, policy: localPolicy, on: app.db)) != nil
                    }
                }
                return await group.reduce(into: [Bool]()) { $0.append($1) }
            }
            let total = try await CreditLedger.balance(of: first, on: app.db) + CreditLedger.balance(of: second, on: app.db)
            #expect(total == 50)
            #expect(results.count { $0 } == 2) // the winner and its own replay
        }
    }
}

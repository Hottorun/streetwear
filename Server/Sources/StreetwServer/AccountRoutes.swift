// AccountRoutes.swift
// Sign in with Apple, signing out, account deletion, and the operator's view of accounts.
//
// All of it is new surface: 1.0 and 1.1 never call these routes, and nothing about
// registration or any existing route changes. An install that never signs in is exactly
// what it was — an anonymous user behind an opaque device token.

import Fluent
import Foundation
import StreetwCore
import Vapor

extension AppleSignIn: @retroactive Content {}
extension AccountDTO: @retroactive Content {}
extension AccountSession: @retroactive Content {}
extension AccountStatus: @retroactive Content {}
extension SetAccountCredits: @retroactive Content {}
extension AdminAccount: @retroactive Content {}

extension AccountDTO {
    init(_ account: AccountModel) throws {
        self.init(id: try account.requireID(), createdAt: account.createdAt)
    }
}

func accountRoutes(authed: any RoutesBuilder, admin: any RoutesBuilder) {
    /// Whether this device is signed in. Read by the You page, so a deletion made from
    /// another phone is reflected rather than remembered.
    authed.get("account") { req async throws -> AccountStatus in
        let device = try await req.authenticatedDevice()
        let available = req.application.appleSignIn.verifier.isAvailable
        let user = try await UserModel.find(device.$user.id, on: req.db)
        guard let accountID = user?.$account.id,
              let account = try await AccountModel.find(accountID, on: req.db)
        else { return AccountStatus(account: nil, signInAvailable: available) }
        return AccountStatus(account: try AccountDTO(account), signInAvailable: available)
    }

    /// Sign in with Apple. See `Accounts.signIn` for what happens to the device's user.
    ///
    /// **Verified before anything is written**, and by a verifier that refuses outright on a
    /// deployment that cannot check signatures yet — see `AppleSignIn.swift`.
    ///
    /// The code exchange runs after the merge has committed and is best effort: a sign-in
    /// must not fail because Apple's token endpoint had a bad minute, and the only thing lost
    /// is the refresh token, which a later sign-in replaces. Logged without the code, the
    /// token or Apple's body.
    authed.post("account", "apple") { req async throws -> AccountSession in
        let device = try await req.authenticatedDevice()
        let body = try req.content.decode(AppleSignIn.self)
        let config = req.application.appleSignIn

        let identity = try await config.verifier.verify(
            identityToken: body.identityToken,
            nonce: body.nonce,
            now: Date()
        )
        let result = try await Accounts.signIn(subject: identity.subject, device: device, on: req.db)

        if let code = body.authorizationCode, !code.isEmpty {
            if let tokens = config.tokens {
                do {
                    if let refresh = try await tokens.refreshToken(forCode: code) {
                        result.account.appleRefreshToken = refresh
                        try await result.account.save(on: req.db)
                    }
                } catch {
                    req.logger.warning("siwa: code exchange failed — \(error)")
                }
            } else {
                req.logger.notice("siwa: code exchange skipped — no Sign in with Apple key on this deployment")
            }
        }

        return AccountSession(
            account: try AccountDTO(result.account),
            isNew: result.isNew,
            merged: result.merged,
            sizes: SizePayload(result.user.sizeProfile)
        )
    }

    /// Signs this device out: it leaves the account for a fresh anonymous user, keeping its
    /// token, and the account keeps everything. See `Accounts.signOut`.
    authed.post("account", "sign-out") { req async throws -> HTTPStatus in
        let device = try await req.authenticatedDevice()
        try await Accounts.signOut(device: device, on: req.db)
        return .noContent
    }

    /// Deletes the caller's account and everything personal under it, which Apple requires
    /// of an app that lets somebody make one.
    ///
    /// **The caller's own device goes too**, along with every other device on the account,
    /// so its token stops working the moment this answers. The app registers a fresh
    /// anonymous device next, which is what an install that never signed in has.
    ///
    /// Apple's token is revoked after the data is gone, best effort: a revocation that fails
    /// is logged and the deletion still stands. Holding somebody's follows hostage to a third
    /// party's uptime would be the wrong way round.
    authed.delete("account") { req async throws -> HTTPStatus in
        let device = try await req.authenticatedDevice()
        let user = try await UserModel.find(device.$user.id, on: req.db)
        guard let accountID = user?.$account.id,
              let account = try await AccountModel.find(accountID, on: req.db)
        else { throw Abort(.notFound, reason: "This device is not signed in") }

        let refreshToken = try await Accounts.delete(account, on: req.db)

        if let refreshToken {
            if let tokens = req.application.appleSignIn.tokens {
                do {
                    try await tokens.revoke(refreshToken: refreshToken)
                } catch {
                    req.logger.error("siwa: revocation failed for a deleted account — \(error)")
                }
            } else {
                req.logger.notice("siwa: revocation skipped — no Sign in with Apple key on this deployment")
            }
        } else {
            req.logger.notice("siwa: revocation skipped — the account holds no refresh token")
        }
        return .noContent
    }

    // MARK: Admin

    /// The newest accounts first, so the owner can find their own right after signing in.
    /// Counts rather than contents: nothing here says what anybody follows.
    admin.get("accounts") { req async throws -> [AdminAccount] in
        let limit = min(max((try? req.query.get(Int.self, at: "limit")) ?? 50, 1), 500)
        let accounts = try await AccountModel.query(on: req.db)
            .sort(\.$createdAt, .descending)
            .limit(limit)
            .all()
        let ids = try accounts.map { try $0.requireID() }
        let users = ids.isEmpty ? [] : try await UserModel.query(on: req.db)
            .filter(\.$account.$id ~~ ids)
            .all()
        let userIDs = try users.map { try $0.requireID() }
        let devices = userIDs.isEmpty ? [] : try await DeviceModel.query(on: req.db)
            .filter(\.$user.$id ~~ userIDs)
            .all()

        var usersPerAccount: [UUID: Int] = [:]
        var accountOfUser: [UUID: UUID] = [:]
        for user in users {
            guard let accountID = user.$account.id, let id = user.id else { continue }
            usersPerAccount[accountID, default: 0] += 1
            accountOfUser[id] = accountID
        }
        var devicesPerAccount: [UUID: Int] = [:]
        for device in devices {
            guard let accountID = accountOfUser[device.$user.id] else { continue }
            devicesPerAccount[accountID, default: 0] += 1
        }

        return try accounts.map { account in
            let id = try account.requireID()
            return AdminAccount(
                id: id,
                createdAt: account.createdAt,
                userCount: usersPerAccount[id] ?? 0,
                deviceCount: devicesPerAccount[id] ?? 0,
                unlimited: account.unlimitedCredits,
                monthlyCostCapMicros: account.monthlyCostCapMicros.map(Int.init)
            )
        }
    }

    /// The owner's switch. Stored now and read by nothing until credits exist.
    admin.post("accounts", ":accountID", "credits") { req async throws -> AdminAccount in
        guard let id = req.parameters.get("accountID", as: UUID.self) else { throw Abort(.badRequest) }
        let body = try req.content.decode(SetAccountCredits.self)
        if let cap = body.monthlyCostCapMicros, cap < 0 {
            throw Abort(.badRequest, reason: "monthlyCostCapMicros cannot be negative")
        }
        guard let account = try await AccountModel.find(id, on: req.db) else { throw Abort(.notFound) }
        account.unlimitedCredits = body.unlimited
        account.monthlyCostCapMicros = body.monthlyCostCapMicros.map(Int64.init)
        try await account.save(on: req.db)

        let users = try await UserModel.query(on: req.db).filter(\.$account.$id == id).all()
        let userIDs = try users.map { try $0.requireID() }
        let devices = userIDs.isEmpty ? 0 : try await DeviceModel.query(on: req.db)
            .filter(\.$user.$id ~~ userIDs)
            .count()
        return AdminAccount(
            id: id,
            createdAt: account.createdAt,
            userCount: users.count,
            deviceCount: devices,
            unlimited: account.unlimitedCredits,
            monthlyCostCapMicros: account.monthlyCostCapMicros.map(Int.init)
        )
    }
}

// ProfileRoutes.swift
// The people on an account: list, add, rename, switch alerts, delete.
//
// A profile is one `users` row under the account, so everything a profile *has* — follows,
// watches, poll hints, sizes — is reached by the routes that already exist, acting for it
// through `X-Profile-ID` (`ActingProfile`). These routes only manage the rows themselves, and
// they act on the device's account: the header, if sent, is checked like anywhere else and
// then ignored. See `docs/profiles.md`.
//
// All of it needs an account. A device that never signed in has exactly one implicit profile,
// which is its own anonymous user, and these routes answer 404 for it as `DELETE /v1/account`
// does.

import Fluent
import Foundation
import StreetwCore
import Vapor

extension ProfileDTO: @retroactive Content {}
extension CreateProfile: @retroactive Content {}
extension UpdateProfile: @retroactive Content {}

extension ProfileDTO {
    init(_ user: UserModel, holderID: UUID) throws {
        let id = try user.requireID()
        self.init(
            id: id,
            name: user.displayName,
            isHolder: id == holderID,
            alertsEnabled: user.alertsEnabled,
            createdAt: user.createdAt
        )
    }
}

func profileRoutes(authed: any RoutesBuilder) {
    /// The device's account, its users holder first, and the holder's id — or a 404 for a
    /// device that is not signed in.
    @Sendable func account(of req: Request) async throws -> (accountID: UUID, users: [UserModel], holderID: UUID) {
        let device = try await req.authenticatedDevice()
        guard let own = try await UserModel.find(device.$user.id, on: req.db),
              let accountID = own.$account.id
        else { throw Abort(.notFound, reason: "Profiles need an account. Sign in first.") }
        let users = try await Accounts.profiles(of: accountID, on: req.db)
        guard let holder = users.first else { throw Abort(.notFound) }
        return (accountID, users, try holder.requireID())
    }

    @Sendable func profile(_ req: Request, in users: [UserModel]) throws -> UserModel {
        guard let id = req.parameters.get("profileID", as: UUID.self) else { throw Abort(.badRequest) }
        // Looked up among the account's own users, so an id from another account is a 404
        // rather than a way to find out whether it exists.
        guard let user = users.first(where: { $0.id == id }) else {
            throw Abort(.notFound, reason: "No profile with that id on this account.")
        }
        return user
    }

    authed.get("account", "profiles") { req async throws -> [ProfileDTO] in
        let (_, users, holderID) = try await account(of: req)
        return try users.map { try ProfileDTO($0, holderID: holderID) }
    }

    /// A name and nothing else. The new profile starts as an anonymous user does — no follows,
    /// no sizes, alerts on — and is set up from inside it.
    authed.post("account", "profiles") { req async throws -> ProfileDTO in
        let (accountID, users, holderID) = try await account(of: req)
        let body = try req.content.decode(CreateProfile.self)
        guard let name = ProfileNaming.clean(body.name) else {
            throw Abort(.badRequest, reason: "A profile needs a name.")
        }
        guard users.count < Profiles.maxPerAccount else {
            throw Abort(.conflict, reason: "An account holds at most \(Profiles.maxPerAccount) profiles.")
        }
        let user = UserModel()
        user.$account.id = accountID
        user.displayName = name
        // The account's location, which every profile shares — see `Accounts.setCountry`.
        user.country = users.first?.country
        try await user.save(on: req.db)
        return try ProfileDTO(user, holderID: holderID)
    }

    /// Rename, or switch the profile's alerts. Only what was sent changes, and a write that
    /// would change nothing is not made.
    authed.patch("account", "profiles", ":profileID") { req async throws -> ProfileDTO in
        let (_, users, holderID) = try await account(of: req)
        let user = try profile(req, in: users)
        let body = try req.content.decode(UpdateProfile.self)

        var changed = false
        if let raw = body.name {
            // The holder may clear their name — they are "You" without one. Anybody else may
            // not: their name is what labels their alerts.
            let name = ProfileNaming.clean(raw)
            if name == nil, user.id != holderID {
                throw Abort(.badRequest, reason: "A profile needs a name.")
            }
            if user.displayName != name {
                user.displayName = name
                changed = true
            }
        }
        if let enabled = body.alertsEnabled, user.alertsEnabled != enabled {
            user.alertsEnabled = enabled
            changed = true
        }
        if changed { try await user.save(on: req.db) }
        return try ProfileDTO(user, holderID: holderID)
    }

    /// Deletes a profile and its follows, watches and poll hints. The holder's own profile
    /// goes only with the account — `DELETE /v1/account` — because the account *is* that
    /// person, and an account with no holder would have nobody for the next sign-in to merge
    /// into.
    authed.delete("account", "profiles", ":profileID") { req async throws -> HTTPStatus in
        let (_, users, holderID) = try await account(of: req)
        let user = try profile(req, in: users)
        guard user.id != holderID else {
            throw Abort(.conflict, reason: "Your own profile goes only with your account.")
        }
        guard let holder = users.first else { throw Abort(.notFound) }
        try await Accounts.deleteProfile(user, holder: holder, on: req.db)
        return .noContent
    }
}

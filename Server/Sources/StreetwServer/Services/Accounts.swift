// Accounts.swift
// Signing in moves a device onto an account; deleting one takes everything personal with it.
//
// Both are one transaction. A sign-in that moved the device and then failed halfway through
// the merge would leave somebody's follows split between two users, one of them about to be
// deleted; a deletion that stopped halfway would leave a person's watches firing at a device
// whose account no longer exists. Neither is something a retry can see, let alone repair.
//
// **The catalogue is never touched.** Everything here is a row under `users` — devices,
// follows, watches, poll hints, brand-check watchers — and the account itself. A brand
// somebody added stays added for everybody else who follows it.

import Fluent
import Foundation
import StreetwCore

enum Accounts {
    struct SignInResult {
        var account: AccountModel
        var user: UserModel
        var isNew: Bool
        var merged: Bool
    }

    /// Puts `device` under the account for `subject`, making the account if there is none.
    ///
    /// Four cases, decided by what the account and the device each already have:
    ///
    /// - **The account has no user** (first sign-in): the device's own user becomes the
    ///   account's. Nothing moves; it is the same person with a name on them now.
    /// - **The account has a user and the device's user is anonymous** (the reinstall, the
    ///   second phone): the device moves onto the account's user and its anonymous user is
    ///   folded in — see `merge` — and then deleted.
    /// - **The device already belongs to this account**: nothing to do.
    /// - **The device belongs to a different account** (signed in as one person, now as
    ///   another): the device moves, and its old user stays where it is — it is the other
    ///   account's data, and folding it into this one would hand one person's follows to
    ///   somebody else. If this account had no user yet, it gets a fresh one with the
    ///   device's sizes, since those are about whoever is holding the phone.
    static func signIn(subject: String, device: DeviceModel, on db: any Database) async throws -> SignInResult {
        try await db.transaction { db in
            var isNew = false
            let account: AccountModel
            if let existing = try await AccountModel.query(on: db).filter(\.$appleSubject == subject).first() {
                account = existing
            } else {
                account = AccountModel(appleSubject: subject)
                try await account.save(on: db)
                isNew = true
            }
            let accountID = try account.requireID()

            let current = try await UserModel.find(device.$user.id, on: db)
            guard let current else { throw AccountError.noUser }

            if current.$account.id == accountID {
                return SignInResult(account: account, user: current, isNew: isNew, merged: false)
            }

            let target = try await primaryUser(of: accountID, on: db)

            switch (target, current.$account.id) {
            case (nil, nil):
                current.$account.id = accountID
                try await current.save(on: db)
                return SignInResult(account: account, user: current, isNew: isNew, merged: false)

            case (let target?, nil):
                try await merge(current, into: target, on: db)
                // The merge moved the row; the caller still holds this instance.
                device.$user.id = try target.requireID()
                return SignInResult(account: account, user: target, isNew: isNew, merged: true)

            case (nil, _?):
                let fresh = UserModel()
                fresh.sizeProfile = current.sizeProfile
                fresh.$account.id = accountID
                try await fresh.save(on: db)
                device.$user.id = try fresh.requireID()
                try await device.save(on: db)
                return SignInResult(account: account, user: fresh, isNew: isNew, merged: false)

            case (let target?, _?):
                device.$user.id = try target.requireID()
                try await device.save(on: db)
                return SignInResult(account: account, user: target, isNew: isNew, merged: false)
            }
        }
    }

    /// The account's user. Oldest first, so the answer stays put when profiles arrive and
    /// an account holds several — the first user is the one the account was made from.
    static func primaryUser(of accountID: UUID, on db: any Database) async throws -> UserModel? {
        try await UserModel.query(on: db)
            .filter(\.$account.$id == accountID)
            .sort(\.$createdAt, .ascending)
            .first()
    }

    /// Folds an anonymous user into an account's user, then deletes it.
    ///
    /// - **Devices** all move: an anonymous user is one install, and every device row it has
    ///   is that install.
    /// - **Follows** are a union. Where both follow a brand the account's mode wins — it is
    ///   the older, deliberate choice, and the anonymous one is usually a starter-pack default.
    /// - **Watches** are a union on (product, size, colour), the same identity the table's
    ///   unique constraint uses. Compared in Swift because that constraint cannot see two
    ///   NULLs as equal, and "any size" is a NULL.
    /// - **Poll hints** and **brand-check watchers** move where the account has none for that
    ///   brand or check; their unique constraints allow one each.
    /// - **Sizes**, per ladder: the account's where it set that ladder, else the device's. A
    ///   reinstall has an empty profile and must not erase the one the account kept, and a
    ///   second phone with a waist entered should not lose it to an account that never had one.
    ///
    /// Must run inside a transaction; `signIn` provides it.
    static func merge(_ anonymous: UserModel, into target: UserModel, on db: any Database) async throws {
        let fromID = try anonymous.requireID()
        let toID = try target.requireID()

        try await DeviceModel.query(on: db)
            .filter(\.$user.$id == fromID)
            .set(\.$user.$id, to: toID)
            .update()

        let followed = Set(try await FollowModel.query(on: db).filter(\.$user.$id == toID).all().map(\.$brand.id))
        for follow in try await FollowModel.query(on: db).filter(\.$user.$id == fromID).all() {
            if followed.contains(follow.$brand.id) {
                try await follow.delete(on: db)
            } else {
                follow.$user.id = toID
                try await follow.save(on: db)
            }
        }

        struct WatchKey: Hashable { var product: UUID; var size: String?; var color: String? }
        let watched = Set(try await WatchModel.query(on: db).filter(\.$user.$id == toID).all().map {
            WatchKey(product: $0.$product.id, size: $0.size, color: $0.color)
        })
        for watch in try await WatchModel.query(on: db).filter(\.$user.$id == fromID).all() {
            if watched.contains(WatchKey(product: watch.$product.id, size: watch.size, color: watch.color)) {
                try await watch.delete(on: db)
            } else {
                watch.$user.id = toID
                try await watch.save(on: db)
            }
        }

        let hinted = Set(try await PollHintModel.query(on: db).filter(\.$user.$id == toID).all().map(\.$brand.id))
        for hint in try await PollHintModel.query(on: db).filter(\.$user.$id == fromID).all() {
            if hinted.contains(hint.$brand.id) {
                try await hint.delete(on: db)
            } else {
                hint.$user.id = toID
                try await hint.save(on: db)
            }
        }

        let waiting = Set(try await BrandCheckWatcherModel.query(on: db).filter(\.$user.$id == toID).all().map(\.$check.id))
        for watcher in try await BrandCheckWatcherModel.query(on: db).filter(\.$user.$id == fromID).all() {
            if waiting.contains(watcher.$check.id) {
                try await watcher.delete(on: db)
            } else {
                watcher.$user.id = toID
                try await watcher.save(on: db)
            }
        }

        target.sizeProfile = mergedSizes(account: target.sizeProfile, device: anonymous.sizeProfile)
        // The same rule as a ladder: the account's country where it has one. Without it a
        // reinstall in another country would serve the account the main shop until the app's
        // next sizes push — and the reinstall's own guess is the phone's region, not a choice.
        if target.country == nil { target.country = anonymous.country }
        try await target.save(on: db)

        try await anonymous.delete(on: db)
    }

    /// Per ladder, the account's where set, else the device's. The display scales are not
    /// stored server-side and come back as defaults either way.
    static func mergedSizes(account: SizeProfile, device: SizeProfile) -> SizeProfile {
        var merged = account
        if merged.apparel.isEmpty { merged.apparel = device.apparel }
        if merged.shoe.isEmpty { merged.shoe = device.shoe }
        if merged.waist.isEmpty { merged.waist = device.waist }
        if merged.dress.isEmpty { merged.dress = device.dress }
        if merged.suit.isEmpty { merged.suit = device.suit }
        if merged.suitLength.isEmpty { merged.suitLength = device.suitLength }
        // "Everything" is the default and the reading of somebody who never chose, so it is
        // the gender filter's "not set".
        if merged.gender == .everything { merged.gender = device.gender }
        return merged
    }

    /// Deletes the account and every personal row under it, in one transaction.
    ///
    /// Each table is deleted explicitly rather than left to `ON DELETE CASCADE`: the cascade
    /// is the guard for a later writer, and this is the promise — it must not depend on a
    /// SQLite connection having switched foreign keys on.
    ///
    /// - Returns: the refresh token to revoke, read before the row went. The caller revokes
    ///   it; Apple being unreachable must not keep somebody's data on this server.
    static func delete(_ account: AccountModel, on db: any Database) async throws -> String? {
        let refreshToken = account.appleRefreshToken
        let accountID = try account.requireID()
        try await db.transaction { db in
            let users = try await UserModel.query(on: db).filter(\.$account.$id == accountID).all()
            let ids = try users.map { try $0.requireID() }
            if !ids.isEmpty {
                try await PollHintModel.query(on: db).filter(\.$user.$id ~~ ids).delete()
                try await WatchModel.query(on: db).filter(\.$user.$id ~~ ids).delete()
                try await FollowModel.query(on: db).filter(\.$user.$id ~~ ids).delete()
                try await BrandCheckWatcherModel.query(on: db).filter(\.$user.$id ~~ ids).delete()
                try await DeviceModel.query(on: db).filter(\.$user.$id ~~ ids).delete()
                try await UserModel.query(on: db).filter(\.$id ~~ ids).delete()
            }
            try await account.delete(on: db)
        }
        return refreshToken
    }
}

enum AccountError: Error {
    case noUser
}

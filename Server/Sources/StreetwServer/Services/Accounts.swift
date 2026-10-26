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
import SQLKit
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
        let (account, isNew) = try await findOrCreate(subject: subject, on: db)
        let accountID = try account.requireID()
        return try await db.transaction { db in
            // **One sign-in per account at a time.** Two first sign-ins for one Apple ID — two
            // phones, or one phone tapping twice — both found the account without a user, both
            // adopted their own, and the account came out holding two users: a holder and a
            // nameless profile nobody made. With the row locked, the second waits, then finds
            // the first's user and merges into it. Postgres only; SQLite takes a database-wide
            // lock on the first write, which is the same serialisation, coarser.
            if let sql = db as? any SQLDatabase, sql.dialect.name == "postgresql" {
                try await sql.raw("SELECT id FROM accounts WHERE id = \(bind: accountID) FOR UPDATE").run()
            }

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
                // Where the phone is, like its sizes: this account has nobody yet to disagree.
                fresh.country = current.country
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

    /// The account for `subject`, made if there is none — outside the sign-in's transaction,
    /// so a lost race can be answered by looking again.
    ///
    /// **Two first sign-ins for one Apple ID used to be a 500.** Both looked, found nothing,
    /// and inserted; the second insert hit the unique constraint on `apple_subject`, which is
    /// not an `AbortError`, and the person was told "Something went wrong" for doing nothing
    /// wrong. Inside the transaction the only answer would have been to fail it — Postgres
    /// refuses every statement after an error until the transaction ends — so the account is
    /// settled first, on its own, and the loser of the race reads the winner's row.
    ///
    /// Made before the merge commits, so a merge that then fails leaves an account with no
    /// user. That is harmless: the next sign-in finds it and adopts the device's user, which
    /// is exactly what the failed one would have done.
    ///
    /// - Parameter racing: a test seam, run between the miss and the insert, which is where
    ///   the other sign-in lands in the race this exists for.
    static func findOrCreate(
        subject: String,
        on db: any Database,
        racing: (@Sendable () async throws -> Void)? = nil
    ) async throws -> (account: AccountModel, isNew: Bool) {
        if let existing = try await AccountModel.query(on: db).filter(\.$appleSubject == subject).first() {
            return (existing, false)
        }
        try await racing?()
        let account = AccountModel(appleSubject: subject)
        do {
            try await account.save(on: db)
            return (account, true)
        } catch where (error as? any DatabaseError)?.isConstraintFailure == true {
            guard let winner = try await AccountModel.query(on: db).filter(\.$appleSubject == subject).first() else {
                throw error
            }
            return (winner, false)
        }
    }

    /// The account's own user — its holder. Oldest first, ties broken by id, so the answer
    /// never moves once an account holds several: the first user is the one the account was
    /// made from, and every later one is a profile. See `docs/profiles.md`.
    static func primaryUser(of accountID: UUID, on db: any Database) async throws -> UserModel? {
        try await profiles(of: accountID, on: db).first
    }

    /// `primaryUser`'s order, for a list already in hand: oldest first, then by id.
    static func holderFirst(_ a: UserModel, _ b: UserModel) -> Bool {
        let left = (a.createdAt ?? .distantPast, a.id?.uuidString ?? "")
        let right = (b.createdAt ?? .distantPast, b.id?.uuidString ?? "")
        return left < right
    }

    /// The user whose account-wide settings apply to `user`: the holder for anybody on an
    /// account, the user itself for an anonymous one.
    static func holder(of user: UserModel, on db: any Database) async throws -> UserModel {
        guard let accountID = user.$account.id,
              let holder = try await primaryUser(of: accountID, on: db)
        else { return user }
        return holder
    }

    /// Sets the country of `user` — and, for a user on an account, of every profile on it.
    ///
    /// **Location is the account's.** A profile is somebody you shop *for*, and the shop is
    /// still in the holder's country (`ROADMAP.md`: profiles share the account, the credits and
    /// the location). So whichever profile's phone says where it is, the whole account moves.
    ///
    /// **Copied onto every user of the account rather than looked up through the holder**, and
    /// this is the only writer for a user on an account. `users.country` has three readers that
    /// matter — `Storefronts.wanted`, a join from follows to users evaluated in SQL every tick;
    /// `Storefronts.serving` for every feed, brand page, Discover page and `BrandDTO`; and
    /// `Notifier` per recipient — and routing each through the account's oldest user would add a
    /// join to all three, where one missed reader serves a profile the main shop or leaves a
    /// country's shop unpolled for a profile that follows it. There are only three writers: this,
    /// registration (an anonymous user, with no account to share) and the sign-in merge, which
    /// calls this. A profile is made with its holder's country (`ProfileRoutes`).
    static func setCountry(_ country: String?, for user: UserModel, on db: any Database) async throws {
        guard let accountID = user.$account.id else {
            if user.country != country {
                user.country = country
                try await user.save(on: db)
            }
            return
        }
        // Compared in Swift and saved only where it differs: this runs on the first call of
        // every launch, and a rewrite that changes nothing is the volume problem
        // `Poller.refresh` guards against. (A filter on `country != X` would skip NULL rows.)
        user.country = country
        for member in try await UserModel.query(on: db).filter(\.$account.$id == accountID).all()
        where member.country != country {
            member.country = country
            try await member.save(on: db)
        }
    }

    /// The account's profiles, holder first. Ordered in Swift by `holderFirst`, so the notifier,
    /// which orders a list it already holds, can never disagree with this about who the holder
    /// is; an account holds at most `Profiles.maxPerAccount` rows.
    static func profiles(of accountID: UUID, on db: any Database) async throws -> [UserModel] {
        try await UserModel.query(on: db)
            .filter(\.$account.$id == accountID)
            .all()
            .sorted(by: holderFirst)
    }

    /// Deletes one profile and everything personal under it, in one transaction. Never the
    /// holder — the route refuses that — and never the catalogue.
    ///
    /// Each table explicitly, as `delete` does, so the promise does not rest on SQLite having
    /// foreign keys switched on. A device hanging off the profile is moved to the holder rather
    /// than deleted: devices belong to the holder by construction, and if one does not, it is
    /// still a phone somebody is holding.
    static func deleteProfile(_ profile: UserModel, holder: UserModel, on db: any Database) async throws {
        let id = try profile.requireID()
        let holderID = try holder.requireID()
        try await db.transaction { db in
            try await PollHintModel.query(on: db).filter(\.$user.$id == id).delete()
            try await WatchModel.query(on: db).filter(\.$user.$id == id).delete()
            try await FollowModel.query(on: db).filter(\.$user.$id == id).delete()
            try await BrandCheckWatcherModel.query(on: db).filter(\.$user.$id == id).delete()
            try await DeviceModel.query(on: db)
                .filter(\.$user.$id == id)
                .set(\.$user.$id, to: holderID)
                .update()
            try await UserModel.query(on: db).filter(\.$id == id).delete()
        }
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
        let country = target.country ?? anonymous.country
        try await target.save(on: db)
        // Through the one writer, so the account's profiles move with the holder.
        try await setCountry(country, for: target, on: db)

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

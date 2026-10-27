// Profiles.swift
// Who the app is acting for, and the one store, set of keys and set of objects that person has.
//
// **A store per profile, swapped at the root — not a profile id on every model.** Tagging would
// need a predicate on every `@Query` and every `TasteScope` consumer, and a missed one would not
// crash: it would put one person's saves into another's taste. A store makes the partition a
// property of the container, which no query can forget. The holder's store is `default.store`
// and their keys are the unscoped ones, so an install from before profiles needs no migration —
// its data simply *is* the holder's profile. See `docs/profiles.md`.

import Foundation
import OSLog
import StreetwCore
import SwiftData
import SwiftUI

/// Who the app is acting for: the holder — and every install that never signed in — or one
/// profile on the account.
struct ProfileScope: Hashable, Sendable {
    /// The profile's server user id; nil for the holder, who sends no header.
    let id: UUID?
    /// Printed on this profile's local alerts. Nil for the holder, whose alerts are unlabelled.
    let name: String?
    /// Where this person's data lives on the phone. Nil is `default.store` and the unscoped
    /// keys — the phone's own, used signed out and kept by the first account to sign in
    /// (`ProfileStores.owner`). Otherwise a profile's user id, or, for the holder of an account
    /// that does not own `default.store`, the account's id.
    let home: UUID?
    /// The account `home` is filed under. Nil with it: `default.store` is not in any account's
    /// directory, whoever owns it.
    let account: UUID?

    /// The phone's store: signed out, and the holder of the account that owns it.
    static let holder = ProfileScope(id: nil, name: nil, home: nil, account: nil)

    /// A profile that is not the holder's.
    static func profile(_ id: UUID, name: String?, account: UUID) -> ProfileScope {
        ProfileScope(id: id, name: name, home: id, account: account)
    }

    /// The holder of an account that found `default.store` already somebody else's: a store
    /// of its own, under the account's id.
    static func ownHolder(of account: UUID) -> ProfileScope {
        ProfileScope(id: nil, name: nil, home: account, account: account)
    }

    var isHolder: Bool { id == nil }

    /// A `UserDefaults` key for this person: the key itself for the phone's store, so nothing
    /// an install already wrote moves, and `<key>.<home>` for any other.
    func key(_ base: String) -> String {
        home.map { "\(base).\($0.uuidString)" } ?? base
    }

    /// The phone's store is the one 1.0 and 1.1 wrote, at the path `streetwApp` has always
    /// pinned; every other is in its account's directory. See `ProfileStores`.
    var storeURL: URL {
        ProfileStores.url(home: home, account: account)
    }

    /// A local alert's body as this profile's — "For Anna: …" — or as it was, for the holder.
    func labelled(_ body: String) -> String {
        guard let name else { return body }
        return ProfileAlert.labelled(body, for: name)
    }

    /// The scope the app is acting for now. Read by the short, synchronous lookups that run
    /// inside one view's lifetime (Shop's picks, the feed's visit line, the starter-pack latch),
    /// which a switch rebuilds anyway. Anything that awaits keeps the scope it started with.
    @MainActor static var active = ProfileScope.holder

    /// Every store this phone holds, by `home`, whichever account it is filed under. The share
    /// inbox uses it to tell a share for a store that is not current — another profile, or an
    /// account that is not signed in — from one for a store that is gone.
    @MainActor static var known: Set<UUID> = []

    /// Every `UserDefaults` key that describes a person rather than the phone. A new one goes
    /// here or is the phone's — there is no third kind — and deleting a profile clears these.
    /// The phone's: the server address, token and account, `didRegisterAfresh`, the usage
    /// tally, the saved-price-drop setting and every dev flag — and the account's, which every
    /// profile shares: the location (`LocationSetting`).
    static let scopedKeys = [
        "sizeProfile", "styleStatement", "feedCursor", "feedPendingReads", "pendingUnfollows",
        "pendingWatchDeletes", "discoverSeen", "shopPicksToday", "shopPicksRefused",
        "shopPickReasons", "shopPicksAnnounced",
        "feedLastOnScreenAt", "feedVisitBoundary", "pollHintsFingerprint", "pollHintState",
        "didOfferStarterPack"
    ]
}

/// Where each account's stores sit on the phone, and who owns the phone's own.
///
/// **Filed by account, and hidden rather than deleted when another account signs in.** A
/// profile's store is `Accounts/<account>/profile-<id>.store`; the holder of an account that
/// did not get `default.store` has `Accounts/<account>/holder.store`. Signing into a second
/// Apple ID used to prune the first one's profile stores the moment its list arrived — the
/// first account's saves, boards and fits gone from the phone for good, for signing in. Now
/// they wait in their directory and come back with the account. See `docs/profiles.md`.
enum ProfileStores {
    private static let log = Logger(subsystem: "com.kern.functional.streetw", category: "profiles")
    private static let ownerKey = "defaultStoreAccount"

    /// The account `default.store` belongs to: whichever first signed in on this phone. Nil
    /// until then — that store is the signed-out phone's, and the first account takes it.
    static var owner: UUID? {
        get { UserDefaults.standard.string(forKey: ownerKey).flatMap(UUID.init(uuidString:)) }
        set { UserDefaults.standard.set(newValue?.uuidString, forKey: ownerKey) }
    }

    private static var root: URL { URL.applicationSupportDirectory }
    private static var accountsDirectory: URL { root.appending(path: "Accounts", directoryHint: .isDirectory) }

    static func directory(for account: UUID) -> URL {
        accountsDirectory.appending(path: account.uuidString, directoryHint: .isDirectory)
    }

    static func url(home: UUID?, account: UUID?) -> URL {
        guard let home else { return root.appending(path: "default.store") }
        // Only a store from before stores were filed by account has no account.
        guard let account else { return root.appending(path: "profile-\(home.uuidString).store") }
        let file = home == account ? "holder.store" : "profile-\(home.uuidString).store"
        return directory(for: account).appending(path: file)
    }

    /// SwiftData's own directory is made for it; an account's is not.
    static func prepare(_ scope: ProfileScope) {
        guard let account = scope.account else { return }
        try? FileManager.default.createDirectory(at: directory(for: account), withIntermediateDirectories: true)
    }

    // MARK: - Reading the disk

    /// Not `path()`, which percent-encodes: "Application Support" became
    /// "Application%20Support", the listing failed, and no store was ever found.
    private static func files(in directory: URL) -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: directory.path(percentEncoded: false))) ?? []
    }

    /// Every account with a directory of stores here.
    static func accounts() -> Set<UUID> {
        Set(files(in: accountsDirectory).compactMap(UUID.init(uuidString:)))
    }

    /// The homes filed under `account`: its profiles, and its own holder store if it has one.
    static func homes(in account: UUID) -> Set<UUID> {
        var homes: Set<UUID> = []
        for file in files(in: directory(for: account)) where file.hasSuffix(".store") {
            if file == "holder.store" {
                homes.insert(account)
            } else if let id = profileID(in: file) {
                homes.insert(id)
            }
        }
        return homes
    }

    /// Profile stores from before they were filed by account, still beside `default.store`.
    static func legacyHomes() -> Set<UUID> {
        Set(files(in: root).filter { $0.hasSuffix(".store") }.compactMap(profileID(in:)))
    }

    static func allHomes() -> Set<UUID> {
        accounts().reduce(into: legacyHomes()) { $0.formUnion(homes(in: $1)) }
    }

    private static func profileID(in file: String) -> UUID? {
        guard file.hasPrefix("profile-") else { return nil }
        return UUID(uuidString: String(file.dropFirst("profile-".count).prefix(36)))
    }

    // MARK: - Changing the disk

    /// Files the stores of `ids` that were written before stores were filed by account under
    /// `account` — the account whose list names them, which is the only evidence of whose they
    /// were. One that no list names stays where it is until Remove takes it.
    static func adoptLegacy(_ ids: Set<UUID>, into account: UUID) {
        let legacy = legacyHomes().intersection(ids)
        guard !legacy.isEmpty else { return }
        let target = directory(for: account)
        try? FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        for file in files(in: root) {
            guard let id = profileID(in: file), legacy.contains(id) else { continue }
            try? FileManager.default.moveItem(at: root.appending(path: file), to: target.appending(path: file))
        }
        log.notice("filed \(legacy.count) profile store(s) under their account")
    }

    /// Deletes one home's store — the file and SQLite's `-wal` and `-shm` beside it — and its
    /// scoped keys.
    static func remove(_ scope: ProfileScope) {
        let url = scope.storeURL
        let directory = url.deletingLastPathComponent()
        let name = url.lastPathComponent
        for file in files(in: directory) where file.hasPrefix(name) {
            try? FileManager.default.removeItem(at: directory.appending(path: file))
        }
        for key in ProfileScope.scopedKeys {
            UserDefaults.standard.removeObject(forKey: scope.key(key))
        }
    }

    /// Deletes everything filed under `account`.
    static func removeAccount(_ account: UUID) {
        for home in homes(in: account) {
            remove(ProfileScope(id: nil, name: nil, home: home, account: account))
        }
        try? FileManager.default.removeItem(at: directory(for: account))
        log.notice("removed an account's stores from this phone")
    }
}

/// Everything that is about one person, built together and thrown away together.
///
/// **A switch builds a new session; it never resets the old one.** Resetting nine objects by
/// hand is nine chances to leave one person's state on another's page. An in-flight sync of
/// the old session finishes against the old session's own context, keys and header, so it
/// lands where it started.
@MainActor
final class ProfileSession {
    let scope: ProfileScope
    let container: ModelContainer
    let sizes: SizeProfileStore
    let statement: StyleStatementStore
    let remote: RemoteSync
    let engine: SyncEngine
    let suggestions: BrandSuggestions
    let deck: DiscoverDeck
    let confirmation: SaveConfirmation
    let collection: CollectionRoute
    let hints: DropHintStore

    init(scope: ProfileScope, container: ModelContainer, settings: ServerSettings, location: LocationSetting) {
        self.scope = scope
        self.container = container
        sizes = SizeProfileStore(scope: scope)
        statement = StyleStatementStore(scope: scope)
        remote = RemoteSync(context: container.mainContext, settings: settings, location: location, scope: scope)
        engine = SyncEngine(context: container.mainContext)
        suggestions = BrandSuggestions(remote: remote, settings: settings)
        deck = DiscoverDeck(scope: scope)
        confirmation = SaveConfirmation()
        collection = CollectionRoute()
        hints = DropHintStore(scope: scope)
    }

    static let schema = Schema([
        Brand.self, BrandUpdate.self, SavedItem.self, Board.self, StockWatch.self, Fit.self,
        BrandDismissal.self, PlannedDrop.self
    ])

    /// Opens the store for `scope`.
    ///
    /// The location is pinned explicitly, and that is load-bearing. A default
    /// `ModelConfiguration` picks its own location — and once the app gained an App Group
    /// entitlement (for the share extension), SwiftData started placing the store in the
    /// *shared group container* instead of the app's own. The app then opened an empty database
    /// and every brand and save appeared to have been wiped, while the real data sat untouched
    /// in the old location. Naming the URL keeps existing installs pointed at their data, and
    /// stops an unrelated capability from silently moving the database again.
    static func container(for scope: ProfileScope) throws -> ModelContainer {
        ProfileStores.prepare(scope)
        let container = try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(schema: schema, url: scope.storeURL)]
        )
        // Before any view exists, so nothing ever draws a board with half its saves still
        // filed the 1.0 way, and the 1.0 unread queue becomes the feed's news before the feed
        // first draws. Both do nothing once a store has been through them — which a profile's
        // store, made after both existed, always has. See `BoardFiling` and `FeedHistory`.
        BoardFiling.adoptLegacy(in: container.mainContext)
        FeedHistory.adoptLegacy(in: container.mainContext)
        return container
    }
}

/// One profile's store and sync, without the rest of a session — what a background pass needs
/// to bring a profile that is not on screen up to date.
@MainActor
struct ProfileSyncer {
    let scope: ProfileScope
    let remote: RemoteSync
    let sizes: SizeProfileStore
    let context: ModelContext
}

/// The account's profiles, which one is current, and switching between them.
@MainActor
@Observable
final class ProfileStore {
    private static let log = Logger(subsystem: "com.kern.functional.streetw", category: "profiles")
    private static let currentKey = "currentProfile"
    private static let listKey = "profiles"
    /// Which account the cached list is of, so a launch signed into another one never draws
    /// the previous account's profiles while its own list is on the way.
    private static let listAccountKey = "profilesAccount"

    /// The account's profiles, holder first, as the server last said. Empty when the device is
    /// not signed in — which is the implicit single profile, and draws nothing about profiles.
    private(set) var profiles: [ProfileDTO] = []
    private(set) var session: ProfileSession
    private(set) var isWorking = false
    var failure: String?
    /// Whether this phone keeps stores of an Apple ID other than the one it is showing —
    /// what You's Remove row is drawn on.
    private(set) var holdsOtherAccounts = false

    private let settings: ServerSettings
    /// The account's country, shared by every session — see `streetwApp.location`.
    private let location: LocationSetting
    /// Where a switch has to be announced: the app delegate's registry and the usage counts
    /// both hold the session's `RemoteSync`.
    private let installed: (ProfileSession) -> Void

    init(settings: ServerSettings, location: LocationSetting, installed: @escaping (ProfileSession) -> Void) {
        self.settings = settings
        self.location = location
        self.installed = installed

        // **A remembered profile counts only while it can work**: signed in, against a server,
        // and still in the list. Anything else is the holder — so `-standalone YES`, a signed-out
        // install and an older server all behave exactly as they did before profiles.
        let account = Self.signedIn(settings)
        let cachedFor = UserDefaults.standard.string(forKey: Self.listAccountKey).flatMap(UUID.init(uuidString:))
        let cached = UserDefaults.standard.data(forKey: Self.listKey)
            .flatMap { try? JSONDecoder().decode([ProfileDTO].self, from: $0) } ?? []
        // A list written before it was stamped with its account is the signed-in one's: until
        // now nothing else could have written it.
        let list = account != nil && (cachedFor == nil || cachedFor == account) ? cached : []
        profiles = list
        if let account {
            ProfileStores.adoptLegacy(Set(list.map(\.id)), into: account)
            Self.claimDefaultStore(for: account)
        }
        let holder = Self.holderScope(for: account)
        let stored = UserDefaults.standard.string(forKey: Self.currentKey).flatMap(UUID.init(uuidString:))
        let scope = account.flatMap { account in
            stored
                .flatMap { id in list.first { $0.id == id && !$0.isHolder } }
                .map { ProfileScope.profile($0.id, name: $0.name, account: account) }
        } ?? holder

        var opened = scope
        let container: ModelContainer
        do {
            container = try ProfileSession.container(for: scope)
        } catch {
            // A profile's store that will not open is not a reason to take the app down; the
            // holder's is, exactly as before profiles.
            Self.log.error("could not open the store for a profile: \(error.localizedDescription)")
            do {
                opened = holder
                container = try ProfileSession.container(for: holder)
            } catch {
                fatalError("Could not create ModelContainer: \(error)")
            }
        }
        session = ProfileSession(scope: opened, container: container, settings: settings, location: location)
        containers[opened.storeURL] = container
        ProfileScope.known = ProfileStores.allHomes()
        listedFor = list.isEmpty ? nil : account
        adopt(session)
        noteOtherAccounts()
        // After the first view update rather than inside whatever set the account — a sync's
        // registration, a sign-in — so the switch never lands halfway through a property write.
        settings.accountChanged = { [weak self] in
            Task { @MainActor in self?.accountDidChange() }
        }
    }

    /// Which account `profiles` is the list of.
    @ObservationIgnored private var listedFor: UUID?

    /// The phone is on a different account, or on none: another account's list is not this
    /// one's, and the store on screen may not be one it can see.
    private func accountDidChange() {
        if !profiles.isEmpty, listedFor != account { setList([], for: nil) }
        settle()
    }

    var current: ProfileScope { session.scope }

    /// The holder's own row, when signed in.
    var holder: ProfileDTO? { profiles.first(where: \.isHolder) }

    /// The account this phone is signed into, when it is one that can have profiles.
    private var account: UUID? { Self.signedIn(settings) }

    private static func signedIn(_ settings: ServerSettings) -> UUID? {
        settings.isConfigured ? settings.account?.id : nil
    }

    private var api: StreetwAPI? {
        guard let baseURL = settings.baseURL, settings.token != nil else { return nil }
        // No profile header: these routes are about the account, and a stale header would
        // refuse the very list that says the profile is gone.
        return StreetwAPI(baseURL: baseURL, token: settings.token)
    }

    // MARK: - Whose store

    /// The holder's store for `account`: the phone's own when the account owns it — and
    /// signed out — and the account's own otherwise. See `ProfileStores.owner`.
    static func holderScope(for account: UUID?) -> ProfileScope {
        guard let account else { return .holder }
        if let owner = ProfileStores.owner { return owner == account ? .holder : .ownHolder(of: account) }
        // Unowned — Remove took the other account's — but this account already has its own.
        return ProfileStores.homes(in: account).contains(account) ? .ownHolder(of: account) : .holder
    }

    /// **`default.store` belongs to the first account that signs in on this phone.** What was
    /// there signed out is that person's, and stays theirs — so a second Apple ID signing in
    /// later starts with an empty holder store of its own rather than inheriting the first's
    /// saves. An account that already has a holder store of its own keeps it: it is the
    /// second account, and Remove took the first's.
    private static func claimDefaultStore(for account: UUID) {
        guard ProfileStores.owner == nil, !ProfileStores.homes(in: account).contains(account) else { return }
        ProfileStores.owner = account
    }

    func scope(for profile: ProfileDTO) -> ProfileScope {
        guard !profile.isHolder, let account else { return Self.holderScope(for: account) }
        return .profile(profile.id, name: profile.name, account: account)
    }

    /// Every profile of the signed-in account, the current one first — what a background pass
    /// walks. Just the current one when there is no account.
    var scopes: [ProfileScope] {
        guard account != nil, !profiles.isEmpty else { return [current] }
        return [current] + profiles.map(scope(for:)).filter { $0.home != current.home }
    }

    /// The homes whose local alerts may be pending: the signed-in account's, or the phone's
    /// own signed out. Every other account is hidden, and so are its drop reminders.
    private var visibleHomes: Set<UUID?> {
        guard let account else { return [nil] }
        var homes = Set(ProfileStores.homes(in: account).map(Optional.some))
        homes.insert(Self.holderScope(for: account).home)
        for profile in profiles where !profile.isHolder { homes.insert(profile.id) }
        return homes
    }

    /// Puts the app on a store the signed-in account may see: its holder's, or one of its
    /// profiles'. Signed out, the phone's own. Run whenever the account may have changed.
    private func settle() {
        let account = self.account
        if let account { Self.claimDefaultStore(for: account) }
        let holder = Self.holderScope(for: account)
        let isVisible = current == holder
            || (!current.isHolder && current.account == account && profiles.contains { $0.id == current.id })
        if !isVisible { switchTo(holder) }
        ProfileScope.known = ProfileStores.allHomes()
        noteOtherAccounts()
        let homes = visibleHomes
        Task { await DropReminders.retain(homes) }
    }

    // MARK: - Switching

    /// Makes `scope` current: a new session over its own store, and the root rebuilt on it.
    func switchTo(_ scope: ProfileScope) {
        guard scope != current else { return }
        if scope.storeURL == current.storeURL {
            // A rename of the current profile: the same store, and a session that labels its
            // local alerts with the new name. The root is keyed on the whole scope, so it is
            // rebuilt too and the new session's launch sync runs.
            session = ProfileSession(scope: scope, container: session.container, settings: settings, location: location)
            adopt(session)
            return
        }
        let container: ModelContainer
        do {
            container = try self.container(for: scope)
        } catch {
            failure = "Could not open that profile: \(error.localizedDescription)"
            return
        }
        // Settled now, while it is still the old person's: the Discover ledger is written in
        // batches, and a switch is as much a leaving as backgrounding is.
        session.deck.persistSeen()
        session = ProfileSession(scope: scope, container: container, settings: settings, location: location)
        adopt(session)
    }

    /// Every store opened this launch, kept open, by file. Switching back — and a background
    /// pass reaching a profile — must reuse the container rather than open a second one on the
    /// same file while the first may still be finishing a sync; a handful of small stores is a
    /// small price for never having two.
    @ObservationIgnored private var containers: [URL: ModelContainer] = [:]

    private func container(for scope: ProfileScope) throws -> ModelContainer {
        if let open = containers[scope.storeURL] { return open }
        let container = try ProfileSession.container(for: scope)
        containers[scope.storeURL] = container
        return container
    }

    func switchTo(_ profile: ProfileDTO) {
        switchTo(scope(for: profile))
    }

    /// The profile a tapped alert was about, made current before anything opens. The holder's
    /// id means the holder; an id this phone has no profile for is ignored.
    func adopt(pushedFor id: UUID?) {
        guard let id, let profile = profiles.first(where: { $0.id == id }) else { return }
        switchTo(profile)
    }

    private func adopt(_ session: ProfileSession) {
        ProfileScope.active = session.scope
        UserDefaults.standard.set(session.scope.id?.uuidString, forKey: Self.currentKey)
        // The store, not the server user: the holder of an account that does not own
        // `default.store` sends no header but files into a store of its own.
        SharedInbox.setCurrentProfile(session.scope.home)
        session.remote.profileRefused = { [weak self] in self?.profileRefused() }
        installed(session)
    }

    /// The server no longer lets this phone act for the current profile. Back to the holder,
    /// and ask for the list — which is what decides whether the profile's store goes too.
    private func profileRefused() {
        guard !current.isHolder else { return }
        Self.log.notice("the current profile was refused; falling back to the holder")
        switchTo(Self.holderScope(for: account))
        Task { await refresh() }
    }

    // MARK: - Background

    /// `scope`'s sync, for a pass that is not driven by a view. The current profile's is the
    /// session's own, so its `isSyncing` is the one the feed shows; any other is built over
    /// the one container this launch holds for that store, with that profile's keys and header
    /// — the same `RemoteSync`, so there is one merge path whichever store it runs on.
    func syncer(for scope: ProfileScope) -> ProfileSyncer? {
        if scope.storeURL == current.storeURL {
            return ProfileSyncer(scope: current, remote: session.remote, sizes: session.sizes, context: session.container.mainContext)
        }
        guard let container = try? container(for: scope) else { return nil }
        let remote = RemoteSync(context: container.mainContext, settings: settings, location: location, scope: scope)
        // Not a switch — nobody is looking at this profile — but the list is what decides
        // whether its store goes.
        remote.profileRefused = { [weak self] in Task { await self?.refresh() } }
        return ProfileSyncer(scope: scope, remote: remote, sizes: SizeProfileStore(scope: scope), context: container.mainContext)
    }

    /// Re-schedules every visible profile's drop reminders from its own store. After a sign-in,
    /// which is what brings an account's hidden reminders back.
    private func rescheduleReminders() async {
        for scope in scopes {
            guard let container = try? container(for: scope) else { continue }
            await DropReminders.refresh(in: container.mainContext, scope: scope)
        }
    }

    // MARK: - Signing in

    /// Signs in, puts the app on the account's own store, and brings it up to date.
    ///
    /// **The store is chosen before the sizes are adopted and before anything syncs.** The
    /// sign-in runs on whatever the phone was showing signed out — `default.store` — and when
    /// that belongs to another account, the new account's sizes and follows written into it
    /// would be one person's data landing in another's store.
    func signIn(identityToken: String, authorizationCode: String?, nonce: String) async throws {
        let signed = try await session.remote.signInWithApple(
            identityToken: identityToken,
            authorizationCode: authorizationCode,
            nonce: nonce
        )
        if !profiles.isEmpty { setList([], for: nil) }
        settle()
        let session = self.session
        RemoteSync.adopt(signed, into: session.sizes)
        // What the account kept — another phone's follows, a reinstall's whole list, its
        // watches — arrives with the sync, so read it now rather than at the next foreground.
        await session.remote.sync(sizes: session.sizes.profile)
        // And the profiles on it, which a reinstall has no record of — then their reminders,
        // which were cleared while the account was not the one signed in.
        await refresh()
        await rescheduleReminders()
    }

    // MARK: - The list

    /// Asks the server for the account's profiles and believes the answer.
    ///
    /// A list that no longer names a profile means it was deleted — on another phone, or with
    /// the account — so its store and keys go too: a profile's local data is the profile's.
    /// **Only the signed-in account's list prunes, and only that account's stores**: an
    /// account that is not signed in has its stores hidden, never deleted on the strength of
    /// somebody else's list.
    func refresh() async {
        guard settings.isConfigured, settings.isRegistered, let api else { return }
        guard settings.account != nil else {
            forgetAll()
            return
        }
        settle()
        do {
            apply(try await api.profiles())
        } catch APIError.server(404, _) {
            // Not signed in after all, or a server that predates profiles. Either way there is
            // one profile, and it is the holder's — but a 404 is not a statement that any
            // profile was deleted, so no store goes on the strength of it.
            forgetAll()
        } catch {
            Self.log.info("profile list not refreshed: \(error.localizedDescription)")
        }
    }

    private func apply(_ list: [ProfileDTO]) {
        guard let account else { return }
        ProfileStores.adoptLegacy(Set(list.map(\.id)), into: account)
        if list != profiles { setList(list, for: account) }
        // Renamed elsewhere: the label on this phone's own alerts follows.
        if let id = current.id, let profile = list.first(where: { $0.id == id }), profile.name != current.name {
            switchTo(profile)
        }
        // A current profile the list no longer names goes back to the holder here.
        settle()
        prune(keeping: Set(list.filter { !$0.isHolder }.map(\.id)), in: account)
    }

    private func setList(_ list: [ProfileDTO], for account: UUID?) {
        profiles = list
        listedFor = list.isEmpty ? nil : account
        if list.isEmpty {
            UserDefaults.standard.removeObject(forKey: Self.listKey)
            UserDefaults.standard.removeObject(forKey: Self.listAccountKey)
        } else {
            UserDefaults.standard.set(try? JSONEncoder().encode(list), forKey: Self.listKey)
            UserDefaults.standard.set(account?.uuidString, forKey: Self.listAccountKey)
        }
    }

    /// Back to one implicit profile: the device has no account any more, or the server does
    /// not answer the question. **Hides; never deletes.** The account's stores stay filed
    /// under it on this phone and come back when it signs in again.
    func forgetAll() {
        if !profiles.isEmpty { setList([], for: nil) }
        settle()
    }

    // MARK: - Changing the list

    func create(named raw: String) async {
        guard let name = ProfileNaming.clean(raw) else { return }
        await run {
            guard let api = self.api else { throw APIError.notConfigured }
            let created = try await api.createProfile(CreateProfile(name: name))
            self.apply(self.profiles + [created])
        }
    }

    func rename(_ profile: ProfileDTO, to raw: String) async {
        let name = ProfileNaming.clean(raw)
        // Only the holder may be nameless; they are "You" without one.
        guard name != nil || profile.isHolder else { return }
        await run {
            guard let api = self.api else { throw APIError.notConfigured }
            let updated = try await api.updateProfile(id: profile.id, UpdateProfile(name: name ?? ""))
            self.replace(updated)
        }
    }

    func setAlerts(_ enabled: Bool, for profile: ProfileDTO) async {
        await run {
            guard let api = self.api else { throw APIError.notConfigured }
            let updated = try await api.updateProfile(id: profile.id, UpdateProfile(alertsEnabled: enabled))
            self.replace(updated)
        }
    }

    /// Deletes a profile on the server, then its store and keys here. Never the holder.
    func delete(_ profile: ProfileDTO) async {
        guard !profile.isHolder else { return }
        await run {
            guard let api = self.api else { throw APIError.notConfigured }
            try await api.deleteProfile(id: profile.id)
            if self.current.id == profile.id { self.switchTo(Self.holderScope(for: self.account)) }
            self.apply(self.profiles.filter { $0.id != profile.id })
        }
    }

    /// Whether deleting the account leaves the holder's saves on this phone: yes when they are
    /// in `default.store`, which was the phone's before the account, no when the account had a
    /// store of its own.
    var accountDeletionKeepsSaves: Bool { Self.holderScope(for: account).home == nil }

    /// Deletes the account from the holder's profile, then every store filed under it.
    ///
    /// `default.store` stays when the account owned it: it was the phone's before there was an
    /// account and stays the phone's after, free for the next account to sign in. Run from
    /// here rather than from the view because the switch rebuilds the page that asked.
    func deleteAccount() async {
        await run {
            guard let account = self.account else { throw APIError.notConfigured }
            self.switchTo(Self.holderScope(for: account))
            let session = self.session
            try await session.remote.deleteAccount(sizes: session.sizes.profile)
            // Signed out now, so this is the phone's own store.
            self.forgetAll()
            let directory = ProfileStores.directory(for: account).path(percentEncoded: false)
            self.containers = self.containers.filter { !$0.key.path(percentEncoded: false).hasPrefix(directory) }
            ProfileStores.removeAccount(account)
            if ProfileStores.owner == account { ProfileStores.owner = nil }
            ProfileScope.known = ProfileStores.allHomes()
            self.noteOtherAccounts()
            // Puts this phone's brands back on the new anonymous device now, rather than at
            // the next foreground — until then nothing would be watched for it.
            await self.session.remote.sync(sizes: self.session.sizes.profile)
        }
    }

    private func replace(_ profile: ProfileDTO) {
        apply(profiles.map { $0.id == profile.id ? profile : $0 })
    }

    private func run(_ work: @escaping @MainActor () async throws -> Void) async {
        isWorking = true
        failure = nil
        do {
            try await work()
        } catch {
            failure = error.localizedDescription
        }
        isWorking = false
    }

    // MARK: - Pruning

    /// Deletes the stores and scoped keys of every profile filed under `account` that is not
    /// in `kept`. The account's holder store is never touched, and neither is the store open.
    private func prune(keeping kept: Set<UUID>, in account: UUID) {
        for home in ProfileStores.homes(in: account) where home != account && !kept.contains(home) && home != current.home {
            let scope = ProfileScope.profile(home, name: nil, account: account)
            containers[scope.storeURL] = nil
            ProfileStores.remove(scope)
            Self.log.notice("removed the local store of a profile that is gone")
        }
        ProfileScope.known = ProfileStores.allHomes()
    }

    // MARK: - Another Apple ID's stores

    /// The stores of every account but the one this phone is showing — signed in, that
    /// account; signed out, whoever owns `default.store`. Profile stores from before stores
    /// were filed by account, which no list has claimed, count too: nothing says whose they are.
    private func otherAccountStores() -> [ProfileScope] {
        let shown = account ?? (current.home == nil ? ProfileStores.owner : nil)
        var stores: [ProfileScope] = []
        for other in ProfileStores.accounts() where other != shown {
            stores += ProfileStores.homes(in: other).map { ProfileScope(id: nil, name: nil, home: $0, account: other) }
        }
        stores += ProfileStores.legacyHomes().map { ProfileScope(id: nil, name: nil, home: $0, account: nil) }
        // `default.store` itself, when it is another account's and not the one open.
        if let owner = ProfileStores.owner, owner != shown, current.home != nil,
           FileManager.default.fileExists(atPath: ProfileScope.holder.storeURL.path(percentEncoded: false)) {
            stores.append(.holder)
        }
        return stores
    }

    private func noteOtherAccounts() {
        let holds = !otherAccountStores().isEmpty
        if holds != holdsOtherAccounts { holdsOtherAccounts = holds }
    }

    /// Deletes every other account's stores from this phone, with their keys, their waiting
    /// shares and their reminders. The account signed in — and the store open — is untouched.
    func removeOtherAccounts() async {
        let stores = otherAccountStores()
        guard !stores.isEmpty else { return }
        for scope in stores { containers[scope.storeURL] = nil }
        SharedInbox.discard(for: Set(stores.map(\.home)))
        for account in Set(stores.compactMap(\.account)) { ProfileStores.removeAccount(account) }
        for scope in stores where scope.account == nil { ProfileStores.remove(scope) }
        if stores.contains(.holder) { ProfileStores.owner = nil }
        ProfileScope.known = ProfileStores.allHomes()
        noteOtherAccounts()
        await DropReminders.retain(visibleHomes)
        Self.log.notice("removed \(stores.count) store(s) of another Apple ID")
    }
}


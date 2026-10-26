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

    static let holder = ProfileScope(id: nil, name: nil)

    var isHolder: Bool { id == nil }

    /// A `UserDefaults` key for this person: the key itself for the holder, so nothing an
    /// install already wrote moves, and `<key>.<id>` for a profile.
    func key(_ base: String) -> String {
        id.map { "\(base).\($0.uuidString)" } ?? base
    }

    /// The holder's store is the one 1.0 and 1.1 wrote, at the path `streetwApp` has always
    /// pinned; a profile's sits beside it.
    var storeURL: URL {
        let name = id.map { "profile-\($0.uuidString).store" } ?? "default.store"
        return URL.applicationSupportDirectory.appending(path: name)
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

    /// Profiles this phone has a store for, as of the last list. The share inbox uses it to
    /// tell a share for a profile that is not current from one for a profile that is gone.
    @MainActor static var known: Set<UUID> = []

    /// Every `UserDefaults` key that describes a person rather than the phone. A new one goes
    /// here or is the phone's — there is no third kind — and deleting a profile clears these.
    /// The phone's: the server address, token and account, `didRegisterAfresh`, the usage
    /// tally, the saved-price-drop setting and every dev flag.
    static let scopedKeys = [
        "sizeProfile", "styleStatement", "feedCursor", "feedPendingReads", "pendingUnfollows",
        "pendingWatchDeletes", "discoverSeen", "shopPicksToday", "shopPicksRefused",
        "feedLastOnScreenAt", "feedVisitBoundary", "pollHintsFingerprint", "pollHintState",
        "didOfferStarterPack"
    ]
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

    init(scope: ProfileScope, container: ModelContainer, settings: ServerSettings) {
        self.scope = scope
        self.container = container
        sizes = SizeProfileStore(scope: scope)
        statement = StyleStatementStore(scope: scope)
        remote = RemoteSync(context: container.mainContext, settings: settings, scope: scope)
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

/// The account's profiles, which one is current, and switching between them.
@MainActor
@Observable
final class ProfileStore {
    private static let log = Logger(subsystem: "com.kern.functional.streetw", category: "profiles")
    private static let currentKey = "currentProfile"
    private static let listKey = "profiles"

    /// The account's profiles, holder first, as the server last said. Empty when the device is
    /// not signed in — which is the implicit single profile, and draws nothing about profiles.
    private(set) var profiles: [ProfileDTO] = []
    private(set) var session: ProfileSession
    private(set) var isWorking = false
    var failure: String?

    private let settings: ServerSettings
    /// Where a switch has to be announced: the app delegate's registry and the usage counts
    /// both hold the session's `RemoteSync`.
    private let installed: (ProfileSession) -> Void

    init(settings: ServerSettings, installed: @escaping (ProfileSession) -> Void) {
        self.settings = settings
        self.installed = installed

        let cached = UserDefaults.standard.data(forKey: Self.listKey)
            .flatMap { try? JSONDecoder().decode([ProfileDTO].self, from: $0) } ?? []
        // **A remembered profile counts only while it can work**: signed in, against a server,
        // and still in the list. Anything else is the holder — so `-standalone YES`, a signed-out
        // install and an older server all behave exactly as they did before profiles.
        let usable = settings.isConfigured && settings.account != nil
        let list = usable ? cached : []
        profiles = list
        let stored = UserDefaults.standard.string(forKey: Self.currentKey).flatMap(UUID.init(uuidString:))
        let scope = stored
            .flatMap { id in list.first { $0.id == id && !$0.isHolder } }
            .map { ProfileScope(id: $0.id, name: $0.name) } ?? .holder

        let container: ModelContainer
        do {
            container = try ProfileSession.container(for: scope)
        } catch {
            // A profile's store that will not open is not a reason to take the app down; the
            // holder's is, exactly as before profiles.
            Self.log.error("could not open the store for a profile: \(error.localizedDescription)")
            do {
                container = try ProfileSession.container(for: .holder)
            } catch {
                fatalError("Could not create ModelContainer: \(error)")
            }
        }
        let opened = container.configurations.first?.url == scope.storeURL ? scope : .holder
        session = ProfileSession(scope: opened, container: container, settings: settings)
        containers[opened.id] = container
        ProfileScope.known = Set(profiles.filter { !$0.isHolder }.map(\.id))
        adopt(session)
    }

    var current: ProfileScope { session.scope }

    /// The holder's own row, when signed in.
    var holder: ProfileDTO? { profiles.first(where: \.isHolder) }

    private var api: StreetwAPI? {
        guard let baseURL = settings.baseURL, settings.token != nil else { return nil }
        // No profile header: these routes are about the account, and a stale header would
        // refuse the very list that says the profile is gone.
        return StreetwAPI(baseURL: baseURL, token: settings.token)
    }

    // MARK: - Switching

    /// Makes `scope` current: a new session over its own store, and the root rebuilt on it.
    func switchTo(_ scope: ProfileScope) {
        guard scope.id != current.id || scope.name != current.name else { return }
        if scope.id == current.id {
            // A rename of the current profile: the same store, and a session that labels its
            // local alerts with the new name. The root is keyed on the whole scope, so it is
            // rebuilt too and the new session's launch sync runs.
            session = ProfileSession(scope: scope, container: session.container, settings: settings)
            adopt(session)
            return
        }
        let container: ModelContainer
        if let open = containers[scope.id] {
            container = open
        } else {
            do {
                container = try ProfileSession.container(for: scope)
            } catch {
                failure = "Could not open that profile: \(error.localizedDescription)"
                return
            }
        }
        // Settled now, while it is still the old person's: the Discover ledger is written in
        // batches, and a switch is as much a leaving as backgrounding is.
        session.deck.persistSeen()
        containers[session.scope.id] = session.container
        containers[scope.id] = container
        session = ProfileSession(scope: scope, container: container, settings: settings)
        adopt(session)
    }

    /// Every store opened this launch, kept open. Switching back must reuse the container
    /// rather than open a second one on the same file while the first may still be finishing
    /// a sync; a handful of small stores is a small price for never having two.
    @ObservationIgnored private var containers: [UUID?: ModelContainer] = [:]

    func switchTo(_ profile: ProfileDTO) {
        switchTo(profile.isHolder ? .holder : ProfileScope(id: profile.id, name: profile.name))
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
        SharedInbox.setCurrentProfile(session.scope.id)
        session.remote.profileRefused = { [weak self] in self?.profileRefused() }
        installed(session)
    }

    /// The server no longer lets this phone act for the current profile. Back to the holder,
    /// and ask for the list — which is what decides whether the profile's store goes too.
    private func profileRefused() {
        guard !current.isHolder else { return }
        Self.log.notice("the current profile was refused; falling back to the holder")
        switchTo(.holder)
        Task { await refresh() }
    }

    // MARK: - The list

    /// Asks the server for the account's profiles and believes the answer.
    ///
    /// A list that no longer names a profile means it was deleted — on another phone, or with
    /// the account — so its store and keys go too: a profile's local data is the profile's.
    func refresh() async {
        guard settings.isConfigured, settings.isRegistered, let api else { return }
        guard settings.account != nil else {
            forgetAll()
            return
        }
        do {
            apply(try await api.profiles())
        } catch APIError.server(404, _) {
            // Not signed in after all, or a server that predates profiles. Either way there is
            // one profile, and it is the holder's — but a 404 is not a statement that any
            // profile was deleted, so no store goes on the strength of it.
            forgetAll(pruning: false)
        } catch {
            Self.log.info("profile list not refreshed: \(error.localizedDescription)")
        }
    }

    private func apply(_ list: [ProfileDTO]) {
        if list != profiles {
            profiles = list
            UserDefaults.standard.set(try? JSONEncoder().encode(list), forKey: Self.listKey)
        }
        let kept = Set(list.filter { !$0.isHolder }.map(\.id))
        ProfileScope.known = kept
        if let id = current.id {
            if let profile = list.first(where: { $0.id == id }) {
                // Renamed elsewhere: the label on this phone's own alerts follows.
                if profile.name != current.name { switchTo(profile) }
            } else {
                switchTo(.holder)
            }
        }
        prune(keeping: kept)
    }

    /// Back to one implicit profile. Called when the device has no account any more.
    ///
    /// - Parameter pruning: whether every profile's store goes too — yes when the server has
    ///   said the account is gone, no when it merely did not answer the question.
    func forgetAll(pruning: Bool = true) {
        if !current.isHolder { switchTo(.holder) }
        if !profiles.isEmpty {
            profiles = []
            UserDefaults.standard.removeObject(forKey: Self.listKey)
        }
        ProfileScope.known = []
        if pruning { prune(keeping: []) }
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
            if self.current.id == profile.id { self.switchTo(.holder) }
            self.apply(self.profiles.filter { $0.id != profile.id })
        }
    }

    /// Deletes the account from the holder's profile, then every other profile's store.
    ///
    /// The holder's store stays: it was the phone's before there was an account and stays the
    /// phone's after. Run from here rather than from the view because the switch rebuilds the
    /// page that asked.
    func deleteAccount() async {
        await run {
            if !self.current.isHolder { self.switchTo(.holder) }
            let session = self.session
            try await session.remote.deleteAccount(sizes: session.sizes.profile)
            self.forgetAll()
            // Puts this phone's brands back on the new anonymous device now, rather than at
            // the next foreground — until then nothing would be watched for it.
            await session.remote.sync(sizes: session.sizes.profile)
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

    /// Deletes the store files and scoped keys of every profile not in `kept`. The holder's
    /// are never touched, and neither is the store currently open.
    private func prune(keeping kept: Set<UUID>) {
        for id in containers.keys.compactMap({ $0 }) where !kept.contains(id) && id != current.id {
            containers[id] = nil
        }
        Self.pruneFiles(keeping: kept)
    }

    private static func pruneFiles(keeping kept: Set<UUID>) {
        let directory = URL.applicationSupportDirectory
        let files = (try? FileManager.default.contentsOfDirectory(atPath: directory.path())) ?? []
        var gone: Set<UUID> = []
        for file in files where file.hasPrefix("profile-") {
            let stem = file.dropFirst("profile-".count).prefix(36)
            guard let id = UUID(uuidString: String(stem)), !kept.contains(id),
                  id != ProfileScope.active.id
            else { continue }
            gone.insert(id)
            try? FileManager.default.removeItem(at: directory.appending(path: file))
        }
        for id in gone {
            let scope = ProfileScope(id: id, name: nil)
            for key in ProfileScope.scopedKeys {
                UserDefaults.standard.removeObject(forKey: scope.key(key))
            }
            log.notice("removed the local store of a profile that is gone")
        }
    }
}

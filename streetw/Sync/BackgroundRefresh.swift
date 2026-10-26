// BackgroundRefresh.swift
// Keeping the feed warm without the app being open, and receiving the server's pushes.
//
// Two paths, and they are not redundant:
//
// - **Push** is the real one. The server knows about a drop within a poll cycle and
//   tells the phone immediately; that is the entire reason a backend exists.
// - **`BGAppRefreshTask`** is the fallback for a feed that is merely *stale* — it gets a
//   handful of system-chosen wakeups a day, which is useless for "dropping in 5 minutes"
//   but fine for having something to show the moment the app opens.
//
// Neither is allowed to be a precondition for the other: a build with no push entitlement
// still background-refreshes, and a device that denies notifications still syncs.

import BackgroundTasks
import StreetwCore
import SwiftData
import SwiftUI
import UIKit
import UserNotifications

/// Hand-off between `streetwApp`, which owns the shared objects, and `AppDelegate`,
/// which UIKit instantiates on its own and cannot be handed anything.
///
/// A static registry rather than a lookup at use time, and installed from
/// `streetwApp.init` for the same reason those objects are built there: anything that
/// resolves them asynchronously races with the first view's `.task`.
@MainActor
enum BackgroundServices {
    private(set) static var remote: RemoteSync?
    private(set) static var sizes: SizeProfileStore?
    private(set) static var settings: ServerSettings?
    private(set) static var route: PushRoute?
    /// So a tapped alert about another profile can switch to it first. The three above are
    /// the current profile's and are re-installed on every switch.
    static var profiles: ProfileStore?

    static func install(
        remote: RemoteSync,
        sizes: SizeProfileStore,
        settings: ServerSettings,
        route: PushRoute
    ) {
        self.remote = remote
        self.sizes = sizes
        self.settings = settings
        self.route = route
    }

    /// One sync of the current profile — what a tap and a stale token need, nothing more.
    @discardableResult
    static func syncNow() async -> Bool {
        guard let remote, let sizes, settings?.isConfigured == true else { return false }
        await remote.sync(sizes: sizes.profile)
        return remote.lastError == nil
    }

    /// What a pass did: whether every profile it reached synced, and how many rows landed.
    struct PassResult {
        var ok = true
        var merged = 0
    }

    /// Brings every profile on the account up to date, each into its own store, until
    /// `deadline` — the background refresh's and a push wake's pass.
    ///
    /// **Not only the profile on screen.** This synced the current store and nothing else, so
    /// another profile's feed was as old as the last time somebody switched to it, and the
    /// alerts that are said on the phone — `PriceAlerts` on that profile's saves, `WatchNotifier`
    /// — waited for the same switch. Each profile goes through the very `RemoteSync.sync` the
    /// foreground uses, with its own store, keys and header (`ProfileStore.syncer`): one merge
    /// path, called per store, and its alerts are labelled "For Anna: …" by its own scope.
    ///
    /// **iOS allows about thirty seconds**, so the order matters more than the total: the
    /// profile a push names, then the current one, then the rest by how long since a pass last
    /// reached them. A pass cut short — out of time, or expired by iOS — stops between profiles
    /// and leaves the stragglers at the head of the next one rather than starving them.
    /// A store the foreground is already syncing is skipped, never waited for.
    ///
    /// - Parameters:
    ///   - named: the profile a push was about, by server user id.
    ///   - limit: at most this many profiles — one, for a push arriving with the app open,
    ///     whose banner waits on this.
    static func syncProfiles(first named: UUID? = nil, until deadline: Date, limit: Int = .max) async -> PassResult {
        guard settings?.isConfigured == true, let profiles else { return PassResult(ok: false) }
        var order = profiles.scopes
        let current = order.removeFirst()
        let stamps = passStamps
        order.sort { (stamps[stampKey($0)] ?? .distantPast) < (stamps[stampKey($1)] ?? .distantPast) }
        order.insert(current, at: 0)
        if let named,
           let index = order.firstIndex(where: { $0.id == named || ($0.isHolder && profiles.holder?.id == named) }) {
            order.insert(order.remove(at: index), at: 0)
        }

        var result = PassResult()
        for scope in order.prefix(limit) {
            guard !Task.isCancelled, Date() < deadline else { break }
            guard let syncer = profiles.syncer(for: scope) else { continue }
            let ran = await syncer.remote.sync(sizes: syncer.sizes.profile, ifIdle: true)
            // Cancelled mid-sync: what landed is saved page by page, and the profile stays
            // unstamped, so the next pass reaches it early.
            if Task.isCancelled { break }
            if ran {
                if syncer.remote.lastError == nil {
                    passStamps[stampKey(scope)] = Date()
                    result.merged += syncer.remote.newItemCount
                } else {
                    result.ok = false
                }
            }
            // From the store, so a profile that is not current still has its reminders armed
            // after permission was granted while somebody else's was on screen.
            await DropReminders.refresh(in: syncer.context, scope: scope)
        }
        return result
    }

    /// When a background pass last synced each store, by `ProfileScope.home`. The phone's, not
    /// a person's: it only orders the next pass.
    private static var passStamps: [String: Date] {
        get { UserDefaults.standard.dictionary(forKey: "backgroundPassAt") as? [String: Date] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: "backgroundPassAt") }
    }

    private static func stampKey(_ scope: ProfileScope) -> String {
        scope.home?.uuidString ?? "default"
    }

    /// How long a pass may start new work for. iOS gives a refresh and a push wake about
    /// thirty seconds; the margin is for the sync already running when this passes.
    static let passBudget: TimeInterval = 22

    /// The APNs environment this build's token belongs to. A token from the development
    /// environment is simply invalid at the production host and vice versa, so the
    /// server stores it per device and this is what tells it which.
    static var apnsEnvironment: String {
        #if DEBUG
        "sandbox"
        #else
        "production"
        #endif
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    /// Must also appear in `BGTaskSchedulerPermittedIdentifiers` in Info.plist —
    /// registering an identifier that isn't listed there traps at launch.
    static let refreshTaskID = "functional.streetw.refresh"

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        // Registration must happen before `didFinishLaunching` returns, so this cannot
        // move into a `.task`.
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: Self.refreshTaskID,
            using: nil
        ) { task in
            guard let task = task as? BGAppRefreshTask else { return }
            Task { @MainActor in await Self.handle(task) }
        }

        UNUserNotificationCenter.current().delegate = self

        // Only re-register a token we are already allowed to have. Calling this
        // unconditionally would be harmless but pointless; asking for authorization at
        // launch would be worse, so the prompt lives behind an explicit action.
        Task { @MainActor in await PushAuthorization.registerIfAuthorized() }
        return true
    }

    // MARK: Push

    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        let hex = deviceToken.map { String(format: "%02x", $0) }.joined()
        Task { @MainActor in
            await BackgroundServices.remote?.pushDeviceToken(hex)
        }
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: any Error
    ) {
        // Expected, and survivable, on a build signed without the push entitlement:
        // everything else in the app keeps working, there just are no alerts.
        print("push: could not register — \(error.localizedDescription)")
    }

    /// A push arrived. The payload deliberately carries no content — it is a nudge to
    /// pull the feed, so the phone and the server can never disagree about what happened.
    ///
    /// `nonisolated` because the payload is `[AnyHashable: Any]`, which is not `Sendable` and
    /// cannot be handed to a main-actor implementation — an error in Swift 6 language mode.
    /// Only the profile id is read out of it, here, and a `UUID` crosses to the main actor
    /// where the whole payload could not.
    nonisolated func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any]
    ) async -> UIBackgroundFetchResult {
        // The one thing read: whose alert it is, so that profile is synced first.
        let profileID = Self.profileID(in: userInfo)
        let deadline = Date().addingTimeInterval(BackgroundServices.passBudget)
        let pass = await BackgroundServices.syncProfiles(first: profileID, until: deadline)
        guard pass.ok else { return .failed }
        // `sync` zeroes its count at the start of each run, so the sum already means "new in
        // this pass" — comparing against a value read beforehand would always say no.
        return pass.merged > 0 ? .newData : .noData
    }

    nonisolated private static func profileID(in userInfo: [AnyHashable: Any]) -> UUID? {
        (userInfo["profileID"] as? String).flatMap(UUID.init(uuidString:))
    }

    // MARK: Background refresh

    @MainActor
    private static func handle(_ task: BGAppRefreshTask) async {
        // Ask for the next slot first: if this pass throws, is killed, or the user never
        // opens the app again, there must still be a future wake-up queued.
        schedule()

        // Every profile, the current one first, stopping between profiles once the budget is
        // spent — and at once if iOS expires the task first. See `syncProfiles`.
        let deadline = Date().addingTimeInterval(BackgroundServices.passBudget)
        let work = Task { await BackgroundServices.syncProfiles(until: deadline) }
        task.expirationHandler = { work.cancel() }

        let pass = await work.value
        task.setTaskCompleted(success: pass.ok)
    }

    /// iOS treats this as a hint and throttles hard on how often the app is opened —
    /// fifteen minutes is a floor, never a promise.
    @MainActor
    static func schedule() {
        let request = BGAppRefreshTaskRequest(identifier: refreshTaskID)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            // Simulators refuse this outright, so it must never be fatal.
            print("background refresh: could not schedule — \(error.localizedDescription)")
        }
    }
}

extension AppDelegate: UNUserNotificationCenterDelegate {
    /// Show the alert even with the app open — a drop is worth interrupting for, and the
    /// feed the user is looking at is exactly what just changed.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        // The profile the alert is about — "For Anna" lands in Anna's store even with the
        // holder on screen — and only that one: the banner waits on this.
        let profileID = (notification.request.content.userInfo["profileID"] as? String)
            .flatMap(UUID.init(uuidString:))
        _ = await BackgroundServices.syncProfiles(first: profileID, until: .distantFuture, limit: 1)
        // Always shown. Whether a brand may interrupt somebody is its follow mode, which
        // the server applies before anything is sent — this used to second-guess it with a
        // phone-only mute that only ever worked with the app open, since iOS shows a push
        // that arrives in the background without asking. What still arrives is either
        // something the mode allows or a watch alert, which no mode silences.
        return [.banner, .sound, .list]
    }

    /// Tapped. Pull first so the item that caused the notification is actually there —
    /// the alert can arrive before the phone has the row it is about — and only then say
    /// where to go.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        // "For Anna: …" opens in Anna's profile: switched before the sync, so the pull and the
        // lookup both run against her store. The holder's id switches back to the holder; an
        // alert with none — from a build or a server before profiles — opens where it is.
        let profileID = (response.notification.request.content.userInfo["profileID"] as? String)
            .flatMap(UUID.init(uuidString:))
        await MainActor.run { BackgroundServices.profiles?.adopt(pushedFor: profileID) }
        await BackgroundServices.syncNow()
        BackgroundServices.route?.open(
            PushDestination(response.notification.request.content.userInfo)
        )
        // Only the server's own alerts. A drop reminder or a standalone watch is scheduled
        // on the phone, and counting it here would make "do the pushes get tapped" partly a
        // question about the drop calendar.
        if response.notification.request.trigger is UNPushNotificationTrigger {
            UsageCounts.record(.pushOpened)
        }
    }
}

/// Where a tapped notification should land.
///
/// Being told something is back in your size and then being dropped on a feed to go and
/// find it is the notification failing at the last step — the alert already knows which
/// product it is about.
enum PushDestination: Equatable {
    /// One item, keyed the way `RemoteSync` stores server-backed rows.
    case update(externalID: String)
    /// A brand's page. What a counted summary ("3 restocks") gets, because no single
    /// product is the subject.
    case brand(remoteID: UUID)
    /// A push with nothing usable in it — a probe, or a build newer than this one.
    case none

    init(_ userInfo: [AnyHashable: Any]) {
        if let event = userInfo["eventID"] as? String, UUID(uuidString: event) != nil {
            self = .update(externalID: "event:\(event)")
            return
        }
        // A local alert names its row outright — `PriceAlerts` — because a standalone row is
        // keyed by its product, not by a server event.
        if let row = userInfo["externalID"] as? String, !row.isEmpty {
            self = .update(externalID: row)
            return
        }
        if let brand = userInfo["brandID"] as? String,
           let id = UUID(uuidString: brand),
           id != Self.probeBrandID {
            self = .brand(remoteID: id)
            return
        }
        self = .none
    }

    /// The server's sentinel for a test push. It refers to no real brand, so navigating to
    /// it would land on an empty page and read as a bug.
    static let probeBrandID = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
}

/// The one place a tapped notification's destination is published.
///
/// Observable rather than a notification-centre broadcast so the value survives being set
/// before the view hierarchy exists — a push that cold-launches the app delivers its tap
/// well before `ContentView` has appeared, and a broadcast at that moment reaches nobody.
@MainActor
@Observable
final class PushRoute {
    /// Cleared by whoever handles it, so the same tap can't re-navigate on every redraw.
    var pending: PushDestination?

    /// Something just shared in that turned out to be sold out. Offered rather than
    /// navigated to, so it is one tap to set the watch and one to ignore.
    var watchOffer: BrandUpdate?

    func open(_ destination: PushDestination) {
        guard destination != .none else { return }
        pending = destination
    }

    /// First one wins for the pass. Sharing five sold-out links should ask once, not
    /// stack five sheets — and the alternative to asking is the watch section on the item
    /// itself, which is always there.
    func offerWatch(_ update: BrandUpdate) {
        guard watchOffer == nil else { return }
        watchOffer = update
    }
}

/// Asking for permission, kept separate from the delegate so a view can call it.
@MainActor
enum PushAuthorization {
    static func current() async -> UNAuthorizationStatus {
        await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    /// Asks APNs for a token, but only if iOS says we are allowed one.
    ///
    /// **Called on every foreground, not only at launch.** Permission granted in iOS
    /// Settings — which is the only route left to somebody who tapped "Not now" — produces
    /// no callback of any kind, so the app used to notice on the *next cold launch* and not
    /// before. Until then the server holds a device row with a null token: `Notifier` finds
    /// the follower, has nobody to send to, and stamps `notified_at` anyway, so every layer
    /// reports healthy and not one notification exists. That is the failure `devicesWithToken`
    /// was added to make visible; this is the one that stops producing it.
    ///
    /// Idempotent and cheap. `registerForRemoteNotifications` is documented as safe to call
    /// on every launch, and a token that has not changed re-delivers the same string, which
    /// `pushDeviceToken` writes over the identical value.
    static func registerIfAuthorized() async {
        let status = await current()
        guard status == .authorized || status == .provisional else { return }
        UIApplication.shared.registerForRemoteNotifications()
    }

    /// Prompts if it hasn't been asked yet, and registers for a token on success.
    @discardableResult
    static func request() async -> Bool {
        do {
            let granted = try await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound, .badge])
            if granted { UIApplication.shared.registerForRemoteNotifications() }
            return granted
        } catch {
            print("push: authorization failed — \(error.localizedDescription)")
            return false
        }
    }
}

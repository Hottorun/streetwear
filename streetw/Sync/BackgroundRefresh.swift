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
    /// Needed to answer one question at push time: is this brand muted. The delegate is
    /// built by UIKit and has no environment, so the container is published here with
    /// everything else.
    private(set) static var container: ModelContainer?

    static func install(
        remote: RemoteSync,
        sizes: SizeProfileStore,
        settings: ServerSettings,
        route: PushRoute,
        container: ModelContainer
    ) {
        self.remote = remote
        self.sizes = sizes
        self.settings = settings
        self.route = route
        self.container = container
    }

    /// Whether the user has silenced the brand a push is about.
    ///
    /// Answered on the device rather than at the source. The server decides *who* to
    /// notify from the catalog, which is shared by everyone — a preference belonging to one
    /// phone has no business in it. The cost is that a muted brand's push is delivered and
    /// then dropped, which is invisible and is the right trade for keeping the catalog
    /// impersonal.
    static func isMuted(_ userInfo: [AnyHashable: Any]) -> Bool {
        guard let remoteID = PushDestination.brandID(in: userInfo), let container else { return false }
        let context = ModelContext(container)
        let descriptor = FetchDescriptor<Brand>(
            predicate: #Predicate { $0.remoteID == remoteID && $0.isMuted }
        )
        return ((try? context.fetchCount(descriptor)) ?? 0) > 0
    }

    /// One sync pass, safe to call from a background wake-up.
    @discardableResult
    static func syncNow() async -> Bool {
        guard let remote, let sizes, settings?.isConfigured == true else { return false }
        await remote.sync(sizes: sizes.profile)
        return remote.lastError == nil
    }

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
        Task { @MainActor in
            let settings = await UNUserNotificationCenter.current().notificationSettings()
            if settings.authorizationStatus == .authorized {
                application.registerForRemoteNotifications()
            }
        }
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
    func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any]
    ) async -> UIBackgroundFetchResult {
        let ok = await BackgroundServices.syncNow()
        guard ok else { return .failed }
        // `sync` zeroes this at the start of each pass, so it already means "new in this
        // pass" — comparing against a value read beforehand would always say no.
        let merged = await BackgroundServices.remote?.newItemCount ?? 0
        return merged > 0 ? .newData : .noData
    }

    // MARK: Background refresh

    @MainActor
    private static func handle(_ task: BGAppRefreshTask) async {
        // Ask for the next slot first: if this pass throws, is killed, or the user never
        // opens the app again, there must still be a future wake-up queued.
        schedule()

        let work = Task { await BackgroundServices.syncNow() }
        task.expirationHandler = { work.cancel() }

        let ok = await work.value
        task.setTaskCompleted(success: ok)
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
        await BackgroundServices.syncNow()
        // Still synced, still in the feed — just not announced. A muted brand is the one
        // you want to keep watching and stop being woken by, and the only control the app
        // used to offer for that was removing it altogether.
        guard !BackgroundServices.isMuted(notification.request.content.userInfo) else { return [] }
        return [.banner, .sound, .list]
    }

    /// Tapped. Pull first so the item that caused the notification is actually there —
    /// the alert can arrive before the phone has the row it is about — and only then say
    /// where to go.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        await BackgroundServices.syncNow()
        BackgroundServices.route?.open(
            PushDestination(response.notification.request.content.userInfo)
        )
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

    /// Which brand a push is about, whatever it is about *within* that brand.
    ///
    /// Read separately from the destination because the two questions differ: a restock
    /// alert routes to one product but is still a message from a brand, and muting has to
    /// silence it. `brandID` travels on every payload alongside `eventID` precisely so this
    /// is answerable without a lookup.
    static func brandID(in userInfo: [AnyHashable: Any]) -> UUID? {
        guard let raw = userInfo["brandID"] as? String,
              let id = UUID(uuidString: raw),
              id != probeBrandID
        else { return nil }
        return id
    }
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

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

    static func install(remote: RemoteSync, sizes: SizeProfileStore, settings: ServerSettings) {
        self.remote = remote
        self.sizes = sizes
        self.settings = settings
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
        return [.banner, .sound, .list]
    }

    /// Tapped. Pull first so the item that caused the notification is actually there.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        await BackgroundServices.syncNow()
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

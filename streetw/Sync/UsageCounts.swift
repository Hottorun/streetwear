// UsageCounts.swift
// The phone's half of the anonymous usage counts: tally here, report now and then.
//
// What is counted and why is in `Usage.swift` in StreetwCore; what the server keeps is in
// `docs/server.md`. This file is only the batching, and its rules are the ones every other
// small thing this app sends already follows:
//
// - **Standalone counts nothing.** There is no server to tell, and a tally nobody will ever
//   read would only grow.
// - **Kept until a reply.** The tally lives in `UserDefaults` and comes out only once the
//   server has answered, by subtraction — so a report that fails is sent again, and a tab
//   opened while one was on the wire is not lost. See `UsageTally.remove`.
// - **Keyed on the token.** A fresh install counts its first open before it has registered;
//   `ContentView` asks again when `settings.token` changes, which is the moment the first
//   report becomes possible. A `.task` that fired once before registration would otherwise
//   have dropped it on the floor — the `BrandSuggestions` failure.
// - **A 401 is a repair, not a shrug.** It means the server has forgotten this device, which
//   is the failure that makes every server feature read as empty rather than broken. The
//   sync is what re-registers, so a refused report runs one, and goes again on the new token.

import Foundation
import OSLog
import StreetwCore
import UIKit

@MainActor
enum UsageCounts {
    private static let log = Logger(subsystem: "com.kern.functional.streetw", category: "usage")
    private static let key = "usageTally"

    /// How often a report may go out. Nothing reads these by the minute, and the server's
    /// budget for this route (`RateLimits.usage`) is set well above what this allows.
    private static let interval: TimeInterval = 5 * 60

    private static var settings: ServerSettings?
    private static var remote: RemoteSync?

    private static var lastReportAt: Date?
    private static var isReporting = false

    /// Whether the next time the scene is active is somebody opening the app. True at launch
    /// and after every trip to the background — and only then: pulling down Notification
    /// Centre takes the scene to inactive and back, and that is not an open.
    private static var isReturning = true

    /// Published from `streetwApp.init`, alongside `BackgroundServices`, so a count made
    /// before any view exists — a notification that cold-launches the app — has somewhere to
    /// go.
    static func install(settings: ServerSettings, remote: RemoteSync) {
        self.settings = settings
        self.remote = remote
    }

    static func record(_ event: UsageEvent) {
        guard settings?.isConfigured == true else { return }
        var tally = load()
        tally.record(event)
        store(tally)
    }

    /// The scene became active. Counts an open, and the tab it opened on, once per return.
    static func sceneBecameActive(onTab tab: String) {
        guard isReturning else { return }
        isReturning = false
        record(.appOpened)
        tabOpened(tab)
    }

    static func sceneEnteredBackground() {
        isReturning = true
    }

    static func tabOpened(_ tab: String) {
        guard let event = UsageEvent(tab: tab) else { return }
        record(event)
    }

    /// Sends what has been counted, unless a report went out in the last few minutes.
    ///
    /// - Parameter force: skip the throttle. For the token changing — the one moment a
    ///   report that could not be made a second ago now can.
    static func report(force: Bool = false) async {
        guard let settings, let remote, settings.isConfigured, settings.isRegistered else { return }
        guard !isReporting else { return }
        if !force, let lastReportAt, Date().timeIntervalSince(lastReportAt) < interval { return }

        var tally = load()
        tally.prune()
        store(tally)
        let report = tally.report()
        guard !report.counts.isEmpty else { return }

        isReporting = true
        defer { isReporting = false }
        lastReportAt = Date()

        do {
            let receipt = try await remote.reportUsage(report)
            settle(report)
            if receipt.refused > 0 {
                log.info("usage report: \(receipt.accepted) counted, \(receipt.refused) refused")
            }
        } catch APIError.unauthorized {
            // Kept, and the registration repaired the way every other route repairs it.
            log.info("usage report refused as unauthorised; re-checking registration")
            await BackgroundServices.syncNow()
        } catch APIError.server(let code, _) where (400..<500).contains(code) && code != 429 {
            // Refused for what it says, which will not change by sending it again.
            log.error("usage report refused with \(code); dropping it")
            settle(report)
        } catch {
            // Offline, a 5xx, or rate limited: all of it goes again next time.
            log.info("usage report deferred: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// One more chance on the way out, which is where a session's counts are freshest — under
    /// the same throttle, so a quick trip to another app costs nothing, and whatever it holds
    /// back goes with the next report.
    ///
    /// Inside a background task, because iOS suspends the process moments after it leaves
    /// the foreground, and a request it was in the middle of would otherwise only finish on
    /// the next launch — if at all.
    static func reportOnTheWayOut() {
        let assertion = BackgroundAssertion()
        assertion.begin()
        Task {
            await report()
            assertion.end()
        }
    }

    /// Holds a background task open for one report, and ends it exactly once — when the
    /// report finishes, or when iOS says time is up, whichever comes first.
    @MainActor
    private final class BackgroundAssertion {
        private var id = UIBackgroundTaskIdentifier.invalid

        func begin() {
            id = UIApplication.shared.beginBackgroundTask(withName: "usage-report") { [weak self] in
                MainActor.assumeIsolated { self?.end() }
            }
        }

        func end() {
            guard id != .invalid else { return }
            UIApplication.shared.endBackgroundTask(id)
            id = .invalid
        }
    }

    // MARK: - Storage

    private static func settle(_ sent: UsageReport) {
        var tally = load()
        tally.remove(sent.counts)
        store(tally)
    }

    private static func load() -> UsageTally {
        guard let data = UserDefaults.standard.data(forKey: key),
              let tally = try? JSONDecoder().decode(UsageTally.self, from: data)
        else { return UsageTally() }
        return tally
    }

    private static func store(_ tally: UsageTally) {
        if tally.isEmpty {
            UserDefaults.standard.removeObject(forKey: key)
        } else {
            UserDefaults.standard.set(try? JSONEncoder().encode(tally), forKey: key)
        }
    }
}

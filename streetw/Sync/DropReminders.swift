// DropReminders.swift
// Being told about a release *before* it happens.
//
// Every notification this app sends is retrospective. The server's `Notifier` pushes once an
// event has landed — a drop published, a restock, a markdown, a storefront going dark — and
// `WatchNotifier` fires locally once a restock has been observed. All of that is right, and
// all of it is after the fact.
//
// A drop calendar is the one screen about the future, and it announced nothing at all. You
// could open Upcoming, read "Stüssy · 28 Aug · 11:00", close the app, and hear from it for
// the first time when the products were already up and gone. The countdown was doing the
// work a notification is for, and only while you were looking at it.
//
// Two alerts per drop, because they answer different questions:
//
// - **On the day**, at breakfast. "This is today" is a planning fact — it decides whether
//   you are near a phone at eleven.
// - **At the release.** This is the one that matters. Streetwear is decided in the first
//   minute, so the useful alert is the one that arrives at the minute.
//
// Local notifications, scheduled ahead. No APNs key, no server round trip, no dependence on
// the poller having noticed anything — and they still fire with the phone offline, which a
// push cannot claim. That is also the only mechanism available: a `PlannedDrop` is a
// personal claim that never leaves the device, so there is nothing on the server that could
// know to send one.
//
// **The whole set is rewritten rather than diffed.** There are a handful of these, they are
// cheap to schedule, and the alternative is tracking which identifiers are outstanding
// across edits, deletions, brand renames and permission being revoked and granted again.
// A reconciliation that can drift produces the one failure this cannot have — an alert about
// a drop that was deleted, or silence about one that was not.

import Foundation
import OSLog
import StreetwCore
import SwiftData
import UserNotifications

@MainActor
enum DropReminders {
    private static let log = Logger(subsystem: "com.kern.functional.streetw", category: "drops")

    /// Everything scheduled here is prefixed, so the rewrite can clear its own alerts
    /// without touching a watch's — `WatchNotifier` schedules `watch-<uuid>` into the same
    /// notification centre, and a blanket `removeAllPendingNotificationRequests()` would
    /// take those with it.
    private static let prefix = "drop-"

    /// Re-schedules every reminder from the current set of planned drops.
    ///
    /// Call after anything that changes one. Cheap and idempotent by construction: it clears
    /// what it owns and re-adds from the store, so calling it twice is the same as calling
    /// it once and calling it after a crash is a repair.
    static func refresh(in context: ModelContext) async {
        let centre = UNUserNotificationCenter.current()

        // Never *asks*. Permission is requested from Settings and from the add sheet, both
        // behind an explicit action; prompting here would put a system alert in front of
        // somebody who has just typed a date. When it has been denied there is nothing to
        // schedule and the drop still shows on Upcoming with its countdown, which is the
        // honest degradation.
        guard await centre.notificationSettings().authorizationStatus != .denied else {
            await clear(in: centre)
            return
        }

        await clear(in: centre)

        let drops = (try? context.fetch(FetchDescriptor<PlannedDrop>())) ?? []
        let now = Date()
        var scheduled = 0

        for drop in drops {
            // A date in the past is history. `UNCalendarNotificationTrigger` does not treat
            // it that way — it matches *components*, so "11:00 on 28 August" quietly becomes
            // 28 August next year, and a drop nobody deleted would fire a reminder twelve
            // months later about something that happened last summer.
            guard drop.releaseAt > now else { continue }

            if drop.remindsOnTheDay, let morning = drop.morningReminder(now: now) {
                await add(
                    id: "\(prefix)day-\(drop.id.uuidString)",
                    at: morning,
                    title: drop.brandName.isEmpty ? "Dropping today" : drop.brandName,
                    body: "\(drop.label) drops today at \(time.string(from: drop.releaseAt)).",
                    brandID: drop.brand?.remoteID,
                    to: centre
                )
                scheduled += 1
            }

            if drop.remindsAtRelease {
                await add(
                    id: "\(prefix)release-\(drop.id.uuidString)",
                    at: drop.releaseAt,
                    title: drop.brandName.isEmpty ? "Dropping now" : drop.brandName,
                    body: "\(drop.label) is dropping now.",
                    brandID: drop.brand?.remoteID,
                    to: centre
                )
                scheduled += 1
            }
        }
        log.info("scheduled \(scheduled) drop reminders from \(drops.count) planned drops")
    }

    /// Drops the reminders for one planned drop without rebuilding the rest.
    ///
    /// Used on delete, where the row is gone from the store before `refresh` could read it —
    /// and calling it is belt-and-braces, since `refresh` clears everything it owns anyway.
    static func cancel(_ drop: PlannedDrop) {
        UNUserNotificationCenter.current().removePendingNotificationRequests(
            withIdentifiers: [
                "\(prefix)day-\(drop.id.uuidString)",
                "\(prefix)release-\(drop.id.uuidString)"
            ]
        )
    }

    private static func clear(in centre: UNUserNotificationCenter) async {
        let pending = await centre.pendingNotificationRequests()
            .map(\.identifier)
            .filter { $0.hasPrefix(prefix) }
        guard !pending.isEmpty else { return }
        centre.removePendingNotificationRequests(withIdentifiers: pending)
    }

    private static func add(
        id: String,
        at date: Date,
        title: String,
        body: String,
        brandID: UUID?,
        to centre: UNUserNotificationCenter
    ) async {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        // One thread for the whole app, matching the rule the server's pushes follow: iOS
        // groups by thread *within* an app, so a per-brand id gives every storefront its own
        // pile on the lock screen instead of one stack that says Dropwall.
        content.threadIdentifier = PushGrouping.threadID
        // So tapping it lands on the brand rather than on the feed. Read by
        // `PushDestination`, which is the same reader the server's payloads go through —
        // there is no second routing path to keep in step.
        //
        // The **remote** id, because that is the one `ContentView.follow` resolves against;
        // the local `Brand.id` would find nothing and silently drop the tap on the feed.
        // Standalone brands have none, and there the tap lands on the feed, correctly.
        if let brandID { content.userInfo = ["brandID": brandID.uuidString] }

        let components = Calendar.current.dateComponents(
            [.year, .month, .day, .hour, .minute], from: date
        )
        do {
            try await centre.add(
                UNNotificationRequest(
                    identifier: id,
                    content: content,
                    trigger: UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
                )
            )
        } catch {
            log.error("could not schedule \(id, privacy: .public): \(error.localizedDescription)")
        }
    }

    /// Built once. A `DateFormatter` resolves a locale and compiles a format, and this is
    /// read once per drop on every reschedule.
    private static let time: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter
    }()
}

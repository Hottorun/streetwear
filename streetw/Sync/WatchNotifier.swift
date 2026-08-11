// WatchNotifier.swift
// Firing stock watches from the client.
//
// The server is the real mechanism — it polls every few minutes and pushes, which is the
// entire reason a backend exists. This is the half that runs on the phone, and it exists
// for two reasons rather than as a duplicate:
//
// - **Standalone mode has no server at all.** A watch created there can only ever be
//   checked by the app itself.
// - **The transition can be observed locally.** In server mode the app already receives
//   the restock event; noticing that it satisfies a watch costs nothing and closes the
//   loop even if the push was missed, denied or throttled.
//
// Edge-triggered, not level-triggered. A watch fires on sold-out → buyable, once. Without
// that, every sync while the item is in stock is another notification about the same
// restock — the exact failure the server's `notified_at` ledger exists to prevent, and it
// has to be prevented here too.

import Foundation
import StreetwCore
import SwiftData
import UserNotifications

@MainActor
enum WatchNotifier {
    /// Checks every active watch against the current variant data and fires the ones that
    /// just became satisfiable. Safe to call after any sync.
    @discardableResult
    static func run(in context: ModelContext) async -> Int {
        let watches = (try? context.fetch(FetchDescriptor<StockWatch>())) ?? []
        var fired = 0

        for watch in watches where watch.isActive {
            guard let update = watch.update else { continue }
            let variants = update.variants

            // Nothing to compare against. A product whose source carries no variants
            // (a feed post, a page watch) falls back to whole-product availability.
            let satisfied = variants.isEmpty
                ? (update.isAvailable == true)
                : watch.isSatisfied(by: variants)

            defer { watch.wasAvailable = satisfied }

            // The edge. `wasAvailable` starts as whatever was true when the watch was
            // created, so watching something already in stock doesn't fire immediately.
            guard satisfied, !watch.wasAvailable else { continue }

            let back = watch.matching(variants)
                .filter(\.available)
                .map(\.displaySize)
                .filter { $0 != "Default Title" && !$0.isEmpty }

            watch.firedAt = Date()
            watch.firedSizes = back
            // Surfacing it in the feed as well as in a notification: an alert that is
            // swiped away should still leave the thing it was about somewhere findable.
            update.isSeen = false
            fired += 1

            await notify(update: update, watch: watch, sizes: back)
        }

        if fired > 0 { try? context.save() }
        return fired
    }

    /// A local notification, which needs no APNs key and no server round trip.
    ///
    /// Silently does nothing when notifications aren't authorized. Asking here would be
    /// the wrong moment — permission is requested from Settings, deliberately behind an
    /// explicit action — and a watch that can't announce itself still shows up in the
    /// feed and on the product page.
    private static func notify(update: BrandUpdate, watch: StockWatch, sizes: [String]) async {
        let centre = UNUserNotificationCenter.current()
        guard await centre.notificationSettings().authorizationStatus != .denied else { return }

        let content = UNMutableNotificationContent()
        content.title = update.brand?.name ?? "Back in stock"
        content.body = sizes.isEmpty
            ? "\(update.title) is back in stock"
            : "\(update.title) is back in \(list(sizes))"
        content.sound = .default
        // Grouped by brand, matching how the server threads its pushes, so a brand
        // restocking several watched items reads as one conversation.
        content.threadIdentifier = update.brand?.id.uuidString ?? "streetw"

        // Immediate: `nil` trigger delivers as soon as it is scheduled.
        try? await centre.add(
            UNNotificationRequest(
                identifier: "watch-\(watch.id.uuidString)",
                content: content,
                trigger: nil
            )
        )
    }

    /// "M", "M and L", "M, L and XL" — matching the server's wording exactly, so the two
    /// delivery paths are indistinguishable to the reader.
    private static func list(_ parts: [String]) -> String {
        switch parts.count {
        case 0: ""
        case 1: parts[0]
        case 2: "\(parts[0]) and \(parts[1])"
        default: parts.dropLast().joined(separator: ", ") + " and " + parts[parts.count - 1]
        }
    }
}

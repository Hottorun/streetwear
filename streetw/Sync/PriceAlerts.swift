// PriceAlerts.swift
// Being told when something you kept gets cheaper.
//
// **A rule from 1.0 changed on purpose.** A price drop is not sudden and never woke anybody:
// a markdown is worth as much next week, which is what the markdowns list is for. That is
// right about a markdown on a garment you have never seen, and wrong about one on the thing
// you saved — that is news about *you*, and "should I finally buy this" is the question a
// save is waiting to have answered.
//
// **Said on the phone, because saves never leave it.** The server knows what somebody
// watches and pushes a markdown on that itself (`Notifier.notifyWatchedPriceDrops`); what
// somebody saved it has never been told, by design. So this runs after every sync — the
// launch sync, a foreground refresh, a background wake, a push — reads the markdowns that
// just landed, and raises a local notification for any that is about a saved product.
// Standalone, where there is no server at all, it says the watched ones too.
//
// Ignores the brand's follow mode, like a watch: a quiet brand's markdown on the jacket you
// kept is still about the jacket. On by default, with its own switch in Alerts.

import Foundation
import StreetwCore
import SwiftData
import UserNotifications

@MainActor
enum PriceAlerts {
    /// The switch in Alerts. Absent means on.
    static let settingKey = "alertsSavedPriceDrops"

    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: settingKey) as? Bool ?? true
    }

    /// How far back a markdown can still be news. A sync after a week away should say what
    /// was cut while the app was closed, not what was cut in spring.
    static let window: TimeInterval = 3 * 86_400

    /// - Parameter serverPushesWatches: in server mode a watched product's markdown arrives
    ///   as a push, so saying it here too would be the same news twice. Standalone, nothing
    ///   else will say it.
    @discardableResult
    static func run(in context: ModelContext, serverPushesWatches: Bool) async -> Int {
        let cutoff = Date().addingTimeInterval(-window)
        // Narrowed on the same index `MarkdownsView` uses — `previousPriceAmount` is written
        // only where a row becomes a markdown — and the kind confirmed in Swift, because a
        // marked-down product that later restocks keeps the old price.
        let descriptor = FetchDescriptor<BrandUpdate>(
            predicate: #Predicate { $0.publishedAt >= cutoff && $0.previousPriceAmount != nil }
        )
        let drops = ((try? context.fetch(descriptor)) ?? []).filter {
            $0.kind == .priceDrop && $0.priceAmount != nil && $0.priceAlertedAmount != $0.priceAmount
        }
        guard !drops.isEmpty else { return 0 }

        // Asked of the saves and the watches, not of each row's relationships — those are
        // proportional to what somebody kept, and in server mode the save sits on an older
        // row for the same garment than the event that just arrived.
        let saved = Set(((try? context.fetch(FetchDescriptor<SavedItem>())) ?? []).compactMap { $0.update.map(key) })
        let watched = Set(
            ((try? context.fetch(FetchDescriptor<StockWatch>())) ?? [])
                .filter { $0.isActive && !(serverPushesWatches && $0.remoteID != nil) }
                .compactMap { $0.update.map(key) }
        )

        let allowed = isEnabled ? await canNotify() : false
        var said = 0
        var told = Set<String>()
        // Newest first, so two cuts landing in one sync say the latest, once.
        for drop in drops.sorted(by: BrandUpdate.newestFirst) {
            // Stamped whether or not anything is shown — switched off, not permitted, or not
            // about anything kept — so turning the switch on later does not fire a burst of
            // markdowns that already happened.
            drop.priceAlertedAmount = drop.priceAmount
            let product = key(drop)
            guard allowed, saved.contains(product) || watched.contains(product),
                  told.insert(product).inserted
            else { continue }
            await notify(drop, product: product)
            said += 1
        }
        try? context.save()
        return said
    }

    /// The garment, as both modes key it: a server event row names its product, a
    /// standalone row is the product.
    private static func key(_ update: BrandUpdate) -> String {
        update.productExternalID ?? update.externalID
    }

    private static func canNotify() async -> Bool {
        let status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        return status == .authorized || status == .provisional || status == .ephemeral
    }

    private static func notify(_ drop: BrandUpdate, product: String) async {
        let content = UNMutableNotificationContent()
        content.title = drop.brand?.name ?? "Price drop"
        // The server's wording for a watched markdown, so the two paths read the same.
        content.body = PriceChange.alert(
            title: drop.title,
            priceText: drop.priceText,
            percent: PriceChange.percentOff(
                previous: drop.previousPriceAmount,
                original: drop.originalPriceAmount,
                now: drop.priceAmount
            )
        )
        content.sound = .default
        // One thread for the app — `PushGrouping.threadID`, as every alert here.
        content.threadIdentifier = PushGrouping.threadID
        // Opens the markdown itself. Keyed by the row's own id rather than an event id, so
        // the same reader works for a standalone row (`shopify:<id>`) and a server one.
        var info: [String: String] = ["externalID": drop.externalID]
        if let brandID = drop.brand?.remoteID { info["brandID"] = brandID.uuidString }
        content.userInfo = info

        // Per product, so a second cut replaces an alert about the first that is still
        // waiting to be seen.
        try? await UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: "price-\(product)", content: content, trigger: nil)
        )
    }
}

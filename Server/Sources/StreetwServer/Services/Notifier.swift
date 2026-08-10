// Notifier.swift
// Turns events into pushes: who should hear about this, and what does it say.
//
// Deliberately free of APNs itself — delivery goes through `PushSending` so the whole
// fan-out (follows, size targeting, batching, dead-token pruning) is testable without a
// certificate or a network. `APNSPushSender` is the only piece that talks to Apple.
//
// Two rules shape everything here:
//
// - **One push per brand per pass, not one per event.** A brand dropping a collection
//   writes 250 events in a single poll. Fanning those out one-to-one would send 250
//   notifications, which is both a terrible experience and a fast route to being muted.
// - **`notified_at` is the ledger**, in the row rather than in memory, so a restart
//   cannot re-notify events that already went out — the same reasoning as
//   `next_check_at` on the poll queue.

import Fluent
import Foundation
import StreetwCore
import Vapor

/// A single notification, already addressed and worded.
struct PushMessage: Sendable, Hashable {
    var deviceToken: String
    /// "production" or "sandbox" — decides which APNs host the token is valid for.
    /// Sending to the wrong one is the classic "works in TestFlight, silent in
    /// development" bug, so it is carried per device rather than set globally.
    var environment: String
    var title: String
    var body: String
    var brandID: UUID
    /// Lets APNs replace an unread notification for the same brand rather than stacking.
    var collapseID: String?
}

enum PushDeliveryError: Error {
    /// The token is dead — the app was deleted or the token belongs to another topic.
    /// Distinguished from a transient failure because the response is to *forget* it,
    /// not to retry it.
    case invalidToken
}

protocol PushSending: Sendable {
    func send(_ message: PushMessage) async throws
}

/// What a notifier pass did. Returned rather than only logged so tests can assert on it.
struct NotifyResult: Sendable, Equatable {
    var events = 0
    var sent = 0
    var failed = 0
    var prunedTokens = 0
}

actor Notifier {
    private let app: Application
    private let sender: (any PushSending)?
    private var isRunning = false

    /// Events older than this are marked notified without being sent. After a long
    /// outage the backlog is history, not news, and firing it would be a burst of
    /// notifications about drops that already sold out.
    private let maxAge: TimeInterval

    init(app: Application, sender: (any PushSending)?, maxAge: TimeInterval = 6 * 3600) {
        self.app = app
        self.sender = sender
        self.maxAge = maxAge
    }

    /// One fan-out pass over everything not yet notified.
    @discardableResult
    func dispatch(limit: Int = 500) async -> NotifyResult {
        guard !isRunning else { return NotifyResult() }
        isRunning = true
        defer { isRunning = false }

        var result = NotifyResult()
        let db = app.db

        let pending: [EventModel]
        do {
            pending = try await EventModel.query(on: db)
                .filter(\.$notifiedAt == nil)
                .sort(\.$createdAt)
                .limit(limit)
                .with(\.$brand)
                .with(\.$product)
                .all()
        } catch {
            app.logger.error("notifier: could not load pending events: \(error)")
            return result
        }
        guard !pending.isEmpty else { return result }
        result.events = pending.count

        let cutoff = Date().addingTimeInterval(-maxAge)
        let fresh = pending.filter { ($0.createdAt ?? .distantPast) >= cutoff }

        // Even with no sender configured we still walk the ledger forward. Otherwise
        // the first deploy that *does* have APNs credentials would notify every event
        // ever recorded.
        if let sender, !fresh.isEmpty {
            for (brandID, events) in Dictionary(grouping: fresh, by: { $0.$brand.id }) {
                await notify(brandID: brandID, events: events, using: sender, into: &result)
            }
        }

        do {
            let ids = pending.compactMap(\.id)
            try await EventModel.query(on: db)
                .filter(\.$id ~~ ids)
                .set(\.$notifiedAt, to: Date())
                .update()
        } catch {
            // Worth shouting about: unmarked events are re-sent on the next pass, which
            // the user experiences as duplicate notifications.
            app.logger.error("notifier: could not mark events notified: \(error)")
        }

        if result.sent > 0 || result.failed > 0 {
            app.logger.info("notifier: sent \(result.sent), failed \(result.failed)")
        }
        return result
    }

    /// Everyone following one brand hears about that brand's batch at most once.
    private func notify(
        brandID: UUID,
        events: [EventModel],
        using sender: any PushSending,
        into result: inout NotifyResult
    ) async {
        let db = app.db
        let brandName = events.first?.brand.name ?? "A brand you follow"

        do {
            let followers = try await FollowModel.query(on: db)
                .filter(\.$brand.$id == brandID)
                .all()
                .map(\.$user.id)
            guard !followers.isEmpty else { return }

            let users = try await UserModel.query(on: db).filter(\.$id ~~ followers).all()
            let devices = try await DeviceModel.query(on: db)
                .filter(\.$user.$id ~~ followers)
                .filter(\.$apnsToken != nil)
                .all()
            guard !devices.isEmpty else { return }

            let devicesByUser = Dictionary(grouping: devices, by: { $0.$user.id })

            for user in users {
                guard let userID = user.id, let userDevices = devicesByUser[userID] else { continue }

                let profile = user.sizeProfile
                let relevant = events.filter { Self.isRelevant($0, to: profile) }
                guard let copy = Self.summary(brand: brandName, events: relevant) else { continue }

                for device in userDevices {
                    guard let token = device.apnsToken else { continue }
                    let message = PushMessage(
                        deviceToken: token,
                        environment: device.environment,
                        title: copy.title,
                        body: copy.body,
                        brandID: brandID,
                        collapseID: brandID.uuidString
                    )
                    do {
                        try await sender.send(message)
                        result.sent += 1
                    } catch PushDeliveryError.invalidToken {
                        // Stop paying for a token Apple has told us is gone. The device
                        // row stays — it still owns follows and a size profile, and the
                        // app re-registers a token on next launch.
                        device.apnsToken = nil
                        try? await device.save(on: db)
                        result.prunedTokens += 1
                    } catch {
                        app.logger.warning("notifier: push failed: \(error)")
                        result.failed += 1
                    }
                }
            }
        } catch {
            app.logger.error("notifier: fan-out failed for brand \(brandID): \(error)")
        }
    }

    /// Size targeting. A restock is only news if it came back in a size you wear —
    /// that is the entire point of holding a size profile server-side.
    ///
    /// Everything else goes to every follower: a new product has no size axis worth
    /// filtering on yet, and a drop lock is about the storefront, not an item.
    static func isRelevant(_ event: EventModel, to profile: SizeProfile) -> Bool {
        guard UpdateKind(rawValue: event.kind) == .restock else { return true }
        guard !profile.isEmpty, !event.sizes.isEmpty else { return true }
        return event.sizes.contains { profile.matches($0) }
    }

    /// The notification text for one brand's batch. `nil` when there is nothing to say.
    static func summary(brand: String, events: [EventModel]) -> (title: String, body: String)? {
        guard !events.isEmpty else { return nil }

        if events.count == 1, let event = events.first {
            let kind = UpdateKind(rawValue: event.kind) ?? .product
            let name = event.product?.title
            switch kind {
            case .restock:
                let sizes = event.sizes.filter { $0 != "Default Title" && !$0.isEmpty }
                let back = sizes.isEmpty ? "Back in stock" : "Back in \(list(sizes))"
                return (brand, name.map { "\(back) — \($0)" } ?? back)
            case .product:
                return (brand, name.map { "New: \($0)" } ?? "Something new just landed")
            case .collection:
                return (brand, name.map { "New collection: \($0)" } ?? "A new collection just landed")
            case .dropLock:
                // The shock-drop signal: a storefront locking down usually means minutes,
                // not hours — so this one is worded to get someone off the sofa.
                return (brand, "Storefront just locked — a drop looks imminent")
            case .pageChange:
                return (brand, "Something changed on the site")
            case .post:
                return (brand, name ?? "New post")
            }
        }

        // Mixed batch: counts, not a list. Nobody reads a 250-item notification.
        var parts: [String] = []
        let byKind = Dictionary(grouping: events, by: { UpdateKind(rawValue: $0.kind) ?? .product })
        if let new = byKind[.product]?.count { parts.append("\(new) new item\(new == 1 ? "" : "s")") }
        if let restocks = byKind[.restock]?.count { parts.append("\(restocks) restock\(restocks == 1 ? "" : "s")") }
        if let collections = byKind[.collection]?.count {
            parts.append("\(collections) new collection\(collections == 1 ? "" : "s")")
        }
        if byKind[.dropLock] != nil { parts.append("a storefront lock") }
        if parts.isEmpty { parts.append("\(events.count) updates") }

        return (brand, sentence(parts))
    }

    /// "M", "M and L", "M, L and XL".
    private static func list(_ items: [String]) -> String {
        sentence(items)
    }

    private static func sentence(_ parts: [String]) -> String {
        switch parts.count {
        case 0: return ""
        case 1: return parts[0]
        case 2: return "\(parts[0]) and \(parts[1])"
        default: return parts.dropLast().joined(separator: ", ") + " and " + parts[parts.count - 1]
        }
    }
}

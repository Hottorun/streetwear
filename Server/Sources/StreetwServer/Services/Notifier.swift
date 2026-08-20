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
    /// The one event this is about, when there is one. Tapping the notification opens that
    /// item's page rather than dropping the user on a tab to find it themselves — which
    /// for a restock in a size they wear is the entire point of the alert.
    ///
    /// Nil for a counted summary, where no single product is *the* one.
    var eventID: UUID?
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

/// What a `probe` pass did, reported per device rather than as totals.
///
/// Totals are the wrong shape for the question a probe answers. "sent 0, failed 0" is
/// true when no device holds a token, when APNs rejected every one, and when the sender
/// isn't configured — three different problems with three different fixes, and the
/// existing `NotifyResult` cannot tell them apart.
struct ProbeResult: Sendable, Equatable {
    /// Why a single device did or didn't receive the test push.
    enum Outcome: String, Sendable {
        case sent
        /// The device never handed us a token — almost always a missing
        /// `aps-environment` entitlement on the app, not a server problem.
        case noToken
        /// Apple says the token is dead or belongs to another topic. Pruned, as in a
        /// real pass.
        case invalidToken
        case failed
    }

    struct Device: Sendable, Equatable {
        var deviceID: UUID
        var environment: String
        var outcome: Outcome
        /// The underlying error, when there was one. This is the line worth reading.
        var detail: String?
    }

    /// Nil sender — no APNs credentials on this deployment. Distinguished from "no
    /// devices" because the two look identical in any count-based summary.
    var senderConfigured = false
    var devices: [Device] = []

    var sent: Int { devices.count { $0.outcome == .sent } }
    var withToken: Int { devices.count { $0.outcome != .noToken } }

    /// One line, for an admin route whose whole job is to be read by eye in a terminal.
    var summary: String {
        guard senderConfigured else {
            return "apns not configured — no key on this deployment, nothing was sent"
        }
        guard !devices.isEmpty else { return "no devices registered" }
        guard withToken > 0 else {
            return "\(devices.count) device(s), none holding an apns token — "
                + "the app is not registering for remote notifications "
                + "(check the aps-environment entitlement)"
        }
        let lines = devices.map { device in
            "  \(device.deviceID) [\(device.environment)] \(device.outcome.rawValue)"
                + (device.detail.map { " — \($0)" } ?? "")
        }
        return "sent \(sent)/\(withToken):\n" + lines.joined(separator: "\n")
    }
}

actor Notifier {
    private let app: Application
    private let sender: (any PushSending)?
    private var isRunning = false

    /// Events older than this are marked notified without being sent. After a long
    /// outage the backlog is history, not news, and firing it would be a burst of
    /// notifications about drops that already sold out.
    private let maxAge: TimeInterval

    /// How long a brand stays quiet after it has interrupted somebody.
    ///
    /// **The fix for a drop arriving as a trickle.** A storefront does not publish a
    /// collection in one write — it puts out a few products, then a few more, and the poller
    /// is on a five-minute cadence while something is happening. Each pass found two or three
    /// new events and each pass sent a push, so a single release read as "2 new items", then
    /// "2 new items", then "3 new items" over half an hour. One-push-per-brand-per-*pass* was
    /// never the right unit; a pass is an implementation detail of the poll loop.
    ///
    /// So the rule is one push per brand per cooldown, and the ordering matters: the **first**
    /// sighting goes out immediately, because being told about a drop late is the one failure
    /// this app cannot afford. Everything that lands during the cooldown is *held* — left
    /// unmarked in the ledger, not discarded — and folded into one consolidated summary when
    /// it lifts. A drop therefore reads as "New: Chore Jacket" and then, once, "14 new items
    /// and 2 restocks".
    ///
    /// Fifteen minutes: comfortably longer than the five-minute active-drop cadence, so
    /// consecutive polls merge, and short enough that the follow-up still arrives while the
    /// thing is on sale.
    ///
    /// A watch alert is deliberately **not** subject to this. It is the one notification
    /// somebody explicitly asked for, about one product in one size, and it is never part of
    /// a trickle — see `notifyWatches`.
    private let cooldown: TimeInterval

    init(
        app: Application,
        sender: (any PushSending)?,
        maxAge: TimeInterval = 6 * 3600,
        cooldown: TimeInterval = 15 * 60
    ) {
        self.app = app
        self.sender = sender
        self.maxAge = maxAge
        self.cooldown = cooldown
    }

    /// Sends one synthetic notification straight to registered devices, bypassing
    /// events, follows, freshness and size targeting entirely.
    ///
    /// This exists because the real pipeline is untestable on demand. A push only
    /// happens when a storefront independently decides to restock something, and until
    /// it does, every layer reports healthy: `/status` says `apnsConfigured: true`, the
    /// poller runs, the feed fills, `pendingPushes` sits at 0 — and not one notification
    /// has ever been delivered. `dispatch` cannot be used to check this either, since it
    /// only ever walks *pending* events and there are none.
    ///
    /// So this deliberately tests one link and no others: is the key valid, is the topic
    /// right, is the token real, is it on the host its environment claims. A failure
    /// here is an APNs problem. A success here plus a silent restock is a pipeline
    /// problem, and that is a genuinely different search.
    ///
    /// Nothing is written to the ledger, so this can be run as often as needed and can
    /// never suppress a real notification.
    func probe(deviceID: UUID? = nil) async -> ProbeResult {
        var result = ProbeResult(senderConfigured: sender != nil)

        let devices: [DeviceModel]
        do {
            let query = DeviceModel.query(on: app.db)
            if let deviceID { query.filter(\.$id == deviceID) }
            devices = try await query.all()
        } catch {
            app.logger.error("notifier: probe could not load devices: \(error)")
            return result
        }

        for device in devices {
            guard let id = device.id else { continue }

            guard let token = device.apnsToken else {
                result.devices.append(
                    .init(deviceID: id, environment: device.environment, outcome: .noToken)
                )
                continue
            }
            // Reported rather than skipped: with no sender we still want the token
            // inventory, which is the other half of "why is it silent".
            guard let sender else {
                result.devices.append(
                    .init(
                        deviceID: id,
                        environment: device.environment,
                        outcome: .failed,
                        detail: "apns not configured"
                    )
                )
                continue
            }

            let message = PushMessage(
                deviceToken: token,
                environment: device.environment,
                title: "streetw",
                body: "Test push — if you can read this, alerts work.",
                brandID: Self.probeBrandID,
                // No collapse id on purpose. A real batch collapses so a brand can't
                // stack up unread; a test is run repeatedly and each one must be visible,
                // otherwise the second run looks like a failure.
                collapseID: nil
            )

            do {
                try await sender.send(message)
                result.devices.append(
                    .init(deviceID: id, environment: device.environment, outcome: .sent)
                )
            } catch PushDeliveryError.invalidToken {
                device.apnsToken = nil
                try? await device.save(on: app.db)
                result.devices.append(
                    .init(
                        deviceID: id,
                        environment: device.environment,
                        outcome: .invalidToken,
                        detail: "apple rejected the token; it has been forgotten"
                    )
                )
            } catch {
                result.devices.append(
                    .init(
                        deviceID: id,
                        environment: device.environment,
                        outcome: .failed,
                        detail: String(describing: error)
                    )
                )
            }
        }

        app.logger.notice("notifier: probe — \(result.summary)")
        return result
    }

    /// Sentinel brand id in the probe's payload. The client treats a push as a nudge to
    /// pull the feed and does nothing with an unknown brand, so this stays inert rather
    /// than deep-linking somewhere that doesn't exist.
    static let probeBrandID = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!

    /// One fan-out pass over everything not yet notified.
    @discardableResult
    func dispatch(limit: Int = 500) async -> NotifyResult {
        guard !isRunning else { return NotifyResult() }
        isRunning = true
        defer { isRunning = false }

        var result = NotifyResult()
        let db = app.db

        let now = Date()

        // Brands still inside their cooldown, excluded **in the query** rather than filtered
        // out afterwards. Their events must stay pending so they can be folded into one
        // consolidated summary when the cooldown lifts — but a brand mid-drop can hold
        // hundreds of them, and with the batch sorted oldest-first they would fill the whole
        // `limit` and starve every other brand of notifications for a quarter of an hour.
        // Leaving them out of the batch spends the budget on brands that can actually send.
        let quiet: [UUID]
        do {
            quiet = try await BrandModel.query(on: db)
                .filter(\.$lastNotifiedAt > now.addingTimeInterval(-cooldown))
                .all()
                .compactMap(\.id)
        } catch {
            app.logger.error("notifier: could not read the cooldown ledger: \(error)")
            return result
        }

        let pending: [EventModel]
        do {
            let query = EventModel.query(on: db).filter(\.$notifiedAt == nil)
            // Guarded: an empty `!~` is not a query anybody wants to hand to a database.
            if !quiet.isEmpty { query.filter(\.$brand.$id !~ quiet) }
            pending = try await query
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

        let cutoff = now.addingTimeInterval(-maxAge)
        let fresh = pending.filter { ($0.createdAt ?? .distantPast) >= cutoff }

        // Even with no sender configured we still walk the ledger forward. Otherwise
        // the first deploy that *does* have APNs credentials would notify every event
        // ever recorded.
        if let sender, !fresh.isEmpty {
            // Watches first, and they suppress the generic summary for the same person
            // and brand. A watch is a far stronger statement than a follow — "I want this
            // exact thing in this exact size" — so when both would fire, the specific one
            // wins rather than the item being buried inside "3 restocks". The
            // one-push-per-brand rule still holds; this only decides *which* push that is.
            //
            // Deliberately outside the cooldown. A watch is the one alert somebody asked
            // for by name, it is about a single product in a single size, and it is never
            // the thing that arrives as a trickle.
            let claimed = await notifyWatches(fresh, using: sender, into: &result)

            let brands = try? await BrandModel.query(on: db)
                .filter(\.$id ~~ Array(Set(fresh.map { $0.$brand.id })))
                .all()
            let byID = Dictionary(
                (brands ?? []).compactMap { brand in brand.id.map { ($0, brand) } },
                uniquingKeysWith: { first, _ in first }
            )

            for (brandID, events) in Dictionary(grouping: fresh, by: { $0.$brand.id }) {
                let brand = byID[brandID]
                let before = result.sent
                await notify(
                    brandID: brandID,
                    events: events,
                    using: sender,
                    skipping: claimed,
                    into: &result
                )
                // Stamped only when something actually went out. A brand filtered away for
                // every follower — wrong gender, wrong size — has not interrupted anybody
                // and must not be muted for a quarter of an hour on the strength of it.
                if result.sent > before, let brand {
                    brand.lastNotifiedAt = now
                    try? await brand.save(on: db)
                }
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

    /// Fires standing stock watches satisfied by this pass's restocks.
    ///
    /// Evaluated against the product's *current* variants rather than the event's size
    /// list, because a watch can be pinned to a colour and the event carries only sizes.
    /// The restock event existing is what makes this edge-triggered — the poller writes
    /// one exactly when something goes sold-out → buyable — and `fired_at` is the ledger
    /// that stops a second pass re-firing it.
    ///
    /// Returns the (user, brand) pairs that received a watch alert, so the generic brand
    /// summary can skip them.
    private func notifyWatches(
        _ events: [EventModel],
        using sender: any PushSending,
        into result: inout NotifyResult
    ) async -> Set<Pair> {
        var claimed: Set<Pair> = []

        let restockedProducts = Set(
            events
                .filter { UpdateKind(rawValue: $0.kind) == .restock }
                .compactMap(\.$product.id)
        )
        guard !restockedProducts.isEmpty else { return claimed }

        do {
            let watches = try await WatchModel.query(on: app.db)
                .filter(\.$product.$id ~~ Array(restockedProducts))
                .filter(\.$firedAt == nil)
                .with(\.$product) { $0.with(\.$variants) }
                .with(\.$brand)
                .all()
            guard !watches.isEmpty else { return claimed }

            let userIDs = Set(watches.map(\.$user.id))
            let devices = try await DeviceModel.query(on: app.db)
                .filter(\.$user.$id ~~ Array(userIDs))
                .filter(\.$apnsToken != nil)
                .all()
            let devicesByUser = Dictionary(grouping: devices, by: { $0.$user.id })

            // The restock event that satisfied each watch, so the alert can open the exact
            // product rather than the brand it belongs to.
            let restockEvent = Dictionary(
                events
                    .filter { UpdateKind(rawValue: $0.kind) == .restock }
                    .compactMap { event in event.$product.id.map { ($0, event) } },
                uniquingKeysWith: { first, _ in first }
            )

            for watch in watches {
                let variants = watch.product.variants.map(\.asVariantInfo)
                let back = watch.target.availableSizes(in: variants)
                guard watch.target.isSatisfied(by: variants) else { continue }

                // Stamped whether or not a device is reachable, for the same reason
                // `events.notified_at` is: a user with no token must not accumulate a
                // watch that fires the instant they register one, months later.
                watch.firedAt = Date()
                watch.firedSizes = back
                try? await watch.save(on: app.db)

                claimed.insert(Pair(user: watch.$user.id, brand: watch.$brand.id))

                for device in devicesByUser[watch.$user.id] ?? [] {
                    guard let token = device.apnsToken else { continue }
                    let message = PushMessage(
                        deviceToken: token,
                        environment: device.environment,
                        title: watch.brand.name,
                        body: Self.watchCopy(product: watch.product.title, sizes: back),
                        brandID: watch.$brand.id,
                        eventID: restockEvent[watch.$product.id]?.id,
                        // Not collapsed onto the brand's other notifications: this is the
                        // one the user explicitly asked for and it must not be replaced by
                        // a later generic summary.
                        collapseID: nil
                    )
                    do {
                        try await sender.send(message)
                        result.sent += 1
                    } catch PushDeliveryError.invalidToken {
                        device.apnsToken = nil
                        try? await device.save(on: app.db)
                        result.prunedTokens += 1
                    } catch {
                        app.logger.warning("notifier: watch push failed: \(error)")
                        result.failed += 1
                    }
                }
            }
        } catch {
            app.logger.error("notifier: watch fan-out failed: \(error)")
        }

        return claimed
    }

    /// "Back in M — Nathan Cargo Pant". Names the product, because a watch is about one
    /// specific thing and a summary would defeat the point of setting it.
    static func watchCopy(product: String, sizes: [String]) -> String {
        sizes.isEmpty
            ? "Back in stock — \(product)"
            : "Back in \(sentence(sizes)) — \(product)"
    }

    /// A user/brand pair that has already been notified in this pass.
    struct Pair: Hashable, Sendable {
        var user: UUID
        var brand: UUID
    }

    /// Everyone following one brand hears about that brand's batch at most once.
    private func notify(
        brandID: UUID,
        events: [EventModel],
        using sender: any PushSending,
        skipping claimed: Set<Pair> = [],
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
                // Already told about this brand by a watch alert, which said something
                // more specific than this summary would.
                guard !claimed.contains(Pair(user: userID, brand: brandID)) else { continue }

                let profile = user.sizeProfile
                let relevant = events.filter { Self.isRelevant($0, to: profile) }
                guard let copy = Self.summary(brand: brandName, events: relevant) else { continue }
                // Only when the alert names one thing. A counted summary ("3 restocks and
                // 2 new items") has no single product behind it, and picking one of them
                // to open would be arbitrary — the brand is the honest destination.
                let single = relevant.count == 1 ? relevant.first?.id : nil

                for device in userDevices {
                    guard let token = device.apnsToken else { continue }
                    let message = PushMessage(
                        deviceToken: token,
                        environment: device.environment,
                        title: copy.title,
                        body: copy.body,
                        brandID: brandID,
                        eventID: single,
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

    /// Size and gender targeting. A restock is only news if it came back in a size you
    /// wear — that is the entire point of holding a size profile server-side.
    ///
    /// Everything else goes to every follower: a new product has no size axis worth
    /// filtering on yet, and a drop lock is about the storefront, not an item.
    static func isRelevant(_ event: EventModel, to profile: SizeProfile) -> Bool {
        // Gender applies to every kind, not just restocks. Being woken at 7am for a
        // women's hoodie is worse than merely seeing one in the feed, so if the filter
        // is worth having anywhere it is worth having here first.
        //
        // A drop lock has no product, so it has no gender and always passes — it is about
        // the storefront rather than an item.
        if let product = event.product, !profile.allows(product.gender) { return false }

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
            case .priceDrop:
                return (brand, name.map { "Price drop: \($0)" } ?? "Something you follow just got cheaper")
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
        if let drops = byKind[.priceDrop]?.count { parts.append("\(drops) price drop\(drops == 1 ? "" : "s")") }
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

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
    /// The profile this alert is about — the recipient user, when it is on an account — so
    /// tapping it opens that profile before the item. Nil for an anonymous user, whose phone
    /// has one profile and nothing to switch. See `docs/profiles.md`.
    var profileID: UUID?
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

    /// Brands whose fan-out hit a *transient* failure this pass — a 503 from Apple, a TLS
    /// blip, a dropped connection — as opposed to a token Apple has told us is dead.
    ///
    /// Their still-fresh events are left unstamped so the next pass tries again. Without
    /// this, `notified_at` was written for every *pending* event whatever happened to it:
    /// a single bad minute at Apple silently consumed the alert, with no retry and nothing
    /// that would ever revisit it.
    ///
    /// The retry is bounded by `maxAge` and needs no counter of its own: once an event is
    /// older than the freshness window it is no longer news, falls out of `fresh`, and is
    /// stamped like any other stale event. So a brand that fails forever costs one extra
    /// attempt per pass until its events age out, not an unbounded queue.
    var retryableBrands: Set<UUID> = []
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
                title: "Dropwall",
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

    /// Tells one person how a request of theirs turned out — today, only that a shop they
    /// asked to watch has been checked (`BrandChecks`).
    ///
    /// Outside the event ledger and the cooldown on purpose: it is not news about a brand,
    /// it is the answer to something this person asked a minute ago, and it is sent once
    /// because the watcher row is what records that it was. A nil brand sends the probe's
    /// sentinel, which the app opens nowhere — a refused shop has no page to land on.
    func tell(userID: UUID, title: String, body: String, brandID: UUID?, collapseID: String) async {
        guard let sender else { return }
        let recipient: Recipient
        do {
            guard let found = try await Self.audience(for: [userID], on: app.db)[userID] else { return }
            recipient = found
        } catch {
            app.logger.error("notifier: could not load devices for a reply: \(error)")
            return
        }
        for device in recipient.devices {
            guard let token = device.apnsToken else { continue }
            let message = PushMessage(
                deviceToken: token,
                environment: device.environment,
                title: title,
                body: recipient.labelled(body),
                brandID: brandID ?? Self.probeBrandID,
                collapseID: recipient.collapse(collapseID),
                profileID: recipient.profileID
            )
            do {
                try await sender.send(message)
            } catch PushDeliveryError.invalidToken {
                device.apnsToken = nil
                try? await device.save(on: app.db)
            } catch {
                app.logger.warning("notifier: reply not delivered: \(error)")
            }
        }
    }

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
            let open = try await query
                .sort(\.$createdAt)
                .limit(limit)
                .with(\.$brand)
                .with(\.$product)
                .all()
            // **The cooldown never applied to a watch, and this is what makes that true.**
            // Excluding a cooled brand's events from the batch also excluded the restock — or
            // the markdown — somebody was watching for, so the one alert asked for by name
            // waited out a quarter of an hour behind the brand's drop. Only the kinds a watch
            // answers to are loaded, and they are not sudden, so stamping them now takes
            // nothing from the summary the cooldown is holding.
            let watchable = quiet.isEmpty ? [] : try await EventModel.query(on: db)
                .filter(\.$notifiedAt == nil)
                .filter(\.$brand.$id ~~ quiet)
                .filter(\.$kind ~~ [UpdateKind.restock.rawValue, UpdateKind.priceDrop.rawValue])
                .sort(\.$createdAt)
                .limit(limit)
                .with(\.$brand)
                .with(\.$product)
                .all()
            pending = open + watchable
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

            // The country shops of the brands in this pass, so each follower hears only from the
            // shop they are served — see `Storefronts`. Not asked at all while no country is
            // switched on, which leaves every follower on the main shop as before.
            let enabled = app.storefrontCountries
            let shops = enabled.isEmpty ? [] : (try? await StorefrontModel.query(on: db)
                .filter(\.$brand.$id ~~ Array(Set(fresh.map { $0.$brand.id })))
                .filter(\.$country ~~ Array(enabled))
                .with(\.$sources)
                .all()) ?? []
            let shopsByBrand = Dictionary(grouping: shops, by: { $0.$brand.id })

            let cooling = Set(quiet)
            for (brandID, events) in Dictionary(grouping: fresh, by: { $0.$brand.id }) where !cooling.contains(brandID) {
                let brand = byID[brandID]
                let before = result.sent
                await notify(
                    brandID: brandID,
                    events: events,
                    storefronts: shopsByBrand[brandID] ?? [],
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
            // **Not every pending event — only the ones this pass is actually finished
            // with.** An event whose brand hit a transient failure keeps its null
            // `notified_at` so the next pass picks it up, *provided it is still fresh*;
            // anything past `maxAge` is stamped regardless, because it has stopped being
            // news and retrying it forever would be worse than dropping it.
            let deferred = Set(
                fresh
                    .filter { result.retryableBrands.contains($0.$brand.id) }
                    .compactMap(\.id)
            )
            let ids = pending.compactMap(\.id).filter { !deferred.contains($0) }
            guard !ids.isEmpty else {
                app.logger.info("notifier: deferred \(deferred.count) event(s) for retry")
                return result
            }
            if !deferred.isEmpty {
                app.logger.info("notifier: deferred \(deferred.count) event(s) for retry")
            }
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
        var claimed = await notifyWatchedPriceDrops(events, using: sender, into: &result)

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

            let audience = try await Self.audience(for: Set(watches.map(\.$user.id)), on: app.db)

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
                let context = watch.product.sizeContext(sizes: variants.map(\.displaySize))
                let back = watch.target.availableSizes(in: variants, context: context)
                guard watch.target.isSatisfied(by: variants, in: context) else { continue }

                // Stamped whether or not a device is reachable, for the same reason
                // `events.notified_at` is: a user with no token must not accumulate a
                // watch that fires the instant they register one, months later.
                watch.firedAt = Date()
                watch.firedSizes = back
                try? await watch.save(on: app.db)

                claimed.insert(Pair(user: watch.$user.id, brand: watch.$brand.id))

                // A profile with alerts off has no recipient here: the watch above is still
                // spent, for the reason it is spent when no device holds a token.
                guard let recipient = audience[watch.$user.id] else { continue }
                for device in recipient.devices {
                    guard let token = device.apnsToken else { continue }
                    let message = PushMessage(
                        deviceToken: token,
                        environment: device.environment,
                        title: watch.brand.name,
                        body: recipient.labelled(Self.watchCopy(product: watch.product.title, sizes: back)),
                        brandID: watch.$brand.id,
                        eventID: restockEvent[watch.$product.id]?.id,
                        // Not collapsed onto the brand's other notifications: this is the
                        // one the user explicitly asked for and it must not be replaced by
                        // a later generic summary.
                        collapseID: nil,
                        profileID: recipient.profileID
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
                        result.retryableBrands.insert(watch.$brand.id)
                    }
                }
            }
        } catch {
            app.logger.error("notifier: watch fan-out failed: \(error)")
        }

        return claimed
    }

    /// A markdown on something somebody is watching — the one price drop worth a push.
    ///
    /// **A rule from 1.0 changed on purpose.** A price drop is not sudden and never woke
    /// anybody: a markdown is worth as much next week, which is what the markdowns list is
    /// for. That is right about a markdown on a garment you have never seen and wrong about
    /// one on the thing you asked to be told about by name — that is news about *you*. The
    /// server cannot know what somebody saved (saves never leave the phone; the phone says
    /// that half itself, see `PriceAlerts`), but it knows watches.
    ///
    /// It goes by the watch path's rules, not the summary's: **no cooldown**, and it does not
    /// start one; **no follow mode**, so a quiet brand's markdown still reaches the person
    /// watching one of its products; no size or gender filter, because the product was
    /// chosen. It does not spend the watch — `fired_at` is the restock's ledger, and a cheaper
    /// sold-out jacket is still a jacket somebody is waiting to come back. Only **active**
    /// watches: one that has fired has been answered. `events.notified_at` is its ledger, so
    /// each markdown is said once. One push per person per product per pass, and it claims
    /// that person's brand summary exactly as a restock alert does.
    private func notifyWatchedPriceDrops(
        _ events: [EventModel],
        using sender: any PushSending,
        into result: inout NotifyResult
    ) async -> Set<Pair> {
        var claimed: Set<Pair> = []
        let drops = Dictionary(
            events
                .filter { UpdateKind(rawValue: $0.kind) == .priceDrop }
                .compactMap { event in event.$product.id.map { ($0, event) } },
            uniquingKeysWith: { first, _ in first }
        )
        guard !drops.isEmpty else { return claimed }

        do {
            let watches = try await WatchModel.query(on: app.db)
                .filter(\.$product.$id ~~ Array(drops.keys))
                .filter(\.$firedAt == nil)
                .with(\.$product)
                .with(\.$brand)
                .all()
            guard !watches.isEmpty else { return claimed }

            let audience = try await Self.audience(for: Set(watches.map(\.$user.id)), on: app.db)

            var told: Set<String> = []
            for watch in watches {
                let productID = watch.$product.id
                // Two watches on one product — an M in black, an L in sand — are one markdown.
                guard let event = drops[productID],
                      told.insert("\(watch.$user.id)/\(productID)").inserted
                else { continue }
                claimed.insert(Pair(user: watch.$user.id, brand: watch.$brand.id))

                let product = watch.product
                let body = PriceChange.alert(
                    title: product.title,
                    priceText: product.priceText,
                    percent: PriceChange.percentOff(
                        previous: event.previousPriceAmount,
                        original: product.originalPriceAmount,
                        now: product.priceAmount
                    )
                )
                guard let recipient = audience[watch.$user.id] else { continue }
                for device in recipient.devices {
                    guard let token = device.apnsToken else { continue }
                    let message = PushMessage(
                        deviceToken: token,
                        environment: device.environment,
                        title: watch.brand.name,
                        body: recipient.labelled(body),
                        brandID: watch.$brand.id,
                        eventID: event.id,
                        // A second cut on the same product replaces the first if it is
                        // still unread; a different product never does — and neither does
                        // the same cut said to another profile on the phone.
                        collapseID: recipient.collapse("price-\(productID.uuidString)"),
                        profileID: recipient.profileID
                    )
                    do {
                        try await sender.send(message)
                        result.sent += 1
                    } catch PushDeliveryError.invalidToken {
                        device.apnsToken = nil
                        try? await device.save(on: app.db)
                        result.prunedTokens += 1
                    } catch {
                        app.logger.warning("notifier: price-drop push failed: \(error)")
                        result.failed += 1
                        result.retryableBrands.insert(watch.$brand.id)
                    }
                }
            }
        } catch {
            app.logger.error("notifier: price-drop fan-out failed: \(error)")
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

    /// A user/brand pair that has already been notified in this pass. Per user, which is per
    /// profile: a watch alert for one profile suppresses that profile's summary and nobody
    /// else's on the same phone.
    struct Pair: Hashable, Sendable {
        var user: UUID
        var brand: UUID
    }

    /// Where one user's alerts go, and how they are marked as theirs.
    struct Recipient: Sendable {
        var devices: [DeviceModel]
        /// The profile's name, when the user is a profile other than its account's holder.
        /// Nil for the holder and for anonymous users, whose alerts read as they always have.
        var label: String?
        /// The user, when it is on an account — what `PushPayload.profileID` carries.
        var profileID: UUID?

        func labelled(_ body: String) -> String {
            label.map { ProfileAlert.labelled(body, for: $0) } ?? body
        }

        /// A collapse id of this profile's own. The holder keeps the plain one, so nothing
        /// changes for any phone with one profile; another profile appends its first eight
        /// hex digits — APNs caps the id at 64 bytes, and two UUIDs are 73.
        func collapse(_ base: String) -> String {
            guard label != nil, let profileID else { return base }
            return "\(base)/\(profileID.uuidString.prefix(8))"
        }
    }

    /// Who hears about each of `userIDs`, and labelled how. See `docs/profiles.md`.
    ///
    /// - **A user on an account is heard on every device of that account.** Devices belong to
    ///   the holder, so a profile has none of its own; its alerts reach the phones its holder
    ///   carries. An anonymous user's devices are its own, as they always were.
    /// - **A profile with alerts off is left out**, holder included. Callers that keep a ledger
    ///   — the watch's `fired_at`, the event's `notified_at` — still write it, so switching
    ///   alerts back on does not release a burst of stale news.
    /// - **Labelled only when it is not the holder.** "For Anna: …" on the body; the holder's
    ///   alerts are unchanged.
    ///
    /// Four queries whatever the size of the batch: the users, their accounts' users, and the
    /// devices of both.
    static func audience(for userIDs: Set<UUID>, on db: any Database) async throws -> [UUID: Recipient] {
        guard !userIDs.isEmpty else { return [:] }
        let users = try await UserModel.query(on: db)
            .filter(\.$id ~~ Array(userIDs))
            .filter(\.$alertsEnabled == true)
            .all()
        let accountIDs = Set(users.compactMap(\.$account.id))
        let members = accountIDs.isEmpty ? [] : try await UserModel.query(on: db)
            .filter(\.$account.$id ~~ Array(accountIDs))
            .all()

        var membersByAccount: [UUID: [UserModel]] = [:]
        for member in members {
            guard let accountID = member.$account.id else { continue }
            membersByAccount[accountID, default: []].append(member)
        }
        let holders = membersByAccount.compactMapValues { users in
            users.min(by: Accounts.holderFirst)?.id
        }

        let owners = Set(users.compactMap(\.id)).union(members.compactMap(\.id))
        let devices = try await DeviceModel.query(on: db)
            .filter(\.$user.$id ~~ Array(owners))
            .filter(\.$apnsToken != nil)
            .all()
        let devicesByOwner = Dictionary(grouping: devices, by: { $0.$user.id })

        var audience: [UUID: Recipient] = [:]
        for user in users {
            guard let id = user.id else { continue }
            guard let accountID = user.$account.id else {
                audience[id] = Recipient(devices: devicesByOwner[id] ?? [])
                continue
            }
            let phones = (membersByAccount[accountID] ?? []).compactMap(\.id).flatMap { devicesByOwner[$0] ?? [] }
            let isHolder = holders[accountID] == id
            audience[id] = Recipient(
                devices: phones,
                // A profile always has a name; the fallback is for a row written by hand.
                label: isHolder ? nil : (user.displayName ?? "another profile"),
                profileID: id
            )
        }
        return audience
    }

    /// Everyone following one brand hears about that brand's batch at most once.
    ///
    /// - Parameter storefronts: the brand's country shops in a switched-on country, with their
    ///   sources. Each follower hears only of events in the shop serving them — their country's
    ///   where it is live, the main shop otherwise — so a reader in Britain is not woken twice
    ///   for one drop, once in each currency.
    private func notify(
        brandID: UUID,
        events: [EventModel],
        storefronts: [StorefrontModel] = [],
        using sender: any PushSending,
        skipping claimed: Set<Pair> = [],
        into result: inout NotifyResult
    ) async {
        let db = app.db
        let brandName = events.first?.brand.name ?? "A brand you follow"

        do {
            let follows = try await FollowModel.query(on: db)
                .filter(\.$brand.$id == brandID)
                .all()
            // How each follower hears from this brand — see `FollowMode`. A quiet follow is
            // left out before its devices are even loaded; the watch alerts it may still be
            // owed went out in `notifyWatches`, which never asks.
            let modes = Dictionary(
                follows.map { ($0.$user.id, $0.mode) },
                uniquingKeysWith: { first, _ in first }
            )
            let followers = follows.filter { $0.mode != .quiet }.map(\.$user.id)
            guard !followers.isEmpty else { return }

            let users = try await UserModel.query(on: db).filter(\.$id ~~ followers).all()
            // Every profile on an account is heard on the account's phones, labelled when it
            // is not the holder's; a profile with alerts off is not in it. See `audience`.
            let audience = try await Self.audience(for: Set(followers), on: db)
            guard audience.values.contains(where: { !$0.devices.isEmpty }) else { return }

            for user in users {
                guard let userID = user.id, let recipient = audience[userID] else { continue }
                let userDevices = recipient.devices
                // Already told about this brand by a watch alert, which said something
                // more specific than this summary would.
                guard !claimed.contains(Pair(user: userID, brand: brandID)) else { continue }

                let profile = user.sizeProfile
                let mode = modes[userID] ?? .everything
                // They follow the brand, so somebody in their country does: whether the shop is
                // live is then only whether it has been read.
                let shop = storefronts.first { storefront in
                    Storefronts.serves(
                        country: storefront.country,
                        to: user.country,
                        enabled: app.storefrontCountries,
                        followedThere: true,
                        baselined: storefront.sources.contains { $0.baselinedAt != nil }
                    )
                }?.id
                let relevant = events.filter {
                    $0.storefrontID == shop && Self.isRelevant($0, to: profile, mode: mode)
                }
                guard let copy = Self.summary(brand: brandName, events: relevant) else { continue }
                // Only when the alert names one thing. A counted summary ("3 restocks and
                // 2 new items") has no single product behind it, and picking one of them
                // to open would be arbitrary — the brand is the honest destination. So is it
                // for a sale, which is about the whole shop and has no product page to open.
                let single = relevant.count == 1 && relevant.first?.kind != UpdateKind.sale.rawValue
                    ? relevant.first?.id
                    : nil

                for device in userDevices {
                    guard let token = device.apnsToken else { continue }
                    let message = PushMessage(
                        deviceToken: token,
                        environment: device.environment,
                        title: copy.title,
                        body: recipient.labelled(copy.body),
                        brandID: brandID,
                        eventID: single,
                        // Per profile: the holder's alert about Kith and Anna's are about two
                        // people, and one must not silently replace the other unread.
                        collapseID: recipient.collapse(brandID.uuidString),
                        profileID: recipient.profileID
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
                        result.retryableBrands.insert(brandID)
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
    /// **Whether this kind of event is worth interrupting somebody for at all.**
    ///
    /// Every kind used to push, and the result was a stream nobody could take seriously —
    /// which is worse than too few notifications, because it teaches people to swipe the
    /// whole app away and takes the one that mattered with it.
    ///
    /// The line is *the unexpected*. A drop, a collection and a storefront locking are things
    /// that happen suddenly, are worth acting on within minutes, and cannot be found any
    /// other way. Everything else is either not urgent or not news:
    ///
    /// - **`restock`** — the single largest source of volume, and almost all of it is about a
    ///   garment the reader has never seen. A restock is only interesting when it is *your*
    ///   size of *your* thing, and that is precisely what a `StockWatch` says. Watches are
    ///   handled by `notifyWatches`, which runs first, claims its (user, brand) pairs and is
    ///   exempt from the cooldown — so a restock somebody asked about still arrives instantly
    ///   while a restock nobody asked about no longer wakes them at seven.
    /// - **`priceDrop`** — real news and not urgent. A markdown is worth as much a week later
    ///   as on the day, which is exactly why `MarkdownsView` exists and carries a badge. The
    ///   one somebody is waiting for — on a product they watch — goes by the watch path,
    ///   `notifyWatchedPriceDrops`; one on something they saved, the phone says itself. A
    ///   brand putting much of its catalogue on sale is `.sale`, which *is* sudden.
    /// - **`pageChange`** — "something on this page is different", from a hashed page watch.
    ///   The weakest signal in the app: it fires on brands where nothing happened.
    /// - **`post`** — a brand's own RSS. Marketing, published by people who already have a
    ///   newsletter.
    ///
    /// None of these are *hidden*: every one still lands in the feed, still counts as unread,
    /// still reaches the markdowns list. This decides only what is worth a buzz.
    /// The switch itself lives on `UpdateKind.isSudden`, in `StreetwCore`, because the app's
    /// feed asks the same question when it decides which of a brand's events gets the
    /// headline and the large photograph. Two copies of a seven-case judgement in two
    /// modules is how the feed ends up leading with the thing this deliberately stayed
    /// silent about. The name stays, and the reasoning stays here, because "is this worth
    /// waking somebody" is what the question means on this side.
    static func isWorthWaking(_ kind: UpdateKind) -> Bool { kind.isSudden }

    /// - Parameter mode: how this follower follows the brand. Both questions must say yes —
    ///   the mode only ever takes away, so a *Sales only* follow is never woken by a kind an
    ///   *Everything* follow would not be. The default is what every follow is until
    ///   somebody chooses otherwise.
    static func isRelevant(
        _ event: EventModel,
        to profile: SizeProfile,
        mode: FollowMode = .everything
    ) -> Bool {
        // Gender applies to every kind, not just restocks. Being woken at 7am for a
        // women's hoodie is worse than merely seeing one in the feed, so if the filter
        // is worth having anywhere it is worth having here first.
        //
        // A drop lock has no product, so it has no gender and always passes — it is about
        // the storefront rather than an item.
        if let product = event.product, !profile.allows(product.gender) { return false }

        let kind = UpdateKind(rawValue: event.kind) ?? .product
        guard Self.isWorthWaking(kind), mode.admits(kind) else { return false }

        guard kind == .restock else { return true }
        guard !profile.isEmpty, !event.sizes.isEmpty else { return true }
        // The run is the event's own sizes, never `product.$variants`: the products here
        // were loaded without them, and that accessor traps rather than returning nothing.
        let context = event.product?.sizeContext(sizes: event.sizes) ?? .unknown
        return event.sizes.contains { profile.matches($0, in: context) }
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
            case .sale:
                // The sale's own words — "25% OFF EVERYTHING · CODE AUTUMN" — because the
                // code is the one part of it found nowhere else.
                return (brand, event.title ?? "A sale just started")
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
        // A sale leads a mixed batch in its own words, so its code is not counted away into
        // "a sale and 3 new items".
        if let sale = byKind[.sale]?.first {
            let said = sale.title ?? "A sale just started"
            return (brand, parts.isEmpty ? said : "\(said) — and \(sentence(parts))")
        }
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

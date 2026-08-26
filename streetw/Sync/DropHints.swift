// DropHints.swift
// Turning a date you wrote down into the server looking sooner.
//
// `DropReminders` is the other half of this and came first: a `PlannedDrop` buys two local
// notifications, at breakfast and at the minute. That closes half the gap. The other half
// is that the *products* still have to be found — and the poller's ordinary cadence is
// twenty minutes, or two hours on a brand that has been quiet, so an alert fires at eleven
// and the drop lands in the feed at 11:20. For a release decided in its first minute that is
// not a late notification, it is a useless one.
//
// A brand with a readable rhythm already gets sixty-second polling inside its own window
// (`Cadence.next(inDropWindow:)`), which is why this is deliberately a *minority* feature and
// was not built the first time round. What it reaches is the case the estimator cannot see:
// a brand that never locks its storefront and never publishes a date until the products are
// already up. Stüssy announces a Friday release on Instagram and gives no machine-readable
// sign of it at all.
//
// **What crosses, and what does not.** One brand id and one instant per hint. Not the title,
// not the note, not how many drops you are tracking — see `PlannedDrop` on why the calendar
// itself is local, and note that this does not undo it: a hint changes poll cadence and
// nothing else, is never read back to another user, and produces no event and no
// notification on its own. Nobody else's Thursday moves.
//
// **The whole set is sent rather than diffed**, for exactly the reason `DropReminders.refresh`
// rewrites the notification centre rather than reconciling it. Tracking which hints are
// outstanding across edits, deletions, brands being unfollowed and a week offline is a
// mechanism that can drift, and drift here means the server politely hammering a storefront
// for a drop somebody deleted in March. One small request, and it cannot drift.

import Foundation
import OSLog
import StreetwCore
import SwiftData

@MainActor
enum DropHints {
    private static let log = Logger(subsystem: "com.kern.functional.streetw", category: "drops")

    /// What was last accepted, so a foreground with nothing new to say costs no request.
    ///
    /// This runs on every foreground — it has to, for the same reason `DropReminders.refresh`
    /// does — and the set is usually identical to the last one. The token is folded into the
    /// fingerprint because re-registering issues a new device and the server's hints belong
    /// to the old one: without it, a reinstall would look "already sent" forever and the
    /// hints would silently never exist.
    private static let sentKey = "pollHintsFingerprint"

    /// Reads the planned drops and sends whatever the server will take.
    ///
    /// Call after anything that changes a `PlannedDrop`, and on foreground. Idempotent and
    /// cheap when nothing has moved.
    ///
    /// `status` is written on every reply and is what the calendar reads to say, per row,
    /// whether the server is actually going to be looking. Passing it in rather than having
    /// this reach for a singleton keeps the one caller that does not want it — a future
    /// background pass — able to say so.
    static func refresh(in context: ModelContext, via remote: RemoteSync, status: DropHintStore) async {
        let hints = build(from: context)
        let fingerprint = fingerprint(of: hints, token: remote.hintIdentity)

        guard fingerprint != UserDefaults.standard.string(forKey: sentKey) else { return }

        guard let response = await remote.pushPollHints(hints) else {
            // Not a failure worth a stamp, and not one worth a banner either — but the
            // calendar must stop claiming the server is watching, because in standalone
            // mode or before registration it is not and never was.
            status.recordUnsent()
            return
        }

        // Stamped only on a reply. A request that failed has left the server holding the
        // previous set, and marking it sent would mean never trying again — the silent
        // half-working state this codebase keeps rediscovering.
        UserDefaults.standard.set(fingerprint, forKey: sentKey)
        status.record(response)

        for refusal in response.rejected {
            log.info("poll hint refused for \(refusal.brandID, privacy: .public): \(refusal.reason.rawValue, privacy: .public)")
        }
        log.info("sent \(response.accepted.count) poll hints, \(response.rejected.count) refused")
    }

    /// The set the server is offered, in the order it would keep under a cap.
    ///
    /// Separated from the sending so the rules are readable in one place and testable
    /// without a network. Three of them:
    ///
    /// - **A brand the server does not know is not a hint.** Standalone brands and anything
    ///   discovered locally have no `remoteID`, and there is nothing on the other end to
    ///   poll harder.
    /// - **One per brand, the soonest.** The server enforces this too — the table is unique
    ///   on (user, brand) — but sending two and letting it refuse both is worse than picking
    ///   here, and the soonest is the one somebody is actually waiting on. Two drops from
    ///   one brand in the same week is a real thing; the second one gets its window when the
    ///   first has passed and this next runs.
    /// - **Soonest first, then capped.** `PollHintPolicy.maxPerUser` is the server's bound,
    ///   applied here so a full calendar sends a request that will be accepted rather than
    ///   one refused whole.
    ///
    /// Dates outside `isAcceptable` — already over, or further out than a season — are
    /// dropped rather than sent and refused, which also means a hint that simply expires
    /// changes this set, changes the fingerprint, and gets withdrawn on the next pass.
    static func build(from context: ModelContext, now: Date = Date()) -> [PollHint] {
        let drops = (try? context.fetch(FetchDescriptor<PlannedDrop>())) ?? []

        var soonest: [UUID: Date] = [:]
        for drop in drops {
            guard let brandID = drop.brand?.remoteID else { continue }
            guard PollHintPolicy.isAcceptable(releaseAt: drop.releaseAt, now: now) else { continue }
            if let held = soonest[brandID], held <= drop.releaseAt { continue }
            soonest[brandID] = drop.releaseAt
        }

        var hints = soonest.map { PollHint(brandID: $0.key, releaseAt: $0.value) }
        // Ties broken on the id so the order — and therefore the fingerprint — is stable
        // across launches. A dictionary's iteration order is not.
        hints.sort { left, right in
            if left.releaseAt != right.releaseAt { return left.releaseAt < right.releaseAt }
            return left.brandID.uuidString < right.brandID.uuidString
        }
        return Array(hints.prefix(PollHintPolicy.maxPerUser))
    }

    /// A cheap, stable description of "the set the server holds".
    ///
    /// Rounded to the minute. A `PlannedDrop` is entered to the minute and nothing finer is
    /// meaningful, while a full timestamp would differ by microseconds between two builds of
    /// the same list and send a request on every foreground.
    private static func fingerprint(of hints: [PollHint], token: String) -> String {
        let body = hints
            .map { "\($0.brandID.uuidString):\(Int($0.releaseAt.timeIntervalSince1970 / 60))" }
            .joined(separator: ",")
        return "\(token)|\(body)"
    }
}

/// What the server said about each hint, so the calendar can stop guessing.
///
/// **The reason this exists at all.** A poll hint is invisible when it works and invisible
/// when it doesn't — the row still says "added by you", the reminders still fire, and the
/// only observable difference is whether the products are there when the alert arrives.
/// That is precisely the shape of failure this project keeps a list of: every layer reports
/// healthy and the feature does not exist. So the answer is kept and printed.
///
/// Held rather than re-fetched. `GET /v1/poll-hints` would answer the same question, but it
/// is a request per launch to re-learn something the last `PUT` already returned, and the
/// calendar is a sheet somebody opens repeatedly. Persisted through `UserDefaults` for the
/// same reason the fingerprint beside it is: without it the page says nothing until the next
/// change, and the fingerprint means there may not *be* a next change.
///
/// `@Observable` and built in `streetwApp.init` alongside the rest, not in a `.task` —
/// a view that reads it appears before an asynchronous build could have finished, which is
/// the race `RemoteSync` and `SizeProfileStore` were both moved out of.
@MainActor
@Observable
final class DropHintStore {
    /// What the server holds, brand by brand: the release time it will watch around.
    private(set) var accepted: [UUID: Date] = [:]
    private(set) var refused: [UUID: PollHintPolicy.Rejection] = [:]
    /// How wide the window is, as the server reported it rather than as this build assumes.
    /// The two deploy separately, and a page that prints "watching from 10:45" off a local
    /// constant would be stating the old number with total confidence.
    private(set) var windowBefore: TimeInterval = PollHintPolicy.windowBefore
    /// Nil until a reply has ever been had. Distinguishes "the server is not watching this"
    /// from "nobody has asked yet", which are different sentences.
    private(set) var lastReplyAt: Date?

    private static let key = "pollHintState"

    init() {
        guard let data = UserDefaults.standard.data(forKey: Self.key),
              let stored = try? JSONDecoder().decode(Stored.self, from: data)
        else { return }
        accepted = stored.accepted
        refused = stored.refused
        windowBefore = stored.windowBefore
        lastReplyAt = stored.lastReplyAt
    }

    /// What one planned drop can honestly claim.
    enum State: Equatable {
        /// The server holds this drop's own time and will poll the brand hard from `from`.
        case watching(from: Date)
        /// The brand is covered, but for a different drop — `DropHints.build` sends the
        /// soonest per brand, so a second date in the same week waits its turn. Named rather
        /// than shown as "not watched", which would be false: it is watched, later.
        case queued
        /// The server refused it, and this is which of the four reasons.
        case refused(PollHintPolicy.Rejection)
        /// Nothing has been sent — standalone, or not yet registered. Local reminders still
        /// fire, which is exactly where this feature stood before the route existed.
        case local
    }

    /// - Parameters:
    ///   - brandID: the brand's **remote** id. A brand added locally has none and can never
    ///     be hinted, which is `.local` and correct.
    func state(brandID: UUID?, releaseAt: Date) -> State {
        guard lastReplyAt != nil, let brandID else { return .local }
        if let held = accepted[brandID] {
            // To the minute: a `PlannedDrop` is entered to the minute, and comparing
            // `Date`s exactly would fail on the sub-second drift of a JSON round trip.
            return abs(held.timeIntervalSince(releaseAt)) < 60
                ? .watching(from: held.addingTimeInterval(-windowBefore))
                : .queued
        }
        if let reason = refused[brandID] { return .refused(reason) }
        return .local
    }

    func record(_ response: PollHintsResponse) {
        accepted = Dictionary(
            response.accepted.map { ($0.brandID, $0.releaseAt) },
            uniquingKeysWith: { a, _ in a }
        )
        refused = Dictionary(
            response.rejected.map { ($0.brandID, $0.reason) },
            uniquingKeysWith: { a, _ in a }
        )
        windowBefore = response.windowBefore
        lastReplyAt = Date()
        persist()
    }

    /// The request could not be made at all — no server, or no registration yet. Everything
    /// standing is dropped rather than left: a stale "watching" is a promise nothing is
    /// keeping, and this page exists to not make those.
    func recordUnsent() {
        guard !accepted.isEmpty || !refused.isEmpty || lastReplyAt != nil else { return }
        accepted = [:]
        refused = [:]
        lastReplyAt = nil
        persist()
    }

    private func persist() {
        let stored = Stored(
            accepted: accepted, refused: refused,
            windowBefore: windowBefore, lastReplyAt: lastReplyAt
        )
        UserDefaults.standard.set(try? JSONEncoder().encode(stored), forKey: Self.key)
    }

    /// Decoded leniently, by hand-written defaults on every field — the same rule
    /// `BrandSource` and `SizeProfile` follow. A field added here later must not be a
    /// throw on launch for anybody holding the older shape.
    private struct Stored: Codable {
        var accepted: [UUID: Date] = [:]
        var refused: [UUID: PollHintPolicy.Rejection] = [:]
        var windowBefore: TimeInterval = PollHintPolicy.windowBefore
        var lastReplyAt: Date?

        init(
            accepted: [UUID: Date],
            refused: [UUID: PollHintPolicy.Rejection],
            windowBefore: TimeInterval,
            lastReplyAt: Date?
        ) {
            self.accepted = accepted
            self.refused = refused
            self.windowBefore = windowBefore
            self.lastReplyAt = lastReplyAt
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            accepted = (try? container.decode([UUID: Date].self, forKey: .accepted)) ?? [:]
            refused = (try? container.decode([UUID: PollHintPolicy.Rejection].self, forKey: .refused)) ?? [:]
            windowBefore = (try? container.decode(TimeInterval.self, forKey: .windowBefore))
                ?? PollHintPolicy.windowBefore
            lastReplyAt = try? container.decode(Date.self, forKey: .lastReplyAt)
        }
    }
}

extension DropHintStore.State {
    /// What the row prints. Nil where there is nothing worth a line — a hint that landed
    /// while the app is doing exactly what it says on the row above is not news.
    var label: String? {
        switch self {
        case .watching(let from):
            "Watching from \(Self.time.string(from: from))"
        case .queued:
            "Watching this brand's earlier drop first"
        case .refused(.notFollowing):
            "Not watched — follow the brand again"
        case .refused(.unknownBrand):
            "Not watched — this brand is no longer in the catalogue"
        case .refused(.outOfRange), .refused(.tooMany):
            "Not watched — reminders only"
        case .local:
            nil
        }
    }

    /// Vermilion only where something is *wrong and fixable*. "Watching from 10:45" is
    /// reassurance and belongs in the quiet voice — an accent on every healthy row would
    /// make the one broken row invisible, which is the opposite of the point.
    var isWarning: Bool {
        if case .refused = self { return true }
        return false
    }

    private static let time: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter
    }()
}

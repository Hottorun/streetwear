// PollHint.swift
// "I know this drops at eleven — go and look."
//
// A `PlannedDrop` is a date somebody typed because they read it somewhere the app cannot:
// an Instagram story, a newsletter, a group chat. Until now it bought two local
// notifications and nothing else, which leaves the gap it was written down to close only
// half shut — the alert fires at eleven, and the poller finds the products at 11:20 because
// the brand has no readable rhythm and is sitting on the quiet cadence.
//
// A hint sends **one timestamp and one brand id** to the server so the poll queue drops to
// a minute around that moment. It is deliberately the smallest possible claim: no title, no
// note, nothing anybody else can see. See `PlannedDrop` for why the *calendar* stays local
// — one person being wrong about a Thursday must not become everybody's Thursday, and it
// still doesn't: a hint changes poll cadence and nothing else. No row is created, no event
// is written, and a notification still requires a real product to have appeared.
//
// **Everything abusable about it lives in this file, and none of it is client-settable.**
// The client sends a brand and an instant; the server decides how wide the window is, how
// far ahead one may be placed, and how many a person may hold. A client that sends more is
// refused rather than truncated, because silently dropping half of somebody's calendar is
// the kind of failure this project keeps a list of.
//
// The property that actually makes it safe is not here, though — it is in `Poller`. Hinted
// sources are claimed against a **separate, fixed budget**, so hinting more brands does not
// buy more requests, it divides the same ones. The extra load a hint can create is bounded
// by that budget no matter how many people hint how many brands, and `PoliteFetcher` still
// spaces every request per host on top. Sixty-second polling is not a new capability
// either: a locked storefront and a brand inside its own historical window both already
// reach it.

import Foundation

/// The rules a poll hint is held to. Shared so the client can trim its request to
/// something that will be accepted — but the server is the only enforcer, and it re-checks
/// every one of these.
public enum PollHintPolicy {
    /// How long before the stated time the fast cadence begins.
    ///
    /// Short, because unlike `DropCadence.windowBefore` this is not a mean over months of
    /// observations — somebody has typed an exact minute, and the uncertainty is theirs
    /// rather than the estimator's. Fifteen minutes covers a storefront that opens the
    /// queue early.
    public static let windowBefore: TimeInterval = 15 * 60

    /// And how long after. Longer than `windowBefore` for the same reason `DropCadence`'s
    /// is: a release staggers, and the storefront keeps publishing for a while after the
    /// first item lands.
    public static let windowAfter: TimeInterval = 45 * 60

    /// So one hint is an hour of attention, and can never be more.
    public static var windowLength: TimeInterval { windowBefore + windowAfter }

    /// How far ahead a hint may be placed.
    ///
    /// A bound rather than a judgement about what people know: an unbounded `releaseAt` is
    /// a row that sits in the table forever, and `Reaper` can only prune what has an end.
    /// A season's worth of lead time is more than anybody has.
    public static let maxLeadTime: TimeInterval = 90 * 86_400

    /// How many a person may hold at once.
    ///
    /// The follow requirement already bounds this by how many brands somebody watches;
    /// this is the second bound, so a thousand-follow account cannot hold a thousand
    /// windows. Twenty is more upcoming drops than anyone is tracking by hand.
    public static let maxPerUser = 20

    /// Whether `releaseAt` may be accepted at all, given when it is being offered.
    ///
    /// A time slightly in the past is fine and is the ordinary case for a drop somebody is
    /// writing down as it happens — it is accepted for exactly as long as its window is
    /// still open, and refused the moment that window has closed. Refusing outright would
    /// mean the app posting hints it knows are dead.
    public static func isAcceptable(releaseAt: Date, now: Date = Date()) -> Bool {
        releaseAt > now.addingTimeInterval(-windowAfter)
            && releaseAt < now.addingTimeInterval(maxLeadTime)
    }

    /// Whether the fast cadence applies right now.
    public static func isActive(releaseAt: Date, now: Date = Date()) -> Bool {
        now >= releaseAt.addingTimeInterval(-windowBefore)
            && now <= releaseAt.addingTimeInterval(windowAfter)
    }

    /// The half-open range of `release_at` values whose windows contain `now`.
    ///
    /// Expressed as a range over the *stored column* rather than as a per-row predicate, so
    /// the queue query is a plain indexed range scan instead of arithmetic on every row.
    public static func activeRange(at now: Date = Date()) -> ClosedRange<Date> {
        now.addingTimeInterval(-windowAfter)...now.addingTimeInterval(windowBefore)
    }

    /// Why a hint was refused. Sent back per brand rather than as one status, because the
    /// three answers have three different meanings and a client that is told "rejected"
    /// cannot tell "you don't follow that brand" from "that date has passed".
    public enum Rejection: String, Codable, Sendable, Hashable {
        /// The caller does not follow the brand. A hint makes the server fetch a
        /// storefront harder; asking for that on a brand you have no relationship with is
        /// the vector, not a mistake.
        case notFollowing
        /// No such brand in the shared catalogue.
        case unknownBrand
        /// Outside `isAcceptable` — already over, or further out than `maxLeadTime`.
        case outOfRange
        /// More than `maxPerUser` were sent, or a second one arrived for a brand that
        /// already had one in the same request.
        case tooMany

        public var reason: String {
            switch self {
            case .notFollowing: "Follow the brand before hinting at its drops"
            case .unknownBrand: "No such brand"
            case .outOfRange: "That date is outside the window a hint may cover"
            case .tooMany: "Too many hints — at most \(PollHintPolicy.maxPerUser), one per brand"
            }
        }
    }
}

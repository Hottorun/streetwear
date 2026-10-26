// FeedVisit.swift
// What "since you were last here" means, precisely — and what that makes `isSeen` mean.
//
// 1.0 managed unread state brand by brand: a checkmark per spread, a dot per brand on the
// rail, "40 new from 6 brands", a swipe to mark one card read. Somebody had to keep the feed
// empty for it to be useful, and the counts it printed disagreed with each other often
// enough that a whole section of the design doc is about making them agree. Phase 1 replaces
// all of it with one line across the feed: above it, what arrived since your last visit;
// below it, everything you have had the chance to see. Push is what finds you; the feed is
// where you look.

import Foundation
import StreetwCore
import SwiftData

/// One stretch of the feed being looked at.
///
/// **A visit is the feed on screen, allowing gaps shorter than `resumeWindow`.** It begins
/// when the Feed tab appears — on launch, on switching to it, on coming back to the app — and
/// ends when the feed has been out of sight for longer than the window: another tab, another
/// app, the phone locked. So a trip to Safari to buy the thing you were looking at, or a
/// glance at Saved, is the same visit, and the line does not jump; coming back after lunch is
/// a new one.
///
/// **The line is drawn where the previous visit ended** — the last moment the feed was on
/// screen — and it does not move during a visit. Read once when the visit begins, because a
/// line that followed you down the page would be a list reordering under a thumb, which is
/// the one property the feed's order exists to protect. Cards that arrive mid-visit land
/// above it, which is where they belong.
///
/// Nil before any visit has been recorded: a fresh install's first look and a phone coming
/// from 1.0. Everything is above the line then, and from 1.0 that is exactly the queue it had
/// not read — see `FeedHistory.adoptLegacy`.
@MainActor
@Observable
final class FeedVisit {
    /// Five minutes: long enough to check out on a storefront and come back, short enough
    /// that putting the phone down and picking it up later is a new visit.
    static let resumeWindow: TimeInterval = 5 * 60

    /// Per profile: "since you were last here" is about one person's last visit. Captured
    /// when the feed is built, because the visit is ended as the feed is torn down — which a
    /// profile switch does after the new profile is already current.
    @ObservationIgnored private let lastOnScreenKey = ProfileScope.active.key("feedLastOnScreenAt")
    @ObservationIgnored private let boundaryKey = ProfileScope.active.key("feedVisitBoundary")

    /// Where this visit's line falls. Nil means there was no earlier visit.
    private(set) var boundary: Date?
    private(set) var isOnScreen = false

    /// `-feedLastVisitHours 5` pretends the last visit ended that long ago, for the first
    /// visit of a launch — so a screenshot or a test of the line does not have to wait out
    /// `resumeWindow`. Dev only, and a no-op without the flag.
    @ObservationIgnored private var override: Date? = {
        guard let raw = UserDefaults.standard.string(forKey: "feedLastVisitHours"), let hours = Double(raw) else { return nil }
        return Date().addingTimeInterval(-hours * 3600)
    }()

    private var defaults: UserDefaults { .standard }

    /// The feed is on screen. Starts a visit, or continues the one a short gap interrupted.
    func appeared(now: Date = Date()) {
        guard !isOnScreen else { return }
        isOnScreen = true

        if let override {
            self.override = nil
            begin(at: override)
            return
        }
        let last = defaults.object(forKey: lastOnScreenKey) as? Date
        if let last, now.timeIntervalSince(last) < Self.resumeWindow {
            // The same visit, interrupted: the line stays where it was drawn.
            boundary = defaults.object(forKey: boundaryKey) as? Date
        } else {
            begin(at: last)
        }
    }

    /// The feed has gone out of sight — another tab, or the app leaving the foreground.
    ///
    /// Returns the moment, for `FeedHistory.markShown`. Whether this ends the visit is only
    /// known later, by how long the gap turns out to be.
    @discardableResult
    func left(now: Date = Date()) -> Date? {
        guard isOnScreen else { return nil }
        isOnScreen = false
        defaults.set(now, forKey: lastOnScreenKey)
        return now
    }

    private func begin(at line: Date?) {
        boundary = line
        defaults.set(line, forKey: boundaryKey)
    }
}

/// The writes that keep `isSeen` and `arrivedAt` coherent with the line.
@MainActor
enum FeedHistory {
    /// **What the feed showed is seen.** Called whenever the feed goes out of sight, for
    /// everything that had arrived by then.
    ///
    /// The feed no longer reads `isSeen` — the line is placed by `arrivedAt` — but four other
    /// things still do, and they have to keep meaning something now that nobody marks
    /// anything read by hand: `FollowedSupply` offers Discover what is unread from brands you
    /// follow, a brand page counts UNREAD, `SyncEngine.prune` never drops an unread row, and a
    /// product page stops being "new" once opened. With no checkmarks, nothing would ever
    /// become seen and all four would grow for ever. So `isSeen` now says *the feed has had
    /// its chance to show this*: above the line during the visit, seen once it is over.
    ///
    /// **What a filter hid is not marked.** A Menswear setting hides womenswear from the
    /// feed, and a row that was never on screen must not be recorded as though it had been —
    /// the rule `markSeen` kept in 1.0, kept here.
    ///
    /// Asked of the store narrowly — `!isSeen` is an index — and saved only when something
    /// changed, because `context.save()` invalidates every `@Query` in the app.
    static func markShown(upTo date: Date, in context: ModelContext, profile: SizeProfile) {
        let rows = (try? context.fetch(FetchDescriptor<BrandUpdate>(predicate: #Predicate { !$0.isSeen }))) ?? []
        var changed = false
        for row in rows where (row.arrivedAt ?? .distantPast) <= date && row.passes(profile) {
            row.isSeen = true
            changed = true
        }
        if changed { try? context.save() }
    }

    /// **The 1.0 unread queue is news, once.** `arrivedAt` did not exist, so every row on a
    /// phone coming from 1.0 is history to the timeline — and the unread ones are exactly what
    /// that person had not seen yet. They arrive when they were written, which is the
    /// nearest thing to an arrival the row has.
    ///
    /// Run before any view exists, like `BoardFiling.adoptLegacy`, and safe to run on every
    /// launch: it is one indexed question that finds nothing once answered. It is also the
    /// repair for any path that writes a row unread without `arrive(at:)` — unread is news,
    /// whatever wrote it.
    static func adoptLegacy(in context: ModelContext) {
        let descriptor = FetchDescriptor<BrandUpdate>(predicate: #Predicate { !$0.isSeen && $0.arrivedAt == nil })
        guard let rows = try? context.fetch(descriptor), !rows.isEmpty else { return }
        for row in rows { row.arrivedAt = row.discoveredAt }
        try? context.save()
    }
}

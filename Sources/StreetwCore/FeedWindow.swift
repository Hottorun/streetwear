// FeedWindow.swift
// How much of the store the feed reads, and why it is an arrival date and not a count.

import Foundation

/// The rows the feed's timeline reads: everything that arrived at or after `floor`.
///
/// **What this replaced, and what it cost.** The feed read the newest 500 arrivals. That was
/// weeks of a busy follow list until the daily catalogue scan began announcing markdowns and
/// restocks on older stock: one scan of four shops is hundreds of rows, all arriving at
/// once, and every row that arrived pushed the oldest one out of the read. Somebody who
/// scrolled the morning's drops, synced in the afternoon and again in the evening found the
/// morning gone — not folded, not moved, simply no longer read, while the cards that
/// replaced it were one "UP TO −30%" card per shop. A count is the wrong bound for a feed
/// whose rows arrive in bursts: it says how much is kept, when the promise is *what*.
///
/// So the bound is a moment. It is opened a page deep, from the store (`opening`), and from
/// then on it only ever moves back: a sync adds rows above it and can no longer take any off
/// the bottom, and reaching the end of what is read reads one more page (`extended`), so
/// everything the phone holds is reachable by scrolling. A new visit opens it a page deep
/// again, so a read somebody once scrolled deep is not paid for on every body for the rest of
/// the session. Lives here rather than beside the
/// view because the app has no test target, and "a later sync never takes away a row that was
/// in the read" is the whole of the fix.
public struct FeedWindow: Equatable, Sendable {
    /// How many arrivals one read adds. Five hundred is what the feed read in total before,
    /// and is measured to keep a pass cheap — see `docs/performance.md`.
    public static let page = 500

    /// Rows that arrived at or after this are read. Nil reads every arrival: the store holds
    /// fewer than the window has asked for.
    public private(set) var floor: Date?

    public init(floor: Date?) {
        self.floor = floor
    }

    /// The window a feed opens with.
    ///
    /// - Parameter edge: when the `page`th newest arrival arrived, or nil when the store holds
    ///   fewer — `openingOffset` is the row to ask for.
    public static func opening(edge: Date?) -> FeedWindow {
        FeedWindow(floor: edge)
    }

    /// Which row, newest arrival first, to ask the store for when opening.
    public static var openingOffset: Int { page - 1 }

    /// Which row to ask for when `loaded` rows are read and the reader has reached the end:
    /// one page past the oldest of them.
    public static func extendingOffset(loaded: Int) -> Int {
        max(loaded, 0) + page - 1
    }

    /// Whether a row is in the read.
    public func admits(arrival: Date) -> Bool {
        floor.map { arrival >= $0 } ?? true
    }

    /// Whether there may be more to read than this window holds — the store holds `total`
    /// arrivals and `loaded` of them are in it.
    public func hasMore(loaded: Int, total: Int) -> Bool {
        floor != nil && total > loaded
    }

    /// One page further back.
    ///
    /// - Parameter edge: when the row at `extendingOffset(loaded:)` arrived, or nil when the
    ///   store holds no row that deep — which reads to the end.
    ///
    /// **Only ever further back.** A floor that moved forward would be the count again: rows
    /// that were read and are not any more.
    public func extended(to edge: Date?) -> FeedWindow {
        guard let floor else { return self }
        guard let edge else { return FeedWindow(floor: nil) }
        return FeedWindow(floor: min(edge, floor))
    }
}

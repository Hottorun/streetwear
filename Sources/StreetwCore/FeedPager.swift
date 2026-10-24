// FeedPager.swift
// How a device reads everything `GET /v1/feed` owes it, within a budget, without losing any.

import Foundation

/// The client's half of feed paging. The server's half — which events a page holds and in
/// what order — is `FeedPaging` in the server target.
///
/// **What this replaced, and what it cost.** A sync asked for one page of 200 and moved the
/// cursor to the newest event in it, so anything older than the 200th event between two
/// syncs fell behind the cursor without ever being sent. It lives here rather than in
/// `RemoteSync` because the app has no test target, and the order of four writes is the
/// whole of the fix.
///
/// The state is two things, and both belong to the connection rather than the data, which is
/// why the caller keeps them in `UserDefaults` beside the cursor it already had:
///
/// - **`cursor`** — the newest event of the last read that *began*. A read is a fixed window,
///   (cursor, newest event at the time], so moving the cursor when the first page lands is
///   safe as long as the rest of that window is remembered.
/// - **`pending`** — the windows that ran out of budget before they were finished, as the
///   server's own continuation tokens, newest first.
///
/// A sync reads the head first — what happened since the cursor — because that is what a
/// push is about and what somebody opening the app is looking for, and spends what budget is
/// left on the backlog. The budget is there because a phone that has been off for a fortnight
/// can be owed tens of thousands of events, and one foreground refresh must not try to pull
/// all of them. The server's order is fair between brands, so what waits for a later sync is
/// the deep history of the busiest brands, not any brand's newest news.
public struct FeedPager: Sendable {
    public struct State: Equatable, Sendable {
        public var cursor: Date?
        public var pending: [String]

        public init(cursor: Date?, pending: [String] = []) {
            self.cursor = cursor
            self.pending = pending
        }
    }

    /// One page, as the caller should ask the server for it.
    public enum Request: Equatable, Sendable {
        /// Begin a read from the cursor. Nil means "this device has never been told
        /// anything", which the server answers with its default window.
        case head(since: Date?)
        /// Carry on a read the server started.
        case resume(String)
    }

    public struct Outcome: Sendable {
        public var state: State
        public var pagesRead: Int
        /// Why the pass stopped before the budget or the backlog ran out, if it did. The
        /// first page is the only one allowed to fail a sync — everything after it has
        /// already been recorded as pending and is simply picked up next time, so a dropped
        /// connection on page three is a slower catch-up, not a failed refresh.
        public var interruption: (any Error)?
    }

    /// Pages per sync, head and backlog together.
    public var maxPages: Int
    /// Unfinished windows kept. Past this the oldest is dropped — the one way an event can
    /// still be lost, and only by a phone more than `maxPending` full windows behind.
    public var maxPending: Int

    public init(maxPages: Int = 5, maxPending: Int = 4) {
        self.maxPages = max(maxPages, 1)
        self.maxPending = max(maxPending, 1)
    }

    /// One pass.
    ///
    /// - Parameters:
    ///   - state: where the last pass left off.
    ///   - fallbackCursor: where the cursor moves when the head names none — the server had
    ///     nothing for brands this device does follow. `RemoteSync` passes the moment the
    ///     sync began on a first sync that reached a follow list, and nil otherwise, which
    ///     leaves the cursor where it was.
    ///   - fetch: asks the server for one page. A continuation the server refuses should come
    ///     back as an empty page with no continuation, so it is spent rather than retried on
    ///     every sync for ever.
    ///   - merge: stores one page. `asBaseline` is true only for the head of a first read —
    ///     a device that has never been told anything is meeting a catalogue, not hearing
    ///     news, and that read stops at its first page because history owes nothing.
    ///   - persist: called after **every** merged page with the state it leaves behind. The
    ///     order is the guarantee: a page is stored, then the state that says it was stored,
    ///     so a process killed between the two re-reads a page rather than skipping one.
    public func run(
        from state: State,
        fallbackCursor: Date?,
        fetch: (Request) async throws -> FeedResponse,
        merge: (_ items: [FeedItem], _ asBaseline: Bool) -> Void,
        persist: (State) -> Void,
        isolation: isolated (any Actor)? = #isolation
    ) async throws -> Outcome {
        let isBaseline = state.cursor == nil
        var budget = maxPages

        let head = try await fetch(.head(since: state.cursor))
        budget -= 1
        merge(head.items, isBaseline)

        var current = state
        current.cursor = head.nextCursor ?? fallbackCursor ?? state.cursor
        // The rest of the window just begun. Folded into `pending` for every write, so it is
        // never only in memory.
        var open = isBaseline ? nil : head.continuation
        func snapshot() -> State {
            State(
                cursor: current.cursor,
                pending: Array(([open].compactMap { $0 } + current.pending).prefix(maxPending))
            )
        }
        persist(snapshot())

        var outcome = Outcome(state: snapshot(), pagesRead: 1)
        do {
            while let token = open, budget > 0 {
                let page = try await fetch(.resume(token))
                budget -= 1
                outcome.pagesRead += 1
                merge(page.items, false)
                open = page.continuation
                persist(snapshot())
            }
            current = snapshot()
            open = nil

            while budget > 0, let token = current.pending.first {
                let page = try await fetch(.resume(token))
                budget -= 1
                outcome.pagesRead += 1
                merge(page.items, false)
                if let next = page.continuation {
                    current.pending[0] = next
                } else {
                    current.pending.removeFirst()
                }
                persist(current)
            }
        } catch {
            outcome.interruption = error
        }
        outcome.state = snapshot()
        return outcome
    }
}

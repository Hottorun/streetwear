import Foundation
import Testing

@testable import StreetwCore

/// The client's half of feed paging, pinned here because the app has no test target.
///
/// The bug: one request of 200 per sync, and the cursor moved to the newest of them — so a
/// window holding more than 200 events lost everything past the 200th, for good.
@Suite("Feed pager")
struct FeedPagerTests {
    /// A server with the same contract as `GET /v1/feed`: a head read is the window after a
    /// cursor up to the newest event at the time, a continuation carries it on, and the
    /// first page alone names the cursor. Offsets are good enough here — the order inside a
    /// window is the server's business, and these tests are about the client not dropping
    /// any of it.
    final class FakeFeed: @unchecked Sendable {
        var events: [(id: UUID, at: Date)] = []
        var pageSize = 200
        var requests: [FeedPager.Request] = []
        /// Fails the request with this index (counted across the fake's whole life).
        var failAt: Int?
        /// Answers any continuation as an unknown token, the way a 400 is mapped.
        var refusesContinuations = false
        private let clock = Date(timeIntervalSince1970: 1_780_000_000)

        func add(_ count: Int) {
            let start = (events.last?.at ?? clock).addingTimeInterval(1)
            for index in 0..<count {
                events.append((UUID(), start.addingTimeInterval(Double(index))))
            }
        }

        struct Refused: Error {}
        struct Dropped: Error {}

        func fetch(_ request: FeedPager.Request) throws -> FeedResponse {
            defer { requests.append(request) }
            if failAt == requests.count { throw Dropped() }

            switch request {
            case .head(let since):
                let lower = since ?? .distantPast
                let window = events.filter { $0.at > lower }
                guard let until = window.map(\.at).max() else { return FeedResponse(items: []) }
                return respond(since: lower, until: until, offset: 0, isHead: true)
            case .resume(let token):
                if refusesContinuations { return FeedResponse(items: []) }
                let parts = token.split(separator: "|")
                let since = Date(timeIntervalSince1970: Double(parts[0])!)
                let until = Date(timeIntervalSince1970: Double(parts[1])!)
                return respond(since: since, until: until, offset: Int(parts[2])!, isHead: false)
            }
        }

        private func respond(since: Date, until: Date, offset: Int, isHead: Bool) -> FeedResponse {
            let window = events
                .filter { $0.at > since && $0.at <= until }
                .sorted { $0.at > $1.at }
            let page = window.dropFirst(offset).prefix(pageSize)
            let next = offset + page.count
            return FeedResponse(
                items: page.map { item(id: $0.id, at: $0.at) },
                nextCursor: isHead ? until : nil,
                continuation: next < window.count
                    ? "\(since.timeIntervalSince1970)|\(until.timeIntervalSince1970)|\(next)"
                    : nil
            )
        }

        private func item(id: UUID, at: Date) -> FeedItem {
            FeedItem(
                eventID: id, kind: "product", createdAt: at,
                brandID: UUID(), brandName: "Brand", title: "Thing"
            )
        }
    }

    /// What one device holds after a pass: every event merged, and what it was told was
    /// history rather than news.
    final class Device: @unchecked Sendable {
        var state = FeedPager.State(cursor: nil)
        var merged: [UUID] = []
        var baseline: Set<UUID> = []
        var log: [String] = []

        func sync(
            _ feed: FakeFeed,
            pager: FeedPager = FeedPager(),
            fallbackCursor: Date? = nil
        ) async throws -> FeedPager.Outcome {
            let outcome = try await pager.run(
                from: state,
                fallbackCursor: fallbackCursor,
                fetch: { try feed.fetch($0) },
                merge: { items, asBaseline in
                    self.merged += items.map(\.eventID)
                    if asBaseline { self.baseline.formUnion(items.map(\.eventID)) }
                    self.log.append("merge")
                },
                persist: { state in
                    self.state = state
                    self.log.append("persist")
                }
            )
            state = outcome.state
            return outcome
        }
    }

    /// A device that has synced once, so the next read is news rather than a baseline.
    private func caughtUp(_ feed: FakeFeed) async throws -> Device {
        let device = Device()
        feed.add(1)
        _ = try await device.sync(feed)
        device.merged.removeAll()
        device.baseline.removeAll()
        device.log.removeAll()
        return device
    }

    @Test("More than a page between two syncs arrives in full, in one sync")
    func readsPastTheFirstPage() async throws {
        let feed = FakeFeed()
        let device = try await caughtUp(feed)
        feed.add(900)

        let outcome = try await device.sync(feed)

        #expect(Set(device.merged) == Set(feed.events.dropFirst().map(\.id)))
        #expect(device.baseline.isEmpty, "a backlog of news is still news")
        #expect(device.state.pending.isEmpty)
        #expect(device.state.cursor == feed.events.last?.at)
        #expect(outcome.pagesRead == 5)
    }

    /// The budget is a delay, never a loss: the rest of the window is the server's own
    /// continuation, kept until a later sync has the requests to spare.
    @Test("Past the budget, the rest of the window waits for the next sync")
    func budgetDefersRatherThanDrops() async throws {
        let feed = FakeFeed()
        let device = try await caughtUp(feed)
        feed.add(1_500)

        _ = try await device.sync(feed)
        #expect(device.merged.count == 1_000)
        #expect(device.state.pending.count == 1)

        // Meanwhile something new: the next sync reads that first, then the backlog.
        feed.add(10)
        let before = device.merged.count
        _ = try await device.sync(feed)
        let second = device.merged[before...]
        #expect(Set(second.prefix(10)) == Set(feed.events.suffix(10).map(\.id)))

        #expect(Set(device.merged) == Set(feed.events.dropFirst().map(\.id)))
        #expect(device.state.pending.isEmpty)
    }

    /// The first sync meets a catalogue. Stored as history, and not chased past one page —
    /// a week of somebody else's past is not owed to a device that has just arrived.
    @Test("A first sync is a baseline and stops at its first page")
    func firstSyncIsOnePageOfHistory() async throws {
        let feed = FakeFeed()
        feed.add(500)
        let device = Device()

        let outcome = try await device.sync(feed)

        #expect(device.merged.count == 200)
        #expect(device.baseline == Set(device.merged))
        #expect(device.state.pending.isEmpty)
        #expect(device.state.cursor == feed.events.last?.at)
        #expect(outcome.pagesRead == 1)
    }

    @Test("A dropped connection after the first page is a slower catch-up, not a loss")
    func interruptionKeepsThePlace() async throws {
        let feed = FakeFeed()
        let device = try await caughtUp(feed)
        feed.add(700)
        feed.failAt = feed.requests.count + 2

        let outcome = try await device.sync(feed)
        #expect(outcome.interruption != nil)
        #expect(device.merged.count == 400)
        #expect(device.state.pending.count == 1)

        feed.failAt = nil
        _ = try await device.sync(feed)
        #expect(Set(device.merged) == Set(feed.events.dropFirst().map(\.id)))
        #expect(device.state.pending.isEmpty)
    }

    /// Only the head may fail a sync: nothing has been stored, and the cursor must stay put
    /// so the window is asked for again.
    @Test("A failed first page moves nothing")
    func failedHeadMovesNothing() async throws {
        let feed = FakeFeed()
        let device = try await caughtUp(feed)
        let cursor = device.state.cursor
        feed.add(5)
        feed.failAt = feed.requests.count

        await #expect(throws: FakeFeed.Dropped.self) { _ = try await device.sync(feed) }
        #expect(device.state.cursor == cursor)
        #expect(device.merged.isEmpty)
    }

    /// A token the server will not read — a deploy that changed the format — is spent, not
    /// asked for on every sync for ever.
    @Test("A refused continuation is dropped from the backlog")
    func refusedContinuationIsSpent() async throws {
        let feed = FakeFeed()
        let device = try await caughtUp(feed)
        feed.add(1_500)
        _ = try await device.sync(feed)
        #expect(device.state.pending.count == 1)

        feed.refusesContinuations = true
        _ = try await device.sync(feed)
        #expect(device.state.pending.isEmpty)
    }

    /// The write order is the crash guarantee: a page is stored before the state that says
    /// so, never after, so a process killed in between reads a page twice rather than never.
    @Test("State is written after every page, and only after it is merged")
    func persistsAfterEachMerge() async throws {
        let feed = FakeFeed()
        let device = try await caughtUp(feed)
        feed.add(450)

        _ = try await device.sync(feed)

        #expect(device.log == ["merge", "persist", "merge", "persist", "merge", "persist"])
    }

    /// The server had nothing for brands the device follows. The cursor still moves when the
    /// caller says the read reached something, or every later sync is a baseline too.
    @Test("An empty head takes the caller's fallback, or leaves the cursor alone")
    func emptyHeadFallsBack() async throws {
        let feed = FakeFeed()
        let moment = Date(timeIntervalSince1970: 1_790_000_000)

        let device = Device()
        _ = try await device.sync(feed, fallbackCursor: moment)
        #expect(device.state.cursor == moment)

        let untouched = Device()
        _ = try await untouched.sync(feed)
        #expect(untouched.state.cursor == nil)
    }

    /// The only remaining way to lose an event, and it takes a phone more than four whole
    /// windows behind: the oldest is dropped so the backlog cannot grow without bound.
    @Test("The backlog is capped, and the oldest window is what goes")
    func backlogIsBounded() async throws {
        let feed = FakeFeed()
        let device = try await caughtUp(feed)
        let pager = FeedPager(maxPages: 1, maxPending: 2)

        for _ in 0..<3 {
            feed.add(300)
            _ = try await device.sync(feed, pager: pager)
        }
        #expect(device.state.pending.count == 2)
        let newest = try #require(device.state.pending.first)
        // The third window began where the second ended, at the 600th event.
        #expect(newest.hasPrefix("\(feed.events[600].at.timeIntervalSince1970)|"))
    }
}

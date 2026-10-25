// FeedPaging.swift
// Which events a page of `GET /v1/feed` carries, and how the next page finds its place.

import Foundation

/// How a read of the feed is split into pages — fairly between brands, and without losing
/// anything at a page boundary.
///
/// **What this replaced.** The route answered newest first with at most 200 events and named
/// the newest of them as the cursor, and the app asked once per sync. Everything past the
/// 200th event was therefore behind the cursor before it had ever been sent: a busy brand
/// writing 250 restocks between two syncs pushed every other brand's news out of the page,
/// and the cursor then stepped over it. The one quiet brand's one drop — the most valuable
/// row in the window — was exactly the row that went missing.
///
/// Two changes, and they are separable:
///
/// - **The order is fair.** Every brand's newest event comes before any brand's second
///   newest, and so on down (`rank`, then newest first within a rank). One busy brand can no
///   longer fill a page while another has something unsent; it fills the *tail* of the
///   read instead. This applies to the first page too, which is all the 1.0 app ever asks
///   for — so the build in the App Store, which cannot page, now loses a busy brand's deep
///   history rather than a quiet brand's only drop. It still receives at most one page,
///   `nextCursor` is still the newest event in it, and it never sees the rest of this.
/// - **The read can be continued.** A page that leaves anything behind says so with a
///   `continuation`, which carries the window and the position, and a newer client follows
///   it until it comes back nil. The window is fixed when the read begins — `until` is the
///   newest event visible to the first page — so events arriving mid-read wait for the next
///   one rather than shifting everything under the reader.
///
/// **Why the position is a keyset and not an offset.** An offset counts rows, and the set
/// can change between pages: an unfollow removes a whole brand's rows, and every row after
/// them would move up past the reader unseen. A keyset names *where* the reader is in the
/// order, which does not move when unrelated rows disappear. Two narrower cases remain, and
/// neither is new. A write that commits late with a timestamp inside a window already being
/// read can be passed over — the race the single cursor always had, measured in the
/// milliseconds between stamping a row and committing it; the rows it shifts are repeated,
/// never skipped, and the client dedupes by event id. And retention deleting older rows of a
/// brand mid-read can move that brand's remaining rows past the reader, which only touches
/// events already past the thirty-day horizon — rows that were about to be deleted anyway.
///
/// **Comparisons are done here, never in SQL.** The keyset holds a timestamp, and the read
/// back of a `timestamptz` into a `Date` is not guaranteed to survive the trip back into a
/// bind with its last microsecond intact — an equality that is off by one drops exactly the
/// tied row the tie-break exists for. The window is narrowed in SQL on inequalities only, and
/// the ranking and the keyset compare the values the database handed back, which are the
/// same values on every page.
enum FeedPaging {
    /// What ranking needs of an event, and nothing else — the page is hydrated afterwards,
    /// once its ids are known, so the whole window is never loaded with products and variants.
    struct Row: Sendable, Equatable {
        var id: UUID
        var brandID: UUID
        var createdAt: Date
    }

    /// Where a reader is in the fair order: the last row it was given.
    struct Position: Codable, Sendable, Equatable {
        /// How many newer events the same brand has in the window.
        var rank: Int
        var createdAt: Date
        var id: UUID
    }

    /// Whether `a` comes before `b`: lower rank first, then newer, then a fixed tie-break on
    /// the id so that two events stamped with one instant still have a settled order.
    static func precedes(_ a: Position, _ b: Position) -> Bool {
        if a.rank != b.rank { return a.rank < b.rank }
        if a.createdAt != b.createdAt { return a.createdAt > b.createdAt }
        return a.id.uuidString > b.id.uuidString
    }

    /// Every row in the window, in the fair order, with its position.
    static func ordered(_ rows: [Row]) -> [Position] {
        var positions: [Position] = []
        positions.reserveCapacity(rows.count)
        for (_, brandRows) in Dictionary(grouping: rows, by: \.brandID) {
            let newestFirst = brandRows.sorted {
                $0.createdAt == $1.createdAt
                    ? $0.id.uuidString > $1.id.uuidString
                    : $0.createdAt > $1.createdAt
            }
            for (rank, row) in newestFirst.enumerated() {
                positions.append(Position(rank: rank, createdAt: row.createdAt, id: row.id))
            }
        }
        return positions.sorted(by: precedes)
    }

    /// One page of the fair order, starting after `position`, and the position to continue
    /// from — nil when nothing is left.
    static func page(
        _ rows: [Row],
        after position: Position?,
        limit: Int
    ) -> (ids: [UUID], next: Position?) {
        let order = ordered(rows)
        let remaining = position.map { start in order.filter { precedes(start, $0) } } ?? order
        let taken = Array(remaining.prefix(max(limit, 1)))
        let next = remaining.count > taken.count ? taken.last : nil
        return (taken.map(\.id), next)
    }
}

/// A read of the feed that has not finished, as the client carries it between pages.
///
/// Opaque on the wire for the reason `DiscoverResponse.nextCursor` is: it is a window *and*
/// a position, and a client doing arithmetic on either would be reimplementing this file.
/// JSON inside base64url rather than a bespoke string, because the dates must round-trip to
/// the last bit — `JSONEncoder` writes a `Date` as a `Double` and reads back the same one,
/// where the ISO-8601 the rest of the API uses keeps whole seconds.
struct FeedContinuation: Codable, Sendable, Equatable {
    /// Exclusive lower bound — the cursor the read began from.
    var since: Date
    /// Inclusive upper bound — the newest event the first page could see.
    var until: Date
    var after: FeedPaging.Position
    /// The kinds the read was begun with (`FeedKinds`). Nil in a token written before kinds
    /// were filtered, which was a read of every kind 1.0 knows.
    var kinds: [String]?

    var token: String {
        let data = (try? JSONEncoder().encode(self)) ?? Data()
        return data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    init(since: Date, until: Date, after: FeedPaging.Position, kinds: [String]? = nil) {
        self.since = since
        self.until = until
        self.after = after
        self.kinds = kinds
    }

    /// Nil for anything this server did not write — a 400 rather than a guess at a window.
    init?(token: String) {
        var base64 = token
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64 += "=" }
        guard let data = Data(base64Encoded: base64),
              let decoded = try? JSONDecoder().decode(FeedContinuation.self, from: data)
        else { return nil }
        self = decoded
    }
}

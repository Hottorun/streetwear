// Usage.swift
// Counting how the app is used, without counting anybody.
//
// 1.0 shipped promising no analytics, and it kept the promise by knowing nothing: not which
// tab is opened, not whether anybody searches, not whether a push is ever tapped. That was
// fine for a free app and is not fine for the next one, which has to decide which AI
// features are worth paying for before building any — and "nobody opens the Style tab" is
// exactly the kind of fact that should decide it.
//
// So the smallest step from "no analytics", and nothing past it:
//
// - **No third-party SDK.** The counts go to our own server and nowhere else, which is what
//   lets the privacy policy say who else is involved in one line.
// - **Tallies, not events.** The phone keeps a count per day per thing — "opened the feed
//   tab 4 times on the 24th" — and sends the tallies. There is no timestamp finer than a
//   day, no sequence, no product, no brand, no search text: only *that* a search was run,
//   never what for.
// - **Totals on arrival.** The server adds each tally to one row per day per thing, shared
//   by everybody, and keeps nothing else. No row per event and no row per device per event
//   exists anywhere, so there is nothing to join a person back onto later.
// - **Weekly actives from one overwritten date.** "How many people used it this week" needs
//   *some* per-device fact, or two opens by one person read as two people. It is the UTC day
//   the device last reported, held on the device row and overwritten — see
//   `UsagePolicy.activeDay` and `docs/server.md`.
//
// Standalone mode sends nothing and records nothing; there is no server to tell.

import Foundation

/// Everything the app counts. The whitelist: the server accepts these names and no others.
///
/// A string on the wire (`UsageCount.event`) rather than this enum, so a newer client that
/// counts something new does not fail an older server's decode — the server refuses the one
/// unknown name and keeps the rest.
public enum UsageEvent: String, Codable, CaseIterable, Sendable {
    /// The app came to the foreground from the background (or was launched).
    case appOpened = "app.opened"
    case feedTab = "tab.feed"
    /// The tab that replaced Discover. Its own name rather than a reuse of `discoverTab`,
    /// because it is a different page — Discover is one part of it — and a count that
    /// carried on under the old name would compare the two as if they were one.
    case shopTab = "tab.shop"
    case savedTab = "tab.saved"
    /// Discover and Style are no longer tabs, and stay accepted: builds that still have
    /// them go on reporting for as long as they are installed.
    case discoverTab = "tab.discover"
    case styleTab = "tab.style"
    /// A search of the shared brand catalogue was run. Never what it was for.
    case brandSearch = "brand.search"
    /// Somebody asked the server to look at a site nobody had added yet.
    case brandCheck = "brand.check"
    case brandFollowed = "brand.followed"
    /// A notification from the server was tapped.
    case pushOpened = "push.opened"
    case saveAdded = "save.added"
    case fitCreated = "fit.created"

    /// The tab event for a tab's name in `Tabs`, so a tab added later cannot quietly count
    /// as one of the others.
    public init?(tab: String) {
        self.init(rawValue: "tab.\(tab)")
    }
}

/// One tally: how many times `event` happened on `day`.
public struct UsageCount: Codable, Sendable, Hashable {
    /// `yyyy-MM-dd`, in UTC — see `UsagePolicy.day(of:)`.
    public var day: String
    /// A `UsageEvent` raw value.
    public var event: String
    public var count: Int

    public init(day: String, event: String, count: Int) {
        self.day = day
        self.event = event
        self.count = count
    }
}

/// `POST /v1/usage`: whatever the phone has counted since it last reported.
public struct UsageReport: Codable, Sendable, Hashable {
    public var counts: [UsageCount]

    public init(counts: [UsageCount]) {
        self.counts = counts
    }
}

/// What the server took. A count, not a list: the client clears what it sent either way,
/// because a tally the server refused once will be refused again.
public struct UsageReceipt: Codable, Sendable, Hashable {
    public var accepted: Int
    public var refused: Int

    public init(accepted: Int, refused: Int) {
        self.accepted = accepted
        self.refused = refused
    }
}

/// The bounds a report is held to. The client trims to them so its report is accepted; the
/// server is the only enforcer and re-checks every one.
///
/// They are what keeps a counting route from becoming a write amplifier: a report can name
/// at most `maxEntries` rows, each row is one of a fixed handful of names on one of a fixed
/// handful of days, and so the whole table can only ever grow by about a dozen rows a day,
/// however many reports arrive.
public enum UsagePolicy {
    /// How far back a tally may be dated. A phone that was offline for a week still
    /// reports its week; anything older is dropped on both ends rather than back-filled
    /// into a total somebody may already have read.
    public static let maxAgeDays = 7

    /// The most rows one report may carry: every event, on every acceptable day, with room.
    /// Past this a report is not the app, and it is refused whole.
    public static let maxEntries = 96

    /// The most one tally may say. Nobody opens a tab five hundred times in a day; a count
    /// past this is not a person, and is refused rather than quietly reduced.
    public static let maxCount = 500

    /// The server-side rows for weekly and daily actives. Not `UsageEvent`s, because a
    /// client must never be able to report itself active — they are written only by the
    /// server, once per device per day, from `devices.active_on`.
    public static let activeDay = "active.day"
    public static let activeWeek = "active.week"

    private static var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    /// The UTC day a moment falls on, as `yyyy-MM-dd`.
    ///
    /// UTC rather than the phone's own zone, so every report — and the server's own clock —
    /// agrees on where one day ends. Built from calendar components rather than a shared
    /// `DateFormatter`, which is not safe to use from two threads at once and is exactly the
    /// race strict concurrency once found in this package.
    public static func day(of date: Date) -> String {
        let parts = utc.dateComponents([.year, .month, .day], from: date)
        func padded(_ value: Int?, _ width: Int) -> String {
            let digits = String(value ?? 0)
            return String(repeating: "0", count: max(0, width - digits.count)) + digits
        }
        return "\(padded(parts.year, 4))-\(padded(parts.month, 2))-\(padded(parts.day, 2))"
    }

    /// The start of a `yyyy-MM-dd` day in UTC, or nil when it is not one.
    public static func date(ofDay day: String) -> Date? {
        let parts = day.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              let year = Int(parts[0]), let month = Int(parts[1]), let dayOfMonth = Int(parts[2])
        else { return nil }
        let components = DateComponents(year: year, month: month, day: dayOfMonth)
        guard let date = utc.date(from: components),
              // Round-tripped, so "2026-02-31" is refused rather than read as 3 March.
              Self.day(of: date) == day
        else { return nil }
        return date
    }

    /// The Monday of the ISO week a day falls in, as `yyyy-MM-dd`.
    public static func weekStart(ofDay day: String) -> String? {
        guard let date = date(ofDay: day) else { return nil }
        // `weekday` is 1 for Sunday through 7 for Saturday; Monday is 2.
        let weekday = utc.component(.weekday, from: date)
        let sinceMonday = (weekday + 5) % 7
        guard let monday = utc.date(byAdding: .day, value: -sinceMonday, to: date) else { return nil }
        return Self.day(of: monday)
    }

    /// Whether a tally may be dated `day`, reported at `now`.
    ///
    /// Today and the `maxAgeDays` before it — and tomorrow, because a phone whose clock runs
    /// a few minutes fast reports tomorrow's date for the last few minutes of every day.
    public static func isAcceptable(day: String, now: Date = Date()) -> Bool {
        guard let date = date(ofDay: day) else { return false }
        let today = utc.startOfDay(for: now)
        guard let earliest = utc.date(byAdding: .day, value: -maxAgeDays, to: today),
              let latest = utc.date(byAdding: .day, value: 1, to: today)
        else { return false }
        return date >= earliest && date <= latest
    }

    /// The tallies in a report the server will add to its totals, and how many it refused.
    ///
    /// Refused per row rather than whole — a newer client's unknown event, or a tally that
    /// aged out on a phone left in a drawer, must not throw away the rest — except for a
    /// report that is simply too long, which is refused whole for the reason
    /// `PollHintPolicy.maxPerUser` is: it is not the app, and a quietly truncated answer is
    /// worse than a plain refusal.
    public static func accepted(_ report: UsageReport, now: Date = Date()) -> (accepted: [UsageCount], refused: Int) {
        guard report.counts.count <= maxEntries else { return ([], report.counts.count) }

        // A row named twice is refused both times: the client keeps one tally per day per
        // event, so a second copy is not the app, and there is no telling which was meant.
        var seen: [String: Int] = [:]
        for row in report.counts { seen["\(row.day)|\(row.event)", default: 0] += 1 }

        var accepted: [UsageCount] = []
        for row in report.counts {
            guard UsageEvent(rawValue: row.event) != nil,
                  (1...maxCount).contains(row.count),
                  seen["\(row.day)|\(row.event)"] == 1,
                  isAcceptable(day: row.day, now: now)
            else { continue }
            accepted.append(row)
        }
        return (accepted, report.counts.count - accepted.count)
    }
}

/// What the phone has counted and not yet reported. A plain value, so the batching rules
/// are testable without a phone, a server or `UserDefaults`.
public struct UsageTally: Codable, Sendable, Hashable {
    /// Day → event → count.
    public private(set) var days: [String: [String: Int]] = [:]

    public init() {}

    public var isEmpty: Bool { days.values.allSatisfy(\.isEmpty) }

    public mutating func record(_ event: UsageEvent, at date: Date = Date()) {
        days[UsagePolicy.day(of: date), default: [:]][event.rawValue, default: 0] += 1
    }

    /// The report to send: newest days first, each tally capped at `maxCount`, nothing the
    /// server would refuse for its age, and never more rows than it will take.
    ///
    /// Capped rather than split across reports, because past the cap the number is not
    /// about a person any more — and splitting would be a way to send the server more than
    /// its bound says one phone can mean.
    public func report(now: Date = Date()) -> UsageReport {
        let rows = days
            .filter { UsagePolicy.isAcceptable(day: $0.key, now: now) }
            .flatMap { day, events in
                events.compactMap { event, count -> UsageCount? in
                    guard count > 0, UsageEvent(rawValue: event) != nil else { return nil }
                    return UsageCount(day: day, event: event, count: min(count, UsagePolicy.maxCount))
                }
            }
            // Ordered so the report — and which rows a full one leaves for next time — is
            // the same every time it is built. A dictionary's order is not.
            .sorted { $0.day != $1.day ? $0.day > $1.day : $0.event < $1.event }
        return UsageReport(counts: Array(rows.prefix(UsagePolicy.maxEntries)))
    }

    /// Takes what was sent out of the tally, leaving anything counted while it was in flight.
    ///
    /// Subtracted rather than cleared: a tab opened while the request was on the wire is a
    /// tally the server has not seen, and clearing the whole store on the reply would lose it.
    public mutating func remove(_ sent: [UsageCount]) {
        for row in sent {
            guard let held = days[row.day]?[row.event] else { continue }
            // A tally that went out at the cap takes its excess with it, or the overflow
            // would be sent as a second report and the cap would bound nothing.
            let remaining = row.count >= UsagePolicy.maxCount ? 0 : held - row.count
            days[row.day]?[row.event] = remaining > 0 ? remaining : nil
        }
        days = days.filter { !$0.value.isEmpty }
    }

    /// Drops days the server would no longer accept, and days with nothing left in them.
    public mutating func prune(now: Date = Date()) {
        days = days.filter { day, events in
            !events.isEmpty && UsagePolicy.isAcceptable(day: day, now: now)
        }
    }

    /// Lenient, like every value this app keeps in `UserDefaults`: a shape written by an
    /// older build must decode as an empty tally rather than throw on launch.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        days = (try? container.decode([String: [String: Int]].self, forKey: .days)) ?? [:]
    }
}

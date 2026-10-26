import Foundation
import Testing

@testable import StreetwCore

@Suite("Usage counts")
struct UsageTests {
    /// 2026-10-24 12:00 UTC, a Saturday.
    private let noon = Date(timeIntervalSince1970: 1_792_843_200)

    private func at(day offset: Int, from date: Date? = nil) -> Date {
        (date ?? noon).addingTimeInterval(Double(offset) * 86_400)
    }

    // MARK: Days

    @Test("A day is the UTC calendar day, zero-padded")
    func dayIsUTC() {
        #expect(UsagePolicy.day(of: noon) == "2026-10-24")
        // 23:30 UTC is still the 24th wherever the phone is.
        #expect(UsagePolicy.day(of: noon.addingTimeInterval(11.5 * 3600)) == "2026-10-24")
        #expect(UsagePolicy.day(of: Date(timeIntervalSince1970: 0)) == "1970-01-01")
    }

    @Test("Only a real yyyy-MM-dd parses as a day")
    func dayParsing() {
        #expect(UsagePolicy.date(ofDay: "2026-10-24") != nil)
        for bad in ["2026-02-31", "2026-10-4", "26-10-24", "2026/10/24", "", "tomorrow", "2026-10-24T00"] {
            #expect(UsagePolicy.date(ofDay: bad) == nil, "\(bad)")
        }
    }

    @Test("A week starts on the Monday it contains")
    func weekStartsMonday() {
        #expect(UsagePolicy.weekStart(ofDay: "2026-10-24") == "2026-10-19") // Saturday
        #expect(UsagePolicy.weekStart(ofDay: "2026-10-25") == "2026-10-19") // Sunday
        #expect(UsagePolicy.weekStart(ofDay: "2026-10-19") == "2026-10-19") // Monday itself
        #expect(UsagePolicy.weekStart(ofDay: "2026-10-26") == "2026-10-26")
        // Across a month and a year boundary.
        #expect(UsagePolicy.weekStart(ofDay: "2027-01-01") == "2026-12-28")
    }

    /// A phone offline for a week still reports its week; one left in a drawer for a month
    /// does not back-fill totals somebody may already have read.
    @Test("A tally may be up to a week old, or a day ahead for a fast clock")
    func acceptableDays() {
        #expect(UsagePolicy.isAcceptable(day: "2026-10-24", now: noon))
        #expect(UsagePolicy.isAcceptable(day: "2026-10-17", now: noon))
        #expect(!UsagePolicy.isAcceptable(day: "2026-10-16", now: noon))
        #expect(UsagePolicy.isAcceptable(day: "2026-10-25", now: noon))
        #expect(!UsagePolicy.isAcceptable(day: "2026-10-26", now: noon))
        #expect(!UsagePolicy.isAcceptable(day: "garbage", now: noon))
    }

    // MARK: What the server accepts

    @Test("Known events on acceptable days are accepted, the rest refused row by row")
    func perRowRefusal() {
        let report = UsageReport(counts: [
            UsageCount(day: "2026-10-24", event: "tab.feed", count: 3),
            UsageCount(day: "2026-10-24", event: "tab.someday", count: 1),   // a newer client
            UsageCount(day: "2026-09-01", event: "app.opened", count: 2),    // too old
            UsageCount(day: "2026-10-24", event: "save.added", count: 0),    // nothing
            UsageCount(day: "2026-10-24", event: "fit.created", count: UsagePolicy.maxCount + 1)
        ])
        let result = UsagePolicy.accepted(report, now: noon)
        #expect(result.accepted == [UsageCount(day: "2026-10-24", event: "tab.feed", count: 3)])
        #expect(result.refused == 4)
    }

    /// A client can never report itself active — that row is the server's alone, written
    /// once per device per day.
    @Test("The server's own active rows are not reportable")
    func activeRowsAreServerOnly() {
        let report = UsageReport(counts: [
            UsageCount(day: "2026-10-24", event: UsagePolicy.activeDay, count: 1),
            UsageCount(day: "2026-10-19", event: UsagePolicy.activeWeek, count: 1)
        ])
        #expect(UsagePolicy.accepted(report, now: noon).accepted.isEmpty)
    }

    @Test("A row named twice in one report is refused both times")
    func duplicatesRefused() {
        let report = UsageReport(counts: [
            UsageCount(day: "2026-10-24", event: "tab.feed", count: 3),
            UsageCount(day: "2026-10-24", event: "tab.feed", count: 4),
            UsageCount(day: "2026-10-23", event: "tab.feed", count: 1)
        ])
        let result = UsagePolicy.accepted(report, now: noon)
        #expect(result.accepted == [UsageCount(day: "2026-10-23", event: "tab.feed", count: 1)])
        #expect(result.refused == 2)
    }

    @Test("A report longer than the bound is refused whole")
    func oversizedRefusedWhole() {
        let rows = (0...UsagePolicy.maxEntries).map { _ in
            UsageCount(day: "2026-10-24", event: "tab.feed", count: 1)
        }
        let result = UsagePolicy.accepted(UsageReport(counts: rows), now: noon)
        #expect(result.accepted.isEmpty)
        #expect(result.refused == rows.count)
    }

    /// The bound has to admit everything the app can legitimately send, or a phone back
    /// from a week offline is refused whole.
    @Test("A full week of every event fits in one report")
    func aFullWeekFits() {
        var tally = UsageTally()
        for offset in -UsagePolicy.maxAgeDays...0 {
            for event in UsageEvent.allCases { tally.record(event, at: at(day: offset)) }
        }
        let report = tally.report(now: noon)
        #expect(report.counts.count == (UsagePolicy.maxAgeDays + 1) * UsageEvent.allCases.count)
        #expect(report.counts.count <= UsagePolicy.maxEntries)
        #expect(UsagePolicy.accepted(report, now: noon).refused == 0)
    }

    // MARK: The phone's tally

    @Test("Recording adds up per day per event")
    func recordingAddsUp() {
        var tally = UsageTally()
        tally.record(.feedTab, at: noon)
        tally.record(.feedTab, at: noon.addingTimeInterval(60))
        tally.record(.feedTab, at: at(day: -1))
        tally.record(.saveAdded, at: noon)

        let report = tally.report(now: noon)
        #expect(report.counts == [
            UsageCount(day: "2026-10-24", event: "save.added", count: 1),
            UsageCount(day: "2026-10-24", event: "tab.feed", count: 2),
            UsageCount(day: "2026-10-23", event: "tab.feed", count: 1)
        ])
    }

    @Test("Days the server would refuse are left out of the report and pruned")
    func oldDaysDropped() {
        var tally = UsageTally()
        tally.record(.appOpened, at: at(day: -30))
        tally.record(.appOpened, at: noon)
        #expect(tally.report(now: noon).counts.map(\.day) == ["2026-10-24"])

        tally.prune(now: noon)
        #expect(tally.days.keys.sorted() == ["2026-10-24"])
    }

    /// A tab opened while the request was on the wire is a tally the server has not seen.
    @Test("Removing what was sent keeps what was counted in flight")
    func removeSubtracts() {
        var tally = UsageTally()
        tally.record(.feedTab, at: noon)
        tally.record(.feedTab, at: noon)
        let sent = tally.report(now: noon).counts

        tally.record(.feedTab, at: noon)       // counted while the request was out
        tally.record(.discoverTab, at: noon)
        tally.remove(sent)

        #expect(tally.report(now: noon).counts == [
            UsageCount(day: "2026-10-24", event: "tab.discover", count: 1),
            UsageCount(day: "2026-10-24", event: "tab.feed", count: 1)
        ])

        tally.remove(tally.report(now: noon).counts)
        #expect(tally.isEmpty)
        #expect(tally.days.isEmpty)
    }

    /// Past the cap the number is not a person, and splitting the overflow into a second
    /// report would make the cap bound nothing.
    @Test("A tally sent at the cap takes its excess with it")
    func capTakesExcess() {
        var tally = UsageTally()
        for _ in 0..<(UsagePolicy.maxCount + 40) { tally.record(.feedTab, at: noon) }
        let sent = tally.report(now: noon).counts
        #expect(sent == [UsageCount(day: "2026-10-24", event: "tab.feed", count: UsagePolicy.maxCount)])

        tally.remove(sent)
        #expect(tally.isEmpty)
    }

    @Test("A tally decodes leniently and round-trips")
    func lenientDecoding() throws {
        var tally = UsageTally()
        tally.record(.fitCreated, at: noon)
        let data = try JSONEncoder().encode(tally)
        #expect(try JSONDecoder().decode(UsageTally.self, from: data) == tally)

        let older = try JSONDecoder().decode(UsageTally.self, from: Data(#"{"other": 1}"#.utf8))
        #expect(older.isEmpty)
    }

    @Test("Every tab has its own event")
    func tabEvents() {
        for tab in ["feed", "shop", "saved"] {
            #expect(UsageEvent(tab: tab) != nil, "\(tab)")
        }
        // Retired tabs, still reported by the builds that had them.
        for tab in ["discover", "style"] {
            #expect(UsageEvent(tab: tab) != nil, "\(tab)")
        }
        #expect(UsageEvent(tab: "brands") == nil)
    }
}

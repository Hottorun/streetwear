// Usage.swift
// Adding the phones' tallies to the totals, and reading the totals back.
//
// See `UsagePolicy` in StreetwCore for what a report may contain and why each bound exists.
// What this file owns is the two writes a report makes, and the one rule that keeps them
// anonymous: **nothing written here names a device.** A report arrives authenticated — that
// is what puts it behind the rate limit and `RequireDevice` — and the device is used for
// exactly one thing, the overwritten `active_on` day. The tallies themselves go straight
// into totals shared by everybody.

import Fluent
import Foundation
import SQLKit
import StreetwCore
import Vapor

enum UsageLedger {
    /// Adds each tally to its day's total, creating the row the first time.
    ///
    /// An upsert rather than read-then-write, because two phones reporting the same tab on
    /// the same day at the same moment is the ordinary case, and a read-then-create would
    /// have one of them fail on the unique constraint. `ON CONFLICT … DO UPDATE` is the same
    /// statement on Postgres and SQLite, which is why it is raw SQL rather than Fluent's
    /// builder — and one statement per row, because Postgres refuses a multi-row upsert that
    /// touches one row twice.
    static func add(_ rows: [UsageCount], on db: any Database) async throws {
        guard let sql = db as? any SQLDatabase else { return }
        for row in rows {
            try await sql.raw("""
                INSERT INTO usage_counts (id, day, event, total) \
                VALUES (\(bind: UUID()), \(bind: row.day), \(bind: row.event), \(bind: row.count)) \
                ON CONFLICT (day, event) DO UPDATE SET total = usage_counts.total + excluded.total
                """).run()
        }
    }

    /// Counts the device as active today — once a day, and once a week — and remembers that
    /// it has been, by overwriting the one day on its row.
    ///
    /// **Why a day on the device row and not a counter the phone keeps.** "How many people
    /// used it this week" cannot be summed from daily totals, because one person on five
    /// days is five daily actives and one weekly one. It needs *some* per-device memory, and
    /// this is the least there can be: one date, overwritten, never a history. A phone
    /// keeping its own "already counted this week" flag would need nothing here, and would
    /// count itself again on every reinstall and every bug that cleared the flag — with no
    /// way for this end to notice.
    ///
    /// Two reports from one device in the same instant could both see yesterday's date and
    /// count it twice. The app sends one at a time, so the only caller that can do it is one
    /// inflating the number by one, which is not worth a lock on the hot path.
    static func markActive(_ device: DeviceModel, now: Date, on db: any Database) async throws {
        let today = UsagePolicy.day(of: now)
        guard device.activeOn != today else { return }

        var rows = [UsageCount(day: today, event: UsagePolicy.activeDay, count: 1)]
        if let week = UsagePolicy.weekStart(ofDay: today),
           device.activeOn.flatMap(UsagePolicy.weekStart(ofDay:)) != week {
            rows.append(UsageCount(day: week, event: UsagePolicy.activeWeek, count: 1))
        }

        device.activeOn = today
        try await device.save(on: db)
        try await add(rows, on: db)
    }

    /// The totals for the last `days` days, newest first.
    static func summary(days: Int, now: Date, on db: any Database) async throws -> UsageSummary {
        let today = UsagePolicy.day(of: now)
        let from = UsagePolicy.day(of: now.addingTimeInterval(-Double(days - 1) * 86_400))
        // A week row is dated on its Monday, which can fall before `from`; the week that
        // `from` is in is still one this summary is about.
        let fromWeek = UsagePolicy.weekStart(ofDay: from) ?? from

        let rows = try await UsageCountModel.query(on: db)
            .filter(\.$day >= fromWeek)
            .all()

        var byDay: [String: UsageSummary.Day] = [:]
        var weeks: [UsageSummary.Week] = []
        for row in rows {
            switch row.event {
            case UsagePolicy.activeWeek:
                weeks.append(.init(week: row.day, activeDevices: row.total))
            case UsagePolicy.activeDay where row.day >= from:
                byDay[row.day, default: .init(day: row.day)].activeDevices = row.total
            default:
                guard row.day >= from else { continue }
                byDay[row.day, default: .init(day: row.day)].counts[row.event] = row.total
            }
        }

        let weekAgo = UsagePolicy.day(of: now.addingTimeInterval(-6 * 86_400))
        let recent = try await DeviceModel.query(on: db)
            .filter(\.$activeOn >= weekAgo)
            .count()

        return UsageSummary(
            from: from,
            to: today,
            activeLastSevenDays: recent,
            weeks: weeks.sorted { $0.week > $1.week },
            days: byDay.values.sorted { $0.day > $1.day }
        )
    }
}

/// `GET /admin/usage` — what the operator reads.
///
/// Server-only, unlike the report it summarises: no client decodes this, so it does not
/// belong in the shared wire contract.
struct UsageSummary: Content {
    struct Day: Content {
        var day: String
        /// Devices that reported that day.
        var activeDevices = 0
        /// `UsageEvent` raw value → total.
        var counts: [String: Int] = [:]

        init(day: String) {
            self.day = day
        }
    }

    struct Week: Content {
        /// The Monday the week starts on.
        var week: String
        /// Devices that reported at least once that week — the number this whole feature
        /// was asked to answer.
        var activeDevices: Int
    }

    var from: String
    var to: String
    /// Devices whose last report falls in the seven days ending today. A rolling week, read
    /// off `devices.active_on`, beside the calendar weeks in `weeks`.
    var activeLastSevenDays: Int
    var weeks: [Week]
    var days: [Day]
}

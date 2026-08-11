// DropCadence.swift
// When is this brand likely to drop next?
//
// There is no feed of release dates to subscribe to. Storefronts publish what is already
// out, not what is coming, and the "drop calendars" that exist elsewhere are hand-edited
// by people. Rather than invent a schedule or scrape someone else's, this reads the one
// honest signal we already hold: **the brand's own history**.
//
// A catalogue of a few hundred products carries hundreds of publication timestamps, and
// most streetwear brands are strikingly regular — Thursday mornings, Friday at 11. The
// modal weekday of those timestamps is a real, checkable pattern.
//
// It is therefore reported as a *pattern*, never as a promise, and only when the history
// actually supports one. `confidence` is the share of drops falling on that weekday, so
// the UI can say "usually Thursdays" for 0.8 and stay silent at 0.2.

import Foundation

public struct DropCadence: Sendable, Hashable {
    /// 1 = Sunday, matching `Calendar.component(.weekday:)`.
    public var weekday: Int
    /// Typical hour of day, 0–23, in the user's calendar.
    public var hour: Int
    /// Share of recent drops that landed on `weekday`, 0–1.
    public var confidence: Double
    /// How many drops the estimate is built from.
    public var sampleSize: Int

    public init(weekday: Int, hour: Int, confidence: Double, sampleSize: Int) {
        self.weekday = weekday
        self.hour = hour
        self.confidence = confidence
        self.sampleSize = sampleSize
    }

    /// Below this the brand has no rhythm worth claiming, and saying nothing is better
    /// than saying something wrong about when to be at a checkout.
    public static let minimumConfidence = 0.4
    /// Fewer drops than this and any pattern is noise.
    public static let minimumSample = 6

    public var isReliable: Bool {
        sampleSize >= Self.minimumSample && confidence >= Self.minimumConfidence
    }

    public var weekdayName: String {
        let symbols = Calendar(identifier: .gregorian).weekdaySymbols
        let index = weekday - 1
        return symbols.indices.contains(index) ? symbols[index] : "?"
    }

    /// The next occurrence of this weekday and hour, strictly in the future.
    public func nextOccurrence(after now: Date = Date(), calendar: Calendar = .current) -> Date? {
        var components = DateComponents()
        components.weekday = weekday
        components.hour = hour
        components.minute = 0
        return calendar.nextDate(
            after: now,
            matching: components,
            matchingPolicy: .nextTime,
            direction: .forward
        )
    }
}

public enum DropCadenceEstimator {
    /// Reads a rhythm out of publication timestamps, or returns nil when there isn't one.
    ///
    /// Only recent history counts: a brand that moved from Saturday to Thursday two years
    /// ago should be described by what it does now, and old products would otherwise
    /// outvote current behaviour purely by being numerous.
    public static func estimate(
        from dates: [Date],
        now: Date = Date(),
        within days: Int = 180,
        calendar: Calendar = .current
    ) -> DropCadence? {
        let cutoff = now.addingTimeInterval(-Double(days) * 86_400)
        let recent = dates.filter { $0 >= cutoff && $0 <= now }
        guard recent.count >= DropCadence.minimumSample else { return nil }

        // A drop is an *event*, not a product. A brand publishing 60 items on one
        // Thursday morning must count once, or a single large collection would decide
        // the answer on its own.
        var days: Set<DateComponents> = []
        var byDay: [DateComponents: [Date]] = [:]
        for date in recent {
            let key = calendar.dateComponents([.year, .month, .day], from: date)
            days.insert(key)
            byDay[key, default: []].append(date)
        }
        guard days.count >= DropCadence.minimumSample else { return nil }

        let dayStarts = byDay.compactMap { $0.value.min() }
        var weekdayCounts: [Int: Int] = [:]
        for date in dayStarts {
            weekdayCounts[calendar.component(.weekday, from: date), default: 0] += 1
        }
        guard let (weekday, count) = weekdayCounts.max(by: { $0.value < $1.value }) else { return nil }

        // The typical hour, taken only from drops on the winning weekday — averaging
        // across all days would blend a Thursday 11am release with a Sunday restock.
        let hours = dayStarts
            .filter { calendar.component(.weekday, from: $0) == weekday }
            .map { calendar.component(.hour, from: $0) }
        let hour = hours.isEmpty ? 12 : Int((Double(hours.reduce(0, +)) / Double(hours.count)).rounded())

        return DropCadence(
            weekday: weekday,
            hour: hour,
            confidence: Double(count) / Double(dayStarts.count),
            sampleSize: dayStarts.count
        )
    }
}

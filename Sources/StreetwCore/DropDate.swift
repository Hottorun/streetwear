// DropDate.swift
// Finding an announced release time on a page — when the page actually says one.
//
// The tempting approach is to hunt for a countdown. It does not work: on the storefronts
// that use them (Corteiz, most password-walled Shopify themes) the target time lives in
// JavaScript, not markup, and the ISO timestamps that *are* in the HTML are blog dates,
// asset versions and analytics beacons. Picking one would produce a confident, wrong
// answer — and a drop calendar that lies about times is worse than no calendar.
//
// So this reads only **labelled** dates, where the page has explicitly said what the
// value means:
//
// - `<time datetime="…">` — the HTML element for exactly this
// - schema.org JSON-LD `availabilityStarts`, `releaseDate`, `startDate`
// - a `<meta>` tag naming a release
//
// When one is present the answer is exact. When none is, this returns nil and the
// calendar stays quiet, which is the honest outcome.

import Foundation

public enum DropDateParser {
    /// The soonest future date the page explicitly labels as a start or release.
    ///
    /// Future-only: a page carrying last season's release date is describing history,
    /// and "upcoming" is the one thing a drop calendar must not get wrong.
    public static func find(in html: String, now: Date = Date()) -> Date? {
        let candidates = timeElements(in: html) + structuredDates(in: html) + metaDates(in: html)
        return candidates
            .compactMap { DateParsing.any($0) ?? DateParsing.iso8601($0) }
            .filter { $0 > now }
            .min()
    }

    /// `<time datetime="2026-08-15T11:00:00-04:00">Friday 11am</time>`
    static func timeElements(in html: String) -> [String] {
        matches(pattern: "<time\\b[^>]*\\bdatetime\\s*=\\s*[\"']([^\"']+)[\"']", in: html)
    }

    /// schema.org keys that mean "this becomes available at". Matched by name so an
    /// unrelated timestamp elsewhere in the same JSON can't be mistaken for one.
    static func structuredDates(in html: String) -> [String] {
        let keys = ["availabilityStarts", "releaseDate", "startDate", "validFrom"]
        return keys.flatMap { key in
            matches(pattern: "\"\(key)\"\\s*:\\s*\"([^\"]+)\"", in: html)
        }
    }

    /// `<meta property="product:availability_starts" content="…">` and friends.
    static func metaDates(in html: String) -> [String] {
        matches(
            pattern: "<meta\\b[^>]*\\b(?:name|property)\\s*=\\s*[\"'][^\"']*(?:release|launch|available|drop)[^\"']*[\"'][^>]*\\bcontent\\s*=\\s*[\"']([^\"']+)[\"']",
            in: html
        )
    }

    private static func matches(pattern: String, in html: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return []
        }
        let range = NSRange(html.startIndex..<html.endIndex, in: html)
        return regex.matches(in: html, range: range).compactMap { match in
            Range(match.range(at: 1), in: html).map { String(html[$0]) }
        }
    }
}

// Robots.swift
// A small, deliberately conservative robots.txt reader.
//
// Scope: the directives that actually govern a polite poller — Allow, Disallow and
// Crawl-delay for the group that applies to us. Not a general-purpose implementation.

import Foundation

public struct RobotsRules: Sendable, Equatable {
    public var allow: [String] = []
    public var disallow: [String] = []
    public var crawlDelay: TimeInterval?

    /// Used when robots.txt is missing or unreadable. Absence of rules is permission —
    /// a 404 must not take a brand offline.
    public static let permissive = RobotsRules()

    /// Longest-match wins, and an explicit Allow beats a Disallow of the same length.
    /// That's the de-facto standard behaviour and it matters: Shopify stores disallow
    /// `/collections/*sort_by*` while allowing `/`.
    public func allows(path: String) -> Bool {
        let allowMatch = Self.longestMatch(path, in: allow)
        let disallowMatch = Self.longestMatch(path, in: disallow)

        guard let disallowMatch else { return true }
        guard let allowMatch else { return false }
        return allowMatch >= disallowMatch
    }

    private static func longestMatch(_ path: String, in patterns: [String]) -> Int? {
        var best: Int?
        for pattern in patterns where matches(path: path, pattern: pattern) {
            if best == nil || pattern.count > best! { best = pattern.count }
        }
        return best
    }

    /// Supports the two wildcards robots.txt actually uses: `*` (any run) and `$` (end).
    static func matches(path: String, pattern: String) -> Bool {
        guard !pattern.isEmpty else { return false }

        var regex = "^"
        var anchoredToEnd = false
        for character in pattern {
            switch character {
            case "*": regex += ".*"
            case "$": anchoredToEnd = true
            default: regex += NSRegularExpression.escapedPattern(for: String(character))
            }
        }
        if anchoredToEnd { regex += "$" }

        return path.range(of: regex, options: .regularExpression) != nil
    }

    /// Picks the group for `userAgent`, falling back to `*`. A named group wins outright
    /// — the standard says the most specific matching group applies, not the union.
    public static func parse(_ text: String, userAgent: String) -> RobotsRules {
        let token = userAgent.lowercased()

        var groups: [String: RobotsRules] = [:]
        var currentAgents: [String] = []
        var startingNewGroup = true

        func append(_ mutate: (inout RobotsRules) -> Void) {
            for agent in currentAgents {
                var rules = groups[agent] ?? RobotsRules()
                mutate(&rules)
                groups[agent] = rules
            }
        }

        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.prefix { $0 != "#" }.trimmingCharacters(in: .whitespaces)
            guard let colon = line.firstIndex(of: ":") else { continue }

            let field = line[line.startIndex..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)

            switch field {
            case "user-agent":
                // Consecutive User-agent lines share the following rules.
                if !startingNewGroup {
                    currentAgents = []
                    startingNewGroup = true
                }
                currentAgents.append(value.lowercased())
            case "disallow":
                startingNewGroup = false
                // "Disallow:" with no value means "allow everything".
                if !value.isEmpty { append { $0.disallow.append(value) } }
            case "allow":
                startingNewGroup = false
                if !value.isEmpty { append { $0.allow.append(value) } }
            case "crawl-delay":
                startingNewGroup = false
                if let seconds = TimeInterval(value) { append { $0.crawlDelay = seconds } }
            default:
                break
            }
        }

        // Most specific match first: our own token, then any group whose name is a
        // substring of our UA, then the wildcard.
        if let mine = groups[token] { return mine }
        if let partial = groups.first(where: { !$0.key.isEmpty && $0.key != "*" && token.contains($0.key) }) {
            return partial.value
        }
        return groups["*"] ?? .permissive
    }
}

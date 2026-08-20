// PoliteFetcher.swift
// The politeness budget, as a wrapper around any other fetcher.
//
// Three guarantees, all per-host:
//   1. robots.txt is fetched once, cached, and obeyed
//   2. requests to one host are spaced by at least `minInterval` (or Crawl-delay)
//   3. nothing is ever requested faster than that, even under concurrency
//
// It lives here rather than in the server because the app polls too, and because the
// rules are a property of being a good citizen, not of one deployment.

import Foundation

public actor PoliteFetcher: HTTPFetching {
    private let base: any HTTPFetching
    private let userAgent: String
    private let minInterval: TimeInterval

    private var rules: [String: RobotsRules] = [:]
    /// Reserved slot per host. Reserving *before* sleeping is what makes concurrent
    /// callers queue up rather than all wake at the same instant.
    private var nextSlot: [String: Date] = [:]

    public init(
        wrapping base: any HTTPFetching = Net.live,
        userAgent: String = Net.userAgent,
        minInterval: TimeInterval = 1.0
    ) {
        self.base = base
        self.userAgent = userAgent
        self.minInterval = minInterval
    }

    public func get(_ url: URL, etag: String?) async throws -> HTTPResponse {
        guard let host = url.host() else {
            throw SourceError.badResponse(0)
        }

        let rules = await robots(for: url, host: host)
        let path = url.path.isEmpty ? "/" : url.path
        guard rules.allows(path: path) else {
            throw SourceError.disallowedByRobots(path)
        }

        try await waitForSlot(host: host, delay: max(minInterval, rules.crawlDelay ?? 0))
        return try await base.get(url, etag: etag)
    }

    /// The same budget and the same robots check, for the one source kind whose reads are
    /// spelled as writes.
    ///
    /// A JSON-RPC catalogue read is still a request against somebody's origin, so it queues
    /// behind everything else going to that host. robots.txt is consulted too, even though
    /// its `Disallow` rules are written for crawlers following links: a merchant who has
    /// disallowed a path has said something, and this is not the place to decide it did not
    /// apply to us.
    public func post(_ url: URL, json body: Data, accept: String) async throws -> HTTPResponse {
        guard let host = url.host() else {
            throw SourceError.badResponse(0)
        }

        let rules = await robots(for: url, host: host)
        let path = url.path.isEmpty ? "/" : url.path
        guard rules.allows(path: path) else {
            throw SourceError.disallowedByRobots(path)
        }

        try await waitForSlot(host: host, delay: max(minInterval, rules.crawlDelay ?? 0))
        return try await base.post(url, json: body, accept: accept)
    }

    /// Fetches and caches robots.txt. A missing or broken file is treated as permissive:
    /// failing closed would silently drop brands for an unrelated reason.
    private func robots(for url: URL, host: String) async -> RobotsRules {
        if let cached = rules[host] { return cached }

        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.path = "/robots.txt"
        components?.query = nil

        var parsed = RobotsRules.permissive
        if let robotsURL = components?.url {
            // Counts against the host's budget like any other request.
            try? await waitForSlot(host: host, delay: minInterval)
            if let response = try? await base.get(robotsURL, etag: nil), response.status == 200 {
                parsed = RobotsRules.parse(
                    String(decoding: response.data, as: UTF8.self),
                    userAgent: userAgent
                )
            }
        }
        rules[host] = parsed
        return parsed
    }

    private func waitForSlot(host: String, delay: TimeInterval) async throws {
        let now = Date()
        let slot = max(now, nextSlot[host] ?? .distantPast)
        nextSlot[host] = slot.addingTimeInterval(delay)

        let wait = slot.timeIntervalSince(now)
        if wait > 0 {
            try await Task.sleep(for: .seconds(wait))
        }
    }

    /// Test seam: preload rules so a suite needn't serve robots.txt.
    public func preload(host: String, rules: RobotsRules) {
        self.rules[host] = rules
    }
}

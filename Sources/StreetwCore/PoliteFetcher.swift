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

    /// How many callers deep one host's queue may be before the next is refused.
    ///
    /// **Reserving before sleeping is what makes the budget correct, and it is also what
    /// made it a weapon.** A slot is claimed by pushing `nextSlot[host]` forward *before*
    /// waiting, so concurrent callers queue instead of all firing at once — that part is
    /// deliberate and load-bearing. But there was no ceiling on how far forward, so a
    /// thousand interactive probes aimed at one storefront booked that host's queue over an
    /// hour into the future, and **the poller's own request for the brand queued behind all
    /// of them**. Being early is the entire product; that is how a drop arrives late.
    ///
    /// **Measured in requests, not in seconds, and that distinction is the whole fix.** The
    /// first attempt at this was an absolute horizon — refuse anything queued more than a
    /// minute out — which is wrong in a way a test caught immediately: the interval is per
    /// host and can legitimately be larger than any constant picked here. A site publishing
    /// `Crawl-delay: 120` books the next slot two minutes ahead *by its own request*, so
    /// every second fetch of it, robots.txt included, would have been refused and the brand
    /// would have become permanently unpollable. Counting callers instead scales with
    /// whatever politeness the host asked for: ordinary sequential use is a queue of one and
    /// can never trip, while the abuse case is bounded at this many requests no matter how
    /// many are attempted.
    public static let maxQueueDepth = 8

    /// The rule itself, as a pure function, because it is the part worth pinning.
    ///
    /// Driving this through the actor in a test does not work and is worth saying why: an
    /// actor admits one caller at a time, so a burst of concurrent callers cannot build a
    /// deep queue faster than the executor lets them in — the test ends up measuring the
    /// scheduler rather than the rule. The arithmetic is two comparisons; testing it
    /// directly says exactly what it does, deterministically.
    ///
    /// `delay == 0` means there is no spacing and therefore no queue to be deep, which is
    /// the configured state in most of the suite.
    public static func isQueueTooDeep(wait: TimeInterval, delay: TimeInterval) -> Bool {
        guard delay > 0 else { return false }
        return wait > delay * Double(maxQueueDepth)
    }

    private func waitForSlot(host: String, delay: TimeInterval) async throws {
        let now = Date()
        let slot = max(now, nextSlot[host] ?? .distantPast)
        let wait = slot.timeIntervalSince(now)

        if Self.isQueueTooDeep(wait: wait, delay: delay) {
            // Deliberately *not* reserving in this branch: a refused caller must not push
            // the queue further out, or a loop of refusals would starve the poller just as
            // effectively as a loop of successes did.
            throw SourceError.hostBusy(host, retryAfter: wait)
        }

        nextSlot[host] = slot.addingTimeInterval(delay)
        if wait > 0 {
            try await Task.sleep(for: .seconds(wait))
        }
    }

    /// Test seam: preload rules so a suite needn't serve robots.txt.
    public func preload(host: String, rules: RobotsRules) {
        self.rules[host] = rules
    }
}

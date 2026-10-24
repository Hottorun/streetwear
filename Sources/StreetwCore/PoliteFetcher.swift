// PoliteFetcher.swift
// The politeness budget, as a wrapper around any other fetcher.
//
// Three guarantees, all per-host:
//   1. robots.txt is fetched once, cached, and obeyed
//   2. requests to one host are spaced by at least `minInterval` (or Crawl-delay)
//   3. nothing is ever requested faster than that, even under concurrency
//
// **On every hop of a redirect, not only the first.** The wrapped fetcher must not follow
// redirects itself (`Net.singleHop`, the default); this does, one hop at a time, and each
// hop is a request like any other — its host's robots.txt, its host's interval.
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

    /// - Parameter base: what actually makes the requests. **It must hand redirects back
    ///   rather than follow them**, or every hop after the first escapes the rules above —
    ///   which is how a redirect into a disallowed path was fetched for as long as this
    ///   wrapped `Net.live`. A test double that never redirects is equally fine.
    public init(
        wrapping base: any HTTPFetching = Net.singleHop,
        userAgent: String = Net.userAgent,
        minInterval: TimeInterval = 1.0
    ) {
        self.base = base
        self.userAgent = userAgent
        self.minInterval = minInterval
    }

    /// A refused hop — a private address, a loop, one past `Net.maxRedirects` — is returned
    /// as the redirect it was. A hop robots.txt disallows throws exactly as a disallowed
    /// first URL does: it is the same request, merely reached by a different route.
    public func get(_ url: URL, etag: String?) async throws -> HTTPResponse {
        var current = url
        try await admit(current)
        var response = try await base.get(current, etag: etag)

        var visited: Set<String> = [current.absoluteString]
        for _ in 0..<Net.maxRedirects {
            guard let next = response.redirectTarget(from: current),
                  HostSafety.isPublic(url: next),
                  visited.insert(next.absoluteString).inserted
            else { break }
            current = next
            try await admit(current)
            response = try await base.get(current, etag: etag)
        }
        return response
    }

    /// The same budget and the same robots check, for the one source kind whose reads are
    /// spelled as writes.
    ///
    /// A JSON-RPC catalogue read is still a request against somebody's origin, so it queues
    /// behind everything else going to that host. robots.txt is consulted too, even though
    /// its `Disallow` rules are written for crawlers following links: a merchant who has
    /// disallowed a path has said something, and this is not the place to decide it did not
    /// apply to us. Only a 307 or 308 is followed, since only those promise the same method.
    public func post(_ url: URL, json body: Data, accept: String) async throws -> HTTPResponse {
        var current = url
        try await admit(current)
        var response = try await base.post(current, json: body, accept: accept)

        var visited: Set<String> = [current.absoluteString]
        for _ in 0..<Net.maxRedirects {
            guard let next = response.redirectTarget(from: current, keepsMethod: true),
                  HostSafety.isPublic(url: next),
                  visited.insert(next.absoluteString).inserted
            else { break }
            current = next
            try await admit(current)
            response = try await base.post(current, json: body, accept: accept)
        }
        return response
    }

    /// Everything one request has to clear before it may go: a public host, that host's
    /// robots.txt, and that host's next slot.
    private func admit(_ url: URL) async throws {
        guard let host = url.host() else {
            throw SourceError.badResponse(0)
        }
        // Before robots.txt, which is itself a request: a hop to a private address must not
        // even be asked for its rules.
        guard HostSafety.isPublic(host: host) else {
            throw SourceError.privateHost(host)
        }

        let rules = await robots(for: url, host: host)
        let path = Self.robotsPath(of: url)
        guard rules.allows(path: path) else {
            throw SourceError.disallowedByRobots(path)
        }

        try await waitForSlot(host: host, delay: max(minInterval, rules.crawlDelay ?? 0))
    }

    /// The path robots.txt rules are matched against.
    ///
    /// **Not `URL.path`, which drops a trailing slash** — `/gb/` comes back as `/gb` — so
    /// `Disallow: /gb/` could never match the very URL it names. victoriassecret.com
    /// disallows a directory per region in exactly that form and redirects European
    /// visitors into one of them. The percent-encoded path is also what RFC 9309 compares.
    static func robotsPath(of url: URL) -> String {
        let path = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath ?? url.path
        return path.isEmpty ? "/" : path
    }

    /// Fetches and caches robots.txt. A missing or broken file is treated as permissive:
    /// failing closed would silently drop brands for an unrelated reason.
    ///
    /// Its own redirects are followed — apex to `www.` is common — and the file found at the
    /// end is the one that applies, which is what RFC 9309 asks for. Each hop is spaced on
    /// its own host; there are no rules to check it against yet, which is the point of it.
    private func robots(for url: URL, host: String) async -> RobotsRules {
        if let cached = rules[host] { return cached }

        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.path = "/robots.txt"
        components?.query = nil

        var parsed = RobotsRules.permissive
        if var current = components?.url {
            // Counts against the host's budget like any other request.
            try? await waitForSlot(host: host, delay: minInterval)
            var response = try? await base.get(current, etag: nil)
            for _ in 0..<Net.maxRedirects {
                guard let next = response?.redirectTarget(from: current),
                      let nextHost = next.host(), HostSafety.isPublic(host: nextHost)
                else { break }
                current = next
                try? await waitForSlot(host: nextHost, delay: minInterval)
                response = try? await base.get(current, etag: nil)
            }
            if let response, response.status == 200 {
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

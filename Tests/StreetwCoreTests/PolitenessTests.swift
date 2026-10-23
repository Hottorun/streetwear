import Foundation
import Testing

@testable import StreetwCore

@Suite("robots.txt")
struct RobotsTests {
    /// The real file from a Shopify storefront: `Allow: /` alongside a long list of
    /// checkout/account disallows. Product data must stay reachable.
    private let shopify = """
    User-agent: *
    Disallow: /admin
    Disallow: /cart/
    Disallow: /checkout
    Disallow: /account
    Disallow: /collections/*sort_by*
    Disallow: /*/collections/*sort_by*
    Allow: /
    Allow: /products/account
    Sitemap: https://example.com/sitemap.xml
    """

    @Test("The endpoints we actually poll are allowed")
    func allowsCatalog() {
        let rules = RobotsRules.parse(shopify, userAgent: "streetw/1.0")
        #expect(rules.allows(path: "/products.json"))
        #expect(rules.allows(path: "/meta.json"))
        #expect(rules.allows(path: "/blogs/news.atom"))
        #expect(rules.allows(path: "/"))
    }

    @Test("Checkout and account paths are refused")
    func disallowsPrivate() {
        let rules = RobotsRules.parse(shopify, userAgent: "streetw/1.0")
        #expect(!rules.allows(path: "/admin"))
        #expect(!rules.allows(path: "/cart/"))
        #expect(!rules.allows(path: "/checkout"))
        #expect(!rules.allows(path: "/account"))
    }

    @Test("Wildcards inside a path are honoured")
    func wildcards() {
        let rules = RobotsRules.parse(shopify, userAgent: "streetw/1.0")
        #expect(!rules.allows(path: "/collections/all?sort_by=price"))
        #expect(!rules.allows(path: "/en/collections/new-sort_by-x"))
        #expect(rules.allows(path: "/collections/all"))
    }

    /// A longer Allow beats a shorter Disallow — the rule that keeps
    /// `/products/account` reachable despite `Disallow: /account`.
    @Test("Longest match wins")
    func longestMatchWins() {
        let rules = RobotsRules.parse(shopify, userAgent: "streetw/1.0")
        #expect(rules.allows(path: "/products/account"))
    }

    @Test("A named group beats the wildcard group")
    func specificGroupWins() {
        let text = """
        User-agent: *
        Disallow: /

        User-agent: streetw
        Disallow: /private
        Crawl-delay: 5
        """
        let mine = RobotsRules.parse(text, userAgent: "streetw/1.0")
        #expect(mine.allows(path: "/products.json"))
        #expect(!mine.allows(path: "/private"))
        #expect(mine.crawlDelay == 5)

        let others = RobotsRules.parse(text, userAgent: "SomeOtherBot/2")
        #expect(!others.allows(path: "/products.json"))
    }

    @Test("Consecutive user-agent lines share the following rules")
    func groupedAgents() {
        let text = """
        User-agent: streetw
        User-agent: otherbot
        Disallow: /nope
        """
        #expect(!RobotsRules.parse(text, userAgent: "streetw").allows(path: "/nope"))
        #expect(!RobotsRules.parse(text, userAgent: "otherbot").allows(path: "/nope"))
    }

    @Test("An empty Disallow means everything is allowed")
    func emptyDisallow() {
        let rules = RobotsRules.parse("User-agent: *\nDisallow:", userAgent: "streetw")
        #expect(rules.allows(path: "/anything"))
    }

    @Test("Comments and junk are ignored")
    func comments() {
        let rules = RobotsRules.parse(
            "# a comment\nUser-agent: *   # trailing\nDisallow: /x # why\nnonsense line",
            userAgent: "streetw"
        )
        #expect(!rules.allows(path: "/x"))
        #expect(rules.allows(path: "/y"))
    }

    @Test("A missing robots.txt is permissive, not a blocker")
    func permissiveByDefault() {
        #expect(RobotsRules.permissive.allows(path: "/anything"))
        #expect(RobotsRules.parse("", userAgent: "streetw").allows(path: "/anything"))
    }
}

@Suite("Politeness budget")
struct PoliteFetcherTests {
    /// Records the wall-clock time of each request so spacing can be asserted.
    private final class TimingClient: HTTPFetching, @unchecked Sendable {
        private let lock = NSLock()
        private(set) var times: [Date] = []
        private(set) var paths: [String] = []
        var robotsBody = "User-agent: *\nAllow: /"

        func get(_ url: URL, etag: String?) async throws -> HTTPResponse {
            lock.withLock {
                times.append(Date())
                paths.append(url.path)
            }
            if url.path == "/robots.txt" {
                return HTTPResponse(data: Data(robotsBody.utf8), status: 200, finalURL: url)
            }
            return HTTPResponse(data: Data("{}".utf8), status: 200, finalURL: url)
        }

        /// Recorded alongside the gets, because a JSON-RPC catalogue read spends the same
        /// per-host budget as any other request and the spacing tests must see it.
        func post(_ url: URL, json body: Data, accept: String) async throws -> HTTPResponse {
            lock.withLock {
                times.append(Date())
                paths.append(url.path)
            }
            return HTTPResponse(data: Data("{}".utf8), status: 200, finalURL: url)
        }
    }

    @Test("robots.txt is fetched once per host, then cached")
    func cachesRobots() async throws {
        let client = TimingClient()
        let polite = PoliteFetcher(wrapping: client, minInterval: 0)

        for _ in 0..<3 {
            _ = try await polite.get(URL(string: "https://example.com/products.json")!)
        }
        #expect(client.paths.filter { $0 == "/robots.txt" }.count == 1)
    }

    @Test("A disallowed path is refused before any request is made")
    func refusesDisallowed() async throws {
        let client = TimingClient()
        client.robotsBody = "User-agent: *\nDisallow: /products.json"
        let polite = PoliteFetcher(wrapping: client, minInterval: 0)

        await #expect(throws: SourceError.self) {
            _ = try await polite.get(URL(string: "https://example.com/products.json")!)
        }
        #expect(!client.paths.contains("/products.json"), "must not have been requested")
    }

    /// **The queue is bounded by depth, and that is what stops it being a weapon.**
    ///
    /// A slot is reserved before sleeping, so concurrent callers queue rather than all
    /// firing at once — deliberate and load-bearing. With no ceiling, a loop of interactive
    /// probes at one storefront booked its queue arbitrarily far ahead and the poller's own
    /// request queued behind every one of them. Being early is the whole product.
    @Test("The queue-depth rule refuses a deep queue and admits a shallow one")
    func queueDepthRule() {
        let delay = 2.0
        let horizon = delay * Double(PoliteFetcher.maxQueueDepth)

        // Ordinary sequential use: one caller ahead. Never refused.
        #expect(!PoliteFetcher.isQueueTooDeep(wait: delay, delay: delay))
        // A handful queued is still fine — that is what the reservation is for.
        #expect(!PoliteFetcher.isQueueTooDeep(wait: horizon, delay: delay))
        // Past the allowance, refused.
        #expect(PoliteFetcher.isQueueTooDeep(wait: horizon + 0.1, delay: delay))
        // The attack: a thousand probes at one host.
        #expect(PoliteFetcher.isQueueTooDeep(wait: 1000 * delay, delay: delay))
    }

    /// The rule scales with whatever politeness the host asked for, which is the whole
    /// reason it counts callers instead of seconds.
    @Test("A long Crawl-delay raises the allowance rather than breaking the host")
    func depthScalesWithDelay() {
        // 120s Crawl-delay: one queued caller is 120s out and must still be admitted. An
        // absolute one-minute horizon refused exactly this, which would have made a polite
        // site permanently unpollable.
        #expect(!PoliteFetcher.isQueueTooDeep(wait: 120, delay: 120))
        #expect(!PoliteFetcher.isQueueTooDeep(wait: 900, delay: 120))
        #expect(PoliteFetcher.isQueueTooDeep(wait: 2000, delay: 120))
    }

    /// With no spacing configured there is no queue, so nothing can be too deep.
    @Test("Zero delay never refuses")
    func zeroDelayAdmits() {
        #expect(!PoliteFetcher.isQueueTooDeep(wait: 9999, delay: 0))
    }

    /// The case an absolute horizon got wrong, kept as a test because it is the reason the
    /// rule is what it is: a host that asks for a long delay must still be fetchable.
    @Test("A host with a long Crawl-delay is still fetchable, one request after another")
    func longCrawlDelayStillWorks() async throws {
        let client = TimingClient()
        // Far larger than any constant a wall-clock horizon would have used.
        let polite = PoliteFetcher(wrapping: client, minInterval: 0.05)
        client.robotsBody = "User-agent: *\nAllow: /\nCrawl-delay: 0.05"

        // Sequential use is a queue of one and must never be refused, however wide the
        // interval — this is what the first version of the ceiling broke.
        for index in 0..<4 {
            _ = try await polite.get(URL(string: "https://example.com/s\(index).json")!)
        }
        #expect(client.paths.filter { $0.hasPrefix("/s") }.count == 4)
    }

    /// The guarantee that matters when many sources for one brand come due together.
    @Test("Concurrent requests to one host are spaced out")
    func spacesConcurrentRequests() async throws {
        let client = TimingClient()
        let interval = 0.25
        let polite = PoliteFetcher(wrapping: client, minInterval: interval)

        await withTaskGroup(of: Void.self) { group in
            for index in 0..<4 {
                group.addTask {
                    _ = try? await polite.get(URL(string: "https://example.com/p\(index).json")!)
                }
            }
        }

        let catalogTimes = zip(client.paths, client.times)
            .filter { $0.0 != "/robots.txt" }
            .map(\.1)
            .sorted()
        #expect(catalogTimes.count == 4)

        for (earlier, later) in zip(catalogTimes, catalogTimes.dropFirst()) {
            let gap = later.timeIntervalSince(earlier)
            #expect(gap >= interval * 0.8, "requests \(gap)s apart, expected >= \(interval)s")
        }
    }

    @Test("Crawl-delay overrides a shorter configured interval")
    func honoursCrawlDelay() async throws {
        let client = TimingClient()
        client.robotsBody = "User-agent: *\nAllow: /\nCrawl-delay: 0.4"
        let polite = PoliteFetcher(wrapping: client, minInterval: 0.05)

        _ = try await polite.get(URL(string: "https://example.com/a.json")!)
        let start = Date()
        _ = try await polite.get(URL(string: "https://example.com/b.json")!)

        #expect(Date().timeIntervalSince(start) >= 0.3)
    }

    /// Budgets are per-host, so two brands can be polled at once. Measured concurrently:
    /// sequentially each host pays its own robots fetch plus one interval, which would
    /// double the wall time if the budgets were shared.
    @Test("Different hosts do not block each other")
    func hostsAreIndependent() async throws {
        let client = TimingClient()
        let interval = 0.4
        let polite = PoliteFetcher(wrapping: client, minInterval: interval)

        let start = Date()
        await withTaskGroup(of: Void.self) { group in
            for host in ["a.example", "b.example", "c.example"] {
                group.addTask {
                    _ = try? await polite.get(URL(string: "https://\(host)/x.json")!)
                }
            }
        }
        let elapsed = Date().timeIntervalSince(start)

        // One host costs ~1 interval (robots now, request one slot later). Three hosts
        // sharing a budget would cost ~3x that.
        #expect(elapsed < interval * 2.5, "hosts appear to share a budget (\(elapsed)s)")
    }

    @Test("One host's budget still applies across separate calls")
    func sameHostIsThrottledAcrossCalls() async throws {
        let client = TimingClient()
        let polite = PoliteFetcher(wrapping: client, minInterval: 0.3)

        _ = try await polite.get(URL(string: "https://example.com/a.json")!)
        let start = Date()
        _ = try await polite.get(URL(string: "https://example.com/b.json")!)

        #expect(Date().timeIntervalSince(start) >= 0.2)
    }
}

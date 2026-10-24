import Foundation
import Testing

@testable import StreetwCore

/// A fetcher that hands redirects back, the way `Net.singleHop` does, so the politeness
/// layer above it is the one doing the following. Keyed by `host + path + query`, which is
/// the whole point here: most of these tests are about *which host* a hop landed on.
private final class RedirectingClient: HTTPFetching, @unchecked Sendable {
    struct Answer {
        var status: Int = 200
        var location: String?
        var body = ""
    }

    private let lock = NSLock()
    private var answers: [String: Answer] = [:]
    private(set) var requested: [String] = []
    private(set) var posts: [String] = []

    func on(_ url: String, _ answer: Answer) {
        lock.withLock { answers[url] = answer }
    }

    func redirect(_ url: String, to location: String, status: Int = 301) {
        on(url, Answer(status: status, location: location))
    }

    private func answer(for url: URL) -> Answer {
        // `URLComponents`, not `URL.path`: the latter drops a trailing slash, and `/gb/` versus
        // `/gb` is exactly the difference one of these tests is about.
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let key = url.host().map { host in
            host + (components?.percentEncodedPath ?? url.path) + (url.query.map { "?\($0)" } ?? "")
        } ?? url.absoluteString
        return lock.withLock {
            requested.append(key)
            // An unknown robots.txt is a 404, which is permissive — the common case.
            return answers[key] ?? Answer(status: 404)
        }
    }

    func get(_ url: URL, etag: String?) async throws -> HTTPResponse {
        let found = answer(for: url)
        return HTTPResponse(
            data: Data(found.body.utf8),
            status: found.status,
            finalURL: url,
            location: found.location
        )
    }

    func post(_ url: URL, json body: Data, accept: String) async throws -> HTTPResponse {
        lock.withLock { posts.append(url.host().map { $0 + url.path } ?? url.absoluteString) }
        return try await get(url, etag: nil)
    }
}

@Suite("Redirects go through the politeness rules")
struct RedirectTests {
    /// **Hollister, exactly.** `/products.json` answers a 301 to `/shop/FileNotFoundError`,
    /// and its own robots.txt — the real file, as fixture — disallows that path. Only the
    /// first URL used to be checked, and URLSession followed the rest unasked.
    @Test("A hop into a path robots.txt disallows is refused, and never requested")
    func refusesADisallowedHop() async throws {
        let http = RedirectingClient()
        http.on("www.hollisterco.com/robots.txt", .init(body: Fixtures.string("hollister_robots.txt")))
        http.redirect(
            "www.hollisterco.com/products.json?limit=250&page=1",
            to: "/shop/FileNotFoundError?catalogId=11558&storeId=19659&langId=-1005&DM_PersistentCookieCreated=true"
        )
        let polite = PoliteFetcher(wrapping: http, minInterval: 0)

        await #expect(throws: SourceError.disallowedByRobots("/shop/FileNotFoundError")) {
            _ = try await polite.get(URL(string: "https://www.hollisterco.com/products.json?limit=250&page=1")!)
        }
        #expect(!http.requested.contains { $0.contains("FileNotFoundError") })
    }

    /// victoriassecret.com sends a European visitor to `/gb/`, which its robots.txt
    /// disallows outright. Its homepage is a request discovery makes for the brand's name
    /// and logo.
    @Test("A geographic redirect into a disallowed region is refused")
    func refusesTheVictoriasSecretRedirect() async throws {
        let http = RedirectingClient()
        http.on("www.victoriassecret.com/robots.txt", .init(body: Fixtures.string("vs_robots.txt")))
        http.redirect("www.victoriassecret.com/", to: "https://www.victoriassecret.com/gb/", status: 302)
        let polite = PoliteFetcher(wrapping: http, minInterval: 0)

        await #expect(throws: SourceError.disallowedByRobots("/gb/")) {
            _ = try await polite.get(URL(string: "https://www.victoriassecret.com/")!)
        }
        #expect(!http.requested.contains("www.victoriassecret.com/gb/"))
    }

    /// A hop to another host answers to *that* host's robots.txt, and is the first request
    /// that host has seen — so its rules are read before anything else is asked of it.
    @Test("Each hop is checked against its own host's robots.txt")
    func readsTheNextHostsRules() async throws {
        let http = RedirectingClient()
        http.redirect("brand.com/sitemap.xml", to: "https://www.brand.com/sitemap.xml")
        http.on("www.brand.com/robots.txt", .init(body: "User-agent: *\nAllow: /"))
        http.on("www.brand.com/sitemap.xml", .init(body: "<urlset/>"))
        let polite = PoliteFetcher(wrapping: http, minInterval: 0)

        let response = try await polite.get(URL(string: "https://brand.com/sitemap.xml")!)

        #expect(response.status == 200)
        // The final URL is the hop that answered, so relative links and a `/password`
        // landing are read against the right page.
        #expect(response.finalURL?.absoluteString == "https://www.brand.com/sitemap.xml")
        #expect(http.requested == [
            "brand.com/robots.txt",
            "brand.com/sitemap.xml",
            "www.brand.com/robots.txt",
            "www.brand.com/sitemap.xml"
        ])
    }

    /// A Shopify store closed for a drop answers a 302 to `/password`. That landing is what
    /// `isLocked` reads, so it must still be reached and reported as the final URL.
    @Test("A redirect to the password page still reads as locked")
    func passwordRedirectIsALock() async throws {
        let http = RedirectingClient()
        http.redirect("shop.example/products.json", to: "/password", status: 302)
        http.on("shop.example/password", .init(body: "<html>Opening soon</html>"))
        let polite = PoliteFetcher(wrapping: http, minInterval: 0)

        let response = try await polite.get(URL(string: "https://shop.example/products.json")!)
        #expect(response.isLocked)
    }

    /// Spaced on the host, hop by hop — following a redirect is not a licence to fire the
    /// next request the instant the first returns.
    @Test("Hops on the same host wait their turn")
    func spacesHops() async throws {
        let http = RedirectingClient()
        http.redirect("example.com/a", to: "/b")
        http.on("example.com/b", .init(body: "ok"))
        let interval = 0.2
        let polite = PoliteFetcher(wrapping: http, minInterval: interval)

        let start = Date()
        _ = try await polite.get(URL(string: "https://example.com/a")!)

        // robots.txt, /a, /b — each one a slot after the last. Measured end to end rather
        // than gap by gap: a loaded machine can only make the whole thing slower, while a
        // single late timestamp can make one gap look short.
        #expect(http.requested == ["example.com/robots.txt", "example.com/a", "example.com/b"])
        #expect(Date().timeIntervalSince(start) >= interval * 2 * 0.9)
    }

    @Test("A redirect loop stops instead of going round")
    func stopsALoop() async throws {
        let http = RedirectingClient()
        http.redirect("example.com/a", to: "/b")
        http.redirect("example.com/b", to: "/a")
        let polite = PoliteFetcher(wrapping: http, minInterval: 0)

        let response = try await polite.get(URL(string: "https://example.com/a")!)

        #expect(response.status == 301)
        #expect(http.requested.filter { $0 != "example.com/robots.txt" } == ["example.com/a", "example.com/b"])
    }

    @Test("A chain longer than the limit ends at the limit")
    func boundsTheChain() async throws {
        let http = RedirectingClient()
        for step in 0..<20 {
            http.redirect("example.com/\(step)", to: "/\(step + 1)")
        }
        let polite = PoliteFetcher(wrapping: http, minInterval: 0)

        let response = try await polite.get(URL(string: "https://example.com/0")!)

        #expect(response.status == 301)
        let pages = http.requested.filter { $0 != "example.com/robots.txt" }
        #expect(pages.count == Net.maxRedirects + 1)
    }

    /// The check the session's delegate used to make, kept: a public host a stranger
    /// controls can answer with a redirect at the metadata endpoint. Neither the hop nor
    /// that address's robots.txt is requested.
    @Test("A redirect to a private address is handed back, not followed")
    func refusesAPrivateHop() async throws {
        let http = RedirectingClient()
        http.redirect("evil.example/", to: "http://169.254.169.254/latest/meta-data/", status: 302)
        let polite = PoliteFetcher(wrapping: http, minInterval: 0)

        let response = try await polite.get(URL(string: "https://evil.example/")!)

        #expect(response.status == 302)
        #expect(!http.requested.contains { $0.hasPrefix("169.254") })
    }

    /// Most URLs fetched now were never typed by anybody — a sitemap index names its
    /// children and robots.txt names its sitemaps — so the first URL is checked too.
    @Test("A private address is refused before any request is made")
    func refusesAPrivateFirstURL() async throws {
        let http = RedirectingClient()
        let polite = PoliteFetcher(wrapping: http, minInterval: 0)

        await #expect(throws: SourceError.privateHost("10.0.0.7")) {
            _ = try await polite.get(URL(string: "http://10.0.0.7/sitemap.xml")!)
        }
        #expect(http.requested.isEmpty)
    }

    /// robots.txt on the apex commonly redirects to `www.`, and the file at the end of
    /// that chain is the one that applies (RFC 9309).
    @Test("robots.txt's own redirect is followed and its rules apply")
    func followsTheRobotsRedirect() async throws {
        let http = RedirectingClient()
        http.redirect("brand.com/robots.txt", to: "https://www.brand.com/robots.txt")
        http.on("www.brand.com/robots.txt", .init(body: "User-agent: *\nDisallow: /private"))
        let polite = PoliteFetcher(wrapping: http, minInterval: 0)

        await #expect(throws: SourceError.disallowedByRobots("/private")) {
            _ = try await polite.get(URL(string: "https://brand.com/private")!)
        }
    }

    /// Only 307 and 308 promise the same method. A JSON-RPC call replayed as a GET
    /// somewhere a 302 pointed means nothing, so that is handed back as it came.
    @Test("A catalogue POST follows a 307 and not a 302")
    func postFollowsOnlyMethodPreservingRedirects() async throws {
        let http = RedirectingClient()
        http.redirect("shop.example/api/mcp", to: "https://www.shop.example/api/mcp", status: 307)
        http.on("www.shop.example/api/mcp", .init(body: "{}"))
        http.redirect("other.example/api/mcp", to: "/login", status: 302)
        let polite = PoliteFetcher(wrapping: http, minInterval: 0)

        let followed = try await polite.post(URL(string: "https://shop.example/api/mcp")!, json: Data("{}".utf8))
        #expect(followed.status == 200)
        #expect(http.posts == ["shop.example/api/mcp", "www.shop.example/api/mcp"])

        let refused = try await polite.post(URL(string: "https://other.example/api/mcp")!, json: Data("{}".utf8))
        #expect(refused.status == 302)
        #expect(!http.requested.contains("other.example/login"))
    }

    @Test("Location is resolved, and only web schemes are followed")
    func resolvesLocation() {
        let base = URL(string: "https://www.hollisterco.com/products.json?limit=250")!
        func target(_ location: String?, status: Int = 301) -> String? {
            HTTPResponse(data: Data(), status: status, location: location)
                .redirectTarget(from: base)?.absoluteString
        }
        #expect(target("/shop/FileNotFoundError?x=1") == "https://www.hollisterco.com/shop/FileNotFoundError?x=1")
        #expect(target("https://www.hollisterco.com/shop/us#top") == "https://www.hollisterco.com/shop/us")
        #expect(target("javascript:alert(1)") == nil)
        #expect(target(nil) == nil)
        // A 304 is in the 3xx range and is not a redirect.
        #expect(target("/elsewhere", status: 304) == nil)
    }
}

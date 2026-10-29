import Foundation
import Testing

@testable import StreetwCore

/// Telling a shop that refuses machines from one that publishes nothing — from the answers a
/// check's own requests got, with fixtures shaped like the real ones and no live traffic.
@Suite("Why a shop cannot be watched")
struct ShopRefusalTests {
    /// Akamai's block page as Bershka, Stradivarius, Pull&Bear and Chanel serve it — trimmed.
    static let akamai = """
    <HTML><HEAD>
    <TITLE>Access Denied</TITLE>
    </HEAD><BODY>
    <H1>Access Denied</H1>
    You don't have permission to access "http&#58;&#47;&#47;www&#46;bershka&#46;com&#47;robots&#46;txt" on this server.<P>
    Reference&#32;&#35;18&#46;5c3b1402&#46;1761561600&#46;2a7f3e1
    <P>https&#58;&#47;&#47;errors&#46;edgesuite&#46;net&#47;18&#46;5c3b1402&#46;1761561600&#46;2a7f3e1</P>
    </BODY>
    </HTML>
    """

    /// Cloudflare's block page, as lululemon.de answers its homepage and sitemap — trimmed.
    static let cloudflare = """
    <!DOCTYPE html><html lang="en-US"><head><title>Attention Required! | Cloudflare</title>
    <meta name="robots" content="noindex, nofollow" /></head><body>
    <div id="cf-wrapper"><h1>Sorry, you have been blocked</h1>
    <h2>You are unable to access lululemon.de</h2></div></body></html>
    """

    @Test("Akamai's and Cloudflare's block pages are challenges, not locks")
    func blockPagesAreChallenges() {
        for body in [Self.akamai, Self.cloudflare] {
            let response = HTTPResponse(data: Data(body.utf8), status: 403)
            #expect(response.isChallenged)
            #expect(!response.isLocked)
            #expect(ProbeOutcome(response) == .challenged)
        }
        // A bare 403 with nothing challenge-shaped about it is still a lock, as before.
        #expect(HTTPResponse(data: Data("Forbidden".utf8), status: 403).isLocked)
    }

    @Test("Every request refused by bot protection is a shop blocking readers")
    func allChallenged() {
        #expect(ShopRefusal.classify([.challenged, .challenged, .challenged]) == .blocksReaders)
    }

    @Test("A dropped connection on every request is a block too")
    func allDropped() {
        #expect(ShopRefusal.classify([.dropped, .dropped, .dropped, .dropped]) == .blocksReaders)
        #expect(ProbeOutcome(URLError(.networkConnectionLost)) == .dropped)
        #expect(ProbeOutcome(URLError(.timedOut)) == .dropped)
        #expect(ProbeOutcome(NSError(domain: NSPOSIXErrorDomain, code: 54)) == .dropped)
        #expect(ProbeOutcome(SourceError.blockedByEdge) == .challenged)
        #expect(ProbeOutcome(SourceError.disallowedByRobots("/")) == .disallowed)
    }

    @Test("One ordinary answer means the shop talks to us and publishes nothing")
    func oneAnswerIsNotABlock() {
        #expect(ShopRefusal.classify([.challenged, .answered(404), .challenged]) == .nothingAnswered)
        #expect(ShopRefusal.classify([.answered(404), .answered(404)]) == .nothingAnswered)
    }

    @Test("A name that does not resolve is absent, not blocking")
    func unreachableIsNotABlock() {
        #expect(ProbeOutcome(URLError(.cannotFindHost)) == .unreachable)
        #expect(ShopRefusal.classify([.unreachable, .unreachable]) == .nothingAnswered)
        #expect(ShopRefusal.classify([]) == .nothingAnswered)
        // Our own queue being full says nothing about the site, either way.
        #expect(ShopRefusal.classify([.busy, .challenged]) == .blocksReaders)
        #expect(ShopRefusal.classify([.busy]) == .nothingAnswered)
    }

    @Test("The curated list is matched on the registrable domain")
    func curated() {
        #expect(ShopRefusal.sellsNoClothes(host: "www.chanel.com"))
        #expect(ShopRefusal.sellsNoClothes(host: "chanel.com"))
        #expect(!ShopRefusal.sellsNoClothes(host: "kith.com"))
    }

    /// The whole of discovery run against a shop that answers every request with Akamai's page,
    /// robots.txt included: nothing is attached — not even a page watch read as a lock — and
    /// the log says why.
    @Test("Discovery over an Akamai wall attaches nothing and reads as blocked")
    func discoveryOverAWall() async {
        let wall = WallHTTP(status: 403, body: Self.akamai)
        let log = ProbeLog(wrapping: wall)
        let found = await BrandDiscovery.discover(website: "bershka.com", instagramHandle: nil, http: log)
        #expect(!found.canMonitor)
        #expect(!log.outcomes.isEmpty)
        #expect(ShopRefusal.classify(log.outcomes) == .blocksReaders)
    }

    @Test("Discovery over a site that drops every connection reads as blocked")
    func discoveryOverDroppedConnections() async {
        let log = ProbeLog(wrapping: WallHTTP(error: URLError(.networkConnectionLost)))
        let found = await BrandDiscovery.discover(website: "asos.com", instagramHandle: nil, http: log)
        #expect(!found.canMonitor)
        #expect(ShopRefusal.classify(log.outcomes) == .blocksReaders)
    }

    @Test("Discovery over a site with nothing on it is the generic refusal")
    func discoveryOverNothing() async {
        let log = ProbeLog(wrapping: WallHTTP(status: 404, body: "Not Found"))
        let found = await BrandDiscovery.discover(website: "example-nothing.com", instagramHandle: nil, http: log)
        #expect(!found.canMonitor)
        #expect(ShopRefusal.classify(log.outcomes) == .nothingAnswered)
    }

    @Test("A refusal reason decodes leniently and is absent from older servers")
    func wire() throws {
        let id = "6F9619FF-8B86-D011-B42D-00C04FC964FF"
        let old = Data(#"{"id":"\#(id)","status":"refused","isWatching":false}"#.utf8)
        #expect(try APICoding.decoder.decode(BrandCheck.self, from: old).refusal == nil)
        let new = Data(#"{"id":"\#(id)","status":"refused","isWatching":false,"refusal":"blocksReaders"}"#.utf8)
        #expect(try APICoding.decoder.decode(BrandCheck.self, from: new).refusal == .blocksReaders)
        let later = Data(#"{"id":"\#(id)","status":"refused","isWatching":false,"refusal":"closedForWinter"}"#.utf8)
        #expect(try APICoding.decoder.decode(BrandCheck.self, from: later).refusal == .nothingAnswered)
    }
}

/// Answers every request the same way — a wall.
private struct WallHTTP: HTTPFetching {
    var status = 200
    var body = ""
    var error: URLError?

    init(status: Int, body: String) {
        self.status = status
        self.body = body
    }

    init(error: URLError) {
        self.error = error
    }

    func get(_ url: URL, etag: String?) async throws -> HTTPResponse {
        if let error { throw error }
        return HTTPResponse(data: Data(body.utf8), status: status, finalURL: url)
    }

    func post(_ url: URL, json body: Data, accept: String) async throws -> HTTPResponse {
        try await get(url, etag: nil)
    }
}

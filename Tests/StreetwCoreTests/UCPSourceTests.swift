import Foundation
import Testing

@testable import StreetwCore

/// The storefront these are written against is Supreme, and the fixtures are the shapes it
/// actually publishes: the profile is its `/.well-known/ucp` with the endpoint and
/// capability list trimmed to what matters, and the search responses follow the UCP catalog
/// schema, one in each of the two envelopes the transport allows.
@Suite("UCP catalog")
struct UCPSourceTests {
    private let origin = URL(string: "https://us.supreme.com")!

    private func client() -> MockHTTPClient {
        let http = MockHTTPClient()
        http.stub("/.well-known/ucp", fixture: "ucp-profile.json")
        return http
    }

    private func source(_ http: MockHTTPClient) -> BrandSource {
        BrandSource(kind: .ucp, url: origin)
    }

    // MARK: - Discovery

    @Test("The MCP endpoint is read out of the storefront's own profile")
    func findsTheEndpoint() throws {
        let discovery = try #require(UCPSource.endpoint(inProfile: Fixtures.data("ucp-profile.json")))
        #expect(discovery.endpoint.absoluteString == "https://eu-production.myshopify.com/api/ucp/mcp")
    }

    /// The capability list is never consulted — it was wrong in both directions on one
    /// storefront in a single afternoon. A checkout-only profile is therefore not a refusal
    /// on its own; what settles it is whether the endpoint answers.
    @Test("Detection is settled by asking, not by the capability list")
    func probesRatherThanTrustingTheProfile() async {
        let checkoutOnly = """
        {"ucp":{"version":"2026-04-08",
          "services":{"dev.ucp.shopping":[{"transport":"mcp","endpoint":"https://x.example/api"}]},
          "capabilities":{"dev.ucp.shopping.checkout":[{"version":"2026-04-08"}]}}}
        """

        // It cannot answer: not a catalogue source, whatever the list said.
        let mute = MockHTTPClient()
        mute.stub("/.well-known/ucp", MockHTTPClient.Stub(body: Data(checkoutOnly.utf8)))
        mute.stubPost(MockHTTPClient.Stub(status: 500))
        #expect(await UCPSource.detect(at: origin, http: mute) == nil)

        // It answers — and an *empty* catalogue still counts, because that is what a
        // storefront between drops legitimately returns, and refusing it would drop the
        // brands whose next drop is the reason somebody is adding them.
        let answering = MockHTTPClient()
        answering.stub("/.well-known/ucp", MockHTTPClient.Stub(body: Data(checkoutOnly.utf8)))
        answering.stubPost(json: #"{"jsonrpc":"2.0","id":1,"result":{"structuredContent":{"products":[]}}}"#)
        #expect(await UCPSource.detect(at: origin, http: answering) == origin)
    }

    /// ...and a source that already exists is never dropped over a capability edit. The
    /// poll path does not consult the list at all.
    @Test("A capability list that stops mentioning the catalogue does not kill the source")
    func fetchIgnoresTheCapabilityList() async throws {
        let http = MockHTTPClient()
        http.stub("/.well-known/ucp", MockHTTPClient.Stub(body: Data("""
        {"ucp":{"version":"2026-04-08",
          "services":{"dev.ucp.shopping":[{"transport":"mcp","endpoint":"https://x.example/api"}]},
          "capabilities":{"dev.shopify.catalog":[{"version":"2026-04-08"}]}}}
        """.utf8)))
        http.stubPost(fixture: "ucp-search-page2.json")

        let result = try await UCPSource(http: http).fetch(source(http), since: nil)
        #expect(result.items.count == 1)
    }

    @Test("A transport we cannot speak is not adopted")
    func ignoresNonMCPTransports() {
        let json = """
        {"ucp":{"version":"2026-04-08",
          "services":{"dev.ucp.shopping":[{"transport":"rest","endpoint":"https://x.example/ucp/v1"}]},
          "capabilities":{"dev.ucp.shopping.catalog.search":[{"version":"2026-04-08"}]}}}
        """
        #expect(UCPSource.endpoint(inProfile: Data(json.utf8)) == nil)
    }

    @Test("Discovery attaches the storefront, not the endpoint")
    func detectStoresTheOrigin() async {
        let http = client()
        http.stubPost(fixture: "ucp-search-page1.json")
        // The origin is what a person recognises on a brand page, and the endpoint is
        // re-read every poll so a merchant can move it without stranding the brand.
        #expect(await UCPSource.detect(at: origin, http: http) == origin)
    }

    // MARK: - Reading a catalogue

    @Test("A product comes back with its price, sizes and stock")
    func readsProducts() async throws {
        let http = client()
        http.stubPost(fixture: "ucp-search-page1.json")
        http.stubPost(json: #"{"jsonrpc":"2.0","id":1,"result":{"structuredContent":{"products":[]}}}"#)

        let result = try await UCPSource(http: http).fetch(source(http), since: nil)
        let item = try #require(result.items.first)

        #expect(item.externalID == "ucp:gid://shopify/Product/8811223344")
        #expect(item.title == "Box Logo Hooded Sweatshirt")
        #expect(item.linkURL?.absoluteString == "https://eu.supreme.com/products/box-logo-hooded-sweatshirt")
        #expect(item.productType == "Sweatshirts")
        #expect(item.tags == ["fw26", "hooded"])
        // Videos are not photographs. A gallery that tries to draw an mp4 shows a hole.
        #expect(item.imageURLStrings == [
            "https://cdn.example.com/box-black.jpg",
            "https://cdn.example.com/box-ash.jpg"
        ])

        // The whole point of preferring this over a page watch: a real size run with real
        // stock in it.
        #expect(item.variants.map(\.size) == ["Medium", "Large"])
        #expect(item.variants.map(\.color) == ["Black", "Ash Grey"])
        #expect(item.variants.map(\.available) == [false, true])
        #expect(item.isAvailable == true)
        // ...and which photograph each colourway is, so selecting one moves the gallery.
        #expect(item.variants.map(\.imageIndex) == [0, 1])
    }

    /// `{"amount": 19800, "currency": "GBP"}` is £198.00. Reading the integer as an amount
    /// would put a £19,800 hoodie in the feed, and it would look like a scraping bug rather
    /// than a units bug.
    @Test("Prices arrive in minor units and are read as such")
    func convertsMinorUnits() {
        #expect(UCPSource.major(of: UCPPrice(amount: 19800, currency: "GBP")) == 198)
        #expect(UCPSource.major(of: UCPPrice(amount: 29900, currency: "USD")) == 299)
        // ...except where there are no minor units. A ¥29,900 jacket is not ¥299.
        #expect(UCPSource.major(of: UCPPrice(amount: 29900, currency: "JPY")) == 29_900)
    }

    /// The transport allows the payload as a structured object *or* as a JSON string inside
    /// a text block, and both are in the wild. Handling one silently loses every merchant
    /// that chose the other.
    @Test("The payload is read from either envelope")
    func readsBothEnvelopes() async throws {
        let http = client()
        http.stubPost(fixture: "ucp-search-page1.json")   // structuredContent
        http.stubPost(fixture: "ucp-search-page2.json")   // content[].text

        let result = try await UCPSource(http: http).fetch(source(http), since: nil)
        #expect(result.items.count == 2)
        #expect(result.items.last?.title == "Cordura Shoulder Bag")
    }

    @Test("Paging follows the cursor and stops when it runs out")
    func pagesWithTheCursor() async throws {
        let http = client()
        http.stubPost(fixture: "ucp-search-page1.json")
        http.stubPost(fixture: "ucp-search-page2.json")

        _ = try await UCPSource(http: http).fetch(source(http), since: nil)

        #expect(http.postedBodies.count == 2, "page two has no cursor, so there is no page three")
        #expect(!http.postedBodies[0].contains("cursor"))
        #expect(http.postedBodies[1].contains("eyJwYWdlIjoyfQ"))
    }

    /// A merchant that hands back the cursor it was given would otherwise re-read one page
    /// until the loop bound ran out, which looks like paging and is not.
    @Test("A repeated cursor ends the walk")
    func stopsOnARepeatedCursor() async throws {
        let http = client()
        let looping = #"{"jsonrpc":"2.0","id":1,"result":{"structuredContent":{"products":[{"id":"p1","title":"A"}],"pagination":{"cursor":"same"}}}}"#
        for _ in 0..<UCPSource.maxPages { http.stubPost(json: looping) }

        let result = try await UCPSource(http: http).fetch(source(http), since: nil)
        #expect(http.postedBodies.count == 2, "one page, then the repeat that ends it")
        #expect(result.items.count == 2)
    }

    /// Negotiation is the whole reason this is more than an HTTP call: without the agent
    /// profile in `meta`, every merchant answers `UCP discovery failed`.
    @Test("Every call names our agent profile")
    func alwaysSendsTheAgentProfile() async throws {
        let http = client()
        http.stubPost(fixture: "ucp-search-page2.json")

        _ = try await UCPSource(http: http).fetch(source(http), since: nil)
        let body = try #require(http.postedBodies.first)
        #expect(body.contains("ucp-agent"))
        #expect(body.contains(UCPAgent.profileURL.absoluteString))
    }

    /// Sold out is the state this app exists for. The endpoint narrows to sale-ready items
    /// by default, which would hide exactly the drop somebody wants telling about — and
    /// then the restock could never fire, because the product was never stored.
    @Test("Sold-out products are asked for, not filtered away")
    func asksForUnavailableStockToo() async throws {
        let http = client()
        http.stubPost(fixture: "ucp-search-page2.json")

        _ = try await UCPSource(http: http).fetch(source(http), since: nil)
        #expect(try #require(http.postedBodies.first).contains("\"available\":false"))
    }

    /// The refusal a first attempt actually gets, and the one whose fix is on our side —
    /// so it must not decay into a generic bad response alongside "the store is down".
    @Test("A refusal from the business is reported as one")
    func surfacesUCPErrors() async {
        let http = client()
        http.stubPost(json: """
        {"jsonrpc":"2.0","id":1,"error":{"code":-32001,"message":"UCP discovery failed"}}
        """)

        await #expect(throws: SourceError.ucp("UCP discovery failed")) {
            try await UCPSource(http: http).fetch(source(http), since: nil)
        }
    }

    /// `data` is not one shape and assuming it was cost the message twice. UCP's own
    /// refusals send an object; the transport's send a bare string — and decoding it as an
    /// object made the *whole envelope* undecodable, so a brand page reported "Nothing
    /// returned" about a server that had answered 200 with a precise explanation.
    ///
    /// Both payloads below are verbatim from Supreme, hours apart: the first when its
    /// endpoint could not resolve our profile, the second after it withdrew the catalogue
    /// tools altogether.
    @Test("The reason survives whichever shape `data` arrives in")
    func readsBothErrorDetailShapes() async {
        let structured = """
        {"jsonrpc":"2.0","id":1,"error":{"code":-32001,"message":"UCP discovery failed",
         "data":{"code":"version_unsupported","content":"Unable to fetch agent profile: Http error"}}}
        """
        let plain = """
        {"jsonrpc":"2.0","id":1,"error":{"code":-32602,"message":"Invalid params",
         "data":"Tool not found: search_catalog"}}
        """

        for (payload, expected) in [
            (structured, "UCP discovery failed — Unable to fetch agent profile: Http error"),
            (plain, "Invalid params — Tool not found: search_catalog")
        ] {
            let http = client()
            http.stubPost(json: payload)
            await #expect(throws: SourceError.ucp(expected)) {
                try await UCPSource(http: http).fetch(source(http), since: nil)
            }
        }
    }

    /// A storefront that withdraws the catalogue tools is no longer watchable this way, and
    /// discovery has to notice rather than attaching a source that errors on every poll.
    /// Supreme did exactly this, the same afternoon it was added.
    @Test("A store that has withdrawn the catalogue tools is not attached")
    func refusesAStoreThatLostItsTools() async {
        let http = client()
        http.stubPost(json: """
        {"jsonrpc":"2.0","id":1,"error":{"code":-32602,"message":"Invalid params",
         "data":"Tool not found: search_catalog"}}
        """)
        // The fixture profile advertises a catalogue, so `detect` would normally trust it;
        // this is the case where trusting it is wrong, and only the call can tell.
        #expect(await UCPSource.detect(at: origin, http: http) == nil)
    }

    /// Supreme's catalogue is genuinely empty between seasons. Reading that as a failure
    /// would back the source off out of the very window it needs to be polling in.
    @Test("An empty catalogue is an answer, not a failure")
    func emptyIsNotAnError() async throws {
        let http = client()
        http.stubPost(json: #"{"jsonrpc":"2.0","id":1,"result":{"structuredContent":{"products":[]}}}"#)

        let result = try await UCPSource(http: http).fetch(source(http), since: nil)
        #expect(result.items.isEmpty)
    }

    @Test("A storefront with no profile is not this adapter's problem")
    func notThisKindWithoutAProfile() async {
        let http = MockHTTPClient()   // no profile stubbed: 404
        await #expect(throws: SourceError.notThisKind) {
            try await UCPSource(http: http).fetch(source(http), since: nil)
        }
    }

    // MARK: - What we tell a merchant about ourselves

    /// streetw has no cart, cannot check out and holds no payment instrument. Declaring a
    /// capability it does not have is claiming to be a shop, and a business reads this to
    /// decide what it may send and what it may expect us to handle.
    @Test("The agent profile claims only what this app can actually do")
    func profileIsReadOnly() throws {
        let data = try UCPAgent.profileJSON()
        let root = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let ucp = try #require(root["ucp"] as? [String: Any])
        let capabilities = try #require(ucp["capabilities"] as? [String: Any])

        #expect(ucp["version"] as? String == UCPAgent.version)
        #expect(capabilities["dev.ucp.shopping.catalog.search"] != nil)
        #expect(capabilities["dev.ucp.shopping.checkout"] == nil)
        #expect(capabilities["dev.ucp.shopping.cart"] == nil)
        #expect(ucp["payment_handlers"] == nil)
    }

    /// The merchant fetches this URL from its own network, so it has to be absolute and
    /// public. A relative or localhost URI does not fail loudly — it fails as a 422 on
    /// every catalogue call, with nothing in the message to say why.
    @Test("The profile URI is absolute and served over HTTPS")
    func profileURLIsPublic() {
        let url = UCPAgent.profileURL
        #expect(url.scheme == "https")
        #expect(url.host() != nil)
        #expect(url.path == "/.well-known/ucp")
    }
}

@Suite("Watchability")
struct WatchabilityTests {
    private func sources(_ kinds: [BrandSource.Kind]) -> DiscoveredSources {
        var found = DiscoveredSources()
        found.sources = kinds.map { BrandSource(kind: $0, url: URL(string: "https://brand.com")!) }
        return found
    }

    /// **A page watch counts**, and this test exists because it briefly did not.
    ///
    /// The argument for excluding it was that "something changed" is too thin to be worth a
    /// brand row. Supreme disproves it: a page watch there fired on a real drop and reached
    /// its follower before the brand's own email. Being early is the entire product, and it
    /// is also the only source that detects a storefront locking down.
    @Test("A page watch is a real source")
    func pageWatchCounts() {
        #expect(sources([.page]).canMonitor)
        #expect(sources([.shopify, .page]).canMonitor)
    }

    /// What is refused is a site where nothing answered at all.
    @Test("Nothing readable means nothing to watch")
    func nothingReadableIsRefused() {
        #expect(!sources([]).canMonitor)
        // Instagram is a stored deep link and has never been automatic — on its own it is
        // not something the app can watch.
        #expect(!sources([.instagram]).canMonitor)
    }

    @Test("Every automatic source kind counts")
    func realSourcesCount() {
        for kind in [BrandSource.Kind.shopify, .collections, .feed, .sitemap, .ucp, .page] {
            #expect(sources([kind]).canMonitor, "\(kind.rawValue) should count")
        }
    }
}

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

    /// Shopify's own storefronts list the vendor-namespaced capability, and some list it
    /// *instead of* the standard one — Supreme's profile changed from one to the other
    /// within hours of this adapter being written, while its endpoint went on answering.
    @Test("Either catalogue capability counts as advertised")
    func acceptsEitherCapabilityName() throws {
        func profile(_ capability: String) -> Data {
            Data("""
            {"ucp":{"version":"2026-04-08",
              "services":{"dev.ucp.shopping":[{"transport":"mcp","endpoint":"https://x.example/api"}]},
              "capabilities":{"\(capability)":[{"version":"2026-04-08"}]}}}
            """.utf8)
        }
        for name in UCPSource.catalogCapabilities {
            let found = try #require(UCPSource.endpoint(inProfile: profile(name)))
            #expect(found.advertisesCatalog, "\(name) should count")
        }
        #expect(UCPSource.endpoint(inProfile: profile("dev.ucp.shopping.checkout"))?.advertisesCatalog == false)
    }

    /// A profile that mentions no catalogue is ambiguous, not a refusal: it might be a
    /// checkout-only store, or it might be a store that has simply stopped saying. Attaching
    /// the first would be the failure this adapter exists to remove — a source that reports
    /// healthy and never produces a drop — so `detect` asks rather than guesses.
    @Test("An unadvertised catalogue is settled by asking the endpoint")
    func probesWhenTheProfileIsSilent() async {
        let checkoutOnly = """
        {"ucp":{"version":"2026-04-08",
          "services":{"dev.ucp.shopping":[{"transport":"mcp","endpoint":"https://x.example/api"}]},
          "capabilities":{"dev.ucp.shopping.checkout":[{"version":"2026-04-08"}]}}}
        """

        // It cannot answer: not a catalogue source.
        let mute = MockHTTPClient()
        mute.stub("/.well-known/ucp", MockHTTPClient.Stub(body: Data(checkoutOnly.utf8)))
        mute.stubPost(MockHTTPClient.Stub(status: 500))
        #expect(await UCPSource.detect(at: origin, http: mute) == nil)

        // It answers — and an *empty* catalogue still counts, because that is what a
        // storefront between drops legitimately returns.
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

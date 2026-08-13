import Foundation
import Testing

@testable import StreetwCore

@Suite("Shopify catalog")
struct ShopifySourceTests {
    private func client(_ fixture: String, etag: String? = nil) -> MockHTTPClient {
        let http = MockHTTPClient()
        http.stub("/products.json?limit=250&page=1", fixture: fixture, etag: etag)
        http.stub("/meta.json", fixture: "shopify_meta.json")
        return http
    }

    @Test("Parses products with prices, images, tags and stock")
    func parsesProducts() async throws {
        let http = client("shopify_kith.json")
        let result = try await ShopifySource(http: http).fetch(.shopify(), since: nil)

        #expect(!result.items.isEmpty)
        let item = try #require(result.items.first)
        #expect(item.externalID.hasPrefix("shopify:"))
        #expect(!item.title.isEmpty)
        #expect(item.linkURL?.path.hasPrefix("/products/") == true)
        #expect(!item.variants.isEmpty)
        #expect(item.kind == .product)
    }

    @Test("Reads currency and display name from meta.json")
    func readsShopMeta() async throws {
        let http = client("shopify_kith.json")
        let result = try await ShopifySource(http: http).fetch(.shopify(), since: nil)

        #expect(result.shopCurrency == "USD")
        // The whole point: the real name, not a hostname guess.
        #expect(result.shopName == "Kith")
    }

    /// Kith ships `[Size]`; BBC ships `[Color, Size]`. The size axis is found by name,
    /// so its position can differ per brand.
    @Test("Extracts the size axis by name, not by position")
    func extractsSizeAxis() async throws {
        let kith = try await ShopifySource(http: client("shopify_kith.json"))
            .fetch(.shopify(), since: nil)
        let sized = kith.items.filter { $0.variants.contains { $0.size != nil } }
        #expect(!sized.isEmpty, "expected at least one product exposing a size axis")

        let bbc = try await ShopifySource(http: client("shopify_bbc.json"))
            .fetch(.shopify(), since: nil)
        let multiAxis = try #require(
            bbc.items.first { $0.variants.contains { $0.size != nil && $0.color != nil } }
        )
        let variant = try #require(multiAxis.variants.first { $0.size != nil })
        // Size must be the axis value, never the joined "COLOR / SIZE" title.
        #expect(!(variant.size ?? "").contains("/"))
        #expect(variant.title.contains(variant.size ?? "\u{0}"))
    }

    @Test("A 304 reports notModified rather than an empty catalog")
    func conditionalGet() async throws {
        let http = client("shopify_kith.json", etag: "W/\"abc123\"")
        var source = BrandSource.shopify()
        source.etag = "W/\"abc123\""

        let result = try await ShopifySource(http: http).fetch(source, since: nil)

        #expect(result.notModified)
        #expect(result.items.isEmpty)
        // Crucially it must not have walked further pages after the 304.
        #expect(http.requestedKeys == ["/products.json?limit=250&page=1"])
    }

    @Test("A locked storefront is reported as a signal, not an error")
    func lockedStorefront() async throws {
        let http = MockHTTPClient()
        http.setDefault(.init(status: 401))

        let result = try await ShopifySource(http: http).fetch(.shopify(), since: nil)

        #expect(result.isLocked)
        #expect(result.items.isEmpty)
    }

    @Test("Non-Shopify payloads are rejected rather than parsed into nothing")
    func rejectsNonShopify() async {
        let http = MockHTTPClient()
        http.stub("/products.json?limit=250&page=1", .init(body: Data("<html>nope</html>".utf8)))

        await #expect(throws: SourceError.self) {
            try await ShopifySource(http: http).fetch(.shopify(), since: nil)
        }
    }

    @Test("Stops paginating once a page ends older than the last sync")
    func stopsPaginatingWhenCaughtUp() async throws {
        // A full page (250) forces a pagination decision; every product is old, so the
        // adapter should decide one page is enough.
        let http = MockHTTPClient()
        http.stub("/meta.json", fixture: "shopify_meta.json")
        http.stub("/products.json?limit=250&page=1", .init(body: Self.page(count: 250, daysAgo: 30)))
        http.stub("/products.json?limit=250&page=2", .init(body: Self.page(count: 250, daysAgo: 60)))

        let result = try await ShopifySource(http: http)
            .fetch(.shopify(), since: Date().addingTimeInterval(-86_400))

        #expect(result.items.count == 250)
        #expect(!http.requestedKeys.contains("/products.json?limit=250&page=2"))
    }

    @Test("Keeps paginating while pages are newer than the last sync")
    func paginatesWhenBehind() async throws {
        let http = MockHTTPClient()
        http.stub("/meta.json", fixture: "shopify_meta.json")
        http.stub("/products.json?limit=250&page=1", .init(body: Self.page(count: 250, daysAgo: 1)))
        http.stub("/products.json?limit=250&page=2", .init(body: Self.page(count: 10, daysAgo: 2)))

        let result = try await ShopifySource(http: http)
            .fetch(.shopify(), since: Date().addingTimeInterval(-86_400 * 365))

        #expect(result.items.count == 260)
        #expect(http.requestedKeys.contains("/products.json?limit=250&page=2"))
    }

    /// Synthesises a catalog page whose products are all `daysAgo` old.
    private static func page(count: Int, daysAgo: Int) -> Data {
        let stamp = ISO8601DateFormatter().string(
            from: Date().addingTimeInterval(-86_400 * Double(daysAgo))
        )
        let products = (0..<count).map { index in
            """
            {"id": \(index + daysAgo * 100_000), "title": "Item \(index)", "handle": "item-\(index)",
             "published_at": "\(stamp)", "created_at": "\(stamp)",
             "options": [{"name": "Size", "position": 1}],
             "variants": [{"id": \(index), "title": "M", "option1": "M", "available": true, "price": "50.00"}],
             "images": []}
            """
        }
        return Data("{\"products\": [\(products.joined(separator: ","))]}".utf8)
    }
}

@Suite("Price and text helpers")
struct ShopifyHelperTests {
    @Test("Prices render in the shop's own currency")
    func formatsPrice() {
        #expect(ShopifySource.formatPrice("180.00", currency: "USD").contains("180"))
        #expect(ShopifySource.formatPrice("not a number", currency: "USD") == "not a number")
    }

    @Test("Descriptions are stripped to plain text")
    func stripsHTML() {
        let html = "<p>Cotton jersey<br></p>\n<p>Made in&nbsp;Japan &amp; dyed</p>"
        #expect(ShopifySource.plainText(from: html) == "Cotton jersey Made in Japan & dyed")
    }

    /// The shape Kith and most storefronts actually publish. Without a separator for
    /// `</li>` the whole spec arrives as one sentence, which is what the product page
    /// was printing.
    @Test("A bullet list keeps its boundaries")
    func separatesListItems() {
        let html = "<ul><li>Textile upper</li><li>Padded collar</li><li>Rubber outsole</li></ul>"
        #expect(
            ShopifySource.plainText(from: html)
                == "Textile upper · Padded collar · Rubber outsole"
        )
    }

    /// A trailing or empty item must not leave a separator pointing at nothing.
    @Test("Empty list items leave no dangling separator")
    func collapsesEmptyListItems() {
        let html = "<ul><li>Cotton</li><li></li><li>Made in Japan</li></ul><br/>"
        #expect(ShopifySource.plainText(from: html) == "Cotton · Made in Japan")
    }

    /// `&amp;` decodes last, or `&amp;lt;` would come out as a real tag delimiter.
    @Test("Entities decode without re-introducing markup")
    func decodesEntitiesSafely() {
        #expect(ShopifySource.plainText(from: "A &amp;lt;b&amp;gt; tag") == "A &lt;b&gt; tag")
        #expect(ShopifySource.plainText(from: "Don&#39;t &quot;quote&quot; me") == "Don't \"quote\" me")
    }

    @Test("Shopify timestamps parse with and without fractional seconds")
    func parsesDates() {
        #expect(DateParsing.iso8601("2026-08-09T11:00:01-04:00") != nil)
        #expect(DateParsing.iso8601("2026-08-09T11:00:01.123-04:00") != nil)
        #expect(DateParsing.any("Fri, 31 Jul 2026 22:00:00 +0000") != nil)
        #expect(DateParsing.any("nonsense") == nil)
    }
}

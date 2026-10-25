import Foundation
import Testing

@testable import StreetwCore

/// Reading the brand's own "was" price, and measuring a markdown from it.
@Suite("Markdowns")
struct MarkdownTests {
    /// Motel Rocks' "up to 50% off dresses" rail, served as it was: every variant carries
    /// `compare_at_price` as a decimal string beside its price.
    @Test("The list endpoint's compare-at price becomes the brand's original")
    func readsCompareAtFromTheList() async throws {
        let http = MockHTTPClient()
        http.stub("/products.json?limit=250&page=1", fixture: "shopify_motelrocks_sale.json")
        http.stub("/meta.json", .init(body: Data(#"{"name": "Motel Rocks", "currency": "USD"}"#.utf8)))

        let result = try await ShopifySource(http: http).fetch(.shopify(), since: nil)
        let sevila = try #require(result.items.first { $0.title.localizedCaseInsensitiveContains("sevila") })

        #expect(sevila.priceAmount == 40)
        #expect(sevila.originalPriceAmount == 80)
        #expect(sevila.originalPriceText == ShopifySource.formatPrice("80", currency: "USD"))
        // Every product on that rail is marked down by its own catalogue.
        #expect(result.items.allSatisfy { PriceChange.isDrop(from: $0.originalPriceAmount, to: $0.priceAmount) })
    }

    /// The fixtures recorded before this existed carry `compare_at_price: null` everywhere,
    /// which is what a full-price catalogue looks like.
    @Test("A product at full price has no original")
    func fullPriceHasNoOriginal() async throws {
        let http = MockHTTPClient()
        http.stub("/products.json?limit=250&page=1", fixture: "shopify_kith.json")
        http.stub("/meta.json", fixture: "shopify_meta.json")

        let result = try await ShopifySource(http: http).fetch(.shopify(), since: nil)
        #expect(!result.items.isEmpty)
        #expect(result.items.allSatisfy { $0.originalPriceAmount == nil && $0.originalPriceText == nil })
    }

    /// The single-product endpoint quotes prices in minor units, compare-at included —
    /// reading it as dollars would make a $69 dress "was $6,900".
    @Test("The product endpoint's compare-at is in minor units too")
    func readsCompareAtFromTheProductPage() async throws {
        let http = MockHTTPClient()
        http.stub("/products/tavita-frill-mini-dress-white.js", fixture: "shopify_motelrocks_product.js")
        http.stub("/meta.json", .init(body: Data(#"{"name": "Motel Rocks", "currency": "USD"}"#.utf8)))

        let item = try #require(await ShopifySource.product(
            at: URL(string: "https://us.motelrocks.com/products/tavita-frill-mini-dress-white")!,
            http: http
        ))
        // Read from `.js` itself, not from the listing it falls back to — which is not
        // stubbed here, and which a real payload always reached before its timestamp was
        // decoded as the string it is.
        #expect(item.publishedAt == DateParsing.iso8601("2024-02-19T01:52:02-05:00"))
        #expect(item.priceAmount == 35)
        #expect(item.originalPriceAmount == 69)
        #expect(PriceChange.percentOff(previous: nil, original: item.originalPriceAmount, now: item.priceAmount) == 49)
    }

    /// Storefronts leave compare-at equal to the price, below it, empty, or as a number
    /// where another sends a string. None of those is a markdown, and none may sink the
    /// catalogue — a page that fails to decode reads as "not a Shopify store".
    @Test("A compare-at that is not a real cut is ignored, whatever its shape")
    func lenientCompareAt() async throws {
        let http = MockHTTPClient()
        http.stub("/products.json?limit=250&page=1", .init(body: Data("""
        {"products": [
          {"id": 1, "title": "Same", "handle": "same", "published_at": "2026-08-01T10:00:00Z",
           "variants": [{"id": 11, "title": "M", "available": true, "price": "100.00", "compare_at_price": "100.00"}]},
          {"id": 2, "title": "Below", "handle": "below", "published_at": "2026-08-01T10:00:00Z",
           "variants": [{"id": 21, "title": "M", "available": true, "price": "100.00", "compare_at_price": "80.00"}]},
          {"id": 3, "title": "Empty", "handle": "empty", "published_at": "2026-08-01T10:00:00Z",
           "variants": [{"id": 31, "title": "M", "available": true, "price": "100.00", "compare_at_price": ""}]},
          {"id": 4, "title": "Number", "handle": "number", "published_at": "2026-08-01T10:00:00Z",
           "variants": [{"id": 41, "title": "M", "available": true, "price": "100.00", "compare_at_price": 140}]},
          {"id": 5, "title": "Rounding", "handle": "rounding", "published_at": "2026-08-01T10:00:00Z",
           "variants": [{"id": 51, "title": "M", "available": true, "price": "100.00", "compare_at_price": "102.00"}]}
        ]}
        """.utf8)))
        http.stub("/meta.json", fixture: "shopify_meta.json")

        let items = try await ShopifySource(http: http).fetch(.shopify(), since: nil).items
        let original = Dictionary(uniqueKeysWithValues: items.map { ($0.title, $0.originalPriceAmount) })
        #expect(items.count == 5)
        #expect(original["Same"] == .some(nil))
        #expect(original["Below"] == .some(nil))
        #expect(original["Empty"] == .some(nil))
        #expect(original["Number"] == 140)
        // Under the 5% a markdown has to clear: exchange-rate drift, not a sale.
        #expect(original["Rounding"] == .some(nil))
    }

    /// An S on sale and an XL at full price: the product reads as the S's price, so it
    /// must be measured against the S's tag, not the XL's.
    @Test("The original belongs to the variant the price was read from")
    func originalFollowsTheLowestVariant() {
        let mixed = ShopifySource.lowest([(price: 120, original: 180), (price: 180, original: nil)])
        #expect(mixed.min == 120)
        #expect(mixed.original == 180)

        // The cheaper variant has no tag of its own; a dearer variant's tag says nothing
        // about it.
        let unrelated = ShopifySource.lowest([(price: 150, original: nil), (price: 180, original: 240)])
        #expect(unrelated.min == 150)
        #expect(unrelated.original == nil)
    }

    /// 180, then 150 for a week, then 120: the last poll saw 150, the brand's tag says 180.
    @Test("A markdown is measured from the brand's original when it is the larger")
    func baseIsTheLargerRealCut() {
        #expect(PriceChange.base(previous: 150, original: 180, now: 120) == 180)
        #expect(PriceChange.percentOff(previous: 150, original: 180, now: 120) == 33)
        // No original published: the poll's price, as before.
        #expect(PriceChange.base(previous: 150, original: nil, now: 120) == 150)
        // An original that is not a cut to today's price is not a base.
        #expect(PriceChange.base(previous: 150, original: 119, now: 120) == 150)
        #expect(PriceChange.base(previous: nil, original: nil, now: 120) == nil)
    }

    private func reshelved(isAvailable: Bool, price: Double, original: Double?) -> FetchedItem {
        let published = Date()
        return FetchedItem(
            externalID: "shopify:1",
            title: "Sevila Dress",
            publishedAt: published,
            createdAt: published.addingTimeInterval(-400 * 86_400),
            kind: .product,
            priceAmount: price,
            originalPriceAmount: original,
            isAvailable: isAvailable
        )
    }

    /// Last season's stock moved onto the sale rail: it is a markdown, and until compare-at
    /// was read it could never have been one — there was no earlier poll to fall from.
    @Test("Old stock put back on the shelf marked down is a price drop")
    func reshelvedOnSaleIsAMarkdown() {
        #expect(Reshelving.firstSighting(of: reshelved(isAvailable: true, price: 40, original: 80)) == .priceDrop)
        // At full price it is the restock it always was.
        #expect(Reshelving.firstSighting(of: reshelved(isAvailable: true, price: 80, original: nil)) == .restock)
        // And with nothing to buy it says nothing, discounted or not.
        #expect(Reshelving.firstSighting(of: reshelved(isAvailable: false, price: 40, original: 80)) == nil)
    }

    /// A launch at an introductory price is still a launch — the louder news.
    @Test("A discounted launch keeps its kind")
    func discountedLaunchIsADrop() {
        let launch = FetchedItem(
            externalID: "shopify:2",
            title: "New Dress",
            publishedAt: Date(),
            createdAt: Date(),
            kind: .product,
            priceAmount: 40,
            originalPriceAmount: 60,
            isAvailable: true
        )
        #expect(Reshelving.firstSighting(of: launch) == .product)
    }
}

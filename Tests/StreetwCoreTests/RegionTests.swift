import Foundation
import Testing

@testable import StreetwCore

@Suite("Countries, currencies and how a price is written")
struct RegionTests {
    @Test("A country is two letters, and nothing a phone reports for 'unknown'")
    func countryCodes() {
        #expect(CountryCode.normalized("gb") == "GB")
        #expect(CountryCode.normalized(" DE\n") == "DE")
        #expect(CountryCode.normalized("GBR") == nil)
        #expect(CountryCode.normalized("") == nil)
        #expect(CountryCode.normalized("001") == nil, "a continent is not a shop's market")
        #expect(CountryCode.normalized("ZZ") == nil)
        #expect(CountryCode.normalized("XK") == nil)
        #expect(CountryCode.normalized(nil) == nil)
    }

    @Test("A currency is three letters, never a symbol")
    func currencyCodes() {
        #expect(CurrencyCode.normalized("gbp") == "GBP")
        #expect(CurrencyCode.normalized("£") == nil)
        #expect(CurrencyCode.normalized("EURO") == nil)
    }

    /// The point of formatting on the phone: a dollar sign means something different in
    /// Toronto, and the server's locale is not the reader's.
    @Test("A price is written in the reader's conventions, in the shop's currency")
    func writesForTheReader() {
        let us = Locale(identifier: "en_US")
        let canada = Locale(identifier: "en_CA")
        let britain = Locale(identifier: "en_GB")
        #expect(PriceFormat.text(amount: 180, currency: "USD", locale: us) == "$180")
        #expect(PriceFormat.text(amount: 180, currency: "USD", locale: canada) == "US$180")
        #expect(PriceFormat.text(amount: 180, currency: "GBP", locale: britain) == "£180")
        #expect(PriceFormat.text(amount: 180, currency: "GBP", locale: us) == "£180")
        // Whole units, as the stored text always was.
        #expect(PriceFormat.text(amount: 179.6, currency: "USD", locale: us) == "$180")
    }

    @Test("Without a currency nothing is formatted, and the stored text prints as it was")
    func fallsBackToTheStoredText() {
        #expect(PriceFormat.text(amount: 180, currency: nil) == nil)
        #expect(PriceFormat.text(amount: nil, currency: "USD") == nil)
        #expect(PriceFormat.display(text: "€180", amount: 180, currency: nil) == "€180")
        #expect(PriceFormat.display(text: "€180", amount: nil, currency: "EUR") == "€180")
        #expect(PriceFormat.display(text: nil, amount: nil, currency: nil) == nil)
        let us = Locale(identifier: "en_US")
        #expect(PriceFormat.display(text: "EUR 180", amount: 180, currency: "EUR", locale: us) == "€180")
    }

    @Test("Two numbers in two currencies are not a markdown")
    func noMarkdownAcrossCurrencies() {
        #expect(PriceChange.isDrop(from: 200, in: "USD", to: 150, in: "USD"))
        #expect(!PriceChange.isDrop(from: 200, in: "USD", to: 150, in: "GBP"))
        // A row from before currencies were stored compares as it always did.
        #expect(PriceChange.isDrop(from: 200, in: nil, to: 150, in: "GBP"))
    }
}

@Suite("Stored prices carry their currency")
struct PriceCurrencyTests {
    @Test("A Shopify product carries the shop's currency, and where it ships")
    func shopifyCarriesTheCurrency() async throws {
        let http = MockHTTPClient()
        http.stub("/products.json?limit=250&page=1", fixture: "shopify_kith.json")
        http.stub("/meta.json", fixture: "shopify_meta.json")
        let result = try await ShopifySource(http: http).fetch(.shopify(), since: nil)

        let item = try #require(result.items.first)
        #expect(item.currency == "USD")

        let shop = try #require(await ShopifySource.shopInfo(for: URL(string: "https://kith.com")!, http: http))
        #expect(shop.shipsTo.contains("GB"))
        #expect(shop.shipsTo.contains("US"))
    }

    /// The display text still falls back to dollars, as it always has — but a guess is not
    /// stored as a fact, so the phone prints that text rather than reformatting it.
    @Test("A shop that does not say its currency stores none")
    func unknownCurrencyIsNil() async throws {
        let http = MockHTTPClient()
        http.stub("/products.json?limit=250&page=1", fixture: "shopify_kith.json")
        let result = try await ShopifySource(http: http).fetch(.shopify(), since: nil)

        let item = try #require(result.items.first { $0.priceText != nil })
        #expect(item.currency == nil)
        #expect(item.priceText?.contains("$") == true)
        #expect(result.shopCurrency == nil)
    }

    @Test("A product page's offer currency is stored with its price")
    func productPageCarriesTheCurrency() throws {
        let base = URL(string: "https://www.hollisterco.com/shop/uk/p/hoodie")!
        let page = try #require(ProductPage.parse(Fixtures.string("hollister_product.html"), base: base))
        let item = page.applied(to: FetchedItem(externalID: "sitemap:x", title: "x", publishedAt: Date(), kind: .product))
        #expect(item.currency == "GBP")
    }

    @Test("A UCP product carries the currency its money names")
    func ucpCarriesTheCurrency() {
        let product = UCPProduct(
            id: "gid://shopify/Product/1",
            title: "Box Logo Hooded Sweatshirt",
            price_range: .init(min: UCPPrice(amount: 19800, currency: "gbp"))
        )
        let item = UCPSource.item(from: product, origin: URL(string: "https://eu.supreme.com")!, seenAt: Date())
        #expect(item?.currency == "GBP")
        #expect(item?.priceAmount == 198)
    }
}

@Suite("The region fields on the wire")
struct RegionWireTests {
    /// 1.0 and 1.1 decode what a new server sends, and a new client decodes what an old
    /// server sends — every field added here is optional.
    @Test("A feed row and a brand from an older server still decode")
    func olderPayloadsDecode() throws {
        let item = #"""
        {"eventID":"6F9619FF-8B86-D011-B42D-00C04FC964FF","kind":"product","createdAt":"2026-10-01T10:00:00Z",
         "brandID":"6F9619FF-8B86-D011-B42D-00C04FC964FE","brandName":"Kith","title":"Hoodie",
         "imageURLs":[],"priceText":"$180","restockedSizes":[],"availableInMySize":false}
        """#
        let decoded = try APICoding.decoder.decode(FeedItem.self, from: Data(item.utf8))
        #expect(decoded.currency == nil)
        #expect(decoded.priceText == "$180")

        let brand = #"{"name":"Kith","slug":"kith.com","currency":"USD","lockedForDrop":false,"sources":[]}"#
        let dto = try APICoding.decoder.decode(BrandDTO.self, from: Data(brand.utf8))
        #expect(dto.storefront == nil)
    }

    /// Absent and empty mean different things — "say nothing" and "back to the main shop" —
    /// so a body that does not mean to touch the country must not carry the key at all.
    @Test("An update that says nothing about the country sends no country")
    func absentCountryIsNotSent() throws {
        let quiet = try JSONSerialization.jsonObject(
            with: APICoding.encoder.encode(UpdateDevice(sizes: SizePayload(apparel: ["M"], shoe: [])))
        ) as? [String: Any]
        #expect(quiet?["country"] == nil)

        let cleared = try JSONSerialization.jsonObject(
            with: APICoding.encoder.encode(UpdateDevice(country: ""))
        ) as? [String: Any]
        #expect(cleared?["country"] as? String == "")
    }
}

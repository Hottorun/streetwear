import Foundation
import Testing

@testable import StreetwCore

/// The product details a page publishes for search engines, read once per new sitemap
/// product. The two fixtures are the real pages behind two of the sitemaps, trimmed to
/// their `<head>`.
@Suite("Product pages")
struct ProductPageTests {
    private let hollisterURL = URL(string: "https://www.hollisterco.com/shop/uk/p/hollister-feel-good-oversized-camo-graphic-hoodie-62515881-1005")!
    private let subduedURL = URL(string: "https://www.subdued.com/us_en/scoop-neck-top-cn01j79")!

    /// Hollister puts the sale price and the list price side by side in one offer's
    /// `priceSpecification`, and spells its SKU `"SKU"`. The list price is what it *was*.
    @Test("Hollister: the selling price, not the list price beside it")
    func readsHollister() throws {
        let page = try #require(ProductPage.parse(Fixtures.string("hollister_product.html"), base: hollisterURL))

        #expect(page.name == "Hollister Feel Good Oversized Butterfly Graphic Hoodie")
        #expect(page.price == 28.99)
        #expect(page.currency == "GBP")
        #expect(page.isAvailable == true)
        #expect(page.sku == "352-488-00381-112")
        #expect(page.imageURLs == ["https://img.hollisterco.com/is/image/anf/KIC_352-6035-00381-112_prod1?policy=product-medium"])
        #expect(page.summary?.hasPrefix("A hoodie in our signature soft fleece") == true)
        // One offer is the product's price and stock, not a size run.
        #expect(page.variants.isEmpty)
    }

    /// Subdued writes its offer's type as a full IRI and its price as a bare number.
    @Test("Subdued: an IRI-typed offer is still an offer")
    func readsSubdued() throws {
        let page = try #require(ProductPage.parse(Fixtures.string("subdued_product.html"), base: subduedURL))

        #expect(page.name == "Scoop neck top")
        #expect(page.price == 14)
        #expect(page.currency == "USD")
        #expect(page.isAvailable == true)
        #expect(page.sku == "CN01J79")
        #expect(page.color == "Multicolor")
    }

    /// The sitemap row becomes the page's product under the same identity, so the merge
    /// lands on the row the sitemap made.
    @Test("A page's facts are laid over the sitemap's row")
    func appliesToTheSitemapItem() throws {
        let page = try #require(ProductPage.parse(Fixtures.string("hollister_product.html"), base: hollisterURL))
        let fromSitemap = FetchedItem(
            externalID: "sitemap:https://www.hollisterco.com/shop/us/p/hollister-feel-good-oversized-camo-graphic-hoodie-62515881",
            title: "Hollister Feel Good Oversized Camo Graphic Hoodie",
            publishedAt: Date(),
            kind: .product
        )
        let item = page.applied(to: fromSitemap)

        #expect(item.externalID == fromSitemap.externalID)
        #expect(item.title == "Hollister Feel Good Oversized Butterfly Graphic Hoodie")
        #expect(item.priceAmount == 28.99)
        #expect(item.priceText?.contains("29") == true)
        #expect(item.isAvailable == true)
        #expect(item.imageURLStrings.count == 1)
    }

    /// Google's documented shape for a garment sold in sizes: a `ProductGroup` whose
    /// variants are products of their own, each with a size and an offer.
    @Test("A product group's variants are the size run")
    func readsAProductGroup() throws {
        let html = """
        <script type="application/ld+json">
        {"@context": "https://schema.org", "@type": "ProductGroup", "name": "Box Logo Hoodie",
         "productGroupID": "BLH", "variesBy": ["https://schema.org/size"],
         "hasVariant": [
           {"@type": "Product", "sku": "BLH-S", "size": "S", "color": "Black",
            "image": "https://cdn.example/blh-black.jpg",
            "offers": {"@type": "Offer", "price": 180, "priceCurrency": "EUR", "availability": "https://schema.org/InStock"}},
           {"@type": "Product", "sku": "BLH-M", "size": "M", "color": "Black",
            "offers": {"@type": "Offer", "price": 180, "priceCurrency": "EUR", "availability": "https://schema.org/OutOfStock"}},
           {"@type": "Product", "sku": "BLH-L", "size": "L", "color": "Black",
            "offers": {"@type": "Offer", "price": 150, "priceCurrency": "EUR", "availability": "https://schema.org/InStock"}}
         ]}
        </script>
        """
        let page = try #require(ProductPage.parse(html, base: URL(string: "https://brand.example/p/blh")!))

        #expect(page.variants.map(\.size) == ["S", "M", "L"])
        #expect(page.variants.map(\.available) == [true, false, true])
        #expect(page.variants.first?.id == "BLH-S")
        #expect(page.variants.first?.color == "Black")
        #expect(page.price == 150)
        #expect(page.currency == "EUR")
        #expect(page.isAvailable == true)
        // The group had no photograph of its own; its variants did.
        #expect(page.imageURLs == ["https://cdn.example/blh-black.jpg"])
    }

    /// The other shape: one product, one offer per size, the size in the offer's name.
    @Test("Offers that each name a size are the size run")
    func readsOffersPerSize() throws {
        let html = """
        <script type="application/ld+json">
        {"@type": "Product", "name": "Chore Coat", "offers": [
          {"@type": "Offer", "name": "S", "sku": "CC-S", "price": "229,95", "priceCurrency": "EUR", "availability": "InStock"},
          {"@type": "Offer", "name": "M", "sku": "CC-M", "price": "229,95", "priceCurrency": "EUR", "availability": "OutOfStock"}
        ]}
        </script>
        """
        let page = try #require(ProductPage.parse(html, base: URL(string: "https://brand.example/chore-coat")!))
        #expect(page.variants.map(\.size) == ["S", "M"])
        #expect(page.variants.map(\.available) == [true, false])
        #expect(page.price == 229.95)
    }

    /// Several offers that name nothing are several sellers or currencies of one thing.
    @Test("Offers with nothing to tell them apart are not sizes")
    func ignoresIndistinctOffers() throws {
        let html = """
        <script type="application/ld+json">
        {"@type": "Product", "name": "Tee", "offers": [
          {"@type": "Offer", "price": 40, "priceCurrency": "USD", "availability": "InStock"},
          {"@type": "Offer", "price": 38, "priceCurrency": "USD", "availability": "InStock"}
        ]}
        </script>
        """
        let page = try #require(ProductPage.parse(html, base: URL(string: "https://brand.example/tee")!))
        #expect(page.variants.isEmpty)
        #expect(page.price == 38)
    }

    /// Templates break their own JSON, most often with a raw newline in a description, and
    /// nest the product under `@graph`.
    @Test("A product under @graph, in JSON a template broke, is still found")
    func toleratesTemplates() throws {
        let html = """
        <script type="application/ld+json">
        {"@context": "https://schema.org", "@graph": [
          {"@type": "WebSite", "name": "Brand"},
          {"@type": ["Product", "Clothing"], "name": "Overshirt", "description": "Heavy
        cotton twill.", "offers": {"@type": "AggregateOffer", "lowPrice": "95.00", "highPrice": "120.00", "priceCurrency": "GBP"}}
        ]}
        </script>
        """
        let page = try #require(ProductPage.parse(html, base: URL(string: "https://brand.example/overshirt")!))
        #expect(page.name == "Overshirt")
        #expect(page.price == 95)
        #expect(page.isAvailable == nil, "nothing was said about stock")
    }

    /// Hollister's homepage declares `og:type` `product` and sells nothing at a price. For a
    /// URL only its page can confirm, that must read as not a product.
    @Test("A page with no product data is not a product, whatever og:type says")
    func refusesAPageThatIsNotAProduct() {
        #expect(ProductPage.parse(Fixtures.string("hollister_home.html"), base: URL(string: "https://www.hollisterco.com/shop/uk")!) == nil)
    }

    @Test("Open Graph stands in when it prints a price")
    func fallsBackToOpenGraph() throws {
        let html = """
        <meta property="og:title" content="Wool Beanie">
        <meta property="og:image" content="/img/beanie.jpg">
        <meta property="product:price:amount" content="35">
        <meta property="product:price:currency" content="EUR">
        """
        let page = try #require(ProductPage.parse(html, base: URL(string: "https://brand.example/beanie")!))
        #expect(page.name == "Wool Beanie")
        #expect(page.price == 35)
        #expect(page.imageURLs == ["https://brand.example/img/beanie.jpg"])
    }

    /// What the share sheet hands over: the JSON-LD blocks' raw text and the page's tags, read
    /// out of the page Safari loaded. Intimissimi's group carries the photographs, while each
    /// variant says `"image": "not_available"` — which is a word, not an address.
    @Test("A page read in the browser is the same product as a page fetched")
    func readsBlocksAndTagsFromTheShareSheet() throws {
        let base = URL(string: "https://www.intimissimi.com/de/product/kurzarm-t-shirt_aus_stretch-merinowolle-CMU17A.html?dwvar_CMU17A_Z_COL_INTU=279K")!
        let metadata = PageMetadataParser.parse(
            tags: ["og:image": "https://www.intimissimi.com/on/demandware.static/-/Sites-INT_EC_COM/default/dwb8a5b8df/images/CMU17A279K-F.jpeg", "og:type": "website"],
            title: "Kurzarm-T-Shirt aus Stretch-Merinowolle - T-Shirts - Herren | IUMAN Intimissimi Uomo",
            canonical: "https://www.intimissimi.com/de/product/kurzarm-t-shirt_aus_stretch-merinowolle-CMU17A.html",
            base: base
        )
        #expect(metadata.type == "website")
        #expect(metadata.canonicalURL?.query == nil)

        let page = try #require(ProductPage.parse(
            jsonLD: ["  ", Fixtures.string("intimissimi_product.jsonld")],
            metadata: metadata,
            base: base
        ))
        #expect(page.name == "Kurzarm-T-Shirt aus Stretch-Merinowolle")
        #expect(page.price == 42.9)
        #expect(page.currency == "EUR")
        #expect(page.isAvailable == true)
        #expect(page.imageURLs.count == 2)
        #expect(page.imageURLs.allSatisfy { $0.hasSuffix(".jpeg") })
        #expect(ProductPage.images("not_available", base: base).isEmpty)
    }

    @Test("Tags with no product data and no price are not a product")
    func tagsAloneAreNotAProduct() {
        let base = URL(string: "https://kith.com/")!
        let metadata = PageMetadataParser.parse(tags: ["og:type": "product", "og:title": "Kith"], title: "Kith", canonical: nil, base: base)
        #expect(ProductPage.parse(jsonLD: [], metadata: metadata, base: base) == nil)
    }

    @Test("Prices are read in either decimal convention")
    func readsPrices() {
        #expect(ProductPage.number("28.99") == 28.99)
        #expect(ProductPage.number(28.99) == 28.99)
        #expect(ProductPage.number("1,234.56") == 1234.56)
        #expect(ProductPage.number("29,95") == 29.95)
        #expect(ProductPage.number("€ 29,95") == 29.95)
        #expect(ProductPage.number("1.234,56") == 1234.56)
        #expect(ProductPage.number("free") == nil)
    }

    @Test("Reading a page says which of three things happened")
    func readsOutcomes() async {
        let http = MockHTTPClient()
        http.stub("/us_en/scoop-neck-top-cn01j79", fixture: "subdued_product.html")
        http.stub("/shop/uk", fixture: "hollister_home.html")

        if case .product(let page) = await ProductPage.read(subduedURL, http: http) {
            #expect(page.price == 14)
        } else {
            Issue.record("a product page should read as a product")
        }
        #expect(await ProductPage.read(URL(string: "https://www.hollisterco.com/shop/uk")!, http: http) == .notAProduct)
        #expect(await ProductPage.read(URL(string: "https://www.subdued.com/gone")!, http: http) == .unreachable(retryable: false))
    }

    /// Our own congestion is the one failure worth coming back for.
    @Test("A busy host is retried; anything else is not")
    func retriesOnlyABusyHost() async {
        struct Busy: HTTPFetching {
            func get(_ url: URL, etag: String?) async throws -> HTTPResponse {
                throw SourceError.hostBusy("shop.example", retryAfter: 10)
            }
            func post(_ url: URL, json body: Data, accept: String) async throws -> HTTPResponse {
                throw SourceError.hostBusy("shop.example", retryAfter: 10)
            }
        }
        #expect(await ProductPage.read(URL(string: "https://shop.example/p/1")!, http: Busy()) == .unreachable(retryable: true))
    }
}

import Foundation
import Testing

@testable import StreetwCore

/// What the share sheet decides before it offers anything: save this, or follow its shop.
@Suite("Page roles")
struct PageRoleTests {
    private func role(_ address: String, product: ProductPage? = nil, type: String? = nil, read: Bool = true) -> PageRole {
        var metadata = PageMetadata()
        metadata.type = type
        return PageRole.of(URL(string: address)!, product: product, metadata: read ? metadata : nil)
    }

    @Test("A homepage is a shop, whatever og:type says")
    func homepages() {
        #expect(role("https://kith.com/") == .shop)
        #expect(role("https://www.intimissimi.com/de/") == .shop)
        #expect(role("https://www.hollisterco.com/shop/uk", type: "product") == .shop)
        #expect(role("https://kith.com/en-us/index.html", read: false) == .shop)
        // Even with product data on it: a homepage's featured product is not what was shared.
        #expect(role("https://kith.com/", product: ProductPage(name: "Hoodie")) == .shop)
    }

    @Test("Product data makes a product")
    func products() {
        #expect(role("https://www.intimissimi.com/de/product/kurzarm-CMU17A.html", product: ProductPage(name: "T-Shirt")) == .product)
        #expect(role("https://kith.com/collections/mens/products/hoodie", product: ProductPage(name: "Hoodie")) == .product)
    }

    @Test("A collection is a shop")
    func collections() {
        #expect(role("https://kith.com/collections/mens-apparel") == .shop)
        #expect(role("https://kith.com/collections/mens-apparel", read: false) == .shop)
        #expect(role("https://www.intimissimi.com/de/herren/strickwaren/", type: "website") == .shop)
    }

    @Test("og:type product, or a product path, without data is still a product")
    func declaredProducts() {
        #expect(role("https://brand.example/item/123", type: "product") == .product)
        #expect(role("https://brand.example/products/hoodie", type: "website") == .product)
    }

    @Test("An address alone keeps the old behaviour: a save")
    func addressesAlone() {
        #expect(role("https://brand.example/journal/autumn-lookbook", read: false) == .product)
    }

    @Test("Locales are not pages")
    func locales() {
        #expect(PageRole.isLocale("de"))
        #expect(PageRole.isLocale("en-us"))
        #expect(PageRole.isLocale("en_GB".lowercased()))
        #expect(!PageRole.isLocale("mens"))
        #expect(!PageRole.isLocale("p"))
    }
}

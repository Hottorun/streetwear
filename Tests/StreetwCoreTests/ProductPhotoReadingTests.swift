import Foundation
import Testing

@testable import StreetwCore

@Suite("Style words and the product shot")
struct ProductPhotoReadingTests {
    @Test("Only the vocabulary, lowercased, once each, at most two")
    func clean() {
        #expect(StyleWords.clean(["Workwear", " goth ", "workwear", "Y2K", "minimal"]) == ["workwear", "y2k"])
        #expect(StyleWords.clean([]).isEmpty)
        // Every word is one token the grammar reads whole, or a search could never match it.
        for word in StyleWords.vocabulary {
            #expect(ShopText.tokens(word) == [word], "\(word)")
        }
    }

    @Test("An index past the gallery is no shot")
    func shotURL() {
        let photos = ["a", "b"]
        #expect(ProductShotIndex.url(in: photos, at: 1) == "b")
        #expect(ProductShotIndex.url(in: photos, at: 2) == nil)
        #expect(ProductShotIndex.url(in: photos, at: nil) == nil)
    }

    @Test("A style word is matched like a tag: it finds the garment, and does not outrank its name")
    func searched() {
        let jacket = ShopListing(id: "1", brandKey: "s", brandName: "Shop", title: "Canvas Jacket", styleWords: ["workwear"])
        let named = ShopListing(id: "2", brandKey: "s", brandName: "Shop", title: "Workwear Overshirt")
        let dress = ShopListing(id: "3", brandKey: "s", brandName: "Shop", title: "Silk Dress", styleWords: ["romantic"])
        let result = ShopSearch.run(ShopQuery.parse("workwear"), in: ShopIndex([jacket, named, dress]), hasSizes: false, fits: { _ in true })
        #expect(result.exact.map(\.listing.id) == ["2", "1"])
        #expect(result.unknown.isEmpty)
    }

    @Test("The reading is optional on the wire, and an older payload decodes without it")
    func wire() throws {
        let card = DiscoverCard(
            productExternalID: "shopify:1", brand: BrandDTO(id: UUID(), name: "Shop", slug: "shop.com"),
            title: "Canvas Jacket", publishedAt: Date(timeIntervalSince1970: 0)
        )
        var object = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(card)) as? [String: Any])
        #expect(object["productShotIndex"] == nil && object["styleWords"] == nil)
        object["productShotIndex"] = 2
        object["styleWords"] = ["workwear"]
        let decoded = try JSONDecoder().decode(DiscoverCard.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(decoded.productShotIndex == 2 && decoded.styleWords == ["workwear"])
    }
}

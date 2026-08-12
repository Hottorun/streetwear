import Foundation
import Testing

@testable import StreetwCore

/// Which photograph shows which colourway, and what a size is called.
///
/// The fixture is a trimmed YoungLA payload, chosen because it exercises both at once:
/// `[Color, Size]` axes with real `variant_ids` on the images, and a size run spelled out
/// in full — `XSmall, Small, Medium, Large, XLarge` — which is the form that used to fall
/// through the word table and leave half of every run unmatchable.
@Suite("Colourway photographs")
struct ColorwayImageTests {
    private func client() -> MockHTTPClient {
        let http = MockHTTPClient()
        http.stub("/products.json?limit=250&page=1", fixture: "shopify_youngla.json")
        http.stub("/meta.json", fixture: "shopify_meta.json")
        return http
    }

    private func firstItem() async throws -> FetchedItem {
        let result = try await ShopifySource(http: client()).fetch(.shopify(), since: nil)
        return try #require(result.items.first)
    }

    /// Shopify has always published the association and the adapter used to discard it, so
    /// selecting a colourway filtered the size run while the photograph stayed on whatever
    /// colour happened to be first. You tapped Aqua and went on looking at the black one.
    @Test("A variant knows which photograph shows it")
    func variantsCarryAnImageIndex() async throws {
        let item = try await firstItem()

        var byColour: [String: Int] = [:]
        for variant in item.variants {
            guard let colour = variant.color, let index = variant.imageIndex else { continue }
            byColour[colour] = index
        }

        // Two colourways, two different photographs — the whole point.
        #expect(byColour["Aqua"] == 6)
        #expect(byColour["Black"] == 3)
        #expect(byColour["Aqua"] != byColour["Black"])
    }

    /// An index into an array the app draws, so it has to be in range for that array.
    @Test("Every index points at a photograph that exists")
    func indicesAreInRange() async throws {
        let item = try await firstItem()
        for variant in item.variants {
            guard let index = variant.imageIndex else { continue }
            #expect(item.imageURLStrings.indices.contains(index))
        }
    }

    /// Most storefronts publish no association at all, and plenty put each colourway on
    /// its own product handle. Nil has to stay nil rather than defaulting to zero — a
    /// gallery that jumps to the first frame on every colourway tap looks deliberate and
    /// is wrong, where one that doesn't move is merely quiet.
    @Test("A storefront that says nothing yields no index")
    func absentAssociationStaysNil() async throws {
        let http = MockHTTPClient()
        http.stub("/products.json?limit=250&page=1", fixture: "shopify_bbc.json")
        http.stub("/meta.json", fixture: "shopify_meta.json")

        let result = try await ShopifySource(http: http).fetch(.shopify(), since: nil)
        let item = try #require(result.items.first)
        #expect(item.variants.allSatisfy { $0.imageIndex == nil })
    }

    /// The other half of the YoungLA fix, checked on the real payload rather than on the
    /// normaliser alone: the run has to arrive as apparel sizes, not as `.other`.
    @Test("A run spelled out in full normalises to apparel sizes")
    func spelledOutRunNormalises() async throws {
        let item = try await firstItem()
        let tokens = item.variants
            .compactMap(\.size)
            .compactMap { SizeNormalizer.normalize($0) }

        #expect(tokens.allSatisfy { $0.kind == .apparel })
        #expect(Set(tokens.map(\.token)).isSuperset(of: ["XS", "S", "M", "L", "XL"]))
    }
}

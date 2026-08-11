import Foundation
import Testing

@testable import StreetwCore

@Suite("Colourways")
struct ColorwayTests {
    private func variant(_ color: String, _ size: String, available: Bool) -> VariantInfo {
        VariantInfo(
            id: "\(color)-\(size)",
            title: "\(color) / \(size)",
            available: available,
            size: size,
            color: color
        )
    }

    @Test("Variants group by colour, preserving catalogue order")
    func groups() {
        let colorways = Colorways.from([
            variant("Black", "S", available: true),
            variant("Black", "M", available: false),
            variant("Sand", "S", available: true),
            variant("Sand", "M", available: true)
        ])

        #expect(colorways.map(\.name) == ["Black", "Sand"])
        #expect(colorways[0].availableSizes == ["S"])
        #expect(colorways[0].allSizes == ["S", "M"])
        #expect(colorways[0].isAvailable)
    }

    @Test("A colourway sold out in every size is still listed, marked unavailable")
    func soldOutColorwayIsKept() {
        let colorways = Colorways.from([
            variant("Black", "M", available: true),
            variant("Sand", "M", available: false)
        ])

        #expect(colorways.count == 2)
        #expect(colorways[1].name == "Sand")
        #expect(!colorways[1].isAvailable, "you still want to know it exists, and to watch it")
    }

    /// A single colourway is not information — a row showing one swatch is chrome. Most
    /// products have exactly one, so this is the common case rather than an edge.
    @Test("A product with one colour produces no colourway row")
    func singleColorIsNotAColorway() {
        #expect(Colorways.from([
            variant("Black", "S", available: true),
            variant("Black", "M", available: true)
        ]).isEmpty)
    }

    @Test("Products with no colour axis produce nothing")
    func noColorAxis() {
        let sizeOnly = [
            VariantInfo(id: "1", title: "S", available: true, size: "S"),
            VariantInfo(id: "2", title: "M", available: true, size: "M")
        ]
        #expect(Colorways.from(sizeOnly).isEmpty)
    }

    @Test("Shopify's placeholder colour is not a colourway")
    func ignoresDefaultTitle() {
        #expect(Colorways.from([
            VariantInfo(id: "1", title: "Default Title", available: true, color: "Default Title"),
            VariantInfo(id: "2", title: "Black", available: true, color: "Black")
        ]).isEmpty)
    }
}

@Suite("Colour swatches")
struct ColorSwatchTests {
    @Test("Common streetwear colours resolve", arguments: [
        "Black", "WHITE", "Navy", "Olive", "Cream", "Burgundy", "Sand"
    ])
    func resolves(name: String) {
        #expect(ColorSwatch.rgb(for: name) != nil)
    }

    /// Real adidas/BBC shape. The leading segment is the colour the garment mostly is.
    @Test("A multi-colour name resolves on its first segment")
    func multiColorName() {
        let swatch = ColorSwatch.rgb(for: "WHITE/OWHITE/CBROWN")
        #expect(swatch != nil)
        #expect(swatch?.isPale == true, "it should read as white, not as the brown at the end")
    }

    /// Longest-first ordering: "off white" must not resolve on the "white" inside it, and
    /// a qualifier must not beat the colour it qualifies.
    @Test("A qualified colour resolves to the right entry")
    func qualifiedNames() {
        #expect(ColorSwatch.rgb(for: "Vintage Black") == ColorSwatch.rgb(for: "Black"))
        #expect(ColorSwatch.rgb(for: "Off White") != ColorSwatch.rgb(for: "White"))
    }

    /// Brands name colourways things that are not colours. Inventing a swatch would
    /// assert a colour the garment may not be, so callers get nil and print the name.
    @Test("An unrecognisable colourway yields no swatch rather than a wrong one")
    func unknownYieldsNil() {
        #expect(ColorSwatch.rgb(for: "Nocturne") == nil)
        #expect(ColorSwatch.rgb(for: "Chapter 3") == nil)
    }
}

@Suite("Image renditions")
struct ImageRenditionTests {
    private let shopify = URL(string: "https://cdn.shopify.com/s/files/1/0234/files/tee.jpg?v=1712")!

    @Test("A Shopify image is asked for at a snapped ladder width")
    func addsWidth() {
        let sized = ImageRendition.sized(shopify, width: 120, scale: 3)
        let query = URLComponents(url: sized, resolvingAgainstBaseURL: false)?.queryItems ?? []

        #expect(query.contains { $0.name == "width" && $0.value == "400" })
    }

    /// Dropping `v=` can serve a stale rendition of a photograph the brand has replaced.
    @Test("The cache-busting version parameter survives")
    func keepsVersion() {
        let query = URLComponents(url: ImageRendition.sized(shopify, width: 120), resolvingAgainstBaseURL: false)?
            .queryItems ?? []
        #expect(query.contains { $0.name == "v" && $0.value == "1712" })
    }

    /// A continuous width mints a distinct URL per layout, so a 118pt tile and a 121pt
    /// tile each miss the other's cache entry and refetch the same photograph.
    @Test("Nearby widths snap to the same URL so the cache is shared")
    func snapsToLadder() {
        #expect(ImageRendition.sized(shopify, width: 118) == ImageRendition.sized(shopify, width: 121))
        #expect(ImageRendition.snapped(390) == 400)
        #expect(ImageRendition.snapped(400) == 400)
        #expect(ImageRendition.snapped(401) == 600)
    }

    @Test("An existing width is replaced, not duplicated")
    func replacesExistingWidth() {
        let already = URL(string: "https://cdn.shopify.com/s/files/tee.jpg?width=32&v=1")!
        let query = URLComponents(url: ImageRendition.sized(already, width: 400), resolvingAgainstBaseURL: false)?
            .queryItems ?? []

        #expect(query.count { $0.name == "width" } == 1)
        #expect(query.first { $0.name == "width" }?.value != "32")
    }

    /// The safe default. A resize parameter an unknown CDN doesn't understand is at best
    /// ignored and at worst a 404, and a missing photograph is worse than a large one.
    @Test("A CDN we don't recognise is left completely alone", arguments: [
        "https://images.example.com/tee.jpg",
        "https://brand.com/media/catalog/product/tee.jpg?v=2"
    ])
    func leavesUnknownHostsAlone(raw: String) {
        let url = URL(string: raw)!
        #expect(ImageRendition.sized(url, width: 400) == url)
    }

    @Test("A shop's own domain serving under /cdn/shop/ is recognised")
    func recognisesShopDomain() {
        let url = URL(string: "https://kith.com/cdn/shop/files/tee.jpg?v=9")!
        #expect(ImageRendition.sized(url, width: 120) != url)
    }
}

import Foundation
import Testing

@testable import StreetwCore

@Suite("Preview images")
struct PreviewImagesTests {
    /// The one that shipped: a delivery-truck graphic captioned "Worry-Free Purchase", as
    /// the first and only impression of a fashion brand.
    @Test(
        "Policy and service rows are not garments",
        arguments: [
            "Worry-Free Purchase",
            "Worry Free Purchase",
            "Gift Card",
            "E-Gift Card",
            "Size Guide",
            "Express Shipping",
            "Returns Policy",
            "Coming Soon",
            "Klarna"
        ]
    )
    func rejectsNonGarments(title: String) {
        #expect(!PreviewImages.isGarment(title: title))
    }

    /// The list must not eat real clothes. Whole-token matching is what protects these —
    /// a `contains` check on "gift" takes the first one and "case" takes the second.
    @Test(
        "Real products survive",
        arguments: [
            "Gifted Hoodie",
            "Leather Card Case",
            "Delivery Driver Jacket",
            "Cargo Pant Black",
            "Nike Air Force 1 '07",
            "Policy Tee"
        ]
    )
    func keepsGarments(title: String) {
        #expect(PreviewImages.isGarment(title: title))
    }

    /// Some storefronts name the file and not the product.
    @Test("A telling file name is caught too")
    func readsTheFileName() {
        #expect(!PreviewImages.isGarment(
            title: "Untitled",
            imageURL: "https://cdn.shopify.com/s/files/1/x/size_chart_1024x.png?v=17"
        ))
        #expect(PreviewImages.isGarment(
            title: "Untitled",
            imageURL: "https://cdn.shopify.com/s/files/1/x/hoodie_black_1024x.jpg?v=17"
        ))
    }

    @Test("Picks garments in order, up to the limit")
    func picksInOrder() {
        let rows: [(title: String, imageURL: String?)] = [
            ("Worry-Free Purchase", "a.png"),
            ("Cargo Pant", "b.png"),
            ("Gift Card", "c.png"),
            ("Hoodie", "d.png"),
            ("Tee", nil)
        ]
        #expect(PreviewImages.pick(from: rows, limit: 5) == ["b.png", "d.png"])
        #expect(PreviewImages.pick(from: rows, limit: 1) == ["b.png"])
    }

    /// A brand whose whole recent catalogue reads as promotional is more likely one this
    /// vocabulary has misjudged than one with nothing to show.
    @Test("Never returns nothing when there was something")
    func fallsBackRatherThanEmptying() {
        let rows: [(title: String, imageURL: String?)] = [
            ("Gift Card", "a.png"),
            ("Size Guide", "b.png")
        ]
        #expect(PreviewImages.pick(from: rows, limit: 3) == ["a.png", "b.png"])
    }
}

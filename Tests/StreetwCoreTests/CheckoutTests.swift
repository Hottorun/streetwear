import Foundation
import Testing

@testable import StreetwCore

@Suite("Checkout links")
struct CheckoutTests {
    private let page = URL(string: "https://kith.com/products/nylon-maverick-pant")!

    private func variant(
        _ id: String,
        size: String?,
        color: String? = nil,
        available: Bool = true
    ) -> VariantInfo {
        let title = [color, size].compactMap { $0 }.joined(separator: " / ")
        return VariantInfo(
            id: id,
            title: title.isEmpty ? "Default Title" : title,
            available: available,
            size: size,
            color: color
        )
    }

    private func profile(apparel: Set<String> = [], shoe: Set<String> = []) -> SizeProfile {
        var profile = SizeProfile()
        profile.apparel = apparel
        profile.shoe = shoe
        return profile
    }

    private var run: [VariantInfo] {
        [
            variant("101", size: "S"),
            variant("102", size: "M"),
            variant("103", size: "L"),
            variant("104", size: "XL", available: false)
        ]
    }

    @Test("Exactly one available variant in your size goes straight to checkout")
    func uniqueSizeIsACartPermalink() {
        let link = Checkout.link(
            to: page, productExternalID: "shopify:9001",
            variants: run, profile: profile(apparel: ["M"])
        )
        #expect(link.action == .checkout)
        #expect(link.url.absoluteString == "https://kith.com/cart/102:1")
        #expect(link.variantID == "102")
        #expect(link.size == "M")
    }

    /// The permalink stays on the storefront the reader was looking at. A regional
    /// subdomain is a different shop with a different currency.
    @Test("The checkout is on the product's own host")
    func keepsTheRegionalHost() {
        let regional = URL(string: "https://usa.palaceskateboards.com/products/tri-ferg-hood")!
        let link = Checkout.link(
            to: regional, productExternalID: "shopify:1",
            variants: run, profile: profile(apparel: ["L"])
        )
        #expect(link.url.absoluteString == "https://usa.palaceskateboards.com/cart/103:1")
    }

    @Test("A checkout is always https, whatever the catalogue linked")
    func checkoutIsHTTPS() {
        let plain = URL(string: "http://kith.com/products/nylon-maverick-pant")!
        let link = Checkout.link(
            to: plain, productExternalID: "shopify:1",
            variants: run, profile: profile(apparel: ["S"])
        )
        #expect(link.url.scheme == "https")
    }

    /// Two of yours in stock is a choice, and the shop's page is where it is made — the app
    /// picking one for you is the wrong-size failure this whole file exists to avoid.
    @Test("Two of your sizes in stock opens the page, naming neither")
    func ambiguousSizesOpenThePage() {
        let link = Checkout.link(
            to: page, productExternalID: "shopify:1",
            variants: run, profile: profile(apparel: ["M", "L"])
        )
        #expect(link.action == .productPage)
        #expect(link.url == page)
        #expect(link.variantID == nil)
        #expect(link.size == nil)
    }

    @Test("One of your two sizes sold out leaves the other to check out")
    func soldOutSiblingDoesNotBlock() {
        let link = Checkout.link(
            to: page, productExternalID: "shopify:1",
            variants: run, profile: profile(apparel: ["M", "XL"])
        )
        #expect(link.action == .checkout)
        #expect(link.variantID == "102")
    }

    /// The page opened on it is the shop saying "sold out in your size" — more use than a
    /// size menu that starts at XS.
    @Test("Your only size sold out opens the page with it selected")
    func soldOutSizeIsPreselected() {
        let link = Checkout.link(
            to: page, productExternalID: "shopify:1",
            variants: run, profile: profile(apparel: ["XL"])
        )
        #expect(link.action == .productPage)
        #expect(link.url.absoluteString == "https://kith.com/products/nylon-maverick-pant?variant=104")
        #expect(link.size == "XL")
    }

    /// No profile is "we don't know your size", never "every size is yours". This is
    /// `claims`, not `matches`, and the difference is somebody's money.
    @Test("With no size profile nothing goes in the checkout")
    func noProfileNoCheckout() {
        let link = Checkout.link(
            to: page, productExternalID: "shopify:1",
            variants: run, profile: SizeProfile()
        )
        #expect(link.action == .productPage)
        #expect(link.url == page)
    }

    /// A bare 44 is as likely an EU shoe as an EU jacket or a waist. `matches` lets it
    /// through so it is never hidden; a checkout must not.
    @Test("A size we cannot read is not yours")
    func unreadableSizeIsNotClaimed() {
        let odd = [variant("201", size: "44"), variant("202", size: "46")]
        let link = Checkout.link(
            to: page, productExternalID: "shopify:1",
            variants: odd, profile: profile(apparel: ["M"], shoe: ["9"])
        )
        #expect(link.action == .productPage)
        #expect(link.variantID == nil)
    }

    @Test("Shoe sizes go through the same strict matching")
    func shoeSizes() {
        let shoes = [
            variant("301", size: "9"), variant("302", size: "9.5"), variant("303", size: "10")
        ]
        let link = Checkout.link(
            to: page, productExternalID: "shopify:1",
            variants: shoes, profile: profile(shoe: ["9.5"])
        )
        #expect(link.url.absoluteString == "https://kith.com/cart/302:1")
        #expect(link.size == "9.5")
    }

    /// "My size" in black and "my size" in sand are two different things in a checkout.
    @Test("The colourway chosen on the page narrows the choice")
    func colourwayNarrows() {
        let both = [
            variant("401", size: "M", color: "Black"),
            variant("402", size: "M", color: "Sand"),
            variant("403", size: "L", color: "Black")
        ]
        let unchosen = Checkout.link(
            to: page, productExternalID: "shopify:1",
            variants: both, profile: profile(apparel: ["M"])
        )
        #expect(unchosen.action == .productPage)

        let sand = Checkout.link(
            to: page, productExternalID: "shopify:1",
            variants: both, profile: profile(apparel: ["M"]), colorway: "sand"
        )
        #expect(sand.url.absoluteString == "https://kith.com/cart/402:1")
    }

    @Test("A product with nothing to choose checks out without naming a size")
    func oneVariantNoSize() {
        let cap = [variant("501", size: nil)]
        let link = Checkout.link(
            to: page, productExternalID: "shopify:1",
            variants: cap, profile: SizeProfile()
        )
        #expect(link.action == .checkout)
        #expect(link.url.absoluteString == "https://kith.com/cart/501:1")
        #expect(link.size == nil)
    }

    @Test("A one-size token is not a size choice either")
    func oneSizeToken() {
        let beanie = [variant("601", size: "OS")]
        let link = Checkout.link(
            to: page, productExternalID: "shopify:1",
            variants: beanie, profile: profile(apparel: ["M"])
        )
        #expect(link.action == .checkout)
        #expect(link.size == nil)
    }

    /// A colour-only product has no Size axis, so each variant's title is just its colour.
    /// Once the colour is chosen there is exactly one thing to buy; before, there are three.
    @Test("A colour-only product checks out once a colour is chosen")
    func colourOnlyProduct() {
        let bag = ["Black", "Olive", "Navy"].enumerated().map { index, colour in
            VariantInfo(id: "70\(index)", title: colour, available: true, color: colour)
        }
        let unchosen = Checkout.link(
            to: page, productExternalID: "shopify:1", variants: bag, profile: SizeProfile()
        )
        #expect(unchosen.action == .productPage)

        let olive = Checkout.link(
            to: page, productExternalID: "shopify:1",
            variants: bag, profile: SizeProfile(), colorway: "Olive"
        )
        #expect(olive.url.absoluteString == "https://kith.com/cart/701:1")
        #expect(olive.size == nil)
    }

    /// No convention for a non-Shopify platform is reliable enough to guess, so the exact
    /// product page is the answer — with nothing appended to it.
    @Test("Anything but Shopify gets the product page untouched")
    func otherPlatforms() {
        for key in ["ucp:gid://shopify/Product/1", "sitemap:https://x.com/p/1", "feed:abc", nil] {
            let link = Checkout.link(
                to: page, productExternalID: key,
                variants: run, profile: profile(apparel: ["M"])
            )
            #expect(link.action == .productPage)
            #expect(link.url == page)
            #expect(link.variantID == nil)
        }
    }

    /// Only a numeric id may be spliced into the path. `ShopifySource` writes "0" for a
    /// variant the payload sent without an id, which would be a permalink to nothing.
    @Test("A variant id that is not a Shopify id is never put in a URL")
    func variantIDsAreValidated() {
        let hostile = [
            variant("0", size: "M"),
            variant("102/../../admin", size: "M"),
            variant("gid://shopify/ProductVariant/7", size: "M")
        ]
        for one in hostile {
            let link = Checkout.link(
                to: page, productExternalID: "shopify:1",
                variants: [one], profile: profile(apparel: ["M"])
            )
            #expect(link.action == .productPage)
            #expect(link.url == page)
        }
        #expect(!Checkout.isShopify("shopify:"))
        #expect(!Checkout.isShopify("shopify:abc"))
    }

    @Test("A link that is not a product page is left alone")
    func notAProductPage() {
        let home = URL(string: "https://kith.com/")!
        let link = Checkout.link(
            to: home, productExternalID: "shopify:1",
            variants: run, profile: profile(apparel: ["M"])
        )
        #expect(link.url == home)
        #expect(link.action == .productPage)
    }

    /// A market or currency parameter belongs to the shop; an old `variant` does not.
    @Test("Preselecting keeps the page's own query and replaces any variant")
    func preselectingEncodes() {
        let withQuery = URL(string: "https://kith.com/products/x?currency=EUR&variant=1")!
        let url = Checkout.preselecting("104", on: withQuery)
        let items = URLComponents(url: url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(items.contains(URLQueryItem(name: "currency", value: "EUR")))
        #expect(items.filter { $0.name == "variant" } == [URLQueryItem(name: "variant", value: "104")])
    }
}

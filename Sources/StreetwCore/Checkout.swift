// Checkout.swift
// The way out to the shop, carrying the size somebody already told us.
//
// Every product page ends at the storefront, and until this it ended at the *product
// page* of the storefront: tap OPEN ON KITH.COM, land on the jacket, pick M again from the
// shop's own size menu, add it to the bag, open the bag, start checkout. Five steps the app
// already knew the answer to — it holds the size profile, it holds every variant, and on a
// drop those five steps are the difference between an M and a sold-out page.
//
// Shopify publishes the shortcut. A **cart permalink**, `https://<shop>/cart/<variant>:1`,
// is a documented storefront URL that opens the shop's checkout with that variant already
// in it. It is the same thing the shop's own "Buy it now" button does, and it is the whole
// of Phase 0's "one-tap checkout": a person still decides, on the shop's own checkout, with
// the shop's own payment — the app never holds a card, a login or a basket. See the
// roadmap's *No auto-buy agent* for why it stops there.
//
// **Only when the answer is unambiguous, because the failure is the wrong size in
// somebody's checkout.** The link is built from `SizeProfile.claims` — the strict half of
// size matching, which is silent on every "don't know" — never from `matches`, which says
// yes whenever it cannot read a size. An unreadable "44", a profile with M *and* L both in
// stock, a jacket in four colourways with none chosen: each of those opens the product page
// rather than guessing, because a guess here is not a wrongly-ruled token on a size run, it
// is money.
//
// Everywhere else, the product page — exactly, rather than the shop's homepage — with the
// size preselected where the platform's URL says how. Only Shopify does reliably:
// `?variant=<id>` is read by every Online Store theme and by Hydrogen's product route.
// WooCommerce wants an attribute slug per store (`?attribute_pa_size=m`, where the slug is
// whatever the merchant named the attribute), Salesforce wants a product-scoped
// `dwvar_<pid>_size`, and the UCP storefronts this app reads publish nothing about their
// web URLs at all. None of those is something the catalogue tells us, so none is guessed.

import Foundation

/// Where the buy bar sends somebody, and what it can honestly say about it.
public struct CheckoutLink: Hashable, Sendable {
    public enum Action: Hashable, Sendable {
        /// The shop's checkout, with one variant already in it.
        case checkout
        /// The product page itself — with `variantID` selected, when there is one.
        case productPage
    }

    public var url: URL
    public var action: Action
    /// The variant the link names, when it names one.
    public var variantID: String?
    /// The size the link carries, as the catalogue prints it. Nil when the link names no
    /// variant, and when the variant it names has no size to choose — a cap, a bag, a
    /// colourway-only product.
    public var size: String?

    public init(url: URL, action: Action, variantID: String? = nil, size: String? = nil) {
        self.url = url
        self.action = action
        self.variantID = variantID
        self.size = size
    }
}

public enum Checkout {
    /// The link for one product, given what the reader wears and what they chose on the page.
    ///
    /// - Parameters:
    ///   - productURL: the product's own page, as the catalogue gave it.
    ///   - productExternalID: how the catalogue keys the garment — `shopify:<id>` is what
    ///     says this is a Shopify product, and therefore that `variants` carry Shopify ids.
    ///     Pass the event's `externalID` when there is no product key; a standalone row is
    ///     keyed `shopify:<id>` there.
    ///   - colorway: the colourway selected on the page, if any. Narrows the variants before
    ///     anything else, because "my size" in black and "my size" in sand are different
    ///     garments in the checkout.
    public static func link(
        to productURL: URL,
        productExternalID: String?,
        variants: [VariantInfo],
        profile: SizeProfile,
        colorway: String? = nil
    ) -> CheckoutLink {
        let plain = CheckoutLink(url: productURL, action: .productPage)
        guard isShopify(productExternalID),
              let host = productURL.host(), !host.isEmpty,
              productURL.path.contains("/products/")
        else { return plain }

        let named = variants.filter { isShopifyVariantID($0.id) }
        let inColour = colorway.map { colour in
            named.filter { $0.color?.caseInsensitiveCompare(colour) == .orderedSame }
        } ?? named

        // Which variants are *this reader's*: one they told us they wear, or one with no size
        // to choose at all. Never one we merely failed to rule out.
        let yours = inColour.filter { hasNoSizeChoice($0) || profile.claims($0) }
        let buyable = yours.filter(\.available)

        if buyable.count == 1, let variant = buyable.first,
           let url = cartPermalink(host: host, variantID: variant.id) {
            return CheckoutLink(
                url: url,
                action: .checkout,
                variantID: variant.id,
                size: hasNoSizeChoice(variant) ? nil : variant.displaySize
            )
        }

        // One variant is theirs and it is sold out. The product page opened on it is still
        // the honest destination — the shop says "sold out" in their size, which is the
        // answer, rather than offering a size menu that starts at XS.
        if buyable.isEmpty, yours.count == 1, let variant = yours.first,
           let url = preselecting(variant.id, on: productURL) {
            return CheckoutLink(
                url: url,
                action: .productPage,
                variantID: variant.id,
                size: hasNoSizeChoice(variant) ? nil : variant.displaySize
            )
        }

        return plain
    }

    /// Whether the catalogue key says Shopify — and therefore that a variant id is one the
    /// storefront's own URLs understand.
    ///
    /// The key rather than the host, because a Shopify shop can live on any domain (Kith,
    /// Palace, Stüssy are none of them `myshopify.com`), and because a UCP storefront *is*
    /// often Shopify underneath while publishing variant ids in its own encoding.
    static func isShopify(_ productExternalID: String?) -> Bool {
        guard let key = productExternalID, key.hasPrefix("shopify:") else { return false }
        return isShopifyVariantID(String(key.dropFirst("shopify:".count)))
    }

    /// A Shopify id is a positive integer, and nothing else may be spliced into a path.
    ///
    /// `ShopifySource` writes `String(variant.id ?? 0)`, so a variant the payload sent
    /// without an id arrives as "0" — which would make a permalink to nothing.
    static func isShopifyVariantID(_ id: String) -> Bool {
        !id.isEmpty && id.utf8.allSatisfy { $0 >= 48 && $0 <= 57 } && id.contains { $0 != "0" }
    }

    /// True for a variant whose only difference from its siblings is not a size.
    ///
    /// "Default Title" (one variant, no options), a one-size token, or a product whose only
    /// axis is colour — `ShopifySource` leaves `size` nil when no axis is named Size, and the
    /// title of a colour-only variant is just the colour. Such a variant is unambiguous once
    /// the colour is chosen, and claiming a size for it would be printing "ADD BLACK".
    static func hasNoSizeChoice(_ variant: VariantInfo) -> Bool {
        guard variant.isMeaningfulSize else { return true }
        if SizeNormalizer.normalize(variant.displaySize)?.kind == .oneSize { return true }
        if variant.size == nil, let color = variant.color,
           variant.title.caseInsensitiveCompare(color) == .orderedSame {
            return true
        }
        return false
    }

    /// `https://<host>/cart/<variant>:1`.
    ///
    /// On the product's own host, which is the storefront the reader has been looking at —
    /// a regional subdomain (`usa.`, `eu.`) is a different shop with its own currency, and
    /// the permalink must not move anybody off it. Always `https`: a checkout is the one
    /// page where a downgrade is not acceptable, whatever the catalogue happened to link.
    static func cartPermalink(host: String, variantID: String) -> URL? {
        guard isShopifyVariantID(variantID) else { return nil }
        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        components.path = "/cart/\(variantID):1"
        return components.url
    }

    /// The product page with `?variant=<id>`, replacing any variant it already named and
    /// keeping every other query item — a market or currency parameter belongs to the shop.
    static func preselecting(_ variantID: String, on productURL: URL) -> URL? {
        guard isShopifyVariantID(variantID),
              var components = URLComponents(url: productURL, resolvingAgainstBaseURL: false)
        else { return nil }
        var items = (components.queryItems ?? []).filter { $0.name != "variant" }
        items.append(URLQueryItem(name: "variant", value: variantID))
        components.queryItems = items
        return components.url
    }
}

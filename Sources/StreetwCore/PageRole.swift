// PageRole.swift
// Whether a shared page is one product or a shop.
//
// The share sheet asks, because the two want different things of it: a product is saved, and
// can be watched; a homepage or a collection saved as a "product" was a junk card on the wall —
// a photograph of a banner, no price, nothing to watch — when what somebody sharing a shop
// almost always means is *follow this*. Pure and here rather than in the extension because it
// is a heuristic that will be improved, and an improvement should be a test, not a device run.

import Foundation

public enum PageRole: String, Sendable, Hashable, Codable {
    case product
    case shop

    /// - Parameters:
    ///   - product: what `ProductPage` read from the page, nil when it found no product.
    ///   - metadata: the page's tags, when the page itself was read — nil for a link shared
    ///     from an app that handed over the address alone, where only the path can speak.
    public static func of(_ url: URL, product: ProductPage?, metadata: PageMetadata?) -> PageRole {
        let segments = url.path.split(separator: "/").map { $0.lowercased() }
        let names = segments.filter { !isLocale($0) && $0 != "index.html" }

        // A homepage is a shop whatever it declares — Hollister's says `og:type` `product`.
        if names.isEmpty { return .shop }
        if product != nil { return .product }

        let namesProduct = names.contains { productSegments.contains($0) }
        if !namesProduct, names.contains(where: { listingSegments.contains($0) }) { return .shop }

        // The page was read and offers no product: no `Product` JSON-LD, no priced Open Graph,
        // and not even `og:type` claiming one. That is the brief's definition of a shop page.
        if let metadata {
            return metadata.type?.contains("product") == true || namesProduct ? .product : .shop
        }
        // An address alone, from Messages or Notes: a save, as every share was before.
        return .product
    }

    /// "de", "en-us", "en_gb" — a storefront's language or region, not a page.
    static func isLocale(_ segment: String) -> Bool {
        let parts = segment.split(whereSeparator: { $0 == "-" || $0 == "_" })
        guard (1...2).contains(parts.count) else { return false }
        return parts.allSatisfy { $0.count == 2 && $0.allSatisfy(\.isLetter) }
    }

    private static let productSegments: Set<String> = ["products", "product", "p", "item", "items", "dp"]
    private static let listingSegments: Set<String> = [
        "collections", "collection", "category", "categories", "c", "shop", "catalog", "catalogue",
        "search", "new", "sale", "brands"
    ]
}

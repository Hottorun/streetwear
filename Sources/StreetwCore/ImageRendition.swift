// ImageRendition.swift
// Asking a CDN for the size we're actually going to draw.
//
// Storefront product photography is shot for a desktop zoom view: Shopify originals are
// routinely 2000–3000px on the long edge and several megabytes each. The feed draws them
// at roughly 120pt in a grid and 350pt as a lead. One brand spread pulls seven of them.
// On anything short of wifi that is slow enough that loads get cancelled by scrolling,
// which `AsyncImage` surfaces as a permanent failure — the "images don't always load"
// problem, most of the way down to its root.
//
// `BrandMark.upscaled` already does this in the other direction, asking the same CDN for
// a *bigger* favicon. Same documented mechanism, opposite need.

import Foundation

public enum ImageRendition {
    /// Widths we ever request, so the URLs stay cacheable across screens.
    ///
    /// A continuous width would mint a distinct URL for every layout — a grid tile at
    /// 118pt and one at 121pt would each miss the other's cache entry and refetch the
    /// same photograph. Snapping to a ladder means the lead image a user already loaded
    /// is the one the detail page draws.
    public static let ladder = [200, 400, 600, 900, 1200, 1600]

    /// A URL for the same image at roughly `width` points on a `scale`× screen.
    ///
    /// Returns the URL untouched when the host isn't a CDN we know how to ask, which is
    /// the safe default: a resize parameter a CDN doesn't understand is at best ignored
    /// and at worst a 404, and a missing photograph is a worse outcome than a large one.
    public static func sized(_ url: URL, width: Int, scale: Int = 3) -> URL {
        let pixels = snapped(width * scale)

        guard isShopifyCDN(url),
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { return url }

        // Preserve `v=` — it is the cache-busting version, and dropping it can serve a
        // stale rendition of a photograph the brand has since replaced.
        var items = components.queryItems?.filter { $0.name != "width" && $0.name != "height" } ?? []
        items.append(URLQueryItem(name: "width", value: String(pixels)))
        components.queryItems = items

        return components.url ?? url
    }

    /// The smallest ladder width that still covers the request, so an image is never
    /// upscaled into softness. Beyond the ladder, ask for the original.
    static func snapped(_ pixels: Int) -> Int {
        ladder.first { $0 >= pixels } ?? ladder[ladder.count - 1]
    }

    /// Shopify serves storefront assets from `cdn.shopify.com` and, more recently, from
    /// the shop's own domain under `/cdn/shop/`. Both accept `width`.
    static func isShopifyCDN(_ url: URL) -> Bool {
        let host = url.host()?.lowercased() ?? ""
        return host.hasSuffix("cdn.shopify.com")
            || host.hasSuffix("cdn.shop")
            || url.path.contains("/cdn/shop/")
            || url.path.contains("/cdn/shopifycloud/")
    }
}

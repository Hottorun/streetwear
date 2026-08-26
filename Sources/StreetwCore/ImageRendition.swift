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
import Synchronization

public enum ImageRendition {
    /// URLs already rewritten, keyed on the request.
    ///
    /// `sized` builds a `URLComponents`, filters and rebuilds the query items and
    /// re-serialises — one of Foundation's more expensive round trips. `CachedImage` calls
    /// it from `body`, for every photograph on screen, on every render pass, and then makes
    /// `.task(id:)` compare the result. The inputs repeat exactly: a grid draws the same
    /// tiles at the same width, and the ladder exists precisely so nearby widths collapse
    /// onto one answer.
    private static let cache = Mutex<[Request: URL]>([:])
    private static let cacheLimit = 4_096

    private struct Request: Hashable {
        var url: URL
        var pixels: Int
    }
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
        let request = Request(url: url, pixels: snapped(width * scale))
        if let hit = cache.withLock({ $0[request] }) { return hit }
        let answer = rewrite(request)
        cache.withLock {
            if $0.count >= cacheLimit { $0.removeAll(keepingCapacity: true) }
            $0[request] = answer
        }
        return answer
    }

    private static func rewrite(_ request: Request) -> URL {
        let (url, pixels) = (request.url, request.pixels)

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

    /// How many pixels wide the drawn image should actually be.
    ///
    /// The same number `sized` puts in the query, exposed because the client needs it even
    /// when the query was never added: `sized` returns the URL untouched for any host it
    /// does not recognise, and those are exactly the ones that hurt — Palace ships 3200²
    /// PNGs, which is a 41MB bitmap once rasterised. Downsampling on the way in is the only
    /// defence there, and it needs a target.
    public static func pixels(for width: Int, scale: Int = 3) -> Int {
        snapped(width * scale)
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

// BrandDiscovery.swift
// Given just a website URL, work out what we can actually watch.

import Foundation

public struct DiscoveredSources: Sendable {
    public var sources: [BrandSource] = []
    public var suggestedName: String?
    /// The brand's own mark, taken from the icon the site publishes for home screens.
    public var logoURL: URL?

    public init() {}

    public var summary: String {
        guard !sources.isEmpty else { return "No automatic sources found" }
        return sources.map(\.kind.label).joined(separator: " · ")
    }

    /// Whether there is anything here to watch at all.
    ///
    /// **A page watch counts, and the reason is evidence rather than theory.** This briefly
    /// did not count them — the argument being that hashing one page says "something
    /// changed" and nothing else, and that on a JavaScript-rendered storefront the hash never
    /// moves. The second half is simply false, and Supreme disproves it: a page watch on that
    /// site fired on a real drop and reached its follower *before the brand's own email did*.
    /// Being early is the entire product, and "something changed at Supreme" delivered on a
    /// Thursday morning is worth more than a full size run delivered late.
    ///
    /// It is also how `StorefrontLock` is detected at all — a password wall or a 403 is what
    /// `PageWatchSource` turns into "a drop looks imminent", which is the strongest signal in
    /// the app and exists on no other source kind.
    ///
    /// So the bar is only that *something answered*. `discover` no longer attaches a page
    /// watch to a site it could not read, which is the honest version of the refusal: not
    /// "this source is too weak to bother with" but "there is nothing here to look at".
    public var canMonitor: Bool {
        sources.contains { $0.kind.isAutomatic }
    }
}

public enum BrandDiscovery {
    /// Probes a domain for a Shopify catalog and a feed, and always falls back to
    /// watching the page itself so every brand yields at least one signal.
    public static func discover(
        website raw: String,
        instagramHandle: String?,
        http: any HTTPFetching = Net.live
    ) async -> DiscoveredSources {
        var result = DiscoveredSources()

        if let base = normalizedURL(raw) {
            var shopName: String?

            // The catalog is not always on the host that was typed: a storefront moved to
            // Hydrogen answers on the apex and 404s `/products.json`, while the classic
            // origin still serves it on `www.`. Whichever one answered is the host the
            // sources are pinned to, so every later poll goes back to the one that works.
            if let store = await ShopifySource.resolve(at: base, http: http) {
                result.sources.append(BrandSource(kind: .shopify, url: store))
                // Only worth probing on a store we already know is Shopify — the
                // endpoint doesn't exist anywhere else, so this costs nothing elsewhere.
                if let collections = await CollectionsSource.detect(at: store, http: http) {
                    result.sources.append(BrandSource(kind: .collections, url: collections))
                }
                // `/meta.json` carries the merchant's own display name, which is the most
                // authoritative answer there is — "Billionaire Boys Club", never
                // "Bbcicecream". Asked for here rather than waiting for the first sync,
                // because the name is shown on the very next screen.
                shopName = await ShopifySource.shopInfo(for: store, http: http)?.name
            }
            if let feed = await FeedSource.detect(at: base, http: http) {
                result.sources.append(BrandSource(kind: .feed, url: feed))
            }
            // The interface a storefront advertises for machines, tried before the sitemap
            // and after everything conventional.
            //
            // **Above the sitemap, and the reason is what each one leaves out.** A sitemap
            // yields a name and a `lastmod` — no price, no variants, no sizes, no stock —
            // so for a brand watched that way the size run renders empty, the size profile
            // matches nothing, a watch has no variant to fire on and a restock cannot be
            // detected at all. That is most of this app switched off for that brand. UCP
            // carries all of it, measured: 250 products from Kith with prices and full size
            // runs. The one thing it lacks is a publication date, which only affects
            // ordering, and a first sighting is stamped when it is seen.
            //
            // Below Shopify and the feed because those are cheaper and need nothing from
            // us. This is the only source whose success depends on **our** deployment being
            // reachable — the merchant fetches `UCPAgent.profileURL` before answering — so
            // when a storefront offers something that works without us, it wins.
            if result.sources.isEmpty, let ucp = await UCPSource.detect(at: base, http: http) {
                result.sources.append(BrandSource(kind: .ucp, url: ucp))
            }

            // A sitemap is the fallback *before* page watching: it names individual
            // products, where a page watch can only say "something changed".
            if result.sources.isEmpty, let sitemap = await SitemapSource.detect(at: base, http: http) {
                result.sources.append(BrandSource(kind: .sitemap, url: sitemap))
            }

            // Page watching is the last resort, and only when there's no structured
            // source; otherwise it just fires on every marketing banner swap.
            //
            // **Attached only if the page can actually be read.** Everything else here is
            // verified before it is trusted — a sitemap has to yield an item, a UCP endpoint
            // has to answer — and this was the one that was assumed. A domain that does not
            // resolve, or answers nothing but a bot wall, still got a source and a brand row
            // that reported no error and delivered nothing forever. `isLocked` is
            // deliberately allowed through: a storefront behind a password page is not
            // unreadable, it is *about to drop*, and that is the strongest signal here.
            if result.sources.isEmpty,
               let watch = try? await PageWatchSource(http: http)
                   .fetch(BrandSource(kind: .page, url: base), since: nil),
               watch.isLocked || watch.fingerprint != nil {
                result.sources.append(BrandSource(kind: .page, url: base))
            }

            // One extra request, once, when a brand is added — never on a poll. It answers
            // two questions at once: the mark the site publishes for home screens, and the
            // name it publishes for link previews.
            let identity = await SiteIdentityProbe.discover(at: base, http: http)
            result.logoURL = identity.logoURL
            result.suggestedName = BrandNaming.pick(
                shopName: shopName,
                siteName: identity.name,
                host: base.host()
            )
        }

        if let handle = normalizedHandle(instagramHandle),
           let url = URL(string: "https://instagram.com/\(handle)") {
            result.sources.append(BrandSource(kind: .instagram, url: url))
        }

        return result
    }

    /// Accepts "kith.com", "kith.com/", "https://kith.com/collections/new".
    /// Reduces to the scheme + host, which is what the probes need.
    public static func normalizedURL(_ raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let withScheme = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
        guard var components = URLComponents(string: withScheme), let host = components.host else { return nil }
        components.scheme = "https"
        components.host = host
        components.path = ""
        components.query = nil
        components.fragment = nil
        return components.url
    }

    /// The part of a host that identifies the *brand* rather than the storefront.
    ///
    /// A brand is not one hostname. Palace alone answers on `palaceskateboards.com`,
    /// `www.`, `usa.` and `eu.` — four hosts, one label, one row in the Brands tab — and
    /// whichever of them the brand was added with is the only one an exact-match check
    /// recognises. Everything shared or discovered from the others is attributed to
    /// nobody, which on screen means a saved item with no brand name over it.
    ///
    /// Two labels, or three when the second-to-last is a public suffix that everybody
    /// registers underneath ("co.uk", "com.au"). Deliberately a heuristic and not the
    /// Public Suffix List: that is a megabyte of data that needs updating, to answer a
    /// question whose worst outcome is a saved link not being filed under a brand — which
    /// is exactly where it already is.
    public static func registrableDomain(of host: String) -> String {
        let labels = host.lowercased().split(separator: ".").map(String.init)
        guard labels.count > 2 else { return labels.joined(separator: ".") }

        let secondToLast = labels[labels.count - 2]
        let take = Self.secondLevelSuffixes.contains(secondToLast) ? 3 : 2
        return labels.suffix(take).joined(separator: ".")
    }

    /// Second-level suffixes common enough to matter for storefronts. Not exhaustive and
    /// not meant to be — an unlisted one costs an unattributed save, not a wrong one.
    private static let secondLevelSuffixes: Set<String> = [
        "co", "com", "net", "org", "gov", "ac", "edu"
    ]

    /// Whether two URLs belong to the same brand's storefront estate.
    public static func isSameBrandHost(_ a: URL?, _ b: URL?) -> Bool {
        guard let first = a?.host(), let second = b?.host() else { return false }
        return registrableDomain(of: first) == registrableDomain(of: second)
    }

    public static func normalizedHandle(_ raw: String?) -> String? {
        guard var handle = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !handle.isEmpty else { return nil }
        if let url = URL(string: handle), url.host?.contains("instagram.com") == true {
            handle = url.lastPathComponent
        }
        handle = handle.trimmingCharacters(in: CharacterSet(charactersIn: "@/ "))
        return handle.isEmpty ? nil : handle
    }

}

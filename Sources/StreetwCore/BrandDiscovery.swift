// BrandDiscovery.swift
// Given just a website URL, work out what we can actually watch.

import Foundation

public struct DiscoveredSources: Sendable {
    public var sources: [BrandSource] = []
    public var suggestedName: String?
    /// The brand's own mark, taken from the icon the site publishes for home screens.
    public var logoURL: URL?
    /// What `/meta.json` said about the shop that answered, on a Shopify store — read in
    /// the same request as the name, so knowing them costs nothing. What a storefront
    /// attached for a country is checked against (`ShopifySource.ShopInfo.shipsTo`).
    public var currency: String?
    public var shipsTo: [String] = []
    /// The copies of the site its homepage names for each language and country (`hreflang`),
    /// read out of the homepage fetch the name and the mark already need. What the server
    /// finds a brand's country shops in (`CountryShops`).
    public var alternates: [LanguageAlternate] = []
    /// Whether the feed found announces the shop's new products rather than posts.
    public var feedAnnouncesProducts = false

    public init() {}

    /// Whether anything found reads the shop's *products* — a Shopify catalogue, UCP, a
    /// sitemap, or a feed of new products — rather than only posts or a page's hash.
    public var readsProducts: Bool {
        sources.contains { source in
            source.kind == .feed
                ? feedAnnouncesProducts || FeedSource.announcesProducts(url: source.url)
                : BrandDiscovery.readsProducts(kind: source.kind, url: source.url)
        }
    }

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
            let hint = storefrontHint(raw)

            // The homepage, once, first: the name and the mark come out of it, and so do the
            // feeds it declares and the country shops it names (`hreflang`). It used to be
            // fetched last, for the name alone; reading it first costs nothing more. A typed
            // store view (`/de_en`) is its own homepage: its feeds are the ones it declares.
            let page = storeViewPage(base, hint: hint)
            let home = await SiteIdentityProbe.homepage(at: page, http: http)
            if let home {
                result.alternates = SiteAlternates.languages(in: home.html, base: home.url)
            }
            let declaredFeeds = home.map { home in
                SiteAlternates.feeds(in: home.html, base: home.url).filter { isSameBrandHost($0, base) }
            } ?? []

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
                let shop = await ShopifySource.shopInfo(for: store, http: http)
                shopName = shop?.name
                result.currency = shop?.currency
                result.shipsTo = shop?.shipsTo ?? []
            }
            // Declared feeds first, then the conventional paths, following a page that lists
            // feeds — Magento's `/rss` — to the one of new products. See `FeedSource.find`.
            if let feed = await FeedSource.find(at: base, declared: declaredFeeds, preferring: hint, http: http) {
                result.sources.append(BrandSource(kind: .feed, url: feed.url))
                result.feedAnnouncesProducts = feed.announcesProducts
            }
            let hasShopify = result.sources.contains { $0.kind == .shopify }
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
            //
            // **Tried whenever there is no Shopify catalogue — a feed does not stand in for
            // one.** It used to need *nothing* found, so a store whose `/products.json`
            // answered 429 but whose blog answered 200 was watched by its blog alone, and a
            // shop's news posts are not its products. A Shopify store rate-limiting the
            // catalogue (us.subdued.com, measured) falls through to here, never to a page
            // watch; nothing retries it another way.
            if !hasShopify, let ucp = await UCPSource.detect(at: base, http: http) {
                result.sources.append(BrandSource(kind: .ucp, url: ucp))
            }

            // A sitemap is the fallback *before* page watching: it names individual
            // products, where a page watch can only say "something changed". What was typed
            // goes along whole, because its path can say which storefront was meant —
            // `subdued.com/eu_en/` — and `base` has had the path stripped.
            //
            // Not beside anything else that reads the products — Shopify, UCP, a feed of new
            // products — because both would name the same garments under different ids, and
            // every one would be on screen twice. A blog's feed is not that, and blocks nothing.
            if !result.readsProducts,
               let sitemap = await SitemapSource.detect(at: base, preferring: hint, http: http) {
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
            //
            // **A feed does not replace it.** Nothing but a page watch sees a storefront lock
            // (`StorefrontLock`), and a feed — of posts or of new products — says nothing
            // about one, so the page is watched beside a feed as it was beside nothing. Only
            // a catalogue — Shopify, UCP, a sitemap — makes it a banner-swap alarm with
            // nothing to add. A typed store view (`subdued.com/de_en`) is watched at that
            // view, so a country's shop on one host is a page of its own.
            let catalogued = result.sources.contains { [.shopify, .ucp, .sitemap].contains($0.kind) }
            if !catalogued,
               let watch = try? await PageWatchSource(http: http)
                   .fetch(BrandSource(kind: .page, url: page), since: nil),
               watch.isLocked || watch.fingerprint != nil {
                result.sources.append(BrandSource(kind: .page, url: page))
            }

            // The homepage read at the start answers two more questions: the mark the site
            // publishes for home screens, and the name it publishes for link previews.
            let identity = SiteIdentityProbe.identity(of: home, base: base)
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
        // **Every user-supplied URL in the project passes through here**, on both sides of
        // the wire, which is why the refusal lives here rather than at the two routes that
        // happen to be the dangerous ones today. A host that is not publicly routable is
        // not a storefront; see `HostSafety` for what that bought.
        guard HostSafety.isPublic(host: host) else { return nil }
        components.scheme = "https"
        components.host = host
        components.path = ""
        components.query = nil
        components.fragment = nil
        return components.url
    }

    /// What was typed, path and all, for the one thing the path can say: which country and
    /// language the storefront is. Read by `LocalePreference` and never fetched, so it gets
    /// none of `normalizedURL`'s checks and needs none.
    static func storefrontHint(_ raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return URL(string: trimmed.contains("://") ? trimmed : "https://\(trimmed)")
    }

    /// The page to watch: the store view the typed URL names (`/de_en`), else the homepage.
    /// Any other path is dropped, as it always was — "kith.com/collections/new" watches Kith.
    static func storeViewPage(_ base: URL, hint: URL?) -> URL {
        guard let view = FeedSource.storeView(of: hint),
              var components = URLComponents(url: base, resolvingAgainstBaseURL: false)
        else { return base }
        components.path = view
        return components.url ?? base
    }

    /// Whether a source of this kind, at this URL, reads the shop's products — what a brand's
    /// catalogue is made of, as against a blog's posts or a page's hash. A feed only when it
    /// is plainly one of new products (`FeedSource.announcesProducts`).
    public static func readsProducts(kind: BrandSource.Kind, url: URL) -> Bool {
        switch kind {
        case .shopify, .ucp, .sitemap: true
        case .feed: FeedSource.announcesProducts(url: url)
        case .collections, .page, .instagram: false
        }
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

// SitemapSource.swift
// The fallback for brands that aren't Shopify and don't publish a feed.
//
// Until now those got a `PageWatchSource`, which can only ever say "something on this
// page changed" — and fires just as loudly for a swapped banner as for a release. A
// sitemap is strictly better: it is a machine-readable list of every product page the
// brand has, maintained by the brand, with a `<lastmod>` on each entry. New products
// appear in it as new URLs.
//
// Two things make this work without keeping any extra state:
//
// - **`<lastmod>` plays the role of `published_at`.** Filtering on `since` is the same
//   mechanism every other adapter uses, so the first poll is a baseline and later polls
//   return only what moved.
// - **Dedupe is already solved upstream.** Items are keyed `sitemap:<url>`, and the merge
//   layer decides what is new — the adapter never has to remember the previous URL set.
//
// What it cannot do is give a product a price. It *can* usually give a name and a
// photograph, because Shopify — and most sitemap generators — emit Google's image
// extension inside each `<url>`:
//
//     <image:image>
//       <image:loc>https://cdn.shopify.com/…/palace-avirex-jacket-black-1.png</image:loc>
//       <image:title>PALACE AVIREX JACKET BLACK</image:title>
//     </image:image>
//
// **That title is the product's real name and it must be preferred over the slug.**
// Palace randomises its handles until a drop is live — `/products/av1bal6eijz1` — so a
// slug-derived title produced a feed of "E7Anvz3I1Psy" over an empty grey tile, while
// the correct name and the correct photograph were sitting two lines further down the
// same XML. Any store that hides its handles this way hits exactly the same wall.
//
// The slug is still the fallback, and when *it* is unreadable too the item says so
// rather than printing a hash at somebody.

import Foundation

#if canImport(FoundationXML)
import FoundationXML
#endif

public struct SitemapSource: SourceAdapter {
    public var kind: BrandSource.Kind { .sitemap }

    /// A sitemap index can point at dozens of children. Only the ones that look like
    /// product listings are followed, and never more than this many — walking an entire
    /// site's sitemap tree on every poll is exactly the impolite behaviour
    /// `PoliteFetcher` exists to prevent.
    private static let maxChildSitemaps = 3
    /// Cap on items returned from one poll, so a brand that rebuilds its whole sitemap
    /// (touching every `lastmod`) can't dump its catalogue into the feed.
    private static let maxItems = 60

    private let http: any HTTPFetching

    public init(http: any HTTPFetching = Net.live) {
        self.http = http
    }

    public func fetch(_ source: BrandSource, since: Date?) async throws -> FetchResult {
        let response = try await http.get(source.url, etag: source.etag)
        if response.notModified {
            return FetchResult(etag: source.etag, notModified: true)
        }
        if response.isLocked {
            return FetchResult(isLocked: true, etag: source.etag)
        }
        try response.requireOK()

        var entries = SitemapParser().parse(response.data)
        guard !entries.isEmpty else { throw SourceError.emptyPayload }

        // A sitemap index lists other sitemaps rather than pages. Follow the ones whose
        // names suggest products; ignore the rest, which are blogs, pages and policies.
        if entries.allSatisfy(\.isIndex) {
            var collected: [Entry] = []
            // Named children first — "…/product/sitemap.xml" is a strong hint and following
            // the blog instead would be a waste of the budget.
            //
            // **But an index whose children are merely numbered still has products in it.**
            // Acne Studios lists 78 files called `sitemap_1.xml` … `sitemap_78.xml`, and
            // Palm Angels 138 named after locales — nothing matches, so the filter selected
            // nothing and the adapter returned empty from a perfectly good index. On screen
            // that is a brand row saying "Sitemap" with no error and no products, which is
            // the failure this whole file keeps producing in new ways. Reading the first few
            // is strictly better than reading none, and it is bounded by exactly the same
            // cap either way.
            let named = entries.filter { Self.looksLikeProducts($0.location) }
            for child in (named.isEmpty ? entries : named).prefix(Self.maxChildSitemaps) {
                guard let url = URL(string: child.location),
                      let childResponse = try? await http.get(url, etag: nil),
                      childResponse.status == 200
                else { continue }
                collected.append(contentsOf: SitemapParser().parse(childResponse.data))
            }
            entries = collected
        }

        let items = entries
            .filter { !$0.isIndex }
            .filter { Self.looksLikeProduct($0.location) }
            .compactMap { entry -> FetchedItem? in
                guard let url = URL(string: entry.location) else { return nil }
                let modified = entry.lastModified.flatMap(DateParsing.any)
                // No `lastmod` means the brand isn't telling us when it changed, and
                // assuming "now" would resurface the whole catalogue on every poll.
                guard let modified else { return nil }
                if let since, modified <= since { return nil }

                return FetchedItem(
                    externalID: "sitemap:\(url.absoluteString)",
                    title: Self.title(for: entry, url: url),
                    linkURL: url,
                    imageURLStrings: entry.imageLocation.map { [$0] } ?? [],
                    publishedAt: modified,
                    kind: .product
                )
            }
            .sorted { $0.publishedAt > $1.publishedAt }
            .prefix(Self.maxItems)

        return FetchResult(items: Array(items), etag: response.etag)
    }

    // MARK: - Heuristics

    /// Path shapes that hold individual products across the platforms streetwear brands
    /// actually use — Shopify, WooCommerce, Squarespace, BigCommerce and custom builds.
    static func looksLikeProduct(_ location: String) -> Bool {
        let lowered = location.lowercased()
        let markers = ["/products/", "/product/", "/shop/", "/p/", "/item/", "/store/"]
        guard markers.contains(where: lowered.contains) else { return false }
        // The listing page itself is not a product.
        return !markers.contains { lowered.hasSuffix($0) || lowered.hasSuffix(String($0.dropLast())) }
    }

    /// Whether a child sitemap's *name* suggests it lists products.
    ///
    /// **Whole tokens, never substrings** — the rule this codebase already runs on for
    /// gender, and it was being broken here in the funniest possible way: `"sitemap"`
    /// contains `"item"`, so every child called anything-`sitemap.xml` matched and the
    /// filter selected the entire index. It has therefore never once narrowed anything, and
    /// the first three children got followed whatever they were — the blog as readily as the
    /// catalogue.
    static func looksLikeProducts(_ location: String) -> Bool {
        let tokens = Set(location.lowercased().split { !$0.isLetter }.map(String.init))
        return !tokens.isDisjoint(with: ["product", "products", "shop", "item", "items"])
    }

    /// The best name the entry can offer, in descending order of trust.
    ///
    /// The image extension's `<image:title>` is the brand's own words and beats anything
    /// derived from a URL. The slug is next, and only when it reads as language — a
    /// randomised handle is worse than admitting we don't have a name, because it prints
    /// a hash where a product should be.
    static func title(for entry: Entry, url: URL) -> String {
        if let published = entry.imageTitle?.trimmingCharacters(in: .whitespacesAndNewlines),
           !published.isEmpty {
            return published
        }
        let derived = title(from: url)
        return isReadable(derived) ? derived : unnamed
    }

    /// What a product is called when nothing has told us yet.
    public static let unnamed = "New arrival"

    /// Whether a title is a stand-in rather than a name.
    ///
    /// Both ends of the sync consult this before *replacing* a stored title: a product
    /// whose name arrived late — a randomised handle that a later poll resolved through
    /// the image extension — should take the real one, and a real one should never be
    /// downgraded back to a hash. Everything else keeps whatever it was given.
    public static func isProvisional(_ title: String) -> Bool {
        title == unnamed || !isReadable(title)
    }

    /// Whether a slug-derived title is a name or a hash.
    ///
    /// A real slug is words: it either has more than one of them, or it is a single word
    /// with no digits stirred through it. "av1bal6eijz1" and "e7anvz3i1psy" are neither,
    /// and there is no length at which a lone letter-and-digit soup becomes a product
    /// name. Short codes stay readable, because "FW26" genuinely is what something is
    /// called.
    public static func isReadable(_ title: String) -> Bool {
        let words = title.split(separator: " ")
        guard words.count == 1, let only = words.first else { return !words.isEmpty }
        guard only.count > 5 else { return true }
        let hasDigit = only.contains(where: \.isNumber)
        let hasLetter = only.contains(where: \.isLetter)
        return !(hasDigit && hasLetter)
    }

    /// "…/products/kith-box-logo-hoodie-black" → "Kith Box Logo Hoodie Black".
    ///
    /// Crude, and knowingly so. For streetwear the slug is usually the product name,
    /// which beats showing a bare URL — but see `isReadable`, because it is sometimes
    /// deliberately not.
    static func title(from url: URL) -> String {
        let slug = url.pathComponents.last(where: { $0 != "/" }) ?? url.absoluteString
        let words = slug
            .replacingOccurrences(of: ".html", with: "")
            .split(whereSeparator: { $0 == "-" || $0 == "_" })
            .map { word -> String in
                // Keep acronyms and season codes as they are: "FW26" must not become
                // "Fw26", and "SS26" is not "Ss26".
                let text = String(word)
                let isCode = text.count <= 4 && text.rangeOfCharacter(from: .decimalDigits) != nil
                return isCode ? text.uppercased() : text.capitalized
            }
        return words.isEmpty ? url.absoluteString : words.joined(separator: " ")
    }

    // MARK: - Detection

    public static func detect(at base: URL, http: any HTTPFetching = Net.live) async -> URL? {
        for path in ["/sitemap.xml", "/sitemap_index.xml"] {
            var components = URLComponents(url: base, resolvingAgainstBaseURL: false)
            components?.path = path
            components?.query = nil
            guard let url = components?.url,
                  let response = try? await http.get(url),
                  response.status == 200
            else { continue }

            let entries = SitemapParser().parse(response.data)
            guard !entries.isEmpty else { continue }
            // Only worth attaching if it actually leads to products; a sitemap of
            // marketing pages would produce a feed of noise.
            if entries.contains(where: { looksLikeProduct($0.location) || looksLikeProducts($0.location) }) {
                return url
            }
        }
        return nil
    }

    struct Entry {
        var location: String
        var lastModified: String?
        /// True when this came from `<sitemapindex>` — a pointer to another sitemap
        /// rather than to a page.
        var isIndex: Bool
        /// First `<image:loc>` in this entry, when the sitemap carries the image
        /// extension. Sitemaps list images newest-first per page, so the first one is the
        /// product's lead shot.
        var imageLocation: String?
        /// First `<image:title>`, which is the product's real name.
        var imageTitle: String?

        init(
            location: String,
            lastModified: String? = nil,
            isIndex: Bool,
            imageLocation: String? = nil,
            imageTitle: String? = nil
        ) {
            self.location = location
            self.lastModified = lastModified
            self.isIndex = isIndex
            self.imageLocation = imageLocation
            self.imageTitle = imageTitle
        }
    }
}

/// Handles both `<urlset>` and `<sitemapindex>`; they share the same `<loc>`/`<lastmod>`
/// shape and differ only in their wrapper, so one parser covers both.
private final class SitemapParser: NSObject, XMLParserDelegate {
    private var entries: [SitemapSource.Entry] = []
    private var location = ""
    private var lastModified = ""
    private var imageLocation = ""
    private var imageTitle = ""
    private var current: String?
    private var isIndex = false
    /// `<image:image>` nests a `<loc>` and a `<title>` of its own, so the same local
    /// names mean two different things depending on where they are. Without this the
    /// image URL overwrites the page URL and every entry points at a CDN photograph.
    private var isInsideImage = false

    func parse(_ data: Data) -> [SitemapSource.Entry] {
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.parse()
        return entries
    }

    /// The parser is not namespace-aware, so elements arrive qualified — "image:loc",
    /// not "loc". Prefixes are conventional rather than fixed, so the local part is what
    /// gets matched.
    private static func localName(_ elementName: String) -> String {
        let lowered = elementName.lowercased()
        guard let separator = lowered.lastIndex(of: ":") else { return lowered }
        return String(lowered[lowered.index(after: separator)...])
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName: String?,
        attributes: [String: String]
    ) {
        let name = Self.localName(elementName)
        if name == "sitemap" { isIndex = true }
        if name == "url" { isIndex = false }
        if name == "url" || name == "sitemap" {
            location = ""
            lastModified = ""
            imageLocation = ""
            imageTitle = ""
        }
        if name == "image" { isInsideImage = true }
        current = name
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        switch (current, isInsideImage) {
        case ("loc", false): location += string
        case ("lastmod", _): lastModified += string
        // Only the first image in an entry is kept; a product page lists every shot.
        case ("loc", true) where imageLocation.isEmpty: imageLocation += string
        case ("title", true) where imageTitle.isEmpty: imageTitle += string
        default: break
        }
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName: String?
    ) {
        let name = Self.localName(elementName)
        if name == "image" { isInsideImage = false }
        if name == "url" || name == "sitemap" {
            let trimmed = location.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                let modified = lastModified.trimmingCharacters(in: .whitespacesAndNewlines)
                entries.append(
                    SitemapSource.Entry(
                        location: trimmed,
                        lastModified: modified.isEmpty ? nil : modified,
                        isIndex: name == "sitemap",
                        imageLocation: Self.cleaned(imageLocation),
                        imageTitle: Self.cleaned(imageTitle)
                    )
                )
            }
        }
        current = nil
    }

    private static func cleaned(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

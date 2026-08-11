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
// What it cannot do is give a product a price or a photograph; a sitemap carries neither.
// Titles are derived from the URL slug, which for streetwear is usually the product name.
// Enriching new URLs through `PageMetadataParser` is the obvious next step, but it costs
// one fetch per product and belongs behind the politeness budget rather than in here.

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
        guard response.status == 200 else { throw SourceError.badResponse(response.status) }

        var entries = SitemapParser().parse(response.data)
        guard !entries.isEmpty else { throw SourceError.emptyPayload }

        // A sitemap index lists other sitemaps rather than pages. Follow the ones whose
        // names suggest products; ignore the rest, which are blogs, pages and policies.
        if entries.allSatisfy(\.isIndex) {
            var collected: [Entry] = []
            for child in entries.filter({ Self.looksLikeProducts($0.location) }).prefix(Self.maxChildSitemaps) {
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
                    title: Self.title(from: url),
                    linkURL: url,
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

    static func looksLikeProducts(_ location: String) -> Bool {
        let lowered = location.lowercased()
        return lowered.contains("product") || lowered.contains("shop") || lowered.contains("item")
    }

    /// "…/products/kith-box-logo-hoodie-black" → "Kith Box Logo Hoodie Black".
    ///
    /// Crude, and knowingly so: a sitemap carries no title. For streetwear the slug is
    /// almost always the product name, which beats showing a bare URL.
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
    }
}

/// Handles both `<urlset>` and `<sitemapindex>`; they share the same `<loc>`/`<lastmod>`
/// shape and differ only in their wrapper, so one parser covers both.
private final class SitemapParser: NSObject, XMLParserDelegate {
    private var entries: [SitemapSource.Entry] = []
    private var location = ""
    private var lastModified = ""
    private var current: String?
    private var isIndex = false

    func parse(_ data: Data) -> [SitemapSource.Entry] {
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.parse()
        return entries
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName: String?,
        attributes: [String: String]
    ) {
        let name = elementName.lowercased()
        if name == "sitemap" { isIndex = true }
        if name == "url" { isIndex = false }
        if name == "url" || name == "sitemap" {
            location = ""
            lastModified = ""
        }
        current = name
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        switch current {
        case "loc": location += string
        case "lastmod": lastModified += string
        default: break
        }
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName: String?
    ) {
        let name = elementName.lowercased()
        if name == "url" || name == "sitemap" {
            let trimmed = location.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                let modified = lastModified.trimmingCharacters(in: .whitespacesAndNewlines)
                entries.append(
                    SitemapSource.Entry(
                        location: trimmed,
                        lastModified: modified.isEmpty ? nil : modified,
                        isIndex: name == "sitemap"
                    )
                )
            }
        }
        current = nil
    }
}

// FeedSource.swift
// RSS / Atom reader for brand journals, lookbooks and news pages — and for a shop's own
// feed of new products, where it publishes one.
// Shopify stores get one of these for free at /blogs/news.atom.

import Foundation

// On Linux, XMLParser lives in a separate FoundationXML module rather than Foundation.
// Without this the parser type is `AnyObject` and nothing here compiles.
#if canImport(FoundationXML)
import FoundationXML
#endif

public struct FeedSource: SourceAdapter {
    public var kind: BrandSource.Kind { .feed }

    private let http: any HTTPFetching

    public init(http: any HTTPFetching = Net.live) {
        self.http = http
    }

    public func fetch(_ source: BrandSource, since: Date?) async throws -> FetchResult {
        let response = try await http.get(source.url, etag: source.etag)
        if response.notModified {
            return FetchResult(etag: source.etag, notModified: true)
        }
        try response.requireOK()

        let parser = FeedParser()
        guard let entries = parser.parse(response.data), !entries.isEmpty else {
            throw SourceError.emptyPayload
        }

        // **A shop's new-products feed is products, not posts.** Magento publishes one at
        // `/rss/feed/index/type/new_products/` — every item a garment with a page of its own —
        // and read as a blog it would put a drop in the feed as "a post". Its items carry no
        // stock and no sizes, and a 75-pixel thumbnail, so the server reads each one's page
        // before saying anything (`Poller.enrich`), exactly as it does a sitemap's.
        let announcesProducts = Self.announcesProducts(url: source.url, title: parser.channelTitle)
        let items = entries.map { entry in
            FetchedItem(
                externalID: "feed:\(entry.identity)",
                title: entry.title,
                summary: entry.summary.map(ShopifySource.plainText(from:)),
                linkURL: entry.link.flatMap(URL.init(string:)),
                imageURLStrings: [entry.imageURL.map { announcesProducts ? Self.fullSize($0) : $0 }]
                    .compactMap { $0 },
                publishedAt: entry.published ?? Date(),
                kind: announcesProducts ? .product : (entry.looksLikeCollection ? .collection : .post)
            )
        }
        return FetchResult(items: items, etag: response.etag)
    }

    /// Probe the conventional feed paths when adding a brand.
    public static func detect(at base: URL, http: any HTTPFetching = Net.live) async -> URL? {
        await find(at: base, http: http)?.url
    }

    /// A feed discovery found, and whether it announces products rather than posts.
    public struct Found: Sendable, Hashable {
        public var url: URL
        public var announcesProducts: Bool

        public init(url: URL, announcesProducts: Bool) {
            self.url = url
            self.announcesProducts = announcesProducts
        }
    }

    /// The conventional places, after whatever the homepage declares.
    static let conventionalPaths = ["/blogs/news.atom", "/blogs/journal.atom", "/feed", "/rss", "/feed.xml", "/atom.xml"]

    /// Under a store view's path (`/de_en/rss`), where a shop runs one per country on one
    /// host. Only the two that name a store view's own feeds; a blog is the site's, not the
    /// store view's.
    static let storeViewPaths = ["/rss", "/feed"]

    /// How many feeds one index page may cost, at most. An index lists a dozen; the one
    /// wanted is nearly always the first, and the rest are categories.
    static let indexBudget = 3

    /// Finds the brand's feed: the ones the homepage declares, then the conventional paths —
    /// under the storefront's own store view first, when the typed URL names one.
    ///
    /// **A page that lists feeds is followed, not refused.** Magento answers `/rss` with an
    /// HTML index of the shop's feeds — one of new products, one per category — and that is
    /// where Subdued's new products are, now that its sitemap has gone. The index is read for
    /// feed links (`FeedIndex`): the new-products feed first, then one named for new
    /// arrivals, then any that is not a category. Category feeds are a shelf, not news, and
    /// are never taken. Among store views, the one `LocalePreference` likes best — the typed
    /// URL's host and path, else English — and an empty feed is passed over for the next.
    public static func find(
        at base: URL,
        declared: [URL] = [],
        preferring hint: URL? = nil,
        http: any HTTPFetching = Net.live
    ) async -> Found? {
        var candidates = declared
        if let view = storeView(of: hint) {
            candidates += storeViewPaths.compactMap { at(base, path: view + $0) }
        }
        candidates += conventionalPaths.compactMap { at(base, path: $0) }

        let preference = LocalePreference.of(hint ?? base)
        var tried: Set<String> = []
        for url in candidates where tried.insert(url.absoluteString).inserted {
            guard let response = try? await http.get(url), response.status == 200 else { continue }
            let parser = FeedParser()
            if let entries = parser.parse(response.data), !entries.isEmpty {
                return Found(url: url, announcesProducts: announcesProducts(url: url, title: parser.channelTitle))
            }
            // Not a feed; perhaps a page listing them.
            guard let html = String(data: response.data, encoding: .utf8) else { continue }
            let links = FeedIndex.choose(
                FeedIndex.links(in: html, base: response.finalURL ?? url),
                preferring: preference
            )
            for link in links.prefix(indexBudget) where tried.insert(link.url.absoluteString).inserted {
                guard let feed = try? await http.get(link.url), feed.status == 200 else { continue }
                let parser = FeedParser()
                guard let entries = parser.parse(feed.data), !entries.isEmpty else { continue }
                return Found(
                    url: link.url,
                    announcesProducts: link.announcesProducts
                        || announcesProducts(url: link.url, title: parser.channelTitle)
                )
            }
        }
        return nil
    }

    /// Whether a feed announces a shop's new products: its URL or its title says so.
    ///
    /// Words, not substrings, and only these: "new" alone is every blog's favourite word, and
    /// a feed called "New Arrivals" is named for exactly what this means.
    public static func announcesProducts(url: URL, title: String? = nil) -> Bool {
        let path = url.path.lowercased()
        if productPathMarkers.contains(where: path.contains) { return true }
        guard let title else { return false }
        return namesNewProducts(title)
    }

    static let productPathMarkers = [
        "new_products", "new-products", "newproducts", "new_arrivals", "new-arrivals", "newarrivals"
    ]

    static func namesNewProducts(_ text: String) -> Bool {
        let words = text.lowercased().split(whereSeparator: { !$0.isLetter }).joined(separator: " ")
        let padded = " \(words) "
        return ["new products", "new arrivals", "new in", "just in", "just landed", "latest arrivals"]
            .contains { padded.contains(" \($0) ") }
    }

    /// A Magento feed's photograph is a thumbnail of the catalogue image, sized by query —
    /// `…/tp0tg3t.jpg?width=75&height=75&canvas=75,75&optimize=medium&fit=bounds`. Without the
    /// sizing it is the image itself. Only a query made of nothing but sizing is dropped;
    /// anything else might be what names the file.
    static func fullSize(_ raw: String) -> String {
        guard var components = URLComponents(string: raw),
              let items = components.queryItems, !items.isEmpty,
              items.allSatisfy({ sizingParameters.contains($0.name.lowercased()) })
        else { return raw }
        components.query = nil
        return components.string ?? raw
    }

    private static let sizingParameters: Set<String> = [
        "width", "height", "canvas", "optimize", "fit", "quality", "format", "bg-color", "auto"
    ]

    /// The store-view segment a typed URL names — `/de_en` in `subdued.com/de_en/` — or nil.
    static func storeView(of hint: URL?) -> String? {
        guard let first = hint?.pathComponents.first(where: { $0 != "/" }), LocaleTokens.isLocale(first)
        else { return nil }
        return "/" + first
    }

    private static func at(_ base: URL, path: String) -> URL? {
        var components = URLComponents(url: base, resolvingAgainstBaseURL: false)
        components?.path = path
        components?.query = nil
        return components?.url
    }
}

/// Reading a page that lists a shop's feeds — Magento's `/rss`, or any page whose links are
/// feeds.
enum FeedIndex {
    struct Link: Hashable {
        var url: URL
        /// What the page calls it: the link's own text, or, where that only says "Get Feed",
        /// the text just before it — Magento prints the name in the cell beside the link.
        var label: String

        var announcesProducts: Bool { FeedSource.announcesProducts(url: url, title: label) }

        var isCategory: Bool {
            let path = url.path.lowercased()
            return path.contains("/category/") || path.contains("/cid/")
        }
    }

    /// Every link on the page that is plainly a feed: Magento's `/rss/feed/…`, a file ending
    /// `.rss`, `.atom` or a feed-named `.xml`, and whatever the page declares as RSS or Atom.
    /// A bare `/rss` or `/feed` is not taken, because that is another index as often as a
    /// feed, and following one index to the next has no end.
    static func links(in html: String, base: URL) -> [Link] {
        var found: [Link] = []
        var seen: Set<String> = []
        for url in SiteAlternates.feeds(in: html, base: base) where seen.insert(url.absoluteString).inserted {
            found.append(Link(url: url, label: ""))
        }
        guard let pattern = try? NSRegularExpression(
            pattern: #"<a\b[^>]*\bhref\s*=\s*["']([^"']+)["'][^>]*>([\s\S]*?)</a>"#,
            options: [.caseInsensitive]
        ) else { return found }
        let range = NSRange(html.startIndex..<html.endIndex, in: html)
        for match in pattern.matches(in: html, range: range) {
            guard let hrefRange = Range(match.range(at: 1), in: html),
                  let textRange = Range(match.range(at: 2), in: html),
                  let whole = Range(match.range, in: html),
                  let url = URL(string: HTMLEntities.decode(String(html[hrefRange])), relativeTo: base)?.absoluteURL,
                  url.scheme == "https" || url.scheme == "http",
                  isFeed(url), !SiteAlternates.isCatalogueOrComments(url),
                  seen.insert(url.absoluteString).inserted
            else { continue }
            var label = text(String(html[textRange]))
            if isGeneric(label) {
                let reach = min(400, html.distance(from: html.startIndex, to: whole.lowerBound))
                let before = html[html.index(whole.lowerBound, offsetBy: -reach)..<whole.lowerBound]
                label = text(String(before))
                    .components(separatedBy: "\n")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .last { !$0.isEmpty } ?? ""
            }
            found.append(Link(url: url, label: label))
        }
        return found
    }

    /// The feeds worth a request, best first: new products, then new arrivals by name, then
    /// anything that is not a category; within each, the store view the preference likes
    /// best, ties in page order.
    static func choose(_ links: [Link], preferring preference: LocalePreference) -> [Link] {
        func rank(_ link: Link) -> Int? {
            let path = link.url.path.lowercased()
            if FeedSource.productPathMarkers.contains(where: path.contains) { return 0 }
            if FeedSource.namesNewProducts(link.label) { return 1 }
            return link.isCategory ? nil : 2
        }
        let ranked = links.enumerated().compactMap { index, link -> (link: Link, rank: Int, score: Int, index: Int)? in
            guard let rank = rank(link) else { return nil }
            return (link, rank, preference.score(LocaleTokens.read(path: link.url)), index)
        }
        return ranked
            .sorted { a, b in
                if a.rank != b.rank { return a.rank < b.rank }
                if a.score != b.score { return a.score > b.score }
                return a.index < b.index
            }
            .map(\.link)
    }

    static func isFeed(_ url: URL) -> Bool {
        let path = url.path.lowercased()
        if path.contains("/rss/feed/") { return true }
        if path.hasSuffix(".rss") || path.hasSuffix(".atom") { return true }
        if path.hasSuffix(".xml") {
            return ["rss", "atom", "feed"].contains { path.contains($0) }
        }
        return false
    }

    private static func isGeneric(_ label: String) -> Bool {
        let lowered = label.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        return lowered.isEmpty || ["get feed", "subscribe", "rss", "feed", "atom", "xml", "rss feed"].contains(lowered)
    }

    /// A fragment of HTML as its text, one line per tag boundary.
    private static func text(_ html: String) -> String {
        HTMLEntities.decode(
            html.replacingOccurrences(of: "<[^>]+>", with: "\n", options: .regularExpression)
        ).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Parser

public struct FeedEntry {
    var title: String = ""
    var link: String?
    var guid: String?
    var summary: String?
    var published: Date?
    var imageURL: String?

    var identity: String { guid ?? link ?? title }

    /// "FW26", "SS25", "Collection", "Lookbook" in a title is almost always a drop.
    var looksLikeCollection: Bool {
        let t = title.lowercased()
        if t.contains("collection") || t.contains("lookbook") || t.contains("capsule") { return true }
        return title.range(of: #"\b(FW|SS|AW)\s?\d{2}\b"#, options: [.regularExpression, .caseInsensitive]) != nil
    }
}

/// Handles both RSS 2.0 (`<item>`) and Atom (`<entry>`) with one pass.
public final class FeedParser: NSObject, XMLParserDelegate {
    private var entries: [FeedEntry] = []
    private var current: FeedEntry?
    private var text = ""
    private var insideEntry = false
    /// The feed's own title — `<channel><title>`, or Atom's `<feed><title>` — which is how a
    /// feed of new products names itself ("New Products from Subdued").
    public private(set) var channelTitle: String?

    public func parse(_ data: Data) -> [FeedEntry]? {
        entries = []
        current = nil
        channelTitle = nil
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.shouldProcessNamespaces = false
        guard parser.parse() else { return entries.isEmpty ? nil : entries }
        return entries
    }

    public func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        text = ""
        switch elementName.lowercased() {
        case "item", "entry":
            insideEntry = true
            current = FeedEntry()
        case "link" where insideEntry:
            // Atom puts the URL in an attribute; RSS puts it in the element body.
            if let href = attributeDict["href"],
               attributeDict["rel"] == nil || attributeDict["rel"] == "alternate" {
                current?.link = href
            }
        case "enclosure", "media:content", "media:thumbnail":
            if current?.imageURL == nil, let url = attributeDict["url"] {
                current?.imageURL = url
            }
        default:
            break
        }
    }

    public func parser(_ parser: XMLParser, foundCharacters string: String) {
        text += string
    }

    public func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        text += String(data: CDATABlock, encoding: .utf8) ?? ""
    }

    public func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        defer { text = "" }

        switch elementName.lowercased() {
        case "item", "entry":
            if var entry = current {
                if entry.imageURL == nil, let summary = entry.summary {
                    entry.imageURL = Self.firstImage(in: summary)
                }
                entries.append(entry)
            }
            current = nil
            insideEntry = false
        case "title" where insideEntry:
            current?.title = value
        case "title":
            if channelTitle == nil, !value.isEmpty { channelTitle = value }
        case "link" where insideEntry:
            if current?.link == nil, !value.isEmpty { current?.link = value }
        case "guid", "id":
            if insideEntry, !value.isEmpty { current?.guid = value }
        case "description", "summary", "content", "content:encoded":
            if insideEntry, current?.summary?.isEmpty != false { current?.summary = value }
        case "pubdate", "published", "updated":
            if insideEntry, current?.published == nil { current?.published = DateParsing.any(value) }
        default:
            break
        }
    }

    /// Feeds usually embed the hero shot as the first `<img>` in the description HTML.
    private static func firstImage(in html: String) -> String? {
        guard let match = html.range(of: #"<img[^>]+src=["']([^"']+)["']"#, options: .regularExpression) else {
            return nil
        }
        let tag = String(html[match])
        guard let srcRange = tag.range(of: #"(?<=src=["'])[^"']+"#, options: .regularExpression) else { return nil }
        return String(tag[srcRange])
    }
}

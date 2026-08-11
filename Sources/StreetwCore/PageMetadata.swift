// PageMetadata.swift
// What a URL is, when all we have is the URL.
//
// The share sheet hands over a link and, if we're lucky, a title. That is not enough to
// put on a wall — a saved item with no photograph is a bookmark, and the whole point of
// the collection is that it is visual. Open Graph is how every storefront already
// describes its own pages to Instagram and iMessage, so it is the same bargain as
// `BrandMark`: the site's own declared metadata, published for exactly this purpose.
//
// Portable on purpose. The share extension shouldn't do the fetching (it is memory
// limited and must return fast), so the app drains its inbox and enriches here — and
// the server could use the identical code for a "save by URL" endpoint later.

import Foundation

public struct PageMetadata: Sendable, Hashable {
    public var title: String?
    public var imageURL: URL?
    public var siteName: String?
    public var price: String?
    public var canonicalURL: URL?
    /// What the page says about stock, when it says anything.
    ///
    /// Nil means the page never declared it, which is genuinely different from "in stock"
    /// — a shared link with no availability must not be presented as buyable, and must not
    /// be presented as sold out either. Only an explicit declaration is acted on.
    public var isAvailable: Bool?

    public init(
        title: String? = nil,
        imageURL: URL? = nil,
        siteName: String? = nil,
        price: String? = nil,
        canonicalURL: URL? = nil,
        isAvailable: Bool? = nil
    ) {
        self.title = title
        self.imageURL = imageURL
        self.siteName = siteName
        self.price = price
        self.canonicalURL = canonicalURL
        self.isAvailable = isAvailable
    }

    public var isEmpty: Bool {
        title == nil && imageURL == nil && siteName == nil && price == nil
    }
}

public enum PageMetadataParser {
    public static func fetch(_ url: URL, http: any HTTPFetching = Net.live) async -> PageMetadata {
        guard let response = try? await http.get(url, etag: nil),
              response.status == 200,
              let html = String(data: response.data, encoding: .utf8)
        else { return PageMetadata() }
        return parse(html, base: response.finalURL ?? url)
    }

    public static func parse(_ html: String, base: URL) -> PageMetadata {
        let tags = metaTags(in: html)

        /// Open Graph first, then Twitter's equivalents, then the plain HTML name.
        /// Storefronts fill in whichever their theme happens to ship.
        func value(_ keys: [String]) -> String? {
            for key in keys {
                if let found = tags[key], !found.isEmpty { return decoded(found) }
            }
            return nil
        }

        var metadata = PageMetadata()
        metadata.title = value(["og:title", "twitter:title"]) ?? titleTag(in: html)
        metadata.siteName = value(["og:site_name", "twitter:site"])
        metadata.price = value([
            "og:price:amount", "product:price:amount", "twitter:data1"
        ]).map { amount -> String in
            let currency = value(["og:price:currency", "product:price:currency"])
            return [amount, currency].compactMap { $0 }.joined(separator: " ")
        }

        if let image = value(["og:image:secure_url", "og:image", "twitter:image"]),
           let url = URL(string: image, relativeTo: base)?.absoluteURL,
           url.scheme == "http" || url.scheme == "https" {
            metadata.imageURL = url
        }
        // A share sheet often hands over a URL carrying tracking parameters; the
        // canonical one is what dedupes a second save of the same product.
        if let canonical = linkHref(rel: "canonical", in: html),
           let url = URL(string: canonical, relativeTo: base)?.absoluteURL {
            metadata.canonicalURL = url
        }
        // schema.org's vocabulary, which is what both Open Graph product tags and JSON-LD
        // use: "InStock", "OutOfStock", "https://schema.org/InStock", "oos", "instock".
        // Only an explicit statement counts — an absent tag stays nil rather than being
        // read as available, because presenting a sold-out thing as buyable is the more
        // annoying half of getting this wrong.
        if let raw = value(["product:availability", "og:availability", "availability"]) {
            metadata.isAvailable = Self.availability(from: raw)
        }
        return metadata
    }

    static func availability(from raw: String) -> Bool? {
        let lowered = raw.lowercased()
        if lowered.contains("outofstock") || lowered.contains("out_of_stock")
            || lowered.contains("out of stock") || lowered.contains("soldout")
            || lowered.contains("sold_out") || lowered.contains("sold out")
            || lowered.contains("discontinued") {
            return false
        }
        if lowered.contains("instock") || lowered.contains("in_stock")
            || lowered.contains("in stock") || lowered.contains("limitedavailability")
            || lowered.contains("preorder") || lowered.contains("backorder") {
            return true
        }
        return nil
    }

    // MARK: - Scraping the head

    /// `property`/`name` → `content`, for every `<meta>` in the document.
    private static func metaTags(in html: String) -> [String: String] {
        guard let pattern = try? NSRegularExpression(pattern: "<meta\\b[^>]*>", options: [.caseInsensitive])
        else { return [:] }

        var tags: [String: String] = [:]
        let range = NSRange(html.startIndex..<html.endIndex, in: html)
        for match in pattern.matches(in: html, range: range) {
            guard let tagRange = Range(match.range, in: html) else { continue }
            let tag = String(html[tagRange])
            // `property` is Open Graph, `name` is Twitter and plain HTML. Either can
            // name the value, so whichever is present wins.
            guard let key = attribute("property", in: tag) ?? attribute("name", in: tag),
                  let content = attribute("content", in: tag)
            else { continue }
            // First occurrence wins: themes sometimes emit a generic tag after the
            // specific one, and the specific one is nearer the top.
            if tags[key.lowercased()] == nil { tags[key.lowercased()] = content }
        }
        return tags
    }

    private static func linkHref(rel: String, in html: String) -> String? {
        guard let pattern = try? NSRegularExpression(pattern: "<link\\b[^>]*>", options: [.caseInsensitive])
        else { return nil }
        let range = NSRange(html.startIndex..<html.endIndex, in: html)
        for match in pattern.matches(in: html, range: range) {
            guard let tagRange = Range(match.range, in: html) else { continue }
            let tag = String(html[tagRange])
            if attribute("rel", in: tag)?.lowercased() == rel, let href = attribute("href", in: tag) {
                return href
            }
        }
        return nil
    }

    private static func titleTag(in html: String) -> String? {
        guard let pattern = try? NSRegularExpression(
            pattern: "<title[^>]*>([\\s\\S]*?)</title>",
            options: [.caseInsensitive]
        ) else { return nil }
        let range = NSRange(html.startIndex..<html.endIndex, in: html)
        guard let match = pattern.firstMatch(in: html, range: range),
              let titleRange = Range(match.range(at: 1), in: html)
        else { return nil }
        let title = decoded(String(html[titleRange]).trimmingCharacters(in: .whitespacesAndNewlines))
        return title.isEmpty ? nil : title
    }

    private static func attribute(_ name: String, in tag: String) -> String? {
        guard let pattern = try? NSRegularExpression(
            pattern: "\\b\(name)\\s*=\\s*(\"([^\"]*)\"|'([^']*)'|([^\\s>]+))",
            options: [.caseInsensitive]
        ) else { return nil }
        let range = NSRange(tag.startIndex..<tag.endIndex, in: tag)
        guard let match = pattern.firstMatch(in: tag, range: range) else { return nil }
        return [2, 3, 4]
            .compactMap { Range(match.range(at: $0), in: tag) }
            .first
            .map { String(tag[$0]) }
    }

    /// Titles routinely arrive as "Nike Dunk &amp; Co &#8211; Kith".
    private static func decoded(_ raw: String) -> String {
        var value = raw
        let entities = [
            "&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"",
            "&#39;": "'", "&apos;": "'", "&nbsp;": " ",
            "&#8211;": "–", "&ndash;": "–", "&#8212;": "—", "&mdash;": "—",
            "&#8217;": "'", "&rsquo;": "'", "&#8216;": "'", "&lsquo;": "'"
        ]
        for (entity, character) in entities {
            value = value.replacingOccurrences(of: entity, with: character)
        }
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

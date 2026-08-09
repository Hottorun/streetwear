// FeedSource.swift
// RSS / Atom reader for brand journals, lookbooks and news pages.
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
        guard response.status == 200 else { throw SourceError.badResponse(response.status) }

        let parser = FeedParser()
        guard let entries = parser.parse(response.data), !entries.isEmpty else {
            throw SourceError.emptyPayload
        }

        let items = entries.map { entry in
            FetchedItem(
                externalID: "feed:\(entry.identity)",
                title: entry.title,
                summary: entry.summary.map(ShopifySource.plainText(from:)),
                linkURL: entry.link.flatMap(URL.init(string:)),
                imageURLStrings: [entry.imageURL].compactMap { $0 },
                publishedAt: entry.published ?? Date(),
                kind: entry.looksLikeCollection ? .collection : .post
            )
        }
        return FetchResult(items: items, etag: response.etag)
    }

    /// Probe the conventional feed paths when adding a brand.
    public static func detect(at base: URL, http: any HTTPFetching = Net.live) async -> URL? {
        let candidates = ["/blogs/news.atom", "/blogs/journal.atom", "/feed", "/rss", "/feed.xml", "/atom.xml"]
        for path in candidates {
            var components = URLComponents(url: base, resolvingAgainstBaseURL: false)
            components?.path = path
            components?.query = nil
            guard let url = components?.url,
                  let response = try? await http.get(url), response.status == 200,
                  let entries = FeedParser().parse(response.data), !entries.isEmpty
            else { continue }
            return url
        }
        return nil
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

    public func parse(_ data: Data) -> [FeedEntry]? {
        entries = []
        current = nil
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

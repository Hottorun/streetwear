// BrandMark.swift
// Finding a brand's logo without asking anyone for it.
//
// Every storefront already publishes its own mark, in a tag that exists for exactly this
// purpose: `<link rel="apple-touch-icon">`, the icon a phone uses when the site is saved
// to a home screen. It is the brand's own file, served deliberately, at a size meant to
// be looked at. That makes it the honest source for a logo — no third-party logo API, no
// scraping a page for the largest image and hoping.
//
// Order of preference is by intent, then by size: an apple-touch-icon is chosen and
// square, a favicon is an afterthought, and `/favicon.ico` is the last resort every site
// answers. `mask-icon` is skipped — it is a monochrome silhouette for Safari's tab bar
// and renders as a black blob.

import Foundation

public enum BrandMark {
    /// Fetches the homepage and returns the best icon it declares.
    public static func discover(at base: URL, http: any HTTPFetching = Net.live) async -> URL? {
        guard let response = try? await http.get(base, etag: nil),
              response.status == 200,
              let html = String(data: response.data, encoding: .utf8)
        else {
            return fallback(for: base)
        }
        // `finalURL` matters: a redirect to www. or to a regional domain makes every
        // relative href resolve against the wrong host.
        let resolved = response.finalURL ?? base
        return find(in: html, base: resolved) ?? fallback(for: resolved)
    }

    /// Every site answers this path, so it is the floor rather than a guess.
    public static func fallback(for base: URL) -> URL? {
        URL(string: "/favicon.ico", relativeTo: base)?.absoluteURL
    }

    public static func find(in html: String, base: URL) -> URL? {
        let candidates = links(in: html).compactMap { link -> Candidate? in
            let rel = link["rel"]?.lowercased() ?? ""
            guard rel.contains("icon"), !rel.contains("mask-icon") else { return nil }
            guard let href = link["href"], !href.isEmpty else { return nil }
            guard let url = URL(string: href, relativeTo: base)?.absoluteURL else { return nil }

            // A data: URI is an inlined icon we can't hand to an image loader.
            guard url.scheme == "http" || url.scheme == "https" else { return nil }

            return Candidate(
                url: url,
                isAppleTouch: rel.contains("apple-touch-icon"),
                pixels: largestDimension(link["sizes"]),
                isVector: href.lowercased().contains(".svg")
            )
        }

        return candidates.max(by: Candidate.isWorse)?.url
    }

    private struct Candidate {
        var url: URL
        var isAppleTouch: Bool
        var pixels: Int
        var isVector: Bool

        /// True when `a` is the weaker choice. Intent first, then resolution — a vector
        /// counts as large because it scales to whatever the view needs.
        static func isWorse(_ a: Candidate, _ b: Candidate) -> Bool {
            if a.isAppleTouch != b.isAppleTouch { return b.isAppleTouch }
            let aSize = a.isVector ? max(a.pixels, 512) : a.pixels
            let bSize = b.isVector ? max(b.pixels, 512) : b.pixels
            return aSize < bSize
        }
    }

    /// "180x180" -> 180, "any" -> a high number, missing -> 0.
    private static func largestDimension(_ sizes: String?) -> Int {
        guard let sizes = sizes?.lowercased() else { return 0 }
        if sizes.contains("any") { return 1_024 }
        return sizes
            .split(whereSeparator: { $0 == " " || $0 == "x" })
            .compactMap { Int($0) }
            .max() ?? 0
    }

    /// Pulls the attributes out of every `<link>` tag. Regex rather than a parser
    /// because this is one flat, well-formed tag shape and the alternative is a
    /// dependency; the rest of the document is deliberately never touched.
    private static func links(in html: String) -> [[String: String]] {
        guard let tagPattern = try? NSRegularExpression(pattern: "<link\\b[^>]*>", options: [.caseInsensitive]),
              let attrPattern = try? NSRegularExpression(
                pattern: "([a-zA-Z-]+)\\s*=\\s*(\"([^\"]*)\"|'([^']*)'|([^\\s>]+))",
                options: []
              )
        else { return [] }

        let range = NSRange(html.startIndex..<html.endIndex, in: html)
        return tagPattern.matches(in: html, range: range).map { match in
            guard let tagRange = Range(match.range, in: html) else { return [:] }
            let tag = String(html[tagRange])
            let tagNSRange = NSRange(tag.startIndex..<tag.endIndex, in: tag)

            var attributes: [String: String] = [:]
            for attribute in attrPattern.matches(in: tag, range: tagNSRange) {
                guard let nameRange = Range(attribute.range(at: 1), in: tag) else { continue }
                let value = [3, 4, 5]
                    .compactMap { Range(attribute.range(at: $0), in: tag) }
                    .first
                    .map { String(tag[$0]) }
                attributes[String(tag[nameRange]).lowercased()] = value ?? ""
            }
            return attributes
        }
    }
}

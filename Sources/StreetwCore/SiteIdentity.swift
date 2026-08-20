// SiteIdentity.swift
// What a brand is called, and what its mark is — from the site's own words.
//
// The hostname is a terrible name and was never meant to be one. Splitting it on dots and
// capitalising the first label produced "Usa" for `usa.palaceskateboards.com` and
// "Bbcicecream" for Billionaire Boys Club, and the second person to add either of those
// inherits whatever the first person could be bothered to correct.
//
// Meanwhile every storefront already declares its name, twice, for other people's link
// previews:
//
//     <meta property="og:site_name" content="Billionaire Boys Club">
//     <title>PALACE SKATEBOARDS</title>
//
// Both were sitting in the homepage HTML that `BrandMark` was **already fetching** to find
// the logo and then throwing away. So this reads both out of one response: one request,
// two answers, and the hostname demoted to what it should always have been — the last
// resort when a site says nothing about itself.

import Foundation

/// A brand's own account of itself.
public struct SiteIdentity: Sendable, Hashable {
    public var name: String?
    public var logoURL: URL?

    public init(name: String? = nil, logoURL: URL? = nil) {
        self.name = name
        self.logoURL = logoURL
    }
}

public enum SiteIdentityProbe {
    /// One homepage fetch, both answers.
    public static func discover(at base: URL, http: any HTTPFetching = Net.live) async -> SiteIdentity {
        guard let response = try? await http.get(base, etag: nil),
              response.status == 200,
              let html = String(data: response.data, encoding: .utf8)
        else {
            return SiteIdentity(logoURL: BrandMark.fallback(for: base))
        }
        // `finalURL` matters: a redirect to www. or to a regional domain makes every
        // relative href resolve against the wrong host.
        let resolved = response.finalURL ?? base
        return SiteIdentity(
            name: BrandNaming.declaredName(in: html),
            logoURL: BrandMark.find(in: html, base: resolved) ?? BrandMark.fallback(for: resolved)
        )
    }
}

public enum BrandNaming {
    /// The name to suggest, in descending order of how deliberately it was written to *be*
    /// the brand's name.
    ///
    /// A Shopify store's `/meta.json` name is the merchant's own setting and outranks
    /// everything; `og:site_name` is the same claim made to link previews; the `<title>`
    /// is the same claim with marketing attached. The hostname says nothing and comes last.
    public static func pick(shopName: String? = nil, siteName: String? = nil, host: String?) -> String? {
        for candidate in [shopName, siteName] {
            if let cleaned = candidate.flatMap(tidy) { return cleaned }
        }
        return host.flatMap(fromHost)
    }

    /// `og:site_name`, then the `<title>` with its marketing tail removed.
    public static func declaredName(in html: String) -> String? {
        if let declared = metaContent(property: "og:site_name", in: html)
            ?? metaContent(property: "application-name", in: html),
           let cleaned = tidy(declared) {
            return cleaned
        }
        return titleTag(in: html).flatMap(fromTitle)
    }

    /// "Billionaire Boys Club & ICECREAM | US Official Site" → "Billionaire Boys Club &
    /// ICECREAM". "Kith – Homepage" → "Kith".
    ///
    /// Titles are written for search engines, so the brand is at the front and everything
    /// after the first separator is a slogan. A leading segment that is itself generic —
    /// "Home", "Shop", "Official Site" — is rejected rather than adopted, because a brand
    /// called Home is worse than no suggestion at all.
    static func fromTitle(_ raw: String) -> String? {
        // Decoded *before* splitting, not after: themes write the separator itself as an
        // entity — "Kith &ndash; Homepage" — so a split on the literal character finds
        // nothing and the slogan survives into the name.
        let decoded = decodeEntities(raw)
        let separators: [Character] = ["|", "–", "—", "·", "•", ":"]
        let head = decoded.split(whereSeparator: { separators.contains($0) }).first.map(String.init) ?? decoded
        guard let cleaned = tidy(head), !isGeneric(cleaned) else { return nil }
        return cleaned
    }

    /// The last resort, made available to callers that only ever have a hostname.
    ///
    /// A saved link from a brand nobody follows has no other source of a name until the
    /// site has been probed, and "Gvgallery" over a photograph is a great deal better than
    /// nothing over a photograph.
    public static func hostName(of host: String) -> String? {
        fromHost(host)
    }

    /// The last resort. Drops the subdomains that are never part of a brand's name —
    /// regions especially, which is where "Usa" came from — and takes the registrable
    /// label rather than the first one.
    static func fromHost(_ host: String) -> String? {
        // Not a public-suffix list, and doesn't need to be: this drops *leading* labels
        // it recognises and then takes the first of what's left, so "brand.co.uk" yields
        // "brand" without knowing anything about "co.uk".
        let noise: Set<String> = [
            "www", "www2", "shop", "store", "shops", "m", "mobile", "eu", "us", "usa",
            "uk", "ca", "au", "de", "fr", "jp", "en", "int", "global", "online"
        ]
        var labels = host.lowercased().split(separator: ".").map(String.init)
        while labels.count > 2, let first = labels.first, noise.contains(first) {
            labels.removeFirst()
        }
        guard let first = labels.first, !first.isEmpty else { return nil }
        return first.capitalized
    }

    /// Trims, collapses whitespace, decodes the handful of entities that turn up in a
    /// `<title>`, and evens out a name shouted in capitals.
    public static func tidy(_ raw: String) -> String? {
        var text = decodeEntities(raw)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        // "PALACE SKATEBOARDS" is a logotype, not a name to store — every place this is
        // drawn already decides its own case. A single shouted word is left alone, because
        // "KITH" and "BAPE" are how those are written and title-casing them is wrong.
        if text == text.uppercased(), text.contains(" ") {
            text = text.capitalized
        }
        return text
    }

    private static func isGeneric(_ name: String) -> Bool {
        let lowered = name.lowercased()
        let generic: Set<String> = [
            "home", "homepage", "shop", "store", "official site", "official store",
            "welcome", "index", "online store", "main", "coming soon"
        ]
        return generic.contains(lowered)
    }

    // MARK: - Scraping

    /// `dotMatchesLineSeparators` because a `<title>` is routinely broken across lines by
    /// a templating engine, and without it those titles simply aren't found.
    static func titleTag(in html: String) -> String? {
        guard let expression = try? NSRegularExpression(
            pattern: "<title[^>]*>(.*?)</title>",
            options: [.caseInsensitive, .dotMatchesLineSeparators]
        ),
            let match = expression.firstMatch(
                in: html,
                range: NSRange(html.startIndex..<html.endIndex, in: html)
            ),
            let range = Range(match.range(at: 1), in: html)
        else { return nil }
        return String(html[range])
    }

    /// One meta tag by `property` or `name`, in either attribute order — themes write it
    /// both ways and matching only one silently loses half of them.
    static func metaContent(property: String, in html: String) -> String? {
        let key = NSRegularExpression.escapedPattern(for: property)
        let patterns = [
            "<meta[^>]+(?:property|name)\\s*=\\s*[\"']\(key)[\"'][^>]*content\\s*=\\s*[\"']([^\"']*)[\"']",
            "<meta[^>]+content\\s*=\\s*[\"']([^\"']*)[\"'][^>]*(?:property|name)\\s*=\\s*[\"']\(key)[\"']"
        ]
        for pattern in patterns {
            guard let expression = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
                  let match = expression.firstMatch(
                    in: html,
                    range: NSRange(html.startIndex..<html.endIndex, in: html)
                  ),
                  let range = Range(match.range(at: 1), in: html)
            else { continue }
            let value = String(html[range])
            if !value.isEmpty { return value }
        }
        return nil
    }

    private static func decodeEntities(_ text: String) -> String {
        HTMLEntities.decode(text)
    }
}

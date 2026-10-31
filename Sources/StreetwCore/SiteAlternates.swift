// SiteAlternates.swift
// What a homepage says about its other copies: the shop it runs for each country, in its
// `hreflang` alternates, and the feeds it advertises for readers.
//
// Both are read out of the homepage `SiteIdentityProbe` already fetches for the name and the
// mark, so knowing them costs no request. They are the brand's own declaration, on its own
// homepage, made for search engines that will send real shoppers to whichever copy it names —
// a site that lies there sends its own customers to the wrong shop — which is why
// `CountryShops` on the server is willing to act on them without anybody reading them first.

import Foundation

/// One `<link rel="alternate" hreflang="…" href="…">`: a copy of the site for a language, and
/// optionally a country.
public struct LanguageAlternate: Sendable, Hashable, Codable {
    /// As the page wrote it, lowercased: `en-us`, `de`, `x-default`.
    public var code: String
    /// The language subtag, lowercased — nil for `x-default`.
    public var language: String?
    /// The country subtag as an ISO code — nil for a language-only code (`en`, `fr`), for a
    /// numeric region (`es-419`) and for `x-default`.
    public var country: String?
    public var url: URL

    public init(code: String, language: String?, country: String?, url: URL) {
        self.code = code
        self.language = language
        self.country = country
        self.url = url
    }

    /// The copy a search engine sends anybody no other alternate matches. Never a country's.
    public var isDefault: Bool { code == "x-default" }

    /// Reads `en-US`, `en_gb`, `zh-Hant-TW`, `x-default`. Nil for anything with no language.
    public init?(code raw: String, url: URL) {
        let code = raw.trimmingCharacters(in: .whitespaces).lowercased()
        guard !code.isEmpty else { return nil }
        if code == "x-default" {
            self.init(code: code, language: nil, country: nil, url: url)
            return
        }
        let subtags = code.split(whereSeparator: { $0 == "-" || $0 == "_" }).map(String.init)
        guard let language = subtags.first,
              (2...3).contains(language.count),
              language.allSatisfy({ $0.isLetter && $0.isASCII })
        else { return nil }
        // The region is the first two-letter subtag after the language; a four-letter one is
        // a script (`Hant`) and a three-digit one a UN region (`419`), neither a country.
        let region = subtags.dropFirst().first { $0.count == 2 && $0.allSatisfy(\.isLetter) }
        self.init(code: code, language: language, country: CountryCode.normalized(region), url: url)
    }
}

public enum SiteAlternates {
    /// Every `hreflang` alternate on the page, in document order, resolved against `base`.
    /// Only http(s) targets; a page listing one code twice keeps the first.
    public static func languages(in html: String, base: URL) -> [LanguageAlternate] {
        var seen: Set<String> = []
        return BrandMark.links(in: html).compactMap { link -> LanguageAlternate? in
            guard relations(link).contains("alternate"),
                  let code = link["hreflang"],
                  let url = resolved(link["href"], against: base),
                  let alternate = LanguageAlternate(code: code, url: url),
                  seen.insert(alternate.code).inserted
            else { return nil }
            return alternate
        }
    }

    /// The RSS and Atom feeds the page declares with `<link rel="alternate" type="…">`.
    ///
    /// **A collection's or a product's Atom feed is not one.** A Shopify theme can declare
    /// `/collections/all.atom`, which is the catalogue itself in another encoding; read as a
    /// feed it would put every product in somebody's feed a second time, as posts. Comment
    /// feeds go the same way — they are replies, not anything a brand published.
    public static func feeds(in html: String, base: URL) -> [URL] {
        var seen: Set<String> = []
        return BrandMark.links(in: html).compactMap { link -> URL? in
            guard relations(link).contains("alternate"),
                  let type = link["type"]?.lowercased(),
                  type.contains("rss+xml") || type.contains("atom+xml"),
                  let url = resolved(link["href"], against: base),
                  !isCatalogueOrComments(url),
                  seen.insert(url.absoluteString).inserted
            else { return nil }
            return url
        }
    }

    static func isCatalogueOrComments(_ url: URL) -> Bool {
        let path = url.path.lowercased()
        return path.contains("/collections/") || path.contains("/products")
            || path.contains("comments")
    }

    private static func relations(_ link: [String: String]) -> Set<String> {
        Set((link["rel"] ?? "").lowercased().split(separator: " ").map(String.init))
    }

    private static func resolved(_ href: String?, against base: URL) -> URL? {
        guard let href = href.map(HTMLEntities.decode)?.trimmingCharacters(in: .whitespaces),
              !href.isEmpty,
              let url = URL(string: href, relativeTo: base)?.absoluteURL,
              url.scheme == "https" || url.scheme == "http"
        else { return nil }
        return url
    }
}

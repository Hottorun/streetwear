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
            name: BrandNaming.declaredName(in: html, host: resolved.host() ?? base.host()),
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
        // The marketing tail is stripped from **all three** claims, not only the `<title>`.
        //
        // A merchant's own Shopify setting was treated as beyond question, and it is not:
        // `/meta.json` says "REPRESENT | US" and `og:site_name` says the same, because the
        // field is what appears in their tab and their checkout, where the region matters.
        // On a brand row it is a wordmark with a country stapled to it, and it outranked
        // everything so nothing else could correct it.
        //
        // Only the pipe-and-dash family splits — a plain hyphen deliberately does not, so
        // "SNS - Sneakersnstuff" and "A-COLD-WALL*" survive intact. Splitting those would
        // trade one wrong name for another.
        //
        // A **handle** is refused at every tier, the way a generic title is. The catalogue
        // is global, so one shop whose `/meta.json` holds its own slug becomes that slug for
        // everybody: `norseprojects-webshop` shipped as the brand name on a Discover release
        // card, on the tab whose entire job is introducing labels. It got past every rule
        // here because nothing was wrong with it as a *string* — it is lower case, has no
        // marketing tail and is not the word "Home".
        //
        // And a **description** is refused the same way, unless it is also the domain. See
        // `isDescriptive` for the shop that taught it.
        for candidate in [shopName, siteName] {
            if let cleaned = candidate.flatMap({ withoutTail($0, host: host) }),
               !looksLikeHandle(cleaned),
               isUsable(cleaned, host: host) {
                return cleaned
            }
        }
        return host.flatMap(fromHost)
    }

    /// Whether a candidate can stand as a brand's name at all.
    ///
    /// A name the domain agrees with is believed whatever words are in it — "Fashion Nova"
    /// on `fashionnova.com` is a brand, not a description. Anything else must read like a
    /// name rather than like the sentence a search engine was fed.
    static func isUsable(_ name: String, host: String?) -> Bool {
        guard !isGeneric(name) else { return false }
        if let label = host.flatMap(domainLabel), naming(name, label: label) != nil { return true }
        return !isDescriptive(name)
    }

    /// Whether a candidate describes the shop's stock rather than naming the shop.
    ///
    /// **Hollister's homepage title is "Clothing for Women & Men | Teen Clothing | Hollister
    /// Co."** with no `og:site_name` beside it, and the first-segment rule offered "Clothing
    /// for Women & Men" as the brand. The catalogue is global and the add screen shows the
    /// name rather than asking for it, so whoever added the shop first would have named it
    /// that for everybody — and a page-watched shop has no `/meta.json` to correct it later.
    /// "Home" and "Official Site" were refused because they are generic; this is the same
    /// failure in a longer sentence.
    ///
    /// The test is for the *nouns of a catalogue* — what is sold and where — never for who
    /// it is sold to. "Boys" is in Billionaire Boys Club's name and "Women" is in nobody's
    /// brand; reading audience words as descriptions would refuse a real name to catch a
    /// title that the category noun beside it already gives away. A name that happens to
    /// contain one of these is still accepted when the domain agrees with it (`isUsable`).
    static func isDescriptive(_ name: String) -> Bool {
        let tokens = name.lowercased().split { !$0.isLetter }.map(String.init)
        return tokens.contains(where: catalogueNouns.contains)
    }

    private static let catalogueNouns: Set<String> = [
        "clothing", "clothes", "apparel", "fashion", "footwear", "shoes", "sneakers",
        "trainers", "accessories", "jewelry", "jewellery", "lingerie", "underwear", "swimwear",
        "sportswear", "activewear", "streetwear", "menswear", "womenswear", "outerwear",
        "dresses", "outfits", "online", "official", "shop", "shopping", "store", "outlet",
        "sale", "collection", "collections", "arrivals", "shipping", "website", "homepage"
    ]

    /// The part of a host that a brand's name should agree with: `hollisterco` for
    /// `www.hollisterco.com`, `brand` for `eu.brand.co.uk`, already folded for comparison.
    static func domainLabel(of host: String) -> String? {
        let registrable = BrandDiscovery.registrableDomain(of: host)
        guard let first = registrable.split(separator: ".").first else { return nil }
        let label = comparable(String(first))
        return label.count >= 3 ? label : nil
    }

    /// The candidate as it should be stored, when it names the domain — trying it whole
    /// first and then without the shopfront words at its edges, so "Official Carhartt WIP
    /// Store UK" still finds "Carhartt WIP" on `carhartt-wip.com`. Nil when it does not.
    ///
    /// A match is the whole label, or a prefix of it at least four letters long: "Hollister
    /// Co." is `hollisterco` exactly, "Palace" is the front of `palaceskateboards`, and
    /// "Hollister" the front of `hollisterco`. Never the other way round — a candidate
    /// that merely *starts* with the label carries something after it, and that something
    /// is usually the slogan this is trying to drop.
    static func naming(_ candidate: String, label: String) -> String? {
        func matches(_ text: String) -> Bool {
            let folded = comparable(text)
            guard folded.count >= 3 else { return false }
            return folded == label || (folded.count >= 4 && label.hasPrefix(folded))
        }
        if matches(candidate) { return candidate }
        let stripped = withoutShopfrontWords(candidate)
        if stripped != candidate, !stripped.isEmpty, matches(stripped) { return stripped }
        return nil
    }

    /// Strips the words a storefront wraps around its own name — "Official", "Store", a
    /// region — from both ends, never from the middle.
    private static func withoutShopfrontWords(_ text: String) -> String {
        var words = text.split(separator: " ").map(String.init)
        func isShopfront(_ word: String) -> Bool {
            shopfrontWords.contains(word.lowercased().trimmingCharacters(in: .punctuationCharacters))
        }
        while let first = words.first, isShopfront(first) { words.removeFirst() }
        while let last = words.last, isShopfront(last) { words.removeLast() }
        return words.joined(separator: " ")
    }

    private static let shopfrontWords: Set<String> = [
        "official", "store", "shop", "online", "site", "website", "webshop", "the",
        "us", "usa", "uk", "eu", "ca", "au", "de", "fr", "it", "es", "nl", "en",
        "global", "intl", "international"
    ]

    /// Lower case, accents folded, letters and digits only — the shape a domain label has.
    ///
    /// The accents are folded from a table rather than through `String.folding`, which is
    /// one more Foundation surface whose Linux behaviour only the deploy would reveal.
    /// "Stüssy" has to meet `stussy.com`; the table covers the Latin letters brand names
    /// actually use, and anything outside it is simply dropped, which costs a match and
    /// never makes a wrong one.
    static func comparable(_ text: String) -> String {
        var out = ""
        for character in text.lowercased() {
            if let folded = accentFolds[character] {
                out += folded
            } else if character.isASCII, character.isLetter || character.isNumber {
                out.append(character)
            }
        }
        return out
    }

    private static let accentFolds: [Character: String] = [
        "à": "a", "á": "a", "â": "a", "ã": "a", "ä": "a", "å": "a", "æ": "ae",
        "ç": "c", "č": "c", "ď": "d", "è": "e", "é": "e", "ê": "e", "ë": "e", "ě": "e",
        "ì": "i", "í": "i", "î": "i", "ï": "i", "ł": "l", "ñ": "n", "ň": "n",
        "ò": "o", "ó": "o", "ô": "o", "õ": "o", "ö": "o", "ø": "o", "ő": "o", "œ": "oe",
        "ř": "r", "š": "s", "ß": "ss", "ť": "t", "ù": "u", "ú": "u", "û": "u", "ü": "u",
        "ů": "u", "ű": "u", "ý": "y", "ÿ": "y", "ž": "z"
    ]

    /// Whether a candidate is a platform **handle** rather than a name somebody wrote.
    ///
    /// The test is the shape of the string, because that is the only evidence there is: a
    /// display name is written for people and gets capitals and spaces, while a handle is
    /// written for a URL and gets neither. So: entirely lower case, no spaces, and either
    /// hyphen- or underscore-joined, or naming the platform outright.
    ///
    /// Deliberately narrow. A single lower-case word — "bbcicecream", "noah" — is left alone,
    /// because plenty of brands really are written that way and there is nothing else to go
    /// on. What it costs when it is wrong is one tier: the next claim down (`og:site_name`,
    /// the `<title>`, the host) answers instead, and all three are also the brand describing
    /// itself.
    static func looksLikeHandle(_ name: String) -> Bool {
        let lowered = name.lowercased()
        guard name == lowered, !name.contains(" "), name.count > 3 else { return false }
        if lowered.contains("myshopify") { return true }
        return lowered.contains("-") || lowered.contains("_")
    }

    /// A name with everything after the first strong separator removed, where what is left
    /// is still a name. Falls back to the whole thing rather than to nothing.
    ///
    /// With a host, the segment that names the domain is taken wherever it sits — "Home |
    /// Palace" is Palace — and only otherwise the first.
    static func withoutTail(_ raw: String, host: String? = nil) -> String? {
        guard let whole = tidy(raw) else { return nil }
        let parts = segments(of: raw)
        if let label = host.flatMap(domainLabel),
           let named = parts.lazy.compactMap({ naming($0, label: label) }).first {
            return named
        }
        guard let head = parts.first, !isGeneric(head) else { return whole }
        return head
    }

    /// `og:site_name`, then the `<title>` with its marketing tail removed.
    ///
    /// `host` is the site's own, and lets the title be read for the segment that names it
    /// rather than for whichever came first — see `fromTitle`.
    public static func declaredName(in html: String, host: String? = nil) -> String? {
        if let declared = metaContent(property: "og:site_name", in: html)
            ?? metaContent(property: "application-name", in: html),
           let cleaned = tidy(declared),
           isUsable(cleaned, host: host) {
            return cleaned
        }
        return titleTag(in: html).flatMap { fromTitle($0, host: host) }
    }

    /// "Billionaire Boys Club & ICECREAM | US Official Site" → "Billionaire Boys Club &
    /// ICECREAM". "Kith – Homepage" → "Kith".
    ///
    /// Titles are written for search engines, so the brand is usually at the front and
    /// everything after the first separator is a slogan. A leading segment that is itself
    /// generic — "Home", "Shop", "Official Site" — is rejected rather than adopted, because
    /// a brand called Home is worse than no suggestion at all, and so is one that reads as
    /// a description of the stock (`isDescriptive`).
    ///
    /// **Usually, not always: some titles put the brand last.** "Clothing for Women & Men |
    /// Teen Clothing | Hollister Co." is SEO-first, and the name is the segment that agrees
    /// with the domain. So when the host is known, that segment wins wherever it sits; the
    /// first segment is only the answer when none of them names the site. Later segments are
    /// never taken *without* the domain's agreement — "Home | Made in Portugal" would
    /// otherwise make a slogan a brand.
    static func fromTitle(_ raw: String, host: String? = nil) -> String? {
        let parts = segments(of: raw)
        if let label = host.flatMap(domainLabel),
           let named = parts.lazy.compactMap({ naming($0, label: label) }).first {
            return named
        }
        guard let head = parts.first, !isGeneric(head), !isDescriptive(head) else { return nil }
        return head
    }

    /// A title cut at its strong separators, each piece tidied.
    private static func segments(of raw: String) -> [String] {
        // Decoded *before* splitting, not after: themes write the separator itself as an
        // entity — "Kith &ndash; Homepage" — so a split on the literal character finds
        // nothing and the slogan survives into the name.
        let decoded = decodeEntities(raw)
        let separators: [Character] = ["|", "–", "—", "·", "•", ":"]
        return decoded
            .split(whereSeparator: { separators.contains($0) })
            .compactMap { tidy(String($0)) }
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

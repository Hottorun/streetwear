// SitemapChoice.swift
// Which of a sitemap index's children are worth a request.
//
// A real retailer's sitemap is a tree, and the tree is cut two ways at once. By **kind** —
// products, categories, pages, a blog — and by **storefront** — one copy per country and
// language. Victoria's Secret publishes an index of fifty-five locale indexes, each listing
// twelve files of which one is products; Hollister one index of forty-eight, sixteen product
// files for sixteen store-and-language pairs; Subdued twenty-five per-store sitemaps named
// only in robots.txt. Reading "the first three children" picked nl/at/au on one and three
// copies of the same catalogue on another, and the products a person in New York would buy
// were in neither.
//
// So a level is read in three cuts, and only the last one can multiply requests:
//
// 1. **Kind.** Children named for products win outright; unnamed ones are read only when
//    nothing says products; children named for anything else — categories, pages, the blog
//    — never are. Whole tokens, never substrings: "sitemap" contains "item".
// 2. **Storefront.** Among what is left, siblings that differ by locale are *alternatives*,
//    and one of them is chosen (`LocalePreference`). The same goes for siblings at one path
//    that differ only by a non-paging query — Hollister's `?targetStoreId=…&targetLangId=…`
//    names a store, not a page.
// 3. **Parts.** What remains is one storefront's catalogue split across files —
//    `product-1.xml`, `product-2.xml`, `?from=1&to=999` — and every part is read, within the
//    caller's budget, because new products are as likely to be in the last part as the first.

import Foundation

/// The country and language a brand's storefront serves, as far as its URL says.
///
/// Read off the host first (`usa.`, `uk.`, a ccTLD) and the path second (`/us/`, `/en-gb/`,
/// `/eu_en/`), and otherwise **en-US**. Not because the app is American — Phase 2 makes
/// location a setting — but because a default has to be one storefront rather than all of
/// them, and English-US is the copy most often complete. Each brand's choice is made once,
/// at discovery, and pinned into the source's URL, so a later poll never has to re-guess.
public struct LocalePreference: Sendable, Hashable {
    public var country: String?
    public var language: String?

    public init(country: String? = nil, language: String? = nil) {
        self.country = country
        self.language = language
    }

    public static let `default` = LocalePreference(country: "us", language: "en")

    /// What a storefront URL says about where it sells, defaulting what it leaves out.
    public static func of(_ url: URL?) -> LocalePreference {
        guard let url else { return .default }
        var found = LocalePreference()

        let labels = (url.host() ?? "").lowercased().split(separator: ".").map(String.init)
        if labels.count > 2, let region = LocaleTokens.region(labels[0]) {
            found.country = region
        } else if let tld = LocaleTokens.countryTLD(labels) {
            found.country = tld
        }

        // Only the first two segments, and only one made of nothing *but* locale: a locale
        // lives at the front of a path, and "/products/it-bag" is not a claim about Italy.
        let segments = url.pathComponents.filter { $0 != "/" }.prefix(2)
        for segment in segments where LocaleTokens.isLocale(segment) {
            let read = LocaleTokens.read(segment)
            found.country = found.country ?? read.countries.first
            found.language = found.language ?? read.languages.first
            break
        }

        if found.language == nil, let country = found.country {
            found.language = LocaleTokens.englishSpeaking.contains(country) ? "en" : nil
        }
        if found.country == nil, found.language == nil { return .default }
        return found
    }

    /// How well a child's locale tokens suit this preference. Higher is better; ties keep
    /// document order.
    ///
    /// A country outweighs a language — a US storefront in Spanish still prices in dollars
    /// and ships to the person — and an untagged sibling scores just above a mismatch,
    /// because among tagged alternatives the untagged one is usually the default copy. The
    /// default breaks ties, so a Japanese storefront with no Japanese sitemap still lands on
    /// the English one rather than on whichever sibling happened to be listed first.
    func score(_ tokens: LocaleTokens.Reading) -> Int {
        match(tokens) * 10 + Self.default.match(tokens)
    }

    private func match(_ tokens: LocaleTokens.Reading) -> Int {
        if tokens.countries.isEmpty && tokens.languages.isEmpty { return 1 }
        var score = 0
        if let country, tokens.countries.contains(country) { score += 4 }
        if let language, tokens.languages.contains(language) { score += 2 }
        return score
    }
}

/// Recognising locale tokens in a URL. A curated list rather than the ISO tables in
/// Foundation, which differ by platform and are one more surface only the Linux deploy
/// would test; an unlisted code simply scores as untagged.
enum LocaleTokens {
    struct Reading: Hashable {
        var countries: [String] = []
        var languages: [String] = []

        /// What tells two siblings apart, order-free.
        var key: String { (Set(countries).sorted() + ["|"] + Set(languages).sorted()).joined(separator: ",") }
    }

    /// Every token in a path segment that reads as a country, a region or a language.
    /// "en-us" is both; "eu_en" is a region and a language; "us" is a country.
    static func read(_ text: String) -> Reading {
        var reading = Reading()
        for token in text.lowercased().split(whereSeparator: { !$0.isLetter }).map(String.init) {
            if let region = region(token) { reading.countries.append(region) }
            if let language = language(token) { reading.languages.append(language) }
        }
        return reading
    }

    /// Whether a path segment is a locale and nothing else — `us`, `en-gb`, `eu_en`.
    static func isLocale(_ segment: String) -> Bool {
        let tokens = segment.lowercased().split(whereSeparator: { !$0.isLetter }).map(String.init)
        return !tokens.isEmpty && tokens.allSatisfy { region($0) != nil || language($0) != nil }
    }

    /// Reads a whole URL's path, segment by segment — filenames included, since siblings
    /// are as often `sitemap_en.xml` and `sitemap_fr.xml` as `/en/` and `/fr/`. Only ever
    /// compared between siblings, so a token they all share changes nothing.
    static func read(path url: URL) -> Reading {
        var reading = Reading()
        for segment in url.pathComponents where segment != "/" {
            let part = read(segment)
            reading.countries += part.countries
            reading.languages += part.languages
        }
        return reading
    }

    static func region(_ token: String) -> String? {
        switch token {
        case "uk", "gb": return "gb"
        case "usa", "us": return "us"
        // Not countries, and storefronts use them exactly as if they were.
        case "eu", "ww", "int", "intl", "global": return token == "intl" ? "int" : token
        default: return countries.contains(token) ? token : nil
        }
    }

    static func language(_ token: String) -> String? {
        // Victoria's Secret writes Spanish as "sp".
        if token == "sp" { return "es" }
        return languages.contains(token) ? token : nil
    }

    /// The country a host's top-level domain names, ignoring the ones sold as vanity
    /// suffixes — `.co`, `.io` and friends say nothing about where a shop sells.
    static func countryTLD(_ labels: [String]) -> String? {
        guard let last = labels.last, last.count == 2, !vanityTLDs.contains(last) else { return nil }
        return region(last)
    }

    private static let vanityTLDs: Set<String> = [
        "co", "io", "me", "tv", "ai", "so", "to", "ly", "fm", "gg", "sh", "ws", "la", "cc",
        "gs", "ms", "nu", "sc", "vc", "am", "st"
    ]

    static let englishSpeaking: Set<String> = ["us", "gb", "ie", "au", "nz", "ca", "sg", "za", "in"]

    private static let countries: Set<String> = [
        "ad", "ae", "ar", "at", "au", "be", "bg", "br", "ca", "ch", "cl", "cn", "co", "cy",
        "cz", "de", "dk", "ee", "eg", "es", "fi", "fr", "gr", "hk", "hr", "hu", "id", "ie",
        "il", "in", "is", "it", "jp", "kr", "kw", "lt", "lu", "lv", "ma", "mc", "mt", "mx",
        "my", "nl", "no", "nz", "pe", "ph", "pl", "pt", "qa", "ro", "rs", "ru", "sa", "se",
        "sg", "si", "sk", "th", "tr", "tw", "ua", "uy", "vn", "za"
    ]

    /// No "uk": it is Ukrainian by ISO and the United Kingdom in every storefront URL seen.
    private static let languages: Set<String> = [
        "ar", "cs", "da", "de", "el", "en", "es", "fi", "fr", "he", "hu", "id", "it", "ja",
        "ko", "ms", "nb", "nl", "no", "pl", "pt", "ro", "ru", "sk", "sv", "th", "tr", "vi",
        "zh"
    ]
}

enum SitemapChoice {
    /// What a child sitemap's name says it holds.
    enum Kind: Int, Comparable {
        /// Named for anything that is not a product — never read.
        case other = 0
        /// Named for nothing in particular — read when nothing is named for products.
        case unnamed = 1
        case products = 2

        static func < (lhs: Kind, rhs: Kind) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    /// Whole tokens, never substrings — `"sitemap"` contains `"item"`, and matching on that
    /// once selected an entire index while appearing to filter it.
    ///
    /// "product" alone is not enough: WooCommerce publishes `product_cat-sitemap.xml`
    /// beside `product-sitemap.xml`, and the first is categories. A qualifier beside the
    /// product word decides.
    static func kind(of location: String) -> Kind {
        // The path and whatever the query says other than which page this is — `?page=2`
        // would otherwise read as a sitemap of pages.
        let url = URL(string: location)
        let named = (url.map { $0.path + "?" + nonPagingQuery(of: $0) } ?? location).lowercased()
        let tokens = Set(named.split { !$0.isLetter }.map(String.init))
        let isProductNamed = !tokens.isDisjoint(with: ["product", "products", "item", "items", "shop"])
        let isOtherNamed = !tokens.isDisjoint(with: otherWords)
        if isProductNamed { return isOtherNamed ? .other : .products }
        return isOtherNamed ? .other : .unnamed
    }

    private static let otherWords: Set<String> = [
        "cat", "category", "categories", "collection", "collections", "tag", "tags", "brand",
        "brands", "attribute", "attributes", "page", "pages", "post", "posts", "blog", "blogs",
        "article", "articles", "news", "cms", "landing", "quiz", "wishlist", "legal", "gift",
        "card", "store", "stores", "location", "locations", "video", "videos", "others",
        "author", "authors", "lookbook", "editorial", "journal", "wordpress", "bundling", "offer"
    ]

    /// The children to read, in order, after all three cuts. `pinned` is set when the choice
    /// between storefronts was made here, so discovery can store the chosen child rather than
    /// re-make the choice — with less to go on — on every poll.
    static func select(
        _ children: [String],
        preferring preference: LocalePreference
    ) -> (follow: [String], choseStorefront: Bool) {
        // A gzip file cannot be read here: decompressing it portably would need zlib on
        // Linux, and none of the sitemaps this was built against need it. Leaving them out is
        // a choice among siblings, never the only option thrown away — when every child is
        // gzipped, nothing is followed and detection moves on.
        var seen: Set<String> = []
        let readable = children.filter { location in
            let lowered = location.lowercased()
            guard !lowered.hasSuffix(".gz"), !lowered.contains(".gz?") else { return false }
            return seen.insert(location).inserted
        }

        guard let best = readable.map(kind(of:)).max(), best != .other else { return ([], false) }
        let candidates = readable.filter { kind(of: $0) == best }

        // Storefronts that differ by locale in the path.
        let readings = candidates.map { location in
            URL(string: location).map(LocaleTokens.read(path:)) ?? LocaleTokens.Reading()
        }
        var chosen = candidates
        var choseStorefront = false
        if Set(readings.map(\.key)).count > 1 {
            let scores = readings.map(preference.score)
            let top = scores.max() ?? 0
            let winningKey = readings[scores.firstIndex(of: top) ?? 0].key
            chosen = zip(candidates, readings).filter { $0.1.key == winningKey }.map(\.0)
            choseStorefront = true
        }

        // Storefronts that differ only by a query naming the store: one path, one file.
        var byPath: [String: String] = [:]
        var following: [String] = []
        for location in chosen {
            guard let url = URL(string: location) else { continue }
            let identity = url.path + "?" + nonPagingQuery(of: url)
            if let earlier = byPath[url.path], earlier != identity {
                choseStorefront = true
                continue
            }
            byPath[url.path] = identity
            if !following.contains(location) { following.append(location) }
        }
        return (following, choseStorefront)
    }

    /// The query with every paging parameter removed, so `?page=2` and `?from=1000&to=1999`
    /// read as parts of one file while `?targetStoreId=11205` reads as a different store.
    static func nonPagingQuery(of url: URL) -> String {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        return items
            .filter { !pagingParameters.contains($0.name.lowercased()) }
            .map { "\($0.name)=\($0.value ?? "")" }
            .sorted()
            .joined(separator: "&")
    }

    private static let pagingParameters: Set<String> = [
        "page", "p", "from", "to", "offset", "start", "part", "limit", "n"
    ]
}

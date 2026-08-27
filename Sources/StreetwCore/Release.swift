// Release.swift
// Telling a brand's *release* from the rest of its shop navigation.
//
// `/collections.json` is not a list of drops. It is every collection object a storefront has
// ever defined, and a storefront defines one for each of its filters — so a real poll of six
// brands returned 826 of them, of which the overwhelming majority are furniture:
//
//     "10.5"  "12C"  "1Y"  "2T"  "36.5"        ← size filters
//     "$50 & Under"  "30% OFF GYMSHARK SALE"   ← price and discount rails
//     "1017 ALYX 9SM"  "16Arlington"  "032c"   ← designers a multi-brand shop stocks
//     "All Products"  "Back in Stock"          ← navigation
//     "&Kin Fall 2026"  "Icecream Fall 2026"   ← *these* are releases
//
// The asymmetry decides the rule. A false negative costs one card nobody misses; a false
// positive puts a full-screen announcement in front of somebody reading **"36.5"** as though
// it were the season's drop. So this refuses far more than it admits, and the bar is the one
// thing every genuine release in that data had and no piece of navigation did: **it names a
// season or a year.**
//
// That deliberately loses real collections — Stüssy's "ALWAYS DO WHAT YOU SHOULD DO" is a
// slogan capsule with no date in it, and it will be refused. Silently missing it is the
// cheaper mistake, and the products in it still reach the feed on their own.
//
// Shared rather than living in the app because both ends need the same answer: the server
// decides which collections to put on the wire, and the client decides what to draw.

import Foundation

public enum Release {
    /// Seasons, as brands write them.
    private static let seasons: Set<String> = [
        "spring", "summer", "fall", "autumn", "winter", "resort", "holiday",
        "prefall", "presummer", "springsummer", "fallwinter"
    ]

    /// Two-letter season codes, which are always followed by a year in practice ("FW26").
    private static let seasonCodes: Set<String> = ["fw", "ss", "aw", "sp"]

    /// Words that mark a rail rather than a release, kept even though the season test would
    /// usually catch them anyway. "Sale" and "Archive" are the ones that matter: a brand runs
    /// "Fall 2025 Sale" and "Spring Archive", both of which name a season and neither of
    /// which is news.
    private static let navigation: Set<String> = [
        "sale", "sales", "clearance", "outlet", "markdown", "markdowns", "discount",
        "archive", "archives", "past", "final", "last", "under", "off",
        "all", "everything", "shop", "browse", "index", "catalog", "catalogue",
        "restock", "restocked", "back", "stock", "instock",
        "gift", "gifts", "gifting", "giftcard", "card", "cards", "voucher",
        // Gift guides and promotions, which name a season and are not releases. Every word
        // here was earned: "Her Holiday Must-Haves", "It's Summer Gifting Season" and
        // "BOGO15 Collection Q3 2023" all passed the season test in a real catalogue.
        "musthaves", "must", "haves", "his", "her", "picks", "guide", "guides",
        "edit", "edits", "favourites", "favorites", "staff", "bogo", "bundle", "bundles",
        "size", "sizes", "colour", "color", "colours", "colors",
        "mens", "womens", "kids", "youth", "unisex", "men", "women",
        "accessories", "footwear", "apparel", "clothing", "essentials", "basics",
        "new", "arrivals", "featured", "trending", "bestsellers", "popular",
        "test", "sample", "preview", "coming", "soon", "template"
    ]

    /// A year a season could plausibly be. Narrow on purpose: "1013 Test Collection" and
    /// "1017 ALYX 9SM" both carry four digits and neither is a date.
    private static let years: ClosedRange<Int> = 2015...2035

    /// Whether this collection is a release worth announcing.
    ///
    /// - Parameter title: the collection's own name, as the storefront publishes it.
    public static func isRelease(title: String) -> Bool {
        let words = tokens(in: title)
        guard !words.isEmpty else { return false }

        // Navigation wins outright, before any season is looked for — "Fall 2025 Sale" names
        // a season and is still a sale rail.
        //
        // Trailing digits are stripped before the check because a promotion appends them to
        // its own name: "BOGO15 Collection Q3 2023" tokenises to `bogo15`, which is not in
        // the list, while `bogo` is. Only the trailing run is removed, so a year survives
        // intact and "2026" is never mistaken for a word.
        guard words.allSatisfy({ !navigation.contains(withoutTrailingDigits($0)) }) else {
            return false
        }

        // A title that is only numbers is a size or a price, whatever else is true of it.
        guard words.contains(where: { $0.contains(where: \.isLetter) }) else { return false }

        return namesASeason(words) || namesAYear(words)
    }

    private static func namesASeason(_ words: [String]) -> Bool {
        words.contains { seasons.contains($0) }
    }

    /// A four-digit year, or a season code carrying a two-digit one ("fw26", "ss'26").
    private static func namesAYear(_ words: [String]) -> Bool {
        for word in words {
            if word.count == 4, let value = Int(word), years.contains(value) { return true }

            // "fw26" arrives as one token; "fw" and "26" arrive as two when an apostrophe
            // separated them, and both forms are common.
            if word.count == 4, seasonCodes.contains(String(word.prefix(2))),
               Int(word.suffix(2)) != nil {
                return true
            }
        }
        // The split form: a season code immediately followed by a two-digit number.
        for (one, two) in zip(words, words.dropFirst()) {
            if seasonCodes.contains(one), two.count == 2, Int(two) != nil { return true }
        }
        return false
    }

    /// The words in a collection's name that are distinctive enough to find its contents by.
    ///
    /// A release is announced as one row and its garments are published as another sixty,
    /// with nothing linking them — `/collections.json` names a release and does not list it.
    /// Brands do tag their seasons, so a distinctive word from the title is the thread: a
    /// product mentioning "fw26" is almost certainly in the FW26 collection.
    ///
    /// Lives here beside `isRelease` so the server's member query and the client's
    /// `Brand.members(of:)` cannot drift about what counts as distinctive.
    public static func distinctiveWords(in title: String) -> [String] {
        let stop: Set<String> = [
            "the", "and", "new", "collection", "collections", "capsule", "drop", "release",
            "collab", "collaboration", "part", "vol", "volume", "edition", "series", "all",
            "shop", "our", "for", "with", "by", "of", "in", "a"
        ]
        return tokens(in: title).filter { word in
            guard !stop.contains(word) else { return false }
            return word.contains(where: \.isNumber) || word.count >= 4
        }
    }

    private static func withoutTrailingDigits(_ word: String) -> String {
        let trimmed = String(word.reversed().drop(while: \.isNumber).reversed())
        return trimmed.isEmpty ? word : trimmed
    }

    private static func tokens(in title: String) -> [String] {
        title
            .lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
    }
}

// Gender.swift
// Working out who a garment is cut for, from catalogue text that was never written to
// answer the question.
//
// Nobody publishes a gender field. What exists is tags, a product type, a URL handle and
// a title, in wildly varying quality: Kith tags products `mens` and `wmns` and is easy;
// Billionaire Boys Club tags the same information as `2026`, `F26`, `Final Sale` and is
// impossible. So this reads every signal it can and, crucially, is allowed to answer
// "I don't know" — which is a real answer here, not a failure.
//
// Three rules carry the whole design:
//
// - **Never hide the ambiguous.** Same rule `SizeNormalizer` follows, for the same
//   reason: a missed drop costs far more than an unwanted hoodie in the feed. Only a
//   confident classification is ever allowed to filter something out.
// - **What a product is *called* outranks where it is *filed*.** "WMNS Dunk Low" is the
//   women's cut — the name says so, and that is the manufacturer's own designation. The
//   `mens` on it is a merchandising tag, and a retailer files one product under several
//   departments all the time. Weighing those equally resolved every WMNS sneaker in a
//   men's department to "unisex" and showed it to someone who had asked for menswear.
// - **Both signals *at the same level* means unisex, not a coin flip.** A product tagged
//   `mens` *and* `wmns` and named neither is genuinely for everyone — that is how
//   storefronts file a shared catalogue, not a mistake to resolve.

import Foundation

public enum Gender: String, Codable, Sendable, CaseIterable {
    case mens
    case womens
    case kids
    /// Explicitly for everyone, or carrying both men's and women's markers.
    case unisex
    /// Nothing in the catalogue said. Never filtered out.
    case unknown

    public var label: String {
        switch self {
        case .mens: "Men's"
        case .womens: "Women's"
        case .kids: "Kids"
        case .unisex: "Unisex"
        case .unknown: "Unspecified"
        }
    }
}

/// What the user wants to see. Stored on the size profile, pushed to the server with it.
public enum GenderPreference: String, Codable, Sendable, CaseIterable, Identifiable {
    case everything
    case mens
    case womens

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .everything: "Everything"
        case .mens: "Menswear"
        case .womens: "Womenswear"
        }
    }

    /// Whether an item of `gender` belongs in the feed.
    ///
    /// Picking a gender means adult clothing in that cut: the opposite gender goes, and so
    /// does kids' — someone shopping menswear is not shopping the children's rail, and a
    /// kids' hoodie in a menswear feed is the same annoyance as a women's one. Only
    /// "Everything" includes it.
    ///
    /// Unisex still stays, because it genuinely fits. Unknown still stays, because we
    /// don't know and guessing would drop real drops — that one is never traded away.
    public func allows(_ gender: Gender) -> Bool {
        switch (self, gender) {
        case (.everything, _): true
        case (.mens, .womens), (.womens, .mens): false
        case (.mens, .kids), (.womens, .kids): false
        default: true
        }
    }
}

public enum GenderClassifier {
    /// Bumped whenever the rules below change.
    ///
    /// Clients store the answer alongside this number and re-derive when it doesn't
    /// match. Without it, every product classified by an older revision keeps that
    /// verdict forever — an improvement to the classifier would only ever apply to
    /// products discovered after the update, which is the worst of both worlds.
    ///
    /// - 1: initial.
    /// - 2: a product's *name* now outranks the department it is filed under, so a
    ///      "WMNS Dunk Low" tagged `mens` is women's rather than unisex.
    public static let version = 2

    // Whole-tag forms that tokenising would destroy. "w-apparel" splits to ["w",
    // "apparel"], and a bare "w" is far too ambiguous to act on by itself.
    private static let womensTags: Set<String> = ["w-apparel", "w-accessories", "wmns-apparel"]
    private static let mensTags: Set<String> = ["m-apparel", "m-accessories", "mns-apparel"]

    private static let womensWords: Set<String> = [
        "women", "womens", "woman", "womenswear", "wmns", "wmn", "ladies", "female", "her"
    ]
    private static let mensWords: Set<String> = [
        "men", "mens", "man", "menswear", "mns", "male", "him"
    ]
    private static let kidsWords: Set<String> = [
        "kid", "kids", "youth", "boy", "boys", "girl", "girls",
        "toddler", "infant", "baby", "junior", "child", "children"
    ]
    private static let unisexWords: Set<String> = ["unisex", "genderless", "allgender"]

    /// What one tier of evidence says. Two tiers are gathered separately so the stronger
    /// one can win outright instead of being averaged with the weaker.
    private struct Signals {
        var mens = false
        var womens = false
        var kids = false
        var unisex = false

        var isSilent: Bool { !mens && !womens && !kids && !unisex }

        var resolved: Gender {
            if unisex { return .unisex }
            // Both, from evidence of equal weight: genuinely for everyone. Calling it
            // unisex shows it to everybody, which is the safe direction.
            if mens && womens { return .unisex }
            if womens { return .womens }
            if mens { return .mens }
            if kids { return .kids }
            return .unknown
        }
    }

    /// Reads every field a storefront might have put the answer in, in two tiers.
    ///
    /// **Named** — the title and the URL handle. This is what the product *is*: "WMNS Air
    /// Force 1" is the women's cut, full stop. `handle` is worth passing wherever it
    /// exists, because a URL like `/products/womens-cargo-pant` is often the only place
    /// the distinction survives when the visible title is just "Cargo Pant".
    ///
    /// **Filed** — tags and product type. This is merchandising, and a single product is
    /// routinely filed under several departments, so it only decides when the name is
    /// silent.
    public static func classify(
        title: String = "",
        productType: String? = nil,
        tags: [String] = [],
        handle: String? = nil
    ) -> Gender {
        var named = Signals()
        consider(tokens(in: title), into: &named)
        if let handle { consider(tokens(in: handle), into: &named) }

        // The name settled it. Tags cannot overrule the manufacturer's own designation.
        if !named.isSilent { return named.resolved }

        var filed = Signals()
        for tag in tags {
            let lowered = tag.lowercased().trimmingCharacters(in: .whitespaces)
            // Whole-tag forms first: tokenising "w-apparel" yields a bare "w", which is
            // far too ambiguous to act on by itself.
            if womensTags.contains(lowered) { filed.womens = true }
            if mensTags.contains(lowered) { filed.mens = true }
            consider(tokens(in: lowered), into: &filed)
        }
        if let productType { consider(tokens(in: productType), into: &filed) }

        return filed.resolved
    }

    private static func consider(_ words: some Sequence<String>, into signals: inout Signals) {
        for word in words {
            if unisexWords.contains(word) { signals.unisex = true }
            // Order is irrelevant here because these are whole tokens, never substrings —
            // which is the entire point. "womens" contains "mens", so any substring
            // search classifies every women's product as men's.
            if womensWords.contains(word) { signals.womens = true }
            if mensWords.contains(word) { signals.mens = true }
            if kidsWords.contains(word) { signals.kids = true }
        }
    }

    /// Convenience for a fetched item, which carries all four fields.
    public static func classify(_ item: FetchedItem) -> Gender {
        classify(
            title: item.title,
            productType: item.productType,
            tags: item.tags,
            // Shopify links are always `/products/<handle>`, and the handle is where the
            // distinction most often survives.
            handle: item.linkURL?.lastPathComponent
        )
    }

    /// Splits on anything that isn't a letter or digit, so "Women's" yields "women" and
    /// "mens-fall-24" yields "mens". Runs of noise collapse rather than producing empties.
    private static func tokens(in text: String) -> [String] {
        text.lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
    }
}

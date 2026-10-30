// FollowFilter.swift
// Following only part of a brand — its jeans, its bags, nothing for kids.
//
// A mode (`FollowMode`) says how much of a brand reaches somebody by *kind* of event; this
// says it by *garment*. Following COS for its knitwear, or Carhartt for its trousers, used to
// mean every tee and every cap as well, and the only way out was *Quiet*, which takes the
// knitwear too. So a follow can carry a filter: category chips ("Jeans", "Bags") and/or the
// reader's own words in Shop's grammar (`ShopQuery`) — "black trousers", "no kids".
//
// **One definition, asked on both ends, the way `FollowMode.admits` is.** `Notifier` asks it
// before a push, and the phone asks it where a row is written; what it does not admit is
// stored already read, with no arrival, and is never pushed. Two copies of the rule would
// drift, and the symptom would be a push about a garment the feed then does not show — or the
// other way round, which is worse.
//
// The inputs are what **both ends hold at the moment they decide**: the title, the catalogue's
// product type and tags, and the price. Not the colourways (the notifier loads a product
// without its variants, and that accessor traps), not the measured colour (only saved
// photographs are measured), not the shop's name (it is the same shop on every row, so a word
// matching it would admit everything). A word is matched exactly as Shop matches it
// (`ShopIndex.carries`): whole tokens, the other grammatical number, the few true synonyms,
// and a category word answered by the slot classifier as well.
//
// What always passes, and why:
//
// - **A garment the classifier cannot place.** `.unknown` is never filtered anywhere in this
//   project — YoungLA names its products `W2156` — and a filter is the last place to start:
//   hiding a real drop because its title is a stock code is the one outcome a follow must not
//   produce. The *positive* half of the filter (chips and words) never hides one.
// - **A brand-wide sale**, a lock, a post, a page change. None is about a garment, so a
//   filter over garments has nothing to say about it; a sale is the one alert a *Sales only*
//   follow exists for, and narrowing a follow to jeans must not swallow the sale on them.
// - **A release** (`.collection`) is many garments under one name, so its title cannot say
//   which shelf it is from — "Denim Tears FW26" is not a pair of jeans. Only an exclusion the
//   reader typed reaches it: "no kids" means no "Kith Kids" capsule either.
// - **A watch**, which ignores every mode and this too — neither end asks the filter on that
//   path. It is the one alert somebody asked for by name.
//
// An exclusion ("no kids") is the one part that applies to everything it matches, unplaced or
// not: it is a word the row literally carries and the reader asked in so many words not to
// see, which is no guess about what the garment is.
//
// Prices, like Shop's, are compared in each shop's own currency and never converted; a row
// with no price is never hidden by a bound. "In my size", "cheaper" and "formal" are questions
// about one reader and one search, not about a shop's shelves, and are read back as not used.

import Foundation

/// What part of a followed brand reaches somebody. Nil — or empty — is all of it.
public struct FollowFilter: Codable, Sendable, Hashable {
    /// Category chips, each a word the grammar knows: a slot ("outerwear", "accessories") or a
    /// kind of garment ("jeans", "bags"). Any one of them admits a garment. Words rather than an
    /// enum so a chip a newer client offers still means something to an older server, which
    /// reads it through the same grammar.
    public var categories: [String]
    /// The reader's own words, in `ShopQuery`'s grammar. Every word must be carried, as in Shop.
    public var words: String?

    public init(categories: [String] = [], words: String? = nil) {
        self.categories = categories
        self.words = words
    }

    /// Lenient, for the reason `FollowMode` is: a field a newer end adds must not take the
    /// follow list down with it.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        categories = (try? container.decodeIfPresent([String].self, forKey: .categories)) ?? []
        words = try? container.decodeIfPresent(String.self, forKey: .words)
    }

    /// The most chips and the longest sentence a follow keeps — far past anything the dialog
    /// offers, and a bound on what a stranger can make the notifier parse per event.
    public static let maxCategories = 12
    public static let maxWords = 200

    /// The same filter, tidied: chips lowercased, de-duplicated and bounded, the words trimmed
    /// and bounded — and **nil when it would let everything through**, so "All" is stored as
    /// no filter at all rather than as an empty one that every reader has to recognise.
    public var normalized: FollowFilter? {
        var seen = Set<String>()
        let chips = categories
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
            .prefix(Self.maxCategories)
        let text = words?.trimmingCharacters(in: .whitespacesAndNewlines).prefix(Self.maxWords)
        let kept = FollowFilter(categories: Array(chips), words: text.map(String.init).flatMap { $0.isEmpty ? nil : $0 })
        return kept.isEmpty ? nil : kept
    }

    /// Whether this lets everything through: no chip, and no word the grammar acts on.
    public var isEmpty: Bool {
        categories.allSatisfy { $0.trimmingCharacters(in: .whitespaces).isEmpty } && Matcher.query(words).isEmpty
    }

    // MARK: - Deciding

    /// The garment a decision is about, in the fields both ends hold.
    public struct Item: Sendable, Hashable {
        public var title: String
        public var productType: String?
        public var tags: [String]
        public var price: Double?

        public init(title: String, productType: String? = nil, tags: [String] = [], price: Double? = nil) {
            self.title = title
            self.productType = productType
            self.tags = tags
            self.price = price
        }
    }

    /// **Whether an event of this kind, about this garment, reaches somebody following with
    /// this filter.** The one rule; see the file header for what always passes.
    ///
    /// Parses the words each call. A caller deciding many rows builds a `Matcher` once.
    public func admits(_ kind: UpdateKind, _ item: Item) -> Bool {
        Matcher(self).admits(kind, item)
    }

    /// A filter read once, for deciding many rows — a merge of a feed page, a notifier pass.
    public struct Matcher: Sendable {
        let chips: [Chip]
        let query: ShopQuery

        /// One category chip, as the grammar reads it.
        struct Chip: Sendable {
            var term: ShopQuery.Term
            /// The shelf a kind belongs on, so "jeans" does not admit a jean jacket — the
            /// same restraint the tally uses, so a chip admits exactly what it counted.
            var slot: GarmentSlot?
        }

        /// - Parameter filter: nil, or one that is empty, admits everything.
        public init(_ filter: FollowFilter?) {
            chips = (filter?.categories ?? []).compactMap { word in
                if let category = FollowCategory.named(word) {
                    return ShopQuery.term(for: category.id).map { Chip(term: $0, slot: category.slot) }
                }
                return ShopQuery.term(for: word.lowercased()).map { Chip(term: $0, slot: nil) }
            }
            query = Self.query(filter?.words)
        }

        /// Only what a follow can act on: words to carry, words ruled out, a price bound.
        static func query(_ words: String?) -> ShopQuery {
            guard let words, !words.trimmingCharacters(in: .whitespaces).isEmpty else { return ShopQuery() }
            var query = ShopQuery.parse(words)
            query.inMySize = false
            query.cheaper = false
            query.formal = false
            return query
        }

        /// Whether this matcher lets everything through.
        public var isEmpty: Bool { chips.isEmpty && query.isEmpty }

        public func admits(_ kind: UpdateKind, _ item: Item) -> Bool {
            guard !isEmpty else { return true }
            switch kind {
            case .sale, .dropLock, .post, .pageChange:
                return true
            case .collection:
                return !isRuledOut(Self.index(item))
            case .product, .restock, .priceDrop:
                break
            }

            let index = Self.index(item)
            if isRuledOut(index) { return false }
            let listing = index.listings[0]
            // The positive half never hides what the classifier cannot place.
            if listing.slot == .unknown { return true }

            if !chips.isEmpty {
                let inChip = chips.contains { chip in
                    if let slot = chip.slot, chip.term.slot == nil, slot != listing.slot { return false }
                    return index.carries(chip.term, at: 0)
                }
                guard inChip else { return false }
            }
            for term in query.terms where !index.carries(term, at: 0) { return false }
            if let price = item.price {
                if let ceiling = query.ceiling, price > ceiling { return false }
                if let floor = query.floor, price < floor { return false }
            }
            return true
        }

        private func isRuledOut(_ index: ShopIndex) -> Bool {
            query.excluded.contains { index.carries($0, at: 0) }
        }

        /// The row as Shop's index reads it, with no shop name — see the file header.
        static func index(_ item: Item) -> ShopIndex {
            ShopIndex([ShopListing(
                id: "",
                brandKey: "",
                brandName: "",
                title: item.title,
                productType: item.productType,
                tags: item.tags,
                price: item.price
            )])
        }
    }

    // MARK: - Saying what it does

    /// What this filter lets through, in the order it is worth reading back — the chips by
    /// their labels, then the words as Shop's field prints them: "JEANS · BAGS · NOT KIDS".
    /// Empty for no filter.
    public var reading: [String] {
        var out = categories.map { FollowCategory.named($0)?.label.lowercased() ?? $0.lowercased() }
        out += Matcher.query(words).reading
        return out
    }

    /// What was typed and recognised, and will not be acted on by a follow — "in your size",
    /// "cheaper", "size 10". Printed so the field never silently drops a word.
    public var unused: [String] {
        guard let words, !words.trimmingCharacters(in: .whitespaces).isEmpty else { return [] }
        let query = ShopQuery.parse(words)
        var out = query.ignored
        if query.inMySize { out.append("in your size") }
        if query.formal { out.append("more formal") }
        if query.cheaper { out.append("cheaper") }
        return out
    }
}

/// A chip the follow dialog can offer: a slot, or a kind of garment the grammar already knows.
///
/// The kinds are the ones a streetwear catalogue is mostly made of, each a word `ShopQuery`
/// reads with its other number and its synonyms ("tees" finds a T-shirt), placed on the shelf
/// `GarmentClassifier` puts it on. A dress has no shelf — the classifier does not place one —
/// so a "Dresses" chip admits dresses by the word and hides nothing unplaced, like every chip.
public struct FollowCategory: Sendable, Hashable, Identifiable {
    /// The word the grammar reads, and what travels on the wire.
    public let id: String
    public let label: String
    /// The shelf this kind sits on, or nil for a slot chip and for a kind with none.
    public let slot: GarmentSlot?

    /// Kinds first, finest before broadest within a shelf, then the shelves themselves —
    /// the order a garment is counted in, so it counts once, as the finest thing it is.
    public static let all: [FollowCategory] = [
        .init(id: "jeans", label: "Jeans", slot: .bottom),
        .init(id: "shorts", label: "Shorts", slot: .bottom),
        .init(id: "sweatpants", label: "Sweatpants", slot: .bottom),
        .init(id: "skirts", label: "Skirts", slot: .bottom),
        .init(id: "trousers", label: "Trousers", slot: .bottom),
        .init(id: "tees", label: "T-shirts", slot: .top),
        .init(id: "hoodies", label: "Hoodies", slot: .top),
        .init(id: "sweatshirts", label: "Sweatshirts", slot: .top),
        .init(id: "sweaters", label: "Sweaters", slot: .top),
        .init(id: "shirts", label: "Shirts", slot: .top),
        .init(id: "jackets", label: "Jackets", slot: .outerwear),
        .init(id: "coats", label: "Coats", slot: .outerwear),
        .init(id: "sneakers", label: "Sneakers", slot: .footwear),
        .init(id: "boots", label: "Boots", slot: .footwear),
        .init(id: "caps", label: "Caps", slot: .headwear),
        .init(id: "bags", label: "Bags", slot: .accessory),
        .init(id: "socks", label: "Socks", slot: .accessory),
        .init(id: "dresses", label: "Dresses", slot: nil),
        .init(id: "outerwear", label: "Outerwear", slot: nil),
        .init(id: "tops", label: "Tops", slot: nil),
        .init(id: "bottoms", label: "Bottoms", slot: nil),
        .init(id: "footwear", label: "Footwear", slot: nil),
        .init(id: "headwear", label: "Headwear", slot: nil),
        .init(id: "accessories", label: "Accessories", slot: nil)
    ]

    private static let byID = Dictionary(all.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

    public static func named(_ word: String) -> FollowCategory? {
        byID[word.trimmingCharacters(in: .whitespaces).lowercased()]
    }

    /// The finest category a garment belongs to, or nil for one the classifier cannot place.
    /// The one placement both the tally and a chip agree on.
    public static func of(_ item: FollowFilter.Item) -> FollowCategory? {
        let index = FollowFilter.Matcher.index(item)
        let slot = index.listings[0].slot
        for category in all {
            guard let term = ShopQuery.term(for: category.id) else { continue }
            if let shelf = term.slot {
                // A shelf chip: what the classifier placed there.
                if shelf == slot { return category }
                continue
            }
            if let shelf = category.slot, shelf != slot { continue }
            if category.slot == nil, slot != .unknown { continue }
            if index.carries(term, at: 0) { return category }
        }
        return nil
    }

    /// A brand's biggest categories, by how many of its products each holds, most first and
    /// ties in `all`'s order. What the follow dialog offers beside *All*.
    ///
    /// Each product counts once, as the finest category it belongs to — so a denim brand
    /// offers Jeans, not Bottoms *and* Jeans — and a product nothing places counts for none.
    public static func biggest(in items: [FollowFilter.Item], limit: Int = 3) -> [FollowCategoryCount] {
        var counts: [String: Int] = [:]
        for item in items {
            if let category = of(item) { counts[category.id, default: 0] += 1 }
        }
        let order = Dictionary(all.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
        return counts
            .sorted { a, b in a.value != b.value ? a.value > b.value : (order[a.key] ?? 0) < (order[b.key] ?? 0) }
            .prefix(limit)
            .compactMap { entry in
                named(entry.key).map { FollowCategoryCount(category: $0.id, label: $0.label, count: entry.value) }
            }
    }
}

/// One of a brand's categories, with how many products it holds.
public struct FollowCategoryCount: Codable, Sendable, Hashable, Identifiable {
    /// `FollowCategory.id` — what a chip sends back in `FollowFilter.categories`.
    public var category: String
    public var label: String
    public var count: Int

    public var id: String { category }

    public init(category: String, label: String, count: Int) {
        self.category = category
        self.label = label
        self.count = count
    }
}

/// `GET /v1/brands/:id/categories`: what the follow dialog offers beside *All*.
public struct BrandCategories: Codable, Sendable, Hashable {
    /// The biggest few, most first.
    public var categories: [FollowCategoryCount]
    /// How many products were counted, so the dialog can say what the counts are out of.
    public var products: Int

    public init(categories: [FollowCategoryCount], products: Int) {
        self.categories = categories
        self.products = products
    }
}

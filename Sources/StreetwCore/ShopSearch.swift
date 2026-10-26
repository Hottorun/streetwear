// ShopSearch.swift
// Finding what a `ShopQuery` asked for among the products already on the phone.
//
// **The scope is the whole of the honesty.** This searches the products from the shops
// somebody follows that the app has already stored — the newest few hundred per shop, and in
// server mode only what arrived as news — and the screen says so in those words. It is not
// the shops' whole catalogues (Phase 3 stores those) and it is not the web (Phase 4 asks a
// model to look). An answer from a narrow search presented as a broad one is the quiet lie
// this project keeps a list of; the same answer labelled with its scope is simply useful.
//
// Three decisions worth knowing before changing anything here.
//
// - **Every word that exists in your shops must match; a word that exists nowhere is set
//   aside and said.** "a black suit for a wedding" would otherwise find nothing at all —
//   no product title says "wedding" — and an empty page is the least useful answer to a
//   sentence with a perfectly good garment in it. So a word no product in the store carries
//   is reported (`unknown`) and left out of the requirement, and the reading under the field
//   says which. That is also exactly the seam where the model will slot in: a word this
//   cannot place is the question it is for.
// - **A failed search says which failure it was** (`Outcome`), the rule the catalogue search
//   learned: an empty list for "never asked" and for "asked, nothing there" read the same and
//   mean opposite things. Here the constraints are applied in a fixed order and the first one
//   to empty the list is named — nothing has that word, nothing has them together, your
//   gender filter hides them, none is under the price, your sizes are not set, none is in
//   your size today. Each has a different fix and the reader is told which.
// - **Ranked, not sorted by date.** A title match outweighs a tag, a tag outweighs the shop's
//   name; sold-out pieces go last rather than vanishing, because a sold-out size is a restock
//   tomorrow and catching that is what the app is for. Ties break on recency and then on id,
//   so a result list typed twice is the same list twice.

import Foundation

/// One product as Shop reasons about it. A value type, built once from the store and read
/// off the main actor, for the reason `Garment` is one: the search has no business holding a
/// model.
public struct ShopListing: Sendable, Hashable, Identifiable {
    /// The garment, not the event — `productExternalID` where there is one, so a jacket that
    /// dropped and then restocked is one listing.
    public var id: String
    /// Who made it, by a key that is stable within one store.
    public var brandKey: String
    public var brandName: String
    public var title: String
    public var productType: String?
    public var tags: [String]
    /// The colourway names the catalogue publishes ("Vintage Black").
    public var colourways: [String]
    /// What `ImageTagger` measured, canonical. Usually empty: it only reads saved photographs.
    public var measuredColours: [String]
    public var visionCategories: [String]
    public var slot: GarmentSlot
    public var price: Double?
    public var publishedAt: Date
    /// Buyable in some size right now.
    public var isAvailable: Bool
    /// Passes the reader's gender filter, and is clothing at all — `BrandUpdate.passes`.
    /// Carried rather than applied at build time, so a search can say "your filter hides
    /// these" instead of claiming there are none.
    public var isShown: Bool
    /// How strongly a full-text index ranked it, where one did — Postgres's `ts_rank_cd` on
    /// the server. Zero on the phone, which has no such index, so there it changes nothing.
    /// A tie-break *after* the field-weighted score and never before it, so the order a
    /// query gives is the grammar's on both ends and the index only settles what the
    /// grammar calls equal.
    public var relevance: Double

    public init(
        id: String,
        brandKey: String,
        brandName: String,
        title: String,
        productType: String? = nil,
        tags: [String] = [],
        colourways: [String] = [],
        measuredColours: [String] = [],
        visionCategories: [String] = [],
        slot: GarmentSlot? = nil,
        price: Double? = nil,
        publishedAt: Date = Date(timeIntervalSince1970: 0),
        isAvailable: Bool = true,
        isShown: Bool = true,
        relevance: Double = 0
    ) {
        self.id = id
        self.brandKey = brandKey
        self.brandName = brandName
        self.title = title
        self.productType = productType
        self.tags = tags
        self.colourways = colourways
        self.measuredColours = measuredColours
        self.visionCategories = visionCategories
        self.slot = slot ?? GarmentClassifier.classify(
            title: title,
            productType: productType,
            tags: tags,
            visionCategories: visionCategories
        )
        self.price = price
        self.publishedAt = publishedAt
        self.isAvailable = isAvailable
        self.isShown = isShown
        self.relevance = relevance
    }
}

/// Every listing's tokens, worked out once — the search runs per keystroke and the
/// tokenising is the expensive part.
public struct ShopIndex: Sendable {
    public let listings: [ShopListing]

    /// Per listing, parallel to `listings`: each token and the weightiest field it was in.
    let fields: [[String: Field]]
    /// Each listing's shop name as one run of letters — "offwhite" — so a query naming the
    /// shop outright finds it even when the name is also a colour.
    let shops: [String]
    /// Every token anywhere in the store, so a word that is nowhere can be named.
    let vocabulary: Set<String>
    let measured: Set<String>
    let slots: Set<GarmentSlot>

    /// Where a token was found. A title names the garment; a tag is how a shop filed it; the
    /// shop's own name is the weakest claim of all, and a colour word does not get to make it
    /// — "white" must not find everything Off-White sells.
    enum Field: Int, Comparable, Sendable {
        case brand = 1
        case tag = 2
        case colourway = 3
        case type = 4
        case title = 5

        static func < (lhs: Field, rhs: Field) -> Bool { lhs.rawValue < rhs.rawValue }

        var weight: Double {
            switch self {
            case .title: 3
            case .type: 2.5
            case .colourway: 2
            case .tag: 1
            case .brand: 1
            }
        }
    }

    public init(_ listings: [ShopListing]) {
        self.listings = listings
        var fields: [[String: Field]] = []
        fields.reserveCapacity(listings.count)
        var shops: [String] = []
        shops.reserveCapacity(listings.count)
        var vocabulary: Set<String> = []
        var measured: Set<String> = []
        var slots: Set<GarmentSlot> = []

        for listing in listings {
            var tokens: [String: Field] = [:]
            func note(_ text: String, as field: Field) {
                for token in ShopText.tokens(text) where (tokens[token] ?? .brand) <= field {
                    tokens[token] = field
                }
            }
            note(listing.brandName, as: .brand)
            listing.tags.forEach { note($0, as: .tag) }
            listing.colourways.forEach { note($0, as: .colourway) }
            if let type = listing.productType { note(type, as: .type) }
            note(listing.title, as: .title)
            fields.append(tokens)
            let shop = ShopText.folded(listing.brandName).filter { $0.isLetter || $0.isNumber }
            shops.append(shop)
            vocabulary.formUnion(tokens.keys)
            vocabulary.insert(shop)
            measured.formUnion(listing.measuredColours.map { $0.lowercased() })
            slots.insert(listing.slot)
        }
        self.fields = fields
        self.shops = shops
        self.vocabulary = vocabulary
        self.measured = measured
        self.slots = slots
    }

    /// Whether anything in the store could answer this word at all.
    func knows(_ term: ShopQuery.Term) -> Bool {
        if let slot = term.slot, slots.contains(slot) { return true }
        if let colour = term.colour, measured.contains(colour.lowercased()) { return true }
        return !term.forms.isDisjoint(with: vocabulary)
    }

    /// How strongly listing `index` carries this word, or nil when it does not.
    func weight(of term: ShopQuery.Term, at index: Int) -> Double? {
        let listing = listings[index]
        var best: Double?
        for form in term.forms {
            guard let field = fields[index][form] else { continue }
            // A colour is a property of the garment, never of the shop — unless the word *is*
            // the shop's whole name, which is how somebody asks for Off-White.
            if field == .brand, term.colour != nil, !term.forms.contains(shops[index]) { continue }
            best = max(best ?? 0, field.weight)
        }
        if best == nil, term.forms.contains(shops[index]) {
            best = Field.brand.weight
        }
        if let colour = term.colour, listing.measuredColours.contains(where: { $0.caseInsensitiveCompare(colour) == .orderedSame }) {
            best = max(best ?? 0, Field.colourway.weight)
        }
        if let slot = term.slot, listing.slot == slot {
            best = max(best ?? 0, 1.5)
        }
        return best
    }

    func tokens(at index: Int) -> Dictionary<String, Field>.Keys { fields[index].keys }
}

public enum ShopSearch {
    public struct Hit: Sendable, Hashable, Identifiable {
        public var id: String { listing.id }
        public var listing: ShopListing
        /// The words this one carries. Printed only on a partial match, where it is the
        /// whole explanation of why it is there.
        public var matched: [String]
        /// Carries every word that exists in the store.
        public var isExact: Bool
        var score: Double
    }

    /// Why the list is what it is — and, when it is empty, which constraint emptied it.
    ///
    /// Codable because the server answers the same question for a catalogue the phone does
    /// not hold, and the screen has to be able to say the same six things about either.
    public enum Outcome: Codable, Sendable, Hashable {
        /// There are results that carry everything asked for.
        case found
        /// Nothing carries all of it; these carry some, most first.
        case closest
        /// Nothing was typed that could be acted on.
        case nothingToSearch
        /// Not one of the words is in any product in the store.
        case notInYourShops([String])
        /// Everything that matched was ruled out by a "no …".
        case allRuledOut([String])
        /// This many matched, and the gender filter hides every one.
        case hiddenByFilter(Int)
        /// This many matched, none inside the price bound; the cheapest is this much.
        case outsidePrice(count: Int, cheapest: Double?)
        /// "In my size" was asked and no size has been entered.
        case noSizes
        /// This many matched, and none is buyable in a size the reader wears.
        case noneInYourSize(Int)
    }

    public struct Result: Sendable {
        public var exact: [Hit] = []
        public var partial: [Hit] = []
        /// Words no product in the store carries, set aside rather than required.
        public var unknown: [String] = []
        public var outcome: Outcome = .nothingToSearch
        /// What "cheaper" settled on, for the reading: the middle price of what matched.
        public var cheaperThan: Double?
        /// Before the display cap — so the screen can say "the first 200 of 340".
        public var total = 0

        public init() {}
    }

    /// Below this many exact matches, the partial ones are shown under them — a search that
    /// found two black suits has room for black tailoring that is not a suit, and one that
    /// found forty does not.
    public static let partialBelow = 12
    public static let partialLimit = 24
    public static let limit = 200

    /// Tailoring's vocabulary, and the clothes it is not. Used **only** to reorder when
    /// "more formal" is asked for, never to refuse anything.
    ///
    /// `Pairing` deliberately has no formality rule, and that note still stands: a blazer with
    /// track pants is the house style, and a rule that refused it would spend its time
    /// refusing the best answers the app has. This is a different thing — somebody *asking*
    /// for the dressier end of a result list — and the most it does is change which end of
    /// the list they see first.
    static let dressy: Set<String> = [
        "suit", "suits", "suiting", "blazer", "blazers", "tailored", "tailoring", "trouser",
        "trousers", "pleat", "pleated", "wool", "oxford", "oxfords", "poplin", "buttondown",
        "loafer", "loafers", "derby", "derbies", "brogue", "brogues", "overcoat", "topcoat",
        "peacoat", "cashmere", "merino", "cardigan", "tie", "ties", "waistcoat", "flannel",
        "tweed", "herringbone", "chino", "chinos", "turtleneck", "rollneck", "silk", "mohair"
    ]
    static let casual: Set<String> = [
        "hoodie", "hoodies", "hoody", "sweatshirt", "sweatpant", "sweatpants", "jogger",
        "joggers", "tee", "tshirt", "graphic", "cargo", "cargos", "shorts", "track",
        "tracksuit", "slide", "slides", "sneaker", "sneakers", "trainer", "trainers", "runner",
        "fleece", "cap", "beanie", "jersey", "mesh", "nylon", "puffer", "bucket"
    ]

    /// - Parameters:
    ///   - hasSizes: whether the reader has entered any size. "In my size" with none is its
    ///     own answer and must not read as "nothing fits you".
    ///   - fits: whether one listing is buyable in a size the reader wears, by
    ///     `SizeProfile.claims`. Asked only of listings that survived everything else, so a
    ///     caller may make it as expensive as a size context costs.
    ///   - knows: whether anything *in the whole store* carries a word, for a caller whose
    ///     index holds only part of it. The server searches a catalogue it cannot load, so
    ///     it hands over the few hundred best candidates and asks its database which words
    ///     exist at all — and that answer, not the candidates' vocabulary, has to decide what
    ///     is required and what is set aside, or a rare word crowded out of the candidates
    ///     would be "not in your shops" there and required here. Nil reads it off `index`,
    ///     which on the phone is the whole store.
    public static func run(
        _ query: ShopQuery,
        in index: ShopIndex,
        hasSizes: Bool,
        fits: (ShopListing) -> Bool,
        knows: ((ShopQuery.Term) -> Bool)? = nil
    ) -> Result {
        var result = Result()
        guard !query.isEmpty else { return result }

        let known = knows ?? index.knows
        let required = query.terms.filter(known)
        result.unknown = query.terms.filter { !known($0) }.map(\.word)
        let hasConstraint = query.ceiling != nil || query.floor != nil || query.inMySize
            || !query.excluded.isEmpty || query.cheaper || query.formal

        if required.isEmpty {
            if !query.terms.isEmpty {
                // Every word was unknown. Searching for nothing *but* the constraints would
                // answer "black suit under 400" with every product under 400, which is not
                // what was asked; saying the words are not there is.
                result.outcome = .notInYourShops(result.unknown)
                return result
            }
            guard hasConstraint else { return result }
        }

        if query.inMySize, !hasSizes {
            result.outcome = .noSizes
            return result
        }

        // What carries the words, before any constraint.
        var candidates: [(index: Int, matched: [String], score: Double)] = []
        for position in index.listings.indices {
            var matched: [String] = []
            var score = 0.0
            for term in required {
                if let weight = index.weight(of: term, at: position) {
                    matched.append(term.word)
                    score += weight
                }
            }
            guard required.isEmpty || !matched.isEmpty else { continue }
            candidates.append((position, matched, score))
        }

        // The constraints, in a fixed order, and the first to empty the list is the answer.
        let ruledOut = candidates.filter { entry in
            !query.excluded.contains { index.weight(of: $0, at: entry.index) != nil }
        }
        if ruledOut.isEmpty {
            result.outcome = .allRuledOut(query.excluded.map(\.word))
            return result
        }

        // The counts an empty answer prints are of what carried every word, where anything
        // did — "1 matches, none in your size" is about the trousers that were asked for, not
        // about everything else that happened to be black.
        func reported(_ entries: [(index: Int, matched: [String], score: Double)]) -> [(index: Int, matched: [String], score: Double)] {
            let complete = entries.filter { $0.matched.count == required.count }
            return complete.isEmpty ? entries : complete
        }

        let shown = ruledOut.filter { index.listings[$0.index].isShown }
        if shown.isEmpty {
            result.outcome = .hiddenByFilter(reported(ruledOut).count)
            return result
        }

        let priced = shown.filter { entry in
            let price = index.listings[entry.index].price
            if let ceiling = query.ceiling { guard let price, price <= ceiling else { return false } }
            if let floor = query.floor { guard let price, price >= floor else { return false } }
            return true
        }
        if priced.isEmpty {
            let counted = reported(shown)
            let cheapest = counted.compactMap { index.listings[$0.index].price }.min()
            result.outcome = .outsidePrice(count: counted.count, cheapest: cheapest)
            return result
        }

        var sized = priced
        if query.inMySize {
            sized = priced.filter { fits(index.listings[$0.index]) }
            if sized.isEmpty {
                result.outcome = .noneInYourSize(reported(priced).count)
                return result
            }
        }

        var exact = sized.filter { $0.matched.count == required.count }
        var partial = required.count >= 2 ? sized.filter { $0.matched.count < required.count } : []

        // "Cheaper" is the cheaper half of what matched, said as a number. A bare re-sort
        // would leave the page looking unchanged above the fold; a bound the reading prints
        // is a change the reader can see and undo.
        if query.cheaper {
            let pool = exact.isEmpty ? partial : exact
            let prices = pool.compactMap { index.listings[$0.index].price }.sorted()
            if !prices.isEmpty {
                let middle = prices[(prices.count - 1) / 2]
                result.cheaperThan = middle
                let under: ((index: Int, matched: [String], score: Double)) -> Bool = {
                    guard let price = index.listings[$0.index].price else { return false }
                    return price <= middle
                }
                exact = exact.filter(under)
                partial = partial.filter(under)
            }
        }

        let rank = ranking(query: query, index: index, among: exact.map(\.index) + partial.map(\.index))
        exact.sort(by: rank)
        partial.sort { a, b in
            a.matched.count != b.matched.count ? a.matched.count > b.matched.count : rank(a, b)
        }

        result.total = exact.count
        result.exact = exact.prefix(limit).map { hit(from: $0, in: index, isExact: true) }
        if exact.count < partialBelow {
            result.partial = partial.prefix(partialLimit).map { hit(from: $0, in: index, isExact: false) }
        }
        result.outcome = result.exact.isEmpty ? .closest : .found
        return result
    }

    private static func hit(
        from entry: (index: Int, matched: [String], score: Double),
        in index: ShopIndex,
        isExact: Bool
    ) -> Hit {
        Hit(listing: index.listings[entry.index], matched: entry.matched, isExact: isExact, score: entry.score)
    }

    /// The order a result list is read in. Total, so the same query gives the same page.
    ///
    /// - Parameter positions: the listings about to be sorted. Formality is worked out for
    ///   those alone, once each, rather than per comparison or for the whole store.
    private static func ranking(
        query: ShopQuery,
        index: ShopIndex,
        among positions: [Int]
    ) -> ((index: Int, matched: [String], score: Double), (index: Int, matched: [String], score: Double)) -> Bool {
        var formality: [Int: Int] = [:]
        if query.formal {
            for position in positions {
                var value = 0
                for token in index.tokens(at: position) {
                    if dressy.contains(token) { value += 1 }
                    if casual.contains(token) { value -= 1 }
                }
                formality[position] = value
            }
        }
        return { a, b in
            let one = index.listings[a.index], other = index.listings[b.index]
            // Something you can buy comes before something you cannot, whatever else is true.
            if one.isAvailable != other.isAvailable { return one.isAvailable }
            if query.cheaper, one.price != other.price {
                return (one.price ?? .infinity) < (other.price ?? .infinity)
            }
            if query.formal {
                let x = formality[a.index] ?? 0, y = formality[b.index] ?? 0
                if x != y { return x > y }
            }
            if a.score != b.score { return a.score > b.score }
            if one.relevance != other.relevance { return one.relevance > other.relevance }
            if one.publishedAt != other.publishedAt { return one.publishedAt > other.publishedAt }
            return one.id < other.id
        }
    }
}

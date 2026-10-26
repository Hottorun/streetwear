// ShopQuery.swift
// What somebody typed into Shop's field, read as a small grammar.
//
// Phase 4 puts a model behind this field and Phase 3 a whole catalogue under it. Until then
// the field is read by rules, over the products from the shops somebody follows that are
// already on the phone — and it is worth being as clear as `StyleStatement` is about what
// that means. **It is not language understanding and it never says it is.** It reads five
// things and treats every other word as a word to find:
//
// - **Words.** Matched as whole tokens against a product's title, type, tags, colourways,
//   measured colour and shop name — never substrings, the rule the whole codebase runs on:
//   "shorts" contains "short", and a `contains` check would answer "short sleeve tee" with
//   every pair of shorts in the store. A word's other number and a few true synonyms count
//   (`forms`); a colour also matches a photograph `ImageTagger` measured as that colour; a
//   category word ("shoes", "outerwear") also matches whatever the slot classifier placed
//   there, because it knows what footwear is better than any one title does.
// - **A price bound.** "under €400", "below 100", "over 50", "between 100 and 200",
//   "100-200", or an amount with a currency on it and no cue ("a black suit, €400"), which
//   is read as a ceiling. A bare number is a *word* — "990" and "1017" are names.
// - **"in my size".** A claim about the reader, so it goes through `SizeProfile.claims`
//   (never `matches`), in each product's own `SizeContext`.
// - **"no …" / "not …" / "without …".** The next word is ruled out. The one filter here that
//   hides, and only because it was asked for in so many words.
// - **Two leanings** — "cheap"/"budget" and "formal"/"smart"/"dressy" — which are the same
//   flags the chips under the field set, so typing it and tapping it cannot disagree.
//
// Everything else — "something", "for", "please" — is dropped, and the field prints back
// what it kept (`reading`), in the app's data voice under the box: "BLACK · SUIT · UNDER
// 400". A field that changes results without saying how is a black box, and a black box that
// is sometimes wrong is worse than none; the reading is what makes it correctable.
//
// In `StreetwCore` and pure, so it can be tested without a store and so the grammar has one
// home when the model arrives to replace it.

import Foundation

public struct ShopQuery: Sendable, Hashable {
    /// One word to find, with every spelling that counts as finding it.
    public struct Term: Sendable, Hashable {
        /// As typed, lowercased — what the reading prints.
        public var word: String
        /// Whole tokens that count as this word: itself, its other number, its synonyms.
        public var forms: Set<String>
        /// The colour this names, canonical (`ColorHarmony`), so a garment whose photograph
        /// was measured black is found by "black" even when its title never says so.
        public var colour: String?
        /// The slot this names, so "shoes" finds boots and loafers by classification.
        public var slot: GarmentSlot?

        public init(word: String, forms: Set<String>, colour: String? = nil, slot: GarmentSlot? = nil) {
            self.word = word
            self.forms = forms
            self.colour = colour
            self.slot = slot
        }
    }

    /// Exactly what was typed.
    public var text: String
    /// What to find. A product has to carry every one that exists anywhere in the shops.
    public var terms: [Term]
    /// What was ruled out — "no wool".
    public var excluded: [Term]
    /// Inclusive bounds on the price, in whatever currency each shop prices in. See
    /// `readAmount` for why nothing is converted.
    public var ceiling: Double?
    public var floor: Double?
    public var inMySize: Bool
    public var cheaper: Bool
    public var formal: Bool
    /// Things the parse recognised and will not act on, printed so the reading says what was
    /// left out rather than leaving the reader to wonder — "SIZE 10".
    public var ignored: [String]

    public init(
        text: String = "",
        terms: [Term] = [],
        excluded: [Term] = [],
        ceiling: Double? = nil,
        floor: Double? = nil,
        inMySize: Bool = false,
        cheaper: Bool = false,
        formal: Bool = false,
        ignored: [String] = []
    ) {
        self.text = text
        self.terms = terms
        self.excluded = excluded
        self.ceiling = ceiling
        self.floor = floor
        self.inMySize = inMySize
        self.cheaper = cheaper
        self.formal = formal
        self.ignored = ignored
    }

    /// Nothing to act on at all: no word, no bound, no leaning.
    public var isEmpty: Bool {
        terms.isEmpty && excluded.isEmpty && ceiling == nil && floor == nil
            && !inMySize && !cheaper && !formal
    }

    /// The chips under the field, folded in. They set the same flags the typed words do, so
    /// "cheap black hoodie" and "black hoodie" + CHEAPER are one query and print one reading.
    public func refined(cheaper: Bool, formal: Bool, inMySize: Bool) -> ShopQuery {
        var copy = self
        copy.cheaper = copy.cheaper || cheaper
        copy.formal = copy.formal || formal
        copy.inMySize = copy.inMySize || inMySize
        return copy
    }

    // MARK: - Saying what was understood

    /// Everything the parse acted on, in the order it is worth reading back.
    ///
    /// The price is printed **without a currency**, even when one was typed. Each shop is
    /// compared in its own currency and nothing is converted, so "UNDER €400" would claim a
    /// conversion that did not happen; "UNDER 400" says what was actually compared.
    public var reading: [String] {
        var out = terms.map(\.word)
        out += excluded.map { "not \($0.word)" }
        switch (floor, ceiling) {
        case let (low?, high?): out.append("\(Self.amount(low))–\(Self.amount(high))")
        case let (nil, high?): out.append("under \(Self.amount(high))")
        case let (low?, nil): out.append("over \(Self.amount(low))")
        case (nil, nil): break
        }
        if inMySize { out.append("in your size") }
        if formal { out.append("more formal") }
        if cheaper { out.append("cheaper") }
        return out
    }

    /// "400", "149.99" — whole numbers without a decimal point, because a bound typed as
    /// "400" printed back as "400.0" reads as the app having misheard it.
    public static func amount(_ value: Double) -> String {
        value.rounded() == value ? String(Int(value)) : String(format: "%.2f", value)
    }

    // MARK: - Reading a sentence

    public static func parse(_ text: String) -> ShopQuery {
        var query = ShopQuery(text: text)
        let lexemes = Lexer.lex(text)
        var index = 0

        func word(at offset: Int) -> String? {
            guard index + offset < lexemes.count, case .word(let value) = lexemes[index + offset] else { return nil }
            return value
        }

        while index < lexemes.count {
            // A price, in any of its shapes, before anything else — "no more than 200" is a
            // ceiling and not a negation of "more".
            if let (bound, consumed) = readPrice(lexemes, at: index) {
                switch bound {
                case .ceiling(let value): query.ceiling = min(query.ceiling ?? value, value)
                case .floor(let value): query.floor = max(query.floor ?? value, value)
                case .range(let low, let high):
                    query.floor = max(query.floor ?? low, low)
                    query.ceiling = min(query.ceiling ?? high, high)
                }
                index += consumed
                continue
            }

            guard case .word(let current) = lexemes[index] else {
                // A number nothing claimed as a price is a name — "990", "1017" — and is
                // searched for like any other word.
                if case .number(let value, let raw) = lexemes[index], value >= 0 {
                    query.add(term: raw)
                }
                index += 1
                continue
            }

            // "in my size", "my sizes", "fits me".
            if let consumed = sizePhrase(lexemes, at: index) {
                query.inMySize = true
                index += consumed
                continue
            }

            // "size 10" names one size, which this cannot act on: the only size it knows how
            // to read is the reader's own, on each garment's own ladder. Saying so beats
            // searching for a "10" that no title contains.
            if current == "size" || current == "sizes" {
                if index + 1 < lexemes.count, let named = sizeName(lexemes[index + 1]) {
                    query.ignored.append("size \(named)")
                    index += 2
                } else {
                    index += 1
                }
                continue
            }

            if negations.contains(current) {
                // The next word that means something is the one ruled out — "no big logos"
                // rules out logos, so "big" is skipped as the filler it is.
                var next = index + 1
                while next < lexemes.count, case .word(let candidate) = lexemes[next],
                      stopwords.contains(candidate) || negations.contains(candidate) || qualifiers.contains(candidate) {
                    next += 1
                }
                if next < lexemes.count, case .word(let ruledOut) = lexemes[next] {
                    if let term = term(for: ruledOut), !query.excluded.contains(where: { $0.word == term.word }) {
                        query.excluded.append(term)
                    }
                    index = next + 1
                } else {
                    index += 1
                }
                continue
            }

            if cheapWords.contains(current) { query.cheaper = true; index += 1; continue }
            if formalWords.contains(current) { query.formal = true; index += 1; continue }
            if stopwords.contains(current) || qualifiers.contains(current) || currencyWords.contains(current) {
                index += 1
                continue
            }

            // Joined across a hyphen or a space where a garment's name is two words, so
            // "t-shirt" is one term and not a search for "t" and "shirt".
            if let following = word(at: 1), let joined = Self.compounds[current + " " + following] {
                query.add(term: joined, as: current + "-" + following)
                index += 2
                continue
            }

            query.add(term: current)
            index += 1
        }

        // A word cannot be both wanted and ruled out; the ruling out is the later, sharper
        // statement, the same precedence `StyleStatement` gives a dislike.
        let ruledOut = Set(query.excluded.map(\.word))
        query.terms.removeAll { ruledOut.contains($0.word) }
        if let low = query.floor, let high = query.ceiling, low > high {
            // "over 300 under 100" asks for nothing; reading it as the range it was surely
            // meant to be is kinder than an empty page for a typo.
            query.floor = high
            query.ceiling = low
        }
        return query
    }

    private mutating func add(term word: String, as label: String? = nil) {
        guard let term = Self.term(for: word, as: label), !terms.contains(where: { $0.word == term.word }) else { return }
        terms.append(term)
    }

    /// The term for one word, or nil for a word too short to mean anything.
    ///
    /// - Parameter label: what to print, where it differs from the token — a compound is
    ///   matched as "tshirt" and read back as "t-shirt".
    static func term(for raw: String, as label: String? = nil) -> Term? {
        let word = raw.lowercased()
        guard word.count >= 2 || word.allSatisfy(\.isNumber) else { return nil }
        var forms: Set<String> = [word]
        if !fixedNumber.contains(word), !word.allSatisfy(\.isNumber) {
            forms.formUnion(otherNumbers(of: word))
        }
        for form in Array(forms) {
            forms.formUnion(synonyms[form] ?? [])
        }

        let colour = ColorHarmony.canonicalName(of: colourAliases[word] ?? word)
        if let colour {
            forms.insert(colour.lowercased())
            for (alias, canonical) in colourAliases where canonical == colour.lowercased() {
                forms.insert(alias)
            }
        }
        return Term(word: label ?? word, forms: forms, colour: colour, slot: categories[word])
    }

    /// The word's other grammatical number, as whole tokens. Conservative on purpose: a
    /// form that does not exist costs nothing, and a wrong one joins two garments.
    static func otherNumbers(of word: String) -> Set<String> {
        var out: Set<String> = [word + "s"]
        if word.hasSuffix("s") || word.hasSuffix("x") || word.hasSuffix("ch") || word.hasSuffix("sh") {
            out.insert(word + "es")
        }
        if word.hasSuffix("ies"), word.count > 4 { out.insert(String(word.dropLast(3)) + "y") }
        if word.hasSuffix("y"), word.count > 3 { out.insert(String(word.dropLast()) + "ies") }
        if word.hasSuffix("es"), word.count > 4 { out.insert(String(word.dropLast(2))) }
        if word.hasSuffix("s"), !word.hasSuffix("ss"), word.count > 3 { out.insert(String(word.dropLast())) }
        return out
    }

    // MARK: - Prices

    enum Bound: Equatable {
        case ceiling(Double)
        case floor(Double)
        case range(Double, Double)
    }

    /// A price starting at `index`, and how many lexemes it used.
    static func readPrice(_ lexemes: [Lexeme], at index: Int) -> (Bound, Int)? {
        // "between 100 and 200", "from 100 to 200".
        if case .word(let cue) = lexemes[index], cue == "between" || cue == "from",
           let (low, used) = readAmount(lexemes, at: index + 1),
           index + 1 + used < lexemes.count,
           case .word(let joiner) = lexemes[index + 1 + used], joiner == "and" || joiner == "to",
           let (high, more) = readAmount(lexemes, at: index + 2 + used) {
            return (.range(min(low.value, high.value), max(low.value, high.value)), 2 + used + more)
        }

        for (phrase, isCeiling) in cues {
            guard matches(phrase, in: lexemes, at: index),
                  let (amount, used) = readAmount(lexemes, at: index + phrase.count)
            else { continue }
            return (isCeiling ? .ceiling(amount.value) : .floor(amount.value), phrase.count + used)
        }

        guard let (low, used) = readAmount(lexemes, at: index) else { return nil }

        // "100-200", "€100 to €200".
        if index + used < lexemes.count {
            let joins: Bool
            switch lexemes[index + used] {
            case .dash: joins = true
            case .word(let joiner): joins = joiner == "to"
            default: joins = false
            }
            if joins, let (high, more) = readAmount(lexemes, at: index + used + 1) {
                return (.range(min(low.value, high.value), max(low.value, high.value)), used + 1 + more)
            }
        }
        // An amount with a currency and no cue at all — "a black suit, €400" — is a budget.
        // Without a currency it is a name, and stays a word.
        return low.hasCurrency ? (.ceiling(low.value), used) : nil
    }

    struct Amount {
        var value: Double
        var hasCurrency: Bool
    }

    /// A number with an optional currency either side: "€400", "400 eur", "$1,200", "1.2k".
    ///
    /// **The currency is read and then deliberately ignored.** Shops price in their own
    /// currency and the store keeps that number; converting would need rates the app does not
    /// fetch, and a guessed rate is a wrong answer presented as a right one. A euro, a dollar
    /// and a pound are close enough that a bound in one means roughly the same in the others,
    /// which is the honest extent of what this can do until prices carry their region
    /// (`ROADMAP.md`, Phase 2).
    static func readAmount(_ lexemes: [Lexeme], at index: Int) -> (Amount, Int)? {
        var cursor = index
        var hasCurrency = false
        if cursor < lexemes.count, lexemes[cursor].isCurrency {
            hasCurrency = true
            cursor += 1
        }
        guard cursor < lexemes.count, case .number(let value, _) = lexemes[cursor] else { return nil }
        cursor += 1
        if cursor < lexemes.count, lexemes[cursor].isCurrency {
            hasCurrency = true
            cursor += 1
        }
        return (Amount(value: value, hasCurrency: hasCurrency), cursor - index)
    }

    private static func matches(_ phrase: [String], in lexemes: [Lexeme], at index: Int) -> Bool {
        guard index + phrase.count <= lexemes.count else { return false }
        for (offset, expected) in phrase.enumerated() {
            switch lexemes[index + offset] {
            case .word(let value) where value == expected: continue
            case .symbol(let value) where value == expected: continue
            default: return false
            }
        }
        return true
    }

    /// Longest first, so "no more than" is tried before anything that starts with "no".
    static let cues: [([String], Bool)] = [
        (["no", "more", "than"], true), (["not", "more", "than"], true),
        (["nothing", "over"], true), (["nothing", "above"], true), (["not", "over"], true),
        (["less", "than"], true), (["cheaper", "than"], true), (["up", "to"], true),
        (["at", "most"], true), (["at", "least"], false), (["more", "than"], false),
        (["budget", "of"], true),
        (["under"], true), (["below"], true), (["max"], true), (["maximum"], true),
        (["within"], true), (["upto"], true), (["budget"], true), (["<"], true), (["≤"], true),
        (["over"], false), (["above"], false), (["min"], false), (["minimum"], false),
        (["from"], false), ([">"], false), (["≥"], false)
    ]

    // MARK: - Size phrases

    private static func sizePhrase(_ lexemes: [Lexeme], at index: Int) -> Int? {
        for phrase in [["in", "my", "size"], ["in", "my", "sizes"], ["my", "size"], ["my", "sizes"], ["fits", "me"]]
        where matches(phrase, in: lexemes, at: index) {
            return phrase.count
        }
        return nil
    }

    private static func sizeName(_ lexeme: Lexeme) -> String? {
        switch lexeme {
        case .number(_, let raw): return raw
        case .word(let value) where sizeLetters.contains(value): return value.uppercased()
        default: return nil
        }
    }

    private static let sizeLetters: Set<String> = ["xxs", "xs", "s", "m", "l", "xl", "xxl", "xxxl", "small", "medium", "large"]

    // MARK: - The vocabulary

    /// Words that carry no information about what to find. Kept short for the reason
    /// `StyleStatement.filler` is: an over-eager list silently deletes the one word that
    /// mattered, and a stray word left in costs only a line in the reading saying it was not
    /// found.
    static let stopwords: Set<String> = [
        "a", "an", "the", "some", "something", "anything", "any", "for", "in", "on", "of", "to",
        "with", "and", "or", "i", "im", "me", "my", "mine", "want", "wants", "need", "needs",
        "looking", "look", "find", "show", "get", "buy", "please", "like", "would", "could",
        "can", "that", "this", "these", "those", "is", "are", "be", "it", "its", "one", "ones",
        "nice", "good", "great", "really", "very", "pretty", "kind", "sort", "thing", "things",
        "stuff", "piece", "pieces", "item", "items", "wear", "wearing", "go", "goes", "which",
        "what", "around", "about", "roughly", "approximately", "ish", "price", "priced", "cost",
        "costs", "costing", "spend", "new", "maybe", "also", "just", "too", "much", "at",
        // The price cues, for when no amount follows them and they are only words.
        "under", "below", "over", "above", "max", "maximum", "min", "minimum", "within", "upto",
        "than", "least", "most", "from", "between", "up"
    ]

    /// Words that describe how much of something, skipped after a negation ("no big logos").
    static let qualifiers: Set<String> = ["big", "small", "huge", "large", "loud", "visible", "obvious", "more", "less"]

    static let negations: Set<String> = ["no", "not", "without", "non", "never", "except", "dont", "nothing"]

    static let cheapWords: Set<String> = ["cheap", "cheaper", "cheapest", "affordable", "inexpensive", "bargain", "budget"]

    static let formalWords: Set<String> = ["formal", "smart", "smarter", "dressy", "dressier", "elegant", "dressed"]

    static let currencyWords: Set<String> = [
        "eur", "euro", "euros", "usd", "dollar", "dollars", "bucks", "gbp", "pound", "pounds",
        "quid", "chf", "sek", "dkk", "nok", "jpy", "yen", "cad", "aud"
    ]

    /// Two words that name one garment. Applied to products and queries alike
    /// (`ShopText.tokens`), so both sides agree on what a token is.
    public static let compounds: [String: String] = [
        "t shirt": "tshirt", "t shirts": "tshirts", "off white": "offwhite",
        "crew neck": "crewneck", "half zip": "halfzip", "quarter zip": "quarterzip",
        "long sleeve": "longsleeve", "short sleeve": "shortsleeve", "button down": "buttondown",
        "zip up": "zipup", "roll neck": "rollneck", "polo shirt": "polo"
    ]

    /// Words whose other number is a different garment. "short" is a sleeve, "shorts" are
    /// trousers; folding them is the substring bug by another route.
    static let fixedNumber: Set<String> = ["short", "shorts", "glass", "glasses"]

    /// Same garment, another word — and only that. Each entry is a set of interchangeable
    /// names; a broader word may list the narrower kinds it covers (a coat query finds an
    /// overcoat), never the other way round. Anything looser than that — "suit" finding
    /// trousers, "warm" finding wool — is a guess about what was meant, and guessing is the
    /// model's job when it arrives.
    static let synonyms: [String: Set<String>] = {
        let interchangeable: [Set<String>] = [
            ["tee", "tees", "tshirt", "tshirts"],
            ["trouser", "trousers", "pant", "pants", "slacks"],
            ["sweater", "sweaters", "jumper", "jumpers", "pullover", "pullovers"],
            ["sneaker", "sneakers", "trainer", "trainers"],
            ["hoodie", "hoodies", "hoody"],
            ["sweatpant", "sweatpants", "jogger", "joggers"],
            ["suit", "suits", "suiting"],
            ["knit", "knits", "knitwear"]
        ]
        let covers: [String: Set<String>] = [
            "coat": ["overcoat", "overcoats", "topcoat", "peacoat", "raincoat", "trenchcoat"],
            "coats": ["overcoat", "overcoats", "topcoat", "peacoat", "raincoat", "trenchcoat"],
            "sweatshirt": ["crewneck", "crewnecks"],
            "sweatshirts": ["crewneck", "crewnecks"],
            "bag": ["tote", "totes", "backpack", "crossbody", "holdall", "duffel", "duffle"],
            "bags": ["tote", "totes", "backpack", "crossbody", "holdall", "duffel", "duffle"],
            "boot": ["boots"], "boots": ["boot"]
        ]
        var out: [String: Set<String>] = covers
        for group in interchangeable {
            for word in group { out[word, default: []].formUnion(group) }
        }
        return out
    }()

    /// A category, answered by the slot classifier as well as by the word.
    static let categories: [String: GarmentSlot] = [
        "outerwear": .outerwear, "top": .top, "tops": .top, "bottoms": .bottom,
        "footwear": .footwear, "shoe": .footwear, "shoes": .footwear,
        "headwear": .headwear, "hat": .headwear, "hats": .headwear,
        "accessory": .accessory, "accessories": .accessory
    ]

    /// Other spellings of the colours `ColorHarmony` knows, and nothing more adventurous —
    /// "khaki" is a tan in New York and an olive in London, and "stone" would find every
    /// product Stone Island makes.
    static let colourAliases: [String: String] = [
        "gray": "grey", "ecru": "cream", "ivory": "cream", "offwhite": "cream", "bone": "cream",
        "maroon": "burgundy", "oxblood": "burgundy", "camel": "tan"
    ]
}

// MARK: - Tokens

/// One unit of a typed query.
enum Lexeme: Equatable {
    case word(String)
    /// The value, and the digits as typed — a number nothing claims as a price is searched
    /// for as a name ("990"), and has to be searched for as it was written.
    case number(Double, String)
    case currency(String)
    case symbol(String)
    case dash

    var isCurrency: Bool {
        switch self {
        case .currency: true
        case .word(let value): ShopQuery.currencyWords.contains(value)
        default: false
        }
    }
}

enum Lexer {
    static let currencySymbols: Set<Character> = ["€", "$", "£", "¥"]

    /// Words, numbers, currencies and the few symbols a price uses.
    ///
    /// Numbers keep their separators where a separator is part of the number: "1,200" and
    /// "1.200" are twelve hundred (a group of exactly three digits), "149.99" and "149,99"
    /// are a price, and a trailing "k" multiplies — "1.5k". Everything else splits.
    static func lex(_ text: String) -> [Lexeme] {
        let characters = Array(ShopText.folded(text))
        var out: [Lexeme] = []
        var index = 0

        while index < characters.count {
            let character = characters[index]

            if character.isLetter {
                var end = index
                while end < characters.count, characters[end].isLetter || characters[end] == "'" { end += 1 }
                let word = String(characters[index..<end]).replacingOccurrences(of: "'", with: "")
                // "400eur" lexes as a number then a word; a word stuck to digits after it
                // ("w32") is a name and stays one token.
                if end < characters.count, characters[end].isNumber {
                    var tail = end
                    while tail < characters.count, characters[tail].isLetter || characters[tail].isNumber { tail += 1 }
                    out.append(.word(String(characters[index..<tail])))
                    index = tail
                } else {
                    out.append(.word(word))
                    index = end
                }
                continue
            }

            if character.isNumber {
                let (lexeme, end) = number(in: characters, from: index)
                out.append(lexeme)
                index = end
                continue
            }

            if currencySymbols.contains(character) {
                out.append(.currency(String(character)))
            } else if character == "-" || character == "–" || character == "—" {
                // A hyphen between two words joins a compound ("t-shirt") and is dropped; it
                // only means a range between two numbers.
                if case .number = out.last { out.append(.dash) }
            } else if "<>≤≥".contains(character) {
                out.append(.symbol(String(character)))
            }
            index += 1
        }
        return out
    }

    private static func number(in characters: [Character], from start: Int) -> (Lexeme, Int) {
        var digits = ""
        var index = start
        while index < characters.count {
            let character = characters[index]
            if character.isNumber {
                digits.append(character)
                index += 1
                continue
            }
            if character == "," || character == ".", index + 1 < characters.count, characters[index + 1].isNumber {
                var run = 0
                while index + 1 + run < characters.count, characters[index + 1 + run].isNumber { run += 1 }
                if run == 3 {
                    // A thousands group: "1,200", "1.200".
                    index += 1
                    continue
                }
                if !digits.contains("."), run <= 2 {
                    digits.append(".")
                    index += 1
                    continue
                }
            }
            break
        }
        // A size or a model number with letters attached ("10.5w", "550s") is a name.
        if index < characters.count, characters[index].isLetter {
            var tail = index
            while tail < characters.count, characters[tail].isLetter || characters[tail].isNumber { tail += 1 }
            let suffix = String(characters[index..<tail])
            if suffix == "k", let value = Double(digits) {
                return (.number(value * 1000, digits + "k"), tail)
            }
            if ShopQuery.currencyWords.contains(suffix), let value = Double(digits) {
                // "400eur": the number, then the currency, as two lexemes. Re-entering the
                // loop at the suffix lets the caller read it.
                return (.number(value, digits), index)
            }
            return (.word(digits + suffix), tail)
        }
        return (.number(Double(digits) ?? 0, digits), index)
    }
}

/// How product text is cut into the tokens a query is matched against.
///
/// One tokeniser for both sides, so a query and a product always agree on what a token is:
/// lowercased, accents folded ("Stüssy" is "stussy"), split on anything that is not a letter
/// or a digit, and the two-word garment names in `ShopQuery.compounds` joined — with the
/// parts kept too, so "white" still finds an Off-White sneaker.
public enum ShopText {
    public static func tokens(_ text: String) -> [String] {
        let parts = folded(text)
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
        var out = parts
        for (first, second) in zip(parts, parts.dropFirst()) {
            if let joined = ShopQuery.compounds[first + " " + second] { out.append(joined) }
        }
        return out
    }

    static func folded(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).lowercased()
    }
}

// StyleStatement.swift
// What somebody says they wear, in their own words, turned into something the app can use.
//
// Every signal in this app is inferred. Saves make a taste vector, photographs make a colour
// and a busyness, catalogue copy makes a slot and a gender — all of it read off behaviour,
// none of it *asked*. That is deliberate and it is also the reason the app can be
// confidently wrong for weeks: somebody who has kept four things has a taste profile built
// from four things, and somebody who wears checkered shirts with black shorts has no way to
// say so except by saving enough of them that the arithmetic notices.
//
// So: one free-text field, read on the device, that says the plain thing. It is worth being
// clear about what this is *not* — it is not natural-language understanding and it does not
// pretend to be. It looks for three things and ignores everything else:
//
// - **Words you like.** Colours (via `ColorHarmony`, so there is one list of colour names in
//   the codebase rather than two) and any other word long enough to mean something. These
//   are matched against a garment's own vocabulary, which is the same set of tokens
//   `GarmentClassifier` and `Pairing` already read.
// - **Words you don't.** A clause that opens with a negation — "no logos", "I don't wear
//   skinny jeans" — contributes the other way. A dislike is the sharper signal of the two
//   and there was previously no way at all to express one about clothes, only about brands.
// - **Things you wear together.** "checkered with black shorts" is a *pairing*, and a
//   pairing is exactly the shape `Pairing` and `FitSuggestions` are looking for. Split on
//   "with", the two sides become a stated affinity that outranks anything the colour wheel
//   would have worked out on its own — because it is not a guess.
//
// The honest limitations, stated rather than papered over: word order is ignored, "I used to
// wear" reads as "I wear", and a sentence about the weather contributes noise. The costs are
// bounded by where the output is used — a *reordering* of suggestions and a nudge to the
// brand ranking, never a filter. Nothing is ever hidden because of what is written here.
//
// In `StreetwCore` because both the pairing rules and the fit builder consume it and neither
// may disagree with the other about the same two garments — the same argument that put
// `ColorHarmony` here.

import Foundation

public struct StyleStatement: Codable, Sendable, Hashable {
    /// Exactly what was typed. Kept so the field can be edited rather than re-derived from
    /// the parse, which would lose the sentence and hand back a word list.
    public var text: String

    /// Words that count in a garment's favour.
    public var likes: Set<String>

    /// Words that count against it. Never a filter — see the note above.
    public var dislikes: Set<String>

    /// Two sets of words stated as going together.
    public struct StatedPairing: Codable, Sendable, Hashable {
        public var one: Set<String>
        public var other: Set<String>

        public init(one: Set<String>, other: Set<String>) {
            self.one = one
            self.other = other
        }
    }

    public var pairings: [StatedPairing]

    public var isEmpty: Bool {
        likes.isEmpty && dislikes.isEmpty && pairings.isEmpty
    }

    public init(
        text: String = "",
        likes: Set<String> = [],
        dislikes: Set<String> = [],
        pairings: [StatedPairing] = []
    ) {
        self.text = text
        self.likes = likes
        self.dislikes = dislikes
        self.pairings = pairings
    }

    /// Decoded by hand and leniently, for the reason every stored value in this app is: a
    /// field added later must not be a crash on launch for somebody holding the older shape.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        text = (try? container.decode(String.self, forKey: .text)) ?? ""
        likes = (try? container.decode(Set<String>.self, forKey: .likes)) ?? []
        dislikes = (try? container.decode(Set<String>.self, forKey: .dislikes)) ?? []
        pairings = (try? container.decode([StatedPairing].self, forKey: .pairings)) ?? []
    }

    // MARK: - Reading a sentence

    /// Everything the parse understood, in the order it is worth showing back.
    ///
    /// A field that silently changes what the app does is a black box, and a black box that
    /// is sometimes wrong is worse than no field. Printing the reading under the box is what
    /// makes it correctable: somebody who writes "I like fits with a bit of colour" and is
    /// shown `bit · colour` can see immediately that it understood less than they meant.
    public var reading: [String] {
        var out = pairings.map { pairing in
            "\(pairing.one.sorted().joined(separator: " ")) + \(pairing.other.sorted().joined(separator: " "))"
        }
        // Words already accounted for by a pairing are not repeated — the pairing is the
        // stronger statement and printing both reads as the app having double-counted.
        let paired = pairings.reduce(into: Set<String>()) { $0.formUnion($1.one); $0.formUnion($1.other) }
        out += likes.subtracting(paired).sorted()
        out += dislikes.sorted().map { "not \($0)" }
        return out
    }

    public static func parse(_ text: String) -> StyleStatement {
        var statement = StyleStatement(text: text)

        for clause in clauses(in: text) {
            let negated = isNegated(clause)
            // "with" is the only word given structural meaning, because it is the only one
            // that reliably names a *relationship* between two garments rather than a
            // property of one. "and" was tried and is useless: "black and white" is one
            // garment as often as it is two.
            let sides = clause
                .components(separatedBy: " with ")
                .map { terms(in: $0) }
                .filter { !$0.isEmpty }

            let all = sides.reduce(into: Set<String>()) { $0.formUnion($1) }
            guard !all.isEmpty else { continue }

            if negated {
                statement.dislikes.formUnion(all)
                continue
            }
            statement.likes.formUnion(all)
            if sides.count >= 2 {
                // Every side against every later side, so "a tee with shorts with sliders"
                // states three pairings and not two.
                for (index, side) in sides.enumerated() {
                    for other in sides.dropFirst(index + 1) {
                        statement.pairings.append(StatedPairing(one: side, other: other))
                    }
                }
            }
        }

        // A word cannot be both. A later "but not black" is the correction, so the dislike
        // wins — that is what "but" is for.
        statement.likes.subtract(statement.dislikes)
        return statement
    }

    /// How much this garment matches what was written, −1…1.
    ///
    /// Saturating rather than additive: three matching words is a stronger signal than one,
    /// and thirty is not ten times stronger than three — it means the sentence was vague.
    public func affinity(for garment: Garment) -> Double {
        guard !isEmpty else { return 0 }
        let words = vocabulary(of: garment)
        let liked = likes.intersection(words).count
        let disliked = dislikes.intersection(words).count
        guard liked > 0 || disliked > 0 else { return 0 }
        return saturating(liked) - saturating(disliked)
    }

    /// Whether these two were named together, and what to call it if so.
    ///
    /// This is the part worth having. A stated pairing is not an inference from a colour
    /// wheel or a slot table — it is somebody saying, in words, that they wear these two
    /// things together — so it outranks everything the rules would have concluded on their
    /// own, and the card can say why in their own terms.
    public func statedPairing(between one: Garment, and other: Garment) -> Bool {
        let a = vocabulary(of: one), b = vocabulary(of: other)
        return pairings.contains { pairing in
            (!pairing.one.isDisjoint(with: a) && !pairing.other.isDisjoint(with: b))
                || (!pairing.one.isDisjoint(with: b) && !pairing.other.isDisjoint(with: a))
        }
    }

    /// Folds what was written into a taste vector, so brand recommendations hear it too.
    ///
    /// Additive and modest. The vector is built from what somebody has actually kept, which
    /// is a record of behaviour; this is a claim about themselves, and the two are not the
    /// same kind of evidence — somebody who writes "workwear" and has saved forty technical
    /// shells means something by both. A stated word is worth roughly as much as a term that
    /// turns up in a handful of saves, which is enough to break a tie and not enough to
    /// rewrite the list.
    ///
    /// Only terms the reference set already uses survive, exactly as `BrandVectorBuilder`
    /// does for saves: a word no brand's catalogue contains can never contribute to a cosine
    /// and would only distort the norm. Dislikes are deliberately absent — a brand is not
    /// demoted for stocking one thing somebody avoids, and `BrandDismissal` is the place a
    /// negative signal about a *brand* belongs.
    public func blended(into taste: BrandVector, known: Set<String>) -> BrandVector {
        guard !likes.isEmpty else { return taste }
        let usable = known.isEmpty ? likes : likes.intersection(known)
        guard !usable.isEmpty else { return taste }

        var vocabulary = taste.vocabulary
        // A share of the vector's existing weight rather than an absolute number: the
        // vocabulary is L2-normalised, so a fixed value would mean one thing on a rich taste
        // profile and something else entirely on a thin one.
        let scale = max(taste.vocabulary.values.max() ?? 0, 0.2) * 0.6
        for term in usable {
            vocabulary[term] = max(vocabulary[term] ?? 0, scale)
        }

        var blended = taste
        blended.vocabulary = normalised(vocabulary)
        return blended
    }

    private func normalised(_ terms: [String: Double]) -> [String: Double] {
        let norm = (terms.values.reduce(0) { $0 + $1 * $1 }).squareRoot()
        guard norm > 0 else { return terms }
        return terms.mapValues { $0 / norm }
    }

    /// A garment's words *plus* its measured colour, lowercased.
    ///
    /// The colour matters: somebody who writes "black shorts" is describing a photograph,
    /// not a product title, and plenty of black garments never say so in their name. Where
    /// `ImageTagger` has looked, the app knows better than the copy does.
    private func vocabulary(of garment: Garment) -> Set<String> {
        var words = garment.vocabulary
        for colour in [garment.color, garment.secondaryColor] {
            if let colour { words.insert(colour.lowercased()) }
        }
        return words
    }

    /// 1 match → 0.6, 2 → 0.84, 3 → 0.94. Never quite 1.
    private func saturating(_ count: Int) -> Double {
        guard count > 0 else { return 0 }
        return 1 - pow(0.4, Double(count))
    }

    // MARK: - Tokenising

    /// Sentence-ish units. A clause is the largest span that can be entirely positive or
    /// entirely negative, so "but" and "except" split as hard as a full stop does.
    private static func clauses(in text: String) -> [String] {
        let lowered = " " + text.lowercased() + " "
        var parts = [lowered]
        for separator in [".", ",", ";", "\n", " but ", " except ", " although ", " though "] {
            parts = parts.flatMap { $0.components(separatedBy: separator) }
        }
        return parts
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    private static func isNegated(_ clause: String) -> Bool {
        let padded = " \(clause) "
        return negations.contains { padded.contains(" \($0) ") }
    }

    private static let negations: Set<String> = [
        "not", "no", "never", "dont", "don't", "doesnt", "doesn't", "avoid", "avoiding",
        "hate", "dislike", "without", "cant", "can't", "wont", "won't", "rarely"
    ]

    /// The words in one clause that are worth keeping.
    static func terms(in clause: String) -> Set<String> {
        var found: Set<String> = []
        for raw in clause.lowercased().split(whereSeparator: { !$0.isLetter && $0 != "-" }) {
            let word = String(raw).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
            guard word.count >= 3, !filler.contains(word) else { continue }
            // Canonicalised through the colour wheel where it is a colour, so "Black" and
            // "black" are one term and match what `ImageTagger` stored.
            found.insert(ColorHarmony.canonicalName(of: word)?.lowercased() ?? word)
        }
        return found
    }

    /// Words that carry no information about clothes.
    ///
    /// Everything here is a word somebody *will* type in a sentence about how they dress and
    /// which describes none of it. Kept short on purpose: an over-eager stop list quietly
    /// deletes the one word that mattered, and the cost of a stray term is a small nudge to
    /// a ranking rather than anything anybody can see.
    private static let filler: Set<String> = [
        "like", "likes", "liked", "love", "loves", "wear", "wears", "wearing", "worn",
        "usually", "always", "sometimes", "often", "mostly", "really", "very", "quite",
        "the", "and", "with", "for", "but", "not", "you", "your", "yours", "our",
        "that", "this", "these", "those", "them", "they", "some", "any", "all",
        "thing", "things", "stuff", "kind", "kinds", "sort", "sorts", "bit", "lot", "lots",
        "fit", "fits", "outfit", "outfits", "style", "styles", "look", "looks", "vibe",
        "day", "days", "time", "times", "when", "where", "what", "how", "who", "why",
        "prefer", "prefers", "into", "about", "over", "under", "just", "also", "than",
        "more", "most", "less", "least", "good", "nice", "cool", "own", "get", "got",
        "myself", "mine", "have", "has", "had", "been", "was", "are", "were", "will",
        "can", "would", "could", "should", "there", "here", "out", "put", "make", "made"
    ]
}

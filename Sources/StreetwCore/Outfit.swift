// Outfit.swift
// Whether several garments work together — which is not the same question as whether any
// two of them do.
//
// `Pairing` answers "does this go with that", and every fit in the app was ranked on it: a
// proposal's score was the verdict on its top against its bottom, with the shoes and the
// jacket chosen afterwards against whatever was already picked. That is a reasonable way to
// *build* an outfit and a poor way to *judge* one, because the three rules people actually
// use when they look at a finished fit are all properties of the whole thing and cannot be
// seen from any pair inside it:
//
// - **How many colours are in play.** Two garments are never "too many colours". Four can
//   be, and the fix is always the same one — let one piece carry the colour and keep the
//   rest quiet.
// - **How many pieces are shouting.** `Pairing` already declines to put two loud things
//   together, and an outfit of four garments can pass every pair while three of them are
//   printed.
// - **Whether anything is repeated.** A colour appearing twice — the cap and the shoes, the
//   jacket and the trainer — is the oldest trick in dressing, and it is invisible pairwise
//   because the two pieces that echo each other are usually not the pair being scored.
//
// The measured inputs are the same ones `ImageTagger` already writes, so this costs nothing
// new: a dominant colour, an accent, busyness, text coverage, and the silhouette. Nothing
// here is trained, for the reason written across this codebase — there is nothing to train
// on, and a recommender that is clever and wrong is worse than one that is obvious and
// right. What it *can* do is say why, which is what a proposal needs to be a proposal.
//
// **A missing measurement is never a penalty.** Most wardrobes are half-unanalysed at any
// moment and Vision does not run in the Simulator at all, so every rule here is written to
// fall silent rather than to score down when it has nothing to read. An outfit the app has
// not looked at scores exactly as it did before this file existed.

import Foundation

public enum Outfit {
    public struct Verdict: Sendable, Hashable {
        /// 0…1, meaningful only against other verdicts.
        public var score: Double
        /// The line a card prints. Nil when nothing has been measured and there is honestly
        /// nothing to say — the same contract `Pairing.Verdict` holds.
        public var reason: String?
        /// Proposing this would read as a bug rather than as a suggestion.
        public var isRefused: Bool

        public init(score: Double, reason: String?, isRefused: Bool = false) {
            self.score = score
            self.reason = reason
            self.isRefused = isRefused
        }
    }

    /// Judges a whole outfit, head down.
    ///
    /// The base is the **worst** pairwise verdict in it, not the average — the rule
    /// `FitSuggestions.accompaniment` and `FitStudio` both already follow, and for the reason
    /// written there: a jacket that goes with the trousers and fights the shirt is not a good
    /// jacket for this outfit, and an average lets one strong agreement hide one real clash.
    /// The whole-outfit rules then adjust it.
    ///
    /// - Parameter statement: what the wearer has written about how they dress. It can
    ///   rescue a pair the colour wheel refused, exactly as it can pairwise.
    public static func score(
        _ pieces: [Garment],
        statement: StyleStatement? = nil
    ) -> Verdict {
        // **One garment is an outfit when it is a set.** A tracksuit or a co-ord occupies
        // both positions by itself — that is what `Garment.isSet` means, and it is why
        // `Pairing` refuses to put a second top beside one. Refusing it here meant a wardrobe
        // whose only workable proposal *was* a set got an empty row: the sets branch in
        // `FitSuggestions.build` offers `items = [piece]` when there is no footwear and no
        // outerwear to add, which is the exact case that branch says it exists for — "offered
        // first so that a wardrobe holding one still produces its proposal".
        if pieces.count == 1, pieces[0].isSet {
            return Verdict(score: 0.7, reason: nil, isRefused: false)
        }
        guard pieces.count >= 2 else { return Verdict(score: 0, reason: nil, isRefused: true) }

        // Two things in the same position is not an outfit. The one exception is the pair
        // this app deliberately builds — a mid layer with a base layer under it — which is
        // two tops and is the correct way to wear a hoodie.
        guard !isDoubleBooked(pieces) else {
            return Verdict(score: 0, reason: nil, isRefused: true)
        }

        var worst = 1.0
        var pairReason: String?
        for (index, one) in pieces.enumerated() {
            for other in pieces.dropFirst(index + 1) {
                // Two tops that are a mid and a base are not put through `Pairing`'s gate:
                // it refuses same-slot pairs by design, and asking it here would refuse every
                // layered fit the engine is meant to produce. They are still judged on the
                // one axis that survives the exemption — a mustard hoodie over a red tee is
                // as wrong as it would be beside the trousers, and skipping the pair outright
                // said nothing about it at all.
                // **A pair `isDoubleBooked` permits must not be refused here.** `Pairing`'s
                // gate turns down two garments that are both inessential — "an accessory
                // sits with anything by construction, so pairing two of them says nothing;
                // and headwear plus a bag is not an outfit anybody was asking about" — which
                // is a fair answer to *that* question and the wrong one to this. A cap and a
                // tote inside a four-piece fit scored the whole outfit as refused, while
                // `isDoubleBooked` above had just decided several accessories are exactly
                // what people wear. Each of them is still judged against every essential
                // piece, which is where a cap's colour actually has to work. Latent today
                // only because the one production caller narrows to `GarmentSlot.essential`;
                // `score` is public API sold as judging a whole outfit.
                //
                // `.unknown` is deliberately not included: the gate's *other* refusal — a
                // garment the classifier could not place — still stands, because putting
                // something we could not read next to something we could is a guess wearing
                // the clothes of a suggestion, and that is as true of a whole outfit as of a
                // pair.
                if !GarmentSlot.essential.contains(one.slot),
                   !GarmentSlot.essential.contains(other.slot),
                   one.slot != .unknown, other.slot != .unknown {
                    continue
                }
                if isLayeredPair(one, other) {
                    let layered = ColorHarmony.score(one.color, other.color)
                    if layered.score < worst {
                        worst = layered.score
                        pairReason = layered.reason
                    } else if pairReason == nil {
                        pairReason = layered.reason
                    }
                    continue
                }
                let verdict = Pairing.score(one, with: other, statement: statement)
                if verdict.isRefused { return Verdict(score: 0, reason: nil, isRefused: true) }
                if verdict.score < worst {
                    worst = verdict.score
                    pairReason = verdict.reason
                } else if pairReason == nil {
                    pairReason = verdict.reason
                }
            }
        }

        var score = worst
        var reason: String?

        let colour = colourShape(pieces)
        score += colour.adjustment

        // **The echo takes the line ahead of the colour shape**, where both fired. Both are
        // true; one is more interesting. "Olive against neutrals" describes the arrangement,
        // which the picture already shows; "Olive picked up twice" names a decision, and it
        // is the observation somebody could not have made at a glance.
        if let echo = echo(pieces) {
            score += 0.06
            reason = echo
        }
        reason = reason ?? colour.reason

        // More than one thing shouting. `Pairing` refuses two loud pieces *pairwise* only by
        // scoring them down, and a four-piece fit can pass every pair while three of its
        // garments are printed.
        let loud = pieces.filter(\.isStatement).count
        if loud > 1 { score -= 0.1 * Double(loud - 1) }

        // Something that needs a layer under it, without one. `FitSuggestions` enforces this
        // structurally when it can; here it is a score, so that a wardrobe with no base layer
        // in it still produces proposals rather than nothing at all.
        if pieces.contains(where: \.needsBaseLayer),
           !pieces.contains(where: { $0.slot == .top && $0.layer == .base }) {
            score -= 0.12
        }

        return Verdict(
            score: min(max(score, 0), 1),
            reason: reason ?? pairReason,
            isRefused: false
        )
    }

    // MARK: - Colour across the whole thing

    /// How the outfit's colours are arranged, and what that is worth.
    ///
    /// The shape being rewarded is the one every styling guide in existence describes and
    /// almost nobody states as arithmetic: **one piece carries the colour and the rest are
    /// quiet.** It is worth saying why that beats the alternative the old ranking preferred.
    /// `ColorHarmony` scores two identical colours at 0.9 and a colour against a neutral at
    /// 0.8, so an all-black fit outranked every fit with anything in it — and on a wardrobe
    /// that is mostly black, which is most streetwear wardrobes, the row produced six
    /// monochrome proposals and the one burgundy short in the collection was never shown.
    /// That is not a taste judgement going wrong; it is a ranking doing exactly what it was
    /// told, on a distribution nobody checked it against.
    private static func colourShape(_ pieces: [Garment]) -> (adjustment: Double, reason: String?) {
        let swatches = pieces.compactMap { $0.color.flatMap(ColorHarmony.Swatch.init(name:)) }
        // Fewer than two measured colours is not a shape. Silence, not a penalty.
        guard swatches.count >= 2 else { return (0, nil) }

        let chromatic = swatches.filter { !$0.isNeutral }
        let names = Set(chromatic.map(\.name))

        switch names.count {
        case 0:
            // Entirely neutral. A real and very wearable answer — it is simply not the only
            // good one, which is the whole correction here. Left flat rather than rewarded.
            return (0, nil)
        case 1:
            // The focal point, and the bonus is deliberately large enough to *clear*
            // monochrome rather than to tie with it. `ColorHarmony` rates black-on-black at
            // 0.9 and a colour against a neutral at 0.8, so a smaller thumb on the scale left
            // the two exactly level — and a tie is decided by the id, which is to say by
            // nothing. On a wardrobe that is four-fifths black that is the whole difference
            // between a row that shows the burgundy shorts and a row that never does.
            let name = names.first ?? ""
            return (0.15, "\(name) against neutrals")
        case 2:
            // Two colours is a decision if they sit well together and a mess if they don't.
            // The distance rule is `ColorHarmony`'s, so the two cannot disagree.
            let ordered = Array(names).sorted()
            let pair = chromatic.filter { $0.name == ordered.first || $0.name == ordered.last }
            guard let a = pair.first, let b = pair.last(where: { $0.name != a.name }) else {
                return (0, nil)
            }
            let apart = a.separation(from: b)
            if apart < 65 || apart >= 140 {
                return (0.04, "\(a.name) with \(b.name.lowercased())")
            }
            return (-0.1, nil)
        default:
            // Three or more colours competing. The one rule of thumb that survives contact
            // with every subculture: past three, an outfit stops reading as chosen.
            return (-0.15, nil)
        }
    }

    /// A colour worn twice, on pieces that are not the same garment.
    ///
    /// Deliberately looks at the accent as well as the dominant: the point of the trick is
    /// that a small amount of a colour somewhere else ties the outfit together, and a
    /// garment's accent is exactly that. Neutrals are excluded — every fit here repeats black
    /// somewhere, and saying so would be printing a line under all of them.
    private static func echo(_ pieces: [Garment]) -> String? {
        var seen: [String: Int] = [:]
        for piece in pieces {
            var names: Set<String> = []
            for raw in [piece.color, piece.secondaryColor] {
                guard let raw, let swatch = ColorHarmony.Swatch(name: raw), !swatch.isNeutral
                else { continue }
                names.insert(swatch.name)
            }
            for name in names { seen[name, default: 0] += 1 }
        }
        guard let repeated = seen.filter({ $0.value >= 2 }).keys.sorted().first else { return nil }
        return "\(repeated) picked up twice"
    }

    // MARK: - Structure

    /// Whether two garments are the mid-and-base pair a layered fit is made of.
    ///
    /// Public because the two screens that *build* an arrangement have to ask it before
    /// consulting `Pairing`, whose gate refuses same-slot pairs by design and would
    /// otherwise refuse every layered fit this engine exists to produce.
    public static func isLayeredPair(_ one: Garment, _ other: Garment) -> Bool {
        one.slot == .top && other.slot == .top && one.layer != other.layer
            && !one.isSet && !other.isSet
    }

    /// Two garments in one position, the deliberate layered pair excepted.
    private static func isDoubleBooked(_ pieces: [Garment]) -> Bool {
        var taken: [GarmentSlot: [Garment]] = [:]
        for piece in pieces {
            for slot in piece.occupied where slot != .unknown {
                taken[slot, default: []].append(piece)
            }
        }
        for (slot, held) in taken where held.count > 1 {
            // Accessories are the one position somebody genuinely wears several of.
            if slot == .accessory { continue }
            guard slot == .top, held.count == 2, isLayeredPair(held[0], held[1]) else {
                return true
            }
        }
        return false
    }
}

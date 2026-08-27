// Discovery.swift
// Deciding what order to show garments from brands nobody here follows.
//
// The discovery feed's supply is the whole catalogue minus what you already watch, and the
// obvious ranking — best pairing against your wardrobe, descending — collapses immediately.
// A brand's catalogue is internally consistent: if one technical shell works with your olive
// cargos, so do the other thirty-nine, and they will all score within a hair of each other.
// So the top fifty cards are two brands, and a feed whose entire purpose is to introduce you
// to a *third* brand has instead spent your attention proving it can sort.
//
// The deeper version of the same failure is that a taste engine left alone is a mirror. It
// can only ever return more of what you already own, which is precisely the thing you do not
// need a recommender for. Somewhere in the run there has to be a garment the ranking has no
// opinion about, or the feed cannot do the one job it exists to do.
//
// Four mechanisms, and they are separate on purpose — each one fixes something the other
// three cannot see:
//
// 1. `interleave` / the per-brand cap — a structural bound, applied while the order is
//    *built*.
// 2. `Saturation` — diminishing returns as a brand keeps appearing, across the whole
//    session rather than within one page.
// 3. `explorationEvery` — a fixed share of positions that ignore the ranking outright.
// 4. `WardrobeGap` — steering towards the slots somebody actually has nothing in.
//
// All of it is pure and deterministic. That is not incidental: `FeedView` already learned
// what happens when a list computes its order from something that moves while you read it,
// and a deck that reshuffled between one scroll and the next would be the same bug with
// better photography. Variety between two people comes from their wardrobes differing;
// variety between two sessions comes from the seen-ledger removing what has already been
// looked at. Neither needs a random number, and a random number would cost the property
// that scrolling back shows you the same card.
//
// Lives here rather than in the app for the `SilhouetteBands` reason: the pixels stay where
// CoreGraphics is, and the part with an opinion in it comes here where it can be tested.

import Foundation

/// One thing the deck could show, reduced to the four facts the ordering actually reads.
///
/// Deliberately not the wire type. The server orders rows out of Postgres and the client
/// re-orders cards it is holding in memory, and neither should have to adopt the other's
/// shape to get the same answer — so this carries an opaque `id` the caller maps back
/// through.
public struct DiscoveryCandidate: Sendable, Hashable, Identifiable {
    /// The caller's own key. A product external id at both ends, but nothing here reads it
    /// except to break ties, so any stable string works.
    public var id: String
    /// Who made it. The unit every diversity rule here is about.
    public var brandID: UUID
    /// Where it goes on the body, for `WardrobeGap`. `.unknown` is ordinary and is steered
    /// neither up nor down.
    public var slot: GarmentSlot
    /// How good a card this is, 0…1 — the pairing verdict against the wardrobe, or the
    /// taste similarity, or a blend. Whatever the caller means by "good"; this file only
    /// ever multiplies it.
    public var affinity: Double
    /// Whether the taste profile has anything to say about this brand at all.
    ///
    /// **False is what makes a card eligible for an exploration slot.** It is not a quality
    /// judgement and must not be read as one: a brand nobody has an opinion about is the
    /// entire point of the exercise.
    public var isFamiliar: Bool

    public init(
        id: String,
        brandID: UUID,
        slot: GarmentSlot = .unknown,
        affinity: Double = 0,
        isFamiliar: Bool = true
    ) {
        self.id = id
        self.brandID = brandID
        self.slot = slot
        self.affinity = affinity
        self.isFamiliar = isFamiliar
    }
}

/// How much a brand has already been shown, and what that costs it next time.
///
/// A per-page cap bounds one page and says nothing about twenty of them: at two per page
/// that is still forty cards from the same shop by the time somebody has been scrolling for
/// a couple of minutes, which is the complaint the cap was meant to answer.
///
/// Damped smoothly rather than by a threshold, for the reason `Popularity.confidence` is:
/// a switch that flips at the fourth card would visibly reorder the feed mid-scroll, and a
/// feed that snaps reads as broken even when the new order is better.
public struct Saturation: Sendable, Hashable {
    /// How many cards from one brand halve its weight. Three, so a fourth card from a brand
    /// has to be about twice as good as a stranger's first to earn its place — enough to
    /// keep a genuinely excellent match, not enough to let one catalogue own the run.
    public static let defaultHalfLife = 3.0

    public var halfLife: Double
    private var shown: [UUID: Int]

    public init(halfLife: Double = Saturation.defaultHalfLife, shown: [UUID: Int] = [:]) {
        self.halfLife = max(0.5, halfLife)
        self.shown = shown
    }

    /// How many of this brand's cards have gone past.
    public func count(for brandID: UUID) -> Int { shown[brandID] ?? 0 }

    /// 0…1. Multiplies a candidate's score.
    public func weight(for brandID: UUID) -> Double {
        1 / (1 + Double(count(for: brandID)) / halfLife)
    }

    public mutating func record(_ brandID: UUID) {
        shown[brandID, default: 0] += 1
    }

    /// Forgets a brand entirely — used when it is followed or dismissed and its cards leave
    /// the deck, so a later re-entry (a dismissal undone, an unfollow) starts clean rather
    /// than carrying a penalty for cards nobody can see any more.
    public mutating func forget(_ brandID: UUID) {
        shown[brandID] = nil
    }
}

/// Which slots somebody is short of, as a multiplier on candidates that fill them.
///
/// `StyleView` already asks this question of the wardrobe and prints the answer; this is the
/// same reading used to steer rather than to report. It is the only signal in the file that
/// comes from the person's *situation* rather than their history, and the only one that
/// makes the feed wider instead of narrower — six tops and no outerwear should surface
/// jackets from labels the taste vector would otherwise have buried.
public enum WardrobeGap {
    /// How much an empty slot is worth over a full one. Half again: enough to lift a decent
    /// jacket over a marginally better t-shirt, never enough to rescue a bad pairing — the
    /// feed is still about whether the clothes go together.
    public static let boost = 0.5

    /// Multipliers per slot, from a count of what is owned.
    ///
    /// **Only over `GarmentSlot.essential`.** Telling somebody they are short of headwear is
    /// a fashion opinion; telling them they own no trousers is an observation. That is the
    /// same line `StyleView` draws, and it is drawn in both places or the tab and the feed
    /// disagree about the same wardrobe.
    public static func weights(owned: [GarmentSlot: Int]) -> [GarmentSlot: Double] {
        let counts = GarmentSlot.essential.map { (slot: $0, count: owned[$0] ?? 0) }
        guard let fullest = counts.map(\.count).max(), fullest > 0 else {
            // Nothing owned anywhere. There is no gap to speak of — every slot is equally
            // empty — and boosting all four equally is the same as boosting none.
            return [:]
        }

        var out: [GarmentSlot: Double] = [:]
        for entry in counts {
            out[entry.slot] = 1 + boost * (1 - Double(entry.count) / Double(fullest))
        }
        return out
    }
}

public enum Discovery {
    /// How many cards one brand may contribute to a single page.
    ///
    /// Two, not one: a brand gets to show that it makes more than one thing, and the spread
    /// under each card covers the rest. The cap is applied while the order is **built**, and
    /// that distinction is the whole of it — `/v1/brands/popular` shipped a "per-brand
    /// budget" that was a global `LIMIT` with the grouping done afterwards, and the result
    /// was fourteen of thirty-five recommendations arriving with no photographs at all
    /// because one storefront's 250-item sweep had taken the entire window. A cut made in
    /// SQL across every brand at once is not a per-brand budget, and the tell is that the
    /// per-brand count changes when the global limit does.
    public static let defaultPerBrand = 2

    /// The least a release card may score, whatever the arithmetic makes of it.
    ///
    /// **Without this a release can never win, and the reason is structural rather than a
    /// matter of tuning.** Every other card earns its place from a `Pairing` verdict against
    /// the wardrobe — but a collection has no garment slot, so the slot gate refuses it
    /// before anything is scored, and it falls back to a bare vector similarity that any
    /// individual jacket beats. The one card the feed most wants to show came last by
    /// construction.
    ///
    /// A floor rather than a fixed score, so a release from a brand that genuinely matches
    /// somebody's taste still outranks one that doesn't — and deliberately not 1.0, because
    /// a release is the *most interesting kind* of card, not more interesting than every
    /// possible garment. The per-brand cap and `Saturation` still apply on top, so this
    /// cannot let one label's season take the run.
    public static let releaseFloor = 0.75

    /// One position in every four ignores the ranking and takes something the taste profile
    /// has no opinion about.
    ///
    /// **This will look like a bug.** Somebody reading the ordering later will find a card
    /// that scored worse than several it was placed above, and the obvious fix is to delete
    /// this. It is deliberate: a feed that only ever returns what already resembles your
    /// wardrobe cannot introduce you to anything, and the whole product is the introduction.
    /// A quarter is the smallest share that reliably survives a page.
    public static let explorationEvery = 4

    /// Whether the card at this position is an exploration slot.
    ///
    /// Never position zero. The first thing somebody sees when they open the tab should be
    /// the best argument the deck has, not the one it is least sure about.
    public static func isExploration(position: Int) -> Bool {
        guard position > 0, explorationEvery > 1 else { return false }
        return position % explorationEvery == explorationEvery - 1
    }

    /// The order to show a page in.
    ///
    /// Built one position at a time rather than sorted, because every rule here changes the
    /// scores of what is left: emitting a card decays its brand for the rest of the run, and
    /// an exploration slot must draw from a different pool than the position before it. A
    /// sort cannot express either.
    ///
    /// - Parameters:
    ///   - candidates: everything eligible, in any order.
    ///   - saturation: carried across pages by the caller and updated here, so the fifth
    ///     page knows what the first one showed.
    ///   - gaps: from `WardrobeGap.weights`. Empty is fine and means "no steer".
    ///   - perBrand: the structural cap.
    public static func order(
        _ candidates: [DiscoveryCandidate],
        saturation: inout Saturation,
        gaps: [GarmentSlot: Double] = [:],
        perBrand: Int = Discovery.defaultPerBrand
    ) -> [DiscoveryCandidate] {
        guard !candidates.isEmpty else { return [] }

        var remaining = candidates
        var used: [UUID: Int] = [:]
        var out: [DiscoveryCandidate] = []
        var previousBrand: UUID?
        /// The cap is per *round*, not once for the whole run.
        ///
        /// Written as a single allowance it front-loads instead of spreading: a pool of
        /// fifty with a cap of two exhausts every brand's budget inside the first eight
        /// cards, and from position nine onwards there is no cap at all — so the brand that
        /// scores highest simply takes the rest, which is the collapse this file is about,
        /// arriving eight cards later than it would have without a cap. Advancing in rounds
        /// makes the guarantee hold over *any* prefix rather than only the first one.
        var round = 0

        /// A candidate's worth at this instant, with everything that has already been shown
        /// folded in.
        func value(_ candidate: DiscoveryCandidate) -> Double {
            let gap = gaps[candidate.slot] ?? 1
            return candidate.affinity * saturation.weight(for: candidate.brandID) * gap
        }

        /// The best index in `remaining` matching a filter, or nil.
        ///
        /// Ties break on the id so the order is stable between two calls with the same
        /// input — the property that makes scrolling back show the same card.
        func best(where isEligible: (DiscoveryCandidate) -> Bool) -> Int? {
            var bestIndex: Int?
            var bestValue = -Double.infinity
            for (index, candidate) in remaining.enumerated() where isEligible(candidate) {
                let score = value(candidate)
                if score > bestValue
                    || (score == bestValue && bestIndex.map({ candidate.id < remaining[$0].id }) == true) {
                    bestValue = score
                    bestIndex = index
                }
            }
            return bestIndex
        }

        while !remaining.isEmpty {
            let position = out.count
            let wantsExploration = isExploration(position: position)

            func underCap(_ candidate: DiscoveryCandidate) -> Bool {
                (used[candidate.brandID] ?? 0) < perBrand * (round + 1)
            }
            func notAdjacent(_ candidate: DiscoveryCandidate) -> Bool {
                candidate.brandID != previousBrand
            }

            // Everybody has spent this round's allowance, so open the next one. Terminates
            // because `remaining` is non-empty and the allowance grows without bound.
            while !remaining.contains(where: underCap) { round += 1 }

            // The pools, in the order this position wants them. An exploration slot with an
            // empty unfamiliar pool falls back to the ranked one rather than leaving a hole:
            // a gap in a paging scroll is a blank screen, which is worse than a card that is
            // merely well-targeted.
            let pools: [(DiscoveryCandidate) -> Bool] = wantsExploration
                ? [{ !$0.isFamiliar }, { $0.isFamiliar }]
                : [{ $0.isFamiliar }, { !$0.isFamiliar }]

            // Adjacency is the only thing given up, and it is the cosmetic one — two cards
            // from a brand in a row reads slightly repetitive, where a broken cap is the
            // collapse. It goes when a brand is the sole holder of this round's allowance,
            // which at the tail of a page is unavoidable.
            //
            // The cap itself is never relaxed: the round above guarantees something is
            // always eligible under it, so there is no third fallback to write.
            var chosen: Int?
            for pool in pools where chosen == nil {
                chosen = best { pool($0) && underCap($0) && notAdjacent($0) }
            }
            for pool in pools where chosen == nil {
                chosen = best { pool($0) && underCap($0) }
            }

            guard let index = chosen else { break }
            let candidate = remaining.remove(at: index)
            used[candidate.brandID, default: 0] += 1
            saturation.record(candidate.brandID)
            previousBrand = candidate.brandID
            out.append(candidate)
        }

        return out
    }

    /// Round-robin over brands, without any of the scoring.
    ///
    /// The server's half of the same idea: it has no taste profile, no wardrobe and no
    /// saturation history, and it only needs to hand over a page that doesn't arrive as one
    /// storefront's sweep followed by everybody else. Generic over the row type with a brand
    /// accessor rather than requiring a conformance, because the two callers are a Fluent
    /// model and a value type and neither should have to know about the other.
    ///
    /// **It rearranges and never discards.** That is load-bearing rather than tidy: the
    /// route's cursor is a position in an enumeration, so a row dropped here is a product
    /// that no page will ever show again and nothing anywhere would report it missing. A
    /// caller that wants a shorter page takes a prefix, where the loss is its own decision
    /// and visible at the point it is made.
    ///
    /// Preserves the caller's ordering within a group — that is where recency lives.
    ///
    /// Generic over the *key* as well as the row, because the same round-robin answers two
    /// questions. The route uses it to stop one brand's sweep opening a page; a release card
    /// uses it with the garment slot, so a mosaic meant to represent a whole collection is
    /// not six socks and a jacket — which is exactly what catalogue order gave.
    public static func interleave<T, Key: Hashable>(
        _ rows: [T],
        by key: (T) -> Key
    ) -> [T] {
        // Buckets in first-appearance order, so a caller that sorted by date gets a page
        // that still leads with the newest thing.
        var order: [Key] = []
        var buckets: [Key: [T]] = [:]
        for row in rows {
            let id = key(row)
            if buckets[id] == nil {
                buckets[id] = []
                order.append(id)
            }
            buckets[id]!.append(row)
        }

        // Plain rounds: every brand gives one row before any brand gives a second.
        //
        // The obvious alternative is to always take from whoever has the most left, which
        // spreads the deepest catalogue most evenly over the whole run. It is the wrong
        // trade here, and visibly so: a brand with a single product would not appear until
        // the prolific ones had been drawn down to its level, which on a real catalogue is
        // most of the way through the page. On a feed whose entire job is introductions, the
        // shop with one thing in it is exactly the introduction worth making early. The cost
        // is a tail weighted towards the deepest brand, and the client's `order` — which has
        // saturation and a taste profile — is better placed to deal with that than this is.
        var out: [T] = []
        while true {
            let eligible = order.filter { !(buckets[$0]?.isEmpty ?? true) }
            guard !eligible.isEmpty else { break }
            for id in eligible {
                out.append(buckets[id]!.removeFirst())
            }
        }
        return out
    }
}

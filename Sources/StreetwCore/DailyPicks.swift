// DailyPicks.swift
// What Shop offers when nobody has typed anything: a few things from your own shops, each
// with the one sentence an archive can say about it.
//
// The Style tab used to end with "what's missing" — six tops and no trousers — and could
// only report it. Picks are the same observation moved to where it can be acted on: a
// product from a shop you follow, chosen because it goes with something you own, leaning
// towards the slots your wardrobe has nothing in, and saying so in a line you can check
// against the photograph of your own garment beside it.
//
// Four rules, each the lesson of a screen that broke it first.
//
// - **No random number, and still a different set tomorrow.** Discover forbids RNG because
//   scrolling back must show the same card. Picks need the same stability within a day and
//   variety across days, so the variety is a *hash of the day and the product*
//   (`jitter`) — deterministic, the same on every launch, and different on the next date.
//   It is a nudge among near-equals, not a lottery: a bad pairing never beats a good one by
//   luck.
// - **The day's set is kept, not recomputed** (the app's `PickLedger` holds it). Every input
//   moves while the screen is open — saving a pick changes the wardrobe, which changes every
//   score — and a set that re-ranked under the thumb that saved one of its cards would be
//   `DiscoverDeck.pinningRead`'s failure on a new screen. So once chosen, today's picks only
//   ever grow (when the catalogue was too thin to fill them) or lose one somebody refused.
//   What the set never contains, *when it is chosen*, is anything already saved or refused.
// - **Different picks point at different things you own** (`DiscoverDeck.spreadAnchors`'s
//   rule). Most of a wardrobe has no measured colour, so `Pairing` ties and breaks the tie
//   on id — the same jacket, every time. Each pick takes its best partner no earlier pick has
//   used, and the reason moves with the partner, or the card would print a verdict about a
//   garment it is not showing.
// - **The reason is always true.** With a wardrobe, it is the pairing `Pairing` actually
//   found. Without one there is nothing to pair against, and the picks still work — on what
//   the store knows for a fact (back in your size, marked down, new this week) — rather than
//   inventing an argument.
//
// Pure and in `StreetwCore`: the app gathers the candidates, the wardrobe and the ledger, and
// this decides. It is also where Phase 4's taste summary and the model's reasons will be
// ranked in, behind the same output.

import Foundation

public enum DailyPicks {
    /// A short set. A page of picks is a recommendation; a page of twenty is a catalogue,
    /// and the catalogue is one field away.
    public static let count = 5

    /// How many candidates are scored against the wardrobe on any one day. `Pairing` runs per
    /// candidate per owned garment, and the catalogue on a phone can be thousands deep, so the
    /// day draws a sample — the newest few always, the rest by the day's hash, so a different
    /// part of the catalogue gets its turn each day.
    public static let poolSize = 240
    static let newestInPool = 40

    /// How far the day's hash may move a score. A fifth of the range a verdict spans: enough
    /// to reorder near-equals from one day to the next, nowhere near enough to rescue a weak
    /// pairing.
    static let jitterWeight = 0.2

    /// Something the store knows happened to a product, which is a reason to show it even
    /// with nothing to pair it with.
    public enum Fact: Sendable, Hashable {
        /// Restocked, in these of the reader's sizes.
        case backInYourSize([String])
        /// Marked down, by this many percent.
        case markedDown(Int)
        /// Published in the last week.
        case new
    }

    public struct Candidate: Sendable {
        public var listing: ShopListing
        public var garment: Garment
        public var fact: Fact?
        /// Buyable in a size the reader told us they wear (`SizeProfile.claims`).
        public var isInYourSize: Bool

        public init(listing: ShopListing, garment: Garment, fact: Fact? = nil, isInYourSize: Bool = false) {
            self.listing = listing
            self.garment = garment
            self.fact = fact
            self.isInYourSize = isInYourSize
        }
    }

    /// Why a pick is on the page, in a form the app turns into a sentence.
    public enum Reason: Sendable, Hashable {
        /// Goes with something owned. `fills` is set when the pick's slot is one the wardrobe
        /// has nothing in — "you own no outerwear yet".
        case goesWith(fills: GarmentSlot?)
        /// Nothing owned goes with it, and it is the kind of thing the wardrobe lacks.
        case fills(GarmentSlot)
        /// Nothing to pair against; this is what the store knows about it.
        case fact(Fact)
        /// None of the above — a garment from a shop you follow, said as plainly as that.
        case fromYourShops
    }

    public struct Pick: Sendable, Hashable, Identifiable {
        /// The listing's id.
        public var id: String
        /// The owned garment it was paired with, by `Garment.id`.
        public var partnerID: String?
        public var reason: Reason
        /// The pairing's own line — "Layers over it", "Black with cream" — where it had one.
        public var detail: String?
    }

    // MARK: - The day

    /// The calendar date on this phone, as a key. Local on purpose: a pick that changes at
    /// one in the afternoon because it is midnight in UTC is a set that changed for no
    /// reason anybody could see.
    public static func day(of date: Date, in calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    /// 0..<1, fixed for a product on a day and unrelated between days.
    ///
    /// FNV-1a rather than `Hasher`, which is seeded per process — the same reason
    /// `SitemapMemory` uses it: today's answer has to survive a relaunch.
    public static func jitter(_ id: String, day: String) -> Double {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in (day + "|" + id).utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 1_099_511_628_211
        }
        // A final avalanche, because FNV's high bits barely move between ids that differ in
        // their last character — and two products of one shop usually do.
        hash ^= hash >> 33
        hash = hash &* 0xff51_afd7_ed55_8ccd
        hash ^= hash >> 33
        return Double(hash >> 11) / Double(UInt64(1) << 53)
    }

    /// The candidates worth scoring today: everything when the catalogue is small, otherwise
    /// the newest few plus the day's sample, plus whatever is already in today's set.
    public static func pool(_ listings: [ShopListing], day: String, keeping: Set<String> = []) -> [ShopListing] {
        guard listings.count > poolSize else { return listings }
        // Keys computed once each, then sorted — the decorate-sort `oncePerProduct` uses,
        // because the day's hash is not free and a comparator would ask for it n·log n times.
        let byDate = listings.indices.sorted { a, b in
            let one = listings[a], other = listings[b]
            if one.publishedAt != other.publishedAt { return one.publishedAt > other.publishedAt }
            return one.id < other.id
        }
        let keys: [Double] = listings.map { jitter($0.id, day: day) }
        let byDay = listings.indices.sorted { a, b in
            keys[a] == keys[b] ? listings[a].id < listings[b].id : keys[a] < keys[b]
        }
        let newest: [ShopListing] = byDate.prefix(newestInPool).map { listings[$0] }
        let sample: [ShopListing] = byDay.prefix(poolSize - newestInPool).map { listings[$0] }
        let kept: [ShopListing] = listings.filter { keeping.contains($0.id) }

        var seen: Set<String> = []
        var out: [ShopListing] = []
        for listing in newest + sample + kept where seen.insert(listing.id).inserted {
            out.append(listing)
        }
        return out
    }

    /// The essential slots a wardrobe has nothing in at all.
    ///
    /// Only once there are three things in it — a wardrobe of one shirt is missing everything,
    /// and saying so four times is noise rather than an observation. Only over
    /// `GarmentSlot.essential`, because telling somebody they are short of headwear is a
    /// fashion opinion. Both lines are the Style tab's "what's missing", which this replaces.
    public static func missing(owned: [GarmentSlot: Int]) -> Set<GarmentSlot> {
        guard owned.values.reduce(0, +) >= 3 else { return [] }
        return Set(GarmentSlot.essential.filter { (owned[$0] ?? 0) == 0 })
    }

    // MARK: - Choosing

    /// Today's picks, in the order they are read.
    ///
    /// - Parameters:
    ///   - candidates: products from followed shops, already narrowed by the caller to what
    ///     may be offered at all — not saved, not refused, buyable, in the reader's size where
    ///     the product says — except anything in `keeping`, which stays whatever happened to
    ///     it today.
    ///   - wardrobe: what the reader owns, through `TasteScope.pairingPool`.
    ///   - owned: how many essential garments of each slot they own, for "what's missing".
    ///   - keeping: today's set so far, in order. Kept first, then topped up.
    public static func choose(
        from candidates: [Candidate],
        wardrobe: [Garment],
        owned: [GarmentSlot: Int],
        statement: StyleStatement? = nil,
        day: String,
        keeping: [String] = [],
        limit: Int = count
    ) -> [Pick] {
        let missing = missing(owned: owned)
        let gaps = WardrobeGap.weights(owned: owned)
        let kept = Set(keeping)

        struct Scored {
            var candidate: Candidate
            var partners: [(garment: Garment, verdict: Pairing.Verdict)]
            var score: Double
        }

        var scored: [String: Scored] = [:]
        for candidate in candidates {
            let id = candidate.listing.id
            let slot = candidate.listing.slot
            // Picks are an argument about outfits, so they are garments an outfit is built
            // from. A cap goes with everything, which is the same as saying nothing.
            guard GarmentSlot.essential.contains(slot) || kept.contains(id) else { continue }

            let partners = wardrobe.isEmpty
                ? []
                : Pairing.best(for: candidate.garment, from: wardrobe, limit: 8, statement: statement)

            let base: Double
            if let best = partners.first {
                base = best.verdict.score
            } else if wardrobe.isEmpty || missing.contains(slot) {
                // Nothing to pair it with, and either nothing to pair against at all or a
                // hole it would fill. Both are true things to say about it.
                base = 0.3
            } else if kept.contains(id) {
                base = 0
            } else {
                // A wardrobe that has this slot covered and nothing in it that goes with this:
                // there is no honest sentence to print under it.
                continue
            }

            var score = base * (gaps[slot] ?? 1)
            switch candidate.fact {
            // News about the reader outranks news about the shop, and a restock in their own
            // size is the most specific news there is.
            case .backInYourSize: score += 0.25
            case .markedDown: score += 0.12
            case .new: score += 0.05
            case nil: break
            }
            if candidate.isInYourSize { score += 0.05 }
            score += jitterWeight * jitter(id, day: day)
            scored[id] = Scored(candidate: candidate, partners: partners, score: score)
        }

        let ranked = scored.values.sorted { a, b in
            a.score == b.score ? a.candidate.listing.id < b.candidate.listing.id : a.score > b.score
        }

        // Today's set first, as it was. Then topped up in passes that relax one cap at a time:
        // one per shop and two per slot, then two per shop, then just two per slot, then
        // anything — so a spread when there is one, and a full set from the one shop
        // somebody follows when that is all there is.
        var chosen: [Scored] = keeping.compactMap { scored[$0] }
        var brands: [String: Int] = [:]
        var slots: [GarmentSlot: Int] = [:]
        for entry in chosen {
            brands[entry.candidate.listing.brandKey, default: 0] += 1
            slots[entry.candidate.listing.slot, default: 0] += 1
        }
        for (perBrand, perSlot) in [(1, 2), (2, 2), (Int.max, 2), (Int.max, Int.max)] {
            for entry in ranked where chosen.count < limit {
                let listing = entry.candidate.listing
                guard !chosen.contains(where: { $0.candidate.listing.id == listing.id }),
                      brands[listing.brandKey, default: 0] < perBrand,
                      slots[listing.slot, default: 0] < perSlot
                else { continue }
                chosen.append(entry)
                brands[listing.brandKey, default: 0] += 1
                slots[listing.slot, default: 0] += 1
            }
        }

        var used: Set<String> = []
        // "You own no outerwear yet" is said once, on the first pick that fills the gap. Three
        // jackets each opening with it reads as the app repeating itself, not as three reasons.
        var said: Set<GarmentSlot> = []
        return chosen.prefix(max(limit, keeping.count)).map { entry in
            let listing = entry.candidate.listing
            var fills: GarmentSlot?
            if missing.contains(listing.slot), said.insert(listing.slot).inserted { fills = listing.slot }
            if let partner = entry.partners.first(where: { !used.contains($0.garment.id) }) ?? entry.partners.first {
                used.insert(partner.garment.id)
                return Pick(
                    id: listing.id,
                    partnerID: partner.garment.id,
                    reason: .goesWith(fills: fills),
                    detail: partner.verdict.reason
                )
            }
            if let fills, !wardrobe.isEmpty {
                return Pick(id: listing.id, partnerID: nil, reason: .fills(fills), detail: nil)
            }
            if let fact = entry.candidate.fact {
                return Pick(id: listing.id, partnerID: nil, reason: .fact(fact), detail: nil)
            }
            return Pick(id: listing.id, partnerID: nil, reason: .fromYourShops, detail: nil)
        }
    }
}

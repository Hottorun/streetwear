import Foundation
import Testing

@testable import StreetwCore

@Suite("Discovery ordering")
struct DiscoveryTests {
    // Four brands with stable ids, so a failure names the same one twice.
    private let a = UUID(uuidString: "00000000-0000-0000-0000-0000000000A1")!
    private let b = UUID(uuidString: "00000000-0000-0000-0000-0000000000B2")!
    private let c = UUID(uuidString: "00000000-0000-0000-0000-0000000000C3")!
    private let d = UUID(uuidString: "00000000-0000-0000-0000-0000000000D4")!

    private func candidate(
        _ id: String,
        _ brand: UUID,
        slot: GarmentSlot = .top,
        affinity: Double = 0.5,
        familiar: Bool = true
    ) -> DiscoveryCandidate {
        DiscoveryCandidate(id: id, brandID: brand, slot: slot, affinity: affinity, isFamiliar: familiar)
    }

    // MARK: - The collapse this whole file exists to prevent

    /// The failure in one test. A brand's catalogue is internally consistent, so if one of
    /// its garments pairs well with somebody's wardrobe they all do — and a plain descending
    /// sort therefore returns forty cards from one shop, on the feed whose entire job is to
    /// introduce a second one.
    @Test("One brand's catalogue cannot own the run")
    func oneBrandCannotDominate() {
        // Forty near-perfect candidates from A, and a handful of merely good ones from
        // everybody else. A sort by affinity puts every A first.
        var pool = (0..<40).map { candidate("a\($0)", a, affinity: 0.95) }
        pool += (0..<6).map { candidate("b\($0)", b, affinity: 0.6) }
        pool += (0..<6).map { candidate("c\($0)", c, affinity: 0.6) }
        pool += (0..<6).map { candidate("d\($0)", d, affinity: 0.6) }

        var saturation = Saturation()
        let ordered = Discovery.order(pool, saturation: &saturation)

        let firstTen = ordered.prefix(10)
        let fromA = firstTen.filter { $0.brandID == a }.count
        #expect(fromA <= 3, "A took \(fromA) of the first ten despite scoring highest on every card")
        #expect(Set(firstTen.map(\.brandID)).count >= 3, "the opening screenfuls must show several brands")
    }

    /// The acceptance test for the whole file, over a run long enough to be a real session.
    ///
    /// Twelve brands, one of which is a far better match than the rest and has a catalogue
    /// four times the size — the shape that produces "why is this all the same shop". The
    /// numbers here are the contract: break one and the feed has regressed to a mirror.
    @Test("Over two hundred cards, no brand owns the feed")
    func longRunStaysDiverse() {
        var pool: [DiscoveryCandidate] = []
        let brands = (0..<12).map { _ in UUID() }
        for (index, brand) in brands.enumerated() {
            // The first brand is both the best match and the deepest catalogue.
            let depth = index == 0 ? 80 : 20
            let affinity = index == 0 ? 0.95 : 0.75 - Double(index) * 0.02
            pool += (0..<depth).map {
                candidate(
                    "\(index)-\($0)",
                    brand,
                    slot: GarmentSlot.essential[$0 % GarmentSlot.essential.count],
                    affinity: affinity,
                    // A third of the catalogue is from brands the taste profile is silent
                    // about, which is roughly what an unfollowed catalogue looks like.
                    familiar: index % 3 != 0
                )
            }
        }

        var saturation = Saturation()
        let run = Discovery.order(pool, saturation: &saturation).prefix(200)
        #expect(run.count == 200)

        var counts: [UUID: Int] = [:]
        for card in run { counts[card.brandID, default: 0] += 1 }

        let worst = counts.values.max() ?? 0
        #expect(
            Double(worst) / 200 <= 0.15,
            "one brand took \(worst) of 200 cards — the feed has collapsed to a mirror"
        )
        #expect(counts.count == brands.count, "every brand should reach a two-hundred-card run")

        let exploration = run.filter { !$0.isFamiliar }.count
        #expect(
            Double(exploration) / 200 >= 0.2,
            "only \(exploration) of 200 cards were something the ranking had no opinion about"
        )

        // And it still reads as a feed rather than a shuffle: consecutive repeats are the
        // exception, not the rule.
        let repeats = zip(run, run.dropFirst()).filter { $0.brandID == $1.brandID }.count
        #expect(repeats <= 4, "\(repeats) adjacent repeats in two hundred cards")
    }

    @Test("No two consecutive cards from the same brand, while an alternative exists")
    func noAdjacentRepeats() {
        var pool: [DiscoveryCandidate] = []
        for (index, brand) in [a, b, c, d].enumerated() {
            pool += (0..<5).map { candidate("\(index)-\($0)", brand, affinity: 0.9 - Double(index) * 0.1) }
        }

        var saturation = Saturation()
        let ordered = Discovery.order(pool, saturation: &saturation, perBrand: 20)

        // The tail can legitimately repeat once every other brand is spent, so this checks
        // the region where a choice genuinely existed.
        let head = ordered.prefix(12)
        for (previous, next) in zip(head, head.dropFirst()) {
            #expect(previous.brandID != next.brandID, "two \(previous.brandID) cards in a row")
        }
    }

    @Test("The per-brand cap binds within a page")
    func perBrandCapIsRespected() {
        let pool = (0..<10).map { candidate("a\($0)", a, affinity: 0.9) }
            + (0..<10).map { candidate("b\($0)", b, affinity: 0.8) }

        var saturation = Saturation()
        let ordered = Discovery.order(pool, saturation: &saturation, perBrand: 2)

        // Everything is emitted — the cap orders a page, it does not throw content away —
        // but the cap holds for as long as anything else is available to show.
        #expect(ordered.count == pool.count)
        let firstFour = ordered.prefix(4)
        #expect(firstFour.filter { $0.brandID == a }.count == 2)
        #expect(firstFour.filter { $0.brandID == b }.count == 2)
    }

    // MARK: - Saturation

    @Test("A brand's weight decays smoothly, never by a step")
    func saturationDecays() {
        var saturation = Saturation()
        #expect(saturation.weight(for: a) == 1)

        var previous = 1.0
        for _ in 0..<8 {
            saturation.record(a)
            let now = saturation.weight(for: a)
            #expect(now < previous, "weight must fall with every card shown")
            #expect(now > 0, "and never reach zero — a brand is quieted, not banned")
            previous = now
        }

        // Half at the half-life, which is what makes the constant readable.
        var three = Saturation(halfLife: 3)
        for _ in 0..<3 { three.record(b) }
        #expect(abs(three.weight(for: b) - 0.5) < 0.0001)

        // And it is per brand — quieting one says nothing about another.
        #expect(three.weight(for: c) == 1)
    }

    /// Saturation is carried by the caller across pages, so page five knows what page one
    /// showed. Without it a two-per-page cap is forty cards from one brand over twenty
    /// pages, which is the complaint the cap was supposed to answer.
    @Test("Saturation carries across pages")
    func saturationSurvivesPaging() {
        var saturation = Saturation()

        var perPage: [Int] = []
        for page in 0..<5 {
            let pool = (0..<4).map { candidate("a\(page)-\($0)", a, affinity: 0.95) }
                + (0..<4).map { candidate("b\(page)-\($0)", b, affinity: 0.5) }
                + (0..<4).map { candidate("c\(page)-\($0)", c, affinity: 0.5) }
            let ordered = Discovery.order(pool, saturation: &saturation, perBrand: 2)
            perPage.append(ordered.prefix(4).filter { $0.brandID == a }.count)
        }

        #expect(perPage[0] >= perPage[4], "A must not lead as strongly on page five as on page one")
        #expect(saturation.count(for: a) > 0)
    }

    @Test("Following or dismissing a brand clears its penalty")
    func forgettingResetsABrand() {
        var saturation = Saturation()
        for _ in 0..<5 { saturation.record(a) }
        #expect(saturation.weight(for: a) < 0.5)

        saturation.forget(a)
        #expect(saturation.weight(for: a) == 1)
    }

    // MARK: - Exploration

    @Test("One position in four ignores the ranking")
    func explorationCadence() {
        #expect(!Discovery.isExploration(position: 0), "the first card is the best argument, not the least sure one")
        #expect(Discovery.isExploration(position: 3))
        #expect(Discovery.isExploration(position: 7))
        #expect(!Discovery.isExploration(position: 4))
    }

    /// The mirror problem. Without this, a feed can only return more of what somebody
    /// already owns, which is the one thing a discovery feed must not do.
    @Test("A brand the taste profile knows nothing about still reaches the run")
    func unfamiliarBrandsSurface() {
        // Everything familiar scores far better than everything unfamiliar, so nothing
        // unfamiliar would ever appear on score alone.
        let pool = (0..<30).map { candidate("known\($0)", [a, b, c][$0 % 3], affinity: 0.9) }
            + (0..<10).map { candidate("new\($0)", d, affinity: 0.1, familiar: false) }

        var saturation = Saturation()
        let ordered = Discovery.order(pool, saturation: &saturation, perBrand: 4)

        let unfamiliarShare = Double(ordered.prefix(20).filter { !$0.isFamiliar }.count) / 20
        #expect(unfamiliarShare >= 0.2, "only \(unfamiliarShare) of the run was something new")

        // And they land on the exploration positions specifically, rather than being
        // sprinkled wherever there was room.
        for position in [3, 7, 11] where position < ordered.count {
            #expect(!ordered[position].isFamiliar, "position \(position) should be an exploration slot")
        }
    }

    /// An exploration slot with nothing to put in it must borrow from the ranked pool. A
    /// hole in a full-screen paging scroll is a blank screen.
    @Test("An exploration slot with an empty pool leaves no hole")
    func explorationFallsBackRatherThanLeavingAGap() {
        let pool = (0..<8).map { candidate("known\($0)", [a, b][$0 % 2], affinity: 0.8) }

        var saturation = Saturation()
        let ordered = Discovery.order(pool, saturation: &saturation, perBrand: 4)

        #expect(ordered.count == pool.count, "no card may be dropped for want of an unfamiliar one")
    }

    // MARK: - Wardrobe gaps

    @Test("An empty slot outranks a full one, and only the essential slots count")
    func wardrobeGapSteers() {
        // Six tops, nothing else — the case the feature is named after.
        let weights = WardrobeGap.weights(owned: [.top: 6, .bottom: 1])

        #expect(weights[.outerwear]! > weights[.top]!)
        #expect(weights[.footwear]! > weights[.bottom]!)
        #expect(abs(weights[.top]! - 1) < 0.0001, "the fullest slot gets no boost")

        // Headwear is a fashion opinion, not an observation — `StyleView` draws the same
        // line and the two must agree about the same wardrobe.
        #expect(weights[.headwear] == nil)
        #expect(weights[.accessory] == nil)
    }

    @Test("An empty wardrobe steers nowhere")
    func emptyWardrobeHasNoGap() {
        #expect(WardrobeGap.weights(owned: [:]).isEmpty)
        #expect(WardrobeGap.weights(owned: [.top: 0, .bottom: 0]).isEmpty)
    }

    @Test("The gap lifts a jacket over a marginally better t-shirt, but not over a bad one")
    func gapLiftsButDoesNotRescue() {
        let gaps = WardrobeGap.weights(owned: [.top: 8])
        let pool = [
            candidate("tee", a, slot: .top, affinity: 0.60),
            candidate("jacket", b, slot: .outerwear, affinity: 0.55),
            candidate("badjacket", c, slot: .outerwear, affinity: 0.10)
        ]

        var saturation = Saturation()
        let ordered = Discovery.order(pool, saturation: &saturation, gaps: gaps)

        #expect(ordered.first?.id == "jacket", "an empty slot should lift a near-equal candidate")
        #expect(ordered.last?.id == "badjacket", "but it must never rescue a bad pairing")
    }

    // MARK: - Determinism

    /// `FeedView` already learned what a list that recomputes its order costs: you read a
    /// page that reorders under your thumb. A deck that reshuffled between one scroll and
    /// the next would be the same bug with better photography.
    @Test("The same input gives the same order every time")
    func orderIsDeterministic() {
        let pool = (0..<24).map {
            candidate("x\($0)", [a, b, c, d][$0 % 4], affinity: 0.5, familiar: $0 % 5 != 0)
        }

        var first = Saturation()
        var second = Saturation()
        let one = Discovery.order(pool, saturation: &first)
        let two = Discovery.order(pool.shuffled(), saturation: &second)

        #expect(one.map(\.id) == two.map(\.id), "the input order must not decide the output order")
    }

    // MARK: - The server's half

    @Test("interleave spreads a page across brands and keeps recency within one")
    func interleaveRoundRobins() {
        // What a date-sorted query actually returns: one storefront's sweep, then everyone
        // else. This is the shape that produced a page of nothing but Kith.
        let rows = (0..<6).map { (id: "a\($0)", brand: a) }
            + [(id: "b0", brand: b), (id: "b1", brand: b)]
            + [(id: "c0", brand: c)]

        let paged = Discovery.interleave(rows, by: \.brand)

        // Nothing is dropped — the route's cursor is a position in an enumeration, and a row
        // discarded here is a product no page would ever show again.
        #expect(paged.count == rows.count)

        // Within a brand, the caller's order survives — that is where recency lives.
        #expect(paged.filter { $0.brand == a }.map(\.id) == ["a0", "a1", "a2", "a3", "a4", "a5"])

        // And the head alternates rather than opening with A's whole sweep.
        #expect(Set(paged.prefix(3).map(\.brand)).count == 3)
    }

    @Test("interleave breaks adjacency only when one brand is all that is left")
    func interleaveDefersRepeatsToTheTail() {
        let rows = (0..<6).map { (id: "a\($0)", brand: a) } + [(id: "b0", brand: b)]
        let paged = Discovery.interleave(rows, by: \.brand)

        #expect(paged.count == 7)
        // B has one row and must be spent early, while A's remaining five have nowhere else
        // to go — so the repeats are pushed to the tail rather than the head.
        #expect(paged.prefix(2).map(\.brand) == [a, b])
    }
}

/// The three sharp edges in `Discovery` that were never reachable through the app and were
/// one caller away from being reachable through anything else.
@Suite("Discovery edges")
struct DiscoveryEdgeTests {
    private func candidate(_ id: String, _ brand: UUID, affinity: Double = 0.5) -> DiscoveryCandidate {
        DiscoveryCandidate(id: id, brandID: brand, slot: .top, affinity: affinity)
    }

    /// `while !remaining.contains(where: underCap) { round += 1 }` never terminates when the
    /// cap is zero, because `perBrand * (round + 1)` stays zero for every round. `Saturation`
    /// guards its own tuning parameter; this one had nothing.
    @Test("A cap of zero is clamped rather than looping forever", .timeLimit(.minutes(1)))
    func zeroCapTerminates() {
        let brand = UUID()
        var saturation = Saturation()
        let out = Discovery.order(
            [candidate("a", brand), candidate("b", brand)],
            saturation: &saturation,
            perBrand: 0
        )
        #expect(out.count == 2)
    }

    /// `best` compares with `>` and `==`, both of which are false against a NaN — so a NaN
    /// candidate could never be selected, and a page of them selected nothing at all, which
    /// the emit loop reads as "no candidate" and truncates the deck.
    @Test("A page whose values are all NaN is still emitted in full")
    func nanDoesNotTruncate() {
        var saturation = Saturation()
        let out = Discovery.order(
            [
                candidate("a", UUID(), affinity: .nan),
                candidate("b", UUID(), affinity: .nan),
                candidate("c", UUID(), affinity: .nan)
            ],
            saturation: &saturation
        )
        #expect(out.count == 3)
    }

    /// …and a NaN ranks last rather than first, so one bad row cannot lead the deck.
    @Test("A NaN scores worse than a real value")
    func nanRanksLast() {
        var saturation = Saturation()
        let out = Discovery.order(
            [candidate("bad", UUID(), affinity: .nan), candidate("good", UUID(), affinity: 0.2)],
            saturation: &saturation
        )
        #expect(out.first?.id == "good")
    }

    /// `similarity > 0` was the old test, and `BrandVector.similarity` is a weighted mean
    /// that essentially never reaches zero — so every card was familiar and the exploration
    /// slots had an empty pool to draw from.
    @Test("The familiarity cutoff is the middle of the page, not zero")
    func cutoffIsRelative() {
        #expect(Discovery.familiarityCutoff([]) == nil)
        #expect(Discovery.familiarityCutoff([0.4]) == 0.4)
        #expect(Discovery.familiarityCutoff([0.2, 0.4, 0.6]) == 0.4)
        // Four values that would all have passed `> 0` handsomely.
        let cutoff = Discovery.familiarityCutoff([0.41, 0.43, 0.45, 0.47])
        #expect(cutoff == 0.44)
    }

    /// A card with no brand must not be a *different* brand every time it is ranked.
    @Test("The unattributed brand id is stable")
    func unattributedIsFixed() {
        #expect(Discovery.unattributed == Discovery.unattributed)
    }
}

/// What a page of `/v1/discover` actually looks like, and the property the reader notices.
///
/// The route hands over exactly two garments per brand per page, so a page is a set of
/// pairs. With a per-round cap of two, both of a brand's cards were eligible in the same
/// round and — a catalogue being internally consistent, so its two cards scoring within a
/// hair of each other — they landed within a card or two of one another. `Saturation` damps
/// the second by a quarter, which does not move it past a whole round of strangers. The
/// scroll read as *the same brands over and over* while the ordering was doing exactly what
/// it was told.
@Suite("A page of pairs")
struct DiscoveryPageTests {
    private func page(brands: Int, each: Int) -> [DiscoveryCandidate] {
        let ids = (0..<brands).map { _ in UUID() }
        return ids.enumerated().flatMap { index, brand in
            (0..<each).map {
                // Every brand slightly better than the next, and a brand's own cards
                // near-identical — which is what a real catalogue looks like.
                DiscoveryCandidate(
                    id: "\(index)-\($0)",
                    brandID: brand,
                    // A real spread of verdicts across brands — `Pairing` scores range
                    // widely — and a brand's own two cards near-identical.
                    affinity: 0.95 - Double(index) * 0.045 - Double($0) * 0.001
                )
            }
        }
    }

    /// The contract: a brand's second card waits for every other brand's first.
    @Test("No brand comes round twice before every brand has been seen once")
    func everyBrandOnceFirst() {
        let pool = page(brands: 15, each: 2)
        var saturation = Saturation()
        let ordered = Discovery.order(pool, saturation: &saturation)

        var seen: Set<UUID> = []
        for (position, candidate) in ordered.enumerated() {
            if !seen.insert(candidate.brandID).inserted {
                #expect(
                    position >= 15,
                    "a brand repeated at position \(position), before all 15 had appeared"
                )
                return
            }
        }
    }

    /// The whole page is still delivered — spacing a brand's cards apart must not drop one.
    /// A card that never appears is a garment no page will ever show, which is the failure
    /// `Discovery.interleave` refuses for the same reason.
    @Test("Spacing a brand's cards apart loses none of them")
    func nothingIsDropped() {
        let pool = page(brands: 15, each: 2)
        var saturation = Saturation()
        let ordered = Discovery.order(pool, saturation: &saturation)
        #expect(ordered.count == pool.count)
        #expect(Set(ordered.map(\.id)) == Set(pool.map(\.id)))
    }
}

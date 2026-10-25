import Foundation
import Testing

@testable import StreetwCore

@Suite("Today's picks")
struct DailyPicksTests {
    private let day = "2026-10-25"

    private func candidate(
        _ id: String,
        _ title: String,
        brand: String = "Halden Works",
        color: String? = nil,
        fact: DailyPicks.Fact? = nil,
        daysAgo: Double = 1
    ) -> DailyPicks.Candidate {
        let listing = ShopListing(
            id: id,
            brandKey: brand,
            brandName: brand,
            title: title,
            publishedAt: Date(timeIntervalSince1970: 1_800_000_000 - daysAgo * 86_400)
        )
        return DailyPicks.Candidate(
            listing: listing,
            garment: Garment(id: id, title: title, color: color),
            fact: fact
        )
    }

    private func owned(_ title: String, color: String? = nil) -> Garment {
        Garment(id: "owned:" + title, title: title, color: color)
    }

    private func counts(_ wardrobe: [Garment]) -> [GarmentSlot: Int] {
        wardrobe.reduce(into: [:]) { $0[$1.slot, default: 0] += 1 }
    }

    // MARK: - The day

    /// Seeded per process, `Hasher` would hand out a new set on every launch; this has to be
    /// today's answer on every launch today and a different one tomorrow.
    @Test("The day's hash is fixed for a day and moves between days")
    func jitterIsDeterministic() {
        let one = DailyPicks.jitter("shopify:1", day: day)
        #expect(one == DailyPicks.jitter("shopify:1", day: day))
        #expect(one >= 0 && one < 1)
        #expect(one != DailyPicks.jitter("shopify:1", day: "2026-10-26"))
        #expect(one != DailyPicks.jitter("shopify:2", day: day))
    }

    @Test("A day is the phone's calendar date")
    func dayKey() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "Europe/Berlin"))
        // 23:30 UTC on the 25th is already the 26th in Berlin.
        let late = Date(timeIntervalSince1970: 1_792_971_000)
        #expect(DailyPicks.day(of: late, in: calendar) == "2026-10-26")
    }

    // MARK: - Choosing

    @Test("A pick says what it goes with, and the partner is something owned")
    func pairsWithTheWardrobe() {
        let wardrobe = [owned("Heavy Boxy Tee", color: "White")]
        let picks = DailyPicks.choose(
            from: [candidate("trouser", "Double Pleat Trouser", color: "Black")],
            wardrobe: wardrobe,
            owned: counts(wardrobe),
            day: day
        )
        #expect(picks.map(\.id) == ["trouser"])
        #expect(picks.first?.partnerID == "owned:Heavy Boxy Tee")
        #expect(picks.first?.reason == .goesWith(fills: nil))
    }

    /// The Style tab's "what's missing", moved to where it can be acted on: three tops and
    /// trousers and no jacket should surface a jacket.
    @Test("Picks lean towards what the wardrobe has nothing in, and say so")
    func leansTowardsTheGap() {
        let wardrobe = [
            owned("Heavy Boxy Tee"), owned("Ringer Tee"), owned("Oxford Shirt"),
            owned("Cargo Pant"), owned("Work Boot")
        ]
        let picks = DailyPicks.choose(
            from: [
                candidate("shell", "Storm Shell Jacket", brand: "Ashgrove"),
                candidate("hoodie", "Wave Hoodie", brand: "Ondo"),
                candidate("coat", "Canvas Chore Coat", brand: "Halden")
            ],
            wardrobe: wardrobe,
            owned: counts(wardrobe),
            day: day
        )
        #expect(picks.last?.id == "hoodie")
        #expect(picks.first?.reason == .goesWith(fills: .outerwear))
        // Said once: the second jacket goes with something too, and does not open by
        // repeating that the wardrobe has no jacket.
        #expect(picks[1].reason == .goesWith(fills: nil))
    }

    /// Ties break on id, so without spreading every pick named the same jacket.
    @Test("Different picks point at different things you own")
    func anchorsSpread() {
        let wardrobe = [owned("Heavy Boxy Tee"), owned("Ringer Tee")]
        let picks = DailyPicks.choose(
            from: [
                candidate("cargo", "Cargo Pant", brand: "A"),
                candidate("denim", "Raw Denim Jean", brand: "B")
            ],
            wardrobe: wardrobe,
            owned: counts(wardrobe),
            day: day
        )
        #expect(picks.count == 2)
        #expect(Set(picks.compactMap(\.partnerID)).count == 2)
    }

    /// With nothing to pair against, the picks still work — on what the store knows for a
    /// fact — rather than inventing an argument.
    @Test("An empty wardrobe still gets picks, with an honest reason")
    func emptyWardrobe() {
        let picks = DailyPicks.choose(
            from: [
                candidate("restock", "Canvas Chore Coat", fact: .backInYourSize(["M"])),
                candidate("plain", "Ripstop Cargo Pant", brand: "Rivet")
            ],
            wardrobe: [],
            owned: [:],
            day: day
        )
        #expect(picks.count == 2)
        #expect(picks.first { $0.id == "restock" }?.reason == .fact(.backInYourSize(["M"])))
        #expect(picks.first { $0.id == "plain" }?.reason == .fromYourShops)
        #expect(picks.allSatisfy { $0.partnerID == nil })
    }

    /// A wardrobe that has trousers covered and nothing that goes with another pair: there is
    /// no true sentence to print under it.
    @Test("Nothing is picked without a reason")
    func noReasonNoPick() {
        let wardrobe = [owned("Cargo Pant"), owned("Raw Denim Jean"), owned("Wool Trouser")]
        let picks = DailyPicks.choose(
            from: [candidate("chino", "Pleated Chino")],
            wardrobe: wardrobe,
            owned: counts(wardrobe),
            day: day
        )
        #expect(picks.isEmpty)
    }

    @Test("Headwear and accessories are never picks")
    func onlyEssentials() {
        let picks = DailyPicks.choose(
            from: [candidate("cap", "Five Panel Cap"), candidate("bag", "Sling Bag")],
            wardrobe: [],
            owned: [:],
            day: day
        )
        #expect(picks.isEmpty)
    }

    @Test("One shop cannot fill the set while another has something")
    func spreadAcrossShops() {
        let wardrobe = [owned("Heavy Boxy Tee")]
        var candidates = (0..<6).map { candidate("a\($0)", "Cargo Pant \($0)", brand: "A") }
        candidates.append(candidate("b0", "Wool Trouser", brand: "B"))
        let picks = DailyPicks.choose(from: candidates, wardrobe: wardrobe, owned: counts(wardrobe), day: day)
        #expect(picks.count == DailyPicks.count)
        #expect(picks.prefix(2).contains { $0.id == "b0" })
    }

    /// Somebody who follows one shop still gets a full set from it.
    @Test("A single shop still fills the set")
    func singleShopFills() {
        let candidates = (0..<8).map { candidate("a\($0)", "Cargo Pant \($0)", brand: "A") }
        let picks = DailyPicks.choose(from: candidates, wardrobe: [], owned: [:], day: day)
        #expect(picks.count == DailyPicks.count)
    }

    /// Saving a pick changes the wardrobe, which changes every score; the set must not
    /// re-rank under the thumb that saved one.
    @Test("Today's set is kept in its order and topped up")
    func keepsTodaysSet() {
        let candidates = (0..<8).map { candidate("p\($0)", "Cargo Pant \($0)", brand: "B\($0)") }
        let picks = DailyPicks.choose(
            from: candidates,
            wardrobe: [],
            owned: [:],
            day: day,
            keeping: ["p7", "p3", "gone"]
        )
        #expect(Array(picks.map(\.id).prefix(2)) == ["p7", "p3"])
        #expect(!picks.contains { $0.id == "gone" })
        #expect(picks.count == DailyPicks.count)
    }

    @Test("The same inputs give the same picks")
    func deterministic() {
        let candidates = (0..<30).map { candidate("p\($0)", "Cargo Pant \($0)", brand: "B\($0 % 7)") }
        let first = DailyPicks.choose(from: candidates, wardrobe: [], owned: [:], day: day)
        let second = DailyPicks.choose(from: candidates.reversed(), wardrobe: [], owned: [:], day: day)
        #expect(first == second)
    }

    @Test("A large catalogue is sampled, with the newest and today's set always in")
    func poolIsBounded() {
        let listings = (0..<1_000).map { index in
            ShopListing(
                id: "p\(index)",
                brandKey: "A",
                brandName: "A",
                title: "Cargo Pant",
                publishedAt: Date(timeIntervalSince1970: Double(index) * 60)
            )
        }
        let pool = DailyPicks.pool(listings, day: day, keeping: ["p3"])
        #expect(pool.count <= DailyPicks.poolSize + 1)
        #expect(pool.contains { $0.id == "p999" })
        #expect(pool.contains { $0.id == "p3" })
        #expect(DailyPicks.pool(listings, day: day, keeping: ["p3"]).map(\.id) == pool.map(\.id))
        #expect(DailyPicks.pool(listings, day: "2026-10-26").map(\.id) != pool.map(\.id))
    }

    @Test("What's missing needs a wardrobe to be missing from")
    func missingNeedsThree() {
        #expect(DailyPicks.missing(owned: [.top: 2]).isEmpty)
        #expect(DailyPicks.missing(owned: [.top: 2, .bottom: 1]) == [.outerwear, .footwear])
    }
}

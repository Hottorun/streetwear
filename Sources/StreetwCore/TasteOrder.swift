// TasteOrder.swift
// The phone's taste, applied to an answer the server ranked.
//
// Phase 4's search is "followed shops first, ranked by taste" (`docs/ai.md`), and the taste is
// the phone's: what somebody owns and saves never leaves it, so the server can only rank by the
// words. This puts the two together without letting either erase the other.
//
// - **Taste is read coarsely.** A pairing verdict is a score in 0...1, and two jackets a hair
//   apart are not a statement about anybody. Scores are read in tenths, and within a tenth the
//   server's order stands — so the words still decide between near-equals, and taste moves only
//   what it has a real opinion about.
// - **Sold-out still goes last, never away** — `ShopSearch`'s rule, kept: a re-rank that pulled
//   a sold-out jacket to the top because it goes with your trousers would be a promise the shop
//   cannot keep today.
// - **It reorders; it never hides.** A garment nothing you own goes with is scored zero and
//   sinks within its band; it is not removed. The same rule as the size profile and the style
//   statement.
// - **Nothing owned, nothing to say**: with an empty wardrobe the answer comes back exactly as
//   the server ranked it.

import Foundation

public enum TasteOrder {
    /// How finely a verdict is read when it reorders.
    static let step = 0.1

    public static func order<Item>(
        _ items: [Item],
        wardrobe: [Garment],
        statement: StyleStatement? = nil,
        garment: (Item) -> Garment,
        isAvailable: (Item) -> Bool
    ) -> [Item] {
        guard !wardrobe.isEmpty, items.count > 1 else { return items }
        // Decorated once each, then sorted — the keys are a pairing run over the whole wardrobe,
        // and a comparator would ask for them n·log n times.
        let keys: [(available: Bool, band: Int)] = items.map { item in
            let best = Pairing.best(for: garment(item), from: wardrobe, limit: 1, statement: statement).first
            let score = best?.verdict.score ?? 0
            return (isAvailable(item), Int((score / step).rounded(.down)))
        }
        let order = items.indices.sorted { a, b in
            if keys[a].available != keys[b].available { return keys[a].available }
            if keys[a].band != keys[b].band { return keys[a].band > keys[b].band }
            return a < b
        }
        return order.map { items[$0] }
    }
}

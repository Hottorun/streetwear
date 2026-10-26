// PickLedger.swift
// What Shop's picks remember between visits: today's set, and what was turned down.
//
// **Today's set is kept, not recomputed.** `DailyPicks` is deterministic, but its inputs are
// not still: saving a pick moves it into the wardrobe, which changes every score, and a set
// that re-ranked under the thumb that had just saved one of its cards would be the
// `DiscoverDeck.pinningRead` failure on a new screen. So the day's ids are written down the
// first time they are chosen, and for the rest of that day the set only grows (when the
// catalogue was too thin to fill it) or loses a pick somebody turned down.
//
// **A refusal is about the garment, not the shop.** "Not for me" on a pick is the one negative
// signal there is about a product from a shop you chose to follow — `BrandDismissal` refuses
// a whole brand and demotes everything like it, which is the wrong verdict on a shop you just
// said you want to hear from. Bounded, oldest forgotten first: it exists so the same pick is
// not offered again next week, not to be a record.
//
// `UserDefaults`, like `StyleStatementStore`: two small values belonging to this device, not
// worth a schema migration. **Local only.** What somebody turned down never leaves the phone,
// the same bargain as every other taste signal here.

import Foundation

@MainActor
enum PickLedger {
    /// Per profile. Read at the moment of use rather than captured: Shop is rebuilt on a
    /// switch, and nothing here awaits.
    private static var todayKey: String { ProfileScope.active.key("shopPicksToday") }
    private static var refusedKey: String { ProfileScope.active.key("shopPicksRefused") }

    /// How many refusals are remembered.
    static let refusedLimit = 500

    private struct Today: Codable {
        var day: String
        var ids: [String]
    }

    /// The set already chosen on `day`, in order; empty on any other day.
    static func kept(on day: String) -> [String] {
        guard let data = UserDefaults.standard.data(forKey: todayKey),
              let today = try? JSONDecoder().decode(Today.self, from: data),
              today.day == day
        else { return [] }
        return today.ids
    }

    /// Writes the day's set. An empty one is not written — a first launch before anything has
    /// synced chose nothing, and remembering that would hold the day's picks empty after the
    /// catalogue arrived.
    static func keep(_ ids: [String], on day: String) {
        guard !ids.isEmpty, ids != kept(on: day),
              let data = try? JSONEncoder().encode(Today(day: day, ids: ids)) else { return }
        UserDefaults.standard.set(data, forKey: todayKey)
    }

    static var refused: Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: refusedKey) ?? [])
    }

    /// "Not for me": never offered again, and off today's set now.
    static func refuse(_ id: String, on day: String) {
        var list = UserDefaults.standard.stringArray(forKey: refusedKey) ?? []
        list.removeAll { $0 == id }
        list.append(id)
        if list.count > refusedLimit { list.removeFirst(list.count - refusedLimit) }
        UserDefaults.standard.set(list, forKey: refusedKey)

        let remaining = kept(on: day).filter { $0 != id }
        if let data = try? JSONEncoder().encode(Today(day: day, ids: remaining)) {
            UserDefaults.standard.set(data, forKey: todayKey)
        }
    }
}

// TasteScope.swift
// The collection as the taste engines are allowed to see it.
//
// `TasteRule` (in the core) decides what one save is; this is where the app gathers what
// that rule needs and hands every consumer the same answer. **Every reader of taste goes
// through here** — a reading on the Style tab built from one set of saves and a ranking on
// the Discover tab built from another is exactly the drift that makes a number look broken,
// and five consumers each filtering by hand is how it would happen.
//
// Who reads what, and why the lines are where they are:
//
// - **Inferring taste** — the Style tab's reading (`StyleProfile`), the brand recommendations'
//   taste vector, the Discover taste vector — reads `counted`/`weighted`: nothing left out, and
//   the mood leant on. These are the places a save is taken as a statement about the person.
// - **Pairing against what you have** — "goes with your …" (`GoesWith`), `FitStudio`, the
//   Discover card's pairing — reads `pairingPool`. The wardrobe is in it **whatever its taste
//   setting**, because owning something is a fact and liking it is not: a jacket kept out of
//   the taste reading is still in the cupboard and still goes with the trousers. Only the
//   fallback for somebody who never filed anything as owned — every save standing in for a
//   wardrobe — goes through the rule, because there a save is being read as "you", and a save
//   somebody said is not them is the one thing known not to be.
// - **Proposing outfits** — `FitSuggestions` and its gap count — reads `fitPool`: the wardrobe,
//   plus the inspiration that counts. Same reasoning, and the mood leans the row.
// - **Arranging by hand** — the fit canvas tray, a fit started from a selection — reads none of
//   this. A person choosing pieces is not an inference.

import Foundation
import StreetwCore
import SwiftData

struct TasteScope: Equatable {
    /// Saves filed on a board that doesn't count, by `SavedItem.id`.
    private(set) var onIgnoredBoard: Set<UUID> = []
    /// Saves on the board somebody is in the mood for.
    private(set) var inMood: Set<UUID> = []
    /// Saves somebody has said not to use, whatever board they are on. Carried rather than
    /// read off the save at the point of use so this value changes when one is flipped — it
    /// is what the derivations behind it are keyed on.
    private(set) var excluded: Set<UUID> = []
    /// The mood board's name, for saying so on screen. Nil when there is no mood.
    private(set) var moodName: String?

    /// - Parameters:
    ///   - boards: any boards, typically `Board.shapingTaste`'s. Only those with a setting are
    ///     walked, so passing them all costs a scalar read each.
    ///   - saves: the collection, for the per-item flag. One scalar per save, already faulted
    ///     by whoever holds the query.
    init(boards: [Board], saves: [SavedItem]) {
        for board in boards {
            switch board.tasteMode {
            case .counts:
                continue
            case .ignored:
                onIgnoredBoard.formUnion(board.saves.map(\.id))
            case .mood:
                inMood.formUnion(board.saves.map(\.id))
                moodName = board.name
            }
        }
        for save in saves where save.isExcludedFromTaste {
            excluded.insert(save.id)
        }
    }

    /// What one save is to the taste engines. Every question below is this one.
    func role(of save: SavedItem) -> TasteRule.Role {
        var modes: Set<TasteMode> = []
        if onIgnoredBoard.contains(save.id) { modes.insert(.ignored) }
        if inMood.contains(save.id) { modes.insert(.mood) }
        return TasteRule.role(isExcluded: excluded.contains(save.id), boards: modes)
    }

    func counts(_ save: SavedItem) -> Bool { role(of: save) != .ignored }

    func isMood(_ save: SavedItem) -> Bool { role(of: save) == .mood }

    /// The saves a reading of taste is built from, in the order given.
    func counted(_ saves: [SavedItem]) -> [SavedItem] {
        saves.filter(counts)
    }

    /// The saves a taste *vector* is built from, each with its weight — the mood leant on, the
    /// left-out dropped. See `TasteRule.weights`.
    func weighted(_ saves: [SavedItem]) -> [(save: SavedItem, weight: Double)] {
        let weights = TasteRule.weights(saves.map(role(of:)))
        return zip(saves, weights).filter { $0.1 > 0 }.map { (save: $0.0, weight: $0.1) }
    }

    /// What "goes with your …" pairs against: the wardrobe whatever its taste setting, or —
    /// for somebody who has never filed anything as owned — every save that counts.
    func pairingPool(_ saves: [SavedItem]) -> [SavedItem] {
        let owned = saves.filter { $0.type == .wardrobe }
        return owned.isEmpty ? counted(saves) : owned
    }

    /// What the fit suggestions are built from: the wardrobe, and the inspiration that counts.
    func fitPool(_ saves: [SavedItem]) -> [SavedItem] {
        saves.filter { $0.type == .wardrobe || counts($0) }
    }

    /// How many saves are left out — what the Style tab says beside its reading, so a reading
    /// built from fewer saves than the wall holds says why.
    func leftOut(of saves: [SavedItem]) -> Int {
        saves.count { !counts($0) }
    }
}

extension BrandUpdate {
    /// The catalogue text a taste vector is built from.
    var productSummary: ProductSummary {
        ProductSummary(
            title: title,
            productType: productType,
            tags: tags,
            priceAmount: priceAmount,
            publishedAt: publishedAt
        )
    }
}

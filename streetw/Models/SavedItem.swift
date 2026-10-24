// SavedItem.swift
// Model for content the user has saved (wardrobe/inspiration)
import Foundation
import SwiftData

@Model
final class SavedItem {
    enum SaveType: String, Codable, Sendable, CaseIterable, Identifiable {
        case inspiration
        case wardrobe

        var id: String { rawValue }

        var label: String {
            switch self {
            case .inspiration: "Inspiration"
            case .wardrobe: "Wardrobe"
            }
        }

        var symbol: String {
            switch self {
            case .inspiration: "bookmark"
            case .wardrobe: "tshirt"
            }
        }
    }

    var id: UUID = UUID()
    var update: BrandUpdate?
    var savedAt: Date = Date()
    var type: SaveType = SaveType.inspiration
    var note: String?

    /// **Legacy, and read by exactly one thing: `BoardFiling.adoptLegacy`.**
    ///
    /// 1.0 filed a save on at most one board, through this to-one, although boards were
    /// always meant to be filters rather than folders — an item belongs with the other tees
    /// *and* with Tokyo. It stays in the schema because that is the safe way to migrate a store
    /// already on phones: the many-to-many below is a brand-new relationship, which is the one
    /// change a lightweight migration cannot get wrong, and the launch pass moves every filing
    /// across and clears this in the same save. After the first launch of a build that has
    /// `boards`, this is nil on every row. Never read it for anything else and never write it.
    var board: Board?

    /// The boards this is filed on. Empty is the common case and stays allowed: most saves
    /// never get filed anywhere, and requiring a board before you can keep something would
    /// defeat the point of a one-tap save.
    ///
    /// Many-to-many and a cascade in neither direction — deleting a board must never take its
    /// saves with it, and un-saving something just takes it off the boards it was on. The
    /// inverse and the delete rule are declared once, on `Board.saves`.
    var boards: [Board] = []

    /// "Don't use for my taste." See `TasteRule` — this beats every board setting.
    ///
    /// Taste only: the item still shows everywhere it always did, and a wardrobe piece flagged
    /// this way still goes into fits and still answers "goes with your …", because owning
    /// something is a fact and liking it is not. See `TasteScope` for who reads what.
    var isExcludedFromTaste: Bool = false

    /// The size you own, or the one you're waiting for. Free text on purpose — brands
    /// run their own scales and "44" or "Youth L" must be as storable as "M".
    var sizeNote: String?

    /// Outfits this item appears in. Many-to-many, and *not* a cascade in either
    /// direction: deleting a fit must not delete the clothes, and un-saving something
    /// leaves the fits it was in rather than silently rewriting them.
    var fits: [Fit] = []

    init(update: BrandUpdate?, savedAt: Date = Date(), type: SaveType = .inspiration, note: String? = nil) {
        self.id = UUID()
        self.update = update
        self.savedAt = savedAt
        self.type = type
        self.note = note
    }

    /// Matches a free-text search across everything a person might remember about a
    /// saved thing: what it was called, who made it, how it was tagged, and whatever
    /// they wrote on it. Deliberately not a `#Predicate` — the fields worth searching
    /// live across a relationship and in arrays, which SwiftData predicates handle
    /// poorly, and a collection is small enough to filter in memory.
    func matches(_ query: String) -> Bool {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return true }
        guard let update else { return false }

        let haystack = [
            update.title,
            update.summary ?? "",
            update.brand?.name ?? "",
            update.productType ?? "",
            note ?? "",
            update.tags.joined(separator: " "),
            // The host, so "kith" finds things shared from kith.com even before that
            // brand is followed and has a name attached.
            update.linkURL?.host() ?? ""
        ].joined(separator: " ").lowercased()

        // Every word must appear somewhere, so "kith hoodie" narrows rather than widens.
        return needle.split(separator: " ").allSatisfy { haystack.contains($0) }
    }

    /// Whether this row has been deleted out from under whatever is still drawing it.
    ///
    /// The `Fit.isGone` rule, for the same reason: reading any property of a deleted `@Model`
    /// traps, and a bulk delete on the wall removes rows a `LazyVStack` may still hold for
    /// one more pass. `isDeleted` alone is not enough — a model whose context has gone
    /// answers false to it and still traps.
    var isGone: Bool { isDeleted || modelContext == nil }

    // MARK: - Boards

    func isFiled(on board: Board) -> Bool {
        boards.contains { $0.id == board.id }
    }

    /// Where this went, in words — what the save confirmation says it was kept to.
    ///
    /// The board when it is on exactly one, since that is the most specific true answer; the
    /// type otherwise, including when it is on several, because a list of board names is not
    /// something a one-line confirmation can say.
    var destinationLabel: String {
        boards.count == 1 ? boards[0].name : type.label
    }

}

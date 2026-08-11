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
    /// Optional, and stays optional: most saves never get filed anywhere, and requiring
    /// a board before you can keep something would defeat the point of a one-tap save.
    var board: Board?
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
}

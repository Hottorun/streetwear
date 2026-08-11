// Fit.swift
// An outfit: several saved things, worn together.
//
// The gap this fills is the difference between a collection and a wardrobe. Saving tells
// you what you like one item at a time; a fit is the first thing in the app that says
// something about how the pieces relate — and it is the only artefact here a person would
// actually want to look at again a month later.
//
// Deliberately built from `SavedItem` rather than from `BrandUpdate`. A fit is made of
// things you kept, so it inherits the collection's guarantees: nothing in a fit can be
// pruned out from under it, and removing a brand doesn't gut it.

import Foundation
import StreetwCore
import SwiftData

@Model
final class Fit {
    var id: UUID = UUID()
    var name: String = ""
    var createdAt: Date = Date()
    var note: String?

    /// Many-to-many: one saved item can appear in several fits, which is the whole point
    /// of owning a good pair of trousers.
    @Relationship(inverse: \SavedItem.fits)
    var items: [SavedItem] = []

    init(name: String = "", items: [SavedItem] = []) {
        self.id = UUID()
        self.name = name
        self.items = items
        self.createdAt = Date()
    }

    /// The items in the order a fit is read — head down — rather than the order they
    /// happened to be added in.
    var ordered: [SavedItem] {
        items.sorted { $0.slot.stackOrder < $1.slot.stackOrder }
    }

    var imageURLs: [URL] {
        ordered.compactMap { $0.update?.primaryImageURL }
    }

    /// "Jacket · Tee · Cargo Pant" — what it is, when it has no name yet.
    var derivedName: String {
        let parts = ordered.compactMap { $0.update?.title }
        guard !parts.isEmpty else { return "Empty fit" }
        return parts.prefix(3).joined(separator: " · ")
    }

    var displayName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? derivedName : name
    }
}

extension SavedItem {
    /// Which part of an outfit this occupies, read off the catalogue text.
    ///
    /// Computed rather than stored: it depends only on fields that never change after the
    /// item is saved, and a stored copy would go stale the moment the classifier improves
    /// — the same trap `BrandUpdate.gender` needed a version number to escape, but without
    /// the cost, because nothing filters on this at feed scale.
    var slot: GarmentSlot {
        guard let update else { return .unknown }
        return GarmentClassifier.classify(
            title: update.title,
            productType: update.productType,
            tags: update.tags,
            visionCategories: update.visionCategories
        )
    }
}

/// A fit the app proposes, assembled from things already saved.
///
/// Not stored — recomputed from the wardrobe each time, because it is a *suggestion*
/// rather than a record. The moment someone keeps one it becomes a real `Fit` and stops
/// being regenerated.
struct SuggestedFit: Identifiable, Hashable {
    var items: [SavedItem]

    /// Stable across recomputation so SwiftUI doesn't animate a reshuffle on every render.
    var id: String { items.map(\.id.uuidString).sorted().joined() }

    var ordered: [SavedItem] {
        items.sorted { $0.slot.stackOrder < $1.slot.stackOrder }
    }
}

enum FitSuggestions {
    /// Composes outfits from saved items, one garment per slot.
    ///
    /// The rules are deliberately dull, because a recommender that is clever and wrong is
    /// worse than one that is obvious and right:
    ///
    /// - **One item per slot**, and never two of the same — two pairs of trousers is not
    ///   a fit.
    /// - **A top and a bottom are required.** Outerwear and footwear are added when the
    ///   wardrobe has them; a proposal of just a jacket is not an outfit.
    /// - **Nothing unplaceable is ever used.** An item the classifier couldn't read would
    ///   appear in a slot it may not belong to, which reads as a bug rather than a
    ///   suggestion.
    /// - **Deterministic.** Seeded by nothing but the wardrobe itself, so the same saves
    ///   produce the same fits and the section doesn't reshuffle every time it is drawn.
    static func build(from saves: [SavedItem], limit: Int = 6) -> [SuggestedFit] {
        var bySlot: [GarmentSlot: [SavedItem]] = [:]
        for save in saves where save.update != nil {
            let slot = save.slot
            guard slot != .unknown, GarmentSlot.essential.contains(slot) else { continue }
            bySlot[slot, default: []].append(save)
        }

        // Newest first within each slot, so a fit is built from what someone is currently
        // into rather than from whatever they saved a year ago.
        for slot in bySlot.keys {
            bySlot[slot]?.sort { $0.savedAt > $1.savedAt }
        }

        guard let tops = bySlot[.top], let bottoms = bySlot[.bottom],
              !tops.isEmpty, !bottoms.isEmpty
        else { return [] }

        let outerwear = bySlot[.outerwear] ?? []
        let footwear = bySlot[.footwear] ?? []

        var fits: [SuggestedFit] = []
        var seen: Set<String> = []

        // Walk the cross product diagonally rather than nesting loops, so the suggestions
        // vary in *both* axes early instead of pairing one top with every bottom.
        let pairs = max(tops.count, bottoms.count)
        for index in 0..<pairs where fits.count < limit {
            let top = tops[index % tops.count]
            let bottom = bottoms[index % bottoms.count]

            var items = [top, bottom]
            if !footwear.isEmpty { items.append(footwear[index % footwear.count]) }
            if !outerwear.isEmpty { items.append(outerwear[index % outerwear.count]) }

            let fit = SuggestedFit(items: items)
            guard seen.insert(fit.id).inserted else { continue }
            fits.append(fit)
        }

        return fits
    }
}

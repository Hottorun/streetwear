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
import UIKit

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

    /// Where each piece sits on the canvas. Parallel to `items` by id rather than by
    /// index — the relationship's order is not guaranteed and an item can be removed from
    /// a fit, which would silently shift every placement after it.
    ///
    /// Stored as structure, not only as the flattened picture, and that is the point:
    /// a fit stays editable, stays a list of things you own, and stays machine-readable —
    /// which is what lets a restock in one of its pieces be worth telling you about.
    var placements: [FitPlacement] = []

    /// Filename of the flattened render, in `FitRender.directory`. Nil until the canvas
    /// has been saved once, and regenerated on every save.
    var renderFile: String?

    /// Boards are filters, and a fit is as fileable as anything else in the collection.
    /// Nullifies on delete for the same reason `SavedItem.board` does — removing a board
    /// must never take the things filed under it.
    var board: Board?

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

    var renderURL: URL? {
        renderFile.map { FitRender.url(for: $0) }
    }

    /// The stored render, decoded — what a share sheet or a card actually hands over.
    ///
    /// An outfit is the most shareable thing in this app and the picture of it already
    /// existed, written on every save and drawn by every card; nothing could get it out.
    /// Reading the file rather than re-rendering keeps sharing free and guarantees what
    /// leaves is exactly what the collection shows.
    var renderImage: UIImage? {
        renderURL.flatMap { UIImage(contentsOfFile: $0.path(percentEncoded: false)) }
    }

    /// The canvas, in draw order. Anything placed but no longer in `items` is dropped —
    /// un-saving something leaves the fits it was in rather than rewriting them, so a
    /// stale placement is expected rather than a bug.
    var placed: [(item: SavedItem, placement: FitPlacement)] {
        let byID = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return placements
            .compactMap { placement in byID[placement.itemID].map { (item: $0, placement: placement) } }
            .sorted { $0.placement.z < $1.placement.z }
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

/// One garment's position on a fit's canvas.
///
/// Normalised, not in points: the canvas is drawn at whatever width the device gives it,
/// and storing pixel coordinates would scrunch every fit made on a Pro Max when opened on
/// a mini. `x`/`y` are the centre of the piece as a fraction of the canvas, and `scale` is
/// relative to a nominal tile — so a fit is resolution-independent and renders identically
/// at thumbnail size.
struct FitPlacement: Codable, Hashable, Sendable, Identifiable {
    var itemID: UUID
    var x: Double
    var y: Double
    var scale: Double
    /// Radians. Free rotation, because snapping is what makes a collage feel like a form.
    var rotation: Double
    /// Draw order. Sparse and ever-increasing rather than a compacted 0..<n, so bringing
    /// one piece to the front is a single write instead of renumbering the whole canvas.
    var z: Int

    var id: UUID { itemID }

    init(
        itemID: UUID,
        x: Double = 0.5,
        y: Double = 0.5,
        scale: Double = 1,
        rotation: Double = 0,
        z: Int = 0
    ) {
        self.itemID = itemID
        self.x = x
        self.y = y
        self.scale = scale
        self.rotation = rotation
        self.z = z
    }

    /// Lenient by hand, and it has to be.
    ///
    /// SwiftData decodes a Codable stored in a `@Model` with an internal `try!`, so a
    /// field added here after a store was written is not a migration problem — it is a
    /// crash on launch for anyone holding the older data. Only `itemID` is required;
    /// everything else falls back to the middle of the canvas at natural size, which is
    /// exactly where a freshly dropped piece would land anyway.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        itemID = try container.decode(UUID.self, forKey: .itemID)
        x = try container.decodeIfPresent(Double.self, forKey: .x) ?? 0.5
        y = try container.decodeIfPresent(Double.self, forKey: .y) ?? 0.5
        scale = try container.decodeIfPresent(Double.self, forKey: .scale) ?? 1
        rotation = try container.decodeIfPresent(Double.self, forKey: .rotation) ?? 0
        z = try container.decodeIfPresent(Int.self, forKey: .z) ?? 0
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

    /// Why this pairing, in the four words that fit under a card.
    ///
    /// Not decoration. A suggestion nobody can account for is indistinguishable from a
    /// random pair, which is exactly what the row felt like when it was proposing on slot
    /// and date alone — so the thing that scores a fit also has to say what it saw. Nil
    /// when the wardrobe has not been analysed yet and there is genuinely nothing to say.
    var reason: String?

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
    /// - **It looks at the clothes.** Every rule above is structural — one top, one
    ///   bottom, both things you kept — and a pair can satisfy all of them and still be
    ///   obviously wrong to anyone with eyes. `ColorHarmony` reads the dominant colour
    ///   `ImageTagger` already stored, ranks the pairings, drops outright clashes, and
    ///   hands back the line that says why. Where nothing has been analysed yet it scores
    ///   everything the same and the order falls back to what it always was.
    /// - Parameter statement: what the wearer has written about how they dress, where they
    ///   have written anything. It reorders and can rescue a pair the colour rules would
    ///   have refused; it never proposes a fit the structural rules rejected.
    static func build(
        from saves: [SavedItem],
        limit: Int = 6,
        statement: StyleStatement = StyleStatement()
    ) -> [SuggestedFit] {
        var bySlot: [GarmentSlot: [SavedItem]] = [:]
        // A suggestion is looked at before it is read, and a piece with no photograph
        // renders as a blank rectangle — so a proposal containing one looks broken however
        // good the pairing is. `ColorHarmony` can't speak for it either: the dominant
        // colour comes from the photograph.
        for save in saves where save.update?.imageURLStrings.isEmpty == false {
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

        var candidates: [(fit: SuggestedFit, score: Double)] = []
        var seen: Set<String> = []

        // Walk the cross product diagonally rather than nesting loops, so the suggestions
        // vary in *both* axes early instead of pairing one top with every bottom. Widened
        // past `limit` because the colour pass now ranks what comes out — proposing the
        // first six structurally valid pairs and then sorting them is not ranking, it is
        // sorting an arbitrary six.
        let pairs = max(tops.count, bottoms.count)
        for index in 0..<(pairs * 2) {
            let top = tops[index % tops.count]
            let bottom = bottoms[index % bottoms.count]

            // Ranked through `Pairing` so a stated preference reaches this row as well as
            // the product page's, but **vetoed** on the colour clash alone as it always was.
            // `Pairing.isRefused` is a stricter bar built for a page that can print nothing
            // at all; applying it here would empty the row on a thin wardrobe, which is
            // exactly the wardrobe most in need of a suggestion. What a statement *can* do
            // is rescue a clash it explicitly named.
            guard let topGarment = top.update?.garment, let bottomGarment = bottom.update?.garment
            else { continue }
            let verdict = Pairing.score(topGarment, with: bottomGarment, statement: statement)
            let stated = statement.statedPairing(between: topGarment, and: bottomGarment)
            guard stated
                || !ColorHarmony.isClash(top.update?.visionColor, bottom.update?.visionColor)
            else { continue }

            var items = [top, bottom]
            if !footwear.isEmpty { items.append(footwear[index % footwear.count]) }
            if !outerwear.isEmpty { items.append(outerwear[index % outerwear.count]) }

            let fit = SuggestedFit(items: items, reason: verdict.reason)
            guard seen.insert(fit.id).inserted else { continue }
            candidates.append((fit, verdict.score))
        }

        // Sorted on the colour reading, tie-broken on the id — so an unanalysed wardrobe,
        // where every score is identical, keeps a stable order rather than reshuffling on
        // each render, which is the property the whole function was built around.
        return candidates
            .sorted { $0.score == $1.score ? $0.fit.id < $1.fit.id : $0.score > $1.score }
            .prefix(limit)
            .map(\.fit)
    }
}

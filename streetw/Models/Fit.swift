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
        items.sorted { wornOver($0.update, $1.update, tieBreak: $0.id.uuidString < $1.id.uuidString) }
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
    @MainActor
    var renderImage: UIImage? {
        LocalImage.load(renderURL)
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
/// One garment in a proposal, which may or may not be yours.
///
/// A suggestion used to be `[SavedItem]` — strictly things already kept — and that made the
/// row useless in the case it should have been best at: a wardrobe with four tops and no
/// trousers got nothing at all, when "here is a bottom that would work with these" is the
/// most useful sentence the app could say. So a piece is now a `BrandUpdate` plus an
/// *optional* save, and `isOwned` is the difference.
///
/// The save is what carries the personal side — the note, the board, the size you own — so
/// keeping it rather than reaching through `update.saves` matters: a proposal built from a
/// catalogue row must not silently adopt somebody's note by matching on the product.
struct FitPiece: Identifiable, Hashable {
    var update: BrandUpdate
    /// The save this stands for, when it is something already kept. Nil means the app is
    /// suggesting a garment you do not have.
    var save: SavedItem?

    var isOwned: Bool { save != nil }
    var slot: GarmentSlot { save?.slot ?? update.garmentSlot }

    /// Identity is the save where there is one and the product otherwise, so a proposal
    /// does not change id the moment the same garment is kept.
    var id: String { save?.id.uuidString ?? update.id.uuidString }

    static func == (lhs: FitPiece, rhs: FitPiece) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

struct SuggestedFit: Identifiable, Hashable {
    var items: [FitPiece]

    /// The pieces this proposal is asking you to acquire. Empty for a fit made entirely of
    /// things you already own, which stays the common case.
    var unowned: [FitPiece] { items.filter { !$0.isOwned } }

    /// Why this pairing, in the four words that fit under a card.
    ///
    /// Not decoration. A suggestion nobody can account for is indistinguishable from a
    /// random pair, which is exactly what the row felt like when it was proposing on slot
    /// and date alone — so the thing that scores a fit also has to say what it saw. Nil
    /// when the wardrobe has not been analysed yet and there is genuinely nothing to say.
    var reason: String?

    /// Stable across recomputation so SwiftUI doesn't animate a reshuffle on every render.
    var id: String { items.map(\.id).sorted().joined() }

    var ordered: [FitPiece] {
        items.sorted { wornOver($0.update, $1.update, tieBreak: $0.id < $1.id) }
    }
}

/// Whether `first` is worn over `second` — the order a fit is read and drawn in.
///
/// `GarmentSlot.stackOrder` alone was enough until a fit could hold **two tops**: a hoodie
/// now brings a tee with it, and the two tie on that key. A tie is resolved in whatever
/// order the array happened to be in, so the base layer could be drawn on top of the thing
/// meant to cover it — which on a collage is not a subtle mistake.
/// - Parameter tieBreak: what to fall back on when the two are indistinguishable by
///   position and layer. Passed in rather than read here because a `SuggestedFit` is keyed
///   on its pieces and a stored `Fit` on its saves, and the arrangement has to be stable
///   across relaunches either way.
private func wornOver(_ first: BrandUpdate?, _ second: BrandUpdate?, tieBreak: @autoclosure () -> Bool) -> Bool {
    let firstSlot = first?.garmentSlot ?? .unknown
    let secondSlot = second?.garmentSlot ?? .unknown
    if firstSlot.stackOrder != secondSlot.stackOrder {
        return firstSlot.stackOrder < secondSlot.stackOrder
    }
    // Mid layers first, so they are drawn over the base layer they cover.
    let firstIsMid = first?.garment.layer == .mid
    let secondIsMid = second?.garment.layer == .mid
    if firstIsMid != secondIsMid { return firstIsMid }
    return tieBreak()
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
    /// - Parameter candidates: catalogue products, from brands already followed, offered
    ///   **only for slots the wardrobe cannot fill at all**. See `gapPieces`.
    static func build(
        from saves: [SavedItem],
        candidates: [BrandUpdate] = [],
        limit: Int = 6,
        statement: StyleStatement = StyleStatement()
    ) -> [SuggestedFit] {
        var bySlot: [GarmentSlot: [FitPiece]] = [:]
        // A suggestion is looked at before it is read, and a piece with no photograph
        // renders as a blank rectangle — so a proposal containing one looks broken however
        // good the pairing is. `ColorHarmony` can't speak for it either: the dominant
        // colour comes from the photograph.
        for save in saves where save.update?.imageURLStrings.isEmpty == false {
            let slot = save.slot
            guard slot != .unknown, GarmentSlot.essential.contains(slot),
                  let update = save.update
            else { continue }
            bySlot[slot, default: []].append(FitPiece(update: update, save: save))
        }

        // Newest first within each slot, so a fit is built from what someone is currently
        // into rather than from whatever they saved a year ago.
        for slot in bySlot.keys {
            bySlot[slot]?.sort { ($0.save?.savedAt ?? .distantPast) > ($1.save?.savedAt ?? .distantPast) }
        }

        // **Only where the wardrobe is genuinely empty.** See `gapPieces` for why this is a
        // gap-filler rather than a general source of pieces.
        for (slot, pieces) in gapPieces(from: candidates, missing: bySlot) {
            bySlot[slot] = pieces
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
            let topGarment = top.update.garment
            let bottomGarment = bottom.update.garment
            let verdict = Pairing.score(topGarment, with: bottomGarment, statement: statement)
            let stated = statement.statedPairing(between: topGarment, and: bottomGarment)
            guard stated
                || !ColorHarmony.isClash(top.update.visionColor, bottom.update.visionColor)
            else { continue }

            // **The shoes and the jacket are chosen, not counted to.**
            //
            // Everything above ranks the top against the bottom and then these two were
            // appended by `index % count` — an arithmetic accident of position in a list
            // sorted by date. So half of a four-piece proposal had been reasoned about and
            // half had not, and a fit could pair a considered black-on-cream top and bottom
            // with whatever shoe happened to sit at that index. That is precisely the
            // "obviously wrong to anyone with eyes" failure the colour pass was added to
            // stop, left in place for two of the four slots.
            //
            // Scored against the pair already chosen rather than against each other, since
            // the top and bottom are what the fit *is* and the other two are answering to
            // it. Same rule as above — a stated pairing can carry a clash, nothing else can
            // — and the same tie-break on id, so the row stays deterministic.
            var items = [top, bottom]
            var chosen = [topGarment, bottomGarment]
            if let shoe = accompaniment(to: chosen, from: footwear, statement: statement) {
                items.append(shoe)
            }
            if let coat = accompaniment(to: chosen, from: outerwear, statement: statement) {
                items.append(coat)
                chosen.append(coat.update.garment)
            }

            // **Nothing that needs something under it goes out without one.**
            //
            // `GarmentSlot` files a t-shirt and a hoodie in the same box, which is right for
            // "what kind of thing is this" and wrong here — so one-top-per-slot happily
            // proposed a hoodie and trousers with nothing underneath, or a jacket over a
            // hoodie over bare skin. Nobody dresses like that, and a suggestion that does
            // reads as the app not knowing what clothes are, which is precisely the
            // gimmicky-recommender failure this whole function is written against.
            //
            // The base layer is scored against everything already chosen, exactly as the
            // shoes and the coat are, so it is a tee that goes with the fit rather than
            // whichever tee was saved most recently.
            if chosen.contains(where: \.needsBaseLayer),
               !chosen.contains(where: { $0.slot == .top && $0.layer == .base }) {
                // Only from tops that are genuinely base layers, and never the top already
                // in the fit.
                let bases = tops.filter {
                    $0.id != top.id && $0.update.garment.layer == .base
                }
                // **A wardrobe with no base layer in it still gets suggestions.** The rule
                // completes a fit; it must not delete one. Somebody who has kept three
                // hoodies and no t-shirt would otherwise open this row to nothing at all,
                // and an empty row explains itself as a bug — the same reason
                // `Pairing.isRefused` is deliberately not applied here. So the requirement
                // bites only when it can be satisfied.
                if !bases.isEmpty {
                    guard let base = accompaniment(to: chosen, from: bases, statement: statement)
                    else { continue }
                    items.append(base)
                }
            }

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

    /// Catalogue products for the slots the wardrobe cannot fill at all.
    ///
    /// **A gap-filler, deliberately, and not a general source of pieces.** The row is
    /// called "From your wardrobe" and its value is that it is *yours*; a version that
    /// mixed shop stock into every proposal would turn the one screen about what you own
    /// into a storefront, which is the criticism the Style tab already answered once by
    /// moving Discover below the reading of your own collection.
    ///
    /// What it fixes is the opposite case, where the row was worst exactly when it should
    /// have been best: four tops and no trousers produced *nothing at all*, when "here is a
    /// bottom that would work with these" is the most useful sentence the app can say. The
    /// wardrobe gaps are already computed and printed one section further down.
    ///
    /// Only ever from brands already followed — these are rows the poller has synced, so
    /// nothing here is fetched to build a suggestion — and only ones carrying a photograph
    /// and a colour. **The colour requirement is the point**: `visionColor` is written by
    /// `ImageTagger`, which by design runs over saves alone, so an unmeasured product
    /// scores neutral against everything and would be picked on recency. That is precisely
    /// the "randomly thrown together" failure the scoring exists to prevent, so a candidate
    /// that has not been looked at is not offered. `FitCandidates` is what arranges for a
    /// bounded few to have been.
    private static func gapPieces(
        from candidates: [BrandUpdate],
        missing bySlot: [GarmentSlot: [FitPiece]]
    ) -> [GarmentSlot: [FitPiece]] {
        guard !candidates.isEmpty else { return [:] }
        var filled: [GarmentSlot: [FitPiece]] = [:]
        for candidate in candidates {
            let slot = candidate.garmentSlot
            guard slot != .unknown, GarmentSlot.essential.contains(slot),
                  bySlot[slot]?.isEmpty != false,
                  !candidate.imageURLStrings.isEmpty,
                  candidate.visionColor != nil
            else { continue }
            filled[slot, default: []].append(FitPiece(update: candidate, save: nil))
        }
        // Newest first, matching how the wardrobe's own pieces are ordered, and capped so a
        // brand that published two hundred products in one sweep cannot own the whole slot.
        for slot in filled.keys {
            filled[slot] = Array(
                (filled[slot] ?? [])
                    .sorted { ($0.update.publishedAt ?? .distantPast) > ($1.update.publishedAt ?? .distantPast) }
                    .prefix(perSlotCandidates)
            )
        }
        return filled
    }

    /// How many unowned products may stand for one empty slot. Small on purpose: this is a
    /// suggestion about clothes you own, with a hole filled in, not a shop.
    private static let perSlotCandidates = 6

    /// The best of `options` to put with a fit already decided, or nil when the slot is
    /// empty or nothing in it works.
    ///
    /// Scored against **every** piece already in the fit and taking the worst of those
    /// scores, not the average: a jacket that goes with the trousers and fights the top is
    /// not a good jacket for this outfit, and averaging lets one strong agreement hide one
    /// real clash. An outright clash with any piece is refused outright, unless the wearer
    /// has named that pairing themselves — the same override the top-and-bottom rule allows,
    /// because an app that refuses the outfit its user described is arguing with them.
    ///
    /// Returning nil is a real answer and a common one. A three-piece fit that works beats a
    /// four-piece fit with a wrong shoe in it, and the slot was optional to begin with.
    private static func accompaniment(
        to chosen: [Garment],
        from options: [FitPiece],
        statement: StyleStatement
    ) -> FitPiece? {
        var best: (item: FitPiece, score: Double)?
        for option in options {
            let garment = option.update.garment
            var worst = Double.greatestFiniteMagnitude
            var refused = false
            for piece in chosen {
                let stated = statement.statedPairing(between: piece, and: garment)
                if !stated, ColorHarmony.isClash(piece.color, option.update.visionColor) {
                    refused = true
                    break
                }
                worst = min(worst, Pairing.score(piece, with: garment, statement: statement).score)
            }
            guard !refused, worst < .greatestFiniteMagnitude else { continue }
            // Ties broken on the id so the row does not reshuffle between renders — the
            // property the whole of `build` is written around, and the common case on a
            // wardrobe nothing has been measured in yet.
            if let current = best,
               current.score > worst || (current.score == worst && current.item.id <= option.id) {
                continue
            }
            best = (option, worst)
        }
        return best?.item
    }
}

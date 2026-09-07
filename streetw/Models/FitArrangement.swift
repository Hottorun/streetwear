// FitArrangement.swift
// Where the app puts a garment when it lays a fit out for you.
//
// Three screens produce an arrangement nobody dragged into place — `FitStudio`'s preview,
// the fit it writes, and a suggestion kept from the Style tab — and until this file they
// disagreed. The studio had a private table of spots, and `StyleView.keep` had **none at
// all**: it wrote a `Fit` with an empty `placements` array, so a suggestion you kept was
// stored as a set of garments with no positions, drew as an empty square on the wall, and
// rendered as one too. On screen that is a fit you asked for arriving blank.
//
// So the table lives here, once, and everything that arranges a fit by machine reads it.
// Dragging a piece afterwards is `FitCanvas`'s business and overwrites all of this, which is
// exactly the intended relationship: the app opens with an arrangement and the person has
// the last word on it.
//
// The layout is a **flat-lay**, not a body. Garments are photographed flat and cut out flat,
// and the moment two of them overlap it stops reading as a photograph of clothes and starts
// reading as a collage that failed. So the positions are chosen to sit clear of each other
// at their stored scales, head down and left to right:
//
//     ┌──────────────────────────────┐
//     │            [cap]             │
//     │  ┌──────┐        ┌────────┐  │
//     │  │ coat │        │  top   │  │
//     │  └──────┘        └────────┘  │
//     │        ┌────────┐    [tee]   │
//     │        │ bottom │            │
//     │ [shoe] └────────┘     [bag]  │
//     └──────────────────────────────┘

import Foundation
import StreetwCore

/// One place on the body, which is **not** the same thing as a `GarmentSlot`.
///
/// A fit can hold two tops — a hoodie with a tee under it — and every part of the app that
/// keyed an arrangement by slot could therefore hold only one of them. `FitStudio` picked
/// per slot into a `[GarmentSlot: String]`, so the base layer the engine had just been taught
/// to require had nowhere to go and the studio went on proposing a full-zip hoodie over bare
/// skin long after the suggestion row had stopped.
struct FitPosition: Hashable, Identifiable {
    var slot: GarmentSlot
    /// Which of the two top positions this is. Nil everywhere else, and nil for a wardrobe
    /// with only one kind of top in it — there is no reason to split a position that will
    /// never hold two things.
    var layer: GarmentLayer?

    var id: String { "\(slot.rawValue)/\(layer?.rawValue ?? "-")" }

    init(_ slot: GarmentSlot, _ layer: GarmentLayer? = nil) {
        self.slot = slot
        self.layer = layer
    }

    /// What the row is called on screen.
    ///
    /// "Layer" and "Top" rather than "Mid" and "Base": the second pair is the vocabulary of
    /// the classifier and the first is the vocabulary of getting dressed. Both sit under
    /// Outerwear in the list, so the three read down the body in the order they are worn.
    var label: String {
        guard slot == .top, let layer else { return slot.label }
        return layer == .mid ? "Layer" : "Top"
    }

    /// Head down, with a mid layer over the base it covers — the order `wornOver` uses, so
    /// the list and the canvas cannot disagree about which garment is on top.
    var order: Int { slot.stackOrder * 2 + (layer == .base ? 1 : 0) }
}

enum FitArrangement {
    /// A position's place on the canvas: centre as a fraction of it, and a scale in
    /// `FitPlacement` units where 1 is a bit under half the canvas.
    struct Spot {
        var x: Double
        var y: Double
        var scale: Double
    }

    /// Every spot is inset far enough that the piece's own frame stays inside the canvas —
    /// a piece is drawn `0.42 · scale` wide about its centre, and the canvas clips. The shoe
    /// sat at 0.86 once and lost its sole off the bottom edge of the render.
    private static let spots: [GarmentSlot: Spot] = [
        .headwear: Spot(x: 0.50, y: 0.13, scale: 0.55),
        .outerwear: Spot(x: 0.25, y: 0.41, scale: 1.15),
        .top: Spot(x: 0.68, y: 0.33, scale: 0.95),
        .bottom: Spot(x: 0.55, y: 0.68, scale: 1.10),
        .footwear: Spot(x: 0.22, y: 0.84, scale: 0.75),
        .accessory: Spot(x: 0.86, y: 0.86, scale: 0.52),
        .unknown: Spot(x: 0.50, y: 0.50, scale: 1.00)
    ]

    /// Where the base layer goes **when there is a mid layer over it**.
    ///
    /// Smaller and tucked under the top's right shoulder, because that is what it is: the
    /// thing worn underneath. When it is the only top in the fit it takes the ordinary top
    /// spot at full size instead — a lone tee drawn small in the corner would read as an
    /// afterthought rather than as the garment the outfit is built on.
    private static let tucked = Spot(x: 0.86, y: 0.55, scale: 0.52)

    static func spot(for position: FitPosition, layered: Bool) -> Spot {
        if layered, position.slot == .top, position.layer == .base { return tucked }
        return spots[position.slot] ?? spots[.unknown]!
    }

    /// Whether an arrangement holds both a mid layer and a base layer, which is the only
    /// thing that changes where a piece goes.
    static func isLayered(_ positions: [FitPosition]) -> Bool {
        positions.contains { $0.slot == .top && $0.layer == .mid }
            && positions.contains { $0.slot == .top && $0.layer == .base }
    }

    /// The canvas for a whole fit.
    ///
    /// `z` is spaced by ten so a later drag can slide a piece between two of them without
    /// renumbering — the same reason `FitPlacement.z` is sparse in the first place — and
    /// counts *down* the body, so a coat is drawn over the shirt it covers.
    static func placements(for pieces: [(position: FitPosition, itemID: UUID)]) -> [FitPlacement] {
        let layered = isLayered(pieces.map(\.position))
        return pieces.map { piece in
            let spot = spot(for: piece.position, layered: layered)
            return FitPlacement(
                itemID: piece.itemID,
                x: spot.x,
                y: spot.y,
                scale: spot.scale,
                rotation: 0,
                z: (12 - piece.position.order) * 10
            )
        }
    }

    /// The position a garment belongs in.
    ///
    /// Only tops are ever split, and only when they need to be: a wardrobe that has never
    /// been read for layers should not grow a second top row for the sake of it.
    static func position(for garment: Garment, splittingTops: Bool) -> FitPosition {
        guard splittingTops, garment.slot == .top, !garment.isSet else {
            return FitPosition(garment.slot)
        }
        return FitPosition(.top, garment.layer)
    }
}

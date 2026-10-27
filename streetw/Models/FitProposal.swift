// FitProposal.swift
// An outfit built around one garment: what the wardrobe offers for every other position on
// the body, ranked against it, and the fit it opens with.
//
// This was the brain of `FitStudio`, a second fit editor with its own preview, its own save
// and its own idea of what a fit is. A fit could be started from three tabs and two detail
// pages and landed in one of the two editors depending on where the tap came from — the
// studio from "Wear it with" and from a Discover card, the canvas from everywhere else — and
// "save and arrange it by hand" was the studio admitting that the canvas was the real editor.
// So the studio is gone and what it knew is here: `FitCanvas` opens pre-filled with
// `opening`, and the shortlist for each position is a shelf in its tray, one tap from being
// swapped in. One editor, whatever opened it.
//
// The rules it carries over are the studio's, unchanged, because a second copy of any of
// them would drift from the "Wear it with" row this is opened from:
//
// - **The judgement is `Pairing`'s**, in the shared core, exactly as `GoesWith` and
//   `FitSuggestions` use it. Nothing here adds vocabulary of its own.
// - **Ranked once, against the subject.** Built when the canvas opens and never again, so
//   swapping a piece never re-sorts a shelf under somebody's thumb — the property `FeedView`
//   learned the hard way. What a swap changes is the picture, which is what was asked for.
// - **The opening arrangement scores a candidate on the worst of its verdicts against what
//   is already chosen**, never the average, as `FitSuggestions.accompaniment` does: a jacket
//   that goes with the trousers and fights the shirt is not a good jacket for this outfit.
//
// Everything here is local. No request is made, and nothing about the wardrobe leaves the
// phone.

import Foundation
import StreetwCore
import SwiftData
import UIKit

/// The garment a fit is being built around, which is **not always something in the store**.
///
/// Built around a product page, it has a `BrandUpdate`. Built around a discovery card, it does
/// not, and must not be given one on the way in: the deck's whole no-pollution rule is that a
/// card from an unfollowed brand writes no row until somebody keeps it (`FeedView` queries
/// `!isSeen`, so a stored discovery page would empty thousands of products into the unread
/// feed). So the subject is an enum, and the row is minted at exactly one moment — when the fit
/// is saved, which is the moment the garment has been chosen.
enum FitSubject: Identifiable {
    /// Something the store already holds: a save, or a row from a followed brand's catalogue.
    case product(BrandUpdate)
    /// A card from the discovery feed, with whatever `DiscoveryAnalysis` has measured of its
    /// photograph. Passed in rather than looked up, because that measurement lives on the
    /// feed's analysis object and the canvas is presented from there.
    case discovery(
        DiscoverCard,
        sticker: UIImage?,
        reading: VisualReading.Reading?,
        packshot: URL?
    )
    /// A garment of your own already in the collection — a save with no product behind it,
    /// which `product` cannot carry.
    case kept(SavedItem)
    /// A garment just photographed and read, and not kept: "does it go with my wardrobe" is
    /// asked in a shop about something not bought. It becomes a save only if the fit does.
    case scan(ScannedGarment)

    var id: String {
        switch self {
        case .product(let update): return update.externalID
        case .discovery(let card, _, _, _): return card.productExternalID
        case .kept(let save): return save.pairingID
        case .scan(let scanned): return scanned.pairingID
        }
    }

    /// The save this already is, when it is one — in which case it goes onto the canvas as
    /// itself and nothing needs minting.
    var existingSave: SavedItem? {
        switch self {
        case .product(let update): return update.saves.first
        case .discovery, .scan: return nil
        case .kept(let save): return save
        }
    }

    /// The subject in the terms `Pairing` reasons about.
    ///
    /// For a discovery card the measured colour is folded in where there is one. It is often
    /// nil — analysis runs only over the cards at the viewport, and Vision does not run in the
    /// Simulator at all — and `Pairing` scores a nil colour as **neutral rather than badly**,
    /// which is what lets the fit rank before a single photograph has been decoded.
    var garment: Garment {
        switch self {
        case .product(let update):
            return update.garment
        case .discovery(let card, _, let reading, _):
            return Garment(
                id: card.productExternalID,
                title: card.title,
                productType: card.productType,
                tags: card.tags,
                color: reading?.color,
                secondaryColor: reading?.secondaryColor,
                busyness: reading?.busyness ?? 0,
                textCoverage: reading?.textCoverage ?? 0
            )
        case .kept(let save):
            return save.garment ?? Garment(id: save.pairingID, title: save.displayTitle)
        case .scan(let scanned):
            return scanned.garment
        }
    }

    /// The save this stands for, creating the row and the save if neither exists yet.
    ///
    /// Called **only when the fit is saved**, never on the way in. For a discovery card this
    /// is `DiscoverSave.save`, the one place that knows how to write a card from an unfollowed
    /// brand — keyed `shopify:<id>` with `productExternalID` beside it, and already marked
    /// seen, so a later follow merges rather than minting a second card.
    ///
    /// Filed as inspiration, not wardrobe: keeping the fit is the moment somebody decided they
    /// want the piece, not proof that they bought it. See `SaveType`.
    func materialise(in context: ModelContext) -> SavedItem? {
        switch self {
        case .product(let update):
            if let existing = update.saves.first { return existing }
            let created = SavedItem(update: update, type: .inspiration)
            context.insert(created)
            return created
        case .discovery(let card, _, _, let packshot):
            guard let update = DiscoverSave.save(card, in: context) else { return nil }
            // **The packshot the deck already found goes onto the row.** The render is drawn
            // from the stored row, not from the sticker the canvas showed, and its fallback is
            // the packshot — so without this a model-first gallery put a person in boots into
            // the saved picture of the outfit, the failure `ProductShot` exists to stop. The
            // analysis pass re-picks it later on its own terms; this is only a first answer.
            if update.packshotURLString == nil, let packshot {
                update.packshotURLString = packshot.absoluteString
            }
            return update.saves.first
        case .kept(let save):
            return save.isGone ? nil : save
        case .scan(let scanned):
            // Inspiration, for the reason above: a fit kept around something seen in a shop
            // says it is wanted, not that it was bought.
            return scanned.save(as: .inspiration, in: context)
        }
    }
}

/// What the wardrobe offers around one garment, and the fit it opens with.
@MainActor
struct FitProposal {
    /// One candidate for one position on the body.
    struct Option: Identifiable {
        var save: SavedItem
        /// The save in `Pairing`'s terms, built once — and read off the save rather than its
        /// product, because a garment of your own has none.
        var garment: Garment
        var position: FitPosition
        /// The line `Pairing` gave for this against the subject. Nil is a real state — the
        /// verdict has nothing to say until a photograph has been measured — and prints
        /// nothing rather than filler, the contract `PairingTile` holds.
        var reason: String?
        var score: Double

        var id: UUID { save.id }
    }

    /// One position and its shortlist, best first.
    struct Shelf: Identifiable {
        var position: FitPosition
        var options: [Option]
        var id: String { position.id }
    }

    let subject: FitSubject
    /// Where the subject sits. Never offered an alternative: it is what was on screen when the
    /// fit was asked for, and a proposal that swaps out its own subject is just the tray.
    let subjectPosition: FitPosition
    /// Every other position the wardrobe can fill, head down.
    let shelves: [Shelf]
    /// What the canvas opens with, besides the subject.
    let opening: [Option]

    var isEmpty: Bool { shelves.isEmpty }

    /// Past this a shelf stops being a choice and starts being the collection. The whole
    /// wardrobe is one chip away in the same tray; this is the shortlist.
    private static let perPosition = 12

    /// - Parameters:
    ///   - anchor: the wardrobe piece the screen that asked was already naming, by
    ///     `pairingID`. **The two must agree.** A discovery card says "Goes with your Kith Mesh
    ///     Donovan Jersey", and a fit that then opened on a different jacket would read as the
    ///     app contradicting itself one tap apart. So the named piece is pinned into its own
    ///     position first and the rest is built around it. Nil from `GoesWith`, which names
    ///     nothing in particular.
    ///   - saves: the collection. Narrowed here to `TasteScope.pairingPool` — the pool `GoesWith`
    ///     reads, so the row and the fit it opens cannot disagree about what you have.
    ///   - boards: the boards with a taste setting, for that pool.
    init(
        around subject: FitSubject,
        anchor: String?,
        saves: [SavedItem],
        boards: [Board],
        statement: StyleStatement
    ) {
        self.subject = subject
        let centre = subject.garment
        let centrePosition = FitArrangement.position(for: centre, splittingTops: true)
        subjectPosition = centrePosition

        // A save with no photograph is excluded outright: there is nothing to draw and nothing
        // to lift a cutout from — the rule the tray and `FitSuggestions` already apply.
        let kept = saves.filter(\.hasPhotograph)
        let wardrobe = TasteScope(boards: boards, saves: saves).pairingPool(kept)

        var byPosition: [FitPosition: [Option]] = [:]
        // Built once and keyed by save: `BrandUpdate.garment` runs two classifiers and builds a
        // vocabulary set, and the opening arrangement asks about each candidate repeatedly.
        var garments: [UUID: Garment] = [:]
        for save in wardrobe {
            guard let garment = save.garment,
                  garment.slot != .unknown, garment.id != centre.id
            else { continue }

            // **Excluded by position, not by slot.** Excluding the whole `.top` slot meant a fit
            // built around a hoodie could never be given a tee to wear under it — the one thing
            // a hoodie needs — because the tee is a top and so is the hoodie.
            let position = FitArrangement.position(for: garment, splittingTops: true)
            guard position != centrePosition else { continue }

            // A layered pair is the one same-slot combination that is an outfit rather than a
            // mistake, so `Pairing` — which refuses same-slot pairs by design — is not asked
            // about it. Everything else goes through the gate untouched.
            let verdict = Outfit.isLayeredPair(centre, garment)
                ? Pairing.Verdict(score: 0.6, reason: "Under it")
                : Pairing.score(centre, with: garment, statement: statement)
            guard !verdict.isRefused else { continue }

            garments[save.id] = garment
            byPosition[position, default: []].append(
                Option(save: save, garment: garment, position: position, reason: verdict.reason, score: verdict.score)
            )
        }

        // Ties break on the id, so the shortlist is the same one on every open and across
        // relaunches. An unmeasured wardrobe scores everything identically, which makes this
        // the common case rather than the edge.
        let shelves = byPosition.keys
            .sorted { $0.order < $1.order }
            .map { position in
                Shelf(
                    position: position,
                    options: Array(
                        (byPosition[position] ?? [])
                            .sorted { $0.score == $1.score ? $0.id.uuidString < $1.id.uuidString : $0.score > $1.score }
                            .prefix(Self.perPosition)
                    )
                )
            }
        self.shelves = shelves
        opening = Self.open(
            around: centre,
            anchor: anchor,
            shelves: shelves,
            garments: garments,
            statement: statement
        )
    }

    /// A few whole outfits around the subject rather than one — what the scan's "does it go
    /// with my wardrobe" shows, where the question is asked in a shop and two or three answers
    /// say more than one.
    ///
    /// Each is the opening arrangement **pinned to a different piece** for the position that
    /// decides an outfit most — the bottom, or the top when the subject is the bottom — taken
    /// best first, so every answer is one `open` would give and the canvas opened on it with the
    /// same anchor lays out exactly the fit that was shown. Judged whole by `Outfit`, which
    /// refuses what it would refuse anywhere; deterministic, like everything that proposes.
    func outfits(limit: Int = 3, statement: StyleStatement) -> [(anchor: String, pieces: [Option], reason: String?)] {
        let centre = subject.garment
        let deciding: [GarmentSlot] = subjectPosition.slot == .bottom ? [.top] : [.bottom, .top]
        let anchors = shelves
            .filter { deciding.contains($0.position.slot) }
            .flatMap(\.options)
            .sorted { $0.score == $1.score ? $0.id.uuidString < $1.id.uuidString : $0.score > $1.score }

        var seen: Set<Set<UUID>> = []
        var found: [(anchor: String, pieces: [Option], reason: String?)] = []
        for anchor in anchors where found.count < limit {
            let pieces = Self.open(
                around: centre,
                anchor: anchor.save.pairingID,
                shelves: shelves,
                garments: [:],
                statement: statement
            )
            guard seen.insert(Set(pieces.map(\.id))).inserted else { continue }
            let verdict = Outfit.score([centre] + pieces.map(\.garment), statement: statement)
            guard !verdict.isRefused else { continue }
            found.append((anchor.save.pairingID, pieces, verdict.reason))
        }
        return found
    }

    /// The opening proposal: the best thing the wardrobe has for each essential position,
    /// chosen against everything already in the fit rather than against the subject alone.
    ///
    /// Only the essential positions are filled. Headwear and accessories are on their shelves —
    /// putting a cap on is exactly what the tray is for — but proposing them unasked turns a fit
    /// into a costume.
    ///
    /// **Anything that needs a layer under it gets one**, the rule `FitSuggestions.build` has:
    /// a full-zip hoodie is not proposed over bare skin. It runs last, so the tee is chosen
    /// against the finished outfit rather than deciding it.
    private static func open(
        around centre: Garment,
        anchor: String?,
        shelves: [Shelf],
        garments: [UUID: Garment],
        statement: StyleStatement
    ) -> [Option] {
        func garment(_ option: Option) -> Garment { garments[option.id] ?? option.garment }

        var chosen: [Garment] = [centre]
        var result: [FitPosition: Option] = [:]

        // The piece the card already named goes in first — see `anchor`. Looked up rather than
        // trusted: a wardrobe changes between the card being drawn and the canvas opening, and a
        // named garment that no longer qualifies quietly falls back to the ordinary arrangement.
        // Matched on `pairingID`, which is what the card was naming.
        if let anchor,
           let pinned = shelves.lazy.flatMap(\.options).first(where: { $0.save.pairingID == anchor }) {
            result[pinned.position] = pinned
            chosen.append(garment(pinned))
        }

        // One garment per *slot*, so the two top positions are filled by the better of the two
        // rather than both — a fit opens as an outfit, and the layering rule below is what adds
        // a second top when the first needs one.
        for slot in GarmentSlot.essential {
            let candidates = shelves.filter { $0.position.slot == slot }
            guard !candidates.isEmpty,
                  !candidates.contains(where: { result[$0.position] != nil }),
                  let best = best(of: candidates.flatMap(\.options), against: chosen, garment: garment, statement: statement)
            else { continue }
            result[best.position] = best
            chosen.append(garment(best))
        }

        // Nothing goes out with nothing under it — but only when the wardrobe can answer. The
        // rule completes a fit and must not empty one, the line `FitSuggestions` draws.
        let base = FitPosition(.top, .base)
        if chosen.contains(where: \.needsBaseLayer),
           result[base] == nil,
           let options = shelves.first(where: { $0.position == base })?.options,
           let under = best(of: options, against: chosen, garment: garment, statement: statement) {
            result[base] = under
        }

        return result.values.sorted { $0.position.order < $1.position.order }
    }

    private static func best(
        of options: [Option],
        against chosen: [Garment],
        garment: (Option) -> Garment,
        statement: StyleStatement
    ) -> Option? {
        var best: (option: Option, score: Double)?
        for option in options {
            let candidate = garment(option)
            var worst = Double.greatestFiniteMagnitude
            var refused = false
            for piece in chosen {
                // A stated pairing carries a clash the wheel would refuse — the one input here
                // that was not inferred from something. See `StyleStatement`.
                let stated = statement.statedPairing(between: piece, and: candidate)
                if !stated, ColorHarmony.isClash(piece.color, candidate.color) {
                    refused = true
                    break
                }
                // A layered pair skips the gate but is still *scored*, on the one axis that
                // applies to two tops. Skipping it outright left `worst` at its sentinel, which
                // the guard below reads as "nothing compared, discard" — so a hoodie with a
                // wardrobe of tees picked nothing at all and the fit opened with one piece.
                if Outfit.isLayeredPair(piece, candidate) {
                    worst = min(worst, ColorHarmony.score(piece.color, candidate.color).score)
                    continue
                }
                let verdict = Pairing.score(piece, with: candidate, statement: statement)
                if verdict.isRefused {
                    refused = true
                    break
                }
                worst = min(worst, verdict.score)
            }
            guard !refused, worst < .greatestFiniteMagnitude else { continue }
            if let current = best,
               current.score > worst
                || (current.score == worst && current.option.id.uuidString <= option.id.uuidString) {
                continue
            }
            best = (option, worst)
        }
        return best?.option
    }
}

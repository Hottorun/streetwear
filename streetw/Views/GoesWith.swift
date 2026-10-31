// GoesWith.swift
// "Wear it with" — the things you already own that would go with the thing on screen.
//
// A product page could say what this garment *is* and what else is like it (`SimilarItems`),
// and both of those are answers a catalogue could give. The one thing only an archive can
// answer is what to put it with, because only the archive knows what you have — and the
// data for it was all already here: `ImageTagger` measures a dominant colour on every save,
// `GarmentClassifier` places every item on the body, and `ColorHarmony` has been ranking
// pairs for the fit row this whole time. Nothing on a product page read any of it.
//
// It reads both ways round on purpose. On something you have *not* kept it is an argument
// for keeping it — "this works with three things you own" is the most useful sentence a
// product page can print. On something you have, it is the start of a fit.
//
// The judgement lives in `Pairing`, in the shared core, for the same reason `ColorHarmony`
// does: `FitSuggestions` and this screen must not disagree about the same two garments. All
// of it is local — the wardrobe never leaves the phone, and no request is made to draw this.

import StreetwCore
import SwiftData
import SwiftUI

struct GoesWith: View {
    @Environment(StyleStatementStore.self) private var statement: StyleStatementStore
    @Query(sort: \SavedItem.savedAt, order: .reverse) private var saves: [SavedItem]
    /// Only the boards with a taste setting — see `Board.shapingTaste`. Usually none.
    @Query(filter: Board.shapingTaste) private var tasteBoards: [Board]

    /// What the row is about: a product, or a garment of your own on its save's page.
    let subject: FitSubject

    init(subject: BrandUpdate) {
        self.subject = .product(subject)
    }

    /// A garment of your own, which has no product to be the subject.
    init(save: SavedItem) {
        self.subject = .kept(save)
    }

    /// Four. A row of suggestions is a prompt, not a lookbook, and past four the tail is
    /// made of the pairings the ranking liked least.
    private static let limit = 4

    @State private var isBuilding = false

    /// The wardrobe, or everything kept if nothing has been filed as owned.
    ///
    /// Same fallback the fit row uses and for the same reason: the honest question is "what
    /// do you own", and most people never split the two axes — so insisting on
    /// `SaveType.wardrobe` would leave the row permanently empty for almost everybody.
    ///
    /// A save with no photograph is excluded outright. This row is looked at before it is
    /// read, and a tile with nothing in it is not a suggestion — the same rule
    /// `FitSuggestions` and the fit tray already apply.
    ///
    /// Through `TasteScope.pairingPool`: a wardrobe piece left out of the taste reading is
    /// still owned and still offered here, while the everything-kept fallback leaves out what
    /// somebody said is not theirs — it is standing in for "you", and that is the one save
    /// known not to be.
    private var wardrobe: [SavedItem] {
        let kept = saves.filter(\.hasPhotograph)
        return TasteScope(boards: tasteBoards, saves: saves).pairingPool(kept)
    }

    /// Saves rather than products, so a garment of your own is offered beside the catalogue's.
    private var pairs: [(save: SavedItem, reason: String?)] {
        let scored = wardrobe.compactMap { save in save.garment.map { (save: save, garment: $0) } }
        let byID = Dictionary(
            scored.map { ($0.garment.id, $0.save) },
            uniquingKeysWith: { first, _ in first }
        )
        let ranked = Pairing.best(
            for: subject.garment,
            from: scored.map(\.garment),
            limit: Self.limit,
            // What somebody has said outranks what the colour wheel worked out — see
            // `StyleStatement`. Empty for anybody who has written nothing, which scores
            // exactly as this did before.
            statement: statement.statement
        )
        return ranked.compactMap { entry in
            byID[entry.garment.id].map { ($0, entry.verdict.reason) }
        }
    }

    var body: some View {
        let found = pairs
        if !found.isEmpty {
            VStack(alignment: .leading, spacing: 14) {
                Rule().padding(.horizontal, 20)

                // **The header opens out into the whole fit**, and that is the answer to the
                // question this row raises and cannot itself answer. Four tiles side by side
                // are four separate suggestions — two of them are often tops, and only one of
                // those can be worn — so the row says what goes with the garment and leaves
                // *what the outfit is* to be assembled in somebody's head. The canvas opens
                // with every position on the body filled (`FitProposal`), the alternatives
                // for each one on a shelf in its tray, and the result can be kept.
                //
                // A whole-row button rather than a small control beside the title: the title
                // is the affordance people reach for, and a section that expands has to look
                // like one from across the page.
                Button { isBuilding = true } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        VStack(alignment: .leading, spacing: 5) {
                            Text("Wear it with")
                                .font(.editorial(19))
                                .foregroundStyle(Color.ink)
                            NoteLine(text: "Tap to build the whole fit.")
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Color.muted)
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.borderless)
                .padding(.horizontal, 20)

                ScrollView(.horizontal) {
                    LazyHStack(alignment: .top, spacing: 14) {
                        ForEach(found, id: \.save.id) { pair in
                            PairingTile(save: pair.save, reason: pair.reason)
                        }
                    }
                    .padding(.horizontal, 20)
                }
                .scrollIndicators(.hidden)
            }
            .padding(.top, 6)
            .padding(.bottom, 28)
            .sheet(isPresented: $isBuilding) { FitCanvas(fit: nil, starting: .around(subject, anchor: nil)) }
        }
    }
}

/// One thing from the wardrobe, and **why**.
///
/// The reason is the line the ranking actually used, not a restatement of the headline —
/// same contract as `SuggestedBrandCard`'s "LIKE YOUR …". A suggestion nobody can account
/// for is indistinguishable from a shuffle, and this row would be the third place in the
/// app to have that problem if it printed nothing. Nil is a real state and prints nothing
/// rather than filler: on a wardrobe `ImageTagger` has not reached yet — or in the
/// Simulator, where Vision does not run at all — there is genuinely nothing to say.
private struct PairingTile: View {
    let save: SavedItem
    let reason: String?

    var body: some View {
        tile.productLink(ifAny: save.update)
    }

    private var tile: some View {
        VStack(alignment: .leading, spacing: 7) {
            UpdateImage(
                // A garment of your own is drawn from your photograph; it has no lead shot.
                url: save.update?.primaryImageURL ?? save.coverURL,
                kind: save.update?.kind ?? .product,
                aspect: 1,
                drawnWidth: 200,
                // The fixed sweep, as everywhere the collection is drawn: these are the
                // photographs you kept, and a transparent PNG must not vanish into a dark
                // backdrop here any more than it does on the wall.
                backdrop: .sweep,
                mark: save.update?.brand?.name
            )
            .frame(width: 132)

            Text(save.displayTitle)
                .font(.editorial(13))
                .foregroundStyle(Color.ink)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .frame(width: 132, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)

            if let reason {
                NoteLine(text: reason, size: 13)
                    .frame(width: 132, alignment: .leading)
            }
        }
        .contentShape(.rect)
    }
}

extension View {
    /// The product page where there is a product, and nothing where there is none — a garment
    /// of your own has no page in any shop to open.
    @ViewBuilder
    func productLink(ifAny update: BrandUpdate?) -> some View {
        if let update { productLink(update) } else { self }
    }
}

extension BrandUpdate {
    /// The stable key `Pairing` matches a scored garment back to its row on.
    ///
    /// `externalID`, not the persistent id: it is the same string dedupe already keys on,
    /// it is identical on the phone and the server, and — unlike a `PersistentIdentifier` —
    /// it is a `String`, which is what `Garment` carries so the type stays free of
    /// SwiftData.
    var pairingID: String { externalID }

    /// This product in the terms `Pairing` reasons about.
    ///
    /// The photograph's measured colour where there is one; `ImageTagger` only runs over
    /// saved items, so a product nobody has kept reaches this with nil and is scored
    /// neutral rather than badly. That is the correct behaviour and not a gap — the
    /// subject of the row is usually exactly such a product.
    var garment: Garment {
        Garment(
            id: pairingID,
            title: title,
            productType: productType,
            tags: tags,
            visionCategories: visionCategories,
            color: visionColor,
            secondaryColor: visionSecondaryColor,
            busyness: visionBusyness,
            textCoverage: visionTextCoverage,
            silhouette: visionSilhouette
        )
    }
}

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
    @Query(sort: \SavedItem.savedAt, order: .reverse) private var saves: [SavedItem]

    let subject: BrandUpdate

    /// Four. A row of suggestions is a prompt, not a lookbook, and past four the tail is
    /// made of the pairings the ranking liked least.
    private static let limit = 4

    /// The wardrobe, or everything kept if nothing has been filed as owned.
    ///
    /// Same fallback `StyleView` uses and for the same reason: the honest question is "what
    /// do you own", and most people never split the two axes — so insisting on
    /// `SaveType.wardrobe` would leave the row permanently empty for almost everybody.
    ///
    /// A save with no photograph is excluded outright. This row is looked at before it is
    /// read, and a tile with nothing in it is not a suggestion — the same rule
    /// `FitSuggestions` and the fit tray already apply.
    private var wardrobe: [SavedItem] {
        let kept = saves.filter { $0.update?.imageURLStrings.isEmpty == false }
        let owned = kept.filter { $0.type == .wardrobe }
        return owned.isEmpty ? kept : owned
    }

    private var pairs: [(update: BrandUpdate, reason: String?)] {
        let updates = wardrobe.compactMap(\.update)
        let byID = Dictionary(
            updates.map { ($0.pairingID, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let ranked = Pairing.best(
            for: subject.garment,
            from: updates.map(\.garment),
            limit: Self.limit
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

                VStack(alignment: .leading, spacing: 5) {
                    Text("Wear it with")
                        .font(.editorial(19))
                        .foregroundStyle(Color.ink)
                    DataLabel(text: "FROM WHAT YOU'VE KEPT")
                }
                .padding(.horizontal, 20)

                ScrollView(.horizontal) {
                    LazyHStack(alignment: .top, spacing: 14) {
                        ForEach(found, id: \.update.id) { pair in
                            PairingTile(update: pair.update, reason: pair.reason)
                        }
                    }
                    .padding(.horizontal, 20)
                }
                .scrollIndicators(.hidden)
            }
            .padding(.top, 6)
            .padding(.bottom, 28)
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
    let update: BrandUpdate
    let reason: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            UpdateImage(
                url: update.primaryImageURL,
                kind: update.kind,
                aspect: 1,
                drawnWidth: 200,
                // The fixed sweep, as everywhere the collection is drawn: these are the
                // photographs you kept, and a transparent PNG must not vanish into a dark
                // backdrop here any more than it does on the wall.
                backdrop: .sweep,
                mark: update.brand?.name
            )
            .frame(width: 132)

            Text(update.title)
                .font(.editorial(13))
                .foregroundStyle(Color.ink)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .frame(width: 132, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)

            if let reason {
                DataLabel(text: reason.uppercased(), size: 10)
                    .frame(width: 132, alignment: .leading)
            }
        }
        .contentShape(.rect)
        .productLink(update)
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
            textCoverage: visionTextCoverage
        )
    }
}

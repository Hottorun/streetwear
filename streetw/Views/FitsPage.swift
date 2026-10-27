// FitsPage.swift
// Saved › Fits: the outfits you kept, the ones the wardrobe could make, and the one place a
// new fit is started by hand.
//
// These were the first two rows of the Style tab, which is gone. They belong in the
// collection because they are made of it — a fit is a list of saved things — and beside
// Inspiration and Wardrobe they read as what they are: a third way of looking at what you
// kept. Every other way into a fit (a selection on the wall, "Wear it with" on a product,
// a Discover card's pairing) lands in the same editor this opens, `FitCanvas`.

import StreetwCore
import SwiftData
import SwiftUI

struct FitsPage: View {
    @Environment(\.modelContext) private var context
    @Environment(StyleStatementStore.self) private var statement: StyleStatementStore

    /// The collection and its boards, as `SavedView` already holds them — passed rather than
    /// queried again, so the page adds no subscription the wall did not already have.
    let saves: [SavedItem]
    let boards: [Board]
    /// The collection's search field, which on this page searches fits.
    let query: String

    @Query(sort: \Fit.createdAt, order: .reverse) private var fits: [Fit]

    @State private var memo = ReadingMemo()
    /// Catalogue products standing in for slots the wardrobe cannot fill.
    ///
    /// Held in `@State` from a bounded fetch rather than as a `@Query`, which over
    /// `BrandUpdate` would subscribe this page to every product ever synced and rebuild it
    /// on every poll. See `FitCandidates`.
    @State private var fitCandidates: [BrandUpdate] = []

    @State private var isComposing = false
    @State private var editing: Fit?
    @State private var trying: SuggestedFit?
    /// The fit a delete has been asked about. Held here rather than on the card: the card
    /// lives in a lazy grid and is routinely recycled, so a dialog owned by one would be torn
    /// down underneath itself — the same reason `SaveConfirmation` is owned by the app.
    @State private var fitPendingDeletion: Fit?

    var body: some View {
        let reading = memo.reading(
            for: saves,
            candidates: fitCandidates,
            statement: statement.statement,
            kept: fits,
            taste: TasteScope(boards: boards, saves: saves)
        )
        let searching = !query.trimmingCharacters(in: .whitespaces).isEmpty
        let shown = searching ? fits.filter { matches($0, query) } : fits

        return GeometryReader { geometry in
            // Two columns, sized from the page rather than fixed, so a fit reads as a picture
            // rather than as a thumbnail in a carousel — the row this replaced scrolled
            // sideways a card and a half at a time, the gesture that cannot be skimmed.
            let card = ((geometry.size.width - 40 - 14) / 2).rounded(.down)
            ScrollView {
                VStack(alignment: .leading, spacing: 34) {
                    if !searching { newFit }

                    if !shown.isEmpty {
                        keptFits(shown, card: card)
                    } else if searching {
                        Text("NO FIT MATCHES \"\(query.uppercased())\"")
                            .font(.data(12))
                            .tracking(0.4)
                            .foregroundStyle(Color.muted)
                            .padding(.horizontal, 20)
                    }

                    // Hidden while searching: the field matches fits somebody kept, and a row
                    // that ignores it reads as a search that failed to apply.
                    if !searching {
                        if !reading.suggested.isEmpty {
                            suggestedFits(reading.suggested, mood: reading.mood, card: card)
                        } else if fits.isEmpty {
                            nothingYet(gaps: reading.gaps)
                        }
                    }
                }
                .padding(.top, 8)
                .padding(.bottom, 32)
            }
            .scrollIndicators(.hidden)
        }
        .sheet(isPresented: $isComposing) { FitCanvas(fit: nil) }
        .sheet(item: $editing) { FitCanvas(fit: $0) }
        // Trying a proposal opens it on the canvas, kept by Save like any other new fit.
        // Tapping a card used to keep it on the spot — a fit written before anybody had seen
        // it arranged, with any garment it borrowed from the catalogue saved in the same tap.
        .sheet(item: $trying) { FitCanvas(fit: nil, starting: .suggestion($0)) }
        // Filling the wardrobe's empty slots from the catalogue. Keyed on the gaps themselves,
        // so it runs once for a given shape of wardrobe and not at all for the common one where
        // nothing is missing.
        .task(id: reading.gaps) {
            fitCandidates = await FitCandidates.pool(for: reading.gaps, in: context)
        }
        // Screenshot affordance: `-demoSheet fit` opens the newest kept fit at launch.
        .task {
            if UserDefaults.standard.string(forKey: "demoSheet") == "fit" { editing = fits.first }
        }
        .confirmationDialog(
            "Delete this fit?",
            isPresented: Binding(
                get: { fitPendingDeletion != nil },
                set: { if !$0 { fitPendingDeletion = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                guard let fit = fitPendingDeletion, !fit.isGone else { return }
                if let render = fit.renderFile { FitRender.remove(render) }
                context.delete(fit)
                try? context.save()
                fitPendingDeletion = nil
            }
            Button("Keep", role: .cancel) {}
        } message: {
            // True, and the reassurance somebody hesitating actually needs: `Fit.items`
            // cascades in neither direction.
            Text("The clothes in it stay in your collection.")
        }
    }

    // MARK: - Sections

    /// The one place a fit is started from nothing. Everywhere else a fit begins *from*
    /// something — a selection, a garment, a proposal — and this is for when it begins from an
    /// idea.
    private var newFit: some View {
        Button { isComposing = true } label: {
            HStack(spacing: 8) {
                Image(systemName: "plus")
                    .font(.system(size: 12, weight: .semibold))
                Text("NEW FIT")
                    .font(.data(11, .semibold))
                    .tracking(0.8)
                Spacer(minLength: 0)
                DataLabel(text: "ARRANGE YOUR OWN", size: 9)
            }
            .foregroundStyle(Color.ink)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .overlay(Rectangle().stroke(Color.hairline, lineWidth: 1))
            .contentShape(.rect)
        }
        .buttonStyle(.borderless)
        // A fit is made of things you kept; with nothing kept the canvas would open onto an
        // empty tray.
        .disabled(saves.isEmpty)
        .padding(.horizontal, 20)
    }

    private func keptFits(_ shown: [Fit], card: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            header("Your fits", "\(shown.count) \(shown.count == 1 ? "OUTFIT" : "OUTFITS")")

            LazyVGrid(columns: columns(card), alignment: .leading, spacing: 22) {
                ForEach(shown) { fit in
                    Button { editing = fit } label: {
                        FitCard(fit: fit, width: card)
                    }
                    .buttonStyle(.plain)
                    .contextMenu { menu(for: fit) }
                }
            }
            .padding(.horizontal, 20)
        }
    }

    /// - Parameter mood: the board the row is leaning towards, said in its header — a row that
    ///   has started favouring one board's clothes without saying so looks like it has stopped
    ///   seeing the rest of the wardrobe.
    private func suggestedFits(_ suggested: [SuggestedFit], mood: String?, card: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            header(
                "From your wardrobe",
                mood.map { "LEANING TOWARD \($0.uppercased()) · TAP ONE TO TRY IT" } ?? "TAP ONE TO TRY IT"
            )

            LazyVGrid(columns: columns(card), alignment: .leading, spacing: 22) {
                ForEach(suggested) { fit in
                    Button { trying = fit } label: {
                        SuggestedFitCard(
                            items: fit.ordered,
                            // What the app saw, when it saw something. The slot list
                            // ("Top · Bottom · Footwear") is a description of the schema and
                            // says nothing a glance at the card doesn't.
                            title: fit.reason ?? fit.ordered.map(\.slot.label).joined(separator: " · "),
                            width: card
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 20)
        }
    }

    /// No fits and nothing to propose — and **why**, when the wardrobe can say.
    ///
    /// "What's missing" used to be a section of its own on the Style tab, and its best use was
    /// exactly this: explaining a suggestion row that was empty for no visible reason. A row
    /// needs a top and a bottom, so somebody with six tops and nothing to wear with them is told
    /// so rather than shown nothing.
    private func nothingYet(gaps: Set<GarmentSlot>) -> some View {
        let missing = gaps.intersection([.top, .bottom]).sorted { $0.stackOrder < $1.stackOrder }
        let detail: String
        if saves.isEmpty {
            detail = "SAVE A FEW THINGS AND THE OUTFITS THEY MAKE START HERE"
        } else if !missing.isEmpty {
            let names = missing.map { $0.label.lowercased() }.joined(separator: " or ")
            detail = "A FIT NEEDS A TOP AND A BOTTOM — NOTHING YOU'VE SAVED READS AS \(names.uppercased()) YET"
        } else {
            detail = "NOTHING YOU'VE SAVED GOES TOGETHER YET — OR START ONE ABOVE"
        }
        return VStack(alignment: .leading, spacing: 8) {
            Text("No fits yet")
                .font(.editorial(22))
                .foregroundStyle(Color.ink)
            DataLabel(text: detail)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 20)
    }

    // MARK: - Pieces

    @ViewBuilder
    private func menu(for fit: Fit) -> some View {
        // Filing without opening the editor. A fit is filed from the canvas because that is
        // where it is made, but it is *looked at* here — and going into an editor to change
        // which board something is on is the long way round.
        if !boards.isEmpty { boardMenu(for: fit) }
        // Sharing belongs here as much as in the editor: this is where fits are looked at,
        // and the editor is where they are made.
        if let image = fit.renderImage {
            ShareLink(
                item: Image(uiImage: image),
                preview: SharePreview(fit.name.isEmpty ? "A fit" : fit.name, image: Image(uiImage: image))
            ) {
                Label("Share fit", systemImage: "square.and.arrow.up")
            }
        }
        Button("Delete fit", systemImage: "trash", role: .destructive) {
            fitPendingDeletion = fit
        }
    }

    /// Only lists boards that exist; making one is the collection's job and the fit
    /// editor's. This is the shortcut, not the place you set boards up.
    private func boardMenu(for fit: Fit) -> some View {
        Menu("File on a board", systemImage: "square.grid.2x2") {
            Button {
                fit.board = nil
                try? context.save()
            } label: {
                Label("None", systemImage: fit.board == nil ? "checkmark" : "")
            }
            ForEach(boards) { board in
                Button {
                    fit.board = fit.board?.id == board.id ? nil : board
                    try? context.save()
                } label: {
                    Label(board.name, systemImage: fit.board?.id == board.id ? "checkmark" : "")
                }
            }
        }
    }

    private func header(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.editorial(19))
                .foregroundStyle(Color.ink)
            DataLabel(text: detail)
        }
        .padding(.horizontal, 20)
    }

    private func columns(_ card: CGFloat) -> [GridItem] {
        [GridItem(.fixed(card), spacing: 14, alignment: .top), GridItem(.fixed(card), alignment: .top)]
    }

    /// A fit matches the collection's search by what it is called — its name, or what the
    /// card prints in place of one — or by any garment in it.
    private func matches(_ fit: Fit, _ query: String) -> Bool {
        guard !fit.isGone else { return false }
        let needle = query.trimmingCharacters(in: .whitespaces)
        return fit.displayName.localizedCaseInsensitiveContains(needle)
            || fit.items.contains { $0.matches(needle) }
    }
}

// MARK: - The fit row, once per change

extension FitsPage {
    /// Everything this page derives from the collection, worked out once per *change*.
    ///
    /// `FitSuggestions.build` classifies every save and scores pairs of them, and `body` runs
    /// far more often than the collection changes: the `@Query`s behind the wall are
    /// unpredicated, so any `context.save()` at all re-evaluates it — and the photograph pass
    /// saves once per batch of twelve while it drains, which on the tab this came from rebuilt
    /// every suggestion seventeen times while somebody was reading it. So the answer is kept
    /// behind a fingerprint that is cheap in the way the build is not: one walk over
    /// already-faulted scalars, no classification. Held in a reference type rather than
    /// `@State`, so the memo is invisible to the dependency graph — the queries already decide
    /// when to look again. See `docs/performance.md`.
    @MainActor
    final class ReadingMemo {
        struct Reading {
            var suggested: [SuggestedFit] = []
            /// Essential slots the wardrobe cannot fill at all, for `FitCandidates` and for
            /// saying why the row is empty. Derived here rather than at the `.task(id:)` that
            /// consumes it, because `SavedItem.slot` runs the classifier.
            var gaps: Set<GarmentSlot> = []
            /// The board everything is leaning towards, if one is.
            var mood: String?
        }

        private struct Fingerprint: Equatable {
            var count: Int
            var digest: Int
            var statement: StyleStatement
            /// The fits that already exist, so keeping one recomputes the row it came off.
            /// Without it the proposal stayed on screen until something else changed, which
            /// is the state in which trying it again writes a duplicate.
            var kept: [String]
            /// The gap-filling candidates, by identity. They arrive from a `.task` after the
            /// first build, so without them in the key the row would keep the version computed
            /// before they landed.
            var candidates: [PersistentIdentifier]
            /// What counts towards taste — leaving a save out changes no count and no stamp.
            var taste: TasteScope
        }

        private var key: Fingerprint?
        private var value = Reading()

        func reading(
            for saves: [SavedItem],
            candidates: [BrandUpdate],
            statement: StyleStatement,
            kept: [Fit],
            taste: TasteScope
        ) -> Reading {
            let fingerprint = Fingerprint(
                count: saves.count,
                digest: CollectionDigest.of(saves),
                statement: statement,
                kept: kept.compactMap(\.wardrobeKey),
                candidates: candidates.map(\.persistentModelID),
                taste: taste
            )
            if fingerprint == key { return value }

            let pool = taste.fitPool(saves)
            value = Reading(
                suggested: FitSuggestions.build(
                    from: pool,
                    candidates: candidates,
                    statement: statement,
                    kept: kept,
                    mood: taste.inMood
                ),
                gaps: FitCandidates.gaps(in: pool),
                mood: taste.moodName
            )
            key = fingerprint
            return value
        }
    }
}

/// A fit, drawn as it was arranged.
///
/// The flattened render when there is one, which is the whole reason it is written: a grid
/// of these would otherwise compose a canvas per card, and each canvas decodes every cutout
/// in it. The live surface is the fallback for fits made before renders existed and for the
/// moment between saving and the file landing.
struct FitCard: View {
    let fit: Fit
    var width: CGFloat = 168

    var body: some View {
        // **Nothing is drawn for a fit that has just been deleted.** The delete is on this
        // card's own context menu, so the row is invalidated while the card is still in the
        // view tree — and every property below traps on a deleted model. See `Fit.isGone`.
        if fit.isGone {
            Color.clear.frame(width: 0, height: 0)
        } else {
            card
        }
    }

    private var card: some View {
        // Read once. This was a computed property read twice per body — here and again by
        // the `ShareLink` in the context menu, whose content builder runs when the card is
        // built rather than when the menu is opened.
        let render = LocalImage.load(fit.renderURL)

        return VStack(alignment: .leading, spacing: 8) {
            Group {
                if let render {
                    Image(uiImage: render).resizable().scaledToFit()
                } else {
                    FitCanvasSurface(fit: fit)
                }
            }
            .frame(width: width, height: width)
            .background(Color.wash.opacity(0.4))

            Text(fit.displayName)
                .font(.editorial(12))
                .foregroundStyle(Color.ink)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(width: width)
    }
}

/// A proposal, which has no canvas yet — so it is drawn as its pieces, overlapped in the
/// order a fit is read. Deliberately looser than a real fit's card: this is something the
/// app is offering, and it should not pretend to be an arrangement somebody made.
struct SuggestedFitCard: View {
    let items: [FitPiece]
    let title: String
    var width: CGFloat = 168

    /// What the proposal is asking you to acquire, if anything.
    ///
    /// **Said out loud, because the alternative is the app quietly pretending you own
    /// something you don't.** A fit drawn from the catalogue looks identical to one drawn
    /// from the wardrobe — same cutouts, same card — and on the page that is about your own
    /// collection that is a small lie with a real cost: you would try it, keep it, and only
    /// later find a garment in it you have never seen.
    private var borrowed: [FitPiece] { items.filter { !$0.isOwned } }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack {
                ForEach(Array(items.prefix(4).enumerated()), id: \.offset) { index, item in
                    FitPieceImage(piece: item)
                        .frame(width: width * 0.55, height: width * 0.55)
                        .offset(
                            x: CGFloat(index % 2 == 0 ? -1 : 1) * width * 0.14,
                            y: CGFloat(index) * width * 0.13 - width * 0.2
                        )
                }
            }
            .frame(width: width, height: width)
            .clipped()
            // **`sweep`, not `wash` — a garment cannot be drawn on a ground that inverts.**
            //
            // This card is made of *cutouts*: `FitPieceImage` draws a lifted garment with
            // its background erased, so whatever is behind it shows through the silhouette.
            // `wash` is adaptive and goes to 0x1C1C19 at night, which is the exact problem
            // the collection wall already solved — most wardrobes are mostly black, and a
            // black jacket lifted onto near-black is a card with nothing visible on it.
            // Worse than the raw product shot it replaced, which at least carried its own
            // white sweep in the pixels.
            //
            // Same fixed cream the archive uses, and for the reason written there:
            // photographs do not invert. Any type set over this has to be `sweepInk`.
            .background(Color.sweep)

            Text(title)
                .font(.editorial(12))
                .foregroundStyle(Color.ink)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)

            // Plain `muted`, not the accent. Vermilion means "this is happening now" and is
            // rationed to a restock, a size you wear, a storefront locking; a garment you
            // have not bought is a fact about the proposal, not an event.
            if !borrowed.isEmpty {
                DataLabel(
                    text: borrowed.count == 1
                        ? "WITH 1 YOU DON'T OWN"
                        : "WITH \(borrowed.count) YOU DON'T OWN",
                    size: 9
                )
            }
        }
        .frame(width: width)
    }
}

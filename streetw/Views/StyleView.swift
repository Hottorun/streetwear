// StyleView.swift
// The third room: what your saves add up to, and what to do with them.
//
// This page used to be four percentage bars derived from the text of your saves — "38%
// Black, 22% Hoodies" — which is a fact about a database rather than anything a person
// wants. It stated the obvious about a wardrobe you already know, and offered nothing to
// act on.
//
// So it is now built around the two things a wardrobe is actually *for*:
//
// - **Fits.** Outfits made of things you kept. The first artefact in the app that says
//   how the pieces relate rather than cataloguing them one at a time, and the only one
//   worth looking at again months later. The app proposes some from your own saves; you
//   keep the ones that are right.
// - **Discover.** Brands worth adding, from what other people watch. The same block the
//   feed ends on, because "what next" has one answer and it shouldn't have two designs.
//
// The derived taste summary survives, demoted to a footnote where a statistic belongs.

import StreetwCore
import SwiftData
import SwiftUI

struct StyleView: View {
    @Environment(\.modelContext) private var context
    @Environment(StyleStatementStore.self) private var statement: StyleStatementStore

    @Query(sort: \SavedItem.savedAt, order: .reverse) private var saves: [SavedItem]
    @Query(sort: \Fit.createdAt, order: .reverse) private var fits: [Fit]
    @Query(sort: [SortDescriptor(\Board.sortIndex), SortDescriptor(\Board.createdAt)])
    private var boards: [Board]

    @State private var isShowingSettings = false
    @State private var isComposing = false
    @State private var editing: Fit?

    /// Everything this page derives from the collection, worked out **once**.
    ///
    /// All three of these were computed properties, and SwiftUI re-runs a computed property
    /// on every read. `profile` was read nine times in one evaluation of `body` — once to
    /// decide whether to draw the taste block and then once per facet line — and `suggested`
    /// three times, and `owned` three. So a single render rebuilt the whole style profile
    /// nine times over, and each rebuild walks every save, faults `save.update` and
    /// `update.brand`, and runs sixty-odd substring scans over any item the photograph
    /// analysis has not reached yet. `FitSuggestions.build` is worse per pass: it classifies
    /// every save and then scores pairs of them.
    ///
    /// This is the discipline `FeedView.feed` and `BrandRecommendations.ranked` already
    /// follow — one struct, computed at the top of `body`, threaded down as a parameter.
    /// Nothing about the answer changes; it is simply asked once.
    private struct Reading {
        var profile = StyleProfile()
        var suggested: [SuggestedFit] = []
        var owned: [SavedItem] = []
        var missing: [(slot: GarmentSlot, note: String)] = []
        /// Essential slots the wardrobe cannot fill at all, for `FitCandidates`.
        ///
        /// Derived here rather than at the `.task(id:)` that consumes it, because
        /// `SavedItem.slot` runs the classifier — asking it per save from `body` is the
        /// cost this whole memo exists to avoid, and is what `FitCanvas.traySlots` had to
        /// be rescued from.
        var gaps: Set<GarmentSlot> = []
    }

    /// Once per *change*, not once per `body` — which are very different numbers.
    ///
    /// Deriving once per render was the right correction and it stopped short. `body` runs
    /// far more often than the collection changes, and three of the reasons are routine and
    /// expensive:
    ///
    /// - **Every one of the three `@Query`s here is unpredicated**, so this view is
    ///   subscribed to the whole `SavedItem`, `Fit` and `Board` tables — and in fact to any
    ///   `context.save()` at all. `ImageTagger.analyzePending` saves once per batch of
    ///   twelve while it drains, so analysing two hundred saves rebuilt the entire style
    ///   profile and every fit suggestion seventeen times, on the main actor, while the
    ///   person was looking at the page.
    /// - **Local state re-renders too.** Opening Settings, opening the composer, keeping a
    ///   suggestion: each flips a `@State` and each rebuilt everything, for a sheet.
    /// - **So does anything else on the tab.** A sync landing, a card marked read.
    ///
    /// None of those change the answer. So the answer is kept and rebuilt only when the
    /// inputs move, behind a fingerprint that is cheap in the way the builds are not: one
    /// walk over already-faulted scalars, no classification, no string scanning. Note what
    /// it must *not* miss — the analysis landing is precisely what changes this reading, a
    /// colour and a silhouette and a category all arriving at once, which is why the two
    /// version stamps are in the digest.
    ///
    /// Held in a reference type rather than in `@State` on purpose: this is a memo, and it
    /// must be invisible to SwiftUI's dependency graph. Publishing it from inside `body`
    /// would be a write during evaluation, and the thing that decides when to recompute is
    /// already `@Query`.
    @State private var memo = ReadingMemo()

    /// Catalogue products standing in for slots the wardrobe cannot fill.
    ///
    /// Held in `@State` from a bounded fetch rather than as a `@Query`, which over
    /// `BrandUpdate` would subscribe this view to every product ever synced and rebuild it
    /// on every poll. See `FitCandidates`.
    @State private var fitCandidates: [BrandUpdate] = []

    @MainActor
    private final class ReadingMemo {
        private var key: Fingerprint?
        private var value = Reading()

        struct Fingerprint: Equatable {
            var count: Int
            var digest: Int
            var statement: StyleStatement
            /// The fits that already exist, so keeping one recomputes the row it came off.
            /// Without it the proposal stayed on screen until something else changed, which
            /// is the state in which tapping it again writes a duplicate.
            var kept: [String]
            /// The gap-filling candidates, by identity. They arrive from a `.task` after
            /// the first build, so without them in the key the row would keep the version
            /// computed before they landed.
            var candidates: [PersistentIdentifier]
        }

        func reading(
            for saves: [SavedItem],
            candidates: [BrandUpdate],
            statement: StyleStatement,
            kept: [Fit]
        ) -> Reading {
            let keptKeys = kept.compactMap(\.wardrobeKey)
            let fingerprint = Fingerprint(
                count: saves.count,
                digest: Self.digest(of: saves),
                statement: statement,
                kept: keptKeys,
                candidates: candidates.map(\.persistentModelID)
            )
            if fingerprint == key { return value }

            let owned = saves.filter { $0.type == .wardrobe && $0.update != nil }
            value = Reading(
                profile: StyleProfile.build(from: saves),
                suggested: FitSuggestions.build(
                    from: saves,
                    candidates: candidates,
                    statement: statement,
                    kept: kept
                ),
                owned: owned,
                missing: Self.missingSlots(owned: owned, saves: saves),
                gaps: FitCandidates.gaps(in: saves)
            )
            key = fingerprint
            return value
        }

        /// Everything the two builds read that can actually *change* after a save exists,
        /// reduced to one integer.
        ///
        /// Deliberately shallow. Title, tags and product type are written once when a row
        /// arrives and never edited, so they are covered by the item being present at all;
        /// what moves underneath a standing collection is the photograph analysis, and every
        /// field it writes is stamped by one of these three versions. `savedAt` catches a
        /// save being replaced rather than added, which `count` alone would miss.
        ///
        /// `brand` is left out on purpose: reading it here would fault the relationship for
        /// every save on every `body`, which is the cost this exists to avoid. A brand
        /// attached after the fact — `SharedSaveImporter.attachBrands` healing an old row —
        /// therefore shows up in the taste block on the next change rather than instantly,
        /// which is the right trade for a facet nobody is watching at that moment.
        private static func digest(of saves: [SavedItem]) -> Int {
            var hasher = Hasher()
            for save in saves {
                hasher.combine(save.id)
                hasher.combine(save.savedAt)
                hasher.combine(save.type)
                guard let update = save.update else { continue }
                hasher.combine(update.analyzedAt)
                hasher.combine(update.visionVersion)
                hasher.combine(update.cutoutVersion)
            }
            return hasher.finalize()
        }

        /// Slots a fit needs and this wardrobe cannot fill, plus the ones it is thin on.
        ///
        /// Only the slots a fit is actually built from — proposing that somebody is short of
        /// headwear is a fashion opinion, and this is meant to be an observation.
        ///
        /// - Parameter owned: the wardrobe. It falls back to everything saved, since most
        ///   people never split the two and an empty section would just look broken.
        private static func missingSlots(
            owned: [SavedItem],
            saves: [SavedItem]
        ) -> [(slot: GarmentSlot, note: String)] {
            let pool = owned.isEmpty ? saves.filter { $0.update != nil } : owned
            guard pool.count >= 3 else { return [] }

            var counts: [GarmentSlot: Int] = [:]
            for save in pool { counts[save.slot, default: 0] += 1 }

            return GarmentSlot.essential
                .sorted { $0.stackOrder < $1.stackOrder }
                .compactMap { slot in
                    switch counts[slot] ?? 0 {
                    case 0: return (slot, "nothing yet")
                    case 1: return (slot, "only one")
                    default: return nil
                    }
                }
        }
    }

    var body: some View {
        let reading = memo.reading(
            for: saves,
            candidates: fitCandidates,
            statement: statement.statement,
            kept: fits
        )

        return NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 34) {
                    if fits.isEmpty && reading.suggested.isEmpty && saves.isEmpty {
                        emptyWardrobe
                    } else {
                        if !fits.isEmpty { myFits }
                        if !reading.suggested.isEmpty { suggestedFits(reading.suggested) }
                        gaps(reading)
                    }

                    // **The tab about you ends with you.**
                    //
                    // There used to be a "Discover" block here — the same
                    // `BrandRecommendations` the feed carries — and it made sense while
                    // Discover was not a tab of its own. It is one now, so this was the same
                    // offer twice, and the weaker copy of it: a strip of six brand cards
                    // under a reading of somebody's wardrobe, against a full-bleed tab whose
                    // every card argues from the clothes they already own.
                    //
                    // It also cost this page its ending. The block was below the taste
                    // reading precisely so the tab did not open as a shop — the right
                    // instinct, applied to something that should not have been on the page
                    // at all.
                    if !reading.profile.isEmpty { taste(reading.profile) }
                }
                .padding(.vertical, 10)
                .padding(.bottom, 28)
            }
            .scrollIndicators(.hidden)
            .background(Color.paper)
            .navigationTitle("Style")
            .toolbarTitleDisplayMode(.inlineLarge)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("New fit", systemImage: "plus") { isComposing = true }
                        .disabled(saves.isEmpty)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Settings", systemImage: "gearshape") { isShowingSettings = true }
                }
            }
            .sheet(isPresented: $isShowingSettings) { SettingsSheet() }
            .sheet(isPresented: $isComposing) { FitCanvas(fit: nil) }
            .sheet(item: $editing) { FitCanvas(fit: $0) }
            // The other half of the pass that runs on the Saved tab. Cutouts are what the
            // canvas is built out of, and a fit can be composed from here without that tab
            // ever having been opened — which left the stickers un-lifted for exactly the
            // person who was about to need them.
            .task(id: ImageTagger.backlog(in: saves)) {
                await ImageTagger.analyzePending(in: context)
            }
            // Filling the wardrobe's empty slots from the catalogue. Keyed on the gaps
            // themselves, so it runs once for a given shape of wardrobe and not at all for
            // the common one where nothing is missing — and after the pass above, because a
            // save measured in the meantime can close a gap.
            .task(id: reading.gaps) {
                fitCandidates = await FitCandidates.pool(for: reading.gaps, in: context)
            }
            // The reading on this page is built from exactly what the pass is producing —
            // register, colours, silhouettes, the suggestion row's stickers — so a wardrobe
            // still being measured describes itself thinly and then changes its mind. Better
            // to say why.
            .safeAreaInset(edge: .top) {
                if let remaining = ImageTagger.progress.remaining {
                    AnalysisLine(remaining: remaining)
                }
            }
            .animation(.easeOut(duration: 0.2), value: ImageTagger.progress.remaining)
        }
        // Ink, not the system blue. Every other tab does this; without it the controls on
        // this page are the only chroma in the app outside a photograph, which is exactly
        // what the accent is rationed to avoid.
        .tint(.ink)
    }

    // MARK: - Sections

    private var emptyWardrobe: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Nothing saved yet")
                .font(.editorial(24))
                .foregroundStyle(Color.ink)
            Text("Save things you like from the feed, or share a link into Dropwall from anywhere. Once there are a few, this is where they become outfits.")
                .font(.editorial(15))
                .foregroundStyle(Color.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 20)
        .padding(.top, 20)
    }

    private var myFits: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionHeader("Your fits", "\(fits.count) \(fits.count == 1 ? "OUTFIT" : "OUTFITS")")

            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: 14) {
                    ForEach(fits) { fit in
                        Button { editing = fit } label: {
                            FitCard(fit: fit)
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            // Filing without opening the editor. A fit is filed from the
                            // canvas because that is where it is made, but it is *looked
                            // at* here — and going into an editor to change which board
                            // something is on is the long way round.
                            if !boards.isEmpty { boardMenu(for: fit) }
                            // Sharing belongs here as much as in the editor: this is where
                            // fits are looked at, and the editor is where they are made.
                            if let image = fit.renderImage {
                                ShareLink(
                                    item: Image(uiImage: image),
                                    preview: SharePreview(
                                        fit.name.isEmpty ? "A fit" : fit.name,
                                        image: Image(uiImage: image)
                                    )
                                ) {
                                    Label("Share fit", systemImage: "square.and.arrow.up")
                                }
                            }
                            Button("Delete fit", systemImage: "trash", role: .destructive) {
                                if let render = fit.renderFile { FitRender.remove(render) }
                                context.delete(fit)
                                try? context.save()
                            }
                        }
                    }
                }
                .padding(.horizontal, 20)
            }
            .scrollIndicators(.hidden)
        }
    }

    private func suggestedFits(_ suggested: [SuggestedFit]) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionHeader("From your wardrobe", "TAP TO KEEP ONE")

            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: 14) {
                    ForEach(suggested) { fit in
                        Button {
                            keep(fit)
                        } label: {
                            SuggestedFitCard(
                                items: fit.ordered,
                                // What the app saw, when it saw something. The slot list
                                // ("Top · Bottom · Footwear") is a description of the
                                // schema and says nothing a glance at the card doesn't.
                                title: fit.reason
                                    ?? fit.ordered.map(\.slot.label).joined(separator: " · ")
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 20)
            }
            .scrollIndicators(.hidden)
        }
    }

    /// What the wardrobe is short of.
    ///
    /// The one thing this tab can say that no other screen can. The feed knows what is
    /// new, the collection knows what you kept, and neither can tell you that you have six
    /// tops and nothing to put with them — which is both the most useful fact here and the
    /// reason a suggestion row is sometimes empty for no visible reason.
    ///
    /// Counted over `SaveType.wardrobe` when there is one, because "what am I missing" is
    /// a question about what you own rather than about what you have admired. It falls
    /// back to everything saved, since most people never split the two and an empty
    /// section would just look broken.
    @ViewBuilder
    private func gaps(_ reading: Reading) -> some View {
        if !reading.missing.isEmpty {
            VStack(alignment: .leading, spacing: 14) {
                sectionHeader(
                    "What's missing",
                    reading.owned.isEmpty ? "FROM YOUR SAVES" : "FROM YOUR WARDROBE"
                )

                VStack(alignment: .leading, spacing: 12) {
                    ForEach(reading.missing, id: \.slot) { entry in
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            Text(entry.slot.label)
                                .font(.editorial(15))
                                .foregroundStyle(Color.ink)
                            Spacer(minLength: 8)
                            DataLabel(text: entry.note.uppercased(), size: 9)
                        }
                        .overlay(alignment: .bottom) { Rule().offset(y: 8) }
                    }
                }
                .padding(.horizontal, 20)
            }
        }
    }

    private func taste(_ profile: StyleProfile) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionHeader("Your taste", "FROM \(profile.totalSaves) SAVED \(profile.totalSaves == 1 ? "ITEM" : "ITEMS")")

            VStack(alignment: .leading, spacing: 16) {
                FacetLine(title: "Colours", facets: profile.colors, axis: .colour)
                // Register above categories: "dark, muted, plain" is a sharper reading of
                // somebody than "hoodies and sneakers", which describes half of streetwear.
                // Both are read off the photograph rather than out of a product title —
                // see `VisualReading`.
                FacetLine(title: "Register", facets: profile.tones, axis: .tone)
                FacetLine(title: "How loud", facets: profile.patterns, axis: .pattern)
                FacetLine(title: "Categories", facets: profile.categories, axis: .category)
                FacetLine(title: "Silhouettes", facets: profile.silhouettes, axis: .silhouette)
                FacetLine(title: "Brands", facets: profile.brands, axis: .brand)
            }
            .padding(.horizontal, 20)
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

    private func sectionHeader(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.editorial(19))
                .foregroundStyle(Color.ink)
            DataLabel(text: detail)
        }
        .padding(.horizontal, 20)
    }

    /// Keeping a suggestion turns it into a real fit, at which point it stops being
    /// regenerated — the suggestion list is derived from the wardrobe, and this one is now
    /// a record.
    ///
    /// **It is arranged, and it does not open the editor.** Two faults, and they compounded
    /// into one bad minute: the fit was written with an *empty* `placements` array, so it
    /// drew as a blank square on the wall above and rendered as one; and the editor was
    /// pushed straight after, so closing it without saving left that blank square behind
    /// anyway — a fit somebody had explicitly not kept, sitting in the collection, with
    /// nothing in it. The row says "TAP TO KEEP ONE" and now that is exactly what a tap does.
    /// Arranging it by hand is what tapping the card in "Your fits" is for.
    private func keep(_ suggestion: SuggestedFit) {
        // **Anything borrowed from the catalogue is kept first.** A `Fit` is made of
        // `SavedItem`s — it has to be, because that is what makes an outfit a list of things
        // you own and what lets "one of these came back in stock" mean anything — so a
        // proposal containing a garment nobody kept cannot be stored as it stands.
        //
        // Saving it is the honest reading of the tap rather than a workaround: the row says
        // "tap to keep one", the card says which pieces are not yours, and keeping the fit
        // is exactly the moment you have decided you want them. Filed as inspiration, not
        // wardrobe, because you have not bought it — see `SaveType`.
        let ordered = suggestion.ordered
        // Split tops only when the proposal actually holds two, so a fit of one tee and one
        // pair of trousers is laid out exactly as it always was.
        let splitting = ordered.filter { $0.update.garment.slot == .top }.count > 1

        var arranged: [(position: FitPosition, itemID: UUID)] = []
        var items: [SavedItem] = []
        for piece in ordered {
            // **Anything borrowed from the catalogue is kept first.** A `Fit` is made of
            // `SavedItem`s — it has to be, because that is what makes an outfit a list of
            // things you own and what lets "one of these came back in stock" mean anything —
            // so a proposal containing a garment nobody kept cannot be stored as it stands.
            //
            // Saving it is the honest reading of the tap rather than a workaround: the row
            // says "tap to keep one", the card says which pieces are not yours, and keeping
            // the fit is exactly the moment you have decided you want them. Filed as
            // inspiration, not wardrobe, because you have not bought it — see `SaveType`.
            let save = piece.save ?? {
                let created = SavedItem(update: piece.update, type: .inspiration)
                context.insert(created)
                return created
            }()
            items.append(save)
            arranged.append((
                FitArrangement.position(for: piece.update.garment, splittingTops: splitting),
                save.id
            ))
        }

        // The proposal's own line goes with it — it is what the card said when it offered
        // this outfit, and it is what the card will say now that it is one. See
        // `Fit.verdict`.
        let fit = Fit(items: items, verdict: suggestion.reason)
        fit.placements = FitArrangement.placements(for: arranged)
        context.insert(fit)
        try? context.save()

        // The render, once every piece has actually decoded — the same contract `FitCanvas`
        // and `FitStudio` hold. Without it a kept fit shows the live canvas until the next
        // time it is edited, which is slower and can disagree with what was on the card.
        Task {
            guard await FitRender.warm(fit) else { return }
            fit.renderFile = await FitRender.write(fit)
            try? context.save()
        }
    }
}

// MARK: - Pieces

/// A fit, drawn as it was arranged.
///
/// The flattened render when there is one, which is the whole reason it is written: a row
/// of these would otherwise compose a canvas per card, and each canvas decodes every
/// cutout in it. The live surface is the fallback for fits made before renders existed and
/// for the moment between saving and the file landing.
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
    /// from the wardrobe — same cutouts, same card — and on the one tab that is about your
    /// own collection that is a small lie with a real cost: you would tap it, get a fit,
    /// and only later find a garment in it you have never seen.
    private var borrowed: [FitPiece] { items.filter { !$0.isOwned } }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack {
                ForEach(Array(items.prefix(4).enumerated()), id: \.offset) { index, item in
                    FitPieceImage(update: item.update)
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
            // the collection wall already solved — most of this catalogue is black, and a
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

/// One facet row, printed as a sentence rather than as a chart.
///
/// The old version drew a `ProgressView` per facet, tinted with the app's one reserved
/// accent — spending the colour that means "this is happening now" on a statistic about
/// last month's saves.
struct FacetLine: View {
    @Environment(CollectionRoute.self) private var collection: CollectionRoute

    let title: String
    let facets: [StyleFacet]
    /// Which axis these belong to, so a tap knows what question it is asking.
    let axis: CollectionFacet.Axis

    var body: some View {
        // Only what dominates — see `StyleProfile.dominant`. An axis with no shape prints
        // nothing rather than listing its own vocabulary back at the reader.
        let shown = StyleProfile.dominant(facets)
        if !shown.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                DataLabel(text: title.uppercased(), size: 9)
                // Each word is its own control, because each is its own query. Printed as
                // one comma-joined line the block was the app's reading of your taste with
                // nothing to do about it — a statement, on the page whose whole subject is
                // you. A facet is really a query over the collection, so tapping one runs
                // it. `FlowRow` rather than a scroller: these are four short words and
                // they should all be visible at once.
                FlowRow(spacing: 8) {
                    ForEach(shown) { facet in
                        Button {
                            collection.open(CollectionFacet(axis: axis, value: facet.label))
                        } label: {
                            Text(facet.label)
                                .font(.editorial(15))
                                .foregroundStyle(Color.ink)
                                // Underlined rather than boxed: the block is meant to read
                                // as a sentence about you, and four rows of chips would
                                // turn a reading into a control panel.
                                //
                                // **`hairline` was too quiet to be an affordance.** It is
                                // the colour of a *divider* — something the eye is meant to
                                // skip over — and under a word that is the only way into
                                // the collection from this page it made the control
                                // invisible: reported as "really difficult to see", which
                                // for a control means it may as well not be there. `muted`
                                // is the app's own secondary ink, so the line still reads
                                // as typography rather than as a border.
                                .overlay(alignment: .bottom) {
                                    Rectangle()
                                        .fill(Color.muted)
                                        .frame(height: 1)
                                        .offset(y: 3)
                                }
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }
        }
    }
}

/// Everything you set by hand, in one place — and nothing else.
///
/// The server address used to be editable here. It isn't any more: the app ships pointing
/// at its own backend, there is one correct value, and a text field inviting someone to
/// change it offered a way to break the app in exchange for nothing. The diagnostics it
/// carried were worth keeping and live in the alerts section now.
struct SettingsSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    SizeProfileSection()
                    Rule()
                    StyleStatementSection()
                    Rule()
                    NotificationsSection()
                }
                .padding(.horizontal, 20)
                .padding(.top, 4)
                .padding(.bottom, 40)
            }
            .scrollIndicators(.hidden)
            .background(Color.paper)
            .navigationTitle("Settings")
            .toolbarTitleDisplayMode(.inlineLarge)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .tint(.ink)
    }
}

#Preview {
    StyleView()
        .modelContainer(PreviewData.container)
}

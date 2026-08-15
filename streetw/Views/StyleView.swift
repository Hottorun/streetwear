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
    @Environment(BrandSuggestions.self) private var suggestions: BrandSuggestions
    @Environment(ServerSettings.self) private var settings: ServerSettings

    @Query(sort: \SavedItem.savedAt, order: .reverse) private var saves: [SavedItem]
    @Query(sort: \Fit.createdAt, order: .reverse) private var fits: [Fit]
    @Query(sort: [SortDescriptor(\Board.sortIndex), SortDescriptor(\Board.createdAt)])
    private var boards: [Board]

    @State private var isShowingSettings = false
    @State private var isComposing = false
    @State private var editing: Fit?

    private var profile: StyleProfile { StyleProfile.build(from: saves) }
    private var suggested: [SuggestedFit] { FitSuggestions.build(from: saves) }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 34) {
                    if fits.isEmpty && suggested.isEmpty && saves.isEmpty {
                        emptyWardrobe
                    } else {
                        if !fits.isEmpty { myFits }
                        if !suggested.isEmpty { suggestedFits }
                        gaps
                    }

                    // Below the reading of your own wardrobe, not above it. This is the
                    // tab about you; a shop at the top of it made the page read as one.
                    if !profile.isEmpty { taste }

                    BrandRecommendations(
                        title: "Discover",
                        blurb: "BRANDS OTHER PEOPLE ON STREETW FOLLOW"
                    )
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
            .task(id: settings.token) { await suggestions.loadIfNeeded() }
            // The other half of the pass that runs on the Saved tab. Cutouts are what the
            // canvas is built out of, and a fit can be composed from here without that tab
            // ever having been opened — which left the stickers un-lifted for exactly the
            // person who was about to need them.
            .task(id: saves.count) { await ImageTagger.analyzePending(in: context) }
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
            Text("Save things you like from the feed, or share a link into streetw from anywhere. Once there are a few, this is where they become outfits.")
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

    private var suggestedFits: some View {
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
    private var gaps: some View {
        let missing = missingSlots
        if !missing.isEmpty {
            VStack(alignment: .leading, spacing: 14) {
                sectionHeader(
                    "What's missing",
                    owned.isEmpty ? "FROM YOUR SAVES" : "FROM YOUR WARDROBE"
                )

                VStack(alignment: .leading, spacing: 12) {
                    ForEach(missing, id: \.slot) { entry in
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

    /// The wardrobe, or everything if nothing has been filed as owned.
    private var owned: [SavedItem] {
        saves.filter { $0.type == .wardrobe && $0.update != nil }
    }

    /// Slots a fit needs and this wardrobe cannot fill, plus the ones it is thin on.
    ///
    /// Only the slots a fit is actually built from — proposing that somebody is short of
    /// headwear is a fashion opinion, and this is meant to be an observation.
    private var missingSlots: [(slot: GarmentSlot, note: String)] {
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

    private var taste: some View {
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
    private func keep(_ suggestion: SuggestedFit) {
        let fit = Fit(items: suggestion.items)
        context.insert(fit)
        try? context.save()
        editing = fit
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

    private var render: UIImage? {
        fit.renderURL.flatMap { UIImage(contentsOfFile: $0.path(percentEncoded: false)) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
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
    let items: [SavedItem]
    let title: String
    var width: CGFloat = 168

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack {
                ForEach(Array(items.prefix(4).enumerated()), id: \.offset) { index, item in
                    FitPieceImage(item: item)
                        .frame(width: width * 0.55, height: width * 0.55)
                        .offset(
                            x: CGFloat(index % 2 == 0 ? -1 : 1) * width * 0.14,
                            y: CGFloat(index) * width * 0.13 - width * 0.2
                        )
                }
            }
            .frame(width: width, height: width)
            .clipped()
            .background(Color.wash.opacity(0.4))

            Text(title)
                .font(.editorial(12))
                .foregroundStyle(Color.ink)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
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
        if !facets.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                DataLabel(text: title.uppercased(), size: 9)
                // Each word is its own control, because each is its own query. Printed as
                // one comma-joined line the block was the app's reading of your taste with
                // nothing to do about it — a statement, on the page whose whole subject is
                // you. A facet is really a query over the collection, so tapping one runs
                // it. `FlowRow` rather than a scroller: these are four short words and
                // they should all be visible at once.
                FlowRow(spacing: 8) {
                    ForEach(facets.prefix(4)) { facet in
                        Button {
                            collection.open(CollectionFacet(axis: axis, value: facet.label))
                        } label: {
                            Text(facet.label)
                                .font(.editorial(15))
                                .foregroundStyle(Color.ink)
                                // Underlined rather than boxed: the block is meant to read
                                // as a sentence about you, and four rows of chips would
                                // turn a reading into a control panel.
                                .overlay(alignment: .bottom) {
                                    Rectangle()
                                        .fill(Color.hairline)
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

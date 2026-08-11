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
                    }

                    BrandRecommendations(
                        title: "Discover",
                        blurb: "BRANDS OTHER PEOPLE ON STREETW FOLLOW"
                    )

                    if !profile.isEmpty { taste }
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
            .sheet(isPresented: $isComposing) { FitComposer(fit: nil) }
            .sheet(item: $editing) { FitComposer(fit: $0) }
            .task(id: settings.token) { await suggestions.loadIfNeeded() }
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
                            FitCard(images: fit.imageURLs, title: fit.displayName)
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button("Delete fit", systemImage: "trash", role: .destructive) {
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
                            FitCard(
                                images: fit.ordered.compactMap { $0.update?.primaryImageURL },
                                title: fit.ordered.compactMap { $0.slot.label }.joined(separator: " · ")
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

    private var taste: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionHeader("Your taste", "FROM \(profile.totalSaves) SAVED \(profile.totalSaves == 1 ? "ITEM" : "ITEMS")")

            VStack(alignment: .leading, spacing: 16) {
                FacetLine(title: "Colours", facets: profile.colors)
                FacetLine(title: "Categories", facets: profile.categories)
                FacetLine(title: "Silhouettes", facets: profile.silhouettes)
                FacetLine(title: "Brands", facets: profile.brands)
            }
            .padding(.horizontal, 20)
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

/// A fit, drawn as its clothes. Stacked head-down so it reads as an outfit rather than a
/// row of products.
struct FitCard: View {
    let images: [URL]
    let title: String
    var width: CGFloat = 168

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(spacing: 2) {
                ForEach(Array(images.prefix(3).enumerated()), id: \.offset) { _, url in
                    UpdateImage(url: url, aspect: 1.55, contentMode: .fill, drawnWidth: 200)
                }
                if images.isEmpty {
                    Color.wash.aspectRatio(1, contentMode: .fit)
                }
            }
            .clipped()

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
    let title: String
    let facets: [StyleFacet]

    var body: some View {
        if !facets.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                DataLabel(text: title.uppercased(), size: 9)
                Text(facets.prefix(4).map(\.label).joined(separator: ", "))
                    .font(.editorial(15))
                    .foregroundStyle(Color.ink)
                    .fixedSize(horizontal: false, vertical: true)
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
            List {
                SizeProfileSection()
                NotificationsSection()
            }
            .scrollContentBackground(.hidden)
            .background(Color.paper)
            .navigationTitle("Settings")
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

// BrandsView.swift
// The brand list and the add-brand flow.

import StreetwCore
import SwiftData
import SwiftUI

struct BrandsView: View {
    @Environment(\.modelContext) private var context
    @Environment(SyncEngine.self) private var engine: SyncEngine
    @Environment(RemoteSync.self) private var remote: RemoteSync
    @Environment(ServerSettings.self) private var settings: ServerSettings
    @Environment(BrandSuggestions.self) private var suggestions: BrandSuggestions

    @Query(sort: \Brand.name) private var brands: [Brand]
    @State private var isAdding = false

    var body: some View {
        NavigationStack {
            Group {
                if brands.isEmpty {
                    EditorialEmptyState(
                        title: "No brands on watch",
                        action: "PASTE A BRAND'S WEBSITE AND STREETW WORKS OUT WHAT IT CAN WATCH"
                    )
                } else {
                    List {
                        ForEach(brands) { brand in
                            NavigationLink(value: BrandRoute(brand: brand)) {
                                BrandRow(brand: brand)
                            }
                            .listRowBackground(Color.paper)
                            .listRowSeparatorTint(Color.hairline)
                            .listRowInsets(EdgeInsets(top: 14, leading: 20, bottom: 14, trailing: 20))
                            // Rules run the full measure. Left alone, the separator
                            // indents to the text and starts halfway past the monogram,
                            // which reads as a misalignment rather than as a decision.
                            .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
                        }
                        .onDelete(perform: delete)

                        // The tab you open to manage brands was also the only one with no
                        // way to find any: five rows and then a page of nothing, while the
                        // recommendations sat on two other screens. Below the list rather
                        // than above it — this page is your brands first.
                        Section {
                            BrandRecommendations(
                                title: "More worth watching",
                                blurb: "PICKED FROM WHAT YOU KEEP"
                            )
                            .listRowInsets(EdgeInsets())
                            .listRowBackground(Color.paper)
                            .listRowSeparator(.hidden)
                        }
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                    .task(id: settings.token) { await suggestions.loadIfNeeded() }
                }
            }
            .background(Color.paper)
            .navigationTitle("Brands")
            .toolbarTitleDisplayMode(.inlineLarge)
            .appDestinations()
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Add brand", systemImage: "plus") { isAdding = true }
                }
            }
            .sheet(isPresented: $isAdding) {
                AddBrandView()
            }
        }
        .tint(.ink)
    }

    private func delete(at offsets: IndexSet) {
        let doomed = offsets.map { brands[$0] }
        // Unfollow first. Deleting only locally looks like it worked, then the next
        // sync re-creates the brand from the server's follow list.
        if settings.isConfigured {
            let remote = self.remote
            Task { for brand in doomed { await remote.unfollow(brand) } }
        }
        for brand in doomed { context.delete(brand) }
        try? context.save()
    }
}

/// A brand, set as an index entry: wordmark, what we watch it with, and the count —
/// the count printed rather than badged, because this is a list of things you follow,
/// not a set of notifications to clear.
struct BrandRow: View {
    let brand: Brand

    private var watching: String {
        let kinds = brand.sources.filter(\.enabled).map { $0.kind.label.uppercased() }
        return kinds.isEmpty ? "NOT WATCHED" : kinds.joined(separator: " · ")
    }

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            BrandMonogram(name: brand.name, logoURL: brand.logoURL)

            VStack(alignment: .leading, spacing: 5) {
                Wordmark(name: brand.name, size: 14)
                DataLabel(
                    text: brand.isLockedForDrop ? "LOCKED · DROP IMMINENT" : watching,
                    size: 10,
                    color: brand.isLockedForDrop ? .signal : .muted
                )
            }

            Spacer(minLength: 8)

            // Labelled, because a bare "390" beside a wordmark says nothing about what
            // is being counted — and the brand page one tap away calls the same figure
            // UNREAD, so borrowing the word costs nothing and makes the two agree.
            if brand.unseenCount > 0 {
                HStack(spacing: 5) {
                    Text("\(brand.unseenCount)")
                        .font(.data(12, .medium))
                        .foregroundStyle(Color.ink)
                    DataLabel(text: "UNREAD", size: 9)
                }
            }
        }
    }
}

/// The brand's own mark, taken from the icon its site publishes for home screens —
/// a file the brand chose, at a size meant to be looked at.
///
/// Falls back to initials rather than to a broken-image box, because plenty of sites
/// serve a generic platform favicon or nothing at all, and a wrong logo is worse than
/// no logo.
///
/// **One weight, whatever the site published.** A list of eight brands was showing three
/// different kinds of mark: a square glyph (Palace's P, Supreme's box) filled its tile;
/// a wide wordmark (KITH, `phase.`) fitted to *width* and floated as a thin strip in a
/// mostly empty square; and a brand publishing nothing fell back to initials at 27% of the
/// tile in `muted` grey, which beside a full-contrast logo reads as **disabled** — as
/// though that row had failed to load. Two changes, and they are the whole of it:
///
/// - The fallback is set at ink weight and large enough to be a mark rather than a label.
///   A brand with no icon should look typeset, not broken.
/// - The padding is thin, so a wide wordmark uses the measure it needs instead of being
///   inset to a third of the tile it was given.
struct BrandMonogram: View {
    let name: String
    var logoURL: URL?
    /// 44 in a list row; larger on a page that is about this one brand, where its own
    /// mark is the most useful thing on screen.
    var size: CGFloat = 44

    /// Two letters where the name gives two words, one where it doesn't. Never three: at
    /// this size a third letter is the difference between a mark and a word set too small
    /// to read.
    private var initials: String {
        let words = name.split(separator: " ").prefix(2)
        let letters = words.compactMap { $0.first.map(String.init) }.joined().uppercased()
        return letters.isEmpty ? "·" : letters
    }

    var body: some View {
        Rectangle()
            .fill(Color.wash)
            .frame(width: size, height: size)
            .overlay {
                if let logoURL {
                    // `BrandMark` has already asked the CDN for 180px, so this must not
                    // re-request a smaller width and undo that — hence a fixed request
                    // size rather than the points this happens to be drawn at.
                    CachedImage(url: logoURL, width: 180) { image in
                        image.resizable().scaledToFit().padding(size * 0.06)
                    } placeholder: {
                        Color.clear
                    } failure: {
                        monogram
                    }
                } else {
                    monogram
                }
            }
            .clipped()
    }

    private var monogram: some View {
        Text(initials)
            .font(.wordmark(size * 0.38, .semibold))
            .tracking(size * 0.02)
            .foregroundStyle(Color.ink)
            .minimumScaleFactor(0.7)
            .padding(.horizontal, size * 0.08)
    }
}

#Preview {
    BrandsView()
        .modelContainer(PreviewData.container)
        .environment(PreviewData.engine)
}

// BrandsView.swift
// Every brand being followed, how each is watched, and whether any of that is failing.
//
// Reached from You › Following. It was behind "ALL" at the head of the feed's brand rail
// until the rail went, and before that it was a tab.

import StreetwCore
import SwiftData
import SwiftUI

struct BrandsView: View {
    @Environment(\.modelContext) private var context
    @Environment(SyncEngine.self) private var engine: SyncEngine
    @Environment(RemoteSync.self) private var remote: RemoteSync
    @Environment(\.dismiss) private var dismiss
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
                        action: "PASTE A BRAND'S WEBSITE AND DROPWALL WORKS OUT WHAT IT CAN WATCH"
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
            .navigationTitle("Following")
            .toolbarTitleDisplayMode(.inlineLarge)
            .appDestinations()
            .toolbar {
                // A sheet, and it was once the one sheet in the app with no way out but a
                // swipe — every other one has a Done or a Close.
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }
                }
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
        // **The ids are taken before anything is deleted, and they are what the unfollow
        // travels on.** Deleting only locally looks like it worked and then the next sync
        // re-creates the brand from the server's follow list — so the unfollow has to
        // happen; and it cannot happen by handing a `Brand` to a `Task` that outlives the
        // delete, because reading a property of a deleted `@Model` traps. `RemoteSync`
        // writes each id to a ledger before it sends, so a pass killed halfway is retried
        // on the next sync rather than silently lost.
        let remoteIDs = doomed.compactMap(\.remoteID)
        // **Before the delete, never after.** `Brand.updates` cascades to `BrandUpdate`,
        // which cascades to `SavedItem` — so without this the swipe takes the whole
        // collection from that brand with it, silently, on a control that says nothing
        // about saves.
        for brand in doomed { brand.releaseKeepsakes() }
        for brand in doomed { context.delete(brand) }
        try? context.save()

        if settings.isConfigured, !remoteIDs.isEmpty {
            let remote = self.remote
            Task { for id in remoteIDs { await remote.unfollow(brandID: id) } }
        }
    }
}

/// A brand, set as an index entry: wordmark, and what we watch it with — including which of
/// those is failing.
///
/// **No unread count.** It printed one, labelled UNREAD, from when this list was a tab and
/// unread was something every screen kept per brand. Unread is "since you were last here" on
/// the feed now, and a second tally of it on a list of follows is a count to reconcile against
/// a screen that no longer keeps one per brand. What this list can say that nothing else can is
/// how each brand is watched, and whether that is working.
struct BrandRow: View {
    let brand: Brand

    /// What the row says under the wordmark, led by the mode when it is not the default.
    ///
    /// This list is where a quiet brand is *reachable* from — it is not on the feed by
    /// definition — so it has to be recognisable as quiet here, or a brand you silenced reads
    /// as one that stopped publishing.
    ///
    /// **The accent on the failing source alone**, where the feed would raise its voice and
    /// where the brand page already does: a failing source is drops going unseen, and in muted
    /// ink it read exactly like a list of source names. Only that word, though — the healthy
    /// source beside it is not news, and a whole line in vermilion says the brand is broken.
    private var status: Text {
        var parts: [Text] = []
        if let mode = brand.followMode.listLabel { parts.append(Text(mode)) }
        if brand.isLockedForDrop {
            parts.append(
                Text("LOCKED · DROP IMMINENT")
                    .foregroundStyle(brand.isAnnouncingLock ? Color.signal : Color.muted)
            )
        } else if brand.watchedSources.isEmpty {
            parts.append(Text("NOT WATCHED"))
        } else {
            for source in brand.watchedSources {
                parts.append(
                    source.isFailing
                        ? Text("\(source.label) FAILING").foregroundStyle(Color.signal)
                        : Text(source.label)
                )
            }
        }
        return parts.dropFirst().reduce(parts[0]) { line, part in line + Text(" · ") + part }
    }

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            BrandMonogram(name: brand.name, logoURL: brand.logoURL)

            VStack(alignment: .leading, spacing: 5) {
                Wordmark(name: brand.name, size: 14)
                status
                    .font(.data(10))
                    .tracking(0.4)
                    .foregroundStyle(Color.muted)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)
        }
    }
}

extension Brand {
    /// Whether a source this brand is watched with failed on its last check.
    ///
    /// `lastError` travels on the wire (`BrandSourceDTO`), so in server mode this is the
    /// poller's answer, and standalone it is the phone's own.
    var hasFailingSource: Bool {
        watchedSources.contains(where: \.isFailing)
    }

    /// Each source the brand is watched with, by name, and whether its last check failed. The
    /// brand page carries the error itself.
    var watchedSources: [(label: String, isFailing: Bool)] {
        sources.filter(\.enabled).map { ($0.kind.label.uppercased(), $0.lastError != nil) }
    }

    /// Only the sources that are failing — what a row about a brand that needs attention says.
    var failingSources: String {
        watchedSources.filter(\.isFailing).map(\.label).joined(separator: " · ") + " FAILING"
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
        // **Fixed, not adaptive — a logo does not invert any more than a photograph
        // does.** This drew on `wash`, which goes to near-black at night, and a brand
        // wordmark is almost always a dark mark authored for a light ground: on the
        // Brands list in dark mode Kith and Palace were black on black, and the only row
        // that survived was the one whose logo had failed to load and fallen back to
        // typeset initials. A list of brands where the identifiable ones are the broken
        // ones.
        //
        // It is the same fact `sweep` already exists for on the collection wall and the
        // fit canvas, and it is settled the same way. The cost is a light tile in a dark
        // list, which is what a wordmark looks like anyway — a credit line under a
        // photograph — and is much the smaller of the two prices.
        Rectangle()
            .fill(Color.sweep)
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
            // `sweepInk`, because the tile behind it stopped inverting. Adaptive `ink`
            // here would be near-white on near-cream in dark mode — trading two
            // invisible logos for every invisible initial, which is worse: the fallback
            // is what a brand with no artwork has instead of a mark.
            .foregroundStyle(Color.sweepInk)
            .minimumScaleFactor(0.7)
            .padding(.horizontal, size * 0.08)
    }
}

#Preview {
    BrandsView()
        .modelContainer(PreviewData.container)
        .environment(PreviewData.engine)
}

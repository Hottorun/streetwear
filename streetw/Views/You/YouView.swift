// YouView.swift
// Everything about the person rather than about the shops, on one page behind the avatar.
//
// In the order somebody would look for it: what the app has read of your taste, the sizes it
// marks things in, the brands it is watching for you, the things you are waiting on, and then
// the settings — alerts, the sentence you wrote about how you dress, and what the app is. Each
// of these used to be somewhere else: the reading was the tail of the Style tab, the settings a
// sheet behind its gear, the brand list a sheet behind "ALL" on the feed's brand rail, the
// watches and the calendar two icons in the feed's toolbar. None of them was news, which is
// what the feed is for, and none of them was a tab's worth of anything.
//
// **Set as type, like every other screen** — paper, serif, mono, rules — and not a stock
// `List`: this is where somebody comes to see what the app thinks of them, and a grouped
// settings form is the one shape that says "this is the app's plumbing".
//
// Nothing here is a placeholder. Profiles, location and credits are planned and not built, and
// a row for each saying so would be three rows of the app talking about itself. Sign-in leads
// the page, quietly, because it is the one setting about whether any of the rest survives a
// reinstall — see `AccountSection`.

import StreetwCore
import SwiftData
import SwiftUI

struct YouView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(SizeProfileStore.self) private var sizes: SizeProfileStore
    @Environment(ServerSettings.self) private var settings: ServerSettings
    @Environment(RemoteSync.self) private var remote: RemoteSync

    @Query(sort: \SavedItem.savedAt, order: .reverse) private var saves: [SavedItem]
    /// Only the boards with a taste setting — see `Board.shapingTaste`. Usually none.
    @Query(filter: Board.shapingTaste) private var tasteBoards: [Board]
    @Query(sort: \Brand.name) private var brands: [Brand]
    /// Both small tables of things somebody set by hand — tens of rows, not the thousands
    /// `BrandUpdate` runs to — so unpredicated is cheaper than two narrower queries each.
    @Query private var watches: [StockWatch]
    @Query private var plannedDrops: [PlannedDrop]

    @State private var memo = TasteMemo()
    @State private var isShowingBrands = false
    @State private var isAddingBrand = false
    @State private var isShowingWatches = false
    @State private var isShowingCalendar = false

    var body: some View {
        let reading = memo.reading(for: saves, taste: TasteScope(boards: tasteBoards, saves: saves))

        return NavigationStack {
            ScrollView {
                // Space between the sections, not rules: four of them end in a row with a
                // hairline of its own, and a second hairline under it a few points down read as
                // a printing error rather than as a division. The serif title starting each one
                // is division enough.
                VStack(alignment: .leading, spacing: 40) {
                    AccountSection()
                    taste(reading)
                    sizesSection
                    following
                    waitingFor
                    NotificationsSection()
                    StyleStatementSection()
                    AboutSection()
                }
                .padding(.horizontal, 20)
                .padding(.top, 4)
                .padding(.bottom, 40)
            }
            .scrollIndicators(.hidden)
            .background(Color.paper)
            // Keyed on the token: the page can appear before registration finishes, and a
            // `.task` that fires once, gets a 401 and swallows it would leave the account
            // section missing for the whole session.
            .task(id: settings.token) { await remote.refreshAccount() }
            .navigationTitle("You")
            .toolbarTitleDisplayMode(.inlineLarge)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            // A brand opened from Following is pushed here, and a destination registered on a
            // tab's stack is invisible from inside a presented one — the failure is a row that
            // silently does nothing.
            .appDestinations()
            .sheet(isPresented: $isShowingBrands) { BrandsView() }
            .sheet(isPresented: $isAddingBrand) { AddBrandView() }
            .sheet(isPresented: $isShowingWatches) { WatchesView() }
            .sheet(isPresented: $isShowingCalendar) { DropCalendarView() }
        }
        .tint(.ink)
    }

    // MARK: - Your taste

    /// What the collection adds up to, each word a way into the saves it was read from.
    ///
    /// Moved here from the end of the Style tab, where it was the tab's footnote. On a page
    /// about the person it leads, because it is the one thing on it the app worked out rather
    /// than was told.
    ///
    /// - Parameter reading: built once per *change* behind a fingerprint, never per `body` —
    ///   see `TasteMemo`.
    private func taste(_ reading: TasteMemo.Reading) -> some View {
        let profile = reading.profile
        return VStack(alignment: .leading, spacing: 18) {
            SettingsHeader(title: "Your taste", note: tasteNote(reading))

            // The reading is built from what the photograph pass produces — colours, register,
            // silhouettes — so a collection still being measured describes itself thinly and
            // then changes its mind. Better to say why.
            if let remaining = ImageTagger.progress.remaining {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.mini).tint(.muted)
                    DataLabel(
                        text: remaining == 1 ? "READING 1 PHOTOGRAPH" : "READING \(remaining) PHOTOGRAPHS",
                        size: 10
                    )
                }
                .transition(.opacity)
            }

            if !profile.isEmpty {
                VStack(alignment: .leading, spacing: 16) {
                    FacetLine(title: "Colours", facets: profile.colors, axis: .colour)
                    // Register above categories: "dark, muted, plain" is a sharper reading of
                    // somebody than "hoodies and sneakers", which describes half of any
                    // wardrobe. Both are read off the photograph rather than out of a product
                    // title — see `VisualReading`.
                    FacetLine(title: "Register", facets: profile.tones, axis: .tone)
                    FacetLine(title: "How loud", facets: profile.patterns, axis: .pattern)
                    FacetLine(title: "Categories", facets: profile.categories, axis: .category)
                    FacetLine(title: "Silhouettes", facets: profile.silhouettes, axis: .silhouette)
                    FacetLine(title: "Brands", facets: profile.brands, axis: .brand)
                }
            }
        }
        .animation(.easeOut(duration: 0.2), value: ImageTagger.progress.remaining)
    }

    /// - Note: says how many saves the reading leaves out beside the count it *was* built from.
    ///   A reading of twenty under a wall of twenty-three, with no word about the other three,
    ///   reads as the app having lost them.
    private func tasteNote(_ reading: TasteMemo.Reading) -> String {
        let total = reading.profile.totalSaves
        guard !reading.profile.isEmpty, total > 0 else {
            return "Save a few things and this is where Dropwall says what it sees in them."
        }
        let source = "Read from \(total) saved \(total == 1 ? "item" : "items")"
        let leftOut = reading.leftOut == 0 ? "" : ", \(reading.leftOut) left out"
        return "\(source)\(leftOut). Tap a word to see those saves."
    }

    // MARK: - Sizes

    /// What is set, one row per ladder, and the way to change it.
    ///
    /// A summary rather than the editor itself: the editor is five ladders of chips and a
    /// gender filter, and laid inline it would be most of this page — set once and read many
    /// times, which is the wrong way round for the space it would take.
    private var sizesSection: some View {
        let profile = sizes.profile
        return VStack(alignment: .leading, spacing: 12) {
            SettingsHeader(
                title: "Sizes",
                note: profile.isEmpty
                    ? "Set them and Dropwall can tell you when something is back in a size you actually wear."
                    : "Ruled in vermilion on every product. A size never hides anything — only what to show does."
            )

            VStack(spacing: 0) {
                ForEach(profile.ladders, id: \.ladder) { row in
                    YouRow(title: row.ladder.label, detail: row.sizes, detailColor: .ink)
                }
                YouRow(title: "Showing", detail: profile.gender.label.uppercased(), detailColor: .ink)
                NavigationLink {
                    SizesPage()
                } label: {
                    YouRow(title: profile.isEmpty ? "Set your sizes" : "Edit sizes", chevron: true)
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Following

    /// The brands being watched, and **which of them is not being watched properly**.
    ///
    /// The full list is a page of its own (`BrandsView`, which was behind "ALL" on the feed's
    /// brand rail): a person following forty shops would otherwise scroll past forty rows to
    /// reach their alerts. What is drawn here is what needs attention — a brand with a source
    /// that is failing. That used to be visible only on the brand's own page, three taps from
    /// anywhere, so a shop that had quietly stopped answering read exactly like one that had
    /// stopped publishing.
    private var following: some View {
        let failing = brands.filter(\.hasFailingSource)
        return VStack(alignment: .leading, spacing: 12) {
            SettingsHeader(title: "Following", note: followingNote(failing: failing.count))

            VStack(spacing: 0) {
                ForEach(failing) { brand in
                    NavigationLink(value: BrandRoute(brand: brand)) {
                        FailingBrandRow(brand: brand)
                    }
                    .buttonStyle(.plain)
                }
                if !brands.isEmpty {
                    Button { isShowingBrands = true } label: {
                        YouRow(title: "All brands", detail: "\(brands.count)", chevron: true)
                    }
                    .buttonStyle(.borderless)
                }
                Button { isAddingBrand = true } label: {
                    YouRow(title: "Add a brand", chevron: true)
                }
                .buttonStyle(.borderless)
            }
        }
    }

    private func followingNote(failing: Int) -> String {
        guard !brands.isEmpty else {
            return "Any shop with a website — paste its address and Dropwall works out what it can watch."
        }
        let watched = "\(brands.count) \(brands.count == 1 ? "brand" : "brands"), watched for drops, restocks and sales."
        switch failing {
        case 0: return watched
        case 1: return "\(watched) One isn't answering — Dropwall keeps trying."
        default: return "\(watched) \(failing) aren't answering — Dropwall keeps trying."
        }
    }

    // MARK: - Waiting for

    /// What somebody asked to be told about: restocks they are watching, and drops coming up.
    ///
    /// Both were icons in the feed's toolbar — a bell drawn only once a watch existed and a
    /// calendar that was always there — beside the photographs on the one screen whose subject
    /// is what has happened. They are lists of things set by hand, so they belong with the
    /// person who set them, and a row can say what an icon could only hint at.
    private var waitingFor: some View {
        let pending = watches.count { $0.isActive && $0.update != nil }
        let fired = watches.count { !$0.isActive && $0.update != nil }
        let now = Date()
        let dates = plannedDrops.count { $0.releaseAt > now }
        // The accent where the feed's calendar icon raised its voice: a locked storefront is
        // the strongest signal in the app, and it means minutes, not days.
        let isLocked = brands.contains(where: \.isAnnouncingLock)

        return VStack(alignment: .leading, spacing: 12) {
            SettingsHeader(
                title: "Waiting for",
                note: "Restocks you're watching for, and the drops that are coming."
            )

            VStack(spacing: 0) {
                Button { isShowingWatches = true } label: {
                    YouRow(title: "Watching", detail: watchDetail(pending: pending, fired: fired), chevron: true)
                }
                .buttonStyle(.borderless)

                Button { isShowingCalendar = true } label: {
                    YouRow(
                        title: "Drop calendar",
                        detail: isLocked
                            ? "A STOREFRONT IS LOCKED"
                            : (dates == 0 ? nil : "\(dates) \(dates == 1 ? "DATE" : "DATES") ADDED"),
                        detailColor: isLocked ? .signal : .muted,
                        chevron: true
                    )
                }
                .buttonStyle(.borderless)
            }
        }
    }

    private func watchDetail(pending: Int, fired: Int) -> String {
        switch (pending, fired) {
        case (0, 0): return "NOTHING ON WATCH"
        case (_, 0): return "\(pending) WAITING"
        case (0, _): return "\(fired) CAME BACK"
        default: return "\(pending) WAITING · \(fired) CAME BACK"
        }
    }
}

// MARK: - The taste reading, once per change

extension YouView {
    /// The taste reading, kept and rebuilt only when what it reads moves.
    ///
    /// The discipline `docs/performance.md` describes for the page this came from. `body` runs
    /// far more often than the collection changes — the `@Query` on saves is unpredicated, and
    /// the photograph pass saves once per batch of twelve while it drains — and
    /// `StyleProfile.build` walks every save, faults its product and runs sixty-odd substring
    /// scans over anything not yet measured. Held in a reference type rather than `@State` so the
    /// memo is invisible to the dependency graph; `@Query` already decides when to look again.
    @MainActor
    final class TasteMemo {
        struct Reading {
            var profile = StyleProfile()
            /// How many saves the reading leaves out, so it can say so.
            var leftOut = 0
        }

        private struct Fingerprint: Equatable {
            var count: Int
            var digest: Int
            /// What counts towards taste. Leaving something out changes no count and no
            /// photograph stamp, so without this the reading would go on including it until
            /// something unrelated changed.
            var taste: TasteScope
        }

        private var key: Fingerprint?
        private var value = Reading()

        func reading(for saves: [SavedItem], taste: TasteScope) -> Reading {
            let fingerprint = Fingerprint(count: saves.count, digest: CollectionDigest.of(saves), taste: taste)
            if fingerprint == key { return value }
            value = Reading(
                profile: StyleProfile.build(from: taste.counted(saves)),
                leftOut: taste.leftOut(of: saves)
            )
            key = fingerprint
            return value
        }
    }
}

// MARK: - Pieces

/// One line on the page: a name, what it is set to, and a chevron when it opens something.
struct YouRow: View {
    let title: String
    var detail: String?
    var detailColor: Color = .muted
    var chevron = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(title)
                .font(.editorial(16))
                .foregroundStyle(Color.ink)
            Spacer(minLength: 8)
            if let detail {
                DataLabel(text: detail, size: 10, color: detailColor)
                    .lineLimit(1)
            }
            if chevron {
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color.muted)
            }
        }
        .padding(.vertical, 12)
        .overlay(alignment: .bottom) { Rule() }
        .contentShape(.rect)
    }
}

/// A brand that needs attention: its mark, and which of its sources is failing.
private struct FailingBrandRow: View {
    let brand: Brand

    var body: some View {
        HStack(spacing: 12) {
            BrandMonogram(name: brand.name, logoURL: brand.logoURL, size: 34)
            VStack(alignment: .leading, spacing: 4) {
                Wordmark(name: brand.name, size: 12)
                DataLabel(text: brand.failingSources, size: 9, color: .signal)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Image(systemName: "chevron.right")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Color.muted)
        }
        .padding(.vertical, 10)
        .overlay(alignment: .bottom) { Rule() }
        .contentShape(.rect)
    }
}

/// Sizes and what to show, as a sheet of their own.
///
/// What the feed's lines about the profile open — "SET YOUR SIZES", "FILTERED TO MENSWEAR" —
/// which are about these two settings and nothing else, so they open onto these and not onto
/// the whole of You.
struct SizesSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            SizesPage()
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Done") { dismiss() }
                    }
                }
        }
        .tint(.ink)
    }
}

/// The size editor, pushed from the summary on You.
private struct SizesPage: View {
    var body: some View {
        ScrollView {
            SizeProfileSection()
                .padding(.horizontal, 20)
                .padding(.top, 4)
                .padding(.bottom, 40)
        }
        .scrollIndicators(.hidden)
        .background(Color.paper)
        .navigationTitle("Sizes")
        .toolbarTitleDisplayMode(.inline)
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

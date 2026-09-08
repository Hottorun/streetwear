// BrandDetailView.swift
// One brand: its mark, what it has been doing, what you kept from it, and how we watch it.
//
// This was the last screen in the app still built out of a stock `List` — grey grouped
// sections, `.bordered` buttons, a system toggle, `LabeledContent`. Every other surface is
// paper, serif headings and mono data labels, so opening a brand fell out of the app and
// into Settings.app for a moment. The information was right; none of the presentation was.
//
// What it is now, in reading order:
//
// - **The brand.** Its own mark at a size worth looking at, its name set as a wordmark,
//   and the one urgent fact — a locked storefront — in the accent, because that is the
//   signal people open this page hoping to see.
// - **A line of counts, which is also the filter.** Catalogue, unread, kept. The three
//   numbers were printed as data and did nothing, on the page whose whole subject is the
//   thing they count — the same criticism `StyleView`'s taste block answered by making
//   each word a query. Tapping one narrows the grid below; the numbers still read as
//   numbers, they just also go somewhere.
// - **The catalogue**, as a vertical grid. Two things were wrong with what was here.
//   It was two *horizontal* carousels, so seeing a brand's output meant swiping a strip
//   sideways twenty times — the one gesture that cannot be skimmed, on the page most
//   likely to be browsed rather than read. And it was capped at twenty of the most recent,
//   which on a brand mid-season is one poll's worth: the app held two hundred and fifty
//   products and showed a dozen, so "what does this brand make" — the question the page
//   exists to answer — was the one thing it could not.
// - **The machinery**, last and quietest: which sources we poll, what they last said, when
//   they last ran. Worth having and never worth leading with.
//
// Following moved to the bottom and became a word rather than a switch. It is a decision
// you make once, and a toggle at the top of a page invites fiddling with it.

import StreetwCore
import SwiftData
import SwiftUI

struct BrandDetailView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.openURL) private var openURL
    @Environment(SyncEngine.self) private var engine: SyncEngine
    @Environment(RemoteSync.self) private var remote: RemoteSync
    @Environment(ServerSettings.self) private var settings: ServerSettings
    @Environment(SizeProfileStore.self) private var sizes: SizeProfileStore

    /// The collection, so "KEPT" can be answered without walking the catalogue — see
    /// `savedFromBrand`. Bounded by how much somebody has kept, which is the size of the
    /// answer rather than the size of the store.
    @Query(sort: \SavedItem.savedAt, order: .reverse) private var saves: [SavedItem]

    @Bindable var brand: Brand

    /// Which of the three counts the grid is currently showing.
    @State private var lens: Lens = .catalogue

    /// The three questions this page can answer about one brand's output.
    ///
    /// They are the three numbers that were already printed above the fold — this only
    /// makes them lead somewhere. `catalogue` is deliberately first and the default: the
    /// page used to open on a handful of recent items, which answered "what has changed"
    /// twice (the feed already did) and "what does this brand make" never.
    private enum Lens: String, CaseIterable, Identifiable {
        case catalogue
        case unread
        case kept

        var id: String { rawValue }

        var label: String {
            switch self {
            case .catalogue: "CATALOGUE"
            case .unread: "UNREAD"
            case .kept: "KEPT"
            }
        }
    }

    /// Everything the app holds for this brand, one row per garment, newest first.
    ///
    /// Filtered like every other browsing list — `BrandUpdate.passes` is the one rule and
    /// every list calls it. Uncapped, unlike the twenty this page used to print: a
    /// `LazyVGrid` builds the tiles it can see and no others, so the cost of showing a
    /// brand's whole output is the cost of the screenful you are looking at.
    /// - Note: built together with `unread` in `shelves()`, out of **one** walk of the
    ///   relationship. Reading `brand.updates` faults the brand's entire catalogue, and
    ///   this page used to do it three times per render.
    private func catalogueAndUnread() -> (catalogue: [BrandUpdate], unread: [BrandUpdate]) {
        let profile = sizes.profile
        var all: [BrandUpdate] = []
        var unread: [BrandUpdate] = []
        all.reserveCapacity(brand.updates.count)
        for update in brand.updates {
            guard update.passes(profile) else { continue }
            all.append(update)
            if !update.isSeen { unread.append(update) }
        }
        return (BrandUpdate.oncePerProduct(all), BrandUpdate.oncePerProduct(unread))
    }

    /// What the feed still owes you from this brand.
    ///
    /// Deduplicated over the **unread rows**, not filtered out of `catalogue` — those are
    /// different questions and only this one agrees with the rest of the app. A garment
    /// that dropped, was read, and has since been marked down holds one unread row and one
    /// read one; `catalogue` keeps the newest event per garment and would answer either way
    /// depending on which landed last. The feed groups with `oncePerProduct` over its
    /// unseen set and `Brand.unseenCount(matching:)` counts distinct keys the same way, so
    /// this page saying a different number is the "two screens describing one queue and
    /// disagreeing about its size" failure that count exists to prevent.
    /// **Not filtered by `passes`, deliberately.** These are things you chose to keep, and
    /// hiding one because it doesn't match a setting you changed afterwards would be the
    /// app editing your own collection. Ordered by when you kept it, which is the only
    /// ordering a collection has.
    ///
    /// **Asked of the saves, not of the catalogue.** This walked `brand.updates` testing
    /// `!$0.saves.isEmpty`, which faults the `saves` relationship of **every** row in the
    /// brand — 250 separate relationship resolutions to find the three saved ones — and then
    /// faulted `save` again inside a comparator that runs O(n log n) times. The answer is
    /// proportional to how much somebody has kept, so it should be read off the thing that
    /// is proportional to that. `saves` is already sorted by the query.
    private var savedFromBrand: [BrandUpdate] {
        saves.compactMap(\.update).filter { $0.brand?.id == brand.id }
    }

    private var automatic: [BrandSource] {
        brand.sources.filter { $0.kind.isAutomatic }
    }

    var body: some View {
        // One evaluation of each list per render, reused by the counts, the filter and the
        // grid. `oncePerProduct` sorts the brand's whole output, and SwiftUI evaluates
        // `body` often and for reasons that have nothing to do with this brand — the same
        // argument as `FeedView.Feed`, one page along.
        let lists = catalogueAndUnread()
        let shelves = Shelves(
            catalogue: lists.catalogue,
            unread: lists.unread,
            kept: savedFromBrand
        )

        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 34) {
                masthead
                if brand.isLockedForDrop { lockNotice }
                counts(shelves)
                links
                shelf(shelves)
                sources
                followingRow
            }
            .padding(.top, 8)
            .padding(.bottom, 40)
        }
        .scrollIndicators(.hidden)
        .background(Color.paper)
        .navigationTitle(brand.name)
        .toolbarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if engine.isSyncing || remote.isSyncing {
                    ProgressView()
                } else {
                    Button("Refresh", systemImage: "arrow.clockwise") {
                        Task { await refresh() }
                    }
                }
            }
        }
        .refreshable { await refresh() }
        .onDisappear {
            brand.lastOpenedAt = Date()
            try? context.save()
        }
    }

    // MARK: - Sections

    /// The mark at 64pt rather than the 44 the list row uses. On a page *about* one brand,
    /// its own logo is the most useful thing on screen and the cheapest to give room to.
    private var masthead: some View {
        HStack(alignment: .center, spacing: 16) {
            BrandMonogram(name: brand.name, logoURL: brand.logoURL, size: 64)

            VStack(alignment: .leading, spacing: 6) {
                Wordmark(name: brand.name, size: 17)
                if let host = brand.websiteURL?.host()?.replacingOccurrences(of: "www.", with: "") {
                    DataLabel(text: host.uppercased(), size: 10)
                }
                DataLabel(
                    text: brand.lastSyncedAt.map { "CHECKED \(Stamp.short($0).uppercased())" }
                        ?? "NOT CHECKED YET",
                    size: 9
                )
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
    }

    /// The one thing on this page allowed to be loud. A storefront going dark usually means
    /// minutes, not hours.
    private var lockNotice: some View {
        HStack(spacing: 10) {
            Image(systemName: "lock.fill")
                .font(.system(size: 11))
                .foregroundStyle(Color.signal)
            Text("Storefront is locked — usually a release is close.")
                .font(.editorial(14))
                .foregroundStyle(Color.ink)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.wash)
        .overlay(alignment: .leading) { Rectangle().fill(Color.signal).frame(width: 2) }
        .padding(.horizontal, 20)
    }

    /// The three counts, and the control that decides what the grid below shows.
    ///
    /// **A count is a query here, not a statistic.** These three numbers already described
    /// exactly the three lists this page can draw, and they sat above a grid you could not
    /// point at any of them — so "4 KEPT" was a fact with nowhere to go on the one screen
    /// that holds those four things. Same argument as `StyleView`'s taste facets, and the
    /// same obligation: each number is the length of the list it opens, or the page is
    /// telling two stories about one shelf.
    ///
    /// Still printed as data rather than as buttons — a segmented control at the top of a
    /// brand page would be the loudest thing on it, and this is a page about clothes.
    /// The selected lens is marked by a rule under it, which is the same underline the feed
    /// uses for "+36 MORE FROM …".
    private func counts(_ shelves: Shelves) -> some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(Lens.allCases) { option in
                Button {
                    lens = option
                } label: {
                    count(
                        shelves.count(option),
                        option.label,
                        // The accent stays on unread and only on unread: it means "this is
                        // happening now" everywhere else in the app, and spending it on a
                        // selection state would be spending it on a preference.
                        accent: option == .unread && shelves.unread.count > 0,
                        isSelected: lens == option
                    )
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(.horizontal, 20)
        .overlay(alignment: .top) { Rule().padding(.horizontal, 20) }
        .overlay(alignment: .bottom) { Rule().padding(.horizontal, 20) }
    }

    private func count(
        _ value: Int,
        _ label: String,
        accent: Bool = false,
        isSelected: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(value)")
                .font(.data(20, .medium))
                .foregroundStyle(accent ? Color.signal : (isSelected ? Color.ink : Color.muted))
            DataLabel(text: label, size: 9, color: isSelected ? .ink : .muted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 14)
        .contentShape(.rect)
        .overlay(alignment: .bottom) {
            // Drawn at full opacity or none rather than conditionally inserted, so the
            // three columns keep one baseline as the selection moves between them.
            Rectangle()
                .fill(Color.ink)
                .frame(height: 2)
                .opacity(isSelected ? 1 : 0)
        }
    }

    /// The brand's output as a vertical grid, narrowed to whichever count was tapped.
    ///
    /// Two columns rather than the feed's three: this page has one brand on it, so a tile
    /// can afford the price and the size run — which is what turns a thumbnail into
    /// something you can decide about — and three-across cannot carry either legibly.
    @ViewBuilder
    private func shelf(_ shelves: Shelves) -> some View {
        let items = shelves.items(for: lens)

        if items.isEmpty {
            emptyShelf(shelves)
        } else {
            LazyVGrid(columns: Self.columns, alignment: .leading, spacing: 26) {
                ForEach(items) { update in
                    CatalogueTile(update: update)
                }
            }
            .padding(.horizontal, 20)
        }
    }

    private static let columns = [
        GridItem(.flexible(), spacing: 14),
        GridItem(.flexible())
    ]

    /// Why the grid is empty, which is three different answers.
    ///
    /// An empty catalogue is a statement about the *watching* — nothing has been found yet,
    /// or nothing here can be watched at all — and that is the one worth the long
    /// explanation `nothingYet` already gives. An empty unread or kept shelf is ordinary
    /// and says so briefly, because a paragraph about it would read as a fault.
    @ViewBuilder
    private func emptyShelf(_ shelves: Shelves) -> some View {
        switch lens {
        case .catalogue:
            nothingYet
        case .unread:
            note(
                shelves.catalogue.isEmpty ? "Nothing to read yet" : "You're up to date",
                "EVERYTHING THIS BRAND HAS PUBLISHED IS IN THE CATALOGUE"
            )
        case .kept:
            note(
                "Nothing kept from here",
                "SAVE SOMETHING AND IT LANDS ON THIS SHELF AND IN YOUR COLLECTION"
            )
        }
    }

    private func note(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.editorial(19))
                .foregroundStyle(Color.ink)
            DataLabel(text: detail, size: 10)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 20)
    }

    /// The three lists, built once and handed down. A struct rather than three parameters
    /// so a new lens is one case and one line rather than a signature change on everything
    /// that draws part of this page.
    private struct Shelves {
        var catalogue: [BrandUpdate]
        var unread: [BrandUpdate]
        var kept: [BrandUpdate]

        func items(for lens: Lens) -> [BrandUpdate] {
            switch lens {
            case .catalogue: catalogue
            case .unread: unread
            case .kept: kept
            }
        }

        func count(_ lens: Lens) -> Int { items(for: lens).count }
    }

    @ViewBuilder
    private var links: some View {
        let destinations: [(label: String, symbol: String, url: URL)] = [
            brand.websiteURL.map { ("SHOP", "arrow.up.right", $0) },
            brand.instagramURL.map { ("INSTAGRAM", "arrow.up.right", $0) }
        ].compactMap { $0 }

        if !destinations.isEmpty {
            HStack(spacing: 10) {
                ForEach(destinations, id: \.label) { destination in
                    Button { openURL(destination.url) } label: {
                        HStack(spacing: 6) {
                            Text(destination.label)
                                .font(.data(11, .semibold))
                                .tracking(1.1)
                            Image(systemName: destination.symbol)
                                .font(.system(size: 8, weight: .semibold))
                        }
                        .foregroundStyle(Color.ink)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .overlay { Rectangle().stroke(Color.hairline, lineWidth: 1) }
                    }
                    .buttonStyle(.borderless)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 20)
        }
    }

    private var nothingYet: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(brand.lastSyncedAt == nil ? "Not checked yet" : "Nothing found yet")
                .font(.editorial(19))
                .foregroundStyle(Color.ink)
            Text(
                automatic.isEmpty
                    ? "Nothing on this site can be watched automatically — it's here as a link."
                    : "Dropwall is watching \(automatic.map { $0.kind.label.lowercased() }.joined(separator: " and ")). New drops will appear here."
            )
            .font(.editorial(14))
            .foregroundStyle(Color.muted)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 20)
    }

    /// Last, and deliberately dry. This is the only place a source's error is visible, so
    /// it has to be legible — but nobody opens a brand page to read about a sitemap.
    private var sources: some View {
        section("How it's watched", "\(brand.sources.count) \(brand.sources.count == 1 ? "SOURCE" : "SOURCES")") {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(brand.sources) { source in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 10) {
                            Text(source.kind.label.uppercased())
                                .font(.data(11, .medium))
                                .foregroundStyle(source.kind.isAutomatic ? Color.ink : Color.muted)
                            Spacer(minLength: 8)
                            DataLabel(
                                text: source.lastError != nil
                                    ? "FAILING"
                                    : (source.kind.isAutomatic ? "WATCHING" : "LINK ONLY"),
                                size: 9,
                                color: source.lastError != nil ? .signal : .muted
                            )
                        }

                        Text(source.url.absoluteString)
                            .font(.data(10))
                            .foregroundStyle(Color.muted)
                            .lineLimit(1)
                            .truncationMode(.middle)

                        if let error = source.lastError {
                            Text(
                                source.failureCount > 1
                                    ? "\(error) — failed \(source.failureCount)×, backing off."
                                    : error
                            )
                            .font(.data(10))
                            .foregroundStyle(Color.signal)
                            .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(.vertical, 12)
                    .overlay(alignment: .bottom) { Rule() }
                }
            }
            .padding(.horizontal, 20)
        }
    }

    /// Words, not switches. These are rare, deliberate and reversible — and a toggle at the
    /// top of the page made them the most prominent controls on a screen that is about
    /// looking at clothes.
    ///
    /// **Two rows, because they were one and it was the wrong one.** "Stop following"
    /// carried a `bell.slash` — the universal mute icon — so the app was already offering
    /// this and then doing something much more drastic. A brand that posts forty times a
    /// week is not one you want to stop watching; it is one you want to stop being woken
    /// by, and until now the only way to get quiet was to delete it from your feed.
    private var followingRow: some View {
        VStack(spacing: 0) {
            if brand.followed {
                actionRow(
                    title: brand.isMuted ? "Unmute" : "Mute alerts",
                    detail: brand.isMuted ? "SILENT · STILL IN YOUR FEED" : nil,
                    symbol: brand.isMuted ? "bell" : "bell.slash",
                    isEmphasised: brand.isMuted
                ) {
                    brand.isMuted.toggle()
                    try? context.save()
                }
            }

            actionRow(
                title: brand.followed ? "Stop following" : "Follow again",
                detail: nil,
                // Not a bell. Unfollowing removes the brand from the feed entirely, and
                // borrowing the mute icon for it is what made the two indistinguishable.
                symbol: brand.followed ? "minus.circle" : "plus.circle",
                isEmphasised: !brand.followed
            ) {
                brand.followed.toggle()
                try? context.save()
                syncFollowState()
            }
        }
        .overlay(alignment: .top) { Rule().padding(.horizontal, 20) }
    }

    private func actionRow(
        title: String,
        detail: String?,
        symbol: String,
        isEmphasised: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.data(12, .medium))
                        .foregroundStyle(isEmphasised ? Color.ink : Color.muted)
                    if let detail { DataLabel(text: detail, size: 9) }
                }
                Spacer()
                Image(systemName: symbol)
                    .font(.system(size: 11))
                    .foregroundStyle(isEmphasised ? Color.ink : Color.muted)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
            .contentShape(.rect)
        }
        .buttonStyle(.borderless)
    }

    private func section(
        _ title: String,
        _ detail: String,
        @ViewBuilder content: () -> some View
    ) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                    .font(.editorial(19))
                    .foregroundStyle(Color.ink)
                DataLabel(text: detail)
            }
            .padding(.horizontal, 20)

            content()
        }
    }

    // MARK: - Actions

    /// The server decides what gets polled, so following has to be recorded there, not
    /// just flagged locally.
    private func syncFollowState() {
        guard settings.isConfigured, let id = brand.remoteID else { return }
        let following = brand.followed
        Task {
            if following {
                try? await remote.follow(brandID: id)
            } else {
                await remote.unfollow(brandID: id)
            }
        }
    }

    /// In server mode the phone never polls storefronts itself.
    private func refresh() async {
        if settings.isConfigured {
            await remote.sync(sizes: sizes.profile)
        } else {
            await engine.sync(brands: [brand])
        }
    }
}

// MARK: - One garment on the brand's shelf

/// A product as the brand page draws it: photograph, what is urgent about it, name, price,
/// size run.
///
/// Two columns wide, which is the whole reason it is not `FeedTile`. That tile is a third
/// of a feed page and carries a title and nothing else, on purpose — it is competing with a
/// lead item above it and with two other brands below. Here there is one brand and no lead,
/// the grid *is* the page, and a tile that says only what something is called is a
/// thumbnail you have to open to learn anything from. At half-width the price and the size
/// run both fit, and those are the two facts that decide whether to tap.
///
/// The accent rule marking your size is kept from `FeedTile`, at the same dose: the size
/// run says it in full, and the rule is what makes it findable while scrolling.
private struct CatalogueTile: View {
    @Environment(SizeProfileStore.self) private var sizes: SizeProfileStore

    let update: BrandUpdate

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            UpdateImage(
                url: update.primaryImageURL,
                kind: update.kind,
                aspect: 1,
                drawnWidth: 200,
                mark: update.brand?.name
            )
            .overlay(alignment: .bottomLeading) {
                if update.isInMySize(sizes.profile) {
                    Rectangle().fill(Color.signal).frame(height: 2)
                }
            }

            // The one line of urgency a card is allowed, and only when there is one — a
            // restock, a markdown, your size. `FeedState` decides; this page does not get
            // its own opinion about what counts as news. See `BrandUpdate.passes` for the
            // same rule applied to filtering.
            if let state = FeedState(update: update, profile: sizes.profile) {
                DataLabel(text: state.text, size: 10, color: state.color)
            }

            Text(update.title)
                .font(.editorial(14))
                .foregroundStyle(Color.ink)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            if let price = update.priceText {
                Text(price)
                    .font(.data(12, .medium))
                    .foregroundStyle(Color.ink)
            }

            // Capped and wrapping. A sneaker runs 3.5–16.5, which measures far wider than
            // half a phone — and a `VStack` is as wide as its widest child, so one
            // unwrapped run would set the width of the entire grid. See `SizeRun(wraps:)`.
            SizeRun(
                entries: SizeRun.entries(for: update, profile: sizes.profile),
                size: 10,
                limit: 6
            )
        }
        .contentShape(.rect)
        .productLink(update)
        .contextMenu { UpdateMenu(update: update) }
    }
}

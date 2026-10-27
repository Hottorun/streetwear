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
    @Environment(FollowFilterPrompt.self) private var followPrompt: FollowFilterPrompt

    /// The collection, so "KEPT" can be answered without walking the catalogue — see
    /// `savedFromBrand`. Bounded by how much somebody has kept, which is the size of the
    /// answer rather than the size of the store.
    @Query(sort: \SavedItem.savedAt, order: .reverse) private var saves: [SavedItem]

    @Bindable var brand: Brand

    /// Which of the three counts the grid is currently showing.
    @State private var lens: Lens = .catalogue

    /// A mode that has been chosen and not yet confirmed by the server, drawn as chosen so
    /// the tap visibly landed; and what went wrong if it was refused.
    @State private var pendingMode: FollowMode?
    @State private var modeError: String?
    /// Editing which part of the brand reaches you — `FollowFilterView`, beside the mode.
    @State private var isEditingFilter = false

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
                if let host = brand.shopURL?.host()?.replacingOccurrences(of: "www.", with: "") {
                    DataLabel(text: host.uppercased(), size: 10)
                }
                if let shop = shopLine {
                    DataLabel(text: shop, size: 9)
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

    /// Which of the brand's shops this page is showing, and what it prices in — "UNITED
    /// KINGDOM SHOP · GBP" where a country's shop serves this phone, "EUROPE SHOP · EUR" for a
    /// regional one (`ShopReach`), "MAIN SHOP · USD" otherwise; the host above it names which
    /// site that is. The one place the location setting is visible, so it is said where it
    /// changes something rather than promised on the setting. See `LocationSetting`.
    private var shopLine: String? {
        if let reach = brand.storefrontReach {
            let shop = switch reach {
            case .country(let code): "\(LocationSetting.name(of: code).uppercased()) SHOP"
            case .europe: "EUROPE SHOP"
            case .countries(let count): "SHOP FOR \(count) COUNTRIES"
            }
            return [shop, brand.currencyCode]
                .compactMap { $0 }
                .joined(separator: " · ")
        }
        return brand.currencyCode.map { "MAIN SHOP · \($0)" }
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
            brand.shopURL.map { ("SHOP", "arrow.up.right", $0) },
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

    /// How much of this brand reaches you, then whether you follow it at all.
    ///
    /// Words, not switches. These are rare, deliberate and reversible — and a toggle at the
    /// top of the page made them the most prominent controls on a screen that is about
    /// looking at clothes.
    ///
    /// **The mode replaced a mute, and the mute was the wrong shape twice.** It was one row,
    /// so "a brand that posts forty times a week" had two answers — put up with it, or stop
    /// following — when what somebody wants of H&M is to watch its prices and not its daily
    /// arrivals. And it was a flag on this phone that the server had never heard of, so a
    /// muted brand's push was composed, sent and delivered regardless, and only dropped if
    /// the app happened to be open. See `FollowMode`.
    ///
    /// Three rows, the chosen one ticked, each saying in its own line what it lets through —
    /// the feed is the place a mode is felt, and a mode that hides things without saying so
    /// is indistinguishable from a broken follow.
    private var followingRow: some View {
        VStack(alignment: .leading, spacing: 0) {
            if brand.followed {
                section("What reaches you", "WATCHED ITEMS ALWAYS ALERT, WHATEVER YOU PICK") {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(FollowMode.allCases) { mode in
                            modeRow(mode)
                        }
                        filterRow
                        if let modeError {
                            DataLabel(text: modeError, size: 9, color: .signal)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.horizontal, 20)
                                .padding(.vertical, 10)
                        }
                    }
                }
                .padding(.top, 22)
                .padding(.bottom, 14)
                .overlay(alignment: .bottom) { Rule().padding(.horizontal, 20) }
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

    /// Which part of the brand the mode applies to — all of it, or what the follow's filter
    /// lets through, said the way the dialog reads it back. Under the modes because it
    /// narrows whichever one is chosen; a quiet brand has nothing for it to narrow.
    @ViewBuilder
    private var filterRow: some View {
        let reading = brand.followFilter?.reading ?? []
        Button { isEditingFilter = true } label: {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Which pieces")
                        .font(.data(12, .medium))
                        .foregroundStyle(Color.ink)
                    DataLabel(
                        text: reading.isEmpty
                            ? "ALL OF IT · OR ONLY SOME CATEGORIES, IN YOUR OWN WORDS"
                            : "ONLY " + reading.joined(separator: " · ").uppercased() + " · SALES ALWAYS",
                        size: 9
                    )
                    .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 12)
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.muted)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .contentShape(.rect)
        }
        .buttonStyle(.borderless)
        .disabled(brand.followMode == .quiet)
        .opacity(brand.followMode == .quiet ? 0.5 : 1)
        .sheet(isPresented: $isEditingFilter) {
            FollowFilterView(brand: brand, isNewFollow: false) { isEditingFilter = false }
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
    }

    /// One mode, as a line you can pick. The chosen one is set in ink and ticked; the others
    /// are muted, the same two weights `actionRow` uses for a setting that is on and off.
    private func modeRow(_ mode: FollowMode) -> some View {
        let isChosen = (pendingMode ?? brand.followMode) == mode
        return Button { choose(mode) } label: {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(mode.title)
                        .font(.data(12, .medium))
                        .foregroundStyle(isChosen ? Color.ink : Color.muted)
                    DataLabel(text: mode.detail, size: 9)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 12)
                if isChosen {
                    if pendingMode == mode {
                        ProgressView().controlSize(.mini)
                    } else {
                        Image(systemName: "checkmark")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Color.ink)
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .contentShape(.rect)
        }
        .buttonStyle(.borderless)
        .disabled(pendingMode != nil)
        .accessibilityAddTraits(isChosen ? .isSelected : [])
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

    /// Changes the mode where `Notifier` can see it, then here — see
    /// `RemoteSync.setFollowMode`. Refused means unchanged, and the page says so rather
    /// than showing a choice the lock screen is not honouring.
    private func choose(_ mode: FollowMode) {
        guard mode != brand.followMode, pendingMode == nil else { return }
        pendingMode = mode
        modeError = nil
        Task {
            do {
                try await remote.setFollowMode(mode, for: brand)
            } catch {
                modeError = "NOT CHANGED — \(error.localizedDescription.uppercased())"
            }
            pendingMode = nil
        }
    }

    /// The server decides what gets polled, so following has to be recorded there, not
    /// just flagged locally.
    private func syncFollowState() {
        guard settings.isConfigured, let id = brand.remoteID else {
            // Standalone, following again is the whole follow — and it asks what to see, as
            // every new follow does. In server mode `RemoteSync.follow` asks.
            if brand.followed { followPrompt.ask(brandID: brand.id) }
            return
        }
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

// MARK: - Follow modes, in words

/// What each mode is called and what it lets through, for the two places that print one:
/// the brand page, where it is chosen, and the brand list, where a quiet brand has to be
/// findable as quiet. Presentation, so it lives with the app rather than beside the rule in
/// `StreetwCore` — the server never prints a mode.
extension FollowMode {
    var title: String {
        switch self {
        case .everything: "Everything"
        case .salesOnly: "Sales only"
        case .quiet: "Quiet"
        }
    }

    /// Said as what reaches the feed, because that is where a mode is felt. The push half
    /// follows from it — nothing is ever pushed that the feed would not have shown.
    var detail: String {
        switch self {
        case .everything: "DROPS, RESTOCKS, SALES AND PRICE CUTS · ALERTS FOR DROPS AND SALES"
        case .salesOnly: "ONLY SALES AND PRICE CUTS · ALERTS WHEN A SALE STARTS"
        case .quiet: "NOTHING IN YOUR FEED, NO ALERTS · STILL SHAPES YOUR TASTE"
        }
    }

    /// The word the brand list adds to a row, or nil for the default — a list that labels
    /// every row *Everything* is a list that has stopped saying anything.
    var listLabel: String? {
        switch self {
        case .everything: nil
        case .salesOnly: "SALES ONLY"
        case .quiet: "QUIET"
        }
    }
}

// MARK: - One garment on the brand's shelf

/// A product as the brand page draws it: photograph, what is urgent about it, name, price,
/// size run.
///
/// Unlike a feed card it carries the size run as well as the price: here there is one brand,
/// the grid *is* the page, and the price and the size run are the two facts that decide
/// whether to tap. The accent rule marks your size: the size run says it in full, and the
/// rule is what makes it findable while scrolling.
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

            if let price = update.priceLabel {
                Text([price, update.percentOffText].compactMap { $0 }.joined(separator: " "))
                    .font(.data(12, .medium))
                    .foregroundStyle(Color.ink)
            }

            // Capped and wrapping. A sneaker runs 3.5–16.5, which measures far wider than
            // half a phone — and a `VStack` is as wide as its widest child, so one
            // unwrapped run would set the width of the entire grid. See `SizeRun(wraps:)`.
            SizeRun(
                entries: SizeRun.entries(for: update, profile: sizes.profile),
                size: 10,
                limit: 6,
                wraps: true
            )
        }
        .contentShape(.rect)
        .productLink(update)
        .contextMenu { UpdateMenu(update: update) }
    }
}

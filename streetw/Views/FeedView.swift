// FeedView.swift
// The hype room: what changed, newest brand first.
//
// Laid out as a magazine front page rather than a list — each brand gets a wordmark
// header, one lead item printed large, and the rest as briefs. That is not only a look:
// a brand can publish an entire collection in one poll (Kith wrote 250 items in a single
// sweep), and a flat list of 250 equal rows is unreadable. Lead-plus-briefs stays
// legible at any batch size, and the "+N more" link is the honest overflow.

import StreetwCore
import SwiftData
import SwiftUI

struct FeedView: View {
    @Environment(\.modelContext) private var context
    @Environment(SyncEngine.self) private var engine: SyncEngine
    @Environment(SizeProfileStore.self) private var sizes: SizeProfileStore
    @Environment(RemoteSync.self) private var remote: RemoteSync
    @Environment(ServerSettings.self) private var settings: ServerSettings
    @Environment(BrandSuggestions.self) private var suggestions: BrandSuggestions

    @Query(filter: #Predicate<Brand> { $0.followed }, sort: \Brand.name)
    private var brands: [Brand]

    @State private var isShowingCalendar = false
    @State private var isShowingWatches = false
    @State private var isShowingMarkdowns = false

    /// Only active watches count — a bell that stays filled forever after one has fired
    /// stops meaning anything.
    @Query(filter: #Predicate<StockWatch> { $0.firedAt == nil })
    private var activeWatches: [StockWatch]

    private var watchCount: Int { activeWatches.count }

    /// Whether the calendar has anything in it.
    ///
    /// The two sheet icons in this toolbar are, for most people most of the time, doors
    /// onto empty rooms — and neither said so, so opening them was a coin toss. The bell
    /// already filled when a watch existed; this is the same courtesy for the other one.
    /// A brand locked for a drop is the strongest signal there is that something is about
    /// to happen, so it earns the accent rather than a plain dot.
    private var isLockedSomewhere: Bool { brands.contains { $0.isLockedForDrop } }

    /// Markdowns still inside the window `MarkdownsView` shows.
    private var markdownCount: Int {
        let cutoff = Date().addingTimeInterval(-MarkdownsView.window)
        let profile = sizes.profile
        return brands.reduce(0) { total, brand in
            total + brand.updates.count {
                $0.kind == .priceDrop && $0.publishedAt >= cutoff && $0.passes(profile)
            }
        }
    }

    /// How many briefs sit under a lead before the rest go behind "+N more".
    private static let briefLimit = 6

    /// Gender is the only filter the feed applies now.
    ///
    /// The "my size" toggle is gone. It lived in the toolbar as a fourth icon competing
    /// with watching, upcoming and refresh, and it was the wrong shape for the job:
    /// something sold out in your size today is back in it tomorrow, and a filter that
    /// *hides* it means you never find out. The size profile still does its real work —
    /// the size run marks your sizes, the state line says "in your size", and a watch
    /// tells you when one returns.
    private var isFilteringGender: Bool {
        sizes.profile.gender != .everything
    }

    /// Computed once per render rather than per access.
    ///
    /// This was a computed property, and every one of `groups`, `totalNew` and the two
    /// `groups.isEmpty` checks in `body` re-walked every update of every brand — four full
    /// passes over as many as 400 rows per brand on each render. SwiftUI evaluates `body`
    /// often and for reasons that have nothing to do with this data.
    private struct Feed {
        var groups: [BrandGroup] = []
        var total: Int = 0
    }

    private var feed: Feed {
        let profile = sizes.profile
        let filterGender = isFilteringGender

        let groups = brands
            .compactMap { brand -> BrandGroup? in
                var unseen = brand.updates.filter { !$0.isSeen }
                if filterGender {
                    // `passes`, not an inline `allows` — this screen and `BrandFeedView`
                    // show the same items and drifted apart precisely because each had its
                    // own copy of the rule.
                    unseen = unseen.filter { $0.passes(profile) }
                }
                guard !unseen.isEmpty else { return nil }
                return BrandGroup(
                    brand: brand,
                    updates: unseen.sorted(by: BrandUpdate.newestFirst)
                )
            }
            .sorted { ($0.latest ?? .distantPast) > ($1.latest ?? .distantPast) }

        return Feed(groups: groups, total: groups.reduce(0) { $0 + $1.updates.count })
    }

    var body: some View {
        // One evaluation, reused by every branch below.
        let feed = self.feed

        return NavigationStack {
            // One path, always. There is no state of this screen where a list of brands
            // worth following is the wrong thing to show — least of all the empty one,
            // where somebody has nothing at all and the old copy just told them to go
            // find a brand themselves.
            stream(feed)
                .background(Color.paper)
            .navigationTitle("Feed")
            .toolbarTitleDisplayMode(.inlineLarge)
            // Registered once, here, for every card in this stack — including the ones on
            // `BrandFeedView`, which is pushed onto it. See `productLink`.
            .appDestinations()
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    // A filled bell, and **no number on it**.
                    //
                    // The count was there because "watching 4 things" and "watching
                    // something" are different states — true, and not worth what it cost.
                    // A badge is the platform's unread mark: it says *something has
                    // happened, deal with it*, and it clears when you do. This one says
                    // neither. It is the number of watches you deliberately set, so it goes
                    // up when you ask for more and comes down only when a restock lands or
                    // you give up — which can be weeks. A permanent red 4 in the corner of
                    // the feed is an alarm about your own settings, nagging hardest exactly
                    // when the thing you are waiting for is slowest to come back.
                    //
                    // The bell fills, which is the honest amount to say: something is on
                    // watch, and the list is one tap away. A watch that actually fires
                    // arrives as a push and as a card in the feed — the two places news
                    // belongs.
                    Button("Watching", systemImage: watchCount > 0 ? "bell.fill" : "bell") {
                        isShowingWatches = true
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Upcoming", systemImage: isLockedSomewhere ? "calendar.badge.exclamationmark" : "calendar") {
                        isShowingCalendar = true
                    }
                    .foregroundStyle(isLockedSomewhere ? Color.signal : Color.ink)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    // Only once there is something to see. A markdown is the one event
                    // whose worth doesn't decay with the feed's ordering, so it gets a
                    // standing list — but an always-present icon onto an empty room is
                    // exactly what the other two were criticised for.
                    if markdownCount > 0 {
                        Button("Marked down", systemImage: "arrow.down.right") {
                            isShowingMarkdowns = true
                        }
                        .badge(markdownCount)
                    }
                }
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
            .overlay(alignment: .bottom) { syncStatus }
            .sheet(isPresented: $isShowingCalendar) { DropCalendarView() }
            .sheet(isPresented: $isShowingWatches) { WatchesView() }
            .sheet(isPresented: $isShowingMarkdowns) { MarkdownsView() }
        }
        .tint(.ink)
    }

    /// What the feed is currently narrowed by, as one readable line. Nil when nothing is.
    private var narrowing: String? {
        isFilteringGender ? sizes.profile.gender.label : nil
    }

    /// True when there is unseen material but every bit of it was filtered away.
    private var filteredToNothing: Bool {
        guard isFilteringGender else { return false }
        return brands.contains { brand in brand.updates.contains { !$0.isSeen } }
    }

    private func stream(_ feed: Feed) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: []) {
                if feed.groups.isEmpty {
                    caughtUp
                } else {
                    masthead(feed)
                    ForEach(feed.groups) { group in
                        BrandSpread(group: group, briefLimit: Self.briefLimit) {
                            markSeen(group)
                        }
                    }
                }

                // Always the tail of the feed, not only its empty state. Finishing your
                // brands is the moment you have attention to spare, and "pull to refresh"
                // was the app's way of saying there is nothing else here.
                BrandRecommendations()
            }
            .padding(.bottom, 32)
        }
        .scrollIndicators(.hidden)
        // Keyed on the token so it reruns the moment registration completes — on a cold
        // launch this view appears before the device has one.
        .task(id: settings.token) { await suggestions.loadIfNeeded() }
    }

    /// The top of a feed with nothing in it. Short, because the recommendations under it
    /// are the actual answer to "what now".
    private var caughtUp: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(headline)
                .font(.editorial(22))
                .foregroundStyle(Color.ink)
            DataLabel(text: subhead)
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .padding(.bottom, 28)
    }

    private var headline: String {
        if brands.isEmpty { return "Nothing on watch yet" }
        return filteredToNothing ? "Nothing matches your filter" : "All caught up"
    }

    private var subhead: String {
        if brands.isEmpty { return "FOLLOW A BRAND AND STREETW STARTS WATCHING ITS CATALOG" }
        if filteredToNothing {
            return "SHOWING \(sizes.profile.gender.label.uppercased()) ONLY — CHANGE IT IN SETTINGS"
        }
        return engine.lastSyncedAt == nil && remote.lastSyncedAt == nil
            ? "PULL TO CHECK YOUR BRANDS FOR THE FIRST TIME"
            : "PULL TO REFRESH"
    }

    /// The count, set as a standfirst. Says what's true and how it's narrowed — no
    /// decoration, because it is the one piece of chrome above the photographs.
    private func masthead(_ feed: Feed) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("\(feed.total) new from \(feed.groups.count) \(feed.groups.count == 1 ? "brand" : "brands")")
                .font(.editorial(15))
                .foregroundStyle(Color.ink)
            if let narrowing {
                DataLabel(text: "FILTERED TO \(narrowing.uppercased())")
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 4)
        .padding(.bottom, 20)
    }

    @ViewBuilder
    private var syncStatus: some View {
        if engine.isSyncing, let progress = engine.progress {
            DataLabel(text: "CHECKING \(progress.uppercased())", color: .paper)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(Color.ink, in: Capsule())
                .padding(.bottom, 10)
                .transition(.opacity)
        }
    }

    /// Server mode when one is configured; otherwise the app polls sources itself.
    private func refresh() async {
        if settings.isConfigured {
            await remote.sync(sizes: sizes.profile)
        } else {
            await engine.syncAll()
        }
    }

    private func markSeen(_ group: BrandGroup) {
        for update in group.updates { update.isSeen = true }
        group.brand.lastOpenedAt = Date()
        try? context.save()
    }
}

// MARK: - One brand's spread

private struct BrandSpread: View {
    let group: BrandGroup
    let briefLimit: Int
    let onDismiss: () -> Void

    /// Releases this brand has just announced.
    ///
    /// Hoisted above the products rather than mixed in with them, because a collection is
    /// *about* those products — it is the headline and they are the contents, and a season
    /// announcement filed between two hoodies is the wrong way round. They also used to be
    /// the emptiest cards in the feed: a collection page rarely publishes a photograph, so
    /// it drew a grey square, a blank size run and no price.
    private var releases: [BrandUpdate] {
        group.updates.filter { $0.kind == .collection }
    }

    private var products: [BrandUpdate] {
        group.updates.filter { $0.kind != .collection }
    }

    /// The newest item *that has a photograph*. A lead is carried by its image, and the
    /// newest thing a brand posts is often a page change with nothing to show — leading on
    /// that wastes the biggest slot on the page.
    private var lead: BrandUpdate? {
        products.first { $0.primaryImageURL != nil } ?? products.first
    }

    private var briefs: [BrandUpdate] {
        Array(products.filter { $0.id != lead?.id }.prefix(briefLimit))
    }

    private var overflow: Int {
        max(0, products.count - (lead == nil ? 0 : 1) - briefs.count)
    }

    private let columns = [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14), GridItem(.flexible())]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Rule()
                .padding(.horizontal, 20)
                .padding(.bottom, 14)

            header

            ForEach(releases) { release in
                CollectionCard(update: release)
                    .padding(.bottom, 22)
            }

            if let lead {
                FeedLead(update: lead)
                    .padding(.bottom, briefs.isEmpty ? 0 : 20)
            }

            if !briefs.isEmpty {
                LazyVGrid(columns: columns, alignment: .leading, spacing: 16) {
                    ForEach(briefs) { update in
                        FeedTile(update: update)
                    }
                }
                .padding(.horizontal, 20)
            }

            if overflow > 0 {
                NavigationLink(value: BrandFeedRoute(brand: group.brand)) {
                    // Underlined so it reads as the link it is; a bare mono line looked
                    // like another caption.
                    DataLabel(text: "+\(overflow) MORE FROM \(group.brand.name.uppercased())", color: .ink)
                        .overlay(alignment: .bottom) {
                            Rectangle().fill(Color.ink).frame(height: 1).offset(y: 3)
                        }
                        .padding(.top, 16)
                        .padding(.horizontal, 20)
                }
            }
        }
        .padding(.bottom, 36)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            NavigationLink(value: BrandRoute(brand: group.brand)) {
                VStack(alignment: .leading, spacing: 5) {
                    Wordmark(name: group.brand.name, size: 15)
                    DataLabel(
                        text: group.headline.uppercased(),
                        color: group.brand.isLockedForDrop ? .signal : .muted
                    )
                }
            }

            Spacer(minLength: 0)

            if let latest = group.latest {
                DataLabel(text: Stamp.short(latest).uppercased())
            }

            Button(action: onDismiss) {
                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.muted)
                    .frame(width: 28, height: 28)
                    .overlay(Circle().stroke(Color.hairline, lineWidth: 0.5))
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Mark \(group.brand.name) seen")
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 14)
    }
}

struct BrandGroup: Identifiable {
    var brand: Brand
    var updates: [BrandUpdate]

    var id: UUID { brand.id }
    var latest: Date? { updates.first?.publishedAt }

    /// "12 new products", "3 restocked", "New FW26 collection" — the line the user reads.
    var headline: String {
        if brand.isLockedForDrop { return "Locked — drop incoming" }

        let counts = Dictionary(grouping: updates, by: \.kind)
            .mapValues(\.count)
            .sorted { $0.value > $1.value }

        guard let (kind, count) = counts.first else { return "Updated" }

        switch kind {
        case .product: return count == 1 ? "New product" : "\(count) new products"
        case .restock: return count == 1 ? "Restocked" : "\(count) restocked"
        case .collection: return updates.first(where: { $0.kind == .collection })?.title ?? "New collection"
        case .post: return count == 1 ? "New post" : "\(count) new posts"
        case .pageChange: return "Page changed"
        case .dropLock: return "Locked — drop incoming"
        case .priceDrop: return count == 1 ? "Price drop" : "\(count) price drops"
        }
    }
}

#Preview {
    FeedView()
        .modelContainer(PreviewData.container)
        .environment(PreviewData.engine)
}

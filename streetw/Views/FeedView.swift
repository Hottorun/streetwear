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

    /// **The unread queue, narrowed by the store rather than by walking it.**
    ///
    /// This screen used to query `Brand` and walk `brand.updates` for every followed brand,
    /// which faults in the entire catalogue — every product ever synced, read or not — on
    /// each evaluation of `body`. Measured on a real store that was 1.4s for the first build
    /// and 44–426ms for every rebuild after, and marking a brand read triggers a rebuild.
    /// That is the lag.
    ///
    /// A predicate on `isSeen` hands the same question to SQLite, which answers it from an
    /// index instead of by materialising thousands of objects. Sorted here too, so the
    /// grouping below inherits the order.
    @Query(
        filter: #Predicate<BrandUpdate> { !$0.isSeen },
        sort: [SortDescriptor(\BrandUpdate.publishedAt, order: .reverse)]
    )
    private var unseen: [BrandUpdate]

    /// Price drops inside the window `MarkdownsView` shows, counted for the toolbar badge.
    ///
    /// Its own query for the same reason: it asks about *read* rows too, so it cannot come
    /// out of `unseen`, and folding it into a walk of everything is what made that walk
    /// necessary in the first place.
    @Query private var markdowns: [BrandUpdate]

    init() {
        // **Narrowed on two stored columns, and the kind confirmed in Swift.**
        //
        // `kind` is a Codable enum and `#Predicate` over one is fragile, so it cannot do
        // the narrowing — but the date alone cannot either: a brand's first sync stamps its
        // whole back catalogue with today, so a thirty-day window is *the entire store* on a
        // freshly added brand, and counting a badge would walk all of it and run `passes`
        // over every row. `previousPriceAmount` is written only where `kind` is set to
        // `.priceDrop`, which makes it a faithful index for the question and reduces the
        // fetch to the handful of rows that could possibly answer it.
        //
        // It is a superset, not the answer: a marked-down product that later restocks keeps
        // the old price and stops being a markdown, so the kind is still checked below.
        //
        // The dismissal clause is not an optimisation — it is the rule that a count is
        // subject to the same filter as the list it counts. Without it, waving markdowns off
        // empties the sheet while the badge that opens it goes on claiming twelve, and a
        // number that disagrees with the page behind it reads as the number being broken.
        let cutoff = Date().addingTimeInterval(-MarkdownsView.window)
        _markdowns = Query(
            filter: #Predicate<BrandUpdate> {
                $0.publishedAt >= cutoff
                    && $0.previousPriceAmount != nil
                    && $0.markdownDismissedAt == nil
            }
        )
    }

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
    ///
    /// It is now **one** pass, and that is the fix for the visible lag when a brand is
    /// marked read. Marking writes a row per update and saves, which invalidates the
    /// `@Query` and re-renders — and this view was answering four more questions on the way
    /// back, each of them another full walk of the same to-many relationships:
    /// `markdownCount` counted every price drop in every brand, `filteredToNothing` looked
    /// for any unseen row anywhere, and the two above. Every one of those calls
    /// `BrandUpdate.passes`, which reads `gender`, which **re-runs the classifier over the
    /// title, tags and handle whenever the stored verdict is from another revision** — the
    /// steady state for anything the server classified. So dismissing one brand cost several
    /// thousand string classifications before a frame could be drawn. (`Classification`
    /// converges the stored answers in the background; this stops the render depending on
    /// that having happened.)
    private struct Feed {
        var groups: [BrandGroup] = []
        var total: Int = 0
        /// Markdowns still inside the window `MarkdownsView` shows.
        var markdowns: Int = 0
        /// Whether anything at all is unread, before the gender filter — the difference
        /// between "all caught up" and "your filter hid everything".
        var hasHiddenUnseen: Bool = false
    }

    private var feed: Feed {
        let profile = sizes.profile
        let filterGender = isFilteringGender

        var result = Feed()
        var byBrand: [UUID: [BrandUpdate]] = [:]
        var brandsByID: [UUID: Brand] = [:]

        // `unseen` is already narrowed by the store to rows with `isSeen == false`, so this
        // walks the unread queue rather than the catalogue. On a synced device those differ
        // by orders of magnitude.
        for update in unseen {
            guard let brand = update.brand, brand.followed else { continue }
            if filterGender, !update.passes(profile) {
                result.hasHiddenUnseen = true
                continue
            }
            byBrand[brand.id, default: []].append(update)
            brandsByID[brand.id] = brand
        }

        for (id, updates) in byBrand {
            guard let brand = brandsByID[id] else { continue }
            result.groups.append(
                BrandGroup(
                    brand: brand,
                    updates: BrandUpdate.oncePerProduct(updates),
                    sortKey: brand.activityKey
                )
            )
        }

        // Ordered on the brand's newest activity overall, **not** on its newest *unread*
        // item — and that distinction is the whole of a bug that made the feed feel broken.
        //
        // Sorting on the unread items means the sort key changes as you read them. Clear the
        // top card of a brand whose remaining unread things are older, and the brand's key
        // drops to that older date and the whole spread slides down the page, under brands
        // you had already dealt with. You are reading a list that reorders itself underneath
        // your thumb, and the item you wanted next is now somewhere else.
        //
        // A brand's newest activity does not move when you read something, so the spread
        // stays where it is until the brand itself publishes again. `latest` is still the
        // newest *unread* date, because that is what the header prints — the two questions
        // are different and were being answered by one value.
        result.groups.sort {
            $0.sortKey == $1.sortKey ? $0.brand.name < $1.brand.name : $0.sortKey > $1.sortKey
        }
        result.total = result.groups.reduce(0) { $0 + $1.updates.count }
        result.markdowns = markdowns.count { $0.kind == .priceDrop && $0.passes(profile) }
        return result
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
                    if feed.markdowns > 0 {
                        Button("Marked down", systemImage: "arrow.down.right") {
                            isShowingMarkdowns = true
                        }
                        .badge(feed.markdowns)
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

    private func stream(_ feed: Feed) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: []) {
                if feed.groups.isEmpty {
                    caughtUp(feed)
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
    private func caughtUp(_ feed: Feed) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(headline(feed))
                .font(.editorial(22))
                .foregroundStyle(Color.ink)
            DataLabel(text: subhead(feed))
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .padding(.bottom, 28)
    }

    private func headline(_ feed: Feed) -> String {
        if brands.isEmpty { return "Nothing on watch yet" }
        return feed.hasHiddenUnseen ? "Nothing matches your filter" : "All caught up"
    }

    private func subhead(_ feed: Feed) -> String {
        if brands.isEmpty { return "FOLLOW A BRAND AND STREETW STARTS WATCHING ITS CATALOG" }
        if feed.hasHiddenUnseen {
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

    /// Clearing one brand's spread.
    ///
    /// Animated for the same reason `BrandFeedView`'s checkmark is: a whole section of the
    /// page disappears, and without a transition that reads as the app stalling and then
    /// jumping rather than as the thing you asked for. The write itself is a row per update
    /// and one save — the cost that made this feel slow was never the writing, it was every
    /// question `body` asked on the way back. See `Feed`.
    private func markSeen(_ group: BrandGroup) {
        // **Every row the spread stood for, not only the ones drawn.** The group is
        // deduplicated to one card per garment, so a jacket that dropped and then restocked
        // contributes one tile and two unseen rows. Clearing the tile alone left the second
        // row unread, so the brand came straight back into the feed showing the same jacket
        // — the checkmark visibly failing to do the one thing it claims. The filter is
        // applied for the opposite reason: what a Menswear setting is hiding was never read
        // and must not be marked as though it had been.
        //
        // Read out of `unseen` rather than out of `brand.updates`. They answer the same
        // question here — every unread row of this brand — but the relationship is the
        // brand's *whole* catalogue, so touching it faults in every product ever synced
        // for it and then runs `passes` over all of them, on the tap whose slowness is the
        // complaint. `unseen` is already narrowed by the store and already in memory,
        // because it is what drew the spread being dismissed.
        let profile = sizes.profile
        let filterGender = isFilteringGender
        let brandID = group.brand.id
        withAnimation(.easeOut(duration: 0.22)) {
            for update in unseen where update.brand?.id == brandID {
                guard !filterGender || update.passes(profile) else { continue }
                update.isSeen = true
            }
            group.brand.lastOpenedAt = Date()
        }
        try? context.save()
    }
}

// MARK: - One brand's spread

private struct BrandSpread: View {
    let group: BrandGroup
    let briefLimit: Int
    let onDismiss: () -> Void

    /// How the spread is laid out, decided in one pass.
    ///
    /// These were five computed properties that read each other: `briefs` re-derived
    /// `lead`, which re-derived `products`, and `overflow` re-derived both — so drawing one
    /// spread filtered `group.updates` about six times, and `lead` walked the products
    /// calling `primaryImageURL` (which parsed every photograph of every product it passed)
    /// until one answered. Marking any brand read re-renders every visible spread.
    private struct Layout {
        /// Releases this brand has just announced.
        ///
        /// Hoisted above the products rather than mixed in with them, because a collection
        /// is *about* those products — it is the headline and they are the contents, and a
        /// season announcement filed between two hoodies is the wrong way round. They also
        /// used to be the emptiest cards in the feed: a collection page rarely publishes a
        /// photograph, so it drew a grey square, a blank size run and no price.
        var releases: [BrandUpdate] = []
        /// The newest item *that has a photograph*. A lead is carried by its image, and the
        /// newest thing a brand posts is often a page change with nothing to show — leading
        /// on that wastes the biggest slot on the page.
        var lead: BrandUpdate?
        var briefs: [BrandUpdate] = []
        var overflow = 0
    }

    private func layout() -> Layout {
        var result = Layout()
        var products: [BrandUpdate] = []
        for update in group.updates {
            if update.kind == .collection { result.releases.append(update) } else { products.append(update) }
        }

        result.lead = products.first(where: \.hasPhotograph) ?? products.first
        let leadID = result.lead?.id
        result.briefs = Array(products.lazy.filter { $0.id != leadID }.prefix(briefLimit))
        result.overflow = max(0, products.count - (result.lead == nil ? 0 : 1) - result.briefs.count)
        return result
    }

    private let columns = [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14), GridItem(.flexible())]

    var body: some View {
        let layout = layout()
        let (releases, lead, briefs, overflow) = (layout.releases, layout.lead, layout.briefs, layout.overflow)

        return VStack(alignment: .leading, spacing: 0) {
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

    /// Where this spread sits on the page: the brand's newest activity, read or not.
    ///
    /// Deliberately *not* derived from `updates`, which shrinks as things are read. Ties
    /// break on the name so two brands that published in the same second do not swap places
    /// between renders — the same reason `BrandUpdate.newestFirst` breaks its ties.
    var sortKey: Date = .distantPast

    var id: UUID { brand.id }

    /// The newest thing here you have not read — what the header stamps. A different
    /// question from `sortKey`, and answering both with one value is what made the feed
    /// reorder itself as you read it.
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

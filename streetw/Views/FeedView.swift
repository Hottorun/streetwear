// FeedView.swift
// The hype room: what happened, newest brand first.
//
// Laid out as a magazine front page rather than a list — each brand gets a wordmark
// header, and under it the *events* that landed. That is not only a look: a brand can
// publish an entire collection in one poll (Kith wrote 250 items in a single sweep), and
// a flat list of 250 equal rows is unreadable.
//
// **The unit is the event, not the product**, and that is the correction this file has
// been through. It used to lead each brand with its newest *garment* printed large and
// print the reason for it as a caption — which shaped a news feed like a product list,
// on a screen whose volume is mostly restocks and re-shelvings that are deliberately not
// worth a push. So a brand's spread is now a short stack of `Story`s, ranked by
// `UpdateKind.newsRank` — a lock, a release, a drop, then the quiet kinds — each stating
// what happened and carrying the garments as its evidence. The lead photograph survives,
// but it belongs to the top story and sits *under* its headline rather than above it.
//
// **Every count on the page opens the list it counts.** A story headline is a link into
// that story alone, and the foot of the spread carries one more to the brand's queue
// entire. The rule this replaces said the opposite — one link per brand, because four
// links under four headlines is a menu — and it was right about *adding* four controls and
// wrong about what it cost: the spread stated two or three different pieces of news, drew
// three tiles of each, and offered one way out, to all of them mixed together. So it could
// name a thing and not open it. Nothing was added to fix that; the sentence already on the
// page became the door (`headline`). See also the note there on why the foot now says the
// total rather than a remainder — it always went to the total.

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
    @State private var isAddingBrand = false
    @State private var isShowingBrands = false

    /// The size profile is set in exactly two places — onboarding step one, which is
    /// skippable and never returns, and a sheet behind the gear in the Style tab's toolbar.
    /// So somebody who skipped the step had the feature quietly switched off with nothing in
    /// the app mentioning it again, and the feed's own "CHANGE IT IN SETTINGS" named a screen
    /// without saying where it is. The lines that talk about the profile now open it.
    @State private var isShowingSettings = false
    /// Bumped whenever a brand's spread is cleared, purely to drive the haptic. A counter
    /// rather than a flag because two brands cleared in a row are two events.
    @State private var clearedBrands = 0

    /// Every watch, because the icon asks two questions of them.
    ///
    /// Whether to draw it at all is about *any* watch — a fired one is still something to
    /// look at, and `WatchesView` keeps it under "CAME BACK". Whether it is **filled** is
    /// about the pending ones only: a bell that stays filled forever after one has fired
    /// stops meaning anything.
    ///
    /// Unpredicated, which is a rule this file otherwise keeps: a `@Query` with no predicate
    /// subscribes the view to the whole table. It is allowed here because the table is
    /// watches somebody set by hand — tens, not the thousands `BrandUpdate` runs to — and
    /// two predicated queries over the same small table would cost more than the one.
    @Query private var watches: [StockWatch]

    private var pendingWatches: Int { watches.count { $0.firedAt == nil } }

    /// Whether the calendar has anything in it.
    ///
    /// **The one icon that is always drawn**, and it has to be: the other two are ways back
    /// to lists made somewhere else, where this is the only route to the drop calendar at
    /// all. Showing it only once a drop is written down would mean it appearing only after
    /// you had found the way to write one down — which is through this icon.
    ///
    /// So the courtesy it gets instead is saying whether the room is empty before you open
    /// it. A brand locked for a drop is the strongest signal there is that something is
    /// about to happen, so it earns the accent rather than a plain dot.
    private var isLockedSomewhere: Bool { brands.contains { $0.isLockedForDrop } }

    /// How many garments one story prints before the rest go behind "+N more".
    ///
    /// One row of the three-column grid. It used to be six, under a single lead, because
    /// the spread was one undifferentiated pile of a brand's output; now a brand publishing
    /// a drop *and* a batch of restocks draws two rows rather than one long one, and the
    /// budget is spent saying two things instead of six times over saying one.
    private static let storyLimit = 3

    /// Gender is the only filter the feed applies now.
    ///
    /// The "my size" toggle is gone. It lived in the toolbar as a fourth icon competing
    /// with watching, upcoming and the refresh button that has since gone the same way,
    /// and it was the wrong shape for the job:
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
                .sensoryFeedback(.success, trigger: clearedBrands)
            .navigationTitle("Feed")
            .toolbarTitleDisplayMode(.inlineLarge)
            // Registered once, here, for every card in this stack — including the ones on
            // `BrandFeedView`, which is pushed onto it. See `productLink`.
            .appDestinations()
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    // **Only once a watch exists**, the rule `MarkdownsView`'s icon already
                    // followed and the one this toolbar was breaking three times over. A
                    // watch is never *set* from here — it is set on a product page, from the
                    // save confirmation, from a sold-out share — so this icon is the way
                    // back to a list, not the way into a feature, and until somebody has
                    // asked to be told about something it opens an empty room. Hiding it
                    // costs nothing and buys the feed a quieter top edge for everybody who
                    // has never used it.
                    //
                    // The test is *any* watch, not any **active** one: `WatchesView` shows
                    // the ones that fired under "CAME BACK", which is the payoff, and an icon
                    // that vanished the moment the thing you were waiting for arrived would
                    // hide exactly the news it exists to carry.
                    //
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
                    if !watches.isEmpty {
                        Button("Watching", systemImage: pendingWatches > 0 ? "bell.fill" : "bell") {
                            isShowingWatches = true
                        }
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
            }
            // The only way to ask by hand, and the only one that was ever needed. See
            // `FeedRefresh`: coming back to the app is what refreshes the feed, and this is
            // the gesture for not waiting. A pull is somebody saying "look now", so it is
            // never throttled.
            .refreshable {
                await FeedRefresh.run(
                    remote: remote,
                    engine: engine,
                    settings: settings,
                    sizes: sizes
                )
            }
            .overlay(alignment: .bottom) { syncStatus }
            .sheet(isPresented: $isShowingCalendar) { DropCalendarView() }
            .sheet(isPresented: $isShowingWatches) { WatchesView() }
            .sheet(isPresented: $isShowingMarkdowns) { MarkdownsView() }
            .sheet(isPresented: $isAddingBrand) { AddBrandView() }
            .sheet(isPresented: $isShowingBrands) { BrandsView() }
            .sheet(isPresented: $isShowingSettings) { SettingsSheet() }
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
                brandRail(feed)

                syncTrouble

                if feed.groups.isEmpty {
                    caughtUp(feed)
                } else {
                    masthead(feed)
                    ForEach(feed.groups) { group in
                        BrandSpread(group: group, storyLimit: Self.storyLimit) {
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

    // MARK: - The brands you follow

    /// **The directory, as a rail rather than as a tab.**
    ///
    /// Brands had a tab of their own and did not earn one. It was a list of names — no news,
    /// no photographs, nothing that changes — sitting beside three tabs that are all about
    /// change, and the feed below already groups by brand with every wordmark opening the
    /// same page. A directory is navigation, and navigation is not a destination.
    ///
    /// What the tab did that the feed could not is the whole reason this exists rather than
    /// being deleted outright: it was the only way to reach a brand that has published
    /// **nothing unread**, which is most of them most of the time, and the only way to add
    /// one. Both are here now, at the head of the page they are about.
    ///
    /// Three deliberate choices. It is **alphabetical, never by activity** — a rail that
    /// reorders as brands publish is a set of targets that move under the thumb, which is
    /// the fault `FeedView`'s brand ordering and `DiscoverDeck.pinningRead` are both written
    /// against, and this is the one strip on the page whose job is to be aimed at. The dot
    /// is a **mark, not a number**: the count is stated by the spread below and by the brand
    /// page, and a third figure to keep in agreement buys nothing. And a horizontal scroller
    /// is acceptable here for the reason `BrandDetailView`'s carousels were not — a rail of
    /// marks is skimmed at a glance, where a strip of *garments* could only be read one and
    /// a half tiles at a time.
    ///
    /// `BrandsView` survives behind "ALL" because it holds the one thing a mark cannot say:
    /// which sources a brand is watched with, and whether any of them is failing.
    private func brandRail(_ feed: Feed) -> some View {
        // Which brands are shouting. Read off the groups that were just built rather than
        // counted again — they are already narrowed by `passes`, so a brand whose entire
        // unread queue is hidden by the gender filter is silent here too, which is the rule
        // that a mark is subject to the same filter as the list it stands for.
        let shouting = Set(feed.groups.map(\.brand.id))

        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                DataLabel(text: "YOUR BRANDS")
                Spacer(minLength: 0)
                if !brands.isEmpty {
                    Button { isShowingBrands = true } label: {
                        DataLabel(text: "ALL \(brands.count)", color: .ink)
                            .overlay(alignment: .bottom) {
                                Rectangle().fill(Color.ink).frame(height: 1).offset(y: 3)
                            }
                    }
                    .buttonStyle(.borderless)
                }
            }
            .padding(.horizontal, 20)

            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: 12) {
                    // **First, not last.** It sat at the tail on the theory that the brands
                    // are the subject and adding one is the afterthought — which is true of
                    // the rail and false of the control. The rail scrolls, so the tail is
                    // wherever the last brand happens to be: with a dozen followed, adding
                    // one meant swiping to the end of a strip to find a button that never
                    // moves relative to anything a person can see. At the head it is in the
                    // same place on every launch and at every collection size, which is what
                    // a control you reach for by muscle memory needs to be.
                    addTile
                    ForEach(brands) { brand in
                        NavigationLink(value: BrandRoute(brand: brand)) {
                            railTile(brand, isShouting: shouting.contains(brand.id))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 20)
                // **Inside the ScrollView, and it has to be.** The unread dot is offset
                // outside the monogram's bounds (`x: 3, y: -3`) so the paper ring strikes it
                // out of the tile — and a `ScrollView` clips its content, so with no vertical
                // padding the tile's top edge *was* the content's top edge and about 3pt of
                // every 8pt dot was sliced flat, ring and all. The `.padding(.top, 4)` below
                // is on the outer `VStack`, outside the scroll view, and does nothing for it.
                // `.scrollClipDisabled()` would also work and lets tiles spill past the left
                // and right margins, which is the clip we want to keep.
                .padding(.top, 6)
            }
            .scrollIndicators(.hidden)
        }
        .padding(.top, 4)
        .padding(.bottom, 28)
    }

    private func railTile(_ brand: Brand, isShouting: Bool) -> some View {
        VStack(spacing: 6) {
            BrandMonogram(name: brand.name, logoURL: brand.logoURL, size: 46)
                .overlay(alignment: .topTrailing) {
                    // A locked storefront earns the mark whether or not anything is unread:
                    // it is the strongest signal in the app and the moment somebody most
                    // wants the page.
                    if isShouting || brand.isLockedForDrop {
                        Circle()
                            .fill(Color.signal)
                            .frame(width: 8, height: 8)
                            // Struck out of the paper rather than drawn on the logo, so the
                            // mark reads at the corner of a light tile in either appearance.
                            .overlay(Circle().stroke(Color.paper, lineWidth: 2))
                            .offset(x: 3, y: -3)
                    }
                }
            Wordmark(name: brand.name, size: 8, color: .muted)
        }
        .frame(width: 58)
    }

    /// Adding a brand, where the brands are. It was a toolbar button on a tab that no longer
    /// exists, and the feed's toolbar already carries four controls — a fifth would be
    /// folded into an overflow menu, which is where a control goes to be forgotten.
    private var addTile: some View {
        Button { isAddingBrand = true } label: {
            VStack(spacing: 6) {
                Rectangle()
                    .fill(Color.clear)
                    .frame(width: 46, height: 46)
                    .overlay {
                        Image(systemName: "plus")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(Color.ink)
                    }
                    .overlay(Rectangle().stroke(Color.hairline, lineWidth: 1))
                DataLabel(text: "ADD", size: 8)
            }
            .frame(width: 58)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Add a brand")
    }

    /// The top of a feed with nothing in it. Short, because the recommendations under it
    /// are the actual answer to "what now".
    private func caughtUp(_ feed: Feed) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(headline(feed))
                .font(.editorial(22))
                .foregroundStyle(Color.ink)
            if feed.hasHiddenUnseen {
                settingsLink(subhead(feed))
            } else {
                DataLabel(text: subhead(feed))
            }
            sizePrompt
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
        // Points at the rail directly above rather than at the abstraction. The one control
        // that answers this sentence is eight points away and is the only thing on screen.
        if brands.isEmpty { return "TAP ADD AND STREETW STARTS WATCHING A BRAND'S CATALOG" }
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
                settingsLink("FILTERED TO \(narrowing.uppercased())")
            }
            sizePrompt
        }
        .padding(.horizontal, 20)
        .padding(.top, 4)
        .padding(.bottom, 20)
    }

    /// A `DataLabel` that opens Settings, underlined so it reads as a door rather than as a
    /// statement. Used for every line on this page that describes the profile: naming a
    /// screen somebody cannot find is the same as not naming it.
    private func settingsLink(_ text: String) -> some View {
        Button { isShowingSettings = true } label: {
            DataLabel(text: text, color: .ink)
                .overlay(alignment: .bottom) {
                    Rectangle().fill(Color.hairline).frame(height: 1).offset(y: 3)
                }
        }
        .buttonStyle(.borderless)
    }

    /// The one mention of sizes anywhere outside onboarding and the gear.
    ///
    /// Skipping step one leaves every ladder empty, and an empty profile draws no vermilion
    /// rule on anything — the size feature is simply off, silently, for somebody who tapped
    /// Skip once weeks ago. It says nothing when the profile has been filled in, so it is a
    /// prompt rather than a permanent piece of chrome.
    @ViewBuilder
    private var sizePrompt: some View {
        if sizes.profile.isEmpty, !brands.isEmpty {
            settingsLink("SET YOUR SIZES AND RESTOCKS IN THEM ARE RULED IN VERMILION")
                .padding(.top, 2)
        }
    }

    /// **The one thing the refresh button did that the pull does not.**
    ///
    /// A spinner in the toolbar was, for the sync it replaced, the only sign the app was
    /// doing anything — and now that a refresh happens on its own when you come back to the
    /// app (`FeedRefresh`), a check nobody asked for needs saying more than one they did:
    /// a pull already has the platform's own spinner attached to the finger that started it.
    ///
    /// It answers for the remote sync too, which it never used to. Standalone the pass names
    /// the brand it is on, because it is long and moves visibly through them; against a
    /// server it is one request with nothing to narrate, so it says only that it is looking.
    /// Silence would be the same screen as "nothing happened", which is the state this is
    /// specifically distinguishing itself from.
    /// **The one place in the app that can say a sync failed.**
    ///
    /// `RemoteSync.lastError` and `SyncEngine.lastError` were both set on every failure path
    /// and read by nothing a person can see — `BackgroundRefresh` consulted one of them as a
    /// boolean and that was the entire readership. So a refused credential, a dead network, a
    /// server mid-deploy and *genuinely nothing happened* were one screen: "All caught up",
    /// with the app quietly not working. An app that watches things on your behalf has to be
    /// able to say when it has stopped watching.
    ///
    /// Under the rail rather than over it, because the rail is the subject of the page and
    /// this is a note about the page's freshness. It clears itself: `lastError` is nil'd at
    /// the top of every sync, so the next one that works takes the line away without anybody
    /// dismissing anything.
    ///
    /// The retry is here and not only in the pull, because somebody who has just been told
    /// the app could not reach the server should not have to guess that a gesture is the
    /// remedy.
    @ViewBuilder
    private var syncTrouble: some View {
        // Whichever engine is actually doing the work, the same branch `FeedRefresh` takes.
        // Reading both and preferring one would print a standalone failure at somebody who
        // has since been switched to a server, about a pass that no longer runs.
        let trouble = settings.isConfigured ? remote.lastError : engine.lastError
        if let trouble, !isSyncingNow {
            VStack(alignment: .leading, spacing: 6) {
                DataLabel(text: "COULDN'T REACH STREETW", color: .signal)
                Text(trouble)
                    .font(.editorial(15))
                    .foregroundStyle(Color.ink)
                    .fixedSize(horizontal: false, vertical: true)
                Button {
                    Task {
                        await FeedRefresh.run(
                            remote: remote,
                            engine: engine,
                            settings: settings,
                            sizes: sizes
                        )
                    }
                } label: {
                    DataLabel(text: "TRY AGAIN", color: .ink)
                        .overlay(alignment: .bottom) {
                            Rectangle().fill(Color.ink).frame(height: 1).offset(y: 3)
                        }
                }
                .buttonStyle(.borderless)
                .padding(.top, 2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .overlay(alignment: .leading) {
                Rectangle().fill(Color.signal).frame(width: 2)
            }
            .padding(.bottom, 24)
        }
    }

    private var isSyncingNow: Bool { engine.isSyncing || remote.isSyncing }

    @ViewBuilder
    private var syncStatus: some View {
        if isSyncingNow {
            DataLabel(
                text: engine.progress.map { "CHECKING \($0.uppercased())" } ?? "CHECKING",
                color: .paper
            )
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Color.ink, in: Capsule())
            .padding(.bottom, 10)
            .transition(.opacity)
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
        // Clearing a brand is the same act as swiping one card away, done to forty of them
        // at once — and only the swipe confirmed itself in the hand (`QuickSave`). So the
        // small, deliberate gesture had a response and the large, irreversible-feeling one
        // was silent, which is the wrong way round: this is the tap most likely to be
        // followed by "did that work?". Same `.success` as the swipe, because it is the
        // same event.
        clearedBrands += 1
    }
}

// MARK: - One brand's spread

private struct BrandSpread: View {
    @Environment(SizeProfileStore.self) private var sizes: SizeProfileStore

    let group: BrandGroup
    /// How many garments one story prints before the rest fold into "+N more". One row of
    /// the three-column grid: a story is evidence for a sentence, not a catalogue, and the
    /// brand page is one tap away for anybody who wants the whole of it.
    let storyLimit: Int
    let onDismiss: () -> Void

    /// How the spread is laid out, decided in one pass.
    ///
    /// The predecessor of this was five computed properties that read each other, so
    /// drawing one spread filtered `group.updates` about six times and walked the products
    /// calling `primaryImageURL` (which parses every photograph of every product it passes)
    /// until one answered. Marking any brand read re-renders every visible spread, so this
    /// is on the path whose slowness is the complaint. One pass, and the result is a value.
    private struct Layout {
        /// Releases this brand has just announced, drawn as `CollectionCard`s.
        ///
        /// Their own list rather than a `Story`, because a release is the one update that is
        /// *about* other updates and already has a card that draws it out of its contents.
        /// Above the rest, because it is the headline and they are what is in it.
        var releases: [BrandUpdate] = []
        /// What happened, ranked. Never empty when there is anything to show.
        var stories: [Story] = []
        /// The garment printed large, drawn under the headline of whichever story it came
        /// out of (`leadIndex`). Nil whenever no *sudden* story has a photograph to give it,
        /// which is the common case for a brand whose news is a batch of restocks. A lead is
        /// carried by its picture, and the newest thing a brand posts is often a page change
        /// with nothing to show — leading on that wastes the biggest slot on the page.
        var lead: BrandUpdate?
        /// How much of this brand's queue is not drawn above — **whether** to offer the
        /// whole of it, not what the offer says. The link prints the total, because the
        /// total is what it opens; this only decides that there is something left worth
        /// opening it for.
        var overflow = 0
    }

    /// One thing that happened to this brand, and the garments that are evidence of it.
    private struct Story: Identifiable {
        var kind: UpdateKind
        /// Everything of this kind in the spread — the count the headline states.
        var total: Int
        /// The few that are drawn.
        var shown: [BrandUpdate]
        /// Sizes that came back, ones the reader wears first. Nil for every other kind.
        var detail: String?

        var id: String { kind.rawValue }

        /// The sentence. This is the line the feed is built around, so it says what
        /// happened in words rather than naming a kind: "12 new products", not "PRODUCT".
        ///
        /// It comes out of `StreetwCore` because the page this headline now *opens* prints
        /// the same sentence as its heading — see `BrandFeedView`. A tap has to land on the
        /// thing it was pointed at, and the cheapest way for it not to is two copies of one
        /// sentence a module apart.
        var headline: String { kind.headline(count: total) }

        /// Only the lock spends the accent. It is the one story here that is about the next
        /// few minutes, and an accent on every headline makes the one that matters invisible
        /// — the same argument the drop calendar's watch line settles the same way.
        var color: Color { kind == .dropLock ? .signal : .ink }
    }

    private func layout(profile: SizeProfile) -> Layout {
        var result = Layout()
        var byKind: [UpdateKind: [BrandUpdate]] = [:]

        // `group.updates` is already deduplicated per garment and sorted newest-first, so
        // each bucket inherits that order and nothing here needs to sort again.
        for update in group.updates {
            if update.kind == .collection {
                result.releases.append(update)
            } else {
                byKind[update.kind, default: []].append(update)
            }
        }

        // **One release, stated once.** Billionaire Boys Club announced its Yankees edit
        // three times in a single spread and every word of it was true: `/collections.json`
        // gave the release, `/products.json` gave the two tees in it, and the brand's own
        // blog gave the announcement — three sources, three kinds, three buckets, and
        // nothing in this function had ever been in a position to notice they were one
        // piece of news. So the card said it, then "2 new products" printed the same two
        // garments underneath it, then "A new post" printed the same announcement again
        // with no photograph.
        //
        // Neither of these hides anything the spread was not already showing: the garments
        // are in the release card's strip and on the page its headline opens, and the post
        // is the same sentence as the release above it. Both still count as unread, both
        // still reach the brand's queue, and the foot link's total is untouched — it has
        // always been `group.updates.count`, the whole of what the brand published.
        // **Fold what the release card is already drawing, and nothing else.** The first
        // version of this read `memberExternalIDs` alone, which is empty on every
        // collection stored before the poller could read one — so on the brands actually
        // in front of somebody it folded nothing, and Represent went on printing "9 pieces
        // in this release" above "9 new products" showing the same nine garments. The
        // membership and the word match are the two answers `Brand.members(of:)` gives, in
        // its order, so asking the same question here keeps the two in step: a card showing
        // nothing folds nothing, which is the honest outcome for a release whose contents
        // we cannot name.
        //
        // Matched against this spread's own products rather than the brand's catalogue —
        // the question is only ever about the handful of unread rows about to be drawn, and
        // `members(of:)` faults the whole relationship to answer a wider one.
        var announced = Set<String>()
        for release in result.releases {
            if !release.memberExternalIDs.isEmpty {
                announced.formUnion(release.memberExternalIDs)
                continue
            }
            let words = BrandUpdate.distinctiveWords(in: release.title)
            guard !words.isEmpty else { continue }
            for product in byKind[.product] ?? [] where product.mentionsAny(of: words) {
                announced.insert(product.productExternalID ?? product.externalID)
            }
        }
        if !announced.isEmpty {
            byKind[.product]?.removeAll { announced.contains($0.productExternalID ?? $0.externalID) }
            if byKind[.product]?.isEmpty == true { byKind[.product] = nil }
        }
        if !result.releases.isEmpty {
            let brandWords = Set(BrandUpdate.distinctiveWords(in: group.brand.name))
            byKind[.post]?.removeAll { post in
                result.releases.contains { Self.restates($0.title, as: post.title, ignoring: brandWords) }
            }
            if byKind[.post]?.isEmpty == true { byKind[.post] = nil }
        }

        // **A lock is a property of the storefront, not of an unread row.** A brand can be
        // locked with its `.dropLock` event already read — or, in server mode, with the lock
        // recorded on the brand and no event of its own in this window at all. That is the
        // strongest signal the app has, and the old header printed it from `isLockedForDrop`
        // for exactly this reason; losing it to a bucket that happens to be empty would be a
        // silent downgrade of the one line worth reading.
        if group.brand.isLockedForDrop, byKind[.dropLock] == nil {
            byKind[.dropLock] = []
        }

        // Sorted before anything is drawn from them, so the lead is chosen against the same
        // order the page is read in. A dictionary has no order and `newsRank` is unique per
        // kind, which makes this a total one.
        var buckets = byKind
            .map { (kind: $0.key, items: $0.value) }
            .sorted { $0.kind.newsRank < $1.kind.newsRank }

        // **Only a sudden event earns the large photograph.**
        //
        // This is the part that actually changes the shape of the page. Restocks and
        // re-shelvings are most of the feed's volume — they are the reason `Reshelving`
        // exists and the reason `isSudden` refuses them a push — and yet a brand whose only
        // news was six restocks used to be handed a full screen of one garment, so the
        // quietest thing that can happen got the loudest slot the app has. A quiet story is
        // its headline and one row of tiles, which is a thing you can scan past; a drop, a
        // release or a lock still opens out.
        //
        // The lead comes from the *top* story that qualifies, not the newest garment in the
        // spread — so a brand mid-drop leads on the drop rather than on whichever product
        // happens to carry the newest timestamp.
        //
        // Lifted out of its bucket rather than merely marked, so the story it belongs to
        // still fills a whole row of tiles underneath it. Taking the lead and then printing
        // `storyLimit` from what was left would have left every drop with a ragged row of
        // two, which reads as the grid having lost one.
        var leadKind: UpdateKind?
        if let index = buckets.firstIndex(where: {
            $0.kind.isSudden && $0.items.contains(where: \.hasPhotograph)
        }) {
            let lead = buckets[index].items.first(where: \.hasPhotograph)
            result.lead = lead
            leadKind = buckets[index].kind
            buckets[index].items.removeAll { $0.id == lead?.id }
        }

        result.stories = buckets.map { bucket in
            Story(
                kind: bucket.kind,
                // What happened, not what is left after the lead was taken out of it.
                total: bucket.items.count + (bucket.kind == leadKind ? 1 : 0),
                // **A markdown states itself and does not spend a row of the page.**
                //
                // `MarkdownsView` exists precisely because the feed is the wrong home for
                // price cuts: the feed is ordered by recency and a cut is worth as much a
                // week later as it was on the day, which is why that screen is *not*
                // emptied by reading and keeps its own `markdownDismissedAt` verdict. It
                // has its own badge in the toolbar and its own way in. Printing three
                // tiles of the same thing under every brand was the same list said twice,
                // and it was a third of the height of a spread whose subject is what just
                // dropped.
                //
                // The headline stays, and stays a link — "4 price cuts" still opens the
                // four, per the rule that every count on a spread opens the list it
                // counts. What goes is the evidence row, because a markdown is a claim
                // about a *number* and the tile was never the thing that carried it.
                shown: bucket.kind == .priceDrop
                    ? []
                    : Array(bucket.items.prefix(storyLimit)),
                // Read off `byKind` rather than off the bucket, so the sizes still name the
                // garment that became the lead.
                detail: bucket.kind == .restock
                    ? Self.returnedSizes(byKind[.restock] ?? [], profile: profile)
                    : nil
            )
        }

        let drawn = result.stories.reduce(result.lead == nil ? 0 : 1) { $0 + $1.shown.count }
        result.overflow = max(0, group.updates.count - result.releases.count - drawn)
        return result
    }

    /// Whether a blog post is announcing the release the spread already leads with.
    ///
    /// A brand that runs a Shopify blog publishes its drop twice — as a collection and as a
    /// post about the collection — and the two titles are never identical, because one is a
    /// page name and the other is a headline. BBC's read "The Women's Edit: New York
    /// Yankees™ | Billionaire Boys Club" and "New York Yankees™ | Billionaire Boys Club".
    ///
    /// Containment over letters and digits catches that pair and nothing more awkward: the
    /// punctuation is where the two disagree — a colon, a trademark, an ampersand written
    /// out — but a headline that adds so much as one trailing word to the page name is no
    /// longer contained in it, and headlines add words. So the words themselves are
    /// compared too, and that is the test that carries most of them.
    ///
    /// **The brand's own name is struck out first.** Nearly every post a brand writes names
    /// it — "Billionaire Boys Club" is three distinctive words on its own — so counting
    /// those would fold two genuinely different announcements together the moment both
    /// mentioned the label, which inside that brand's own spread they always do.
    ///
    /// What is left has to overlap in at least two words, and then either the post adds
    /// nothing the release did not name, or **one** word of its own. That slack is the
    /// whole difference between a rule that works and the one shipped before it: a page is
    /// called "The Women's Edit: New York Yankees | Billionaire Boys Club" and the post
    /// about it is headlined "Introducing the New York Yankees Collection", and a strict
    /// subset test folds neither. Slack on the post's side only, because headlines add
    /// words and page names do not.
    ///
    /// Two words is the floor because one is a coincidence — every drop a brand makes is
    /// "denim" sooner or later. The cost of the slack, accepted knowingly: a genuinely
    /// separate post sharing two words and adding one ("Women's Running Edit" against the
    /// release above) is folded away. That shape is rare, the duplicate it prevents is not,
    /// and nothing is lost from the brand's queue either way.
    private static func restates(_ release: String, as post: String, ignoring brand: Set<String>) -> Bool {
        let a = release.lowercased().filter { $0.isLetter || $0.isNumber }
        let b = post.lowercased().filter { $0.isLetter || $0.isNumber }
        if a.count >= 12, b.count >= 12, a.contains(b) || b.contains(a) { return true }

        let release = Set(BrandUpdate.distinctiveWords(in: release)).subtracting(brand)
        let post = Set(BrandUpdate.distinctiveWords(in: post)).subtracting(brand)
        guard !release.isEmpty, !post.isEmpty else { return false }
        guard release.intersection(post).count >= 2 else {
            return release.isSubset(of: post) || post.isSubset(of: release)
        }
        return post.subtracting(release).count <= 1 || release.subtracting(post).isEmpty
    }

    /// What came back, the reader's own sizes first.
    ///
    /// The same rule `FeedState` applies to one card, applied to a story about several: the
    /// sizes still print when none of them are yours, because a restock is genuinely news
    /// about the product — it just isn't news about *you*, so it is set in metadata grey
    /// like the rest of this line rather than in the accent.
    private static func returnedSizes(_ items: [BrandUpdate], profile: SizeProfile) -> String? {
        var seen: Set<String> = []
        var mine: [String] = []
        var others: [String] = []
        for item in items {
            for size in item.restockedSizes where size != "Default Title" && !size.isEmpty {
                guard seen.insert(size).inserted else { continue }
                if profile.claims(size) { mine.append(size) } else { others.append(size) }
            }
        }
        let shown = (mine + others).prefix(4)
        return shown.isEmpty ? nil : "BACK IN \(shown.joined(separator: ", ").uppercased())"
    }

    private let columns = [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14), GridItem(.flexible())]

    var body: some View {
        // One evaluation per render, threaded into the sections as a parameter — the
        // discipline `FeedView.Feed` and `BrandDetailView` already follow.
        let layout = layout(profile: sizes.profile)

        return VStack(alignment: .leading, spacing: 0) {
            Rule()
                .padding(.horizontal, 20)
                .padding(.bottom, 14)

            header

            ForEach(layout.releases) { release in
                CollectionCard(update: release)
                    .padding(.bottom, 26)
            }

            ForEach(Array(layout.stories.enumerated()), id: \.element.id) { index, story in
                self.story(story, lead: index == leadIndex(layout) ? layout.lead : nil)
                    .padding(.bottom, 26)
            }

            if layout.overflow > 0 {
                NavigationLink(value: BrandFeedRoute(brand: group.brand)) {
                    // **It says the whole, because the whole is what it opens.**
                    //
                    // This read "+8 MORE FROM …" and went to a page holding all fifteen —
                    // the eight it named *and* the seven already drawn above it. A link
                    // whose number describes a remainder and whose destination is the total
                    // is a small lie told on the way to a page you then have to reconcile
                    // with the one you left, and it was the reason the whole spread read as
                    // three counts nobody could account for.
                    //
                    // The remainder is not worth stating now that each headline opens its
                    // own story: what is left to offer here is the brand's queue entire,
                    // and that is a number the page it opens can be checked against.
                    //
                    // Underlined so it reads as the link it is; a bare mono line looked
                    // like another caption.
                    DataLabel(text: "ALL \(group.updates.count) FROM \(group.brand.name.uppercased())", color: .ink)
                        .overlay(alignment: .bottom) {
                            Rectangle().fill(Color.ink).frame(height: 1).offset(y: 3)
                        }
                        .padding(.horizontal, 20)
                }
            }
        }
        .padding(.bottom, 36)
    }

    /// Which story the lead photograph was taken out of. Matched on the kind, which is
    /// unique across the stories by construction — one bucket per kind.
    private func leadIndex(_ layout: Layout) -> Int? {
        guard let kind = layout.lead?.kind else { return nil }
        return layout.stories.firstIndex { $0.kind == kind }
    }

    /// **The sentence is the way in, and no new control is added to say so.**
    ///
    /// A spread states two or three things — "7 new products", "8 things are back" — prints
    /// three tiles of each, and used to offer exactly one link out: "+8 more", which went to
    /// all of them mixed together. So the page could *say* two different pieces of news and
    /// open only their sum, and somebody wanting one of them had nothing to press.
    ///
    /// The standing objection to fixing this was that four links under four headlines turns a
    /// spread into a menu, and that is right about *adding* four links. It is not what this
    /// does: the headline is already on the page, already states the count, and is already
    /// the only line naming the thing you would be asking for. Tapping the sentence that says
    /// seven new products to see seven new products adds no furniture at all — the chevron is
    /// the whole cost, and the alternative is a page that answers a question it just raised
    /// by making you go via the brand's whole queue.
    ///
    /// **Only when something is behind it.** A `.dropLock` story is synthesised from
    /// `Brand.isLockedForDrop` and often stands for no unread row at all, and a link onto an
    /// empty filtered page pushes and immediately pops itself — a tap that visibly does
    /// nothing, which is worse than a line that was never a link.
    @ViewBuilder
    private func headline(_ story: Story) -> some View {
        let text = VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(story.headline)
                    .font(.editorial(19))
                    .foregroundStyle(story.color)
                    .fixedSize(horizontal: false, vertical: true)
                if story.total > 0 {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.muted)
                }
                Spacer(minLength: 0)
            }
            if let detail = story.detail {
                DataLabel(text: detail)
            }
        }

        if story.total > 0 {
            NavigationLink(value: BrandFeedRoute(brand: group.brand, kind: story.kind)) {
                text
            }
            .buttonStyle(.plain)
        } else {
            text
        }
    }

    /// One event, then what it is evidence of.
    @ViewBuilder
    private func story(_ story: Story, lead: BrandUpdate?) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            headline(story)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.bottom, lead == nil && story.shown.isEmpty ? 0 : 14)

            if let lead {
                FeedLead(update: lead)
                    .padding(.bottom, story.shown.isEmpty ? 0 : 20)
            }

            if !story.shown.isEmpty {
                LazyVGrid(columns: columns, alignment: .leading, spacing: 16) {
                    ForEach(story.shown) { update in
                        FeedTile(update: update)
                    }
                }
                .padding(.horizontal, 20)
            }
        }
    }

    /// Who, when, and the way to be done with them.
    ///
    /// The sub-line that used to sit under the wordmark — "12 new products" in tracked caps
    /// — is gone, because that sentence is now the story headline below and printing it
    /// twice a few points apart is the app saying one thing in two voices.
    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            NavigationLink(value: BrandRoute(brand: group.brand)) {
                Wordmark(name: group.brand.name, size: 15)
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
        .padding(.bottom, 18)
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
}

#Preview {
    FeedView()
        .modelContainer(PreviewData.container)
        .environment(PreviewData.engine)
}

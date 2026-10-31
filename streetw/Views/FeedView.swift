// FeedView.swift
// What happened at your shops: one card per event, newest first, with a line where you
// left off.
//
// This is the Phase 1 feed, and it is deliberately not the 1.0 one. That was a magazine
// front page grouped by brand — a wordmark header per brand, a stack of stories under it,
// counts and "›" links, a checkmark to clear the spread, an alphabetical rail of brands at
// the top and four icons above it. Each piece was argued for and the sum was a first screen
// of five counters and three lines of links before its one photograph. What it is now:
//
// - **A two-column grid of picture cards** — photograph, brand, one label, price, and no
//   product name (`FeedCard`). Every event has a picture.
// - **Newest first across brands** (`FeedTimeline`). A release is one card; a burst of
//   three or more events of a kind from one brand inside thirty minutes is one card.
// - **One line instead of unread state** (`FeedVisit`). Above it, what arrived since your
//   last visit; below it, everything you have had the chance to see. Nothing to clear.
// - **One row of filters** (`FeedFilterRow`), which replaced the rail and the icons.
// - **One line about the future** (`UpcomingLine`), and the full list under Upcoming.
//
// See `docs/design-decisions.md`, *The feed*, for each rule and the 1.0 rule it replaced.

import StreetwCore
import SwiftData
import SwiftUI

/// Owns how much of the store the feed reads (`FeedWindow`), so the page under it can be
/// rebuilt with a deeper query without losing its own state — the visit, the filter, the
/// scroll position.
struct FeedView: View {
    @Environment(\.modelContext) private var context

    /// Opened when a visit begins and only ever deepened during it. Nil until the first.
    @State private var window: FeedWindow?

    var body: some View {
        // One fetch of one row, made until the window is stored on appearance.
        let window = self.window ?? opening()
        FeedPage(
            window: window,
            readFurther: { loaded in
                self.window = window.extended(to: Self.arrival(at: FeedWindow.extendingOffset(loaded: loaded), in: context))
            },
            // **A new visit reads a page again.** Within a visit the window only deepens, so
            // nothing leaves the screen; across visits a read somebody once scrolled deep would
            // otherwise be paid for on every body for the rest of the session, and grow with
            // every sync. The end of the page reads further back again when it is reached.
            reopen: { self.window = opening() }
        )
        .onAppear { if self.window == nil { self.window = window } }
    }

    private func opening() -> FeedWindow {
        FeedWindow.opening(edge: Self.arrival(at: FeedWindow.openingOffset, in: context))
    }

    /// When the row `offset` places from the newest arrival arrived, or nil when the store
    /// holds no row that deep.
    static func arrival(at offset: Int, in context: ModelContext) -> Date? {
        var edge = FetchDescriptor<BrandUpdate>(
            predicate: #Predicate { $0.arrivedAt != nil },
            sortBy: [SortDescriptor(\.arrivedAt, order: .reverse)]
        )
        edge.fetchOffset = offset
        edge.fetchLimit = 1
        return (try? context.fetch(edge))?.first?.arrivedAt
    }

    /// Every arrival the store holds, read or not — what the window could still reach.
    static func arrivals(in context: ModelContext) -> Int {
        (try? context.fetchCount(FetchDescriptor<BrandUpdate>(predicate: #Predicate { $0.arrivedAt != nil }))) ?? 0
    }
}

struct FeedPage: View {
    @Environment(\.modelContext) private var context
    @Environment(\.scenePhase) private var scenePhase
    @Environment(SyncEngine.self) private var engine: SyncEngine
    @Environment(SizeProfileStore.self) private var sizes: SizeProfileStore
    @Environment(RemoteSync.self) private var remote: RemoteSync
    @Environment(ServerSettings.self) private var settings: ServerSettings
    @Environment(BrandSuggestions.self) private var suggestions: BrandSuggestions
    @Environment(DropHintStore.self) private var hints: DropHintStore

    @Query(filter: #Predicate<Brand> { $0.followed }, sort: \Brand.name)
    private var brands: [Brand]

    /// **The timeline: news, narrowed and bounded by the store.**
    ///
    /// Read rows as well as unread, because the feed is everything that happened and the line
    /// says where you left off — but only rows that arrived *as news*: a baseline, a catch-up
    /// and whatever a follow mode keeps out are history and have no arrival (`arrivedAt`).
    /// Bounded, because in server mode every event is its own row and a few weeks of twenty
    /// brands is tens of thousands of them, and a `@Query` with no bound subscribes the view
    /// to all of it — see `docs/performance.md`. **Bounded by an arrival date, never a count**
    /// (`FeedWindow`): a count let each scan's markdowns push the morning's drops out of the
    /// read, and the feed lost what somebody had already scrolled.
    @Query private var news: [BrandUpdate]

    private let window: FeedWindow
    /// Reads one page further back, given how many rows are read now.
    private let readFurther: (Int) -> Void
    /// Opens the read afresh, a page deep: a new visit has begun.
    private let reopen: () -> Void

    /// Dates somebody wrote down. A small table, so unpredicated.
    @Query(sort: \PlannedDrop.releaseAt) private var planned: [PlannedDrop]

    /// Rows that may be dated ahead — a product published in the future, an announced
    /// release time. Narrowed by the store; `UpcomingDrops.build` checks the date.
    @Query private var scheduled: [BrandUpdate]

    init(window: FeedWindow, readFurther: @escaping (Int) -> Void, reopen: @escaping () -> Void) {
        self.window = window
        self.readFurther = readFurther
        self.reopen = reopen
        let floor = window.floor ?? .distantPast
        let timeline = FetchDescriptor<BrandUpdate>(
            predicate: #Predicate { $0.arrivedAt.flatMap { $0 >= floor } == true },
            sortBy: [SortDescriptor(\.arrivedAt, order: .reverse)]
        )
        _news = Query(timeline)
        _scheduled = Query(filter: UpcomingDrops.scheduledFilter(now: Date()))
    }

    @State private var visit = FeedVisit()
    /// Whether this tab is the one on screen. A visit is the feed being looked at, and
    /// coming back to the app on another tab is not that.
    @State private var isTabVisible = false

    /// `-feedFilter upcoming` opens the feed narrowed, so a screenshot needs no tapping.
    @State private var filter = FeedFilter(rawValue: UserDefaults.standard.string(forKey: "feedFilter") ?? "") ?? .all
    /// The brand the feed is narrowed to, by `FeedTimeline`'s key.
    @State private var brandKey: String?
    /// `-feedBrand "Ondo Club"`, resolved against the follow list once it is there.
    @State private var launchBrand = UserDefaults.standard.string(forKey: "feedBrand")

    @State private var isAddingBrand = false
    @State private var isShowingSizes = false
    @State private var editingDrop: PlannedDropEditor.Subject?

    var body: some View {
        // Each once per render, and threaded down: the rule `FeedPass` exists to keep.
        let pass = FeedPass(news: news, profile: sizes.profile, since: visit.boundary)
        let upcoming = UpcomingDrops.build(planned: planned, brands: brands, scheduled: scheduled)
            .filter { entry in brandKey.map { $0 == entry.brand?.id.uuidString } ?? true }

        return NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    syncTrouble

                    if filter == .all || filter == .drops, let next = UpcomingDrops.next(in: upcoming) {
                        UpcomingLine(entry: next) {
                            withAnimation(.easeOut(duration: 0.15)) { filter = .upcoming }
                        }
                        .padding(.bottom, 14)
                    }

                    if filter == .upcoming {
                        upcomingList(upcoming)
                    } else {
                        timeline(pass)
                    }
                }
                .padding(.bottom, 32)
            }
            .scrollIndicators(.hidden)
            .background(Color.paper)
            // Pinned under the title rather than scrolled away: the filters are how the page
            // is read, and they replaced controls that sat in the toolbar for the same reason.
            .safeAreaInset(edge: .top, spacing: 0) {
                FeedFilterRow(filter: $filter, brand: $brandKey, brands: brands) { isAddingBrand = true }
            }
            .navigationTitle("Feed")
            .toolbarTitleDisplayMode(.inlineLarge)
            .youButton()
            // Registered once, here, for every card in this stack — including the pages they
            // push. See `productLink`.
            .appDestinations()
            // The only way to ask by hand, and the only one that was ever needed. See
            // `FeedRefresh`: coming back to the app is what refreshes the feed, and this is
            // the gesture for not waiting. A pull is somebody saying "look now", so it is
            // never throttled.
            //
            // **The sync runs in its own task, and the pull only waits for it.** SwiftUI cancels
            // a refresh action's task when the content under it changes mid-refresh — and a sync
            // changes it at once: the trouble line goes, the pill comes, cards arrive. Run inside
            // the action, every pull on the grid ended "Kith: cancelled" while TRY AGAIN, which
            // is not a refresh, synced fine. Awaiting `.value` keeps the spinner honest.
            .refreshable {
                await Task {
                    await FeedRefresh.run(remote: remote, engine: engine, settings: settings, sizes: sizes)
                }.value
            }
            .overlay(alignment: .bottom) { syncStatus }
            .sheet(isPresented: $isAddingBrand) { AddBrandView() }
            .sheet(isPresented: $isShowingSizes) { SizesSheet() }
            .sheet(item: $editingDrop) { subject in
                PlannedDropEditor(subject: subject, brands: brands) {
                    UpcomingDrops.rescheduleAlerts(in: context, via: remote, hints: hints)
                }
            }
            // Keyed on the token so it reruns the moment registration completes — on a cold
            // launch this view appears before the device has one.
            .task(id: settings.token) { await suggestions.loadIfNeeded() }
        }
        .tint(.ink)
        .onAppear {
            isTabVisible = true
            visit.appeared()
        }
        .onDisappear {
            isTabVisible = false
            leave()
        }
        // Coming back to the app on this tab is a return to the feed; going to the app
        // switcher, or locking the phone, is leaving it. `onAppear` says neither.
        .onChange(of: scenePhase) { _, phase in
            guard isTabVisible else { return }
            if phase == .active { visit.appeared() } else { leave() }
        }
        .onChange(of: brands.count, initial: true) { _, _ in resolveLaunchBrand() }
        .onChange(of: visit.started) { _, _ in reopen() }
    }

    /// The feed went out of sight: what it had shown is seen. See `FeedHistory.markShown`.
    private func leave() {
        guard let at = visit.left() else { return }
        FeedHistory.markShown(upTo: at, in: context, profile: sizes.profile)
    }

    private func resolveLaunchBrand() {
        guard let name = launchBrand, !brands.isEmpty else { return }
        launchBrand = nil
        brandKey = brands.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.id.uuidString
    }

    private var chosenBrand: Brand? {
        brandKey.flatMap { key in brands.first { $0.id.uuidString == key } }
    }

    // MARK: - The timeline

    private let columns = [
        GridItem(.flexible(), spacing: 14, alignment: .top),
        GridItem(.flexible(), spacing: 14, alignment: .top)
    ]

    @ViewBuilder
    private func timeline(_ pass: FeedPass) -> some View {
        let shown = pass.timeline.narrowed(to: filter, brand: brandKey)

        if brands.isEmpty {
            nothingFollowed
        } else if shown.isEmpty {
            // On screen at once: a filter with nothing in the newest page reads further back
            // before it says there is nothing.
            furtherBack
            nothingHere(isHidingSome: pass.isHidingSome)
        } else {
            if filter == .all || filter == .restocks { sizePrompt }

            LazyVGrid(columns: columns, alignment: .leading, spacing: 26) {
                Section {
                    cards(shown.fresh, in: pass)
                }
                Section {
                    cards(shown.earlier, in: pass)
                } header: {
                    if let boundary = visit.boundary, !shown.earlier.isEmpty {
                        sinceLine(hasFresh: !shown.fresh.isEmpty, boundary: boundary)
                    }
                }
            }
            .padding(.horizontal, 16)

            furtherBack

            // The tail of the feed, not only its empty state. Reaching the end of what your
            // brands did is the moment there is attention to spare.
            if filter == .all, brandKey == nil {
                BrandRecommendations()
                    .padding(.top, 44)
            }
        }
    }

    /// **The end of what is read is not the end of the feed.** Reached — by scrolling to the
    /// foot of the grid, or at once when a filter leaves the page short — it reads one page
    /// of older arrivals (`FeedWindow.extended`), and again while it stays in sight and the
    /// store holds more. Keyed on the window, so each deeper read is asked about once.
    @ViewBuilder
    private var furtherBack: some View {
        if window.floor != nil {
            Color.clear
                .frame(height: 1)
                .task(id: window) {
                    if window.hasMore(loaded: news.count, total: FeedView.arrivals(in: context)) {
                        readFurther(news.count)
                    }
                }
        }
    }

    private func cards(_ cards: [FeedTimeline.Card], in pass: FeedPass) -> some View {
        ForEach(cards) { card in
            if let brand = pass.brands[card.brand] {
                FeedCard(card: card, rows: pass.rows(of: card), brand: brand)
            }
        }
    }

    /// **The line that replaced every checkmark, dot and count.** Above it, what arrived
    /// since the last visit; below it, everything you have had the chance to see. When
    /// nothing is new it heads the page instead, saying so — the honest version of 1.0's
    /// "All caught up", which was a statement about a queue somebody had to keep empty.
    private func sinceLine(hasFresh: Bool, boundary: Date) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Rectangle().fill(Color.ink).frame(height: 1)
            HStack(alignment: .firstTextBaseline) {
                NoteLine(
                    text: hasFresh ? "↑ New since you were last here" : "Nothing new since you were last here",
                    color: .ink
                )
                Spacer(minLength: 8)
                NoteLine(text: Stamp.short(boundary))
            }
        }
        .padding(.top, hasFresh ? 18 : 2)
        .padding(.bottom, 6)
        .background(Color.paper)
    }

    // MARK: - Upcoming

    @ViewBuilder
    private func upcomingList(_ entries: [UpcomingDrop]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if entries.isEmpty {
                empty(
                    "Nothing ahead",
                    "Locked shops and set dates land here."
                )
            } else {
                UpcomingDropList(
                    entries: entries,
                    addDate: { editingDrop = .new($0) },
                    edit: { editingDrop = .existing($0) },
                    delete: { UpcomingDrops.delete($0, in: context, via: remote, hints: hints) }
                )
            }
            // **A date you know and the app cannot**, written down where the dates are. A
            // reminder on the day and at the minute, and the poller looks harder — see
            // `docs/drop-calendar.md`.
            if !brands.isEmpty {
                underlined("Add a date") { editingDrop = .new(chosenBrand) }
                    .padding(.horizontal, 20)
                    .padding(.top, 20)
            }
        }
    }

    // MARK: - Empty

    private var nothingFollowed: some View {
        VStack(alignment: .leading, spacing: 0) {
            empty("Nothing on watch yet", "Add a brand to start watching.")
            underlined("Add a brand") { isAddingBrand = true }
                .padding(.horizontal, 20)
                .padding(.top, 14)
                .padding(.bottom, 36)
            // There is no state of this screen where a list of brands worth following is
            // the wrong thing to show — least of all this one.
            BrandRecommendations()
        }
    }

    /// Nothing under this filter, and why — which is three different answers.
    @ViewBuilder
    private func nothingHere(isHidingSome: Bool) -> some View {
        let brand = chosenBrand
        VStack(alignment: .leading, spacing: 0) {
            if let brand, brand.followMode == .quiet {
                // Chosen from the menu, where it is labelled — and empty because that is what
                // Quiet means, which is worth saying rather than looking broken.
                empty("Nothing from \(brand.name) reaches the feed", "Followed quietly. Its page has it all.")
                NavigationLink(value: BrandRoute(brand: brand)) {
                    underlinedLabel("Open \(brand.name)")
                }
                .buttonStyle(.borderless)
                .padding(.horizontal, 20)
                .padding(.top, 14)
            } else {
                empty(emptyTitle(brand: brand), emptyDetail(isHidingSome: isHidingSome))
                if isHidingSome {
                    underlined("Change it") { isShowingSizes = true }
                        .padding(.horizontal, 20)
                        .padding(.top, 14)
                }
            }
        }
        if filter == .all, brand == nil {
            BrandRecommendations()
                .padding(.top, 36)
        }
    }

    private func emptyTitle(brand: Brand?) -> String {
        let what = switch filter {
        case .all, .upcoming: "Nothing"
        case .drops: "No drops"
        case .restocks: "No restocks"
        case .sales: "No sales"
        }
        return brand.map { "\(what) from \($0.name) yet" } ?? "\(what) yet"
    }

    private func emptyDetail(isHidingSome: Bool) -> String {
        if isHidingSome { return "You're seeing \(sizes.profile.gender.label.lowercased()) only." }
        if engine.lastSyncedAt == nil, remote.lastSyncedAt == nil {
            return "Pull down to check your brands."
        }
        return switch filter {
        case .all, .upcoming: "Drops, restocks and sales land here."
        case .drops: "New products and releases land here."
        case .restocks: "Things back in stock land here."
        case .sales: "Markdowns and sales land here."
        }
    }

    private func empty(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.editorial(22))
                .foregroundStyle(Color.ink)
                .fixedSize(horizontal: false, vertical: true)
            NoteLine(text: detail, size: 16)
        }
        .padding(.horizontal, 20)
        .padding(.top, 18)
    }

    private func underlined(_ text: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { underlinedLabel(text) }
            .buttonStyle(.borderless)
    }

    /// A line of type underlined so it reads as a door rather than as a statement.
    private func underlinedLabel(_ text: String) -> some View {
        NotificationsSection.SettingsAction(title: text)
    }

    /// The one mention of sizes on the feed, and only until they are set.
    ///
    /// "BACK IN YOUR SIZE" is the one label that spends the accent, and with an empty
    /// profile it can never be said — the feature is simply off, silently, for somebody who
    /// skipped the onboarding step once. It opens the sizes rather than naming a screen.
    @ViewBuilder
    private var sizePrompt: some View {
        if sizes.profile.isEmpty {
            underlined("Set your sizes") { isShowingSizes = true }
                .padding(.horizontal, 20)
                .padding(.bottom, 18)
        }
    }

    // MARK: - Sync

    /// **The one place in the app that can say a sync failed.**
    ///
    /// `RemoteSync.lastError` and `SyncEngine.lastError` were both set on every failure path
    /// and read by nothing a person can see, so a refused credential, a dead network, a server
    /// mid-deploy and *genuinely nothing happened* were one screen, with the app quietly not
    /// working. An app that watches things on your behalf has to be able to say when it has
    /// stopped watching. It clears itself: `lastError` is nil'd at the top of every sync.
    ///
    /// The retry is here and not only in the pull, because somebody who has just been told
    /// the app could not reach the server should not have to guess that a gesture is the
    /// remedy.
    @ViewBuilder
    private var syncTrouble: some View {
        // Whichever engine is actually doing the work, the same branch `FeedRefresh` takes.
        let trouble = settings.isConfigured ? remote.lastError : engine.lastError
        if let trouble, !isSyncingNow {
            VStack(alignment: .leading, spacing: 6) {
                NoteLine(text: "Couldn't reach Dropwall.", size: 15, color: .signal)
                Text(trouble)
                    .font(.editorial(15))
                    .foregroundStyle(Color.ink)
                    .fixedSize(horizontal: false, vertical: true)
                underlined("Try again") {
                    Task {
                        await FeedRefresh.run(remote: remote, engine: engine, settings: settings, sizes: sizes)
                    }
                }
                .padding(.top, 2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .overlay(alignment: .leading) {
                Rectangle().fill(Color.signal).frame(width: 2)
            }
            .padding(.bottom, 18)
        }
    }

    private var isSyncingNow: Bool { engine.isSyncing || remote.isSyncing }

    /// **What the refresh button did that the pull does not.** A refresh happens on its own
    /// when you come back to the app (`FeedRefresh`), and a check nobody asked for needs
    /// saying more than one they did — a pull already has the platform's spinner attached to
    /// the finger that started it.
    @ViewBuilder
    private var syncStatus: some View {
        if isSyncingNow {
            DataLabel(
                text: engine.progress.map { "Checking \($0)…" } ?? "Checking…",
                color: .paper
            )
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Color.ink, in: Capsule())
            .padding(.bottom, 10)
            .transition(.opacity)
        }
    }
}

#Preview {
    FeedView()
        .modelContainer(PreviewData.container)
        .environment(PreviewData.engine)
}

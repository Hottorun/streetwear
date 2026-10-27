//
//  ContentView.swift
//  Dropwall
//
//  Created by Dimitris Kern on 09.08.26.
//

import StreetwCore
import SwiftData
import SwiftUI

/// The tabs, and what an unrecognised name resolves to.
enum Tabs {
    static let all = ["feed", "shop", "saved"]

    /// Names that were tabs once, and where what they held lives now. They still exist in
    /// muscle memory and in screenshot scripts, and a `TabView` whose selection matches nothing
    /// draws a blank page — so each lands on the closest honest answer instead:
    ///
    /// - `discover` is part of Shop.
    /// - `style` held the fits, kept and proposed, which are Saved › Fits now (`opensOnFits`).
    ///   Its taste reading is on You, which is not a tab.
    /// - `brands`, and anything else, is the feed.
    static func resolve(_ name: String?) -> String {
        switch name {
        case let name? where all.contains(name): name
        case "discover": "shop"
        case "style": "saved"
        default: "feed"
        }
    }

    /// Whether the launch asked for the retired Style tab, which Saved answers on its Fits strip.
    static var opensOnFits: Bool {
        UserDefaults.standard.string(forKey: "startTab") == "style"
    }
}

struct ContentView: View {
    @Environment(\.modelContext) private var context
    @Environment(RemoteSync.self) private var remote: RemoteSync
    @Environment(ServerSettings.self) private var settings: ServerSettings
    @Environment(ProfileStore.self) private var profiles: ProfileStore
    @Environment(SizeProfileStore.self) private var sizes: SizeProfileStore
    @Environment(PushRoute.self) private var route: PushRoute
    @Environment(SaveConfirmation.self) private var confirmation: SaveConfirmation
    @Environment(CollectionRoute.self) private var collection: CollectionRoute
    @Environment(YouRoute.self) private var you: YouRoute
    @Environment(AIStore.self) private var ai: AIStore
    @Environment(\.scenePhase) private var scenePhase

    /// Dev affordance, matching `-seedBrands` / `-seedSizes`: `-startTab saved`
    /// opens straight to a tab so screenshots don't need UI automation.
    ///
    /// Resolved through `Tabs.resolve` because the set has changed: `-startTab brands` names
    /// a tab that no longer exists, and a `TabView` whose selection matches nothing draws an
    /// empty page — a launch flag that silently opens the app on nothing is worse than one
    /// that is ignored.
    @State private var selection = Tabs.resolve(UserDefaults.standard.string(forKey: "startTab"))

    /// Sticky, so skipping the starter pack doesn't offer it again on every launch —
    /// someone who intends to add one brand by hand shouldn't be asked twice.
    ///
    /// Per profile: a profile somebody has just added has no brands and has never been
    /// offered anything, so switching to it opens on onboarding — the right first screen for
    /// setting somebody else up. The root is rebuilt on a switch, so the key is read afresh.
    @AppStorage(ProfileScope.active.key("didOfferStarterPack")) private var didOfferStarterPack = false

    /// Latched, **not** derived from `brands.isEmpty`.
    ///
    /// This used to be `.constant(brands.isEmpty && !didOfferStarterPack)`, which meant
    /// onboarding dismissed itself the instant it added a brand — its own side effect
    /// flipped the condition holding it open, and the alerts step was never reachable
    /// because the flow was torn down before it could get there.
    @State private var isOnboarding = false
    /// The decision is made once per launch. Without this, a returning user in server
    /// mode would be shown onboarding for the moment before their follows arrive.
    @State private var hasDecidedOnboarding = false

    /// The item a tapped notification asked for, shown over whatever tab is open.
    ///
    /// A sheet rather than a push onto the feed's stack: the notification is an
    /// interruption and this is the answer to it, so it should be dismissable back to
    /// exactly where the person was — not leave them somewhere they have to navigate out
    /// of. It also means the destination doesn't depend on which tab happened to be
    /// selected when the alert arrived.
    @State private var opened: BrandUpdate?
    @State private var openedBrand: Brand?

    var body: some View {
        // **Three tabs, and everything about the person behind the avatar on each.**
        //
        // What happened at your shops · what to get next · what is yours. Style was the fourth,
        // and it was never a place: it was a reading of your taste, two rows of fits and a
        // settings gear. The fits are Saved › Fits, the reading is on You, and the settings
        // with it (see `YouView`) — beside the brands you follow, the things you are waiting
        // on and the calendar, which were sheets behind icons on the feed. Brands stopped
        // being a tab before this for the same reason: a directory of names with no news in
        // it, beside tabs that are all about change.
        TabView(selection: $selection) {
            Tab("Feed", systemImage: "square.stack", value: "feed") {
                FeedView()
            }
            // Between the brands you chose and the things you kept, which is where it
            // belongs: it is the way *in* to the first and the way *out* of the second.
            Tab("Shop", systemImage: "magnifyingglass", value: "shop") {
                ShopView()
                    // **The one tab whose foot is deliberately near-black.** A card there is
                    // a poster with its own fixed ground (see `DiscoverCardView`), and the
                    // floating tab bar takes its material from what is behind it — so in the
                    // light appearance it came out dark with a *light-appearance* selection,
                    // which is dark type on a dark pill. Telling the bar which scheme it is
                    // dressing for is the whole fix; every other tab is unaffected.
                    .toolbarColorScheme(.dark, for: .tabBar)
            }
            Tab("Saved", systemImage: "bookmark", value: "saved") {
                SavedView()
            }
        }
        // Ink, not the system blue: the accent is reserved for things that are happening
        // now, so it must never be spent on ordinary controls.
        .tint(.ink)
        // **Scaled, but bounded.** `Font.editorial/data/wordmark` now scale with the
        // reader's setting, which is the whole point — but this app is dense by design: a
        // size run of twenty tokens, three-up garment grids, a tab bar of four. Past
        // accessibility2 those stop being tight and start being unusable, and an app that
        // cannot be operated is not more accessible than one set slightly small.
        //
        // At the root rather than per screen, so a sheet or a pushed page cannot escape it.
        // The four largest settings still get the largest type the layout can actually hold.
        .dynamicTypeSize(...DynamicTypeSize.accessibility2)
        // Tapping a facet in the taste summary is a question about the collection, so it
        // is answered in the collection — which means closing You, the page it was asked
        // from, as well as changing tab. Keyed on the request count rather than on the
        // facet: asking for the one you are already looking at is a legitimate way to get
        // back to the Saved tab, and an unchanged value publishes nothing.
        .onChange(of: collection.requests) { _, _ in
            you.isOpen = false
            selection = "saved"
        }
        // Presented once, here, whichever tab's avatar asked — see `YouRoute`.
        .sheet(isPresented: Bindable(you).isOpen) { YouView() }
        // Above the tab bar rather than over the card that was saved: a half-width card has
        // no room for it, and the card in question has usually been scrolled past by the
        // time you decide to amend it anyway.
        .overlay(alignment: .bottom) {
            SaveToast()
                .padding(.bottom, 92 + confirmation.bottomClearance)
        }
        .animation(.spring(duration: 0.32), value: confirmation.pending?.id)
        // Sync at the root, not in FeedView: a configured server should be live
        // whichever tab the app happens to open on.
        .task(id: settings.baseURLString) {
            // **A device with no token cannot have follows, so it must not wait.**
            //
            // The first sync is four sequential round trips — register, follows, feed,
            // watches — and gating the whole of onboarding behind it meant a brand-new
            // user sat looking at an empty tab for as long as all four took: measured at
            // ten seconds against a cold server, and never less than the three or four a
            // warm one costs. That is the first thing anybody ever sees of this app, and
            // it reads as a launch that failed rather than as a sync in progress.
            //
            // The wait was there for a real reason — see below — but it only ever applied
            // to somebody who *has* follows to wait for. A device that has never
            // registered has no server identity, so the answer is already known locally
            // and known to be empty. `hasDecidedOnboarding` latches, so this is the one
            // decision and the call after the sync becomes a no-op.
            if !settings.isRegistered { decideOnboarding() }

            // `lastAttemptedAt`, not `lastSyncedAt`: the question here is "has a sync run
            // yet this launch", and a failed one has. Retrying it is `FeedRefresh`'s job,
            // on a throttle — a `.task` that fires once per appearance is not a retry.
            if settings.isConfigured, remote.lastAttemptedAt == nil {
                await remote.sync(sizes: sizes.profile)
            }
            // Whether the profiles this phone holds still exist. After the sync, so a token
            // the sync had to replace is the one asked with.
            if settings.account != nil { await profiles.refresh() }
            // Only after that sync has had its chance to populate `brands`, so a
            // returning user isn't shown a starter pack while their follows are in
            // flight. In standalone mode there is nothing to wait for and this is
            // immediate.
            decideOnboarding()
            // Dev-only and a no-op without the flag. Here as well as in `DevSeed` because
            // in server mode the store is empty until this sync lands, and the flag is
            // documented as working on its own.
            DevSeed.seedSavesIfRequested(in: context)
        }
        // The anonymous usage counts — see `UsageCounts`. An open is counted here rather
        // than in `streetwApp`, because only this view knows which tab it opened on; and in a
        // `.task` as well as on the phase change, because a cold launch has no earlier phase
        // to change from. The phase is checked, so a background launch — a push, a refresh
        // — is not somebody opening the app.
        .task {
            if scenePhase == .active { UsageCounts.sceneBecameActive(onTab: selection) }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active: UsageCounts.sceneBecameActive(onTab: selection)
            case .background: UsageCounts.sceneEnteredBackground()
            default: break
            }
        }
        .onChange(of: selection) { _, tab in UsageCounts.tabOpened(tab) }
        // Keyed on the token, per the rule for anything authenticated on first launch: the
        // first open is counted before registration has finished, and this is what sends it
        // once it has — and sends again after a stale token has been replaced.
        .task(id: settings.token) { await UsageCounts.report(force: true) }
        // Whether anything AI is drawn, and what it costs, for every tab at once — at the root
        // because Shop's field and Saved's scan both ask. Keyed on the token (first launch
        // appears before registration), the account (signing in turns "Sign in to use" into a
        // price) and, through `.id(session.scope)` above this view, the profile.
        .task(id: AIStatusKey(token: settings.token, account: settings.account?.id)) {
            await ai.refresh()
        }
        // Also here, not only on `scenePhase`: `onChange` fires on *changes*, and a cold
        // launch has no previous phase to change from — so anything shared while the app
        // was not running would sit in the inbox until the user backgrounded and
        // returned. Draining twice is harmless; the inbox empties itself.
        .task {
            await SharedSaveImporter.drain(
                into: context, scope: remote.scope, route: route, confirm: confirmation
            )
        }
        // Only when there is genuinely nothing to show. A returning user who has removed
        // all their brands is a deliberate act, which is what `didOfferStarterPack`
        // remembers.
        .fullScreenCover(isPresented: $isOnboarding) {
            // **Only latch when the offer was actually made.** `didOfferStarterPack` is
            // permanent, and it was being set on the way out of onboarding whatever had
            // happened inside it — so a first run against a server that was down ended with
            // an empty feed and the starter pack out of reach for the life of the install.
            // `OnboardingView` says which of the two it was.
            OnboardingView { mayLatch in
                if mayLatch { didOfferStarterPack = true }
                isOnboarding = false
            }
        }
        // A tap can arrive before this view exists — a push cold-launching the app — so
        // the pending destination is read on appearance as well as on change.
        .task { follow(route.pending) }
        .onChange(of: route.pending) { _, destination in follow(destination) }
        // **The close control is added here, not in the views.** Both are also pushed onto a
        // navigation stack elsewhere, where a Done button would be wrong — so the dismiss
        // belongs to the presentation, which is the thing that knows it is modal.
        //
        // Without it, tapping a notification landed on a product page whose only exit was a
        // downward swipe: `ProductDetailView`'s toolbar is a More menu and
        // `BrandDetailView`'s is Refresh, so neither offered a way back. That is often a
        // person's very first interaction with a Dropwall notification.
        .sheet(item: $opened) { update in
            NavigationStack {
                ProductDetailView(update: update)
                    .toolbar {
                        ToolbarItem(placement: .topBarLeading) {
                            Button("Close", systemImage: "xmark") { opened = nil }
                        }
                    }
            }
            .tint(.ink)
        }
        .sheet(item: $openedBrand) { brand in
            NavigationStack {
                BrandDetailView(brand: brand)
                    .toolbar {
                        ToolbarItem(placement: .topBarLeading) {
                            Button("Close", systemImage: "xmark") { openedBrand = nil }
                        }
                    }
            }
            .tint(.ink)
        }
        // Both driven from the confirmation rather than from the toast, which dismisses
        // itself on the tap that opens them — a sheet owned by a view that is going away
        // is a sheet that never appears.
        .sheet(item: Bindable(confirmation).choosingBoard) { update in
            BoardPicker(update: update)
                .presentationDetents([.medium])
        }
        // **Un-saving is asked about, wherever it was asked from.** The bookmark on a card
        // and the Remove item in its menu both delete the note, the size note and the board
        // filing along with the save — `SaveDetailView` has always said so and both of these
        // did it in silence. Hosted here rather than on the card for the same reason as the
        // sheets below: the card lives in a `LazyVStack` and is recycled or scrolled off on
        // its own schedule, and a dialog owned by one would go with it.
        //
        // Only reached when there is something to lose — see `isAuthored`. A bare bookmark
        // still comes off in one tap, because making the commonest action in the app a
        // two-step one to protect the case that needs no protecting is its own kind of wrong.
        .confirmationDialog(
            "Remove this from your collection?",
            isPresented: Binding(
                get: { confirmation.removingSave != nil },
                set: { if !$0 { confirmation.removingSave = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Remove", role: .destructive) {
                if let update = confirmation.removingSave {
                    removeSave(update, in: context)
                }
                confirmation.removingSave = nil
            }
            Button("Keep", role: .cancel) { confirmation.removingSave = nil }
        } message: {
            // The same sentence `SaveDetailView` uses, because it is the same act and a
            // second wording of one promise is how the two stop agreeing.
            Text("Your note and where you filed it go too. Fits it appears in are left alone.")
        }
        .sheet(item: Bindable(confirmation).settingWatch) { update in
            WatchEditor(update: update)
                .presentationDetents([.medium, .large])
        }
        // The answer to sharing in something that's gone. Kept as a sheet, and
        // deliberately not folded into the toast: a share is acted on when the app comes
        // back to the foreground, which can be long after the fact and while looking at
        // something else entirely. A dismissible confirmation is right for a save you just
        // made and watched happen; it is the wrong shape for an offer you might simply not
        // be there for.
        .sheet(item: Bindable(route).watchOffer) { update in
            WatchEditor(
                update: update,
                headline: "This one's sold out. Want to know when it's back?"
            )
            .presentationDetents([.medium, .large])
        }
    }

    /// Resolves a notification's destination against the store, now that the sync it
    /// triggered has had its chance to bring the row in.
    private func follow(_ destination: PushDestination?) {
        guard let destination else { return }
        route.pending = nil

        switch destination {
        case .update(let externalID):
            // Fetched by id rather than scanned: the table is thousands of rows deep after
            // a few weeks and this runs on the main actor while a sheet is animating.
            var descriptor = FetchDescriptor<BrandUpdate>(
                predicate: #Predicate { $0.externalID == externalID }
            )
            descriptor.fetchLimit = 1
            // A miss is possible and survivable — the event may have been pruned, or the
            // sync may have failed — so it falls back to the brand rather than doing
            // nothing at all.
            if let found = try? context.fetch(descriptor).first {
                opened = found
            } else {
                selection = "feed"
            }
        case .brand(let remoteID):
            // A counted summary is about the brand, so its page is where the batch is.
            var descriptor = FetchDescriptor<Brand>(
                predicate: #Predicate { $0.remoteID == remoteID }
            )
            descriptor.fetchLimit = 1
            if let found = try? context.fetch(descriptor).first {
                openedBrand = found
            } else {
                selection = "feed"
            }
        case .tab(let name):
            // Today's picks: a set, not one product, so the tab they are on.
            you.isOpen = false
            selection = Tabs.resolve(name)
        case .none:
            break
        }
    }

    /// **Asked once, with a fetch, rather than held as a `@Query`.**
    ///
    /// This read an unpredicated `@Query<Brand>` whose only reader was this function, which
    /// runs once per launch and latches. The cost was everything else: a `@Query` makes its
    /// view depend on the table, and this is the *root* view — the `TabView` owning all four
    /// tabs, the toast overlay and six sheets. So every write to any `Brand` row rebuilt the
    /// whole app's view tree, and `FeedView.markSeen` stamps `brand.lastOpenedAt` on exactly
    /// the tap the user reports as slow. One question asked once should not subscribe the
    /// root of the app to a table for the rest of the session.
    ///
    /// `fetchLimit = 1`, because the question is "is there any", not "how many".
    private func decideOnboarding() {
        guard !hasDecidedOnboarding else { return }
        hasDecidedOnboarding = true
        var descriptor = FetchDescriptor<Brand>()
        descriptor.fetchLimit = 1
        let hasBrand = ((try? context.fetch(descriptor))?.isEmpty == false)
        isOnboarding = !hasBrand && !didOfferStarterPack
    }
}

/// What the AI status is asked again on.
private struct AIStatusKey: Hashable {
    var token: String?
    var account: UUID?
}

#Preview {
    ContentView()
        .modelContainer(PreviewData.container)
}

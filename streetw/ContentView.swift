//
//  ContentView.swift
//  streetw
//
//  Created by Dimitris Kern on 09.08.26.
//

import SwiftData
import SwiftUI

/// The tabs, and what an unrecognised name resolves to.
enum Tabs {
    static let all = ["feed", "discover", "saved", "style"]

    /// `-startTab brands` still exists in muscle memory and in screenshot scripts, and
    /// Brands is no longer a tab. It resolves to the feed, which is where the brand rail
    /// and the add-a-brand control live — the closest honest answer, and never a blank page.
    static func resolve(_ name: String?) -> String {
        guard let name, all.contains(name) else { return "feed" }
        return name
    }
}

struct ContentView: View {
    @Environment(\.modelContext) private var context
    @Environment(RemoteSync.self) private var remote: RemoteSync
    @Environment(ServerSettings.self) private var settings: ServerSettings
    @Environment(SizeProfileStore.self) private var sizes: SizeProfileStore
    @Environment(PushRoute.self) private var route: PushRoute
    @Environment(SaveConfirmation.self) private var confirmation: SaveConfirmation
    @Environment(CollectionRoute.self) private var collection: CollectionRoute


    /// Dev affordance, matching `-seedBrands` / `-seedSizes`: `-startTab style`
    /// opens straight to a tab so screenshots don't need UI automation.
    ///
    /// Resolved through `Tabs.resolve` because the set has changed: `-startTab brands` names
    /// a tab that no longer exists, and a `TabView` whose selection matches nothing draws an
    /// empty page — a launch flag that silently opens the app on nothing is worse than one
    /// that is ignored.
    @State private var selection = Tabs.resolve(UserDefaults.standard.string(forKey: "startTab"))

    /// Sticky, so skipping the starter pack doesn't offer it again on every launch —
    /// someone who intends to add one brand by hand shouldn't be asked twice.
    @AppStorage("didOfferStarterPack") private var didOfferStarterPack = false

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
        TabView(selection: $selection) {
            Tab("Feed", systemImage: "square.stack", value: "feed") {
                FeedView()
            }
            // **Brands is not a tab, and that is the point of four.**
            //
            // It was a directory — a list of names, with no news in it and nothing that
            // changes — sitting beside three tabs that are all about change. Every wordmark
            // in the feed already opens the brand page, and the feed itself is grouped by
            // brand, so the tab's only exclusive jobs were reaching a brand with nothing
            // unread and adding one. Both are on `FeedView`'s brand rail now, and the full
            // index (which sources, and whether any is failing) is a sheet behind it.
            //
            // What is left is an honest set: what happened · what is new to you · what is
            // yours · what that says about you.
            //
            // Between the brands you chose and the things you kept, which is where it
            // belongs: it is the way *in* to the first and the way *out* of the second.
            Tab("Discover", systemImage: "safari", value: "discover") {
                DiscoverFeedView()
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
            Tab("Style", systemImage: "chart.pie", value: "style") {
                StyleView()
            }
        }
        // Ink, not the system blue: the accent is reserved for things that are happening
        // now, so it must never be spent on ordinary controls.
        .tint(.ink)
        // Tapping a facet in the taste summary is a question about the collection, so it
        // is answered in the collection. Keyed on the request count rather than on the
        // facet: asking for the one you are already looking at is a legitimate way to get
        // back to the Saved tab, and an unchanged value publishes nothing.
        .onChange(of: collection.requests) { _, _ in
            selection = "saved"
        }
        // Above the tab bar rather than over the card that was saved. `quickSave` claims
        // the horizontal drag on the lower half of a feed card, so anything laid over that
        // region is competing with a gesture for the same pixels — and the card in
        // question has usually been scrolled past by the time you decide to amend it
        // anyway.
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
        // Also here, not only on `scenePhase`: `onChange` fires on *changes*, and a cold
        // launch has no previous phase to change from — so anything shared while the app
        // was not running would sit in the inbox until the user backgrounded and
        // returned. Draining twice is harmless; the inbox empties itself.
        .task { await SharedSaveImporter.drain(into: context, route: route, confirm: confirmation) }
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
        .sheet(item: $opened) { update in
            NavigationStack { ProductDetailView(update: update) }
                .tint(.ink)
        }
        .sheet(item: $openedBrand) { brand in
            NavigationStack { BrandDetailView(brand: brand) }
                .tint(.ink)
        }
        // Both driven from the confirmation rather than from the toast, which dismisses
        // itself on the tap that opens them — a sheet owned by a view that is going away
        // is a sheet that never appears.
        .sheet(item: Bindable(confirmation).choosingBoard) { update in
            BoardPicker(update: update)
                .presentationDetents([.medium])
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

#Preview {
    ContentView()
        .modelContainer(PreviewData.container)
}

//
//  ContentView.swift
//  streetw
//
//  Created by Dimitris Kern on 09.08.26.
//

import SwiftData
import SwiftUI

struct ContentView: View {
    @Environment(\.modelContext) private var context
    @Environment(RemoteSync.self) private var remote: RemoteSync
    @Environment(ServerSettings.self) private var settings: ServerSettings
    @Environment(SizeProfileStore.self) private var sizes: SizeProfileStore
    @Environment(PushRoute.self) private var route: PushRoute


    /// Dev affordance, matching `-seedBrands` / `-seedSizes`: `-startTab style`
    /// opens straight to a tab so screenshots don't need UI automation.
    @State private var selection = UserDefaults.standard.string(forKey: "startTab") ?? "feed"

    @Query private var brands: [Brand]
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
            Tab("Brands", systemImage: "tag", value: "brands") {
                BrandsView()
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
        // Sync at the root, not in FeedView: a configured server should be live
        // whichever tab the app happens to open on.
        .task(id: settings.baseURLString) {
            if settings.isConfigured, remote.lastSyncedAt == nil {
                await remote.sync(sizes: sizes.profile)
            }
            // Only after that sync has had its chance to populate `brands`, so a
            // returning user isn't shown a starter pack while their follows are in
            // flight. In standalone mode there is nothing to wait for and this is
            // immediate.
            decideOnboarding()
        }
        // Also here, not only on `scenePhase`: `onChange` fires on *changes*, and a cold
        // launch has no previous phase to change from — so anything shared while the app
        // was not running would sit in the inbox until the user backgrounded and
        // returned. Draining twice is harmless; the inbox empties itself.
        .task { await SharedSaveImporter.drain(into: context, route: route) }
        // Only when there is genuinely nothing to show. A returning user who has removed
        // all their brands is a deliberate act, which is what `didOfferStarterPack`
        // remembers.
        .fullScreenCover(isPresented: $isOnboarding) {
            OnboardingView {
                didOfferStarterPack = true
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
        // The answer to sharing in something that's gone. The share extension can't ask —
        // it does no networking, so at share time nobody knows the thing is sold out — and
        // this is the first moment anyone does.
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

    private func decideOnboarding() {
        guard !hasDecidedOnboarding else { return }
        hasDecidedOnboarding = true
        isOnboarding = brands.isEmpty && !didOfferStarterPack
    }
}

#Preview {
    ContentView()
        .modelContainer(PreviewData.container)
}

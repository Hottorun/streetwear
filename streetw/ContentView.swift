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


    /// Dev affordance, matching `-seedBrands` / `-seedSizes`: `-startTab style`
    /// opens straight to a tab so screenshots don't need UI automation.
    @State private var selection = UserDefaults.standard.string(forKey: "startTab") ?? "feed"

    @Query private var brands: [Brand]
    /// Sticky, so skipping the starter pack doesn't offer it again on every launch —
    /// someone who intends to add one brand by hand shouldn't be asked twice.
    @AppStorage("didOfferStarterPack") private var didOfferStarterPack = false

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
            guard settings.isConfigured, remote.lastSyncedAt == nil else { return }
            await remote.sync(sizes: sizes.profile)
        }
        // Also here, not only on `scenePhase`: `onChange` fires on *changes*, and a cold
        // launch has no previous phase to change from — so anything shared while the app
        // was not running would sit in the inbox until the user backgrounded and
        // returned. Draining twice is harmless; the inbox empties itself.
        .task { await SharedSaveImporter.drain(into: context) }
        // Only when there is genuinely nothing to show. A returning user who has removed
        // all their brands is a deliberate act, which is what `didOfferStarterPack`
        // remembers.
        .fullScreenCover(isPresented: .constant(brands.isEmpty && !didOfferStarterPack)) {
            OnboardingView { didOfferStarterPack = true }
        }
    }
}

#Preview {
    ContentView()
        .modelContainer(PreviewData.container)
}

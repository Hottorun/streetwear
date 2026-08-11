//
//  streetwApp.swift
//  streetw
//
//  Created by Dimitris Kern on 09.08.26.
//

import StreetwCore
import SwiftData
import SwiftUI

@main
struct streetwApp: App {
    /// Owns `BGAppRefreshTask` registration and the APNs callbacks, neither of which
    /// SwiftUI exposes. It has to exist before `didFinishLaunching` returns.
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase

    let sharedModelContainer: ModelContainer

    // Built here, not in a `.task`, so they exist before any view body runs. Creating
    // them asynchronously raced with child views' own `.task`s: FeedView could run
    // first, see nil, and silently skip the sync — the server looked "not working".
    @State private var settings: ServerSettings
    @State private var sizes: SizeProfileStore
    @State private var remote: RemoteSync
    @State private var engine: SyncEngine
    @State private var suggestions: BrandSuggestions
    @State private var route: PushRoute

    init() {
        Net.configureSharedCache()
        Appearance.configure()

        let schema = Schema([
            Brand.self, BrandUpdate.self, SavedItem.self, Board.self, StockWatch.self, Fit.self
        ])
        let container: ModelContainer
        do {
            // The store location is pinned explicitly, and that is load-bearing.
            //
            // A default `ModelConfiguration` picks its own location — and once the app
            // gained an App Group entitlement (for the share extension), SwiftData
            // started placing the store in the *shared group container* instead of the
            // app's own. The app then opens an empty database and every brand and save
            // appears to have been wiped, while the real data sits untouched in the old
            // location. Naming the URL keeps existing installs pointed at their data,
            // and stops an unrelated capability from silently moving the database again.
            let storeURL = URL.applicationSupportDirectory.appending(path: "default.store")
            container = try ModelContainer(
                for: schema,
                configurations: [ModelConfiguration(schema: schema, url: storeURL)]
            )
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
        }
        sharedModelContainer = container

        let settings = ServerSettings()
        let sizes = SizeProfileStore()
        let remote = RemoteSync(context: container.mainContext, settings: settings)
        // Built here for the same reason as the rest, and one more: a push that
        // cold-launches the app delivers its tap before any view exists, so the
        // destination has to have somewhere to land before `ContentView` appears.
        let route = MainActor.assumeIsolated { PushRoute() }
        _settings = State(initialValue: settings)
        _sizes = State(initialValue: sizes)
        _remote = State(initialValue: remote)
        _engine = State(initialValue: SyncEngine(context: container.mainContext))
        _suggestions = State(initialValue: BrandSuggestions(remote: remote, settings: settings))
        _route = State(initialValue: route)

        // The app delegate is built by UIKit and can't be handed these, so they are
        // published here — the same moment they become valid.
        MainActor.assumeIsolated {
            BackgroundServices.install(remote: remote, sizes: sizes, settings: settings, route: route)
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(settings)
                .environment(sizes)
                .environment(remote)
                .environment(engine)
                .environment(suggestions)
                .environment(route)
                .task { await DevSeed.runIfRequested(in: sharedModelContainer.mainContext) }
        }
        .modelContainer(sharedModelContainer)
        .onChange(of: scenePhase) { _, phase in
            // Queue the next wake-up on the way out. Submitting while active is allowed
            // but pointless — the system only ever runs it once we're backgrounded.
            if phase == .background { AppDelegate.schedule() }

            // Anything shared while the app was closed is filed on the way back in.
            // On becoming active rather than on launch, because the usual path is
            // share-from-Safari and then switch straight to an app that never quit.
            if phase == .active {
                let context = sharedModelContainer.mainContext
                Task { await SharedSaveImporter.drain(into: context) }
            }
        }
    }
}

/// Dev affordance: launch with `-seedBrands kith.com,bbcicecream.com` to populate the
/// store from real sites without tapping through the add flow. No effect otherwise.
@MainActor
enum DevSeed {
    static func runIfRequested(in context: ModelContext) async {
        seedSizesIfRequested()
        guard let list = UserDefaults.standard.string(forKey: "seedBrands"), !list.isEmpty else { return }

        let existing = (try? context.fetch(FetchDescriptor<Brand>()))?.count ?? 0
        guard existing == 0 else { return }

        let engine = SyncEngine(context: context)
        var brands: [Brand] = []

        for site in list.split(separator: ",").map(String.init) {
            let found = await BrandDiscovery.discover(website: site, instagramHandle: nil)
            let brand = Brand(
                name: found.suggestedName ?? site,
                websiteURL: BrandDiscovery.normalizedURL(site)
            )
            brand.sources = found.sources
            brand.logoURLString = found.logoURL?.absoluteString
            brand.usesGeneratedName = true
            context.insert(brand)
            brands.append(brand)
        }
        try? context.save()

        // Second dev flag: `-seedSizes "M,L,9,9.5"` fills the size profile.
        // First pass establishes the baseline; second marks a slice unseen so the
        // feed has something to render.
        await engine.sync(brands: brands)
        for brand in brands {
            for update in brand.recentUpdates(limit: 6) { update.isSeen = false }
        }
        try? context.save()
    }

    private static func seedSizesIfRequested() {
        guard let raw = UserDefaults.standard.string(forKey: "seedSizes"), !raw.isEmpty else { return }

        var profile = SizeProfile()
        for token in raw.split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces) }) {
            switch SizeNormalizer.normalize(token)?.kind {
            case .apparel: profile.apparel.insert(SizeNormalizer.normalize(token)!.token)
            case .shoe: profile.shoe.insert(SizeNormalizer.normalize(token)!.token)
            default: break
            }
        }
        if let data = try? JSONEncoder().encode(profile) {
            UserDefaults.standard.set(data, forKey: "sizeProfile")
        }
    }
}

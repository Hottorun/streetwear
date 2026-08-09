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
    var sharedModelContainer: ModelContainer = {
        let schema = Schema([
            Brand.self,
            BrandUpdate.self,
            SavedItem.self,
        ])
        let modelConfiguration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)

        do {
            return try ModelContainer(for: schema, configurations: [modelConfiguration])
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
        }
    }()

    init() {
        Net.configureSharedCache()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .task { await DevSeed.runIfRequested(in: sharedModelContainer.mainContext) }
        }
        .modelContainer(sharedModelContainer)
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

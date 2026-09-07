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
    /// What the wearer has said about their own style, in words. Built here with the rest
    /// so a view's `.task` can never see a nil where a preference should be.
    @State private var statement: StyleStatementStore
    @State private var remote: RemoteSync
    @State private var engine: SyncEngine
    @State private var suggestions: BrandSuggestions
    /// The Discover tab's supply. Built here rather than by the view for the reason every
    /// other shared object is: a `.task` that creates it races the child views' own tasks,
    /// and a deck that is nil when the tab first appears looks exactly like a broken feed.
    /// Holding it here also means the pages survive switching tabs.
    @State private var deck: DiscoverDeck
    /// Cutouts and colour for the cards on screen. Held beside the deck so the measurements
    /// survive a tab switch — they are a fetch and two Vision requests each.
    @State private var analysis: DiscoveryAnalysis
    @State private var route: PushRoute
    /// Owned here rather than by a card: the card that triggered a save lives in a
    /// `LazyVStack` and is routinely recycled or scrolled off before the confirmation has
    /// been acted on.
    @State private var confirmation: SaveConfirmation
    /// How the Style tab asks the collection to open at a facet.
    @State private var collection: CollectionRoute
    /// What the server said about each poll hint, so the drop calendar can say per row
    /// whether anything is actually going to be watching. See `DropHintStore`.
    @State private var hints: DropHintStore

    init() {
        Net.configureSharedCache()
        Appearance.configure()

        let schema = Schema([
            Brand.self, BrandUpdate.self, SavedItem.self, Board.self, StockWatch.self, Fit.self,
            BrandDismissal.self, PlannedDrop.self
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
        _statement = State(initialValue: MainActor.assumeIsolated { StyleStatementStore() })
        _remote = State(initialValue: remote)
        _engine = State(initialValue: SyncEngine(context: container.mainContext))
        _suggestions = State(initialValue: BrandSuggestions(remote: remote, settings: settings))
        _deck = State(initialValue: MainActor.assumeIsolated { DiscoverDeck() })
        _analysis = State(initialValue: MainActor.assumeIsolated { DiscoveryAnalysis() })
        _route = State(initialValue: route)
        _confirmation = State(initialValue: MainActor.assumeIsolated { SaveConfirmation() })
        _collection = State(initialValue: MainActor.assumeIsolated { CollectionRoute() })
        _hints = State(initialValue: MainActor.assumeIsolated { DropHintStore() })

        // The app delegate is built by UIKit and can't be handed these, so they are
        // published here — the same moment they become valid.
        MainActor.assumeIsolated {
            BackgroundServices.install(
                remote: remote,
                sizes: sizes,
                settings: settings,
                route: route,
                container: container
            )
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(settings)
                .environment(sizes)
                .environment(statement)
                .environment(remote)
                .environment(engine)
                .environment(suggestions)
                .environment(deck)
                .environment(analysis)
                .environment(route)
                .environment(confirmation)
                .environment(collection)
                .environment(hints)
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
            //
            // **The route is not optional here.** This is the drain that actually runs in
            // that usual path — `ContentView`'s `.task` fires once per appearance and so
            // never sees a share that arrives while the app is already alive. Draining
            // without a route imports the save and then removes it from the inbox, so the
            // sold-out prompt had nothing left to be asked about: the offer to watch
            // something you just shared was unreachable except on a cold launch, and even
            // then only if that `.task` won the race against this.
            if phase == .active {
                let context = sharedModelContainer.mainContext
                // Permission can be granted in iOS Settings, which tells the app nothing.
                // Without this the token is only ever asked for at launch, so somebody who
                // turned alerts on by hand went on receiving none until they next killed the
                // app. See `PushAuthorization.registerIfAuthorized`.
                Task { await PushAuthorization.registerIfAuthorized() }
                // **The feed checks for news because you came back, not because you asked.**
                // This is what replaced the refresh button in the feed's toolbar; see
                // `FeedRefresh` for the throttle and why the two modes get very different
                // ones. Its own `Task`, so a slow storefront cannot hold up the inbox drain
                // below — a share somebody is waiting on outranks a poll nobody asked for.
                Task {
                    await FeedRefresh.runIfStale(
                        remote: remote,
                        engine: engine,
                        settings: settings,
                        sizes: sizes
                    )
                }
                Task {
                    await SharedSaveImporter.drain(
                        into: context,
                        route: route,
                        confirm: confirmation
                    )
                    // After the inbox, never before it: a share that just arrived is what
                    // somebody is waiting on, and the repair queue is a backlog nobody
                    // asked about. Both announce nothing — a bookmark quietly becoming a
                    // product page is not news.
                    SharedSaveImporter.attachBrands(in: context)
                    await SharedSaveImporter.repair(in: context)
                    // Last of the three, because the other two can make it unnecessary: a
                    // real brand outranks whatever a site says about itself.
                    await SharedSaveImporter.identifySites(in: context)
                    // Costs no network and is why the feed does not re-classify its whole
                    // store on every render — see `Classification`.
                    Classification.settleGenders(in: context)
                    // And whether each row is clothing at all, which is what keeps gift
                    // cards and size charts out of the feed without a classifier running
                    // per row per render. See `BrandUpdate.isMerchandise`.
                    Classification.settleMerchandise(in: context)
                    // Same reason, for the date the feed orders brands by: without it,
                    // every brand followed before the field existed makes the feed walk
                    // its whole catalogue to work out where the spread goes.
                    Classification.settleActivityDates(in: context)
                    // **The reminders are re-scheduled here as well as when one is edited,
                    // and the reason is permission.** A drop can be written down before
                    // notifications are allowed — that is the ordinary order of events, since
                    // the reason to allow them is having something to be told about — and the
                    // grant happens in iOS Settings, where this app is not running. Nothing
                    // would ever go back and schedule the alerts, and the failure is silent
                    // in the worst way: the row sits on Upcoming looking armed, and the drop
                    // passes without a word. It is a rewrite from the store, so running it
                    // on every foreground costs a handful of writes and is the repair for
                    // every other way this can drift too.
                    await DropReminders.refresh(in: context)
                    // And the server's half of the same fact. The reminder fires at eleven;
                    // this is what makes the products be *there* at eleven, on the brands
                    // whose rhythm the poller cannot read. On foreground for the same
                    // reason the line above is — a drop written down offline, or on a build
                    // before this existed, would otherwise never be sent — and it costs
                    // nothing when the set has not changed. See `DropHints`.
                    await DropHints.refresh(in: context, via: remote, status: hints)
                }
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
        await seedBrandsIfRequested(in: context)
        // **Not only inside `-seedBrands`.** It was called at the tail of the brand seed and
        // nowhere else, so in server mode — where brands arrive from the sync rather than
        // from the flag — the flag was documented in CLAUDE.md as independent and silently
        // did nothing. It reads the store now, so it works whichever way the catalogue got
        // there; `ContentView` calls it again after the launch sync, because on a fresh
        // server-mode install the store is still empty at this point.
        seedSavesIfRequested(in: context)
    }

    private static func seedBrandsIfRequested(in context: ModelContext) async {
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

    /// Third dev flag: `-seedSaves 8` files a few garments into the wardrobe.
    ///
    /// This exists because the Discover tab's whole argument — *this goes with clothes you
    /// already own* — is invisible without a wardrobe, and building one by hand means
    /// tapping save eight times through a scrolling feed on every fresh install. Worse, the
    /// interesting case is not "eight saves" but "eight saves **across complementary
    /// slots**": `Pairing` gates on slot before it scores anything, so eight t-shirts
    /// produce exactly no pairings and the screen looks broken in a way that is entirely the
    /// seeding's fault.
    ///
    /// So it fills slots round-robin rather than taking the newest N, and it takes only
    /// garments with a photograph — the same rule every surface that draws a save applies.
    /// Idempotent and cheap to call twice: it does nothing once anything has been saved, so
    /// `ContentView` can call it again after the launch sync without checking anything.
    static func seedSavesIfRequested(in context: ModelContext) {
        let raw = UserDefaults.standard.string(forKey: "seedSaves") ?? ""
        guard let wanted = Int(raw), wanted > 0 else { return }

        let existing = (try? context.fetch(FetchDescriptor<SavedItem>()))?.count ?? 0
        guard existing == 0 else { return }

        // Whatever is in the store, however it got there — seeded by `-seedBrands`, or
        // synced from the server.
        let brands = (try? context.fetch(FetchDescriptor<Brand>())) ?? []
        guard !brands.isEmpty else { return }

        // Grouped by where it goes on the body, so the wardrobe spans slots that can
        // actually be worn together.
        var bySlot: [GarmentSlot: [BrandUpdate]] = [:]
        for brand in brands {
            for update in brand.updates where !update.imageURLStrings.isEmpty {
                let slot = update.garmentSlot
                guard GarmentSlot.essential.contains(slot) else { continue }
                bySlot[slot, default: []].append(update)
            }
        }

        var picked: [BrandUpdate] = []
        var round = 0
        while picked.count < wanted {
            let available = GarmentSlot.essential.filter { (bySlot[$0]?.count ?? 0) > round }
            guard !available.isEmpty else { break }
            for slot in available where picked.count < wanted {
                picked.append(bySlot[slot]![round])
            }
            round += 1
        }

        for update in picked {
            context.insert(SavedItem(update: update, type: .wardrobe))
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

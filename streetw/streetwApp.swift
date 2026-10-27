//
//  streetwApp.swift
//  Dropwall
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

    // Built here, not in a `.task`, so they exist before any view body runs. Creating
    // them asynchronously raced with child views' own `.task`s: FeedView could run
    // first, see nil, and silently skip the sync — the server looked "not working".
    @State private var settings: ServerSettings
    /// The account's profiles and the current one's `ProfileSession` — its store, sizes, style
    /// statement, sync, Discover deck, recommendations, save confirmation, collection route and
    /// drop-hint status. Everything about one person lives there and is rebuilt on a switch;
    /// what stays here is about the phone. See `docs/profiles.md`.
    @State private var profiles: ProfileStore
    /// Cutouts and colour for the cards on screen. Held at the app rather than in a profile's
    /// session: they are measurements of photographs, not of a person, and they survive a tab
    /// switch — they are a fetch and two Vision requests each.
    @State private var analysis: DiscoveryAnalysis
    @State private var route: PushRoute
    /// Whether the You page is up. One for the app, so the page is presented once from the
    /// root whichever tab's avatar was tapped — see `YouRoute`.
    @State private var you: YouRoute
    /// Which country's shops the account is served. **The account's, not a profile's** — a
    /// profile is somebody you shop for, and the shop is still where you are — so it is held
    /// here, read by every profile's `RemoteSync`, and survives a switch. See `docs/profiles.md`.
    @State private var location: LocationSetting
    /// The balance and the packs, and the listener that credits an interrupted purchase.
    /// Built here because the listener must be running before StoreKit delivers anything —
    /// see `CreditStore.start`. **The account's, not a profile's**: every profile spends from
    /// the one ledger, so a switch must neither rebuild it nor ask the server again.
    @State private var credits: CreditStore
    /// Whether the model-backed actions exist here and what each costs — and the one way to
    /// call them, which hands every charge to `credits`. The account's, for `credits`' reason.
    /// See `AIStore`.
    @State private var ai: AIStore

    init() {
        Net.configureSharedCache()
        Appearance.configure()

        let settings = ServerSettings()
        let location = MainActor.assumeIsolated { LocationSetting() }
        // Built here for the same reason as the rest, and one more: a push that
        // cold-launches the app delivers its tap before any view exists, so the
        // destination has to have somewhere to land before `ContentView` appears.
        let route = MainActor.assumeIsolated { PushRoute() }
        // The store is opened inside, for whichever profile is current — the holder's is the
        // `default.store` every earlier build wrote. The app delegate is built by UIKit and
        // can't be handed these, so each session is published the moment it becomes valid.
        let profiles = MainActor.assumeIsolated {
            ProfileStore(settings: settings, location: location) { session in
                BackgroundServices.install(
                    remote: session.remote,
                    sizes: session.sizes,
                    settings: settings,
                    route: route
                )
                UsageCounts.install(settings: settings, remote: session.remote)
            }
        }
        MainActor.assumeIsolated { BackgroundServices.profiles = profiles }
        let credits = MainActor.assumeIsolated { CreditStore(settings: settings) }
        MainActor.assumeIsolated { credits.start() }
        _location = State(initialValue: location)
        _credits = State(initialValue: credits)
        _ai = State(initialValue: MainActor.assumeIsolated { AIStore(settings: settings, credits: credits) })
        _settings = State(initialValue: settings)
        _profiles = State(initialValue: profiles)
        _analysis = State(initialValue: MainActor.assumeIsolated { DiscoveryAnalysis() })
        _route = State(initialValue: route)
        _you = State(initialValue: MainActor.assumeIsolated { YouRoute() })
    }

    var body: some Scene {
        WindowGroup {
            let session = profiles.session
            ContentView()
                // **Keyed on the profile.** Every `@State` and `@Query` below belongs to one
                // person's store, and a switch must rebuild them against the new one rather than
                // carry a feed, a scroll position or a half-made save across.
                .id(session.scope)
                .environment(settings)
                .environment(profiles)
                .environment(session.sizes)
                .environment(location)
                .environment(credits)
                .environment(ai)
                .environment(session.statement)
                .environment(session.remote)
                .environment(session.engine)
                .environment(session.suggestions)
                .environment(session.deck)
                .environment(analysis)
                .environment(route)
                .environment(session.confirmation)
                .environment(session.collection)
                .environment(you)
                .environment(session.hints)
                .environment(session.followPrompt)
                .modelContainer(session.container)
                .task {
                    await DevSeed.runIfRequested(in: session.container.mainContext)
                    // Screenshot affordance: `-demoOpen <externalID>` lands on one product
                    // page, through the same route a notification tap takes.
                    if let id = UserDefaults.standard.string(forKey: "demoOpen"), !id.isEmpty {
                        route.open(.update(externalID: id))
                    }
                }
        }
        .onChange(of: scenePhase) { _, phase in
            // Whoever is current at the moment of the change, captured once: the work below
            // runs for one person's store even if somebody switches while it is in flight.
            let session = profiles.session
            // Queue the next wake-up on the way out. Submitting while active is allowed
            // but pointless — the system only ever runs it once we're backgrounded.
            if phase == .background {
                AppDelegate.schedule()
                UsageCounts.reportOnTheWayOut()
                #if DEBUG
                AppDelegate.debugPassIfRequested()
                #endif
            }

            // The Discover ledger is written in batches rather than once per card — see
            // `DiscoverDeck.markSeen` — so leaving the foreground is where it gets settled.
            // `.inactive` as well as `.background`: that is the phase a swipe-up to the app
            // switcher reaches, and the one before a kill.
            if phase != .active { session.deck.persistSeen() }

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
                let context = session.container.mainContext
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
                        remote: session.remote,
                        engine: session.engine,
                        settings: settings,
                        sizes: session.sizes
                    )
                    // After the refresh rather than beside it: if the token has gone stale,
                    // the sync is what notices and re-registers, and a report racing it
                    // would try the same repair at the same moment.
                    await UsageCounts.report()
                }
                Task {
                    await SharedSaveImporter.drain(
                        into: context,
                        scope: session.scope,
                        route: route,
                        confirm: session.confirmation
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
                    await DropReminders.refresh(in: context, scope: session.scope)
                    // And the server's half of the same fact. The reminder fires at eleven;
                    // this is what makes the products be *there* at eleven, on the brands
                    // whose rhythm the poller cannot read. On foreground for the same
                    // reason the line above is — a drop written down offline, or on a build
                    // before this existed, would otherwise never be sent — and it costs
                    // nothing when the set has not changed. See `DropHints`.
                    await DropHints.refresh(in: context, via: session.remote, status: session.hints)
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
        DemoCatalog.seedIfRequested(in: context)
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
        // First pass establishes the baseline; second turns a slice into news so the
        // feed has something to render, arriving when each was published. A dozen per brand
        // by default; `-seedNews 400` makes the feed as deep as a busy follow list, which is
        // what its speed has to be measured against.
        //
        // Garments only. A baseline's newest rows are mostly `/collections.json` furniture —
        // Kith's newest 241 were all collections — and real news never looks like that:
        // after the baseline a collection is announced only once its stock says it is one.
        await engine.sync(brands: brands)
        let slice = Int(UserDefaults.standard.string(forKey: "seedNews") ?? "") ?? 12
        for brand in brands {
            let garments = brand.updates.filter { [.product, .restock, .priceDrop].contains($0.kind) }
            for update in BrandUpdate.oncePerProduct(garments).prefix(slice) {
                update.arrive(at: update.publishedAt)
            }
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

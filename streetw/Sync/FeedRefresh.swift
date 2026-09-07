// FeedRefresh.swift
// When the feed goes and looks, and who asks it to.
//
// **There is no refresh button.** It sat in the feed's toolbar as a fourth icon beside
// watching, upcoming and markdowns — the one control there that was not a door onto
// anything, competing for attention with three that are, on the screen whose whole subject
// is a list of photographs. It was also asking the reader to do the app's job: a feed that
// needs to be told to check is a feed that is, until you tell it, quietly out of date.
//
// Two things replace it, and between them they cover every moment somebody would have
// reached for it:
//
// - **Coming back to the app.** This is when the question is actually being asked — you
//   opened it to see whether anything happened — so it is answered before anybody has to
//   ask. Throttled, because `scenePhase` goes active for a glance at the lock screen as
//   readily as for a session.
// - **Pulling down.** The impatient case, and the one gesture everybody already tries. It
//   was always attached (`.refreshable`); the button was a second way to do a thing the
//   list already did, and the only one of the two that took up space.
//
// The intervals differ by an order of magnitude and that is the whole reason this is a type
// rather than two literals. In server mode a refresh is one request against a poller that
// has already done the fetching for everybody, so it can be cheap and often. Standalone,
// the phone fetches every followed storefront itself — so the throttle is the brand's own
// cadence, not the reader's patience, and a foreground pass every few minutes would be this
// app hammering shops it is a guest of. `PoliteFetcher`'s argument, one layer up.

import Foundation

@MainActor
enum FeedRefresh {
    /// One request to a server that is already polling on everybody's behalf.
    static let serverInterval: TimeInterval = 60

    /// The phone doing the polling itself. Matches the ordinary source cadence — asking
    /// more often cannot produce anything new and is fetching from storefronts for nothing.
    static let standaloneInterval: TimeInterval = 20 * 60

    /// Deliberate: a pull is somebody saying "look now" and is never throttled.
    static func run(
        remote: RemoteSync,
        engine: SyncEngine,
        settings: ServerSettings,
        sizes: SizeProfileStore
    ) async {
        if settings.isConfigured {
            await remote.sync(sizes: sizes.profile)
        } else {
            await engine.syncAll()
        }
    }

    /// The foreground pass. Silent when it decides not to run, and silent when it does —
    /// the feed simply has more in it, which is what the reader came to find out.
    ///
    /// The throttle is on the last *attempt*, not the last success. A sync that failed is
    /// exactly the one worth trying again on the next foreground — but it must still be
    /// spaced, or a server that is down turns every glance at the app into another request.
    ///
    /// Nil means nothing has run yet this launch, and that case is left to `ContentView`'s
    /// launch task rather than raced with here: both guard on `isSyncing`, so a double call
    /// is harmless, but a cold launch already has a sync in flight and starting a second is
    /// noise.
    static func runIfStale(
        remote: RemoteSync,
        engine: SyncEngine,
        settings: ServerSettings,
        sizes: SizeProfileStore,
        now: Date = Date()
    ) async {
        let last = settings.isConfigured ? remote.lastAttemptedAt : engine.lastSyncedAt
        guard let last else { return }
        let interval = settings.isConfigured ? serverInterval : standaloneInterval
        guard now.timeIntervalSince(last) >= interval else { return }
        await run(remote: remote, engine: engine, settings: settings, sizes: sizes)
    }
}

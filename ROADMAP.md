# streetw — roadmap

## Positioning

A calm, private archive of the clothes you care about, that also happens to know when they drop.
The differentiator is the combination: drop apps are utilitarian and loud, save apps don't track
unreleased items. Nobody has done both.

Two modes, kept deliberately distinct:

- **Hype feed** — time-sensitive, ephemeral, countdowns, urgency affordances allowed.
- **Collection** — permanent, private, no badges, no counts, no "new" dots.

## Decided

- **Server-backed.** A small backend polls sources on a schedule and pushes via APNs. iOS
  `BGAppRefreshTask` is opportunistic — a few system-chosen wakeups a day — and drops resolve in
  minutes, so client-only polling cannot support drop, restock or shock-drop alerts.
- **Instagram is never scraped.** Link-out only. The `BrandSource.Kind.instagram` slot stays
  adapter-less; if a best-effort third-party "teased something" flag is ever added it goes there,
  and everything else keeps working when it breaks.

### Explicitly out of scope

| | Why |
|---|---|
| Resale price pull-in (StockX/GOAT) | No public API; third-party resellers are expensive and unstable |
| Raffle autofill | Even single-entry is substantial work and bot-adjacent; not needed now |
| Social / community feed | Different product, cold-start problem, fights the calm-archive positioning |

## Phase 1 — make the existing app trustworthy ✅

Done. Measured against Kith and Billionaire Boys Club.

- [x] **Paginate `products.json`.** Sorted by `published_at` desc, and `limit=250` (the max page
      size) covered only ~4 days of Kith. Now walks up to 10 pages and stops as soon as a page ends
      older than the last sync: **250 → 2,500 products** for Kith on a first sweep (11s), while an
      incremental sync still stops after one page. This also fixes restock detection for older
      items, which never re-entered the 250 window because restocking doesn't change `published_at`.
- [x] **Per-variant availability.** 2,353 of Kith's 2,500 products carry real sizes. Restocks now
      diff per variant and record which sizes returned — cards read "Back in M, L".
- [x] **Size profile.** Sizes come from the option axis actually *named* "Size" (Kith ships
      `[Size]`, BBC ships `[Color, Size]`, so position isn't fixed) rather than being parsed out of
      a joined title like "WHITE/OWHITE/CBROWN / 5". `SizeNormalizer` folds "medium"/"M",
      "9.0"/"9"/"US 9"/"US9" together. Feed gains a "my size" filter and a "Your size" badge;
      verified in the simulator, 12 → 10 items when filtered to M, L, XL · US 9, 9.5.
      Deliberate rule: **unrecognised sizing is never hidden.** EU ("44") and waist ("32") numbers
      fall through to `.other` and always match, because a missed drop costs far more than a
      false positive. `SizeProfile`/`SizeNormalizer` live in the portable layer — the server needs
      exactly this logic to target restock pushes.
- [x] **Per-shop currency + real brand name from `/meta.json`.** Replaced the USD assumption and the
      hostname guess — "Bbcicecream" is now "Billionaire Boys Club". Only overwrites the name while
      the user has kept our generated guess (`Brand.usesGeneratedName`).
- [x] **Conditional GETs.** `ETag` stored per source and replayed as `If-None-Match`; verified
      returning 304 on an unchanged catalog, so a poll costs an empty body instead of megabytes.
- [x] **Per-source backoff** — `2^failures` minutes, capped at 6h (`BrandSource.isReadyToCheck`).
- [x] **Concurrent brand sync** via `TaskGroup`, previously strictly serial.
- [x] **Disk image cache** — `URLCache.shared` configured at launch (32MB memory / 512MB disk);
      `AsyncImage` goes through `URLSession.shared` and was refetching on every scroll.
- [x] **Retention/pruning** — 400 newest per brand, never dropping saved or unread items.
      Verified: 3,931 fetched → 800 stored.
- [x] **Surface `source.lastError`** including failure count and backoff state.

### Keep the adapter layer portable

`streetw/Sources/` must stay free of SwiftData, SwiftUI and UIKit so it can be lifted into the
server target unchanged. `UpdateKind` and `VariantInfo` were extracted out of the `@Model`
`BrandUpdate` for exactly this reason — `BrandUpdate.Kind` is now just a typealias. The layer
compiles standalone with no shim; keep it that way.

## Phase 2 — the backend ✅

Done. See `BACKEND.md` for the reasoning and `Server/README.md` for how to run it.

Two things are built but not yet switched on, and neither is code: the server needs an
APNs key in its environment, and the app target needs the Push Notifications capability
(a paid team). Until then the whole pipeline runs and `/status` reports
`apnsConfigured: false` rather than pretending.

- [x] **SwiftPM monorepo + `StreetwCore` extraction.** Adapters, sizing and discovery moved to
      `Sources/StreetwCore/`; the app links it as a local package. Adapters now take an injected
      `HTTPClient`, which is what makes them testable and what will let the server swap in its own
      rate-limited client.
- [x] **First test target** — 40 fixture-driven swift-testing tests, no network. Building the
      package in Swift 6 mode immediately found a real data race (shared `DateFormatter`s used from
      the concurrent sync task group), and the tests found a real bug: a drop-lock was keyed so that
      it could only ever fire once per source, so a brand's *second* drop would never alert.
- [x] **Vapor skeleton, migrations, poller.** `Server/` is a separate SwiftPM package
      depending on `StreetwCore` by path, so the iOS project never resolves Vapor. Postgres
      in production, SQLite locally (array columns are `.json`, so one migration serves both).
      Verified end to end against live Kith and BBC: discovery → 1,461 products / 25k variants
      stored → **zero events on the first poll** (baseline) → a forced restock produced one
      event with `restockedSizes: ["M"]` and `availableInMySize: true` for a matching device.
      Now 32 tests, no network.
- [x] **Client syncs from the server.** Wire types moved to `StreetwCore` so app and
      server share one contract. The app registers a device, follows brands server-side,
      and fills its SwiftData store from `/v1/feed` — the whole UI, saving, style profile
      and size filter keep working unchanged. Standalone mode still works when no server
      is set. Verified end to end against a live server: restock detected → phone synced →
      feed shows "2 restocked · Back in M".
- [x] **All client operations routed through the server.** Audited and verified on the
      wire: register, size-profile push, site probe (dry run), add brand, follow, unfollow,
      feed sync. Local polling remains only as the standalone fallback when no server is
      configured.
- [x] **Deployed.** Railway, Postgres, poller running. The app ships the deployment URL as
      `ServerSettings.defaultBaseURLString`, applied only when nothing has been stored yet,
      so a fresh install is server-backed with no setup and an explicitly cleared field
      still means standalone.
- [x] **Fixed: every Postgres write touching a `[String]` column failed.** Device
      registration 500'd and the poller stored zero products, while brand and source
      writes on the same database succeeded — the difference being that only the former
      touch array columns. Fluent binds `[String]` as a native Postgres array, but
      `CreateSchema` declares those columns `.json` → JSONB, so Postgres rejects the
      insert. SQLite JSON-encodes instead, so it never reproduced locally, and production
      `ErrorMiddleware` reduced it to "Something went wrong."
      `FixPostgresArrayColumns` converts the five columns to `TEXT[]`; `/status` now also
      counts `users`, the one table whose absence from that check let a fully broken
      registration path report green. Deployed and confirmed live: `POST /v1/devices`
      returns a token and `users`/`devices` count up, where before it 500'd.
- [x] **Background refresh on the client.** `BGAppRefreshTask` registered in an
      `AppDelegate` and re-queued whenever the app backgrounds, so the feed is warm
      before it is opened. Explicitly the *fallback*, not the mechanism — the system
      grants a handful of wakeups a day, which is fine for staleness and useless for a
      drop. `UIBackgroundModes` and `BGTaskSchedulerPermittedIdentifiers` had to move
      into a real `streetw-Info.plist`: Xcode silently drops both as `INFOPLIST_KEY_*`
      settings, and the failure only shows up as a refused registration at runtime.
- [x] **Device registration → APNs, size-targeted restock pushes.** The server holds the
      size profile, so it can decide that a restock in M is news for one follower and
      not another — that targeting is the whole reason the profile lives server-side.
      Fan-out is behind a `PushSending` protocol, so who-gets-what is covered by 10 tests
      with no certificate and no network. Two rules shaped it: **one push per brand per
      pass** (a collection drop writes hundreds of events in one poll, and that has to be
      one notification), and **`notified_at` as a ledger in the row**, so a restart can't
      re-notify and a backlog older than 6 h is marked without being sent rather than
      fired as a burst about drops that already sold out. A token APNs rejects is
      forgotten; the device row survives, because it owns the follows.
      **Not yet live:** needs an APNs key on the server (`APNS_KEY_P8`/`_KEY_ID`/`_TEAM_ID`)
      and the Push Notifications capability on the app target, which needs a paid team.
      Without either, everything else works and `/status` says `apnsConfigured: false`.
- [x] **Fixed: a failed poll silently spent the brand's baseline.** Fallout from the
      array-column bug rather than a separate mistake — while writes were failing, Kith
      polled repeatedly and stamped `last_checked_at` each time without storing anything.
      The baseline rule keyed off that field, so the first working poll looked incremental
      and wrote **250 back-catalogue products as new-drop events**. Sources now carry
      `baselined_at`, set only once a fetch has completed and its batch is stored, and
      `SyncEngine` on the client got the same rule: `lastSyncedAt` is stamped only when a
      source actually succeeded. Two regression tests cover it.
- [x] **Politeness budget.** `PoliteFetcher` wraps any fetcher: robots.txt fetched once
      per host and obeyed (longest-match Allow/Disallow, wildcards, Crawl-delay, named
      groups), plus a reserved-slot limiter that spaces requests per host even under
      concurrency. The browser-spoofing User-Agent is gone — an honest
      `streetw/1.0 (+repo url)` was verified to get 200s from the storefronts we actually
      poll, so impersonation bought nothing and being identifiable is what keeps access.
- [x] **`FOR UPDATE SKIP LOCKED` on the poll queue.** The claim is a *lease*: a single
      statement takes the due batch and pushes `next_check_at` five minutes out before
      any network call, so two instances can never fetch the same storefront (which would
      multiply the politeness budget by the instance count) and a process killed
      mid-poll costs one lease rather than stranding the brand. Postgres only; SQLite has
      neither the syntax nor a second instance to protect against.
- [x] **Retention server-side.** Events past 30 days that have already been notified,
      then products unseen for 180 days with no events left. The ordering is
      load-bearing in both directions: `events.product_id` is `ON DELETE CASCADE`, so
      pruning a product first would silently delete feed history — and deleting a product
      the source still lists makes the next poll announce it as a new drop, i.e.
      retention manufacturing a fake release. The phone already keeps far less (400 per
      brand, never dropping saved or unread) and pages the rest from here.

## Phase 3 — alerts and the round app

- [x] **A visual identity.** The app was stock SwiftUI forms; it now has a design system
      (`streetw/Views/DesignSystem.swift`): an achromatic gallery palette where photographs
      carry all the colour, and exactly one accent — vermilion — rationed to things that are
      time-critical. Three type roles rather than SF at four sizes: **New York** for titles,
      tracked SF caps for brand wordmarks, **SF Mono** for sizes, prices and times.
      The signature element is the **size run**, a product's sizes printed as type with
      sold-out struck through and yours ruled in vermilion — the size profile finally
      *visible* rather than implied. Long runs narrow to what's buyable, because a sneaker
      runs 5–13 in half sizes and an overflowing row truncates every token to an ellipsis.
      The feed is laid out lead-plus-briefs per brand, which is load-bearing rather than
      decorative: a brand can publish 250 items in one poll and a flat list of equal rows is
      unreadable.
- [x] **Brand marks.** Brands show their own logo, taken from the icon their site
      publishes for home screens (`BrandMark` in StreetwCore) — the brand's own file,
      served for exactly that purpose, so no scraping and no third-party logo API.
      Ranked by intent, then decodability, then size: raster beats vector because
      `UIImage` cannot decode SVG and one would silently become a monogram. Shopify CDN
      URLs get their size parameters rewritten from 32px to 180px, since nearly every
      storefront declares only a favicon. Falls back to initials, which is not a rare
      path — BBC declares only an SVG. `/favicon.ico` is a guess rather than a floor:
      Shopify 404s it.
- [ ] Push: new drop · restocked in your size · storefront locked (drop imminent)
- [ ] **Shock-drop alerts** — mostly built already: `PageWatchSource` plus the `dropLock` signal
      (401/403 or redirect to `/password`) is exactly the unannounced-release detector. It only
      needs push behind it.
- [ ] Drop calendar — upcoming releases, filterable by brand/category; needs `releaseDate` on
      `BrandUpdate`
- [ ] **Share Extension** — save from any site in Safari, not just tracked brands. This is what
      makes it an archive rather than a feed reader.
- [ ] Onboarding starter pack — the empty state is currently a dead end
- [ ] Search across saves
- [ ] Widget + Live Activity for countdowns

## Phase 4 — the collection, properly

- [x] **Split `UpdateCard`.** Done early, because the restyle forced the issue: `FeedLead`
      and `FeedTile` carry time, price, stock and the accent, while `CollectionTile`
      carries none of it. The hype/calm distinction is now a data boundary rather than a
      visual one, exactly as this list predicted one shared card would fail to be.
- [x] **Masonry, image-first grid.** Saved is a staggered two-column wall — hand-split
      into columns rather than a `LazyVGrid`, which forces every row to its tallest cell
      and flattens a wall back into a table. Still driven by a deterministic hash of the
      item id rather than by real image dimensions; deterministic on purpose, because a
      collection that reflows while you look at it is the opposite of calm.
- [ ] Quick-save gesture — swipe from feed straight to a board, no modal
- [ ] Auto-tagging via Vision (dominant colour, silhouette) — replaces the text-vocabulary guessing
      in `StyleProfile` and is what makes boards self-organise
- [ ] Boards, private by default
- [ ] Notes and size annotations per saved item

## Known gaps not yet scheduled

- Real image dimensions for the collection wall, so tile heights match the photographs
- An entry point for server settings and the notification prompt: both were removed from
  the Style tab, so there is currently no way in the app to change the server URL or grant
  notification permission. The shipped default server means nothing is broken today, but
  push cannot be switched on without a prompt somewhere.
- Sitemap-based discovery for non-Shopify brands
- Shopify `/collections.json` for collection-level drops
- `updated_at` for silent product edits (price changes, description rewrites)

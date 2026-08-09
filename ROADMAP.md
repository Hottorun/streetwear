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

## Phase 2 — the backend

See `BACKEND.md` for the full plan.

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
      12 tests, no network.
- [x] **Client syncs from the server.** Wire types moved to `StreetwCore` so app and
      server share one contract. The app registers a device, follows brands server-side,
      and fills its SwiftData store from `/v1/feed` — the whole UI, saving, style profile
      and size filter keep working unchanged. Standalone mode still works when no server
      is set. Verified end to end against a live server: restock detected → phone synced →
      feed shows "2 restocked · Back in M".
- [ ] Background refresh on the client so the feed is warm before the app opens
- [ ] Device registration → APNs, size-targeted restock pushes
- [x] **Politeness budget.** `PoliteFetcher` wraps any fetcher: robots.txt fetched once
      per host and obeyed (longest-match Allow/Disallow, wildcards, Crawl-delay, named
      groups), plus a reserved-slot limiter that spaces requests per host even under
      concurrency. The browser-spoofing User-Agent is gone — an honest
      `streetw/1.0 (+repo url)` was verified to get 200s from the storefronts we actually
      poll, so impersonation bought nothing and being identifiable is what keeps access.
- [ ] `FOR UPDATE SKIP LOCKED` on the poll queue, once there's more than one instance
- [ ] Retention server-side; the phone then keeps a much smaller window

## Phase 3 — alerts and the round app

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

- [ ] Masonry, image-first grid
- [ ] Quick-save gesture — swipe from feed straight to a board, no modal
- [ ] Auto-tagging via Vision (dominant colour, silhouette) — replaces the text-vocabulary guessing
      in `StyleProfile` and is what makes boards self-organise
- [ ] Boards, private by default
- [ ] Notes and size annotations per saved item
- [ ] Split `UpdateCard` — the hype/calm distinction should become a data boundary, not just a
      visual one; feed and collection sharing one card component won't survive past v1

## Known gaps not yet scheduled

- Sitemap-based discovery for non-Shopify brands
- Shopify `/collections.json` for collection-level drops
- `updated_at` for silent product edits (price changes, description rewrites)

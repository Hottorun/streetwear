# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

`streetw` is an iOS app (SwiftUI + SwiftData, iOS 26.5 deployment target) that watches streetwear
brands for new drops, restocks and collections, and builds a style profile from what you save.
Bundle ID `com.kern.functional.streetw`, signed by team `JD6NETLE45` (KERN AG).

The repo holds **three things** — a shared library, an iOS app, and a server:

```
Package.swift            StreetwCore library + tests
Sources/StreetwCore/     adapters, sizing, discovery — no SwiftData/SwiftUI/UIKit
Tests/StreetwCoreTests/  swift-testing, fixture-driven, no network
streetw/                 the iOS app (Models/, Views/, Sync/)
Shared/                  in BOTH app and extension targets — the App Group inbox contract
ShareExtension/          share-sheet extension target
streetw.xcodeproj        app + ShareExtension targets; links StreetwCore as a local package
Server/                  SEPARATE SwiftPM package: Vapor + Fluent poller and API
```

`Server/` is deliberately its own package depending on the root by path. If Vapor were a
root dependency, opening the iOS app in Xcode would resolve and build the whole server
tree. Run `swift build`/`swift test` from `Server/` for it, from the root for the library,
and `xcodebuild` for the app. `Server/README.md` covers running it; `BACKEND.md` covers why
it exists.

## Build environment

**`xcode-select` on this machine points at CommandLineTools, not Xcode.** Every `xcodebuild` /
`simctl` invocation must set `DEVELOPER_DIR` or it fails with "requires Xcode":

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
```

**In-editor SourceKit diagnostics are mostly false.** The same CommandLineTools toolchain lacks the
SwiftData macro plugin, so the language server floods every model and view file with
`External macro implementation type 'SwiftDataMacros.PersistentModelMacro' could not be found` and
cascading `Cannot find type 'Brand' in scope`. **Only `xcodebuild` output is authoritative** — do not
chase these, and do not "fix" code in response to them.

**The deployment target is 26.5, so most installed simulators cannot run it.** The iPhone 16 family
here is on iOS 18.3/18.5 and `xcodebuild` rejects them as "no device matching destination". Pick a
26.5 device:

```bash
xcrun simctl list devices available | sed -n '/-- iOS 26.5 --/,/^--/p'
```

**Xcode holds a lock on the shared DerivedData build.db.** If Xcode is open, a CLI build dies with
"database is locked"; pass `-derivedDataPath` to build somewhere else.

**`swift test` also needs `DEVELOPER_DIR`.** The swift-testing `Testing` module ships with Xcode's
toolchain, not CommandLineTools, so without it every test file fails with `no such module 'Testing'`
before anything runs.

**Not every Info.plist key can be a build setting.** The target uses `GENERATE_INFOPLIST_FILE`, but
Xcode silently ignores `INFOPLIST_KEY_UIBackgroundModes` and
`INFOPLIST_KEY_BGTaskSchedulerPermittedIdentifiers` — the build succeeds and the keys are simply
absent, which surfaces much later as `BGTaskScheduler` refusing the identifier at runtime. Those two
live in `streetw-Info.plist`, which `INFOPLIST_FILE` points at and Xcode merges the generated keys
over. It sits beside the `.xcodeproj` rather than in `streetw/`, because that directory is a
synchronized root group and an Info.plist inside it would also be copied in as a resource. Verify
additions landed by reading the built bundle, never by trusting the setting:

```bash
plutil -p /tmp/streetw-dd/Build/Products/Debug-iphonesimulator/streetw.app/Info.plist
```

### Build and run

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
DEVICE=<udid-of-an-iOS-26.5-device>

xcodebuild -project streetw.xcodeproj -scheme streetw \
  -destination "platform=iOS Simulator,id=$DEVICE" \
  -derivedDataPath /tmp/streetw-dd build

xcrun simctl install "$DEVICE" /tmp/streetw-dd/Build/Products/Debug-iphonesimulator/streetw.app
xcrun simctl launch "$DEVICE" com.kern.functional.streetw
xcrun simctl io "$DEVICE" screenshot shot.png
```

First boot of a fresh 26.5 simulator takes ~4 minutes; run `simctl bootstatus` in the background
rather than blocking a foreground call on it.

Dev-only launch flags (all read via `UserDefaults`, all no-ops when absent):

| Flag | Effect |
|---|---|
| `-seedBrands kith.com,bbcicecream.com` | Populates the store from real sites, skipping the add flow |
| `-seedSizes "M,L,9,9.5"` | Fills the size profile |
| `-startTab style` | Opens straight to a tab, so screenshots need no UI automation |

`-seedSizes` writes `UserDefaults` from a `.task`, which runs *after* `SizeProfileStore` is
constructed — the profile only takes effect on the **next** launch.
Inspect what landed by querying the store directly:

```bash
DB="$(xcrun simctl get_app_container "$DEVICE" com.kern.functional.streetw data)/Library/Application Support/default.store"
sqlite3 "$DB" "select (select count(*) from ZBRAND), (select count(*) from ZBRANDUPDATE), (select count(*) from ZBRANDUPDATE where ZISSEEN=0);"
```

### Driving the simulator UI

`simctl` cannot tap. Clicks must be posted as `CGEvent`s against the Simulator window, which needs
Accessibility permission for the terminal. Build a throwaway clicker with
`CGEvent(mouseEventSource:mouseType:mouseCursorPosition:mouseButton:)` posting
`.mouseMoved` → `.leftMouseDown` → `.leftMouseUp`.

Coordinate mapping, measured on this setup (window at 612,20 sized 456×972, bezels shown, zoom 1:1):

```
screenX = windowX + 27 + devicePointX
screenY = windowY + 69 + devicePointY
```

**Switches need a longer synthetic press.** A ~90ms down/up flips buttons and tab items
but not `Toggle`/`UISwitch` — hold ~300ms. Two "the tap isn't landing" investigations
turned out to be this, not coordinates.

Verify the scale before trusting it — click two tab-bar items a known distance apart and confirm
the screen delta equals the device-point delta. Re-read the window geometry each session. To locate
targets precisely, scan the PNG for the accent colour rather than eyeballing: selected controls are
`rgb(0,122,255)`, and pixel coordinates ÷ 3 give device points.

### Adding files

The Xcode project uses `PBXFileSystemSynchronizedRootGroup`. Any `.swift` file added under
`streetw/` (including new subdirectories) joins the target automatically — never hand-edit
`project.pbxproj` to register sources.

### Tests

```bash
swift test                                    # all 98
swift test --filter "Size normalisation"      # one suite
swift test --filter relockFiresAgain          # one test
```

swift-testing (`@Test`/`#expect`), not XCTest. They cover `StreetwCore` only — the iOS app has no
tests, and SwiftData/SwiftUI code is verified by running the app.

Tests never hit the network: `MockHTTPClient` serves fixtures keyed by `"path?query"` and honours
`If-None-Match`, so the 304 path is genuinely exercised. It also records requests, which is how the
pagination tests assert on pages the adapter *didn't* fetch. Fixtures in
`Tests/StreetwCoreTests/Fixtures/` are trimmed real payloads — refresh them from the live sites
rather than hand-writing, so brand-specific shapes (BBC's `[Color, Size]` axes) stay represented.

The package builds in **Swift 6 language mode** while the app is still Swift 5. Strict concurrency
therefore catches things in `StreetwCore` that the app would not — that's a feature; it found a
real shared-mutable-`DateFormatter` race. Don't reach for `nonisolated(unsafe)` to quiet it.

## Architecture

### The fetch pipeline

```
BrandSource (what to watch)  →  SourceAdapter  →  FetchResult/FetchedItem  →  SyncEngine  →  SwiftData
        value type              off main actor        value types             @MainActor
```

The critical invariant: **adapters never touch SwiftData.** They do networking off the main actor
and return plain `Sendable` value types; only `SyncEngine` (which is `@MainActor`) writes models.
This is why there is no `@ModelActor` anywhere, and why `FetchedItem` duplicates fields that also
exist on `BrandUpdate`. Keep new adapters on this side of the line.

`streetw/Sources/` is also intended to be lifted verbatim into a planned server target
(see `ROADMAP.md`), so it must stay free of SwiftData, SwiftUI and UIKit. `UpdateKind` and
`VariantInfo` live there rather than nested in `BrandUpdate` for that reason — `BrandUpdate.Kind`
is only a typealias. Don't move them back.

Adapters live in `streetw/Sources/` and are resolved through `SourceAdapters.adapter(for:)`:

- `ShopifySource` — public `/products.json`. The highest-value source by far; most streetwear
  brands run Shopify, giving structured products, images, prices, tags and stock for free.
- `CollectionsSource` — public `/collections.json`, so a release is one named event rather
  than sixty product rows. **This endpoint calls the body field `description`, where
  `/products.json` calls it `body_html`** — the wrong key loses every summary silently.
- `FeedSource` — one `XMLParser` delegate handling both RSS `<item>` and Atom `<entry>`.
- `SitemapSource` — `/sitemap.xml` for brands that are neither Shopify nor feed-publishing.
  Uses `<lastmod>` as `published_at`, so `since` filtering needs no extra state. Skips
  entries with no `lastmod`: assuming "now" would resurface the whole catalogue every poll.
- `PageWatchSource` — last resort, only when nothing structured was found.

Discovery prefers them in that order, so a page watch is now genuinely a fallback rather
than the common case for non-Shopify brands.

`BrandDiscovery` (in `Sync/`) probes a bare domain, attaches whatever it finds, and falls back to a
page watch so every brand yields some signal.

### Deliberate design decisions

Changing these silently will break intended behavior:

- **Instagram is never scraped.** `BrandSource.Kind.instagram` has `isAutomatic == false` and
  `SourceAdapters.adapter(for:)` returns `nil` for it — it is a stored deep link only. Aggregating
  arbitrary public profiles isn't permitted and unofficial endpoints break constantly.
- **A brand's first sync is a baseline, not news.** `SyncEngine.merge` checks
  `brand.lastSyncedAt == nil` and inserts that batch pre-marked `isSeen`, so adding a brand doesn't
  dump 250 back-catalogue products into the feed.
- **Only a sync that reached something may spend the baseline.** The flag that says "already
  baselined" is also the incremental cursor, so stamping it after a sync that stored nothing means
  the first batch that *does* arrive is announced as news. `SyncEngine.sync` sets `lastSyncedAt`
  only when at least one source succeeded; the server keeps a separate `sources.baselined_at`
  rather than reusing `last_checked_at`, which is stamped before the fetch and survives a failure.
  This is not theoretical — it dumped 250 Kith products into the feed as new drops.
- **`PageWatchSource` hashes visible text, not raw HTML** — after stripping scripts, styles,
  comments, tags and hex-looking tokens. Raw HTML changes on every load (CSRF tokens, cache
  busters), which would make every check look like a change. The first sight of a page stores a
  fingerprint and emits nothing.
- **A 401/403 or a redirect to `/password` is a feature, not an error.** Storefronts lock down right
  before a drop, so this surfaces as `Brand.isLockedForDrop` and a `.dropLock` update rather than a
  failure. `HTTPClient.get` deliberately returns the status code instead of throwing on 4xx.
- **A lock fires on the transition, not on every poll.** `PageWatchSource` stores the sentinel
  `lockedFingerprint` in place of the content hash while locked, so polling through a drop adds one
  event, and reopening (which restores a real hash) lets the *next* drop fire again. Keying the
  event id on the source alone made a lock a once-ever occurrence.
- **Only a price *drop* is an event, and only past 5%.** Storefronts recompute prices
  from exchange rates several times a day; treating every edit as news would bury the one
  real markdown. A rise is never announced. `FetchedItem.priceAmount` exists because
  `priceText` is formatted for display and two strings say nothing about direction.
  A restock outranks a drop, so one product writes at most one event per poll.
- **Restock is the only reason a seen item resurfaces.** `SyncEngine.refresh` re-flags an update
  only when a *variant* goes false→true, recording which sizes returned in `restockedSizes`
  (falling back to whole-product `isAvailable` for sources without variants).
- **`FetchResult.notModified` is not the same as an empty `items`.** A 304 means "unchanged";
  merging its empty list would be a no-op, but the distinction matters for any future caller that
  treats "no items" as meaningful.
- **`ShopifySource` stops paginating early** once a page ends older than `since`. Only the first
  page carries the `ETag`, which is sufficient — if the newest products are unchanged, nothing
  further back can have moved.

### The share extension

- **`Shared/` is compiled into both targets.** `SharedInbox` is the contract between
  them, so it is listed in each target's `fileSystemSynchronizedGroups` rather than
  duplicated. `ShareExtension/` belongs to the extension alone.
- **The extension does no networking and touches no SwiftData.** It extracts the URL,
  writes one JSON file into the App Group container, and returns. Extensions run under a
  hard memory limit and are expected back immediately; the app enriches the link with its
  Open Graph title, price and image on the next foreground (`SharedSaveImporter`).
- **The inbox is one file per save, and reading is separate from deleting.** Two
  processes are involved, so a read-modify-write on a shared array loses saves. Nothing
  is removed until the item is committed to the store — otherwise a fetch that hangs, or
  a kill mid-import, throws the save away.
- **Adding the App Group silently moved the SwiftData store.** A default
  `ModelConfiguration` puts the store in the *shared group container* once the app has an
  App Group entitlement, so the app opens an empty database and every brand and save
  appears wiped while the real data sits in the old location. `streetwApp` now pins the
  store URL explicitly to `URL.applicationSupportDirectory`. Don't remove that.
- The App Group id must be identical in `streetw.entitlements` and
  `ShareExtension.entitlements`. A mismatch fails silently — the container URL is nil and
  every share vanishes without an error.

### SwiftData specifics

- Dedupe is by `BrandUpdate.externalID`, a source-scoped stable string (`shopify:<product id>`,
  `feed:<guid>`, `lock:<source uuid>`). Nothing relies on `@Attribute(.unique)`.
- **`Brand.sources` is a `[BrandSource]` Codable array, so mutating one element does not persist.**
  `SyncEngine.sync(brand:)` rebuilds the whole array and reassigns it. Preserve that pattern.
- Saved state is read through the `BrandUpdate.saves` inverse relationship
  (`update.save`), *not* a per-item `@Query`. An earlier version ran one query per card and would
  not scale to a grid.
- Images are stored as `[String]` (`imageURLStrings`) with a computed `imageURLs`; SwiftData is
  happier with those than `[URL]`.
- **A Codable struct stored in a `@Model` must decode leniently.** SwiftData decodes those with an
  internal `try!`, so a field added to `BrandSource` after a store was written is not a migration
  problem — it is a crash on launch for anyone holding the older data, which is exactly what
  `failureCount` did on device. `BrandSource.init(from:)` defaults every field but `kind` and `url`;
  keep it that way, and add new fields the same way.

### Client/server wiring

Wire types live in `Sources/StreetwCore/API.swift` and are shared by both sides; the
server adds Vapor `Content` conformance by extension. Don't duplicate a DTO in the server
— that's how the two drift. `APICoding` pins ISO8601 dates on both ends, and
`ContentConfiguration` is set to match: a mismatch wouldn't error, it would silently
return the wrong `since` window.

Shared objects (`ServerSettings`, `SizeProfileStore`, `RemoteSync`, `SyncEngine`) are
built in `streetwApp.init`, **not** in a `.task`. Creating them asynchronously raced with
child views' own `.task`s — `FeedView` could run first, see nil, and skip the sync, which
looked exactly like a broken server.

### Everything must go over the server when one is configured

Each operation that could fetch from the phone is guarded by `settings.isConfigured`, with
the local path in the `else`. Adding a new one means adding both halves:

| Operation | Server route |
|---|---|
| launch/refresh sync | `GET /v1/follows` + `GET /v1/feed` |
| add brand | `POST /v1/brands/discover` then `POST /v1/follows` |
| "check site" preview | `GET /v1/brands/probe` (dry run — creates nothing) |
| delete / unfollow | `DELETE /v1/follows/:id` |
| size profile change | `PATCH /v1/devices/me` |
| APNs token / environment | `PATCH /v1/devices/me` |

Two traps worth knowing. Deleting a brand locally without unfollowing looks like it worked
and then the next sync **restores it** from the server's follow list. And the launch sync
lives on `ContentView`, not `FeedView` — in `FeedView` it only ran if the user happened to
open that tab.

### Politeness is not optional

All outbound fetching should go through `PoliteFetcher` (the server wires it up in
`configure.swift`). It obeys robots.txt per host and spaces requests by
`POLITE_INTERVAL`, reserving each slot *before* sleeping so concurrent callers queue
rather than all firing at once. `Net.userAgent` is honest on purpose — verified to get
200s from the storefronts we poll, so don't "fix" access problems by impersonating a
browser. A missing robots.txt is treated as permissive: failing closed would drop brands
for an unrelated reason.

### StreetwCore must compile on Linux

The server image builds it with swift-corelibs-foundation, which differs from Apple's
Foundation in ways the compiler only reveals there. Already hit and guarded:

- `XMLParser`/`XMLParserDelegate` live in a separate **FoundationXML** module
  (`#if canImport(FoundationXML)`), not Foundation.
- `URLCache` has no two-argument initialiser; `diskPath:` is required
  (`#if canImport(FoundationNetworking)`).

`canImport(FoundationNetworking)` is a reliable "is this Linux" discriminator here. Adding
Foundation APIs to `StreetwCore` risks this class of break and it will not show up in any
local build or test — only in the deploy.

### Keep the Docker toolchain in step with local

`Server/Dockerfile` pins `swift:6.3.3-noble` to match `swift --version` here. `Package.resolved`
pins dependency *versions*, and those dependencies declare their own swift-tools-version —
Vapor's tree needs 6.2+. Building the same resolved graph on an older image fails with
`is using Swift tools version 6.2.0 but the installed version is 6.0.3`. Bumping the local
toolchain, or re-resolving to newer dependencies, means bumping the image tag too.

### The repo directory name is load-bearing

`Server/Package.swift` refers to `.product(name: "StreetwCore", package: "streetw")`.
SwiftPM derives a **path dependency's identity from the directory basename**, not from
`name:` in the manifest — so the root package must live in a folder called `streetw`.
Renaming the checkout, or building in a differently-named directory, fails with
`unknown package 'streetw'`. This is why the Dockerfile uses `WORKDIR /streetw`.

Related: SwiftPM validates that every declared target directory exists when it loads the
graph, so the Docker image must copy `Tests/` and `Server/Tests/` too even though it only
builds the executable. Omitting them yields a confusing "overlapping sources" error.

### Server specifics

- **The catalog is global.** Brands, sources, products and variants are one row per
  real-world thing; only users, devices, follows and size profiles are personal. Never add
  a `user_id` to a catalog table — polling once for everyone is the whole design.
- **`next_check_at` is the schedule**, held in the row rather than in memory, so restarts
  resume and a second instance can later use `FOR UPDATE SKIP LOCKED`.
- **A failed poll must still advance `next_check_at`** (`Poller.quarantine`). Without it, a
  source that errors after fetching stays "due" and every tick re-downloads the entire
  catalog — a hot loop against the brand. This actually happened; there's a test for it.
- **A `[String]` column must be `TEXT[]` on Postgres, not JSONB.** Fluent binds a Swift
  `[String]` as a *native* Postgres array, so a column declared `.json` (which renders as
  JSONB) rejects every insert: `column is of type jsonb but expression is of type text[]`.
  SQLite has no array type and JSON-encodes instead, so **this cannot reproduce locally** —
  it only appears against the deployed Postgres, and production `ErrorMiddleware` reduces
  it to "Something went wrong." `FixPostgresArrayColumns` converts the five affected
  columns; `CreateSchema` is left as-is because it is already applied in production.
  The tell: writes to tables *without* an array column (brands, sources) keep working, so
  the deploy looks healthy while registration and the poller both silently fail.
- **`/status` counts every table**, `users` included. It was the one table it didn't touch,
  which is exactly why a completely broken registration path still reported green.
- **One push per brand per pass, never one per event.** A brand publishing a collection
  writes hundreds of events in a single poll; fanning those out one-to-one is both a
  terrible experience and a fast route to being muted. `Notifier` groups by brand and
  sends a counted summary.
- **`events.notified_at` is the push ledger**, in the row for the same reason as
  `next_check_at`. Events are marked even when nothing was sent — when no APNs key is
  configured, and when they are older than the 6h freshness window. Skipping that would
  mean the first deploy with credentials notifies every event ever recorded, and coming
  back from an outage fires a burst about drops that already sold out.
- **Push delivery is behind `PushSending`.** `Notifier` never imports APNs, so the whole
  fan-out — follows, size targeting, batching, dead-token pruning — is tested with no
  certificate and no network. Only `APNSPushSender` talks to Apple.
- **Retention prunes events before products, never the reverse.** `events.product_id` is
  `ON DELETE CASCADE`, so pruning a product takes feed history with it; and deleting a
  product the source still lists makes the next poll announce it as a new drop. Only
  products unseen for `PRODUCT_RETENTION_DAYS` *with no events left* are eligible.
- **The poll queue claim is a lease, not a select.** `FOR UPDATE SKIP LOCKED` plus
  pushing `next_check_at` forward in the same statement, before any network call — so a
  second instance can't double-fetch a storefront and a crash mid-poll costs one lease.
  Postgres only; SQLite keeps the plain query.
- **`HTTPFetching`, not `HTTPClient`** — Vapor re-exports `AsyncHTTPClient.HTTPClient` and
  an unqualified collision in the server target is nastier than the wordier name.
- **Don't name a test helper `withApp`.** VaporTesting exports a generic `withApp<T>` that
  does *not* run `configure`. A single-statement test closure lets Swift infer `T` from
  `test(...)`'s discardable return and silently pick that overload — the app comes up with
  no routes and everything 404s, while multi-statement closures resolve to yours and pass.
  The local helper is called `withServer`.

### The collection

- **Boards are filters, not folders.** `SavedItem.board` is optional and
  `Board.items` deletes with `.nullify` — removing a board must never take the saved
  things with it. `SaveType` (Inspiration/Wardrobe) is a separate axis and an item can be
  on both.
- **Only saved items get image analysis.** `ImageTagger` runs from the Saved tab, bounded
  per pass, and stamps `analyzedAt` even on failure so a dead image URL isn't retried
  forever. Running it over a catalogue sweep would analyse 250 items nobody kept.
- **Dominant colour is centre-cropped before voting.** A seamless studio sweep is 70–85%
  of a product shot; without the crop every item resolves to "White". The backdrop
  brightness threshold is 0.93 and was measured — 0.88 excludes the grey sweep but also
  eats a white garment's own pixels, leaving its shadows to vote "Grey".
- **Vision's classifier does not work in the Simulator** ("Failed to create espresso
  context"). Categories are device-only; the code degrades to the text vocabulary, so
  this looks like nothing happening rather than an error.

### SwiftUI gotcha

Buttons inside a `List` row need `.buttonStyle(.borderless)`. With `.plain` the row takes the tap
as a single target and the buttons never fire — this silently broke the size chips, and it looks
identical in a screenshot, so it's only catchable by actually tapping.

### Verifying adapters against the live web

Fixtures go stale — storefronts change shape. To check parsing against the real thing, add a
temporary executable target depending on `StreetwCore` and run it with `swift run`, or call the
adapters from a scratch test. Adapters take an injected `HTTPClient`; passing `Net.live` (the
default) hits the network for real.

### Adding to StreetwCore

Anything in `Sources/StreetwCore/` needs `public` to be visible to the app, including memberwise
inits — SwiftPM has no implicit cross-module access. If a type is only used inside the app, it
belongs in `streetw/`, not here.

## Known gaps

See `ROADMAP.md` for the planned work and what's explicitly out of scope. The near-term ones:

- Push is built but not switched on: it needs an APNs key on the server (`APNS_*`) and the Push
  Notifications capability on the app target, which requires a paid team. Until then `/status`
  reports `apnsConfigured: false` and the app says so in Settings rather than pretending.
- `StyleProfile` derives colors/categories/silhouettes from title and tag text only. Image-based
  color extraction via Vision is the intended upgrade.
- No size profile yet, so per-variant restock data is displayed but not filtered on.

## Other agent configs

A Codex config exists at `~/.codex/config.toml`. To pull anything importable from it (MCP servers,
slash commands, subagents, skills, instructions), reply `/import` to scan and list what's available,
then `/import --yes=<digest>` using the digest the scan prints. If `/import` isn't available on this
surface, run `claude import` from a terminal instead.

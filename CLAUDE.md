# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

`streetw` is an iOS app (SwiftUI + SwiftData, iOS 26.5 deployment target) that watches streetwear
brands for new drops, restocks and collections, and builds a style profile from what you save.
Bundle ID `functional.streetw`.

The repo holds **three things** — a shared library, an iOS app, and a server:

```
Package.swift            StreetwCore library + tests
Sources/StreetwCore/     adapters, sizing, discovery — no SwiftData/SwiftUI/UIKit
Tests/StreetwCoreTests/  swift-testing, fixture-driven, no network
streetw/                 the iOS app (Models/, Views/, Sync/)
streetw.xcodeproj        app target; links StreetwCore as a local package
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

### Build and run

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
DEVICE=<udid-of-an-iOS-26.5-device>

xcodebuild -project streetw.xcodeproj -scheme streetw \
  -destination "platform=iOS Simulator,id=$DEVICE" \
  -derivedDataPath /tmp/streetw-dd build

xcrun simctl install "$DEVICE" /tmp/streetw-dd/Build/Products/Debug-iphonesimulator/streetw.app
xcrun simctl launch "$DEVICE" functional.streetw
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
DB="$(xcrun simctl get_app_container "$DEVICE" functional.streetw data)/Library/Application Support/default.store"
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
swift test                                    # all 40
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
- `FeedSource` — one `XMLParser` delegate handling both RSS `<item>` and Atom `<entry>`.
- `PageWatchSource` — fallback for brands with neither.

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
- **Restock is the only reason a seen item resurfaces.** `SyncEngine.refresh` re-flags an update
  only when a *variant* goes false→true, recording which sizes returned in `restockedSizes`
  (falling back to whole-product `isAvailable` for sources without variants).
- **`FetchResult.notModified` is not the same as an empty `items`.** A 304 means "unchanged";
  merging its empty list would be a no-op, but the distinction matters for any future caller that
  treats "no items" as meaningful.
- **`ShopifySource` stops paginating early** once a page ends older than `since`. Only the first
  page carries the `ETag`, which is sufficient — if the newest products are unchanged, nothing
  further back can have moved.

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

### Server specifics

- **The catalog is global.** Brands, sources, products and variants are one row per
  real-world thing; only users, devices, follows and size profiles are personal. Never add
  a `user_id` to a catalog table — polling once for everyone is the whole design.
- **`next_check_at` is the schedule**, held in the row rather than in memory, so restarts
  resume and a second instance can later use `FOR UPDATE SKIP LOCKED`.
- **A failed poll must still advance `next_check_at`** (`Poller.quarantine`). Without it, a
  source that errors after fetching stays "due" and every tick re-downloads the entire
  catalog — a hot loop against the brand. This actually happened; there's a test for it.
- **`HTTPFetching`, not `HTTPClient`** — Vapor re-exports `AsyncHTTPClient.HTTPClient` and
  an unqualified collision in the server target is nastier than the wordier name.
- **Don't name a test helper `withApp`.** VaporTesting exports a generic `withApp<T>` that
  does *not* run `configure`. A single-statement test closure lets Swift infer `T` from
  `test(...)`'s discardable return and silently pick that overload — the app comes up with
  no routes and everything 404s, while multi-statement closures resolve to yours and pass.
  The local helper is called `withServer`.

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

- No background refresh or push; updates only arrive while the app is open. The project has
  committed to a server-backed poller for this — `BGAppRefreshTask` is too throttled for drops.
- `StyleProfile` derives colors/categories/silhouettes from title and tag text only. Image-based
  color extraction via Vision is the intended upgrade.
- No size profile yet, so per-variant restock data is displayed but not filtered on.

## Other agent configs

A Codex config exists at `~/.codex/config.toml`. To pull anything importable from it (MCP servers,
slash commands, subagents, skills, instructions), reply `/import` to scan and list what's available,
then `/import --yes=<digest>` using the digest the scan prints. If `/import` isn't available on this
surface, run `claude import` from a terminal instead.

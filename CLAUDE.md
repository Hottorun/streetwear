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
| `-standalone YES` | Runs with no server, so `SyncEngine` polls from the phone |

**`-standalone YES` is the only way to get standalone mode.** `-serverBaseURL ""` used to do it
and no longer does — see *The server address is not a setting* below.

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
  **`<image:title>` is the product's name and `<image:loc>` its lead photograph** — read
  both, because the slug is not always a name: Palace randomises its handles until a drop
  is live, so `/products/e7anvz3i1psy` yielded a feed of hashes over empty tiles while the
  real name sat two lines below in the same entry. Note the image extension nests its own
  `<loc>`, so the parser must know which one it is inside or every link points at a CDN.
  A slug that still reads as a hash becomes `SitemapSource.unnamed` rather than being
  printed, and both merge paths upgrade a provisional title when a real one arrives later
  (`isProvisional`) — dedupe is on `externalID`, so nothing else would ever revisit it.
- `PageWatchSource` — last resort, only when nothing structured was found.

Discovery prefers them in that order, so a page watch is now genuinely a fallback rather
than the common case for non-Shopify brands.

`BrandDiscovery` (in `Sync/`) probes a bare domain, attaches whatever it finds, and falls back to a
page watch so every brand yields some signal.

**A brand's name comes from the brand, not from its hostname.** Splitting a host on dots produced
"Usa" for `usa.palaceskateboards.com` and "Bbcicecream" for Billionaire Boys Club — and the catalog
is global, so whatever the first person to add a brand accepted is what everyone inherits.
`SiteIdentityProbe` reads `og:site_name` and the `<title>` out of the homepage fetch `BrandMark`
was **already making** for the logo, so it costs nothing. Order is Shopify `/meta.json` →
`og:site_name` → `<title>` (first segment, marketing tail dropped) → host. A generic title ("Home",
"Official Site") is refused rather than adopted, because the field is pre-filled and pre-filled
fields get accepted.

**The catalog is not always on the host that was typed.** A storefront moved to Hydrogen
answers on the apex and 404s `/products.json`, while the classic Shopify origin still
serves the full catalog on `www.` — Palace does exactly this, and probing one host demoted
a storefront with titles, prices, images and stock all the way to a sitemap.
`ShopifySource.resolve` tries both and returns whichever answered, and that is the URL the
sources are pinned to. It swaps **only** `www.`: every other subdomain a brand runs
(`usa.`, `eu.`) is a region with its own currency, and switching someone off one would
change every price in their feed.

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

### Push, and why it was silent for months

- **`aps-environment` in `streetw.entitlements` is load-bearing.** Without it iOS refuses
  `registerForRemoteNotifications()`, the delegate takes the `didFailToRegister` path, no token is
  ever issued, and `RemoteSync.pushDeviceToken` never runs. The server then holds device rows with
  a null token, `Notifier` finds followers, has nobody to send to, and stamps `notified_at` anyway.
  **Every layer reports healthy and not one notification exists.** The app shipped like this with
  eleven tokenless devices while `/status` read green.
- **`devicesWithToken` on `/status` and `POST /admin/push-test` exist to make that visible.**
  The probe sends a synthetic push straight to registered devices, bypassing events, follows,
  freshness and size targeting, and reports *per device* rather than as counts — "sent 0" is
  equally true when nobody holds a token, when Apple rejected every one, and when there is no key
  on the deployment, and those have three different fixes. It writes nothing, so it can be run
  during a drop without swallowing a real alert.
- **The value is `development` even for builds that ship.** Xcode's export step replaces it using
  the distribution profile, and it matches `BackgroundServices.apnsEnvironment`, which reports
  `sandbox` for DEBUG — so the token and the host the server sends it to agree.
- **One `threadID` for the whole app, not one per brand.** iOS groups notifications by thread
  *within* an app, so a per-brand id — which is what this shipped with — gave every storefront its
  own pile on the lock screen instead of one stack that says "streetw". Grouping is the thread id;
  stopping a single brand from shouting is `collapseID`, which stays per brand. They are different
  knobs and were being confused for each other.
- **A notification carries the event it is about, and tapping it opens that item.** `PushPayload`
  ships `eventID` whenever the alert names one thing — a restock, one new drop, a fired watch — and
  nil for a counted summary, where no single product is the subject and the brand page is the honest
  destination. `PushRoute` is built in `streetwApp.init` alongside everything else, because a push
  that cold-launches the app delivers its tap **before any view exists**; a notification-centre
  broadcast at that moment reaches nobody.

### Heuristics carry a version

`Gender` and `GarmentSlot` are text classification over catalogue copy nobody wrote to answer the
question, so they will keep improving. A stored verdict from an older revision is *worse than no
verdict*, because nothing would ever revisit it.

- **`GenderClassifier.version` is stored beside the answer** (`BrandUpdate.genderVersion`) and the
  value is re-derived on mismatch. Without it, improving the rules only ever reaches products
  discovered after the update. Bump the version whenever the rules change. **The version
  travels on the wire too** (`FeedItem.genderVersion`): the server decides gender so both
  platforms agree, but the two deploy on different schedules, and stamping the *local*
  number on a server-supplied verdict froze it forever the moment the phone shipped better
  rules.
- **The classifier's inputs travel with its verdict.** `FeedItem` carries `productType` and
  `tags` because the client does not merely display them — gender, `GarmentSlot` and
  `StyleProfile` are all read off them, and with neither on the wire every server-backed
  item arrived as a bare title, so any local re-derivation could only answer `.unknown`.
  Unknown is never filtered, so the whole of YoungLA's womenswear — filed
  `product_type: "For Her"`, and named `W2156`, which is not a word — reappeared in a
  menswear feed. `RemoteSync.backfill` fills these in on rows written before that, because
  the merge skips ids it already holds and they would otherwise never heal.
- **A cut named after an age is not an age.** A "baby tee" is a women's cut. Reading it as
  childrenswear put it on the kids' rail, which menswear *and* womenswear feeds both hide —
  so it vanished from every filtered feed there is. `cutPhrases` is for phrases only; a lone
  ambiguous word needs no entry, because whole-token matching already spares "boyfriend
  jeans" and "dad hat".
- **What a product is *called* outranks where it is *filed*.** "WMNS Dunk Low" is the women's cut —
  that is Nike's own designation — and a `mens` tag on it is a shelf decision. Weighing them
  equally resolved every WMNS sneaker in a men's department to `.unisex`, which is never hidden, so
  a menswear-only feed showed them all. Title and handle decide; tags only speak when the name is
  silent.
- **Match whole tokens, never substrings.** "womens" contains "mens", so any `contains` check
  classifies every women's product as menswear — precisely backwards.
- **`.unknown` is a real answer and is never filtered out.** Billionaire Boys Club tags everything
  `2026` / `F26` / `Final Sale`; guessing would delete the brand from a filtered feed.

### Sizing

- **Shoe sizes are stored canonically in US**, everywhere — the profile, the wire, every
  comparison. `SizeProfile.shoeScale` is a *display* preference, so switching to EU rewrites
  nothing and needs no re-send.
- **A region code is the whole difference between a UK 9 and a US 9**, which are a full size apart.
  Both codes used to be stripped and the remainder read as US. Only a size that *names* its scale
  is converted; a bare "44" stays `.other` and is never hidden, because it is as likely a waist or
  an EU jacket.
- **A converted size matches within half a size.** Brand tables genuinely disagree by that much, so
  demanding an exact hit after a conversion would hide real results. Native US sizes get no
  tolerance, or the profile silently widens by a size.
- **One-size items always match.** The toggle that could exclude them bought nothing and hid most
  of the accessories in the feed. `UserModel.includeOneSize` survives only because the column is
  `NOT NULL` in an applied schema.

### The server address is not a setting

The app ships pointing at one backend and there is no UI to change it. An empty stored value used
to mean "deliberately standalone", because Settings had a field you could clear — **that reading is
gone**, and an empty value now falls back to the default. Anyone who cleared the field while it
existed was otherwise stranded offline with no way back: catalog search returns nothing,
recommendations never load, watches never reach the server, and every failure is silent. Standalone
is now reachable only via `-standalone YES`.

Related, and the same class of mistake: **a failed lookup must say which failure it was.** The
search screen returned an empty list both when the catalog genuinely had no match and when it had
never been asked, and the copy claimed the former.

### Stock watches

- **A watch is a predicate over variants, not a product.** Watching "this hoodie" on something that
  runs XS–XXL in four colourways fires on somebody else's size and trains you to ignore it, so a
  watch pins a size, a colour, or both.
- **`WatchTarget` lives in `StreetwCore`** because both ends evaluate it — the phone against
  SwiftData so standalone works, the server against Postgres so the alert arrives with the app
  closed. Two implementations would drift, and the symptom would be an alert that fires on one
  path and not the other.
- **Firing is edge-triggered and `fired_at` is the ledger**, in the row for the same reason
  `events.notified_at` is. `StockWatch.wasAvailable` is seeded at creation, so watching something
  already in stock doesn't fire immediately.
- **A watch alert replaces that brand's summary push for that user in the same pass.** It is the
  more specific statement, and one-push-per-brand-per-pass still holds — this only decides which.
- **A watch is spent even when no device can receive it**, or a user who registers a token months
  later gets an alert about a restock that has long sold out.

### Images

- **`CachedImage`, not `AsyncImage`.** `AsyncImage` treats *cancellation* as failure, so scrolling a
  `LazyVGrid` — which tears down off-screen rows and cancels their loads — latches a broken tile
  permanently, with no way to ask for a retry. `CachedImage` leaves a cancelled load in `.loading`,
  retries transient failures twice, and collapses duplicate in-flight requests for one URL.
- **Ask the CDN for the size being drawn.** Storefront originals are 2000–3000px and a feed spread
  pulls seven; that is most of why loads were being cancelled in the first place. `ImageRendition`
  snaps to a **ladder** of widths so a 118pt tile and a 121pt tile share one cache entry instead of
  minting two URLs for the same photograph. An unrecognised host is left completely alone — a
  resize parameter a CDN doesn't understand is at best ignored and at worst a 404.
- **A paged gallery must warm its neighbours.** `TabView` builds a page only when it is reached, so
  the load for photo *n* started the moment you landed on it and every swipe arrived on an empty
  frame. `ImageGallery` calls `ImageLoader.prefetch` for ±2 on each index change. The prefetch is
  `Task.detached` **on purpose**: started from a `.task`, a structured child would be cancelled by
  the next page change, which is precisely when it matters. It joins `inFlight`, so a page that
  catches up with its own warm-up awaits it rather than starting a second request.

### Gestures: paging and quick-save share a direction

Horizontal swipe is claimed twice — paging through a product's photographs, and `quickSave`'s
file/mark-read. Resolved **by region, not by screen**: `quickSave` offsets the whole card (it has
to, or the hint appears beside a card that hasn't moved) while `quickSaveHandle()` marks the part
that actually recognises the drag, which is the caption. Attaching the gesture at card level
swallows the photograph's paging; attaching it nowhere loses the actions.

### Recommendations

- **`BrandVector`'s unit of work is the whole catalog.** Two components — inverse document frequency
  and price percentile — are defined relative to every *other* brand, so vectors cannot be built one
  brand at a time. `BrandSimilarity` caches them with a TTL rather than persisting: they are
  entirely derived, and a stale vector is worse than a missing one.
- **Price is compared as a rank, never as an amount.** Brands store their own currency and there
  are no exchange rates anywhere in this system; ranking sidesteps conversion entirely.
- **Vocabulary is TF-IDF over tags and product types, never titles.** Product names are unique to
  one brand, so IDF would rate "Nocturne" maximally distinctive — the opposite of useful. IDF is
  also what flattens Kith's 130 internal merchandising codes.
- **Scored as a weighted mean of per-component similarities**, not one cosine over a concatenated
  vector: vocabulary has hundreds of dimensions and gender has five, and a single cosine would let
  the former drown the latter on dimension count alone.
- **Taste beats popularity but never replaces it.** This measures catalog *composition*, which is a
  proxy for aesthetic and not the thing itself, so a brand nobody follows must not outrank a
  well-liked one on vibes alone.
- **The taste vector is computed on the phone.** Saves are the sharpest signal and the most
  personal; the server ships candidates *with their vectors* and the comparison happens locally, so
  nothing about a save leaves the device. Don't "improve" this by uploading saves.

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
- **A shared link is enriched from the catalogue when it can be, and Open Graph only when it
  can't.** `ShopifySource.product(at:)` reads `/products/<handle>.js`, which gives the size run,
  the colourways and which of them are gone — Open Graph gives a title, a picture and a price,
  which is a bookmark. It uses `.js` rather than the `.json` beside it for one reason: **`.json`
  omits `available`**, and stock is the whole question. The cost is prices in minor units. A
  catalogue hit is also keyed `shopify:<id>`, so sharing something from a followed brand lands on
  the row that already exists rather than minting a second card for it.
- **The sold-out prompt is asked by the app, not the extension — because it cannot be asked
  earlier.** The extension does no networking, so at share time nobody knows whether the thing is
  in stock. `SharedSaveImporter` offers the watch on the next foreground, which in the usual
  share-from-Safari-and-switch-back flow is seconds later. It offers **only** on an explicit
  `isAvailable == false`: a page that declared nothing about stock must not be guessed at, or the
  reward for saving something you could have bought is an unprompted sheet.

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
  keep it that way, and add new fields the same way. `SizeProfile` has the same hand-written
  lenient `init(from:)` for the same reason — it lives in `UserDefaults` on real phones.
- The schema is `Brand`, `BrandUpdate`, `SavedItem`, `Board`, `StockWatch`, `Fit`. A new `@Model`
  that isn't listed in `streetwApp.init` simply doesn't exist at runtime.
- **`Fit.items` ↔ `SavedItem.fits` is many-to-many and cascades in neither direction.** Deleting a
  fit must not delete the clothes, and un-saving something leaves the fits it was in rather than
  silently rewriting them.

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
| find a brand | `GET /v1/brands?q=` (name **or** pasted URL) |
| add a brand nobody has | `POST /v1/brands/discover` then `POST /v1/follows` |
| "check site" preview | `GET /v1/brands/probe` (dry run — creates nothing) |
| delete / unfollow | `DELETE /v1/follows/:id` |
| size and gender profile | `PATCH /v1/devices/me` |
| APNs token / environment | `PATCH /v1/devices/me` |
| stock watches | `POST` / `GET` / `DELETE /v1/watches` |
| recommendations | `GET /v1/brands/popular` |

**The catalog is searched before anything is created.** It is global, so the second person to add
Kith should be following the existing row, not filling in a form about Kith — `AddBrandView` only
falls through to discovery when the search comes back empty.

Three traps worth knowing. Deleting a brand locally without unfollowing looks like it worked
and then the next sync **restores it** from the server's follow list. The launch sync
lives on `ContentView`, not `FeedView` — in `FeedView` it only ran if the user happened to
open that tab. And **anything hitting an authenticated route on first launch must key its
`.task` on `settings.token`**: the view appears before registration completes, a `.task` fires
once per appearance, and a 401 swallowed by `try?` leaves the feature silently empty for the whole
session. That is exactly what happened to `BrandSuggestions`.

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
  real-world thing; only users, devices, follows, size profiles and watches are personal.
  Never add a `user_id` to a catalog table — polling once for everyone is the whole design.
  (`watches` points *at* a product without owning it, exactly as `follows` points at a brand.)
- **`UserModel.sizeProfile` is three discrete columns, not an encoded blob.** A new field on
  `SizeProfile` is therefore *not* automatically persisted: it round-trips through the accessor
  and is silently dropped on write. Adding one means a column, a migration, and a line in both
  halves of the accessor. `gender` was lost this way and only surfaced because a test asserted on
  a push that should have been filtered.
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
  New tables get it right up front — see `CreateWatches`, which declares `fired_sizes` as
  `TEXT[]` on Postgres and `.array(of: .string)` on SQLite from the same migration.
- **The feed ships variants.** It used to send only an `availableInMySize` badge, which made the
  whole size feature inert in the mode the app actually ships in: with no variants on the client,
  `isAvailable(in:)` returns true for everything, so the size filter matched every item and the
  size run — the app's signature element — rendered as blank space on every non-restock. The
  saving was never real either; a product carries tens of variants, not thousands.
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
- **The wall never crops.** The feed's grid fills its tiles because a grid of thumbnails
  needs one rhythm; the archive is the opposite — you kept these particular photographs, so
  `CollectionTile` draws `.fit` and takes the picture's measured aspect as the tile's shape.
  The clamp in `SavedView.aspect` is therefore a clamp on the *photo*, not on the layout:
  the old 0.66–1.5 window squared off every lookbook shot, and what is left only stops a
  panorama blowing one column out.
- **Only saved items get image analysis.** `ImageTagger` runs from the Saved tab, batched
  so results appear as they land, and stamps `analyzedAt` even on failure so a dead image
  URL isn't retried forever. Running it over a catalogue sweep would analyse 250 items
  nobody kept. It **drains** the backlog rather than stopping after one batch: the view only
  re-runs it when the save count changes, so a single batch left everything past the first
  dozen unmeasured — and an unmeasured item is a tile drawn to a guess.
- **Dominant colour is centre-cropped before voting.** A seamless studio sweep is 70–85%
  of a product shot; without the crop every item resolves to "White". The backdrop
  brightness threshold is 0.93 and was measured — 0.88 excludes the grey sweep but also
  eats a white garment's own pixels, leaving its shadows to vote "Grey".
- **Vision's classifier does not work in the Simulator** ("Failed to create espresso
  context"). Categories are device-only; the code degrades to the text vocabulary, so
  this looks like nothing happening rather than an error.
- **A fit needs a top and a bottom.** `FitSuggestions` proposes at most one garment per slot and
  never uses anything the classifier couldn't place — an item dropped into a slot it may not
  belong to reads as a bug rather than a suggestion. Suggestions are recomputed from the wardrobe
  and deterministic, so the row doesn't reshuffle on every render; keeping one turns it into a
  stored `Fit` and it stops being regenerated.

### Fits are a canvas, not a form

`FitCanvas` replaced a three-slot picker. An outfit is not a schema: the moment you want to layer
two jackets, add a bag, or lay something out flat rather than person-shaped, slots say no — about
exactly the things that make an outfit yours. Free position, scale and rotation, and **no
snapping**, because a grid turns a collage back into a form.

- **Slots did not die; they stopped being the interface.** `GarmentSlot` still filters the tray and
  still drives `FitSuggestions`. Canvas for the person, slots for the machine. Deleting it would
  take the suggestions engine with it.
- **Cutouts are what the screen depends on.** Raw product shots are white rectangles overlapping
  white rectangles. `Cutout` lifts the garment with Vision's on-device subject masking, once, in
  the `ImageTagger` pass that is already decoding the photograph — not per drag. Like the
  classifier, **it does not work in the Simulator** ("Failed to create espresso context"), so the
  canvas there looks like a mood board and that is not a bug. `FitPieceImage` falls back to the
  original, which is also the permanent answer for anything with no single subject to lift.
- **A brand that ships transparent PNGs has always looked like the cutout worked.** Palace publishes
  3200² PNGs with an alpha channel; Kith publishes 2000² JPEGs on a flat `#EBEBEB` sweep. So a
  Palace item lands on the canvas as a sticker with `Color.paper` showing through whether or not
  anything was ever lifted, and a Kith item lands as a grey rectangle — which reads as "the cutout
  works for one brand and not the other" when in fact it had never run for either. It is the same
  fact behind the two backdrops in the feed and on the collection wall: `UpdateImage` draws
  `Color.wash` behind a `.fit` photograph, so a transparent PNG shows the app's cream and a JPEG
  shows the photographer's grey. Check the pixels before believing a brand-specific bug.
- **`Seamless` is the fallback for when Vision won't, and it is all refusals.** Subject lifting
  produces nothing in the Simulator, which makes the whole canvas un-buildable there, and it can
  decline on device too. `Seamless` deletes a uniform studio backdrop instead — it knows nothing
  about clothes and must never pretend to, so it only fires when the border is flat, light and
  opaque, and it bails when the fill removed almost nothing or almost everything. Two details are
  load-bearing: the fill is **flood-filled inward from the frame's edge**, never a global
  colour match, because the white square of a graphic print and the gaps between a shoe's laces are
  the same colour as the sweep and a global pass punches holes through the garment; and the rim is
  **feathered** afterwards, because a hard threshold stops on the garment's anti-aliased edge and
  leaves a pale halo of the sweep it was cut from.
- **The cutout carries its own version, because `analyzedAt` cannot speak for it.**
  `ImageTagger` used to select on `analyzedAt == nil` alone, so every item analysed before cutouts
  existed was already stamped and never revisited — the whole established collection stayed
  sticker-less and the canvas was a mood board *on device too*. `Cutout.version` beside
  `BrandUpdate.cutoutVersion` is the `genderVersion` pattern: a row from an older build decodes 0,
  is stale, and gets one more look. It is stamped even when nothing was lifted (a flat-lay has no
  subject and must not be re-cut every launch), so a nil `cutoutFile` at the current version means
  "there is nothing here", not "nobody asked". Bump the version whenever the lift changes.
  `StyleView` runs the pass as well as `SavedView` — a fit is composed from the Style tab, and
  requiring a visit to Saved first denied stickers to exactly the person about to need them.
- **Placements are normalised, never points.** `FitPlacement` stores centre as a fraction of the
  canvas, so one description of a fit lays out identically at 900px for a render and at 168pt for a
  card — and a fit made on a Pro Max doesn't scrunch on a mini. It decodes leniently by hand for the
  usual reason: SwiftData decodes a stored Codable with an internal `try!`.
- **`z` is sparse and only ever grows.** Bringing a piece to the front is one write instead of
  renumbering the canvas.
- **Both the structure and the render are kept.** The structure is what keeps a fit editable, keeps
  it a list of things you own, and makes "one of these came back in stock" possible at all. The
  render is what a scrolling row draws without composing a canvas per card.
- **`FitRender.warm` before `write`, always.** `ImageRenderer` draws one frame synchronously and
  gives an async load no chance to finish, so a canvas of `CachedImage`s renders as a stack of empty
  tiles — which is exactly what the first saved fit produced. `FitPieceImage` reads
  `ImageLoader.cached` directly and `warm` is what guarantees it is populated, at the *same width*.
- **A fit is its own type that files onto a board**, rather than living inside one — `Fit.board`
  nullifies exactly as `SavedItem.board` does, so deleting a board never deletes an outfit.
- **The Style tab is not a settings screen.** Sizes and the gender filter moved to Settings; what
  is left is a reading of your taste and things to do with it. `StyleView` is also the only place
  besides the feed that shows recommendations, and it shares the block rather than restyling it.

- **A saved thing is still a product.** `SaveDetailView` shows the size run, the colourways and a
  watch, not just a note field. The page had been read too literally as "what did I think" and
  dropped everything the item *is* — but the commonest reason to keep something you can't have is
  that it was sold out, and "tell me when it's back" is the one thing here a screenshot can't do.
  `ColorwaySection` and `WatchSection` are shared with `ProductDetailView` rather than restyled.

### SwiftUI gotchas

Buttons inside a `List` row need `.buttonStyle(.borderless)`. With `.plain` the row takes the tap
as a single target and the buttons never fire — this silently broke the size chips, and it looks
identical in a screenshot, so it's only catchable by actually tapping.

**One over-wide row sets the width of the whole page.** A `VStack` is as wide as its widest child,
and in a `ScrollView` that width is then handed to every flexible sibling — so a single unwrappable
row does not overflow on its own line, it re-lays out the entire screen. `SizeRun` prints every
token `.fixedSize()` (it has to, or the row renders as a line of ellipses), and on the product page
`limit: .max` let a sneaker's 3.5–16.5 run measure 892pt on a 402pt phone. The photograph above it
was then drawn as an 892pt square: the detail page opened as one enormous crop with the title, the
size run and the buy bar all pushed off the bottom, and it looked for all the world like a bug in
`ImageGallery` — the run that caused it was never on screen. It also only showed on *some*
products, which made it read as a fault in whichever card had been tapped. `SizeRun(wraps:)` uses
`FlowRow`, which answers with the width it was **proposed** — that, not the extra lines, is the
property that matters. Anything raising `limit` must set it.

**A lone `.cancellationAction` beside a `.searchable` becomes a "···" menu.** With a search field
in the bar, iOS 26 has nowhere to put a leading text button and folds it into an overflow menu — so
`AddBrandView` shipped with an ellipsis whose entire contents was one item called Cancel. An icon
button in `.topBarTrailing` is not collapsed. Worth checking on any screen that has both.

**Every screen is paper, serif and mono — a stock `List` is not.** `BrandDetailView` was the last
one built out of grouped sections, `.bordered` buttons and `LabeledContent`, and opening a brand
fell out of the app into Settings.app for a moment. New screens compose `Color.paper`,
`.editorial()`, `Wordmark`, `DataLabel` and `Rule()` in a `ScrollView`.

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

- `StyleProfile` derives colors/categories/silhouettes from title and tag text only. Image-based
  color extraction via Vision is the intended upgrade.
- **Collaborative filtering is not wired up.** `BrandVector` recommends on catalog content, which
  works from a standing start; co-follow ("people who follow Kith also follow ALD") would be
  better and is meaningless at the current user count. It goes in behind a minimum-co-occurrence
  threshold, blended rather than replacing.
- Fits are composed by hand or proposed from the wardrobe; nothing reads the *photographs* when
  proposing one, so a suggestion can pair two things that clash.

## Other agent configs

A Codex config exists at `~/.codex/config.toml`. To pull anything importable from it (MCP servers,
slash commands, subagents, skills, instructions), reply `/import` to scan and list what's available,
then `/import --yes=<digest>` using the digest the scan prints. If `/import` isn't available on this
surface, run `claude import` from a terminal instead.

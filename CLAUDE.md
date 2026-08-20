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
swift test                                    # all 297
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
- `UCPSource` — the Universal Commerce Protocol endpoint a storefront advertises **for
  machines**, when it has switched its JSON catalogue off. See *Reading a storefront that
  has closed its catalogue* below.
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

### Reading a storefront that has closed its catalogue

Supreme is a Shopify store (`us.supreme.com` → `eu-production.myshopify.com`) with every
machine-readable surface switched off. Probed directly, on the day this was written:

```
  /products.json                403   /collections/all.atom       403
  /collections.json             403   /sitemap.xml                404
  /products/<handle>.js|.json   403   /meta.json                  200  ← the only one
  /collections/all              200 — HTML, client-rendered, no product links in it
```

So every adapter above declines and discovery lands on `PageWatchSource`, which hashes the
visible text of a page whose products are drawn by JavaScript. **The hash never moves.** The
brand row says "WATCHING", the source records no error, and the app delivers nothing, ever —
the exact "every layer reports healthy and the feature does not exist" failure this file
keeps a list of.

The same robots.txt that fronts those 403s says *"Agents should use UCP/MCP for catalog"* and
gives the discovery URL. The door was moved, not closed, and `UCPSource` walks through it.

- **It is read-only by construction.** The endpoint also exposes `create_cart`,
  `create_checkout` and `complete_checkout`. None appear in `UCPSource`, and `UCPAgent`
  declares only the two catalogue capabilities — a business reads that profile to decide
  what to send and what we can handle, so claiming `checkout` would be claiming to be a
  shop. Supreme's own robots.txt draws the same line: "Checkouts are for humans."
- **UCP is a negotiation, and the agent profile is the price of entry.** A business fetches
  `UCPAgent.profileURL` *from its own network* before answering; without it every call gets
  `UCP discovery failed`. So the server serves it at `/.well-known/ucp` and both modes quote
  that URL — a phone cannot host one. **If UCP sources start failing everywhere at once,
  curl that URL first.** The failure ladder, all three seen live: no profile sent → "Missing
  ucp version"; profile sent but the route not deployed → "Unable to fetch agent profile:
  Http error"; deployed → it works.
- **This is not a Supreme workaround — it is most of Shopify.** Probed live,
  `/.well-known/ucp` with `catalog.search` is published by Kith, Palace, BBC ICECREAM,
  Stüssy, Aimé Leon Dore, Allbirds and Gymshark; of the eight tried, only one had none. Those
  brands all still serve `/products.json`, so `ShopifySource` keeps them — but any of them
  could switch it off tomorrow, as Supreme did, and the fallback is now in place.
- **Verified against real catalogues, not only fixtures.** `admin/ucp-test` against Kith,
  Palace and BBC returns 250 products each (five pages of fifty, so paging works), with
  prices converted correctly — `US$180`, not `US$18,000` — and real size runs including
  Palace's hat sizes ("7 1/8"). Supreme itself answers `0 products`, which is **correct**:
  its own page markup reads `{"allProductsCount":0,"products":[]}` between drops.
- **`available: false` means "do not narrow", confirmed by measurement.** Against Kith it
  returns 109/461 variants in stock where `true` returns 127/445 — so `false` genuinely
  includes sold-out stock rather than selecting only it. Worth having checked: the opposite
  reading would have silently hidden everything buyable.
- **The status is not the message.** A refusal arrives as **422 with the reason in the
  JSON-RPC body**, and that reason names the fix. Reading the status first reported "Server
  returned 422" and threw the sentence away, so the body is decoded first and the status
  only speaks when nothing in it can. `SourceError.ucp` is its own case because these
  failures are usually *ours*.
- **`search_catalog` is a search, not an enumeration.** No sort-by-newest, and the UCP
  product model has **no publication date at all** — so this pages a bounded window and lets
  dedupe on `externalID` decide what is new, `since` cannot narrow the request, and
  `publishedAt` is "first seen". `Reshelving` can therefore say nothing here, which is its
  documented safe default.
- **`available: false` is sent deliberately.** The endpoint narrows to sale-ready items by
  default, which would hide exactly the sold-out drop somebody wants telling about — and the
  restock could never fire, because the product would never have been stored.
- **Prices are minor units.** `{"amount": 19800, "currency": "GBP"}` is £198.00. Zero-decimal
  currencies (JPY, KRW) are already whole and must not be divided.
- **Discovery re-reads `/.well-known/ucp` every poll** rather than pinning the endpoint seen
  the day a brand was added, which would mean silently polling a dead URL the day it moves.
- **Ranked below the sitemap, above a page watch.** On data alone it should outrank nearly
  everything — prices, variants, live stock. What holds it down is that it is the only
  source whose success depends on *us* being reachable, and demoting a working sitemap for
  something that can fail on our side is the wrong trade. Above a page watch the argument is
  unanswerable.
- **`POST /admin/ucp-test?url=` reports per stage**, for the same reason `push-test` does:
  "0 products" is equally true when a store has no UCP, when our profile 404s, and when the
  season is simply over, and those have three different fixes.

### Deliberate design decisions

Changing these silently will break intended behavior:

- **Instagram is never scraped.** `BrandSource.Kind.instagram` has `isAutomatic == false` and
  `SourceAdapters.adapter(for:)` returns `nil` for it — it is a stored deep link only. Aggregating
  arbitrary public profiles isn't permitted and unofficial endpoints break constantly.
- **`BrandUpdate.passes` is the one browsing filter, and every list calls it.** It said so in its own
  doc comment for a long time and had *no callers*: the feed applied `profile.allows(gender)` inline
  and `BrandFeedView` — which is where "+36 more from Kith" goes — applied nothing at all. So a
  Menswear setting held on the feed and evaporated the moment you opened the rest of the same drop,
  which reads as the setting being broken rather than as one screen missing it. Gender hides; **size
  does not** — a size you don't wear is said in vermilion, not by removing the product, because a
  sold-out size today is the restock this app exists to catch. A new screen that lists a brand's
  output calls `passes`; it does not write its own copy of the rule.
- **A count is subject to the same filter as the list it counts.** `Brand.unseenCount` counts
  everything unseen and no screen means that: the feed cleared to "all caught up" under a Menswear
  setting while the brands list still claimed 40 unread and the brand page still printed UNREAD in
  vermilion — about womenswear it had just decided not to show. Two screens describing one queue and
  disagreeing about its size reads as the number being broken. Every visible count calls
  `Brand.unseenCount(matching:)`; the unfiltered one survives only for a caller that genuinely means
  every row.
- **`FeedView.feed` is one pass, and that is a correctness property as much as a speed one.**
  Marking a brand read writes a row per update and saves, which invalidates the `@Query` and
  re-renders — and the view then answered four more questions on the way back, each a full walk of
  every brand's `updates`, each calling `passes`, which reads `gender`, which **re-runs the
  classifier whenever the stored revision differs from this build's** — the steady state for
  anything the server classified. So dismissing one brand cost thousands of string classifications
  before a frame could be drawn, which is the reported lag. Anything added to that body walks the
  relationship once or not at all.
- **A stored classification that keeps re-deriving has to be written back.** `Classification`
  settles stale `genderVersion` rows in bounded batches after a sync and on foreground. It
  recomputes *locally* and stamps the local revision, which is honest — the prohibition below is on
  stamping the local number onto a **server-supplied** raw value, which freezes somebody else's
  verdict forever.
- **A product page says what is left now, not what was left when the event fired.** A feed row's
  variants are a snapshot: right for a record, wrong for the one screen where somebody is deciding
  to buy something. A hoodie that dropped on Friday and sold out on Saturday still printed a full
  run of ticks with "IN YOUR SIZE" over it and a buy button underneath. `StockRefresh` re-reads the
  storefront on `ProductDetailView` and `SaveDetailView` only, throttled by `stockCheckedAt`, and
  touches **stock alone** — rewriting `priceText` would leave a markdown comparing today's price
  against a "was" from another week. It fetches from the phone in both modes, the one documented
  exception to the table further down: `SharedSaveImporter` already does the same through the same
  adapter, and there is no route for "what is in stock right now" because the question is always
  about the single product being looked at.
- **Following a brand the poller has watched for months hands over its recent history, pre-marked
  seen.** The feed cursor is one timestamp across every followed brand, so `GET /v1/feed` correctly
  reports that nothing has happened since — the brand page opened empty, its counts read zero, and
  nothing said it was being watched until the next drop, which for a seasonal label is months away.
  `GET /v1/brands/:id/feed` is a bounded window over one brand and `RemoteSync.catchUp` merges it as
  a **baseline**, the same rule as `SyncEngine`'s first sync and the poller's `baselined_at`. It
  must never advance `cursor` — that would skip every other brand's events in the same window — and
  must never arrive unread, which is the 250-product bug delivered at the exact moment somebody is
  deciding whether following was a good idea.
- **A collection is not a product** (`CollectionCard`, `CollectionReleaseView`). It is the one update
  that is *about* other updates, and it was drawn as a garment: no photograph (a season page rarely
  has one), an empty size run, no price, and a tap onto a product page with nothing on it — so
  "DENIM TEARS FW26", the most interesting thing a brand posts all season, rendered as the emptiest
  card in the feed. Releases are hoisted above the products in a brand's group, because they are the
  headline and the garments are the contents. `Brand.members(of:)` reconstructs which garments
  belong to one — `/collections.json` names a release and does not list it — from a distinctive word
  in the title (brands tag their seasons) falling back to a publication window. Deliberately a
  heuristic: the alternative is a network call per card in a scrolling feed, and being wrong costs a
  page with a few extra garments rather than a missed drop. **`members(of:)` admits `.product`
  only.** It filtered on `kind != .collection`, which lets in every other kind of event — and a
  release lands in the middle of ordinary trading, so the window swept up restocks of last season's
  stock and price drops off the sale rail and printed them as the contents of a new collection. A
  restock is by definition not part of something only just announced, and the word match is no
  protection because a re-shelved item from the same season carries the same season code.
- **One garment, one row, in every list** (`BrandUpdate.oncePerProduct`). The store holds *events*:
  a feed row is `event:<uuid>` and one jacket drops, is marked down and comes back in an L, so a
  brand page, a release and a brand's spread each printed it three times at three prices. Keyed on
  `productExternalID` — the garment — never on `externalID`, which is the event; a row with no
  product behind it keeps its own key so two unrelated links can never collapse into one. The
  survivor is the newest by `newestFirst`, so the choice is stable across relaunches. **Anything
  that clears a list has to clear the rows it folded away**: `markSeen` and "Mark all seen" walk
  `brand.updates`, not the deduplicated array, or the brand returns to the feed showing the same
  jacket. `unseenCount(matching:)` counts distinct garments for the same reason — counting rows
  said 40 above a page showing 25.
- **`published_at` says when a product was last put on a shelf, not when it is new.**
  Storefronts rewrite it on every re-merchandising sweep — Kith's own tags say so
  (`081126NIKEremerch`, `shopifyflow:removedtag`) — so a fifth of its 250 newest products
  were created more than three months before they were "published", one Air Max 1 by 1,015
  days, and the sold-out ones landed as a page of new clothes nobody could buy. `Reshelving`
  reads `created_at` beside it: a launch keeps its kind, a re-shelving you can buy is a
  `.restock`, and a re-shelving with nothing buyable in it is **silent** — stored, so a watch
  still reaches it and a real restock still fires, but never announced. Ninety days, chosen
  to sit in the gap in the data rather than on a boundary; brands do build a product record
  a season ahead, and suppressing a real drop is the one failure this cannot afford.
- **`publishedAt` is not an ordering, and `BrandUpdate.newestFirst` is.** Storefronts stamp a
  whole drop with one second — Represent's 250 newest products carry 154 distinct timestamps —
  and a sitemap's `lastmod` is often date-only, so ties are the common case, not the edge.
  `sorted(by:)` is not stable and `brand.updates` is a to-many relationship whose array order
  is unspecified and free to differ between reads, so sorting on the date alone gave the tied
  items **a fresh arbitrary order on every render**. On screen: marking a card read in
  "+36 more" showed the wrong item next and then swapped back. Every list of a brand's output
  sorts with this comparator, which breaks the tie on `externalID`.
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
  rules. **Re-deriving is not free and must not be the steady state** — see `Classification`
  and the note about `FeedView.feed` above.
- **A stamp says *when* something was looked at; it must also say *what*.**
  `BrandUpdate.analyzedImageURL` sits beside `analyzedAt` because a row's photograph changes after
  the fact, and on the commonest path: a link shared from Safari lands with one Open Graph image or
  a URL that 404s, the pass stamps it (deliberately — a dead URL must not be retried forever), and
  `SharedSaveImporter.repair` then fills in the catalogue's real photographs. Every version field
  was already current, so nothing ever looked at them: no colour, no cutout, no measured aspect, no
  silhouette, for as long as the item existed. A photograph the analysis has not seen makes the
  whole pass due again. `ImageTagger.backlog` is the matching `.task(id:)` key — keying on
  `saves.count` meant new *work* was invisible unless somebody happened to save something else.
- **The classifier's inputs travel with its verdict.** `FeedItem` carries `productType` and
  `tags` because the client does not merely display them — gender, `GarmentSlot` and
  `StyleProfile` are all read off them, and with neither on the wire every server-backed
  item arrived as a bare title, so any local re-derivation could only answer `.unknown`.
  Unknown is never filtered, so the whole of YoungLA's womenswear — filed
  `product_type: "For Her"`, and named `W2156`, which is not a word — reappeared in a
  menswear feed. `RemoteSync.backfill` fills these in on rows written before that, because
  the merge skips ids it already holds and they would otherwise never heal.
  **It fills `variants` for the same reason, and that is the louder case.** A row stored before the
  feed carried them holds none for as long as it exists, and with no variants there is no size run,
  no colourways and nothing to watch — the two things a product page is *for*, absent on exactly
  the brands somebody has followed longest. Filled only when empty, never overwritten: an event is
  a record of what happened, and the stock in it is what was true when it fired.
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
- **Bottoms have their own ladder, and it is not apparel.** A 32 is not an M, no table converts
  between them, and a person wears one of each — so `SizeKind.waist` is its own case. Without it
  every pair of trousers normalised to `.other`: never hidden, and never *matched* either, so on
  denim and workwear — half of what these brands make — the size feature was simply switched off.
  Two bands, and the difference is the whole care taken: a string that **names** itself a waist
  ("W34", "34W", "waist 34", "32x30") is read across the full human range, while a **bare** number
  is only a waist up to 37, because from 38 up it collides with the EU shoe ladder and guessing
  would *hide* a product. Note `w` is also the women's-shoe marker: "W 9" falls out of the waist
  reader by range and lands on the shoe ladder, and there is a test pinning that.
- **Each ladder filters only once it has been filled in.** They are separate questions — a shoe size
  says nothing about a waist — and the profile-wide `isEmpty` guard could not express it: somebody
  who had entered shoe sizes and nothing else had *every garment in the app* hidden, because an
  empty `apparel` set matched no letter. Adding a third ladder made that three times as likely to
  be reached. Adding a fourth means adding the `isEmpty ||` to its case too.
- **A size spelled out in full is the same size.** YoungLA writes its entire catalogue as
  `XXSmall, XSmall, Small, Medium, Large, XLarge, XXLarge`, and the word table held only the three
  bare words — so every extremity fell through to `.other`: never hidden, per the rule below, but
  never *matched* either. On every product the brand makes, somebody's own size was the one token
  not ruled in vermilion. `SizeNormalizer.shortened` folds an all-`X` prefix (or the `2X`/`3X`
  shorthand for one) onto the short form before the lookup. The prefix must be X's and nothing
  else: "petite small" is not an S, and folding it into one would put the wrong garment in a
  size-filtered feed, which is the failure this whole layer exists to prevent.
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

- **Some products have no photograph, permanently, and that is different from loading.** Palace's
  sitemap publishes entries with no `<image:loc>`, so those rows hold an empty image array for as
  long as they exist. They were drawing the `kind` symbol — a small grey sparkle on a blank tile —
  which is indistinguishable from an image still on its way, so a brand page sat there apparently
  loading forever. `UpdateImage.mark` sets the brand's wordmark in its place: a statement rather
  than a wait. Anywhere a photograph *is* the feature rather than decoration, such a product is
  excluded outright instead — the fit tray and `FitSuggestions` both filter on a non-empty image
  array, because a collage is made of pictures and offering one that isn't there is offering
  nothing.
- **A fit render is never written with a hole in it.** `ImageRenderer` draws one frame
  synchronously, so a piece still loading comes out as an empty rectangle — and that is written to
  disk and drawn on the card *for as long as the fit exists*, since nothing recomputes a render that
  already succeeded. `FitRender.warm` now reports whether every piece decoded and `save()` skips the
  write when it didn't; keeping the previous render, or none, beats baking in the gap.
- **`CachedImage`, not `AsyncImage`.** `AsyncImage` treats *cancellation* as failure, so scrolling a
  `LazyVGrid` — which tears down off-screen rows and cancels their loads — latches a broken tile
  permanently, with no way to ask for a retry. `CachedImage` leaves a cancelled load in `.loading`,
  retries transient failures twice, and collapses duplicate in-flight requests for one URL.
- **Ask the CDN for the size being drawn.** Storefront originals are 2000–3000px and a feed spread
  pulls seven; that is most of why loads were being cancelled in the first place. `ImageRendition`
  snaps to a **ladder** of widths so a 118pt tile and a 121pt tile share one cache entry instead of
  minting two URLs for the same photograph. An unrecognised host is left completely alone — a
  resize parameter a CDN doesn't understand is at best ignored and at worst a 404.
- **A colourway selects a photograph, and the catalogue always said which.** Selecting "Aqua"
  filtered the size run while the gallery went on showing the black one, which reads as the control
  being broken rather than as a missing feature. Shopify publishes the association twice, in two
  encodings — `variant_ids` on each image in the list endpoint, `featured_image.position` on each
  variant in `/products/<handle>.js` — and the adapter decoded neither, so the two paths need
  different arithmetic (one is zero-based, the other is not) to produce one answer. `VariantInfo`
  carries an **index**, not a URL: the URL is already in the images array and sending it per variant
  would put a second copy of every photograph on the wire. Nil is normal and common — plenty of
  storefronts publish nothing, and Palace and BBC put each colourway on its own product handle — so
  a nil must leave the gallery alone rather than jump it to the first frame, which would look
  deliberate and be wrong. `ImageGallery.selection` is an optional binding for the same reason:
  callers that only page by hand keep the gallery's own state, and the two are never synced as
  separate properties or a swipe would fight the selection that caused it.
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
- **A headcount has to earn its weight** (`Popularity.confidence`). Normalising by the maximum makes
  a number between 0 and 1 at any scale, which quietly turned a *two-person* lead into a full unit
  of evidence — a bigger gap than the entire spread of affinity, since every streetwear catalogue
  resembles every other and similarities bunch in a narrow band. So the ranking was "whatever two
  people follow" wearing the clothes of a taste engine. Damped smoothly rather than by a threshold,
  or the list would reorder the day one person joined.
- **A dismissal is the only negative signal, and it is not just a hide.** `BrandDismissal` stores the
  refused brand's vector, and `Recommender.repulsion` demotes candidates that *resemble* it — one
  tap on a technical-outdoor label should quiet the other four. Measured against the **nearest**
  refusal, never the average: rejecting a loud graphic label says nothing about the quiet Japanese
  one further down. Weighted below taste, because people reject things for reasons that have nothing
  to do with the clothes. Local, like the taste vector, and for a stronger reason — what somebody
  turned down is more revealing than what they followed.
- **A recommendation's photographs are budgeted per brand, in SQL.** `/v1/brands/popular`
  fetched them with one date-sorted query and a global `LIMIT`, then enforced a per-brand cap
  while grouping the rows — which enforces nothing, because the cut already happened. A brand
  that publishes 250 items in one sweep owned the whole window: measured against production,
  **fourteen of thirty-five recommendations came back with no photographs at all**, and
  Represent came back with one delivery graphic, its garments all being older than the global
  cut so the "everything here reads as promotional" fallback had nothing else to pick. The
  tell is that a brand's picture count *changes when `limit` changes*, which a real per-brand
  budget cannot do. It is now one small query per candidate, which is what
  `AddProductBrandIndex` exists for — `products.brand_id` is a foreign key and Postgres does
  not index the referencing side by itself.
- **`PreviewImages.pick` decides the fallback on what has a photograph, not on what survived
  the vocabulary.** A brand whose garments are all imageless — ordinary for a sitemap source
  — otherwise counts as "filtering removed nothing", skips the fallback, and returns an empty
  list built from rows that did have pictures.
- **The block prints six and the list holds thirty.** Three cards is one screenful of a scroll
  you were already doing, and two of them are usually brands you have an opinion about — too
  small to be an offer. Thirty fetched, because "SEE ALL" led to a page of six otherwise.
- **A card says why, and the reason is the one the ranking used.** `sharedTraits` reads the terms
  contributing most to the dot product, so the line cannot drift from the score. It printed the
  follower count instead, which at this scale read "1 PERSON WATCHING" on every row — an argument
  *against* following, under every brand, on the block whose job is to make following attractive.
  `GarmentSlot.unknown` is excluded: it is the classifier declining to answer and is a large share
  of most catalogues, so it matches constantly and means nothing ("LIKE YOUR UNKNOWN").
- **A term fit to be scored is not automatically fit to be printed.** The vocabulary keeps every
  token a merchandiser wrote *on purpose* — IDF is what decides whether it means anything, and a
  code nobody else uses is genuinely distinctive. That is right for the arithmetic and wrong for
  the caption: the block was reading "LIKE YOUR ITP" under a brand it was trying to sell. `Trait`
  gates the sentence and nothing else — four letters, a vowel and a consonant, and a short list of
  ordinary words that describe the shop rather than the clothes ("sale", "mens"). A brand whose
  only shared terms are unreadable falls through to the category line that already exists.
- **The block builds its ranking once per render.** `recommender` rebuilds a taste vector over
  every save in the store, and it was being read by `visible` and then again by `reason(for:)` for
  each card — seven full builds per body, on a block that sits on three tabs.
- **Anything written in `StyleStatement` is blended in additively and modestly.** A save is a
  record of behaviour and a sentence is a claim; a stated word is worth about as much as a term
  appearing in a handful of saves. Only terms the candidate set already uses survive, exactly as
  the taste vector does for saves. Dislikes are deliberately *not* applied here — a brand is not
  demoted for stocking one thing somebody avoids, and `BrandDismissal` is where a negative signal
  about a brand belongs.

### Saying it in words

`StyleStatement` is the one place the app asks instead of inferring, and it is small on purpose.
It reads three things out of free text — words you like, words a negated clause rules out, and
things named either side of "with" — and ignores the rest. Written in `StreetwCore` because
`Pairing` and `FitSuggestions` both consume it and must not disagree about the same two garments.

- **"with" is the only word given structural meaning.** It is the only one that reliably names a
  relationship between two garments rather than a property of one. "and" was tried and is useless:
  "black and white" is one garment as often as it is two.
- **A stated pairing outranks the colour wheel and can overrule its veto.** Everything else here is
  inferred; this is somebody saying it. An app that refuses the outfit its user just described is
  arguing with them. It cannot beat the **slot gate** — two tops do not become an outfit because
  somebody typed "tees".
- **It reorders; it never hides.** Same rule as the size profile, for the same reason: a filter you
  did not know you had set is indistinguishable from a broken feed.
- **The field prints what it understood.** A free-text box that silently changes behaviour is a
  black box, and a black box that is sometimes wrong is worse than no box. The reading under it is
  what makes it correctable.
- **Local only.** It never goes to the server — the same bargain as the taste vector, and for a
  stronger reason: it is a sentence somebody wrote about themselves.
- **`FitSuggestions` ranks through `Pairing` but still vetoes on the colour clash alone.**
  `Pairing.isRefused` is a stricter bar built for a page that may print nothing; applying it to the
  fit row would empty it on a thin wardrobe, which is the wardrobe most in need of a suggestion.

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
- **The drain that matters is the one on `scenePhase == .active`, and it must carry the
  `PushRoute`.** `ContentView`'s `.task` fires once per appearance, so it never sees a share that
  arrives while the app is already alive — which is the whole "share from Safari, switch back"
  flow. The scene-phase drain in `streetwApp` is what actually runs, and it was passing no route:
  `offerWatch` returned at its first `guard`, the save was committed, the inbox file was removed,
  and the sold-out prompt had nothing left to be asked about. It was reachable only on a cold
  launch, and only if the `.task` won the race.
- **Not every Shopify storefront serves `/products/<handle>.js`.** Palace 404s it on the apex,
  `www.` and `usa.` alike, while answering `/products.json` fine — so `ShopifySource.product(at:)`
  returned nil for every Palace share and the importer fell through to Open Graph: no size run, no
  colourways, no stock, and therefore never an offer to watch a sold-out item. The page's own
  markup is not a substitute; Palace advertises schema.org `inStock` on products whose every
  variant reads `available: false`. The fallback searches the **catalogue listing** rather than
  `/products/<handle>.json`, which is served where `.js` is not but omits `available` — the one
  field the whole feature turns on. Bounded by `maxListedPages`, because somebody is waiting.
  It also swaps to `www.` to find the catalogue, and **the currency then comes from the host that
  answered, not the host that was shared**: Palace's apex is USD and its `www.` is GBP, so reading
  one and pricing against the other prints a British price with a dollar sign on it.
- **An event id is not a product id, and the share importer needs the second one.** A feed row is
  keyed `event:<uuid>` because one garment produces several events over its life — a drop, a
  markdown, a restock — and that is right for a feed and useless for asking "are these the same
  thing". `SharedSaveImporter` keys a catalogue hit `shopify:<id>`, the way the *local* poller
  keys it, and looked for an existing row under that key alone: which a server-backed row never
  has. So sharing something the app was already showing you minted a second card for it, in the
  only mode the app ships in — the dedupe worked standalone and nowhere else. `FeedItem` and
  `BrandUpdate` now carry `productExternalID` beside the event key, `backfill` fills it on rows
  written before it existed, and `existingRow` matches on either. A product match can be ambiguous
  (several events, one garment): a row that is already **saved** wins, since that is the one
  carrying somebody's note and board; otherwise the most recent.
- **A share that landed badly must get another chance.** Enrichment runs once, at import, and the
  inbox file is deleted immediately after — so a link that found no catalogue record kept a title
  and one Open Graph photograph *permanently*: no price, no size run, no colourways, no stock and
  therefore no watch. Every reason the first attempt fails is temporary or fixable — a regional
  subdomain that publishes no catalogue at all (`eu.palaceskateboards.com` answers nothing),
  a storefront that was slow that minute, a product further back than `maxListedPages` pages while
  somebody waits, or an older build. `SharedSaveImporter.repair` is the `cutoutVersion` pattern
  applied to that: `BrandUpdate.enrichmentVersion` decodes 0 on an older row and earns one more
  look, and is stamped **even when the attempt found nothing**, so a genuinely un-catalogued link
  is not re-fetched every launch forever. Bump the version when enrichment learns something.
- **A brand is not one hostname.** Palace answers on the apex, `www.`, `usa.` and `eu.`; the Brands
  tab holds whichever one it was added with. `matchingBrand` compared exact hosts with `www.`
  stripped, so anything shared or discovered from the other three was attributed to nobody — which
  on screen is a collection tile with no wordmark, a detail page titled "Saved", and an item
  contributing nothing to the brand facet of the style profile. Five of eleven saves in the test
  store were in that state, all Palace. `BrandDiscovery.registrableDomain` compares the last two
  labels (three under a `co.uk`-shaped suffix); `attachBrands` heals rows that already landed, and
  needs no version stamp because it costs no network and is idempotent. It is deliberately a
  heuristic and not the Public Suffix List — the worst outcome of an unlisted suffix is a save that
  stays unattributed, which is where it already was.
- **A save has a brand name even when there is no brand.** `Brand` is only attached when the link
  matches something followed, so everything shared from a label nobody has added — which is most of
  what sharing is *for* — was anonymous: no wordmark on the wall, "Saved" for a page title, nothing
  to tap. The host is not the answer either, since `bbcicecream.com` is Billionaire Boys Club. So
  `SharedSaveImporter.identifySites` runs the same `SiteIdentityProbe` a followed brand's name comes
  from — one homepage fetch **per host**, not per row, grouped before anything is requested — and
  stores `siteName` and `siteLogoURLString`. `BrandUpdate.brandLabel` is the one accessor: followed
  brand, then declared site name, then the tidied domain. Every surface that used to print
  `brand?.name` now prints that.
- **The brand line on a saved item is a way in, with three honest destinations.** Followed pushes
  the brand page; known-but-unfollowed opens `BrandPreviewSheet`, which exists precisely to answer
  "should I follow this"; unknown opens `AddBrandView(prefill:)`. The catalog is searched before the
  add flow is offered, the same rule `AddBrandView` itself follows.
- **Enrichment takes the catalogue's whole set of photographs over the single Open Graph frame.** A
  share arrives with the one image published for link previews; keeping it because the field was
  technically non-empty left a gallery reading "1/1" about a garment the app had eight pictures of.
  Only ever *more*, so a storefront that publishes one is never talked down to zero — and the images
  it gains are what put the row back in front of `ImageTagger`.
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

**A brand carries its sources on the wire, and the client cannot work them out.** In server
mode the phone never discovers anything and never polls, so the *only* way it can know a
brand is watched at all is if the follow list says so. It didn't: `BrandDTO` had no sources
field, `RemoteSync` never wrote `Brand.sources`, and the app then faithfully reported its
own empty array — "NOT WATCHED" on every row of the brands list, "0 SOURCES" on every brand
page, and an empty state claiming the site could not be watched automatically. Three false
statements about brands the poller was working through on schedule, and the one place a
failing source is visible was blank in the mode the app ships in. Notes on the fix:

- **`BrandSourceDTO` is not `BrandSource`.** `fingerprint` and `etag` are the poller's
  working state — a content hash and a cache validator — and mean nothing to anybody who is
  not doing the polling. Putting them on the wire would ship two fields a future client
  could only misuse. `RemoteSync.source(from:)` leaves both nil, which is correct: under
  `-standalone YES` the first poll of each source fills them in.
- **`kind` crosses as a string.** A server that learns a new source kind must not fail to
  decode on an older client and take the whole brand list down with it; an unknown kind
  renders as its raw name and counts as manual.
- **`BrandDTO.init` takes sources as a parameter rather than reading `brand.$sources`.**
  Fluent's `@Children` accessor traps at runtime when the relation was not eager loaded,
  and four routes hand over brands with four different query shapes. The parameter turns
  "somebody forgot a `.with`" from a crash on a production route into a compile error.
  `/v1/follows` needs the *nested* form: `.with(\.$brand) { $0.with(\.$sources) }`.
- **Every route that hands over a brand hands over its sources**, because the client stores
  one `Brand` row whichever route it arrived on — a search result that is then followed
  must not overwrite a populated list with an empty one.

### Everything must go over the server when one is configured

Each operation that could fetch from the phone is guarded by `settings.isConfigured`, with
the local path in the `else`. Adding a new one means adding both halves:

| Operation | Server route |
|---|---|
| launch/refresh sync | `GET /v1/follows` + `GET /v1/feed` |
| catch up on a brand just followed | `GET /v1/brands/:id/feed` (merged as a baseline) |
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
- **A weekly brand is not a dormant brand, it is a punctual one.** `quietForAWeek` put a
  source on the two-hour cadence, and a brand that drops once a week is quiet right up until
  the moment it isn't — so it was on the slowest schedule at exactly the minute it mattered
  and a Thursday 11am release could be found at 12:50. In streetwear that is not a late
  notification, it is a useless one. `Cadence.next(inDropWindow:)` drops to a minute inside
  the window `DropCadence.isWithinWindow` reads out of the brand's own publication history —
  an hour before the usual hour and three after, since the hour is a mean and a release
  staggers. Outside the window nothing changes, which is what pays for it: the same request
  budget, spent where something is actually going to happen. Never opened on a rhythm that
  isn't `isReliable`.
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
- **…and one push per brand per *cooldown*, because a pass was never the right unit.** A
  storefront does not publish a drop in one write — it puts out a few products, then a few
  more — and the poller runs at a five-minute cadence while something is happening, so each
  pass found two or three events and sent a push. One release read as "2 new items", then "2
  new items", then "3 new items" over half an hour. `brands.last_notified_at` is the ledger,
  in the row for the same reason `events.notified_at` is. The ordering is the point: the
  **first** sighting goes out immediately, and everything landing inside the cooldown is
  *held* — left unmarked, not discarded — and folded into one summary when it lifts. Three
  details are load-bearing. Cooled-down brands are excluded **in the query**, or a brand
  mid-drop fills the whole 500-event batch and starves everyone else for fifteen minutes.
  The stamp lands only when a push actually went out, so a brand every follower filters away
  is not muted on the strength of it. And a **watch alert is exempt** — it is the one alert
  somebody asked for by name, about one product in one size, and it is never the trickle.
- **`events.notified_at` is the push ledger**, in the row for the same reason as
  `next_check_at`. Events are marked even when nothing was sent — when no APNs key is
  configured, and when they are older than the 6h freshness window. Skipping that would
  mean the first deploy with credentials notifies every event ever recorded, and coming
  back from an outage fires a burst about drops that already sold out.
- **Push delivery is behind `PushSending`.** `Notifier` never imports APNs, so the whole
  fan-out — follows, size targeting, batching, dead-token pruning — is tested with no
  certificate and no network. Only `APNSPushSender` talks to Apple.
- **An event keeps what was true when it fired, including the price.** `events.previous_price_text`
  / `previous_price_amount` are on the *event*, not the product, for the same reason `sizes` is:
  the product row holds what is currently true and the next poll overwrites it. Without them a
  markdown could say "this got cheaper" and not what it dropped from or by how much, so the
  markdowns list had nothing to rank by. **One column per `update()`** in the migration — Fluent
  renders several `.field`s as a single `ALTER TABLE … ADD COLUMN a, ADD COLUMN b`, which Postgres
  accepts and SQLite rejects, so writing it the other way round passes everywhere except production.
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

- **A save is confirmed, not interrogated.** Filing used to be reachable only through the
  left-swipe board picker, and a watch only from a product page — so the app's best idea was
  three taps from the moment you wanted it. The fix is *not* to ask "which board?" on every
  save: most saves are reflexive, the honest answer is usually "I don't know yet", and taxing
  the common case to serve the rare one turns one tap into a decision. `SaveConfirmation`
  instead completes the save unconditionally and then offers to amend it — Board, and Notify —
  for `dwell`. Nothing waits on it and dismissing it changes nothing.
  - **A watch can now be set on something that is in stock.** That is the new capability, and
    the reason this exists at all. Wanting to be told your size went and came back is not
    conditional on it being gone right now, and until this the question could only be asked
    about something already sold out.
  - **No counting numerals.** A visible "3… 2… 1…" makes a quiet confirmation feel timed,
    which is the opposite of the intent. The dwell is a hairline that drains.
  - **It is owned by the app, not by the card.** The card that triggered it lives in a
    `LazyVStack` and is routinely recycled or scrolled away before you act on the toast; so are
    the two sheets, which are presented from `ContentView` because the toast dismisses itself
    on the tap that opens them.
  - **It clears the buy bar.** Anchored above the tab bar — `quickSave` owns the horizontal
    drag on the lower half of a feed card, so anything laid over that region fights a gesture
    for the same pixels — but a product page puts its buy button there, and covering it for
    four seconds at the moment somebody decided they want the thing is the worst possible
    place for a confirmation. `bottomClearance` lifts it while that page is up.
  - **A share gets the same confirmation, and it is the main point of it.** The extension
    cannot ask anything — it does no networking, so at share time nobody knows the title, the
    sizes or the stock — so a link from Safari used to land silently and the only way to file it
    or watch it was to go and find it again. `SharedSaveImporter.drain` now raises the
    confirmation for a landed share, on the next foreground, which is the first moment any of
    those answers exist.
  - **`announce` speaks once per drain, not once per item.** Sharing five things must not stack
    five sheets or flash five confirmations that each replace the last unread — and a
    confirmation whose two buttons act on *one* product has no honest subject when several
    arrived, the same reason a counted push carries no `eventID`. A batch is left to speak for
    itself in the collection.
  - **The sold-out share stays a sheet and wins outright over the toast.** It is deliberately
    *not* folded into the confirmation. A share is acted on when the app next comes to the
    foreground, which can be long after the fact and while looking at something else; a
    dismissible toast is right for a save you just made and watched happen, and the wrong shape
    for an offer you might not be there for. Raising both would be two answers to one share.

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
- **The collection wall does not invert, because photographs don't.** `Color.sweep` is the one
  colour in the app that is fixed rather than adaptive, and `UpdateImage`/`ImageGallery` take a
  `backdrop` so only the archive uses it — the feed keeps the adaptive `wash`, because a card there
  is a notice and should belong to whatever appearance the phone is in. Both halves of the problem
  are real and they pull the same way: a brand shipping **transparent PNGs** (Palace) has the
  backdrop showing through the garment's own silhouette, so at night a black jacket was drawn on
  near-black and the tile was a caption with nothing above it; a brand shipping **JPEGs on a white
  sweep** (Kith) carries its backdrop in the pixels, so letterboxing it with near-black put a
  lightbox inside a dark tile. Same wall, one brand invisible and the next one glaring, neither a
  fault in the photograph. `SaveDetailView` passes `sweep` too — opening a tile must not change what
  the garment is standing on. The fit canvas is the remaining surface with this property and still
  uses adaptive `Color.paper`.
- **The garment first; the brand is the caption.** The wordmark used to sit *above* the title in
  tracked caps, so the most repeated line on the wall carried the most visual weight — six tiles
  shouting PALACE SKATEBOARDS over six different products. A brand name earns its place by marking a
  *change* of brand, so `CollectionTile` also goes silent when the visible wall is one label
  (`SavedView.isMixedBrand`, computed over what is showing rather than over the whole collection, so
  a single-brand board quiets it and going back to Inspiration brings it back). Removing the name
  outright was the other option and is worse: browsing by label is a real thing to do in an archive.
- **The photograph is asked six things, not two** (`VisualReading`, `Histogram`,
  `Silhouette`). Dominant colour and Vision's category labels both answer questions a
  product *title* could mostly have answered too. The picture knows more, and all of it was
  going unasked while the bytes sat decoded: a **second colour**, **busyness** (colour
  variety plus edge density — what makes two loud pieces argue, and no tag anywhere says
  it), **text coverage** (the axis catalogue parsing can never reach, because no brand files
  a hoodie under "logo-heavy"), **shape** off the cutout mask, **tonal register** (how dark,
  how colourful — this is what separates a Palace wardrobe from a Kith one while both read
  "mostly black"), and a **perceptual fingerprint**. All on device, all from requests that
  ship with the OS, none of it leaving the phone. `VisualReading.version` is the
  `cutoutVersion` pattern — bump it and every row gets one more look.
- **`visionBusyness` is not a claim that there is a print.** A four-panel colourblock jacket
  scores high with no print on it at all, and that is correct for the thing it feeds:
  whether two pieces argue when worn together. Naming it after prints would invite the wrong
  reading and then the wrong fix.
- **Text outranks busyness when naming what a garment is doing.** A chest wordmark on an
  otherwise plain hoodie is *Logo*, not *Graphic* — filing it with the all-over prints puts
  it where it does not belong. One label per item, so nothing double-counts.
- **The measured reading beats the word list wherever there is one** (`Garment.isStatement`).
  The vocabulary was always a stand-in for looking: "camo" in a title is a guess that the
  picture is busy. It stays, because `ImageTagger` only runs over saves, so a product on a
  page nobody has kept has never been measured and words are all there is.
- **A silhouette is refused far more often than it is given, and every guard was earned.**
  Read on the widest row, a funnel-neck fleece and a Palace hoodie both came back "Cropped"
  — because a top laid flat has its sleeves out, so the widest row is the *wingspan* and
  says nothing about the cut. It reads the hem now. There is deliberately no "Cropped" at
  all: cropped and boxy both widen the body against the length and these measurements cannot
  separate them, so claiming to would be a guess dressed as a measurement. Three further
  refusals, each added after the logs showed it was needed: the outline must be
  substantially smaller than its bounding box, it must **vary across its middle** (a frame
  with softened corners narrows only at the ends and is otherwise a rectangle), and the
  answer must be a shape a garment can physically be — a real collection produced tops 1.29
  times wider at the hem than they were long, which is a photograph being measured.
  **`SilhouetteBands` lives in `StreetwCore` while the measuring stays in the app**: the
  pixels need CoreGraphics and cannot go there, but the bands are the part with an opinion
  in them and the only part testable without a photograph — which matters, because Vision
  produces no mask in the Simulator and that path can never run in a test at all.
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
- **A suggestion looks at the clothes, not only at the schema.** Every rule in `FitSuggestions` was
  structural — one top, one bottom, both things you kept — so a pair could satisfy all of them and
  be obviously wrong to anyone with eyes. `ColorHarmony` reads the dominant colour `ImageTagger`
  already stored, ranks the pairings and drops outright clashes. Deliberately **not** a model: there
  is nothing to train on, and the same rule that governs the brand recommender applies here — a
  recommender that is clever and wrong is worse than one that is obvious and right. Three things it
  must keep doing: a neutral goes with anything (most streetwear is black, grey, cream or denim, so
  that is the common case and not the escape hatch); navy and brown count as neutrals, because they
  are chromatic to a colour picker and neutral to a wardrobe; and an **unknown or missing** colour
  scores neutral rather than badly — nothing has been analysed yet is not the same as having looked
  and disapproved, and Vision does not run in the Simulator at all. The candidate pool is widened
  past `limit` before ranking, or the sort is just sorting an arbitrary six. It also returns the
  line saying why, which is what the card prints: a suggestion nobody can account for is
  indistinguishable from a shuffle, which is what the row felt like.
- **Placements are normalised, never points.** `FitPlacement` stores centre as a fraction of the
  canvas, so one description of a fit lays out identically at 900px for a render and at 168pt for a
  card — and a fit made on a Pro Max doesn't scrunch on a mini. It decodes leniently by hand for the
  usual reason: SwiftData decodes a stored Codable with an internal `try!`.
- **`z` is sparse and unbounded in both directions.** Bringing a piece to the front is one write
  instead of renumbering the canvas, and sending one to the back is `min - 1` — which is the only
  way to reach something a big coat has buried.
- **A piece's size is its frame, not a `scaleEffect`.** For a `scaledToFit` image the two draw the
  same thing, but a scale effect multiplies everything laid *over* the piece with it: the selection
  outline thickens and the handles come out as thumbnails on a jacket and specks on a ring. It
  matters in `FitCanvasSurface` too — a render at 900px would otherwise be a 400pt drawing blown
  up. Anything overlaid on a piece depends on this.
- **The corner handle scales *and* turns, and it reads in the canvas' coordinate space.** A pinch is
  the fast path, not the only one: two fingers on a piece the size of a stamp is a gesture nobody
  can aim, and pinching the topmost of an overlapping stack is a coin toss. The handle it starts on
  is itself rotating and scaling as the drag proceeds, so measuring locally would have it chasing
  its own tail — hence `.coordinateSpace(.named(_:))` on the canvas. The turn accumulates from the
  previous angle rather than from the start, or a rotation past half a revolution snaps back when
  `atan2` wraps.
- **The handles live inside the piece's bounds, bought with empty padding.** A view drawn outside
  its parent is one clip away from being untappable. The padding is empty, so it draws nothing and
  catches nothing — which is what stops the gap between two pieces stealing a drag.
- **A drag out of the tray is `.draggable`, not a `DragGesture`.** The tray is a horizontal
  scroller, and any gesture that begins on touch fights the scroll for the same finger; lift-on-long
  -press does not. The payload is a prefixed `String` rather than a custom `Transferable`, because a
  bespoke UTI has to be declared in the Info.plist and this project has already been bitten by keys
  Xcode silently drops — the prefix is what makes anything else dropped on the canvas refused rather
  than parsed hopefully. Dropping something already placed **moves** it: one saved thing is one
  garment, and two of the same jacket is not a fit.
- **A drag ends with the centre still on the canvas.** The canvas clips, so an unclamped drag posts
  a garment somewhere it can never be grabbed back from. Clamping the centre rather than the whole
  frame still lets half a piece bleed off the edge, which is a real collage move.
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
  - **`StyleReading` holds every threshold that turns a measurement into a word**, because two
  copies would drift and the symptom is specific: a facet reading "Graphic · 12" that opens
  onto nine items, which reads as the count being broken. `StyleProfile.build` counts with
  it and `CollectionFacet.matches` filters with it.
- **Register sits above categories in the taste block.** "Dark, muted, plain" is a sharper
  reading of somebody than "hoodies and sneakers", which describes half of streetwear.
- **A facet is a query, not a statistic.** The taste block printed four comma-joined lines of
    nouns and ended there — the app's own reading of what you like, with nothing to do about it, on
    the page whose whole subject is you. Each word is now its own control and opens the collection
    narrowed to it, via `CollectionRoute` (the `PushRoute` shape, built in `streetwApp.init` for the
    same reason: a view that reads it appears before anything could have set it). Two details are
    load-bearing. `CollectionFacet.matches` **mirrors how `StyleProfile.build` counted**, including
    the photograph-then-text order — if they drift, a facet reading "Black · 12" opens onto nine
    items and the count looks broken. And the route carries a request *counter* as well as the
    facet, because asking for the facet you are already looking at is a legitimate way back to the
    Saved tab, and an unchanged value publishes nothing. The chip in `SavedView` is always visible
    while it applies and always removable: a filter set from another tab that you cannot see is
    indistinguishable from a collection that has lost things.
  - **"What's missing" is the one thing this tab can say that no other screen can.** The feed knows
    what is new and the collection knows what you kept; neither can tell you that you have six tops
    and nothing to put with them — which is also the reason the suggestion row is sometimes empty
    for no visible reason. Counted over `SaveType.wardrobe` when there is one, since the question is
    about what you own, falling back to everything saved because most people never split the two.
    Only over `GarmentSlot.essential`: saying somebody is short of headwear is a fashion opinion,
    and this is meant to be an observation.
  - **Discover sits below the reading of your own wardrobe.** It used to sit above it, which made
    the tab about you open as a shop.

- **"Wear it with" is the one thing an archive can say that a catalogue cannot** (`GoesWith`,
  `Pairing`). It reads both ways round: on something you haven't kept it is the argument for
  keeping it, and on something you have it is the start of a fit. The judgement is in
  `StreetwCore` beside `ColorHarmony` so this page and the fit row can't disagree about the
  same two garments. Four rules — slots must complement (a gate, not a score), colour via
  `ColorHarmony`, weight must agree, one statement piece — and the interesting one is
  **absent**: no formality penalty. A blazer with track pants is the house style here, so
  the first rule anyone reaches for would spend its time refusing the best answers the app
  has. Note also that a *fabric* is not a season: `wool` and `linen` and `mesh` were in the
  seasonal lists and the tests took them out, because a wrong refusal is invisible — the
  suggestion never appears and nobody can tell it was suppressed.
- **The classifier's vocabulary is read off real wardrobes, not guessed at.** Three of eleven
  saves on the test device were `.unknown` — invisible to fits, pairings and the wardrobe's
  own slot counts — and two were ordinary clothes: Palace names its hoodies "P3 HOOD", and
  `fleece` was in no list at all. `blazer` was missing too, found by a pairing test that was
  asserting about formality and failing on the slot gate instead. Compound names still
  resolve correctly because the table is walked in slot order: "Fleece Jacket" is outerwear,
  a bare "fleece" is a top.
- **Emptying a brand's unread page leaves it** (`BrandFeedView`). That screen *is* the unread
  queue for one brand, so clearing it with the checkmark left you looking at a page whose
  entire content was the thing you just finished — which reads as the button breaking the
  page rather than completing it. `onChange`, not a check in `body`, or the `unseenOnly:
  false` route (a brand's whole history, allowed to be empty) would refuse to open.
- **The watch bell fills; it does not carry a number.** A badge is the platform's unread
  mark — something happened, deal with it, and it clears when you do. A watch count is none
  of those: it is the number of watches you deliberately set, and it comes down only when a
  restock lands, so it nags hardest exactly when the thing you are waiting for is slowest.
  A watch that fires arrives as a push and as a card in the feed, which is where news goes.
- **A saved thing is still a product.** `SaveDetailView` shows the size run, the colourways and a
  watch, not just a note field. The page had been read too literally as "what did I think" and
  dropped everything the item *is* — but the commonest reason to keep something you can't have is
  that it was sold out, and "tell me when it's back" is the one thing here a screenshot can't do.
  `ColorwaySection` and `WatchSection` are shared with `ProductDetailView` rather than restyled —
  as is `StorefrontBar`, which is *pinned* on both. On the archive it had been a small text link
  below two rows of chips, which put the page's most consequential control at the bottom of a
  scroll. Anything laid over the bottom of either page must clear it: `StorefrontBar.height` is
  what `SaveConfirmation.bottomClearance` is set to.
- **That page is in two halves and says so.** Above the rule is the garment, and it is the same
  garment anybody else would see; below it is only yours — the note, the size you own, the board,
  why you kept it. Before the `Yours` masthead they were one undifferentiated column at one
  rhythm, which is what made an archive page read as a form. The masthead carries a generous top
  margin on purpose: the watch section ends in a rule of its own, and two hairlines a few points
  apart read as a printing error rather than as a division.
- **The archive says what a catalogue cannot: what you have worn it with.** `SavedItem.fits` was
  already recorded and nothing read it, so a fit could be built out of an item and the item's own
  page would never mention it.
- **A board is made from wherever you needed one.** Both `SaveDetailView` and `FitCanvas` create
  boards inline, because that is how a board actually comes about — you find the second thing that
  belongs with the first. `FitCanvas`'s board menu in particular used to be behind
  `if !boards.isEmpty`, so somebody who had never made a board was shown no way to file anything
  and no hint that filing was possible; a menu that hides the thing you would open it for is worse
  than no menu. Filing a fit is also on the `StyleView` card's context menu, since that is where
  fits are looked at — the editor is where they are made.

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

**`@State` belongs to the position, not to the thing.** A card in a `LazyVStack` is a view
*description*; SwiftUI keeps the instance and its state when the description at that position
changes. So paging to the seventh photograph of a jacket and then marking the brand read — which
removes that card and pulls the next up — left `ImageGallery.localIndex` at 7, and the shirt that
arrived opened on its seventh frame. Worse when the next product has fewer photographs: the
`TabView` has no page with that tag and draws nothing, which reads as a failed image. It resets on
`urls` (the set of photographs *is* the identity of what is being paged) and clamps on read,
because `onChange` runs after the body that first sees the new set.

**A `DragGesture` on the content of a paging `TabView` starves the pager, even when it does
nothing.** `ImageViewer` attached one as a `simultaneousGesture` and checked the zoom scale inside
its handlers, which reads as the same thing and is not: the recogniser had already taken the drag
before deciding to ignore it. The full-screen viewer — the one place in the app where paging is the
entire point — could not be swiped at all, and the "1/8" in the corner named seven photographs with
no way to reach them. A gesture that is not attached cannot compete, so it is attached only while
`live > 1.01`.

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

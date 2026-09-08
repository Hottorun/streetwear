# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

**Dropwall** is an iOS app (SwiftUI + SwiftData, iOS 18.0 deployment target) that watches
streetwear brands for new drops, restocks and collections, and builds a style profile from what
you save. Bundle ID `com.kern.functional.streetw`, signed by team `JD6NETLE45` (KERN AG).

**The app is called Dropwall; everything underneath is still called `streetw`, and that is
deliberate.** The name was chosen just before the first submission, by which point the identifiers
were load-bearing: the bundle ID is permanent once a build reaches App Store Connect, the App Group
is the only channel between the app and its share extension, `StreetwCore` is a SwiftPM package
whose identity comes from the checkout directory name, and `APNS_TOPIC` on the server has to equal
the bundle ID exactly. Renaming any of those buys nothing a user can see and costs a re-verification
of the entire push chain. So:

| Says Dropwall | Stays `streetw` |
|---|---|
| App Store name, `CFBundleDisplayName` (app + extension) | Bundle IDs, App Group, BGTask id, logger subsystem |
| Every user-facing string, the privacy policy, review notes | `StreetwCore`, `StreetwAPI`, `streetwApp`, the scheme, the repo |
| `PushGrouping.threadID` | `app.streetw.hottorun.com`, `streetw-Info.plist` |

When renaming anything, remember **`streetwear` contains `streetw`** — match on a word boundary or
you will rename the product category the app is about.

The repo holds **three things** — a shared library, an iOS app, and a server:

```
Package.swift            StreetwCore library + tests
Sources/StreetwCore/     adapters, sizing, discovery — no SwiftData/SwiftUI/UIKit
Tests/StreetwCoreTests/  swift-testing, fixture-driven, no network
streetw/                 the iOS app (Models/, Views/, Sync/)
Shared/                  in BOTH app and extension targets — the App Group inbox contract
ShareExtension/          share-sheet extension target
streetw.xcodeproj        app + ShareExtension targets; links StreetwCore as a local package
Tools/AppIcon/           renders the app icon — the PNGs in the catalogue are generated
Server/                  SEPARATE SwiftPM package: Vapor + Fluent poller and API
docs/                    the long-form rules for one area each — see below
```

`Server/` is deliberately its own package depending on the root by path. If Vapor were a
root dependency, opening the iOS app in Xcode would resolve and build the whole server
tree. Run `swift build`/`swift test` from `Server/` for it, from the root for the library,
and `xcodebuild` for the app. `Server/README.md` covers running it; `BACKEND.md` covers why
it exists.

### The docs set

This file is the part that applies to any change: how to build, the invariants, the traps. The
deep rules for one area each live in `docs/`, and the section below on each names the files that
oblige you to read it. **Read the doc before changing code in its area** — every rule in them names
the failure that bought it, and most look like arbitrary complications until you know what they
cost.

| Doc | Covers |
|---|---|
| `docs/design-decisions.md` | The feed, the tabs, browsing filters, counts, ordering, baselines, events, push |
| `docs/discover.md` | The Discover deck, its supply, ranking, presentation and card |
| `docs/fits.md` | The fit canvas, the studio, suggestions, and judging a whole outfit |
| `docs/collection.md` | Saves, boards, the archive page, and everything the photograph is asked |
| `docs/server.md` | The poller, the schema, migrations, retention, `Notifier` |
| `docs/performance.md` | Every rule written after measuring — queries, bodies, decoding, sorts |
| `docs/share-extension.md` | The App Group inbox, enrichment, brand attribution |
| `docs/drop-calendar.md` | `PlannedDrop`, local reminders, and poll hints |
| `docs/recommendations.md` | `BrandVector`, similarity, popularity, dismissals |
| `docs/ucp.md` | Reading a storefront that has closed its catalogue |

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

**The deployment target is 18.0, and the whole installed simulator set can run it.** It was 26.5
— every device on the current point release and nothing else — until `d476131` lowered it, because
nothing asked for the higher floor: there is not one `#available` or `@available` in the project and
it compiles clean at 18.0. Verified by running on iOS 18.5 as well as 26.5. Don't raise it back
without an API that needs it, and if you do, add the availability guards rather than moving the
floor for everyone. List what's installed with:

```bash
xcrun simctl list devices available | grep -E '^--|iPhone'
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
DEVICE=<udid-of-any-iOS-18.0-or-newer-simulator>

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
| `-startTab style` | Opens straight to a tab, so screenshots need no UI automation. One of `feed`, `discover`, `saved`, `style` — anything else (including the retired `brands`) resolves to the feed via `Tabs.resolve` rather than drawing a blank page |
| `-standalone YES` | Runs with no server, so `SyncEngine` polls from the phone |
| `-seedSaves 8` | Files garments into the wardrobe, spread across `GarmentSlot.essential`. Independent of `-seedBrands`: it reads whatever brands the store holds, so in server mode it runs after the launch sync rather than at launch |

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

### The app icon is generated, not drawn

The three 1024² PNGs in `AppIcon.appiconset` (light, dark, tinted) come out of
`Tools/AppIcon/RenderIcon.swift`; see the README beside it for how to run it and what the mark
means. Kept as code because the icon uses the app's own palette and typeface, and a hand-exported
PNG drifts from those the first time one changes — silently, on the one surface nobody looks at
twice. It is deliberately pure CoreGraphics/CoreText: importing AppKit needs an `NSApplication`
and traps when run headless, which is how it is run.

Verify an icon change the way every other Info.plist change is verified — by reading the built
bundle, not by trusting the catalogue:

```bash
plutil -p /tmp/streetw-dd/Build/Products/Debug-iphonesimulator/streetw.app/Info.plist | grep -A4 CFBundleIcons
```

### Tests

```bash
swift test                                    # all 394
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

**…and `/meta.json` is typed in by a human, so it is tidied where it is read.** Stüssy publishes
`" Stüssy"` — a literal leading space — and Represent publishes `"REPRESENT | US"`. `BrandNaming`
exists for exactly that, and **three call sites read `FetchResult.shopName` while two of them
bypassed it**, independently and in the same way: `BrandDiscovery` hands the value to
`BrandNaming.pick` and gets a clean name, while `SyncEngine` and the server's `Poller` both assign
it straight onto `brand.name`. The space went into the global catalogue and out to everyone, and a
wordmark with a leading space is a visible indent against every neighbour. It is cleaned in
`ShopifySource.shopInfo` now — where the field is produced, so a fourth caller cannot repeat it —
and `pick` re-applying the same rules is harmless because they are idempotent.
`RemoteSync.displayName` trims on the way in as the repair for rows already written, and for the
one name a human can set by hand (`POST /admin/brands/:id/name`); **whitespace only there**, since
re-running `withoutTail` would silently truncate a deliberate override at its first pipe.

**The catalog is not always on the host that was typed.** A storefront moved to Hydrogen
answers on the apex and 404s `/products.json`, while the classic Shopify origin still
serves the full catalog on `www.` — Palace does exactly this, and probing one host demoted
a storefront with titles, prices, images and stock all the way to a sitemap.
`ShopifySource.resolve` tries both and returns whichever answered, and that is the URL the
sources are pinned to. It swaps **only** `www.`: every other subdomain a brand runs
(`usa.`, `eu.`) is a region with its own currency, and switching someone off one would
change every price in their feed.

### Reading a storefront that has closed its catalogue

Supreme is a Shopify store with every machine-readable surface switched off — every adapter
declines and a page watch hashes a page whose products are drawn by JavaScript, so the hash never
moves. Its robots.txt points at UCP/MCP instead, and `UCPSource` walks through that door.

**Read `docs/ucp.md` before touching `UCPSource`, `UCPAgent` or `/admin/ucp-test`.** It covers why
the source is read-only by construction, why the agent profile must be served from the server (a
phone cannot host one), the 422-body-before-status rule, minor-unit prices, `available: false`, and
what was measured against real catalogues.

### Deliberate design decisions

**Read `docs/design-decisions.md` before changing the feed, the tabs, the brand rail, any browsing
filter, any unread count, collections, ordering, baselines, price/restock events, or push.**
Changing these silently breaks intended behaviour, and each rule there names the failure that
bought it. The short form of the load-bearing ones:

- Instagram is never scraped — a stored deep link only.
- The feed's unit is the **event**, not the product; only a sudden kind earns the lead photograph,
  and `UpdateKind.isSudden` **is** `Notifier.isWorthWaking`.
- Every count on a spread opens the list it counts, and every visible count is subject to the same
  filter as that list (`Brand.unseenCount(matching:)`, `BrandUpdate.passes`).
- Brands is not a tab; the alphabetical brand rail at the head of `FeedView` replaced it.
- There is no refresh button — `scenePhase == .active` and pull-to-refresh, on two very different
  throttles (60s server, 20min standalone).
- A brand's first sync is a baseline, and only a sync that reached something may spend it.
- Ordering: brands by `lastActivityAt` (stored, never by newest *unread*); a brand's output by
  `BrandUpdate.newestFirst`; one garment one row via `oncePerProduct`.
- Only a price *drop* past 5% is an event; restock outranks it; a lock fires on the transition.
- Push: one per brand per **cooldown**, `aps-environment` is load-bearing, one `threadID` for the
  whole app.

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
  own pile on the lock screen instead of one stack that says "Dropwall". Grouping is the thread id;
  stopping a single brand from shouting is `collapseID`, which stays per brand. They are different
  knobs and were being confused for each other. **The value lives in `PushGrouping.threadID` in
  `StreetwCore`**, because three targets raise alerts — the server's APNs sender, `DropReminders`
  and `WatchNotifier` — and nothing makes it visible when they stop agreeing. `WatchNotifier`
  threaded by brand id for a long time while its comment claimed it matched the server, which it
  never had: a restock announced by push stacked under the app, and the *same* restock announced
  locally started a pile of that brand's own.
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

### Dates you know and the app cannot

The drop calendar is the one screen about the future. `PlannedDrop` is a hand-entered date — the
fourth kind of claim, labelled "ADDED BY YOU", never blended with one a storefront stated — and it
is **local only**, like `StyleStatement`. Two alerts (09:00 and the release), `DropReminders.refresh`
rewrites the whole set rather than diffing it, and clears only its own `drop-` prefixed requests.

The one thing that leaves the phone is a **poll hint**: one brand id and one instant, which only
makes the poller look sooner. **Read `docs/drop-calendar.md` before touching `DropHints`,
`PollHintPolicy`, `DropReminders` or `PUT /v1/poll-hints`** — it covers the two independent bounds
(what an account may ask for vs `Poller.hintBudget`), why an oversized set is refused whole, and the
four states `DropCalendarView.watchLine` prints.

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

`BrandVector`'s unit of work is the **whole catalog** — IDF and price percentile are defined
relative to every other brand, so vectors cannot be built one brand at a time. Price is compared as
a rank, never an amount. The **taste vector is computed on the phone** and saves never leave the
device; `BrandDismissal` is the only negative signal and is local for a stronger reason.

**Read `docs/recommendations.md` before touching `BrandVector`, `BrandSimilarity`, `Recommender`,
`Popularity` or `BrandRecommendations`** — it covers the weighted-mean scoring, why a headcount has
to earn its weight, per-brand photograph budgeting in SQL, `Trait` gating what may be *printed*, and
how `StyleStatement` blends in.

### Discover

A full-bleed vertical scroll of garments, mostly from brands you **don't** follow, arguing the one
thing only an archive can: *this goes with clothes you already own*. Supplied by `GET /v1/discover`
(paged by depth through every unfollowed catalogue) plus `FollowedSupply` for what is unread from
brands you do follow. `/v1/brands/popular` could not have been the supply — its candidates come from
the follows table.

**Read `docs/discover.md` before touching `DiscoverDeck`, `DiscoverCardView`, `DiscoveryAnalysis`,
`Discovery.swift`, `DiscoverProductSheet` or `/v1/discover`.** It is the longest set of rules in the
project and every one names what it fixed. The ones most easily broken by accident:

- A discovery card is **never persisted with `isSeen == false`** — `FeedView` queries `!isSeen`, so a
  stored page would empty thousands of products into the unread feed. Only a save writes a row.
- The ranking must not move the card being read (`DiscoverDeck.pinningRead`), and there is **no RNG**.
- Diversity is a property of the query shape, not of tuning; the offset advances by
  `discoverPerBrand`, never by the fetch window.
- Three voices (`DeckPresentation`), decided by what the app can back up — never a rotation.
- The card is a column on one fixed sweep-to-ink ground; nothing but the wordmark is laid over the
  photograph; the pager is a `ScrollView`, and the double-tap save goes *inside* it.

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

`Shared/` is compiled into **both** targets and `SharedInbox` is the contract between them. The
extension does no networking and touches no SwiftData: it writes one JSON file into the App Group
container and returns. The app enriches on the next foreground (`SharedSaveImporter`), preferring
the catalogue (`/products/<handle>.js`, which has `available`) over Open Graph.

**Read `docs/share-extension.md` before touching `SharedInbox`, `SharedSaveImporter`, the App Group,
or anything about entitlements.** Notably: adding the App Group silently moved the SwiftData store,
so `streetwApp` pins the store URL explicitly — don't remove that. Also covered: one file per save
with reading separate from deleting, `enrichmentVersion` giving a bad landing another chance,
`registrableDomain` matching a brand across its hostnames, `brandLabel` when there is no brand, and
why the sold-out prompt is asked by the app rather than the extension.

### SwiftData specifics

- **A `#Predicate` over a stored `[String]` cannot be compiled to SQL, and the failure is a
  crash.** `FitCandidates` fetched with `#Predicate { !$0.imageURLStrings.isEmpty }`, which looks
  like every other narrowing in the app and is not one: an array *attribute* is a blob, and
  CoreData throws `NSInvalidArgumentException` out of `NSSQLGenerator` rather than returning
  nothing. A *relationship* is different — `!$0.saves.isEmpty` compiles to a count, which is why
  `SharedSaveImporter` gets away with the same shape. It stayed hidden because that function
  returns early unless an essential slot is completely empty, so it fired the day somebody's
  wardrobe lost a slot, on the Style tab, with nothing on screen connecting the two. Narrow on
  the fetch limit and filter arrays in Swift.
- **Reading any property of a deleted `@Model` traps**, and the delete is usually on the very
  card that draws it: `context.delete` invalidates the query, SwiftUI re-renders, and a
  `LazyHStack` tears its rows down on its own schedule — so `FitCanvasSurface` reached
  `fit.placements` one pass later and took the app down with `_assertionFailure`. `Fit.isGone`
  asks `isDeleted` **and** `modelContext == nil` (a model whose context has gone answers false
  to the first and still traps), every accessor a card draws answers emptily for it, and
  `FitCard` skips such a row entirely.
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
- The schema is `Brand`, `BrandUpdate`, `SavedItem`, `Board`, `StockWatch`, `Fit`,
  `BrandDismissal`, `PlannedDrop`. A new `@Model` that isn't listed in `streetwApp.init` simply
  doesn't exist at runtime.
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

### Who may call what

Three tiers, and the middle one is the part that was wrong for a long time.

- **Public**: `GET /health` and `GET /.well-known/ucp`. The first must stay cheap and must
  not fail the deploy when the database blinks; the second has to be fetchable by a merchant
  before it will answer a catalogue query, and is a fixed statement about the software naming
  no device, user or brand.
- **Device token** — everything under `/v1` except registration.
- **`ADMIN_TOKEN`** — everything under `/admin`, including `/status`.

- **`grouped(DeviceAuthenticator())` does not require a device.** It only *offers* to find
  one, so every route under it was protected purely because its handler happened to call
  `authenticatedDevice()`. The three that did not — catalogue search, site probe, brand
  discovery — were wide open, and discovery makes the server fetch a URL a stranger chose and
  write a row into a catalogue everybody shares. `RequireDevice` now sits in the group, so
  membership *is* the guarantee it looks like and a new route cannot be accidentally public
  by forgetting a line inside its body.
- **A missing `ADMIN_TOKEN` refuses rather than allows.** `/admin/poll` makes the server
  fetch fifty storefronts, `/admin/push-test` wakes every phone holding a token, and
  `delete?force=true` removes a brand and cascades away every follow on it. "Open when unset
  so nothing breaks" is a lock that stays unlocked until somebody remembers, on a deployment
  where forgetting is silent. Compared with `constantTimeEquals`, because `==` on a secret
  leaks its length and prefix to anyone willing to time the responses.
- **The key is read once, where the group is built** — not per request. Partly cost, mostly
  testability: `AdminAuthenticator.decide` is a pure function, because mutating the
  environment while a parallel suite reads it is a race rather than a test.
- **`/status` is a diagnostic, not a health check.** It counts users and devices and prints
  the database error verbatim. `GET /v1/devices/me/delivery` is what the app needs instead —
  two booleans about *the caller*, which is also the better question: a global
  `devicesWithToken > 0` is satisfied by somebody else's phone while yours has no token.
- **Nobody may name a brand.** `DiscoverBrand.name` is ignored. The catalogue is global, so
  whatever the first person to add a shop typed became its name for everybody who followed
  it — no review step and no second person to correct it, which makes a typo permanent and
  anything worse a vandalism vector costing one request. The name comes from the storefront's
  own `/meta.json`, `og:site_name` or `<title>`, and `usesGeneratedName` stays true so the
  first poll can still improve it. `POST /admin/brands/:id/name` is the one trusted override,
  for the shop whose own metadata is wrong ("Official Carhartt WIP Store UK").
  **The add-brand screen shows the name rather than asking for it** — a text field that
  quietly does nothing is worse than no field.
- **A page watch is a real source, and "something changed" is worth having.** This was
  briefly refused as too thin to justify a brand row, on the theory that a JavaScript-rendered
  storefront never moves its hash. That is false, and Supreme disproves it: a page watch there
  fired on a real drop and reached its follower **before the brand's own email**. Being early
  is the entire product. It is also the only source from which `StorefrontLock` is detected —
  a password wall is what becomes "a drop looks imminent", the strongest signal in the app.
  What discovery refuses is narrower and honest: a site where *nothing answered at all*, page
  included. Everything else is verified before it is trusted — a sitemap must yield an item,
  a UCP endpoint must answer — and the page watch was the one that was assumed.

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
| poll hints from the drop calendar | `PUT /v1/poll-hints` (whole set; no-op standalone) |
| recommendations | `GET /v1/brands/popular` |
| the Discover feed | `GET /v1/discover` (no standalone equivalent — the phone only holds brands somebody already followed, which is the opposite of the question) |

Two operations deliberately **do not** have a server half, and both fetch from the phone in
either mode. `StockRefresh` re-reads one product's stock on the page where somebody is
deciding whether to buy it. `SharedSaveImporter` enriches a shared link — an arbitrary URL
from any storefront, any blog, any resale listing, which the server's catalogue has nothing
to look up — through `ShopifySource.product(at:)` and one `SiteIdentityProbe.discover` per
host per `siteIdentityVersion`. Both go through the same adapters and the same politeness as
everything else the phone fetches, and both say so in their own file headers. A route would
be the better answer the day either needs to happen in bulk.

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

**A token the server no longer recognises is worse than no token, and it used to be permanent.**
`ensureRegistered` registered only when `settings.token == nil`, so an install holding a
credential the server had forgotten — a device row pruned, a database restored, a deployment
moved — sent it forever, was refused by every authenticated route, and never asked for another.
Every server-backed feature then reads as *empty rather than broken*: no feed, no
recommendations, watches that silently never arrive, and a Discover tab saying "you've seen
everything". Reproduced exactly that way on a fresh simulator install, which
is the only reason it was findable. A 401 on the sizes push — the first authenticated call every
launch makes — now spends the token and registers again, **once**: a second refusal is not a
credential problem, and retrying would mint a device row per launch.

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

**The catalog is global** — brands, sources, products and variants are one row per real-world thing;
only users, devices, follows, size profiles, watches and poll hints are personal. Never add a
`user_id` to a catalog table.

**Read `docs/server.md` before touching the poller, the schema, migrations or `Notifier`.** The
traps that cost the most: a `[String]` column must be `TEXT[]` on Postgres and **cannot reproduce on
SQLite**; a failed poll must still advance `next_check_at`; the poll claim is a lease
(`FOR UPDATE SKIP LOCKED`); `UserModel.sizeProfile` is three discrete columns, so a new
`SizeProfile` field is silently dropped without a migration; retention prunes events before
products; `Poller.refresh` guards every write, because rewrites — not rows — are what fill the
volume; and only the *unexpected* is worth a buzz (`Notifier.isWorthWaking`), one push per brand per
**cooldown**.

### The collection

The saved wall, the archive page, and everything the photograph is asked. `SaveConfirmation`
completes a save unconditionally and then *offers* to amend it — filing is never a question asked
before the save. Boards are **filters, not folders** (`.nullify`, never cascade). The wall never
crops and does not invert: `Color.sweep` is the one fixed colour in the app, because photographs
don't invert either.

**Read `docs/collection.md` before touching `SavedView`, `SaveDetailView`, `SaveConfirmation`,
`ImageTagger`, `Cutout`, `Seamless`, `Silhouette`, `VisualReading`, `ProductShot`, `ColorNamer` or
`StyleView`.** The rules most easily broken: only saved items get image analysis and the pass
**drains** its backlog; a photograph that did not answer is not one that never will (`.gone` vs
`.unavailable`); the first photograph is not necessarily a photograph of the product; a lift is
verified before it is believed; bumping `Cutout.version` means bumping `VisualReading.version` with
it; and a facet is a query whose `matches` must mirror how `StyleProfile.build` counted.

### Fits

An outfit is not a schema. `FitCanvas` is free position, scale and rotation with **no snapping**;
slots did not die, they stopped being the interface (`GarmentSlot` still filters the tray and drives
`FitSuggestions`). `Outfit` judges the whole thing — always on the **worst** pairwise verdict, never
the average — because the rules people use looking at a finished fit are invisible from any pair
inside it. Cutouts are what the screen depends on, and Vision does not run in the Simulator, so the
canvas genuinely looks worse there.

**Read `docs/fits.md` before touching `FitCanvas`, `FitPlacement`, `FitRender`, `FitStudio`,
`FitSuggestions`, `FitArrangement`, `FitBackground`, `Outfit` or `Pairing`.** Load-bearing and easy
to undo by accident: placements are **normalised, never points**; the ground belongs to the fit and
is **fixed**, or a render bakes in whichever appearance the phone was in; `FitRender.warm` before
`write`, always, at the same width; a piece's size is its **frame**, not a `scaleEffect`; a position
on the body is not a `GarmentSlot` (a fit can hold two tops); one arrangement table is read by
everything that lays a fit out by machine; and every rule falls **silent** rather than scoring down
when it has nothing to read.

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

### Keeping it fast

Every rule here was measured, is cheap to break by accident, and expensive to find again.
**Read `docs/performance.md` before adding a `@Query`, a computed property in a view body, or
anything called per variant, per row or per pixel.** The headlines:

- **Derive once per `body`, and pass it down** — a computed property in a SwiftUI view has no
  memory. Five screens were doing this at once.
- **…and for the expensive ones, once per *change***, behind a cheap fingerprint
  (`StyleView.ReadingMemo`).
- **A `@Query` with no predicate subscribes the view to the whole table.** Narrow it, cap it, or ask
  a `FetchDescriptor` once in a `.task`.
- **Walking a to-many relationship faults the whole thing in.** Ask the *store* the narrow question.
- **Nothing decodes an image on the main thread** — `UIImage(data:)` does not decode. Caches are
  budgeted in bytes, never in count.
- **A comparison sort reads its keys n·log n times, and a SwiftData property is not a stored
  property** — decorate, sort, map back.
- Guard a write that changes nothing: `context.save()` invalidates every `@Query` in the app.
- Verify on a real store by driving the app; poll SQLite to time an interaction.

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

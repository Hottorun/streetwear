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
- [x] **Drop calendar.** Built without inventing data, which is the whole difficulty:
      nobody publishes a machine-readable release calendar, and the ones that exist are
      hand-edited by people. So it shows three clearly-labelled kinds of claim — a
      **locked** storefront (observed, and the strongest signal there is), a **scheduled**
      product whose publication date is in the future (the brand's own date), and an
      **expected** drop derived from the brand's own history. `DropCadence` reads the
      modal weekday and hour out of hundreds of publication timestamps, counting a *day*
      rather than a product so one 60-item collection can't decide the answer, and stays
      silent below 6 drops or 40% confidence. Reported as a pattern with its sample size,
      never as a promise. No `releaseDate` field was needed — `publishedAt` in the future
      already is one.
- [x] **Share Extension.** A new target plus an App Group inbox: the extension writes a
      link and returns immediately, the app enriches it from the page's own Open Graph
      and files it into the collection. Links from anywhere now become cards, which is
      what makes this an archive rather than a feed reader. Two traps worth remembering,
      both in CLAUDE.md: reading and deleting the inbox must be separate steps or a
      hanging fetch loses the save, and adding the App Group silently relocated the
      SwiftData store into the shared container — which looks exactly like the database
      being wiped.
- [x] **Onboarding starter pack.** Ten brands with a line each on *why* they're worth
      watching, running the same discovery the add-brand flow runs. Replaces an empty
      state that told you to paste a website while assuming you knew which website.
- [x] **Search across saves.** Across title, brand, type, tags, note and host — so a
      thing shared from kith.com is findable as "kith" before that brand is even
      followed. Filtered in memory rather than as a `#Predicate`, because the fields
      worth searching live across a relationship and in arrays.
- [ ] Widget + Live Activity for countdowns
- [x] **Announced release times, where a page actually states one.** The obvious approach
      — hunt for a countdown — does not work: on the storefronts that use them the target
      lives in JavaScript, and the ISO timestamps that *are* in the markup are blog dates,
      asset versions and analytics beacons. Verified against a live locked Corteiz page,
      which contains the word "countdown" and four unrelated timestamps and no labelled
      start time. So `DropDateParser` reads only *labelled* dates — `<time datetime>`,
      schema.org `availabilityStarts`/`releaseDate`/`startDate`, and release-named `<meta>`
      tags — and returns nil otherwise. A drop calendar that lies about times is worse
      than one that stays quiet. A locked storefront that also names a time is now the
      strongest entry the calendar can hold: observed *and* exact.

## Phase 4 — the collection, properly ✅

- [x] **Split `UpdateCard`.** Done early, because the restyle forced the issue: `FeedLead`
      and `FeedTile` carry time, price, stock and the accent, while `CollectionTile`
      carries none of it. The hype/calm distinction is now a data boundary rather than a
      visual one, exactly as this list predicted one shared card would fail to be.
- [x] **Masonry, image-first grid.** Saved is a staggered two-column wall — hand-split
      into columns rather than a `LazyVGrid`, which forces every row to its tallest cell
      and flattens a wall back into a table. Still driven by a deterministic hash of the
      item id rather than by real image dimensions; deterministic on purpose, because a
      collection that reflows while you look at it is the opposite of calm.
- [x] **Boards, private by default.** `isPrivate` is on the model from the first row
      rather than implied by there being no sharing yet — so privacy is a property of the
      data, not something retrofitted the day sharing arrives and defaults the wrong way.
      Deliberately orthogonal to Inspiration/Wardrobe: that answers "do I own this", a
      board answers "what does this belong with", and an item can be both. Boards are
      therefore a *filter*, never a folder, which is also why deleting one nullifies
      rather than cascades — losing an archive because a grouping was tidied away is the
      worst thing this app could do.
- [x] **Quick-save gesture.** Swipe right to keep, left to file on the first board, with
      the destination named under your thumb as you drag. The point is that it replaces a
      *decision*, not a tap: a sheet asking "which board?" turns an impulse into admin.
      Hand-rolled rather than `.swipeActions`, which belong to `List` — the feed is a
      `ScrollView` of photographs, and moving the card under the finger is what makes
      direction feel like a choice.
- [x] **Notes and size annotations.** A catalogue knows what a garment costs; it cannot
      know you bought the L because the M ran short, or that you're waiting on a 9.5.
      Size is free text on purpose — brands run their own scales and "44" must be as
      storable as "M". The size shows on the wall; the note stays on the item's own page,
      because the collection is meant to be looked at rather than read.
- [x] **Auto-tagging via Vision.** Dominant colour off the photograph plus categories from
      Vision's on-device classifier, preferred over the text vocabulary, which stays as
      the fallback for anything not yet analysed. The text approach was guessing: a brand
      calling a shoe "Triple White" is naming a colourway, "Nocturne" describes nothing,
      and a shared-in link may have a two-word title and no tags. Verified against real
      Kith and BBC shots — a Velour Soccer Jersey reads **Burgundy** from its picture,
      which no title-parsing would ever have found.
      Two things learned the hard way and written into the code: the seamless sweep is
      70–85% of a product shot, so the vote had to be **centre-cropped** or every item
      came back "White" including a black Air Jordan; and tightening the backdrop
      threshold to exclude the grey sweep also ate the near-white pixels of genuinely
      white garments, leaving only their shadows to vote "Grey" — measured, reverted, and
      documented at the threshold.
      Only *saved* items are analysed; running this over a 250-item catalogue sweep would
      burn battery describing things nobody kept.

## Known gaps not yet scheduled

### Closed

- [x] **Real image dimensions for the collection wall.** `ImageTagger` already decodes
      each saved image, so the aspect comes free; the wall lays tiles out at the shape of
      the actual photograph and falls back to the deterministic guess until measured.
      Clamped both ways, because one panoramic shot would otherwise blow a column out.
- [x] **Price drops** (was "`updated_at` for silent product edits"). Most silent edits are
      noise; a markdown is the exception, and it is invisible in `published_at` because
      that doesn't change. `FetchedItem` now carries a numeric `priceAmount` — display
      text like "€180" cannot be compared — and `PriceChange` requires a 5% fall before it
      counts, which clears the exchange-rate drift multi-currency storefronts recompute
      several times a day. Only *drops* exist as a case: a brand raising a price is not
      something anyone wants pushed to their phone. A restock outranks a markdown, so one
      product never writes two events for one poll. Both client and server detect it.
- [x] **Shopify `/collections.json`.** A 60-piece release arrives through the product
      endpoint as 60 unrelated rows; through this one it is a single named event, which is
      what brands actually announce. Built as its own source kind rather than a second
      request inside `ShopifySource`, because one source = one URL = its own ETag, failure
      count and place in the poll queue. Structural collections ("all", "frontpage") and
      empty ones are skipped — the first are navigation, the second are pages a
      merchandiser made but hasn't filled. Verified against the live Kith endpoint, which
      caught a real bug: this endpoint calls the field `description` where
      `/products.json` calls it `body_html`, and decoding the wrong key loses every
      summary silently.
- [x] **Sitemap-based discovery for non-Shopify brands.** Previously those fell straight
      to a page watch, which can only say "something on this page changed" and fires as
      loudly for a swapped banner as for a release. A sitemap is a brand-maintained list
      of every product URL with a `<lastmod>` on each, so `since` filtering works exactly
      as it does elsewhere and no extra state is needed — dedupe is already handled
      upstream by `externalID`. Follows a sitemap index to its product children only,
      capped, and refuses entries with no `lastmod` rather than assuming "now", which
      would resurface the whole catalogue every poll. It cannot supply a price or a
      photograph; titles come from the slug.

### Still open

- Enriching sitemap-discovered products through `PageMetadataParser`, so those cards get a
  title and photograph instead of a slug. One fetch per new product, so it belongs behind
  the politeness budget rather than inside the adapter.
- Vision's image classifier cannot initialise in the Simulator ("Failed to create espresso
  context"), so categories only populate on a real device. The colour path works in both,
  and the text vocabulary covers the gap — but it means simulator screenshots understate
  what the profile knows.
- Silhouette (oversized / boxy / cropped) is still read from text only. Vision's taxonomy
  doesn't carry fit, so this would need aspect-ratio heuristics or a trained model.

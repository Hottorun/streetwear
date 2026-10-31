# Server specifics

Part of the streetw guidance set; see `CLAUDE.md` for the index and the build rules.

## Server specifics

- **The catalog is global.** Brands, sources, products and variants are one row per
  real-world thing; only accounts, users (a profile is one), devices, follows, size profiles,
  watches and poll hints are personal. Never add a `user_id` to a catalog table — polling once for everyone is the whole
  design. (`watches` points *at* a product without owning it, exactly as `follows` points at a
  brand, and `poll_hints` at a brand's *schedule* without owning that either — a hint changes
  cadence and is never read back to anybody but the device that wrote it.)
- **`UserModel.sizeProfile` is discrete columns, not an encoded blob.** A new field on
  `SizeProfile` is therefore *not* automatically persisted: it round-trips through the accessor
  and is silently dropped on write. Adding one means a column, a migration, and a line in both
  halves of the accessor. `gender` was lost this way and only surfaced because a test asserted on
  a push that should have been filtered; the waist was lost the same way through `SizePayload`.
  `noFieldIsSilentlyDropped` now lists every `SizeProfile` field as stored or display-only and fails
  on one that is neither — the display scales (`shoeScale`, `dressScale`, `suitScale`) have no
  column on purpose, because they never change what is matched. `AddUserDressAndSuitSizes` adds
  three `TEXT[]` columns with one `update()` each, and spells the empty default per dialect: `{}` is
  Postgres's empty array, and SQLite stores JSON, where `{}` is not an array.
- **The notifier reads a size on the product's ladder** (`ProductModel.sizeContext(sizes:)`), with
  the run passed in rather than read off `$variants` — the restock path loads products without
  their variants, and that accessor traps.
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
- **The feed is read to the end, in pages that are fair between brands** (`FeedPaging`,
  `GET /v1/feed`). It answered newest first with at most 200 events and named the newest of
  them as the cursor, and the app asked once per sync — so everything older than the 200th
  event between two syncs fell behind the cursor without ever being sent. A busy brand writing
  250 restocks pushed every other brand's news out of the window, and a quiet brand's one drop
  was exactly the row that went. Found by reading the code; reproduced by
  `FeedPagingTests.nothingIsLostPastAPage` (200 of 251 delivered) before it was fixed. Five
  details are load-bearing:
  - **The order is fair**: every brand's newest event before any brand's second newest (rank
    within brand, then newest first). One busy brand can no longer fill a page while another
    has something unsent — it fills the *tail* of the read. This applies to the first page
    too, which is all the 1.0 app reads: it still gets one page and `nextCursor` is still the
    newest event in the window, but what it loses now is the deep end of the busiest brand
    rather than a quiet brand's only drop.
  - **The window is fixed when the read begins** — `(since, newest event visible now]` — and
    `continuation` carries it, opaque, until it comes back nil. An event written mid-read
    belongs to the next read.
  - **The position is a keyset, not an offset.** An unfollow between pages removes a whole
    brand's rows and an offset would slide the next brand's past the reader. The keyset only
    moves for retention deleting a brand's rows mid-read, which touches nothing younger than
    the thirty-day horizon.
  - **The ranking and the keyset compare in Swift, never in SQL**, and the upper bound is
    applied in Swift too. The bound is a timestamp read out of the database on the first
    page; binding it back is not guaranteed to keep its last microsecond, and a `<= until`
    that dropped the newest event would re-rank its whole brand by one and slide rows past
    the reader. Decoded values compared with each other are exact, because every page decodes
    the same rows the same way. Only a three-column projection of the window is loaded; the
    page alone is hydrated with products and variants.
  - **The token is JSON in base64url** rather than an ISO date, because the ISO-8601 the rest
    of the API speaks keeps whole seconds and the window's bounds must round-trip exactly.
  The client's half — a budget of five pages per sync, the head first, unfinished windows kept
  as their tokens — is `FeedPager` in `StreetwCore`; see `docs/design-decisions.md`.
- **A follow has a mode, and `Notifier` reads it** (`follows.mode`, `FollowMode`). *Everything*,
  *Sales only* or *Quiet*; the rule between them is `FollowMode.admits(_:)`, and what *Sales
  only* lets through is `UpdateKind.isSale` — one switch, so a new sale kind is one case. It
  replaced 1.0's `Brand.isMuted`, a flag on the phone consulted when a push arrived in the
  foreground, about a push this server had already composed and sent. Four details:
  - **`NOT NULL DEFAULT 'everything'`**, not nullable. Every existing row was made by somebody
    who could not choose and was getting everything, and every follow the 1.0 app makes sends
    no mode. A nullable column is also a trap: `mode != 'quiet'` is NULL for a NULL row, so
    the obvious filter would have silenced every follow older than the migration.
  - **The mode only takes away.** `isRelevant` asks `isWorthWaking` *and* `admits`, so a
    *Sales only* follow is never woken by a kind an *Everything* follow would not be — which
    means by a brand-wide `.sale` and nothing else, because a single markdown is not sudden. A
    quiet follow is dropped before its devices are loaded.
  - **A watch alert ignores every mode.** `notifyWatches` never asks: it is the one alert
    somebody asked for by name, and quieting a brand must not swallow the restock a watch was
    set for.
  - **`POST /v1/follows` only changes a mode it was sent.** Following a brand you already
    follow — from a search result, a saved item — posts again with none, and reading that as
    *Everything* would undo the brand page's choice. `PATCH /v1/follows/:brandID` is how a
    mode changes, and it refuses a brand you do not follow rather than starting to.
  The feed is **not** filtered here: every event still goes to the phone, which stores the
  ones the mode does not admit already read. A quiet brand's own page is still its catalogue,
  and a server-side filter would have frozen it at the moment it went quiet.
- **A follow can carry a filter, and `Notifier` asks it after the mode** (`follows.filter`,
  `AddFollowFilter`, `FollowFilter`; the rules are in `docs/design-decisions.md`). Four details:
  - **One nullable JSON text column, and null is *All*.** Every follow before the migration and
    every one 1.0–1.3 makes has none, which is the truth about them. Text rather than `TEXT[]` or
    discrete columns because nothing asks SQL about it — the notifier and the follow list decode
    it in Swift — and an array column is the one shape SQLite cannot reproduce. Written through
    `FollowModel.filter`, which normalises (lowercased chips, bounded words) and stores an empty
    filter as nil, so *All* has one spelling.
  - **`PATCH /v1/follows/:id` changes it only when one is sent**, beside the mode the body
    always carries; an empty one clears it. 1.3's body — a mode alone — still decodes and must
    not clear a filter another phone on the account set. `GET /v1/follows` returns it as
    `BrandDTO.followFilter`; no other route does. A profile's follows are its own rows, so its
    filter is too, and the account merge moves the row whole.
  - **Read once per follow per pass**, not per event (`FollowFilter.Matcher`): parsing the words
    is the expensive half and a drop is hundreds of events. The product's title, type, tags and
    price are what it reads, the four fields the phone holds when it stores the row; a sale has no
    product and passes. `notifyWatches` and `notifyWatchedPriceDrops` never ask it.
  - **`GET /v1/brands/:id/categories`** counts the brand's biggest categories for the follow
    dialog (`FollowCategory.biggest`): the main shop's listed products, the newest 2,500, three
    columns of each (`.field`), on the standard device budget.
- **A refused check records why** (`brand_checks.refusal`, `AddBrandCheckRefusal`,
  `BrandCheck.Refusal`, `ShopRefusal`). `BrandChecks.run` wraps the shared fetcher in a `ProbeLog`
  for the length of the check — above `PoliteFetcher`, so robots.txt, spacing and the host check
  are untouched and no request changes — and a check that finds nothing watchable is
  `blocksReaders` when every request was a bot-protection page, a dropped connection or a robots
  refusal, else `nothingAnswered`. A domain on the curated `sellsNoClothes` list is refused at
  `start` with no fetch. The push to somebody who asked to be told says which. **No retry, no
  other User-Agent, ever**: the label is the whole response (`ROADMAP.md`, *Decided*). The 1.0
  routes (`GET /v1/brands/probe`, `POST /v1/brands/discover`) are unchanged.
- **`/status` counts every table**, `users` included. It was the one table it didn't touch,
  which is exactly why a completely broken registration path still reported green.
- **Only the *unexpected* is worth a buzz** (`Notifier.isWorthWaking`). A drop, a collection, a
  storefront lock and a brand going on sale (`.sale`, added since — see
  `docs/design-decisions.md`) happen suddenly, are worth acting on within minutes, and cannot be
  found any other way. A **restock**, a **price drop**, a **page change** and a **post** are not: the first
  is the largest single source of volume and almost all of it is about a garment the reader has
  never seen; a markdown is worth as much a week later, which is what `MarkdownsView` and its
  badge are for; a page change is "something on this page is different", which fires on brands
  where nothing happened; and a post is a brand's own marketing RSS. Every one of them still
  reaches the feed, the unread counts and the markdowns list — this decides only what interrupts.
  Sending everything taught people to swipe the whole app away, which takes the one that mattered
  with it.
  **The restock somebody actually cares about still arrives instantly**, through `notifyWatches`
  — that is what a `StockWatch` is for, it runs first, claims its (user, brand) pairs, and is
  exempt from the cooldown. Note the server *cannot* do this for a merely **saved** item: saves
  never leave the phone, by design. "Notify" in `SaveConfirmation` is the path that turns a save
  into something the server can act on. **The markdown somebody cares about arrives the same
  way** (`notifyWatchedPriceDrops`): a `.priceDrop` on a product with an active watch pushes "Down
  33% to $120 — Nathan Cargo Pant" by the watch rules — no mode, no cooldown, does not spend the
  watch, one per person per product, collapsed per product so a second cut replaces the first.
  A saved item's markdown is said by the phone (`PriceAlerts`).
  **Exempt from the cooldown was only half true until sales.** Cooled-down brands are left out
  of the batch in the query, and with them the restock a watch was waiting for — so the one alert
  asked for by name waited out the brand's quarter of an hour. The watch kinds (`.restock`,
  `.priceDrop`) of a cooling brand are now loaded too and answered at once; neither is sudden, so
  stamping them takes nothing from the summary the cooldown is holding.
  Three existing tests encoded the old behaviour and were re-pointed rather than deleted, because
  the old expectations are exactly what a later change might reinstate by accident.
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
  products gone for `PRODUCT_RETENTION_DAYS` *with no events left* are eligible — for a source
  the daily scan has completed within that window, "gone" is `unlisted_at` (two complete scans
  in a row did not find it), counted from then; for everything else it is `last_seen_at`, as
  before. The scan does not stamp `last_seen_at`, so a listed product in a scanned shop must
  never be judged by it. **Nor is a product with an active watch pruned**: `watches.product_id`
  cascades, so retention used to delete the watch with it, silently — and a product only its own
  page re-reads can go unseen by any catalogue for months while being watched throughout.
- **What fills the volume is rewrites, not rows.** Postgres does not edit a row in place:
  every `UPDATE` writes a new tuple and leaves the old one dead until autovacuum reclaims
  it — and reclaimed space goes back to the *table* for reuse, not to the filesystem, so a
  volume's high-water mark only ever rises. `Poller.refresh` used to `save` every product
  and **every variant** unconditionally on every poll, so a Shopify source returning 250
  products every twenty minutes wrote ~18,000 dead product tuples a day per brand before a
  single fact about any of them had changed, plus one per variant — ten to thirty times
  that again. That is orders of magnitude more storage than the catalogue itself, and it is
  invisible in any row count. Both writes are now guarded by a comparison against what is
  already stored.
  **`last_seen_at` is the detail that made the guard possible.** Stamped with `Date()` every
  poll, it guaranteed every row differed every time, so no dirty check above it could ever
  have saved a write. Its one and only reader is `Reaper`, comparing it against a cutoff
  measured in *months* — so it is coarsened to a day, which is still three orders of
  magnitude finer than the question being asked of it. Anything new written on the poll path
  has to answer the same question: does this change often, and does anything actually read
  it at that resolution? Note that fixing the churn does not shrink an already-bloated
  volume — that needs a `VACUUM FULL` or `pg_repack` once.
- **The poll queue claim is a lease, not a select.** `FOR UPDATE SKIP LOCKED` plus
  pushing `next_check_at` forward in the same statement, before any network call — so a
  second instance can't double-fetch a storefront and a crash mid-poll costs one lease.
  Postgres only; SQLite keeps the plain query.
- **Discovery runs as a check, in a row, off the request** (`BrandChecks`, `brand_checks`). The
  discover route said nothing until `BrandDiscovery.discover` had finished — thirteen requests at
  the politeness interval for a site that is not on Shopify, 26.8s measured on subdued.com — and
  the app gives up after thirty seconds of silence, so "can't be added" was often the app timing
  out on a readable site. Four details are load-bearing. **A check is shared by domain** for
  `reuseFor`, which is what lets the add reuse the preview instead of fetching the storefront a
  second time. **It is a row, not memory**, because a deploy restarts the process: a row left
  `checking` that nothing in this process is running reads as interrupted after `orphanAfter`, and
  `resumeOrphans` re-runs it on boot when somebody is still waiting. **Slow is not interrupted**:
  the first version timed checks out at five minutes, and a storefront tarpitting the caller made
  one take twenty-four, so `running` — in memory, because it is a fact about this process — is
  what says a check is alive. **Settles of one check are chained**, because the actor is re-entrant
  at every `await` and two settles could otherwise create the same brand twice. And **a refused
  check creates nothing**, the same rule the discover route holds. The two 1.0 routes stay, using
  the same `BrandCatalog` helpers, because the build in the App Store calls them and waits.
- **A save from a shop the catalogue lacks adds the shop, for search, and follows nobody**
  (`StartBrandCheck.catalogueOnly`, `brand_checks.catalogue_only`, `AddCatalogueOnlyCheck`; the
  app's half is `CatalogueSuggestions`). Search can only recommend from shops the server reads,
  and the shops people save from without following are the ones it is missing. Rules, each one
  held by `CatalogueOnlyCheckTests`:
  **Only the domain arrives**, once per shop per install, server mode only. **Nothing about the
  requester is kept**: the device token authenticates the request as on every `/v1` route, and
  that is all it does — no watcher row is written, `brand_checks` has no column a requester could
  go in, and the route logs nothing about the caller — so the domain cannot become a record that
  this person saved from that shop. **Only a real shop is added** (`BrandChecks.addsToCatalogue`):
  a ready check with a source that reads products — Shopify, a sitemap, UCP. A page watch is
  enough to *follow* a shop and nothing to search; a refusal of any kind (`ShopRefusal`: readers
  blocked, no clothes sold, nothing answered) adds nothing; a shop the catalogue already has is
  left alone by `BrandCatalog.existing` before anything is fetched. A catalogue-only request that
  joins somebody's recent preview sets the flag on that check, and is added from its finished
  answer. The add goes through `materialize` inside the check's settle chain, so it and a follow
  of the same shop make one brand. **Its own budget**, per device, on top of the outbound one:
  ten in a burst, thirty a day (`RateLimits.catalogueOnly`), because every success is a brand the
  poller then reads for everybody. Such a brand is an ordinary unfollowed catalogue brand: the
  poll claim takes every main shop (`storefront_id IS NULL`) whether or not anybody follows it,
  and only country storefronts wait for a follower.
- **Usage counts are totals, and the only per-device fact is one overwritten day**
  (`POST /v1/usage`, `UsageLedger`, `UsagePolicy`). 1.0 promised no analytics; the roadmap
  needs to know which features are used before paying for AI ones, so this is the smallest
  step from that promise and nothing past it. No third-party SDK. The phone keeps a tally per
  UTC day per whitelisted event (`UsageEvent` — app opened, each tab, brand search, add-brand
  check, push tapped, save, fit, follow) and reports it every few minutes and on the way out.
  The server adds each tally to `usage_counts`, **one row per (day, event) shared by everybody,
  with no `user_id` or `device_id` and never one** — so there is nothing to join a person back
  onto. Five things are load-bearing:
  - **Weekly actives come from `devices.active_on`**, the UTC day the device last reported,
    overwritten. One person on five days is five daily actives and one weekly one, so a week
    cannot be summed from days; it needs *some* per-device memory, and one date is the least
    there can be. The first report of a day adds `active.day`, and the first of an ISO week adds
    `active.week` on that week's Monday. A client cannot report itself active —
    `UsagePolicy.accepted` refuses both names — so a reinstall or a buggy tally can inflate a
    tab count but not the number of people.
  - **Only the usage report stamps it.** Not the feed, not `PATCH /v1/devices/me`: a background
    refresh and a push wake both make those, and a phone in a drawer is not somebody using the
    app. The cost is that 1.0, which never reports, is invisible to it.
  - **It must not be a write amplifier.** Its own budget (`RateLimits.usage`, 10 burst / 30 an
    hour, against the app's one per five minutes), a 32KB body limit at the route, at most
    `maxEntries` rows per report (longer is refused whole), counts up to `maxCount`, days no older
    than a week. The table can only grow by about a dozen rows a day however many reports arrive.
  - **An upsert, in raw SQL, one statement per row, in one transaction.** `ON CONFLICT (day,
    event) DO UPDATE` is the same on Postgres and SQLite and is what lets two phones add to one
    row at once; Postgres refuses a multi-row upsert that touches a row twice; and the phone
    keeps what it sent until a reply, so half a report followed by a retry would double count.
  - **Never pruned.** A year is a few thousand rows of totals describing nobody, and the history
    is what they are for. `active_on` is overwritten and needs no sweep.
  `GET /admin/usage?days=` reads it back: per-day totals and daily actives, calendar-week
  actives, and devices active in the last seven days. The privacy policy names every event.
- **A sitemap product is announced from its page, not from the sitemap** (`Poller.enrich`,
  `PendingAnnouncement`, `AddProductEnrichment`). A sitemap gives a URL and at best one
  photograph, so every sitemap brand had no price, no stock and no sizes — no size run, no
  markdown, nothing to watch. `ProductPage` reads the schema.org `Product` a page publishes for
  search engines, and four details are load-bearing. **The event waits for the page**: written
  at first sight it went out as "New arrival" over a slug with no price, and the phone keeps the
  copy it was sent, so reading the page a minute later fixed the server's row and nobody's
  screen. So a new row carries `pending_announcement` and `enrich`, which runs at the end of
  every tick before the notifier, writes the event once the page is read — `announce` whatever
  the page said, `confirm` only if it showed a product, deleting the row otherwise (a
  tentative URL is a category page as often as a product). **The budget is per pass**:
  `enrichmentBudget` pages, owed announcements first, then watched products older than
  `recheckAfter`, then a baseline's unread rows, the last two behind `backfillInterval` because
  they are a table scan. **Every read is stamped** (`enriched_at`), found or not, except our own
  `hostBusy` — a dead URL must not be retried forever. **A re-read goes through `refresh`**, with
  the first read as its baseline, so a watched sitemap product's restock raises the same event a
  Shopify poll would and the watch fires on it; and `refresh` no longer lets a source that
  publishes no price or stock (a sitemap) erase the page's.
- **A sitemap source is never polled more than hourly** (`SitemapSource.minimumInterval`), drop
  window, hint and lock included. Sitemaps are regenerated on a schedule — Subdued's nightly,
  Victoria's Secret's at 02:31, Hollister's cached at the edge for a day — and Subdued's is 7.2 MB
  a read. Its memory of what it has seen lives in `sources.fingerprint` (`SitemapMemory`), which
  is only rewritten when it changed.
- **The catalogue is read at two speeds** (`CatalogueScan.swift`, `Poller.scanTick`, `ScanLoop`,
  `catalogue_scans`, `CreateCatalogueScans`). The poll is the fast half and is unchanged: it
  reads a shop's newest products every few minutes, its baseline is the newest 2,500 and it
  re-reads only the newest ~250. Everything older — exactly what goes on sale — sat at whatever
  price it had the day it fell out of that window, invisible to a markdown, a restock, a watch,
  `CatalogueSale` and search. **Once a day, every Shopify source is read to the end** of
  `/products.json` (`ShopifySource.cataloguePage`, 250 a page) and every product, variant, price,
  `compare_at_price` and stock is stored or updated. Measured live against Aimé Leon Dore on
  2026-10-26: 900 products and 4,015 variants in 4 pages, 7.9 MB of JSON, 8 seconds at the
  two-second politeness interval — so the roadmap's 5,000-product shop is 21 pages and under a
  minute of one host's budget. Load-bearing, each with what it prevents:
  - **The scan says nothing new.** It writes catalogue state, and its events come only from
    `refresh` by the poll's own rules — a size back, a markdown past 5% — and from
    `CatalogueSale`. Three rules hold that:
    - **A first scan is a baseline**, and so is one after no scan has finished for three days
      (`CatalogueScan.staleAfter`) or after the poll re-spent its baseline (a country shop back
      from a pause) — `Poller.scanIsBaseline`. On the day this shipped, every product past the
      newest 250 held months-old prices and stock, and comparing against them would have
      announced every markdown and restock since as news. Decided when a scan begins and kept
      in its row, so one scan is one or the other from its first page to its last.
    - **A product the scan meets for the first time is stored silently** — old stock the
      poll's window never reached is not a drop.
    - **…and one published within a day of the poll's last read is not stored at all**
      (`newsMargin`), nor is anything new while the poll is failing. "New" is the poll's word:
      a scan that stored a drop first would have left the poll finding it already known, and
      the drop would never have been announced. A day rather than "since the poll's last read"
      because a storefront's `/products.json` is cached at the edge and a product can appear in
      it later than its `published_at`.
    `firstScanIsSilentAndAMarkdownIsNot` scans a 5,000-product shop whose older half moved
    since the baseline and asserts no event, then a markdown on one old product and asserts
    exactly that one `.priceDrop`.
  - **An unchanged product causes no write**, which is `refresh`'s rule, and the scan also does
    not stamp `last_seen_at` (`refresh(marksSeen: false)`) — a daily stamp would be a rewrite of
    the whole catalogue a day, the exact churn `refresh` exists to stop. Measured on Postgres: a
    second scan of an unchanged 5,400-product catalogue updated **zero** product and variant rows
    (`pg_stat_user_tables`), plus one brand row and three scan-row writes; the test pins the same
    with triggers on SQLite. Retention reads `unlisted_at` for scanned shops instead.
  - **Scheduling.** One row per Shopify source in `catalogue_scans`, made by the scanner itself
    for any source without one (`enrolScans`) — five paths make sources, and a scan that relied
    on each of them remembering would be missing for whichever forgot. A source's scan falls at a
    fixed second of the UTC day taken from its id (`CatalogueScan.slot`), so a few hundred
    sources spread across the day rather than bursting at midnight, and a deploy spreads the
    first scans over the next 24 hours. The next scan is the source's slot at least twelve hours
    after the last *started*: one per slot, at most once a day, and a late start does not push
    the next a day later. Only sources the poll has baselined: a scan before the poll's first
    read would take the newest products for old ones.
  - **The lease is the poll claim's, on its own table.** `due_at` is pushed forward by
    `leaseDuration` in the statement that picks the rows, `FOR UPDATE OF catalogue_scans SKIP
    LOCKED`, so two instances never scan one source, and only the scan row is locked — the poll's
    claim locks `sources` every tick and must never skip one because a scan holds it.
    `CatalogueScanPostgresTests` runs two scanners at once against eight shops and counts eight
    pages, not sixteen. SQLite keeps a plain query.
  - **Budgeted, and resumable.** At most `pagesPerTurn` (4) pages a source per pass and
    `scansPerPass` (3) sources per pass, one pass a minute: twelve pages a minute at most, far more
    than a daily read of every catalogue needs. A source with pages left goes back in the queue
    at once, behind every scan that has waited longer, so a 30,000-product shop (120 pages) takes
    thirty turns and its share of the fetcher, never all of it. Hard cap `maxPages` (200, 50,000
    products): a scan that reaches it stops, keeps what it read, says so (`last_truncated`) and
    does not count as complete. Between turns the row holds the next page, the products seen so
    far as 32-bit digests (`ScanDigests`, ~27 KB at 5,400 products) and the sale reading, so a
    deploy mid-scan resumes on whichever instance claims it next; a scan in progress for twelve
    hours (`abandonAfter`) starts again rather than stitching a catalogue from two days. A lock
    waits an hour, `hostBusy` waits its retry, and a failure backs off from five minutes to six
    hours.
  - **It never slows the poll.** Its own loop (`ScanLoop`), not a step of `PollLoop`, with one
    page in flight at a time through the shared `PoliteFetcher` — a poll to the same host waits at
    most one politeness slot. Merges of one brand are serialised (`Poller.holdBrand`), because a
    poll and a scan comparing the same product at once would both see a size come back and both
    write the restock; held around the merge only, so a poll waits at most one page being
    written. That is per instance: the two claims keep two instances off one *source* each, not
    a poll on one instance off a scan on another.
  - **Removal is two complete scans in a row.** `/products.json` is paged by number, so a product
    removed mid-read shifts the next page up by one and a listed row goes unseen. The first miss
    sets `products.missing_since`, the second `unlisted_at`; any read that sees it again clears
    both. Only products first stored before the scan began are judged. A scan that finds more
    than half a shop missing (and more than 25 products) marks nothing and logs — a storefront
    that stopped answering past some page reads exactly like a mass delisting. Nothing is deleted:
    retention takes an unlisted product six months on, and Discover stops dealing it.
  - **`CatalogueSale` over the whole catalogue counts only what can be bought.** A complete scan
    records `brands.catalogue_share` and when; a whole catalogue carries stock kept listed after
    it sold out, whose price says nothing about a sale anyone can act on, and counted in it either
    dilutes a real sale or holds the share over the line for good. The thresholds keep their
    meaning — 30% of the buyable catalogue cut is a sale — and the first scan is a baseline. The
    two readings can disagree for weeks (old stock marked down: 40% to the scan, 5% to the poll),
    so **either may start a sale and only the poll may end one, when its read and a scan from
    the last three days are both under 10%**; letting either end what the other held would
    announce the sale again every few days. Main shop only, like the poll's.
  - **Country storefronts** are scanned exactly when they are polled — the claim applies
    `Storefronts.wanted` — and a paused one is never claimed and never fetched.
  - **`DISABLE_CATALOGUE_SCAN=true`** stops the scan and nothing else. Its cost is mostly storage,
    so on a volume near its cap it is the one background job to switch off.
  - **What it costs to store**, measured on Postgres 17 by replaying Aimé Leon Dore's real pages
    six times over with fresh ids (5,400 products, 24,090 variants — 4.5 a product, a typical
    streetwear size run): products 10.6 MB (1.66 KB a row, heap 9.5 MB, indexes 0.8 MB),
    variants 6.4 MB (129 bytes a row, heap 3.3 MB, indexes 3.0 MB), 17.0 MB of database growth.
    **About 3.2 MB per 1,000 products**: ALD's 900 is ~2.8 MB, a 5,000-product shop ~16 MB, a
    30,000-product one ~95 MB, one at the 50,000 cap ~160 MB. The scan alone reaches 5 GB only
    somewhere past 1.5 million products, before events, dead tuples and whatever search adds —
    so how near Hobby's cap it brings the volume depends on which brands are in the catalogue,
    and `databaseBytes` is where to watch it. A change is one new
    tuple per changed row: re-pricing one page of 250 products rewrote 250 product and 1,027
    variant rows (~0.5 MB of dead tuples), so a whole-catalogue sale costs about one more copy
    of that brand until autovacuum reuses it.
  - **`/admin/status` says `databaseBytes`** (`pg_database_size`, nil on SQLite), the number the
    volume cap is measured against and one no row count stands in for, beside `scansFinishedToday`,
    `scansInProgress` and `unlistedProducts`.
- **A watched product that no catalogue re-reads has its own page re-read** (`Poller.watchedRechecks`,
  inside `enrich`). A sitemap names a URL and nothing else, and a UCP search pages a bounded
  window with no order, so a watched product from either would otherwise never be priced or
  stocked again — and a huge non-Shopify retailer cannot be scanned honestly (20,000 pages at 2s
  is eleven hours a brand). So its page is read again through `ProductPage` every `recheckAfter`
  (six hours), which gives price and stock, and so a markdown and a restock by `refresh`'s rules
  — the watch fires on them as on a Shopify product. Four details:
  - **Watched, not saved.** Saves never leave the phone (`docs/collection.md`), so the server
    cannot know what is saved and must not be told; the per-item set is the watches, and "Notify"
    on a save is what makes one. Anything a later opt-in sends would join the same queue.
  - **Budgeted per host**: at most `recheckPerHost` (2) of one host's pages a pass, never-read
    first then oldest, inside the pass's `enrichmentBudget`. A host with more watched products
    than that covers in six hours is re-read less often rather than harder.
  - **A UCP product the protocol still reads is left to it** (`ucpCoverage`, two days of
    `last_seen_at`, which a page read of a UCP product does not stamp): those reads carry prices
    and live stock already, and a page printing the price slightly differently would argue with
    them every six hours. Only one that has fallen out of the search window is read by its page.
  - **A page never brings a second vocabulary of variants.** A UCP product's variants are named
    by the protocol and its page's by its JSON-LD; taking the page's would store every size twice
    and never see one come back. They are matched on size and colour onto the held ones
    (`Poller.translated`), and only a clean match is used; otherwise only the product's own price
    and stock are read, which still gives a markdown and a whole-product restock. Nor does a page
    rename a product a catalogue named.
  - **No brand-wide sale detection for these sources** — the scan's share needs the whole
    catalogue, and a handful of watched pages is not one. Their banner reads still announce a
    code sale (`SaleBanners`).
- **A brand going on sale is said once, by whichever detector sees it first** (`SaleEvents`,
  `.sale`). Both write through `SaleEvents.announce`, which refuses a second `.sale` for the brand
  inside `quietPeriod` (24h): an end-of-season sale marks the catalogue down *and* puts "SALE NOW
  ON" in the bar, minutes apart. Each detector still records what it saw, so the suppressed one
  cannot fire later. A sale event has no product; its words are `events.title`/`summary`
  (`AddSaleLedgers`), its link on the wire is the brand's site.
  - **The catalogue** (`Poller.settleSale`, `CatalogueSale`): every pass with prices counts what
    share of the products it read is a real cut — from the brand's original
    (`products.original_price_*`, `AddProductOriginalPrice`) or from the price stored before the
    pass. On at 30% and at least 12 products, off under 10% and only after three days, so a
    markdown taken in waves on a store with no compare-at is one sale and not one per wave. The
    state is `brands.sale_measured_at`/`sale_since`, **written only on a transition** — the brand
    row is read every poll and rewriting it each time is the volume problem `refresh` guards
    against — and **the first measurement is a baseline**: measured against Motel Rocks, 1,155 of
    2,748 products were already marked down, which a deploy would otherwise have announced. It is
    a share of the *read* (the newest 250 for an incremental Shopify poll), not of the stored
    catalogue, whose prices are whatever they were when last read. **The daily scan measures the
    whole buyable catalogue too** (`CatalogueSale.decideScan`, `brands.catalogue_share`), which is
    the sale on older stock the newest 250 cannot see — see *The catalogue is read at two speeds*
    below. Either may start a sale; only the poll ends one, and only while a fresh scan agrees.
  - **The announcement bar** (`SaleBanners`, `SaleBanner`, `SaleBannerLedger`): a code sale moves
    no price, so the homepage is read every 30–60 minutes per brand (fixed per brand by its id, so
    reads do not bunch), three a pass, through the shared `PoliteFetcher`. Only brands somebody
    would hear from — at least one follow that is not *Quiet* — and never a locked storefront.
    `brands.banner_check_at` is the schedule, nil until the first read, **which is a baseline**;
    it moves whatever the read did, like `next_check_at` after a failed poll (a day when robots.txt
    refuses `/`). On Postgres the due brands are claimed with `FOR UPDATE SKIP LOCKED` in a CTE
    that returns the old schedule, because two instances reading one bar would both announce it;
    SQLite keeps the plain query. The ledger (`sale_banner`, `sale_banner_seen_at`) keys on the
    offer ("30% OFF EVERYTHING · CODE BDAY30"), not the prose, and a banner briefly missing from a
    rotated bar is not forgotten for two weeks. Pattern matching only: the end date and the fine
    print wait for Phase 4.
- **The feed sends only the kinds a client can draw** (`FeedKinds`, `?kinds=` on `/v1/feed` and
  `/v1/brands/:id/feed`). 1.0 maps an unknown kind onto a product, so a request naming none gets
  `FeedKinds.legacy`, the seven 1.0 shipped with; only kinds this server knows survive the
  parameter, which bounds the filter. The filter is on the window the read pages through, and the
  kinds travel inside the continuation (`FeedContinuation.kinds`, nil in an older token, read as
  legacy) so one read is one window to its last page — the new client sends its kinds on every
  page, but a token stored across an app update must not change its window halfway.
- **An account owns users; a device reaches it through its user** (`accounts`, `users.account_id`,
  `CreateAccounts`, `Accounts`, `AccountRoutes.swift`). Sign in with Apple is optional, and 1.0
  and 1.1 never call these routes, so `account_id` is null for nearly every user and nothing may
  assume one. It is a plain index, not unique: Phase 2's profiles are one user each under one
  account. The column cascades from `accounts`, and deletion still deletes every table by hand
  in one transaction, so the promise does not rest on SQLite having foreign keys switched on.
  Eight details are load-bearing:
  - **The first sign-in adopts the device's user; a later one merges** (`Accounts.signIn`). The
    reinstall and the second phone arrive with an anonymous user of their own. The device moves
    onto the account's user, keeping its token, and the anonymous user is folded in and deleted,
    all in one transaction. Follows are a union and the account's mode wins where both have one.
    Watches are a union on (product, size, colour), compared in Swift because the unique
    constraint cannot see two NULLs as equal. Poll hints and brand-check watchers move where the
    account has none. Sizes are merged per ladder: the account's where set, else the device's,
    and a gender of `everything` counts as unset. A device already on *another* account moves
    alone; that user is the other person's data.
  - **The sign-in answers with the merged sizes, and the app adopts them** (`AccountSession.sizes`).
    Every sync pushes the phone's profile destructively, so without this a reinstall, whose
    profile is empty, would erase the sizes signing in was meant to keep.
  - **The nonce on the wire is the raw value.** The app puts `SHA256(nonce)` on the Apple request
    and Apple copies it into the token. The server hashes what it is sent and compares. Sending
    the hash would prove nothing, because the claim is printed in the token.
  - **The production verifier checks Apple's signature, then the claims**
    (`AppleIdentityTokenVerifier`, `AppleSignIn.swift`). `GET /v1/account` says
    `signInAvailable: true`. The header must say `alg: RS256` — `none`, HS256 and everything
    else are refused before any key is looked at, because the algorithm is the server's to
    choose, not the token's. The key is the one Apple's JWKS (`https://appleid.apple.com/auth/keys`)
    publishes under the header's `kid`, built with `_RSA.Signing.PublicKey(n:e:)` (2048 bits or
    refused) and checked with `.insecurePKCS1v1_5` over SHA-256 of `header.payload` exactly as
    sent. Only then does `AppleIdentityClaims.check` run (issuer, audience = the bundle id,
    expiry, nonce, subject). RSA is `_CryptoExtras` from swift-crypto, declared in
    `Server/Package.swift` alongside swift-certificates once the owner approved both; neither
    downloads anything, both were already in `Package.resolved` through Vapor. `jwt-kit` was
    not taken.
  - **The JWKS is cached and re-read on an unknown `kid` — at most once per five minutes**
    (`AppleSigningKeys`), thirty seconds after a read that failed. Apple rotates keys, so an
    unknown `kid` may be genuine; a forged token can name any `kid` too, and without the floor
    every one would make this server ask Apple again. Concurrent misses share one read, a day-old
    set is re-read on next use so a withdrawn key stops being trusted, and a re-read that fails
    keeps the set already held. A bad token is 401; Apple unreachable with no keys held is 503,
    the one refusal about the server rather than the token. Fetched through `app.client`, not
    `PoliteFetcher` — it is Apple's API, not a storefront.
  - **`SIWA_TEST_TOKENS=true` accepts unsigned tokens, outside production only.** Every claim
    check still runs. It exists so the app's DEBUG-only `-fakeAppleSignIn <subject>` can drive
    sign-in → merge → delete against a local server. On an environment named `production`,
    which is what the Docker `CMD` passes, it is ignored and logged as critical.
  - **Revocation is real and needs a key.** The client secret is an ES256 JWT
    (`AppleClientSecret`). P-256 is in the `Crypto` that Vapor already re-exports, so this needs
    no new dependency. It is read from `SIWA_KEY_ID`, `SIWA_TEAM_ID` (`JD6NETLE45`) and
    `SIWA_PRIVATE_KEY` (the `.p8`'s PEM; escaped `\n` accepted, as for `APNS_KEY_P8`). With them,
    sign-in trades the authorization code for a refresh token (`accounts.apple_refresh_token`,
    never logged and never on the wire), and `DELETE /v1/account` revokes it. Without them,
    both steps are skipped and logged as skipped. Either way the exchange runs after the merge
    commits and the revocation runs after the data is gone, so neither depends on Apple's
    uptime. Not yet encrypted at rest.
  - **Deletion takes every device on the account, the caller's included.** The app then
    registers a fresh anonymous device and re-follows the phone's own brands
    (`RemoteSync.deleteAccount`, then `didRegisterAfresh`, which is persisted so a kill between
    the two cannot strand it). The catalogue is never touched.
- **A first sign-in settles its account before it merges** (`Accounts.findOrCreate`). Two first
  sign-ins for one Apple ID both missed the lookup and both inserted, and the second hit the
  unique constraint on `apple_subject` — not an `AbortError`, so a 500. Inside the transaction
  there was no answer, because Postgres refuses every statement after an error until the
  transaction ends; outside it, the loser reads the winner's row. The merge transaction then
  takes `SELECT … FOR UPDATE` on the account row (Postgres only), so the second sign-in waits
  and merges into the first's user instead of both adopting their own — which, with profiles,
  would have left a nameless second user that looks like a profile. `SignInRaceTests`.
- **Profiles are users under the account, and `X-Profile-ID` says which one a request acts for**
  (`ActingProfile`, `ProfileRoutes.swift`, `AddUserProfiles`). Read `docs/profiles.md` before
  touching them. In short: the holder is the account's oldest user and goes only with the
  account; a profile's follows, watches, hints and sizes are its own rows, deleted with it
  (`Accounts.deleteProfile`), never the catalogue; a header naming a user off the device's
  account is refused with `ProfileHeader.refusal`; every push path reaches the account's
  devices through `Notifier.audience`, labels another profile's alerts, honours its
  `alerts_enabled` and collapses per profile. **Profiles share the account's credits and
  country**: the credit routes read the device's own user, so every profile hits one ledger;
  `users.country` is written to every user on the account by `Accounts.setCountry` alone (the
  device PATCH as any profile, the merge, a new profile copying its holder), so the storefront
  rules — `Storefronts.wanted`'s follow join, `serving`, `Notifier` — need no change to treat a
  profile as being where its holder is.
- **The owner's unlimited credits are a flag on the account** (`accounts.unlimited_credits`,
  `monthly_cost_cap_micros`). Credits read both (`docs/credits.md`). To set them on your own
  account, sign in on your phone, then:
  ```bash
  curl -H "Authorization: Bearer $ADMIN_TOKEN" https://app.streetw.hottorun.com/admin/accounts
  # the newest row, with your device count, is yours
  curl -X POST -H "Authorization: Bearer $ADMIN_TOKEN" -H 'Content-Type: application/json' \
    -d '{"unlimited": true, "monthlyCostCapMicros": null}' \
    https://app.streetw.hottorun.com/admin/accounts/<id>/credits
  ```
  The cap is in millionths of a dollar (`25000000` is $25), `null` clears it, and a negative
  value is refused. The list shows counts only and nothing about what anybody follows.
- **Credits and cost metering have their own doc** (`docs/credits.md`); the server rules in
  short. `credit_ledger` is the balance — no stored total — and a spend locks the account row
  (`FOR UPDATE`) before summing, which SQLite cannot exercise: `CreditRaceTests` runs against a
  scratch Postgres named by `STREETW_TEST_POSTGRES_URL` and is skipped otherwise. Two unique
  constraints *are* the idempotency — `(apple_transaction_id, reason)` credits and refunds a
  purchase once each, `(account_id, allowance_month)` grants a month once — and both rely on
  NULLs never colliding, on Postgres and SQLite alike. `ai_costs` keeps numbers only, with both
  keys `ON DELETE SET NULL` so deleting an account unnames its costs and keeps the measurement;
  the ledger cascades. Every amount and token count is a `BIGINT`, and a sum is
  `CAST(… AS BIGINT)` because Postgres sums a `BIGINT` into a `NUMERIC` that will not decode as
  an `Int`. Both tables set `created_at` themselves rather than through `@Timestamp`, because
  the month a row falls in decides the allowance and the cap and has to be testable across a
  month's end. `POST /v1/app-store/notifications` is public and verified by signature — the
  envelope, the transaction and any renewal info, each against Apple Root CA - G3
  (`AppStoreVerifier`, `AppStoreSignature.swift`; the rules are in `docs/credits.md`).
- **A brand's main shop is the brand row; a country's shop is a `storefronts` row**
  (`StorefrontModel`, `CreateStorefronts`, `Storefronts`). Big retailers run a shop per country —
  Victoria's Secret UK is a different company from the US one — so a brand maps to its storefront
  per country: a base URL, a currency, **its own sources** and the **set of countries it serves**.
  `sources`, `products` and `events` carry a nullable `storefront_id`, and **null is the main
  shop**. Six details are load-bearing:
  - **A storefront serves a set of countries** (`storefront_countries`, `StorefrontCountryModel`,
    `CreateStorefrontCountries`), because brands run one shop for a region: `eu.kith.com` is one
    shop, in euros, for 48 countries. A join table, not a `TEXT[]`, because an array column
    cannot be reproduced on SQLite and every serving rule would then be tested by nothing local.
    **Unique on `(brand_id, country)`** — one shop per brand per country is the schema's rule,
    not the routes' — with `brand_id` copied from the storefront so the constraint can see it.
    The migration gave each existing shop its own country as its one entry and wrote nothing
    else, so nothing was re-polled or re-baselined. `storefronts.country` survives as
    `homeCountry`, always one of the set: it sits inside the old `(brand_id, country)` unique
    constraint, SQLite cannot drop a column that does, and the two databases must not diverge.
    Keeping it a member of the set means that constraint can never fire on its own; taking it
    out of the set moves it to another member (`Storefronts.narrow`). It is what
    `StorefrontDTO.country` sends; `StorefrontDTO.countries` is the set.
  - **The main shop is not a row, and that is what keeps existing data unchanged.** Every source,
    product and event already in the database is exactly "the main shop", so a null column says
    so with no backfill, no re-discovery, no new polling and no baseline re-spent. Minting a
    storefront per brand and re-pointing every source would have rewritten every source and
    product row — the volume problem `refresh` guards against — to say what null already says.
    The main shop has no country either: Palace's is British and Kith's American, nothing here
    knows which, and it is what serves everybody nobody else serves.
  - **Countries are switched on by `STOREFRONT_COUNTRIES`** (`GB,DE`), read once at boot like
    `ADMIN_TOKEN`. Unset is none, which is today. An environment variable rather than a table
    because a country multiplies the polling of every brand followed there, so switching one on
    is a deployment decision, made rarely and visibly — not a toggle somebody with the admin key
    flips at a terminal and nobody notices.
  - **A storefront is polled only while any of its countries is switched on and has a follower
    of the brand** (`Storefronts.wanted`, `Storefronts.isRead`): a follow's user has that
    `users.country`. Worked out once per tick, and applied in the claim itself
    (`storefront_id IS NULL OR storefront_id = ANY(wanted)`), so a paused storefront is never
    claimed, never fetched and never pushes its schedule forward. `wanted` is a set of
    storefront ids, so a shop followed from three countries is claimed and fetched **once** —
    membership decides whether, the claim is per source (`MultiCountryStorefrontTests`, and
    `StorefrontPostgresClaimTests` against a scratch Postgres). **The main shop's sources are
    claimed exactly as before** — `PollerStorefrontTests` counts the requests. Its product pages
    are read by `enrich` under the same rule.
  - **A storefront that sat idle re-baselines** (`Storefronts.resumeAfter`, a day), as a whole:
    its sources are read for all its countries at once, so "idle" means nobody in any of them
    followed the brand. Nothing
    polls a paused storefront, so the first read after a pause compares against whatever it
    knew months ago — and would announce every product and restock since as news to the first
    follower back. Nothing else ever leaves a source unread for a day: the longest backoff is
    six hours. The baseline is *un-spent* (`baselined_at` cleared) rather than this one read
    declared one, so a resumed read that fails still owes it — the rule a first poll keeps.
  - **A caller is served the storefront whose set holds their country, only when it is live** —
    their country is switched on, the shop is being read (somebody in one of its switched-on
    countries follows the brand — for a follower that is themselves, for Discover it can be a
    German follower keeping `eu.kith.com` read for somebody browsing from France), and it has
    been baselined (`Storefronts.serving`). Otherwise the main shop, exactly as before: an
    Italian in `eu.kith.com`'s set gets Kith's main shop until Italy is switched on. One rule for
    `GET /v1/feed`, `GET /v1/brands/:id/feed`, `GET /v1/discover`, every `BrandDTO` and
    `Notifier`, and it is **one shop per brand per person, never both**: a reader in Britain
    would otherwise get every drop twice, once in each currency, and a push for each. A brand
    page's sources and currency are the serving shop's; `BrandDTO.storefront` names it, nil
    for the main shop, which is all 1.0 ever sees.
- **Every stored price carries its currency** (`products.currency`, `AddStorefrontColumns`), from
  the read that produced it — Shopify's `/meta.json`, a JSON-LD offer's `priceCurrency`, UCP's
  money. An event's previous price is in its product's currency. **Nothing is converted**: there
  are no exchange rates anywhere in this system, prices are compared within one shop, and a
  price that changed currency between two reads is not a markdown (`PriceChange.isDrop`'s
  currency guard). A row from before the column has none, and on the wire falls back to
  `brands.currency` — correct, because every such row is the main shop's. `FeedItem.currency` and
  `DiscoverCard.currency` are optional, so 1.0 and 1.1 decode exactly as before.
- **`users.country` is the caller's country, nullable, and null is the main shop**
  (`UpdateDevice.country`, `RegisterDevice.country`, `CountryCode`). Sent on `PATCH /v1/devices/me`
  beside the sizes, and on registration so the first feed is already the right shop. Absent
  changes nothing and an empty string clears it. **A code that is not one is ignored, not
  refused**: that PATCH is the first authenticated call of every launch and doubles as the
  liveness check, and a 400 there would fail the whole sync over a setting.
- **What only the main shop does.** The brand's name and `brands.currency` come from main-shop
  sources only, so a British storefront cannot rename the brand or reprice its legacy rows. Both
  sale detectors read the main shop alone — the catalogue's state lives on the brand row, and the
  announcement bar is `brands.website` — so a country storefront's readers hear of no `.sale`
  yet; a sale on the main shop is not one on theirs. `repoint` and `source` rebuild the main
  shop and leave every storefront alone.
- **A storefront is attached by hand, for a set of countries**
  (`POST /admin/brands/:id/storefronts?url=…&countries=DE,FR,IT` — or `country=GB`, or a JSON body
  `{"countries": [...]}`). It runs ordinary discovery on the URL, through the poller's fetcher.
  **Naming no countries is the offer and writes nothing**: every country the shop's `/meta.json`
  ships to, minus those another shop of the brand serves; `countries=all` takes it. An offer
  rather than a default because a shop's list is not its market — `eu.kith.com`'s 48 include the
  US and Canada, where Kith's main shop is — so somebody reads it first. A token that is not a
  country code refuses the whole request rather than attaching for the rest. It refuses three
  mistakes: nothing watchable there; **a catalogue the brand already reads** — the main shop
  (a Shopify Markets subfolder like `/en-gb/` is read off the host, so it would be the main shop
  again in its currency; reading those is not built) or a shop already attached, which is pointed
  at `…/add` instead; and countries the shop's `/meta.json` says it does not ship to, unless
  `&force=true`. Measured: Kith's US shop ships to 197 countries, `eu.kith.com` prices in EUR and
  ships to 48, and Palace's `www.` prices in GBP and ships to five — GB, GG, IM, JE, PH.
  `/meta.json`'s own `country` is where the *merchant* is (`eu.kith.com` says FR), not who it
  sells to, and is not read. Attaching for countries another shop serves takes them off it
  (`Storefronts.release`); a shop left serving nobody is removed with its history, which is what
  replacing a one-country shop always did. `POST /admin/brands/:id/storefronts/:country/add?countries=`
  and `…/remove?countries=` change the set of the shop serving `:country` without re-reading or
  re-baselining anything; `add` refuses a country another shop holds (remove it there, out loud —
  the people in it change shop) and checks ships-to like attaching, and `remove` refuses the last
  country, which is `…/delete`. `POST /admin/brands/:id/storefronts/:country/delete` removes the
  whole shop, for every country it serves, with its sources, products and events — the products
  by hand (`Storefronts.remove`), because `products.source_id` is `ON DELETE SET NULL` from the
  initial schema and the cascade from the storefront stops at its sources. `GET /admin/catalog`
  prints each shop's whole set. Nothing discovers country storefronts automatically.
- **`HTTPFetching`, not `HTTPClient`** — Vapor re-exports `AsyncHTTPClient.HTTPClient` and
  an unqualified collision in the server target is nastier than the wordier name.
- **Don't name a test helper `withApp`.** VaporTesting exports a generic `withApp<T>` that
  does *not* run `configure`. A single-statement test closure lets Swift infer `T` from
  `test(...)`'s discardable return and silently pick that overload — the app comes up with
  no routes and everything 404s, while multi-statement closures resolve to yours and pass.
  The local helper is called `withServer`.

## Product search

`GET /v1/products/search` and `GET /v1/products/:id/similar` (`ProductRoutes.swift`,
`ProductSearch`, `CatalogueText.swift`). The phone's half and the screen's rules are in
`docs/discover.md` (*Shop*); these are the server's.

- **One grammar, both ends.** The text is parsed by `ShopQuery` and matched, constrained, ranked
  and explained by `ShopSearch.run` — the code the phone runs over its own store. The server only
  adds what a phone does not need: an index to *find* candidates in a catalogue too large to load,
  and the database's answer to which words exist at all. `ProductSearchTests.parity` runs the same
  queries through the route and through `ShopSearch` over the same products and compares the
  pages, the partial matches, the struck words, the outcome and the "cheaper" bound.
- **The index finds; the grammar decides.** `CatalogueTextIndex.candidates` hands over the best
  `ProductSearch.pool` (600) products in scope carrying any of the words — every word first, then
  `ts_rank_cd`, then recency and id — and `ShopSearch` keeps what really matches. So it errs wide:
  a category word looks for every token `GarmentClassifier.vocabulary` can place there, a compound
  ("tshirt") for its parts in order, a shop's name by brand id. What can be said in SQL — a price
  bound, a ruled-out word in the vector — narrows the candidates, and a second read of 200 without
  them is what lets an empty answer still say how many matched and what the cheapest was.
- **Which words exist is asked of the whole scope** (`existing`, one `EXISTS` per word), never read
  off the candidates. A rare word crowded out of 600 would otherwise be "not in your shops" on the
  server and required on the phone — `rareWordsAreRequired` reproduces exactly that. `ShopSearch.run`
  takes it as `knows:`.
- **`simple`, not `english`** (`AddProductSearch`). Product names are not prose: the English
  configuration drops "on", "off" and "all" as stop words (On Running, Off-White, All Saints), and
  stems "Vans" to "van" and "boxy" to "boxi". The grammar spells out a word's other number and its
  synonyms itself, the same on both ends, so a stemmer would only add matches the phone never makes.
- **`products.search` is a generated column** — `setweight` A title, B product type, D tags, through
  `streetw_fold` (accents folded with `translate`, because `unaccent` is not `IMMUTABLE`) and
  `streetw_join` (`array_to_string` is only `STABLE`). Nothing that writes a product changes; the
  poller is untouched. A generated column sees one row of one table, so the brand's name is matched
  in Swift and the colourways through an expression index on `variants`
  (`idx_variants_color_search`), one index scan per word: an aggregate asking every word per variant
  recomputed the vector each time, 68ms of an 80ms query.
- **Ranking quality is a property of Postgres.** SQLite (`PortableTextIndex`) reads the same fields
  with `LIKE`, newest first, no rank, and the candidates' vocabulary stands in for `existing`. It is
  there so the tests drive the route, the scopes and the grammar end to end; tune nothing against it.
  `ProductSearchPostgresTests` covers the rank, the spellings and `existing` against
  `STREETW_TEST_POSTGRES_URL`.
- **What is searched** (`CatalogueScope.predicate`): `kind = 'product'`, a photograph, the shop that
  serves the caller (`Storefronts.serving` — one shop per brand, never both), announced
  (`pending_announcement IS NULL`) and still listed (`unlisted_at IS NULL`). Scope `followed` is
  every follow whatever its mode — *Quiet* still shapes search; `all` is every brand. The gender
  filter and "in my size" are applied by the grammar, so an empty answer can say it was the filter.
- **Candidates are read as columns, the page as models.** Hydrating 600 `ProductModel`s and four
  thousand `VariantModel`s through Fluent was 380ms of a 650ms search; reading rows into values and
  building `DiscoverCard`s for the page alone brought "black hoodie" to 105ms and the rest to 20–70ms,
  measured in release on eight thousand products. The size context is worked out only for the
  listings "in my size" is asked about.
- **Paging is an offset into one query's ranking** (`cursor`, opaque). Total, with no randomness, so
  the same query pages the same way; a catalogue that changes between two pages can repeat or skip a
  product at the seam, which is the price of not holding a cursor's state.
- **One list over every shop is `scope=all` plus `boost=`** (Phase 5). The scope reads every
  follow whatever the scope (`CatalogueScope.followed`), and `ProductSearch.load` adds
  `ProductSearch.lift` to the score of every listing from a followed brand (`ShopListing.boost`):
  1 for `standard`, 3 for `more`. In `ShopSearch`'s ranking it sits beside the field-weighted
  score, after availability and the leanings, so it settles near-equals and nothing else; on the
  phone every listing is followed and the boost is zero, which orders nothing. `boost` on
  `scope=followed` is ignored and not reported. The answer's `boost` says what was applied.
- **Meaning matches** (`meaning=true`, Phase 5). The query's hundred nearest products by text
  vector (price-narrowed, as the full-text candidates are) are still candidates and still add
  their similarity to `relevance`; those at or above the model's threshold
  (`ProductSearch.measuredThresholds[model]`, `Application.meaningThresholds`) are also handed to
  `ShopSearch.run(meaning:)`, which lets them into the main list without the words — only while
  fewer than `ShopSearch.partialBelow` products carry every word, measured below — credits each
  missing word at a tag's weight (`ShopSearch.meaningWeight`), and runs every constraint over
  them — so "no wool" still rules out the wool blazer the embedding liked. The query is embedded
  as its words plus "formal" when it leans that way (`embeddingText`), never a ruled-out word.
  `meaningSearched` is true only when vectors answered and the model has a threshold; **a model
  with none makes no meaning matches**, so switching models cannot put unmeasured guesses on the
  page. Without `meaning=true` none of this happens and the candidates are read exactly as
  before, which is what 1.2 and 1.3 ask for. **The hundred were forty until 2026-10-30**:
  pgvector's HNSW scan returns at most `hnsw.ef_search` rows, forty by default, whatever the
  `LIMIT` says — measured on the eval catalogue, `LIMIT 100` through the index gave 40 rows —
  so `SemanticIndex.nearest` now raises the setting to its limit with a `SET LOCAL` in a
  transaction of its own (a pooled database gives each statement its own connection
  otherwise), at about a millisecond instead of half of one. A tight narrowing is still applied
  after the scan and can leave fewer; pgvector 0.8's `hnsw.iterative_scan` would finish the
  count and is not set, because an older extension refuses the name and every search's
  vectors with it.
- **Parity is defined for the word path.** The phone has no vectors, so `parity` (and
  `parityWithTheLift`, the same over a followed and an unfollowed shop with the lift on) holds
  the route and `ShopSearch` to the same page for the same products when no vector speaks:
  SQLite has none, and that is the configuration the parity tests run in. A meaning match is
  the one thing the server may add, and it is labelled.
- **"More like this"** takes the product's id, or the external id the phone holds with `?brand=` —
  percent-encoded as one segment, because a sitemap product's key is its whole URL. By vector where
  this product has one under the current model, otherwise by its own words read as a query and
  scored the way `SimilarItems` scores (the same slot, each shared word, half a point for the same
  shop, at least two). `basis` says which.

## Embeddings

Search and "more like this" compare vectors, and the vectors come from one place: **`Embeddings/`,
a Python service running Marqo FashionCLIP, deployed as a second Railway service beside this one.** The
server sends it text or image URLs and gets back unit vectors; it stores nothing. The server decides
what to embed and when, stores each vector in pgvector beside the model id that produced it, and does
the comparing in Postgres. Nothing in either Swift package imports anything from the sidecar, and the
phone never talks to it.

It is off in production until two things are true, and each is said at boot: a Postgres with pgvector
(`docs/pgvector-migration.md`), and the sidecar deployed with `EMBEDDING_URL` and `EMBEDDING_TOKEN`
set on this service.

### The sidecar

- **Self-hosted, not an API.** A query embedding is on the path of every search, and an image
  embedding on every product the poller sees. A third-party API would put a stranger's uptime
  in front of the search box and a per-call bill on the catalogue. It would also send every
  query a person typed to somebody else, which `StyleStatement` was kept local to avoid. The
  model is 200M parameters and runs on CPU at roughly 3–10 images a second on 2 vCPU
  (measured in Docker and natively; Railway's own number is still to be taken), and embedding
  100k products once costs well under a dollar. There is nothing to buy. `Embeddings/README.md`
  and `Embeddings/eval/README.md` have the measurements.
- **Python, in its own service.** torch has no Swift equivalent worth the port, and putting it
  in the server's image would put a 2 GB toolchain into every server deploy. A separate service
  also lets the model's memory be sized and restarted on its own.
- **Marqo FashionCLIP by default, chosen on the search eval.** FashionSigLIP v1 was the first
  model — Marqo offers SigLIP 2 only commercially, and v1 beat the base SigLIP by only a few points
  on `Embeddings/eval` — and the switch was made on 2026-10-30 after nine models were run through
  *The search eval* below, which measures what the server compares (text with text): P@10 0.836 →
  0.862, nDCG@10 0.861 → 0.883, seven right meaning matches added where SigLIP added two, and
  512-wide vectors instead of 768. Both are Apache-2.0 and pinned by revision. **The model is a
  build argument of the image** (`EMBEDDING_MODEL_REPO`, `_REVISION`), so switching back, or to
  the third-party `srpone/zooclaw-fashionsiglip2` — Apache-2.0 with a `LICENSE` file since
  2026-10-28, eleven points better than v1 on `Embeddings/eval`'s text R@1, four times slower per
  image, never run through the search eval — is two variables and no code. **A model needs its
  own numbers on this side, keyed by the id the sidecar reports**: a search threshold in
  `ProductSearch.measuredThresholds` and reading bars in `ZeroShot.measuredBars`; a model
  missing from either makes no meaning matches and reads no photographs, rather than running
  another model's. `Embeddings/README.md` (*Choosing the model*) has the switch and its cost.
- **The model id names the repository and the revision**, and is stored beside every vector. Two
  models, or two revisions of one, do not share a space: a vector from one compared with a query
  from the other still produces a ranking, and the ranking is noise. If an answer names a
  different model from the one the provider last reported, `SidecarEmbeddingProvider` throws
  `modelChanged` rather than return the vectors under the old id, and the backfill's next batch
  starts re-embedding under the new one.
- **The sidecar fetches URLs, so it is an SSRF surface, and it sits next to Postgres.** It
  refuses non-public addresses on every hop and pins the connection to the address it
  checked. It requires a token, compared in constant time, and refuses everything without
  one, like `ADMIN_TOKEN`. It has no public domain.

### The server's half

- **One protocol, `EmbeddingProvider`** (`Services/Embeddings.swift`): `space` (the model id and
  the dimension, as the provider reports them — asynchronous, because the sidecar learns them from
  its own `/health`), `embedsImages`, `embed(texts:)` → `[[Float]]` and `embed(imageURLs:)` → one
  `ImageEmbedding` per URL. The dimension is never hard-coded — FashionCLIP is 512, the SigLIP
  models 768.
  `SidecarEmbeddingProvider` is the production conformer, `FakeEmbeddingProvider` the tests'.
- **Unset is off, and off is a supported state.** With `EMBEDDING_URL` or `EMBEDDING_TOKEN` unset,
  `SidecarEmbeddingProvider.make` returns nil, logs `embeddings: off — …` (a warning when only one
  is set), and search is full-text. Set, it logs `embeddings: sidecar at …`. Every failure is an
  `EmbeddingError` naming which one it was (unreachable, refused, malformed, model changed, wrong
  count or dimension, timed out), so search can fall back without guessing.
- **pgvector is installed only where it is available.** `AddProductEmbeddings` runs
  `CREATE EXTENSION IF NOT EXISTS vector` only when `pg_available_extensions` lists it, and creates
  `product_embeddings (product_id, model, text_embedding vector, image_embedding vector,
  embedded_at, image_url, image_failure, image_attempts, image_retry_at)`. Where it is not —
  production today, and SQLite — the migration records itself and does nothing, and boot logs
  `search: full-text; semantic search unavailable (…)`.
- **The same work runs again at every boot** (`SemanticIndex.prepare`), and that is load-bearing:
  the move to pgvector is a dump and restore, the restored `_fluent_migrations` says the migration
  ran, and without the boot pass the new database would never get its table. Rehearsed. A column
  added to the table is added there too, with `ADD COLUMN IF NOT EXISTS`, for the same reason.
- **The model id is stored beside every vector**, so a new model is a re-embed and not a migration:
  `EmbeddingBackfill` embeds what has no row or a row from another model, a batch at a time, and a
  nearest-neighbour query names the model, so two models' vectors are never compared. The column is
  a bare `vector`; the HNSW index is built per model on `text_embedding::vector(n)`, partial on the
  model (`SemanticIndex.ensureIndex`), so another dimension is another index. A half-finished
  re-embed answers from fewer products, never from a mix — a search compares the current
  model's vectors only, and full-text answers for the rest, so nothing is down while it runs.
  Expect about an hour per 10,000 products on Railway's 2 vCPU for a 224 px ViT-B/16 (FashionCLIP,
  FashionSigLIP), and the product readings to follow behind; `docs/pgvector-migration.md`
  (*Switching the embedding model*) is the owner's note.
- **A separate table, not a column on `products`**: the poller and the scan rewrite product rows,
  and a few kilobytes of floats would ride along on every rewrite — the volume problem above.
  **Measured on Postgres 17 with pgvector 0.8.7**, 565 real products embedded by FashionSigLIP:
  7.2 MB after `VACUUM FULL`, **about 12.7 MB per 1,000 products** — 3,076 bytes per 768-wide
  vector, two per product, out of line in TOAST, and 4.2 KB per product of HNSW index on the text
  vector. That is four times what the scan measured for the products themselves (3.2 MB), so a
  catalogue's whole footprint is roughly 16 MB per 1,000 products before events. FashionCLIP's
  512-wide vectors are two thirds of that, about 9 MB per 1,000 products. A re-embed
  rewrites every row, so until autovacuum reuses the space the table is briefly twice that, and the
  old model's index stays until dropped.
- **What is compared is text with text, and a photograph with photographs.** A search embeds its
  own words and is matched against each product's *text* vector (title, type, brand, colourways,
  tags — the fields the grammar reads), and "more like this" compares two products' text vectors.
  The scan's "find this" (Phase 5, `AIScanSimilar`) sends the reader's photograph to the
  sidecar's `POST /embed/photo` (`EmbeddingProvider.embed(photo:)`) and compares it with every
  product's *image* vector (`SemanticIndex.nearest(column: .image)`), falling back to its words
  against text vectors. **The image vector it compares is the clean product shot's where the
  reading found one past the lead** — `COALESCE(shot_embedding, image_embedding)`
  (`Column.expression`, *The product photograph and style words* below) — because a reader's
  photograph of a jacket is a garment on its own, and a lookbook lead put somebody's jeans first.
  Each column has its own HNSW index per model (`ensureIndex`); the image one, on that
  expression, is new in Phase 5 and is built by the first backfill batch after the deploy — a
  one-off `CREATE INDEX` that reads are not blocked by.
- **The sidecar is sent a 400 px rendition, never the original** (`SemanticIndex.rendition`,
  `ImageRendition`; Shopify's CDN takes `width`, an unknown host is sent untouched). The model
  reads 224 px, and fetching 2,000–3,000 px originals was most of a batch: measured on 48 lead
  photographs each from Billionaire Boys Club, Stüssy and STAUD, originals ran at 0.87 a second
  with 7 timeouts, renditions at 4.2 a second with none. `image_url` still records the stored
  address, which is what the due query compares, and nothing is re-embedded: on the 203 products
  of `Server/ReadingEval` a rendition's vector sits at a median cosine of 0.998 from the
  original's.
- **A photograph that cannot be read costs its product only the image vector.** The sidecar
  answers `null` for it with a reason and a `transient` flag, which the provider turns into
  `.gone` (a 4xx, a 200 that will not decode, a refused address) or `.unavailable` (a timeout,
  429, 5xx, no DNS answer) — the split `docs/collection.md` makes on the phone. The text vector is
  written either way. A gone photograph is written off **for that URL**: `image_url` records it,
  so the row leaves the backlog, and a different lead photograph later makes it due again. An
  unavailable one is asked again at `image_retry_at` — an hour, then four, sixteen, sixty-four —
  and the fifth unavailable answer writes it off too, because a backlog that never drains
  re-fetches the same photographs forever. Each write-off is logged with its URL.
- **Unlisted products are neither searched, offered as "more like this", nor embedded**
  (`unlisted_at IS NULL` in `CatalogueScope.predicate` and in the backfill's query), as Discover
  leaves them out.
- **Query time needs the provider up.** A search embeds its words under a 1.5 s deadline
  (`ProductSearch.embeddingTimeout`, `withTimeout`); slow or down, the answer is the full-text one,
  which is complete on its own. Vectors widen the candidates and add to their rank; they make a
  match the grammar would not only when `meaning=true` asks (above), and then labelled. **`withTimeout` returns at the deadline whether or not the work
  listens**: a task group cancels its children and then *waits* for them, and an HTTP request on
  an event loop does not hear cancellation, so a group-based timeout over the sidecar returned
  when the request's own timeout fired. The abandoned request ends by its own timeout
  (`textTimeout`, 10 s, sized for the backfill's batches of 32).
- **…and one failure rests semantic search for 30 s** (`SemanticRest`). The deadline bounds one
  search, not an outage: with the sidecar down, AsyncHTTPClient retries the refused connection
  until the deadline, so every search was 1.6 s instead of 50–80 ms for as long as the sidecar was
  redeploying. Now the first search after a failure waits, and the next thirty seconds of searches
  are full-text without asking. In memory, per process, reset whenever the provider is set — a
  pause, not a verdict. "More like this" asks the same pause, and needs the sidecar only for the
  model id, which is cached after its first answer; with the vectors in Postgres it keeps
  answering by vector while the sidecar is merely slow.
- **`Application.semanticSearch`** is the one switch every semantic path asks — pgvector installed
  *and* a provider — so nothing runs half on. The backfill loop starts only behind it and only where
  the poller runs; `POST /admin/embed?batches=` runs batches by hand (and is how a server with
  `DISABLE_POLLER=true` embeds anything), and says which half is missing when it cannot.

## The search eval

`Server/SearchEval/` (Phase 5) — fifty-three searches a person would type (`queries.json`:
colours, garments, price bounds, "no …", shop names, German shoppers' English — "pullover",
"trainers", "shoes for the office", "bermuda" — and vague style words), each with a written
judge in `searcheval.py` (`JUDGES`) of what a person would accept, applied to the whole
catalogue and frozen in `judgements.json` with the day it was judged. Standard library only;
Postgres through `psql`; every address must be `127.0.0.1`, so it cannot be pointed at a
deployment. **Run it before and after every ranking change**, and paste both into the change.

1. A scratch Postgres with pgvector, the sidecar (`Embeddings/README.md`, natively or Docker),
   and a local server with the poller on, `DATABASE_URL` on the scratch database and
   `EMBEDDING_URL`/`EMBEDDING_TOKEN` set. Add the shops with `POST /v1/brands/discover` and follow
   them with one device so the poller reads them; the poller is polite by construction. The
   judged catalogue is Drake's, Stüssy, Noah, Aimé Leon Dore, STAUD, Billionaire Boys Club and
   Colorful Standard — 10,041 products, read 2026-10-27 to 29. Wait for the backfill
   (`product_embeddings` as many rows as listed products).
2. `python3 searcheval.py dump` and, only when the catalogue has moved, `judge --date …` — then
   read the pooled top tens (`run … --out`) and correct the judges, never the JSON.
3. `python3 searcheval.py run before after` prints P@10, recall in the first 100 (out of at most
   100, so a vague search with nine hundred right answers is not penalised for showing a
   hundred), nDCG@10, MRR, how many came back empty and how many results were by meaning, then
   P@10 by kind. The eval's reader follows Drake's and Colorful Standard, so the lift has
   something to lift. `before` is `scope=all` alone — what 1.2 and 1.3 send, and still answered
   that way.
4. `EMBEDDING_TOKEN=… python3 searcheval.py thresholds` embeds each query as the server does
   and, for each bar, counts the products among its hundred nearest that the words did **not**
   find and how many of those are judged right — the precision of what meaning adds.

**Measured on 2026-10-29** (FashionSigLIP v1, the catalogue above, 10,041 products, 14,378
judged answers; debug build):

| variant | P@10 | R@100 | nDCG@10 | MRR | empty | by meaning |
|---|---|---|---|---|---|---|
| `before` (`scope=all`, what 1.2/1.3 ask) | 0.834 | 0.697 | 0.849 | 0.895 | 2 | 0 |
| `after-words` (lift, no meaning) | 0.832 | 0.696 | 0.856 | 0.926 | 2 | 0 |
| `after` (lift + meaning — what the app sends) | **0.836** | 0.693 | **0.861** | **0.945** | **1** | 27 |
| `after-more` ("More from my brands") | 0.826 | 0.678 | 0.853 | 0.945 | 1 | 27 |
| ungated, every one of the hundred nearest admitted | 0.809 | 0.692 | 0.836 | 0.931 | 0 | 987 |

The base build's `before` gave the same top ten as the new build's on all 53 queries. By kind,
`after` moved style from 0.58 to 0.61 and German phrasing from 0.72 to 0.68; "smart summer
jacket" went from 0.6 to 0.8 and "something for a wedding" from nothing to one. The lift costs
"pullover" and "a jacket for rain" a place or two to the followed shops, which is the price of
the lift and why it is one point, not three. Small gains, measured — not a transformation:
FashionSigLIP's *text* vectors are a weak signal for what the words missed.

**The threshold is 0.66, and only under a search the words found little for** (fewer than
`ShopSearch.partialBelow`, twelve, word matches). From `thresholds`: of what meaning would add
to a search the words already answered, at most 16 % is right at *any* bar (0.159 at 0.64, 0.160
at 0.66, falling to 3 % at 0.74 — the nearest texts above 0.7 are mostly products whose *shop's
name* is in the query, "billionaire boys club hoodie" finding everything Billionaire Boys Club
makes); under the five searches the words found little for, 0.64 admits 29 at 28 % and **0.66
admits 9, of which 8 are right (89 %)**, with nothing above 0.68. So 0.66 is the lowest bar that
is mostly right, and the gate is what keeps the other 84 % off the page; the ungated row above
is what happens without it. Nine is a small sample — re-run `thresholds` on a bigger catalogue,
and on any new model, before moving it.

**FashionCLIP, measured the same way on 2026-10-30** (`searcheval.py meaning` scores a model's
vectors alone, and `thresholds --bars` takes each model's own range, since CLIP puts every pair of
texts closer than SigLIP does): over the same 53 searches and judgements, `after` went from P@10
0.836 to **0.862** and nDCG@10 0.861 to **0.883**, German phrasing from 0.31 to 0.32, and under the
searches the words found little for its gate admitted **seven** right results where SigLIP's
admitted two — the best of nine models run, and why it is the default
(`Embeddings/README.md`, *Choosing the model*). Its bar is **0.45**
(`measuredThresholds["Marqo/marqo-fashionCLIP@44f4c655124e"]`). The two rows stay in the table:
the sidecar reports which model answered, a search compares only that model's vectors and gates
them by its bar — so while the catalogue is re-embedded, meaning matches come from the products
already done — and switching the sidecar back finds the old vectors' bar still there.

## The product photograph and style words

Phase 5, `ProductReading.swift`. Whether one of a product's later photographs should **stand in
for the shop's first** — because the first is on a person and that one is the whole garment on
its own — and up to two style words from a fixed vocabulary, read **once per product** on the
server and sent on the wire. `docs/collection.md` (*The cover*) has the phone's half: the
shop's first photograph is the cover unless the server says so or somebody chose one by hand.

- **The shop's first photograph is right by default, and nil means "keep it"** — the owner's
  rule, 2026-10-31 (`ZeroShot.version` 2). The first version answered the question "which
  photograph is the clean product shot?", with 0 for a lead that was one and a later index
  otherwise, and it decided "product shot" by "no person in it". On Motel Rocks most galleries
  carry a close-up of the fabric; a swatch has nobody in it either, so the cover of a dress
  became a square of cloth — on the server, and on the phone, whose Vision check asked the same
  question. The question now is "should a later photograph stand in for the first?", and the
  answer is yes only when the reading is **confident twice**: that the first photograph is on a
  person, and that a later one is the whole garment on a plain background, ahead of "a person"
  *and* ahead of "a close-up" by the model's margin. A lead that reads as a product, or that the
  model is unsure about, is not looked past; a gallery of models and swatches all the way down
  keeps the shop's choice. `shotIndex` is therefore nil or ≥ 1, never 0, and nil is "nothing
  to say" rather than "no shot". **Precision over recall**: a wrong stand-in overrides a shop's
  own choice with something worse, and the margins were chosen so that none on the labelled set
  is wrong.
- **Zero-shot through the embedding model is the method** (`ZeroShot`), the owner's rule: Claude
  only if it clearly reads the photographs better, which is the comparison below. A photograph
  is scored against **three classes** of sentence — the whole garment on its own ("a product
  photo of a whole garment on a plain background", "a ghost mannequin photo of a garment", …), a
  person wearing it ("a fashion model posing", …) and a close-up ("a close-up photo of fabric
  texture", "a swatch of material", "a clothing label", "a cropped close-up of part of a
  garment", …) — each class's score its best similarity to its sentences, and what counts is how
  far a class leads **both** of the others (`ZeroShot.Scores.personLead`, `.productLead`). Two
  classes were not enough: with the fabric sentence one voice among the "not a product"
  prompts, a swatch still read as more product than person. The prompts are embedded once per
  model through the sidecar's own `/embed/text`; **the sidecar is unchanged** — every comparison
  is a dot product in Swift.
- **The bars are the model's, and are kept per model id** (`ZeroShot.Bars`,
  `ZeroShot.measuredBars`, keyed like `ProductSearch.measuredThresholds`): `personMargin`, how
  far "a person" must lead for the first photograph to be read as on a person at all;
  `shotMargin`, how far "the whole garment" must lead for a later photograph to stand in; and
  `styleBar`. Each model puts the same photograph and sentence at its own distance — CLIP's
  margins and SigLIP's are not on one scale — so bars tuned on one would be wrong on every
  product under another, and nothing on the wire would show it: the stand-ins and the words
  would simply be worse. **A model with no bars is not read.** `ZeroShot.prompts` throws
  `Unmeasured`, the backfill answers `waiting` with the reason and logs it once
  (`POST /admin/readings` prints it), and boot names the models that have bars. The reading eval
  below measures a new model's bars; `ReadingEvalTests` sweeps both margins and prints the table
  whatever the model, and scores and writes a result only for a model that has them.
- **The other photographs are embedded only when the first clearly looks like a person.** The
  lead's vector is the one `EmbeddingBackfill` already stored, so most products (188 of the
  eval's 233 under FashionCLIP, 198 under SigLIP) are answered with no request at all. Otherwise
  up to five more, as 400 px renditions, **four to a request with a 250 ms pause after each**,
  stopping at the first request that holds a stand-in: the sidecar takes requests one at a time,
  and a search's query embedding waits behind whichever is in. Measured while the reading ran
  flat out: single query embeddings answered in 0.02–0.10 s, far inside their 1.5 s.
- **Style words** (`StyleWords.vocabulary` in the core: workwear, minimal, preppy, streetwear,
  tailoring, y2k, sporty, outdoor, romantic, vintage, skate, western, boho, grunge, graphic —
  single tokens, so a search can match them whole) are scored as 0.7 × the shot's similarity to
  the word's prompt (a few phrases averaged, "a photo of rugged canvas work jacket clothing") plus
  0.3 × the product's text vector's, **minus the word's mean over the catalogue**, and at most two
  above 0.01 are given. The mean is the dot product with the average stored photograph and text
  vector — pgvector's `avg()` over up to 2,000 rows, one query, refreshed daily; nothing is read
  until there are 200 photographs to average (`minimumCalibration`). Without the calibration a
  prompt's raw similarity says as much about the prompt as the photograph.
- **Stored once per product.** `products.shot_index` (nil = keep the shop's first photograph,
  which is also "not read") and `products.style_words` (`TEXT[]`, nil = not read, empty = read
  and nothing clear), GIN-indexed for search; `AddProductReading`. The ledger is
  `product_readings` (Postgres only): the method key (method, `ZeroShot.version`, model id), an
  md5 of the first six photographs read, attempts, `retry_at` and `gone` — so a restart resumes,
  a new gallery or model or version reads again, and nothing on `products` changes unless the
  answer did. A stand-in also writes its vector to `product_embeddings.shot_embedding` (added at
  boot by `SemanticIndex.prepare`), which photo search compares instead of the lead.
- **A rule change reads the catalogue again, and forgets the old answers first.** Bumping
  `ZeroShot.version` changes every method key, so every product is due; that is hours on
  Railway (below), and until a product is reached its old `shot_index` would go on being served
  on every feed row, Discover card and `/v1/products/readings` it is on. So `ClearProductShots`
  — the migration that ships with version 2 — sets every `shot_index` to nil at deploy: nil is
  the new rule's default, a wrong stand-in is worse than none, and the stand-ins the new rule
  does find come back as the backfill reaches them. The style words are left (the same prompts
  read them, and search needs them meanwhile), and the ledger keeps its old keys, which is what
  makes everything due. **What the owner will see**: at deploy every cover is the shop's first
  photograph; over the next hours (about two on this Mac, four on Railway's 2 vCPU for 10,000
  products — the catalogue was 11,286 at the last count) the log prints `read 16 (n shots past
  the first photograph, …)` batches and the few confident stand-ins arrive, then it is only new
  products again. Phones learn a stand-in on their next `/v1/products/readings` ask for the row
  (`docs/collection.md`) — and **the server goes first**: the app build that ships the rule
  ignores stand-ins adopted under the old one and asks again, and with the migration run it can
  never adopt an old answer as current.
- **The backfill** (`ProductReadingBackfill`) runs behind the embedding backfill, sixteen products
  a batch, where the poller runs and only where `semanticSearch` is on — idle, and said at boot,
  when the sidecar is off. A product is due once its lead photograph's embedding has settled
  (a vector, or written off). A photograph the sidecar cannot read follows `EmbeddingBackfill`'s
  rules: `.gone` goes into `gone` and is never asked again for this reading; `.unavailable`
  leaves the reading unsettled with its best answer so far, asked again at one hour, then four,
  sixteen and sixty-four, and settled as it stands on the fifth. `POST /admin/readings?batches=`
  runs it by hand and says why when it cannot. **Pace, measured** on this Mac (sidecar on 4
  threads, renditions): the first 160 products in 44 s with 99 extra photographs; then 3,305 of
  the 10,043 in about 40 minutes (with builds competing), at 1.0–2.4 products a second depending on the shop — STAUD and
  Drake's, whose leads are models or lifestyle shots, cost five photographs a product, Colorful
  Standard and Aimé Leon Dore none. Of those 3,305, 564 got a shot past the lead (139 of Drake's,
  254 of Stüssy's, 153 of STAUD's) and 328 none, 283 of them STAUD's on-model galleries. A whole
  10,000-product catalogue is therefore about two hours here, and should be expected to take
  twice that on Railway's 2 vCPU — once; afterwards it is only new products.
- **On the wire**: `FeedItem.productShotIndex` and `.styleWords`, `DiscoverCard` the same (search
  hits are `DiscoverCard`s), optional and ignored by older apps; `readShotIndex` drops an index
  the gallery no longer reaches. An older app reads a stand-in exactly as it read a product shot
  and shows it; where the server now keeps the shop's choice it falls back to its own Vision
  pick, as it always did for a product with none. **`POST /v1/products/readings`** answers for
  products the phone already holds (its saves, whose feed rows were sent before the reading) — at
  most a hundred, keyed by brand and external id or the external id alone, only those read, the
  stand-in as its URL.
- **Search matches style words like tags.** `ShopListing.styleWords` is noted at a tag's weight in
  `ShopIndex` (so "workwear" finds a canvas jacket, and a title that says workwear still ranks
  first), `PostgresTextIndex` adds `p.style_words && ARRAY[…]` to the candidates and to `existing`
  for the words that are style words, and `PortableTextIndex` a `LIKE`. The phone stores the words
  and `ShopCatalogue` reads them, so parity holds. The ranking is otherwise untouched.
- **The Haiku switch.** `PRODUCT_READING=haiku` reads with the fast model instead
  (`AIProvider.readProductPhotos`, `docs/ai.md`), asked the same three-way question in words —
  is the first photograph clearly on a person; is a later one clearly the whole product on its
  own; is it not a close-up, a crop, a swatch or a label — with 0 for "keep the first" and a
  wrong stand-in named as worse than none. Numbered from one on the page, and 1 reads as 0: the
  first photograph is never its own stand-in. Owner-paid as `product_reading` under
  `AI_BACKGROUND_DAILY_CAP_MICROS`, checked before every product; off by default, and switching
  method reads the catalogue again.

### The reading eval

`Server/ReadingEval/labelled.json`: 203 products from the search eval's seven shops (29 each,
chosen by a hash of the id among products with two or more photographs) plus, for the close-up
rule, 30 STAUD products whose gallery carries a swatch or a detail photograph (group
`close-ups`, chosen by a hash of the id on 2026-10-31 — the local catalogue has no Motel Rocks,
and STAUD is the shop in it that ends most galleries with a square of cloth); their first six
photographs, and labels made by hand by looking at every photograph — `shots`, every photograph
that is the whole product on its own (null when none is: lookbook pages, galleries on models all
the way down), `details`, every close-up, crop, swatch or label (2026-10-31; 148 of the 233 have
one), and every plausible style word (2026-10-30; the 30 added are unlabelled for words). 45 of
the 233 do not lead with a product shot, and 20 of those have one later — the stand-ins there are
to find. The harness is `ReadingEvalTests`, which runs the shipped code against the network and
writes `results-<method>.json` beside the labels, printing the other method's last run for
comparison. From `Server/` in a checkout named `streetw`, with `DEVELOPER_DIR` set:

```bash
STREETW_READING_EVAL=siglip EMBEDDING_URL=http://127.0.0.1:8080 EMBEDDING_TOKEN=… swift test --filter ReadingEval
STREETW_READING_EVAL=haiku ANTHROPIC_API_KEY=… swift test --filter ReadingEval   # AI_MODEL_FAST= to try another
```

The Haiku run needs nothing but the key — no database, no server, no sidecar — and is estimated
at about forty cents.

**Every run embeds every photograph and sweeps the margins.** The harness embeds the first six
photographs of each product up front (the sidecar's batches of 64), runs the shipped reader
against that cache — so what it *asks* is still what the backfill would ask — and then re-runs
the rule from the same scores at every pair of margins from 0.00 to 0.08, printing for each:
stand-ins right/made (the precision), how many were close-ups, how many overrode a lead that was
a product shot already, stand-ins found of those there were to find, the answer right overall,
and **which products the wrong ones were** (`#index→photograph`, into `labelled.json`), so a
wrong stand-in can be looked at rather than counted. Then the style bar. A model that
`ZeroShot.measuredBars` does not name is only measured — choose from the table, add the row, run
again; one that is named is scored and written. `results-siglip.json` is the last scored run of
the default model. The first rule, exactly as it shipped (its prompts and margins are kept in
the harness as `V1`), is run on the same photographs for the "before" column.

**Measured on 2026-10-31** over the 233, FashionSigLIP v1 (bars 0.01 / 0.02 / 0.01) and
FashionCLIP (bars 0.03 / 0.04 / 0.035):

| | SigLIP zero-shot | FashionCLIP zero-shot (default) | Haiku |
|---|---|---|---|
| override precision (a stand-in that is a product shot) | **11/11 = 1.000** | **4/4 = 1.000** | not yet run (no key on the build machine) |
| override rate | 11/233 = 0.047 | 4/233 = 0.017 | |
| overrides to a close-up — before, under the first rule | 0 — 5 of its 23 stand-ins (precision 18/23 = 0.783) | 0 — 7 of its 38 (20/38 = 0.526) | |
| stand-ins found, of the 20 there were to find | 11/20 = 0.550 | 4/20 = 0.200 | |
| answer right (a right stand-in, or none where the lead is a shot or nothing is) | 224/233 = 0.961 | 217/233 = 0.931 | |
| style words right (precision) | 186/287 = 0.648 | 173/269 = 0.643 | |
| products with a right word | 137/199 = 0.688 | 129/199 = 0.648 | |
| products given any word | 184/233 = 0.790 | 174/233 = 0.747 | |
| photographs embedded beyond the leads | 85 | 43 | |
| time / cost | 130 s on a Mac / nothing | 149 s on a Mac / nothing | |

The same sweep, for the choice: SigLIP at 0.00 / 0.02 is also every stand-in right and finds
15 of 20, and at 0.00 / 0.01 its one wrong stand-in is STAUD's Teddy jean on a model's legs; the
bars are the step inside that, because a lead that reads as a person by nothing at all is not
"clearly" one and the prompts were tuned on these labels. FashionCLIP at 0.00 / 0.04 finds 10
of 20 with one wrong in twelve — the Natalie suede jacket, a model seen from behind, read as a
garment on a plain background — and below a shot margin of 0.04 its wrong stand-ins are all
people on white; 0.03 / 0.04 is the first pair with none. **On the 30 close-up products neither
model makes a stand-in** (the first rule chose a close-up on one of them), and 12 of the 30 lead
with a model, so the price of the rule is visible there too: three had a product shot to find.

**FashionCLIP reads photographs worse than SigLIP** — it finds a fifth of the stand-ins SigLIP
finds at the same precision, and confuses a person on a plain ground with a garment on one —
while reading text better (*The search eval*). The one sidecar serves both, so the model is
chosen for search and the reading takes what it gets; what it gets under the new rule is a
cover that is the shop's own photograph nearly everywhere, which is the safe side. If the
stand-ins matter more than the search's two points, the owner's switch back is the two
variables in `Embeddings/README.md`.

For scale: always answering "streetwear" would be right on 35 % of products, so the words are
about twice the base rate, and the misses are honest ones (a puffer read as grunge). **The
prompts, the margins, the weights and the bar were tuned on these same labels**, which flatters
both zero-shot columns — the margins were picked off the sweep above as the first pair with no
wrong stand-in — so expect a few points less on a fresh set, and expect the first wrong
stand-in on a new shop to be a model on a plain background rather than a close-up. Haiku gets
no tuning beyond its prompt — label a second set before switching on a small margin.

## AI

The rules are `docs/ai.md`; what the server's other parts need to know about it:

- **Switched like the embedding provider**: `AIService.make` in `configure` reads
  `ANTHROPIC_API_KEY` (or `AI_FAKE=true` off production) once, says on or off at boot, and
  stores the result as `Application.ai`. Nil is off, and every path asks that one value — a test
  sets it after `configure`, as it sets `embeddingProvider`.
- **Two tables' worth of schema.** `ai_pick_reasons` (`CreateAIPickReasons`): a pick's sentence
  under a unique `sha256` key, with no user or device column, pruned by the `Reaper` after thirty
  days. `events.sale_ends_at` and `events.sale_terms` (`AddSaleReading`), nullable with no
  backfill, one column per `update()` for SQLite.
- **Background reading runs inside the poll pass** — a page in `Poller.enrich`, a banner in
  `SaleBanners.check` through `SaleEvents.announce(reading:)` — so it shares the pass's
  politeness and adds no request to a storefront: the page and the homepage were already being
  read. It adds seconds to a pass where it runs, which is why it is two pages a pass and one
  banner per new sale, and why the owner's daily cap stops it outright.
- **Owner spending is `ai_costs` rows with neither key**, summed since midnight UTC
  (`AIBackground.spentToday`, `CAST(… AS BIGINT)` like every other sum here). Pick sentences
  count against the same cap.

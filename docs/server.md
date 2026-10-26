# Server specifics

Part of the streetw guidance set; see `CLAUDE.md` for the index and the build rules.

## Server specifics

- **The catalog is global.** Brands, sources, products and variants are one row per
  real-world thing; only users, devices, follows, size profiles, watches and poll hints are
  personal. Never add a `user_id` to a catalog table — polling once for everyone is the whole
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
  products unseen for `PRODUCT_RETENTION_DAYS` *with no events left* are eligible.
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
    catalogue, whose prices are whatever they were when last seen; older stock nobody re-reads is
    the roadmap's Phase 3 blind spot.
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
- **A brand's main shop is the brand row; a country's shop is a `storefronts` row**
  (`StorefrontModel`, `CreateStorefronts`, `Storefronts`). Big retailers run a shop per country —
  Victoria's Secret UK is a different company from the US one — so a brand maps to its storefront
  per country: a base URL, an ISO country, a currency and **its own sources**. `sources`,
  `products` and `events` carry a nullable `storefront_id`, and **null is the main shop**. Five
  details are load-bearing:
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
  - **A country's storefront is polled only while somebody there follows the brand**
    (`Storefronts.wanted`): its country is switched on and a follow's user has that
    `users.country`. Worked out once per tick, and applied in the claim itself
    (`storefront_id IS NULL OR storefront_id = ANY(wanted)`), so a paused storefront is never
    claimed, never fetched and never pushes its schedule forward. **The main shop's sources are
    claimed exactly as before** — `PollerStorefrontTests` counts the requests. Its product pages
    are read by `enrich` under the same rule.
  - **A storefront that sat idle re-baselines** (`Storefronts.resumeAfter`, a day). Nothing
    polls a paused storefront, so the first read after a pause compares against whatever it
    knew months ago — and would announce every product and restock since as news to the first
    follower back. Nothing else ever leaves a source unread for a day: the longest backoff is
    six hours.
  - **A caller is served a country's storefront only when it is live** — the country is
    switched on, somebody there follows the brand, and it has been baselined
    (`Storefronts.serving`). Otherwise the main shop, exactly as before. One rule for
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
- **A storefront is attached by hand** (`POST /admin/brands/:id/storefronts?country=GB&url=…`).
  It runs ordinary discovery on the URL, through the poller's fetcher, and refuses three
  mistakes: nothing watchable there; **the same catalogue as the main shop** — a Shopify Markets
  subfolder like `/en-gb/` is read off the host, so it would be the main shop again in its
  currency (reading those is not built); and a shop whose `/meta.json` says it does not ship to
  the country, unless `&force=true`. Measured: Kith's US shop ships to 197 countries, `eu.kith.com`
  prices in EUR and ships to 48, and Palace's `www.` prices in GBP and ships to five — GB, GG,
  IM, JE, PH. `/meta.json`'s own `country` is where the *merchant* is (`eu.kith.com` says FR), not
  who it sells to, and is not read. Attaching a country that already has one replaces it;
  `POST /admin/brands/:id/storefronts/:country/delete` removes one, cascading its sources,
  products and events. Nothing discovers country storefronts automatically.
- **`HTTPFetching`, not `HTTPClient`** — Vapor re-exports `AsyncHTTPClient.HTTPClient` and
  an unqualified collision in the server target is nastier than the wordier name.
- **Don't name a test helper `withApp`.** VaporTesting exports a generic `withApp<T>` that
  does *not* run `configure`. A single-statement test closure lets Swift infer `T` from
  `test(...)`'s discardable return and silently pick that overload — the app comes up with
  no routes and everything 404s, while multi-statement closures resolve to yours and pass.
  The local helper is called `withServer`.

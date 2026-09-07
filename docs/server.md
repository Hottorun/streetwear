# Server specifics

Part of the streetw guidance set; see `CLAUDE.md` for the index and the build rules.

## Server specifics

- **The catalog is global.** Brands, sources, products and variants are one row per
  real-world thing; only users, devices, follows, size profiles, watches and poll hints are
  personal. Never add a `user_id` to a catalog table — polling once for everyone is the whole
  design. (`watches` points *at* a product without owning it, exactly as `follows` points at a
  brand, and `poll_hints` at a brand's *schedule* without owning that either — a hint changes
  cadence and is never read back to anybody but the device that wrote it.)
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
- **Only the *unexpected* is worth a buzz** (`Notifier.isWorthWaking`). A drop, a collection and
  a storefront lock happen suddenly, are worth acting on within minutes, and cannot be found any
  other way. A **restock**, a **price drop**, a **page change** and a **post** are not: the first
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
  into something the server can act on.
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
- **`HTTPFetching`, not `HTTPClient`** — Vapor re-exports `AsyncHTTPClient.HTTPClient` and
  an unqualified collision in the server target is nastier than the wordier name.
- **Don't name a test helper `withApp`.** VaporTesting exports a generic `withApp<T>` that
  does *not* run `configure`. A single-statement test closure lets Swift infer `T` from
  `test(...)`'s discardable return and silently pick that overload — the app comes up with
  no routes and everything 404s, while multi-statement closures resolve to yours and pass.
  The local helper is called `withServer`.

# Keeping it fast

Part of the streetw guidance set; see `CLAUDE.md` for the index and the build rules.

## Keeping it fast

Every rule here was written after measuring, and each names the thing it was measured
against. They are cheap to break by accident and expensive to find again.

**Derive once per `body`, and pass it down.** A computed property in a SwiftUI view has no
memory: every read redoes the work, and SwiftUI evaluates bodies constantly and for reasons
that have nothing to do with your data. Found live in five screens at once — `StyleView`
built the whole `StyleProfile` **nine times** per render and `FitSuggestions` three;
`SavedView` re-ran its filter chain once per *realised tile*, because `isMixedBrand` was read
inside the `ForEach` closure; `CollectionReleaseView` walked a brand's entire catalogue six
times through `Brand.members(of:)`, and `CollectionCard` four more *inside the feed's
`LazyVStack`*; `ProductDetailView` and `SaveDetailView` rebuilt a sneaker's variant list four
to six times. The pattern that works is the one `FeedView.Feed` already used: one struct,
computed at the top of `body`, threaded into the sections as a parameter. **Watch for a `let`
scoped inside a `ScrollView`'s content builder** — a modifier applied *outside* it re-reads
the property, which is exactly what `BrandFeedView` was doing with `.onChange(of:)`.

**…and for the expensive ones, once per *change*, which is a much smaller number.** Deriving
once per `body` was the right correction and it stopped short: `body` runs far more often than
the collection changes. `StyleView`'s three `@Query`s are unpredicated, so it rebuilds on *any*
`context.save()` — and `ImageTagger.analyzePending` saves once per batch of twelve while it
drains, so analysing two hundred saves rebuilt the whole `StyleProfile` and every
`FitSuggestions` pairing seventeen times over, on the main actor, while somebody was reading the
page. Opening Settings did it again, for a sheet. `StyleView.ReadingMemo` keeps the answer behind
a fingerprint that is cheap in the way the builds are not — one walk over already-faulted scalars,
no classification, no string scanning. Two rules for the fingerprint: it must contain
`analyzedAt`, `visionVersion` and `cutoutVersion`, because the photograph analysis landing is
precisely what changes the reading; and it must **not** touch `update.brand`, because faulting a
relationship per save per `body` is the cost being avoided. Held in a plain reference type rather
than `@State`, so the memo is invisible to the dependency graph — `@Query` already decides when to
invalidate. `FitCanvas` needed the same treatment for a simpler reason: `wearable`, `trayItems`,
`traySlots` and `drop` were four computed properties reading each other, and `traySlots` runs
`GarmentClassifier.classify` over the whole collection (a slot is computed, not stored) — so the
chip row classified every save on every pass and the filter did it again.

**A `@Query` with no predicate subscribes the view to the whole table.** Both halves of that
cost. `SimilarItems` fetched every event ever synced and scanned it in `body`, three times per
push, because `onAppear` and `StockRefresh` each save. And `ContentView` — the *root*, owning
all four tabs — held one whose only reader ran once per launch, so every `Brand` write rebuilt
the app's entire view tree. `FeedView.markSeen` stamps `brand.lastOpenedAt`, which is why
marking one brand read was felt on every screen at once. Narrow it, cap it with `fetchLimit`,
or ask a `FetchDescriptor` once in a `.task` and hold the answer in `@State`.

**Walking a to-many relationship faults the whole thing in.** `brand.updates` is the brand's
entire catalogue, so `Brand.unseenCount(matching:)` per visible row was a full catalogue walk
per row. The fix is always the same shape: ask the *store* the narrow question
(`#Predicate<BrandUpdate> { !$0.isSeen }`) and group in memory once for every row. Likewise
`BrandDetailView.savedFromBrand` tested `!$0.saves.isEmpty` over the catalogue to find three
saved rows — read it off `SavedItem` instead, which is proportional to the answer.

**Nothing decodes an image on the main thread.** `UIImage(data:)` produces no pixels; it wraps
a data provider and the real decode happens inside the CoreAnimation commit, on the main
thread, at first draw. So the app had *no* off-main decoding anywhere despite loading
asynchronously throughout. `ImageLoader.decode` uses `CGImageSourceCreateThumbnailAtIndex` with
`kCGImageSourceShouldCacheImmediately` (forces rasterisation on the calling thread) and
`kCGImageSourceThumbnailMaxPixelSize` (caps hosts `ImageRendition` cannot rewrite — Palace ships
3200² PNGs, a 41MB bitmap). Keep `kCGImageSourceCreateThumbnailWithTransform`: `UIImage(cgImage:)`
carries no EXIF orientation. **An image cache is budgeted in bytes, never in count** — the same
cache holds 130pt tiles and 1600px zoom renditions, and a count limit over that range is a
gigabyte. And local files get cached too (`LocalImage`): `BrandUpdate.cutoutURL` used to argue
that `UIImage(contentsOfFile:)` should be re-read each time *because* it decodes lazily, which
is backwards — a fresh `UIImage` per call is a rasterisation CoreAnimation can never reuse, and
`FitCanvas` reads one per piece per **frame** of a drag.

**A failure is a result too, and it used to be the only one nobody cached.** `ImageLoader`
retries a failed load twice with a backoff (300ms, then 900ms) and then throws the result
away, so the next appearance of the same tile pays for the same three requests and the same
1.2 seconds of sleeping — and `.task(id:)` fires on every appearance, so scrolling a grid back
and forth re-ran it per row. Invisible while everything resolves; loud the moment one host does
not, which is not exotic: a domain blocked by a DNS filter, or `BrandMark.fallback`'s guess at
`/favicon.ico` on a Shopify store that 404s it. `ImageLoader.refusals` remembers a refusal and
throws immediately inside the window instead of asking. Two windows, because the two classes
are not alike: a 4xx or bytes that will not decode are settled answers and are believed for
half an hour, while a timeout or a dropped connection is believed for a minute, doubling per
consecutive failure up to the same half hour. **Cancellation is never recorded** — a fast
scroll must not teach the loader that everything it passed is broken — and a success clears
the entry outright.

**Anything called per variant, per row, or per pixel earns a second look.** Three found by
measurement, all invisible in a profile taken on a small store:
- `SizeNormalizer.normalize` is regular expressions all the way down and
  `range(of:options:.regularExpression)` compiles a fresh `NSRegularExpression` every call. An
  apparel size costs 0.3µs because the word table answers first; a shoe size costs 17µs and a
  multi-axis variant title 26µs. It is called twice per variant by `SizeRun.entries` and again
  per variant by `SizeProfile.matches` — **3.2ms for one 48-variant card**, on every body
  evaluation. Memoised (the input space is a few hundred strings and repeats relentlessly) and
  the patterns compiled once: 0.10ms, a 31× improvement.
- `GarmentClassifier.match` rebuilt six `Set`s from `table` on every call, and `classify` calls
  it once per field — 78 set constructions for a product with ten tags.
- `GenderClassifier` ran three `replacingOccurrences` per field for a phrase list that only
  ever matches "baby", and built a throwaway `[String]` per field. 52µs → 29µs.

**A comparison sort reads its keys n·log n times, and a SwiftData property is not a stored
property.** `BrandUpdate.oncePerProduct` sorted the models directly, so `newestFirst` read
`publishedAt` — and on a tie `externalID` — through the persisted accessors on *both* sides of
every comparison: about seven thousand reads for a 400-product brand. Measured against a real
Kith catalogue on an iPhone 17 Pro, that was **18–22ms, and 97% of the derivation it sits in**;
faulting `brand.updates` cost **0.0ms** (the relationship is already cached) and filtering 400
rows cost 0.4ms. Decorating first — one pass pulling the keys into plain value tuples, sort
those, map back — is 3.0–3.4ms for the same answer. This is the hot path behind "marking
something read in +N more lags": one mark-read is two body evaluations, so **44.3ms → 8.2ms**,
from four dropped frames at 120Hz to none. Every list of a brand's output goes through it.

**…and the obvious fix was the wrong one, twice.** `BrandFeedView` looked like the `FeedView`
bug — a view walking `brand.updates` — so the first attempt was the same cure: a `@Query` on
`BrandUpdate` narrowed with `#Predicate { $0.brand?.id == brandID }`. It made the page **three
times slower** (54–92ms), because the relationship traversal becomes a correlated subquery while
the relationship it replaced was already free. Memoising behind a fingerprint was the second
idea and buys almost nothing once the sort is cheap. The lesson is the one this section keeps
restating: instrument the phases before choosing a fix, because "it walks a to-many
relationship" and "it is slow" turned out to be unrelated facts about the same function.

**A guard that short-circuits belongs in the callee, not at six call sites.**
`BrandUpdate.passes` reads `gender`, which re-runs the classifier whenever the stored revision
differs — the steady state for anything the server classified. `SizeProfile.allows` returns
true immediately for `.everything`, but Swift evaluates the argument first, so the classifier
ran regardless. `FeedView` guarded its own call site with `if filterGender` and nothing else
did, so every other list paid the full classifier per row for a filter that was switched off.

**Guard a write that changes nothing.** `context.save()` invalidates every `@Query` in the
app. `ProductDetailView.onAppear` set `isSeen = true` unconditionally, and `onAppear` fires
again on every return to the page — the most expensive possible way to do nothing.

**Verify on a real store, by driving the app.** The numbers above came from a benchmark in the
package plus `simctl` and a `CGEvent` clicker against a store of three brands and 470 updates
(see *Driving the simulator UI*). Marking Kith's **388 unread rows** read now lands in **0.10s**
from tap release to the change being visible in SQLite. Poll the store directly to time an
interaction — screenshots are far too coarse:

```bash
DB="$(xcrun simctl get_app_container "$DEVICE" com.kern.functional.streetw data)/Library/Application Support/default.store"
sqlite3 "$DB" "select count(*) from ZBRANDUPDATE where ZISSEEN=0;"
```

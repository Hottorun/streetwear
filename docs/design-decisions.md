# Deliberate design decisions

Part of the streetw guidance set; see `CLAUDE.md` for the index and the build rules.

## Deliberate design decisions

Changing these silently will break intended behavior:

- **Instagram is never scraped.** `BrandSource.Kind.instagram` has `isAutomatic == false` and
  `SourceAdapters.adapter(for:)` returns `nil` for it — it is a stored deep link only. Aggregating
  arbitrary public profiles isn't permitted and unofficial endpoints break constantly.
- **The feed's unit is the event, not the product, and there are four tabs because of it.**
  It was shaped like a product list: each brand led with its newest *garment* printed full
  width and square, with the reason for it set as a caption in tracked caps under the
  wordmark. That is the wrong shape for what the screen holds. Restocks and re-shelvings are
  most of its volume — the whole reason `Reshelving` exists — and they are the same events
  `Notifier.isWorthWaking` refuses to send a push about, so the quietest thing that can
  happen was being handed the loudest slot the app has. A brand whose only news was six
  restocks got a full screen of one shoe.
  A brand's spread is now a short stack of **stories**, one per kind, ranked by
  `UpdateKind.newsRank`: a lock, a release, a drop, then the quiet kinds. Each states what
  happened in words ("14 new products", "4 price cuts") and carries its garments as
  evidence — one row of three, with the rest folding into the link at the foot.
  Three things are load-bearing. **Only a sudden kind earns the lead photograph**
  (`UpdateKind.isSudden`), which is what actually changes the page: a quiet story is a
  headline and one row you can scan past, where a drop still opens out. **The ordering is
  fixed, never derived from counts** — a rank computed from how many of each landed would
  reorder a brand's spread as its items are read, which is the property `FeedView`'s brand
  ordering exists to protect. And `isSudden` **is** `Notifier.isWorthWaking`: the switch
  moved into `StreetwCore` and the server calls it, because two copies of a seven-case
  judgement is how the feed ends up leading with the thing the push deliberately stayed
  silent about. The lock story is synthesised from `Brand.isLockedForDrop` rather than from
  an unread `.dropLock` row, since a storefront can be locked with its event already read.
- **Every count on a spread opens the list it counts, and the headline is the door.** A spread
  said *7 new products* and *8 things are back*, printed three tiles of each, and offered one
  link out — "+8 MORE FROM BBC" — which went to **all fifteen mixed together**. So the page
  could name two different pieces of news and open neither, and the number in the link
  described a remainder while its destination was the total: a small lie you only catch by
  reconciling the page you land on against the one you left. The rule that used to sit here
  said the link is per brand rather than per story, because four links under four headlines is
  a menu. That is right about *adding* four controls and is not what this does — the headline
  is already on the page, already states the count, and is already the only line naming what
  you would ask for, so tapping "7 new products" to see seven new products adds nothing but a
  chevron (`BrandFeedRoute.kind`, `BrandSpread.headline`). Four things follow. The sentence
  lives on `UpdateKind.headline(count:)` because the feed and the page it opens both print it,
  and a tap has to land under the words that promised it. **A headline with no row behind it
  is not a link** — the `.dropLock` story is synthesised from `Brand.isLockedForDrop` and often
  stands for nothing unread, and a link onto an empty filtered page pushes and pops itself,
  which is a tap that visibly does nothing. **"Mark all seen" clears the story it is looking
  at, never the spread** — a checkmark on a page headed "7 new products" must not also swallow
  eight restocks. And the foot link now says **"ALL 14 FROM …"**, because the total is what it
  always opened.
- **Brands is not a tab, and the brand rail is what replaced it.** It was a directory — a
  list of names, with no news in it and nothing that changes — beside three tabs that are
  all about change, while the feed below already grouped by brand and every wordmark in it
  already opened the brand page. Its only exclusive jobs were reaching a brand that has
  published *nothing unread* (most of them, most of the time) and adding one. Both are now
  the rail at the head of `FeedView`, and `BrandsView` survives behind "ALL" as a sheet
  because it holds the one thing a mark cannot say: which sources a brand is watched with,
  and whether any of them is failing. What is left is an honest set — **Feed** (what
  happened) · **Discover** (what's new to you) · **Saved** (what's yours) · **Style** (what
  that says about you). Notes on the rail: it is **alphabetical, never by activity**, because
  it is the one strip on the page whose job is to be aimed at and a rail that reorders as
  brands publish is a set of moving targets — `DiscoverDeck.pinningRead`'s lesson, met on a
  new surface. The unread mark is a **dot, not a number**: the spread below and the brand
  page both state the count, and a third figure to keep in agreement buys nothing; it is read
  off the groups the feed just built, so a brand whose whole unread queue is hidden by the
  gender filter is silent here too. A horizontal scroller is acceptable here for the reason
  `BrandDetailView`'s carousels were not — a rail of *marks* is skimmed at a glance, where a
  strip of *garments* can only be read a tile and a half at a time. And **add is the first
  tile, not the last** — it went in at the tail on the theory that the brands are the subject
  and adding one is the afterthought, which is true of the rail and false of the control: the
  rail scrolls, so the tail is wherever the last brand happens to be, and with a dozen
  followed, adding one meant swiping to the end of a strip to reach a button that never
  moves relative to anything visible. At the head it is in the same place at every collection
  size. `Tabs.resolve` maps the now-dead `-startTab brands` onto the feed, because a
  `TabView` whose selection matches nothing draws a blank page.
- **There is no refresh button, and the feed's toolbar is what it cost** (`FeedRefresh`). Four
  icons sat above a page whose whole subject is photographs, and only three of them were doors
  onto anything — the fourth was asking the reader to do the app's job, since a feed that has to
  be *told* to check is one that is quietly out of date until you tell it. Coming back to the
  app is the moment the question is actually being asked, so `scenePhase == .active` answers it
  before anybody has to; pulling down is the impatient case and was always attached, so the
  button was a second way to do a thing the list already did and the only one of the two taking
  up room. **The two throttles differ by an order of magnitude and that is the point of the
  type**: in server mode a refresh is one request against a poller that has already fetched for
  everybody (60s), while standalone the phone fetches every followed storefront itself, so the
  interval is the *brand's* cadence rather than the reader's patience (20 min) — a foreground
  pass every few minutes would be this app hammering shops it is a guest of. A pull is somebody
  saying "look now" and is never throttled. Two consequences worth keeping. The `CHECKING` pill
  now answers for the **remote** sync as well, because a check nobody asked for needs saying
  where one they did already has the platform's spinner attached to the finger that started it —
  and silence during it is the same screen as "nothing happened". And the bell follows the
  markdowns icon's rule: **drawn only once a watch exists**, since a watch is never set from
  here (it is set on a product page, from the save confirmation, from a sold-out share) so the
  icon is the way *back* to a list, not the way into a feature. The test is *any* watch, not any
  active one — `WatchesView` keeps fired ones under "CAME BACK", and an icon vanishing the moment
  the thing you waited for arrives would hide exactly the news it exists to carry. The calendar
  is the one icon always drawn, because it is the only route to the drop calendar at all:
  showing it only once a drop is written down means it appears only after you found the way to
  write one down, which is through it.
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
  every row. The markdowns badge is the same obligation: `BrandUpdate.markdownDismissedAt` narrows
  `MarkdownsView`'s query *and* `FeedView`'s badge query, or waving markdowns off empties the sheet
  while the badge that opens it goes on claiming twelve.
- **Dismissing a markdown is not marking it seen, and the two must stay separate.** The markdowns
  list exists precisely because it is *not* emptied by reading things — the feed is ordered by
  recency and a price cut is worth as much a week later as it was on the day — but that left a
  standing list with no way to shorten it, which turns it into wallpaper. So `markdownDismissedAt`
  is its own verdict, set only from that screen, leaving the product in the feed and on its brand
  page. `SyncEngine` clears it when it writes a *new* `.priceDrop` on the same row, because a second
  cut is a new markdown: that path rewrites the row rather than inserting one (in server mode every
  event is its own row and the question never arises), so without it, waving off a 10% cut in March
  would silently swallow the 40% cut in June.
- **A brand page is that brand's catalogue, and its counts are the way into it**
  (`BrandDetailView`). Two things were wrong with what was there. It was two **horizontal
  carousels**, so seeing a brand's output meant swiping a strip sideways one and a half tiles at a
  time — the one gesture that cannot be skimmed, on the page most likely to be browsed rather than
  read. And "Recent" was capped at twenty, which on a brand mid-season is a single poll's worth:
  the app held 400 Kith products and showed a dozen, so *what does this brand make* — the question
  the page exists to answer — was the one thing it could not. It is a two-column `LazyVGrid` over
  everything now, uncapped because a lazy grid builds only the screenful you are looking at, and
  the tile carries the price and the size run rather than the title alone (`CatalogueTile`, not
  `FeedTile` — that one is a third of a feed page and is competing with a lead above it).
  `UpdateCarousel` and `EmptyStateView` were deleted with it; this was their only caller.
  **The three counts are the filter.** Catalogue, unread and kept already described exactly the
  three lists the page can draw and sat above a grid you could not point any of them at — same
  criticism `StyleView`'s taste block answered by making each word a query, and the same
  obligation: each number is the length of the list it opens, or the page tells two stories about
  one shelf. So `UNREAD` deduplicates over the **unread rows** rather than filtering the catalogue,
  which is what makes it agree with the feed and with `Brand.unseenCount(matching:)`; and `KEPT` is
  deliberately *not* filtered by `passes`, because those are things somebody chose and hiding one
  for a setting changed afterwards would be the app editing their own collection.
- **Every row of Upcoming names a brand, so every row opens it.** That page answers "who is about
  to drop"; the next question is always "what have they been doing", and the wordmark at the top of
  each row was inert — the only route to the brand was to dismiss the sheet and go looking. A
  locked storefront in particular is the strongest signal in the app and the moment somebody most
  wants the page. Note the sheet needs its **own** `appDestinations()`: a destination registered on
  the feed's stack is invisible from inside a presented one, and the failure is a link that does
  nothing, silently.
- **`FeedView.feed` is one pass, and that is a correctness property as much as a speed one.**
  Marking a brand read writes a row per update and saves, which invalidates the `@Query` and
  re-renders — and the view then answered four more questions on the way back, each a full walk of
  every brand's `updates`, each calling `passes`, which reads `gender`, which **re-runs the
  classifier whenever the stored revision differs from this build's** — the steady state for
  anything the server classified. So dismissing one brand cost thousands of string classifications
  before a frame could be drawn, which is the reported lag. Anything added to that body walks the
  relationship once or not at all.
- **…and the pass is over the unread queue, which the *store* narrows.** One pass was not enough on
  its own. The view queried `Brand` and walked `brand.updates`, which faults in the whole catalogue
  — every product ever synced, read or not — where the question was only ever about the unread few:
  measured on a real store, 1.4s for the first build and 44–426ms for every rebuild after, and
  marking a brand read *causes* a rebuild. `FeedView` now holds a `@Query` on
  `#Predicate<BrandUpdate> { !$0.isSeen }`, which SQLite answers from an index, and groups by brand
  in memory. `markSeen` reads out of that same array for the same reason — touching
  `brand.updates` to clear one spread faults the brand's entire catalogue on the tap whose slowness
  is the complaint. The markdown badge is the third case: its window is thirty days, which on a
  freshly added brand is the whole store, so it narrows on `previousPriceAmount != nil` — written
  only where `kind` becomes `.priceDrop`, so it is a faithful index for the question — and confirms
  the kind in Swift, because a marked-down product that later restocks keeps the old price.
- **The feed orders brands by their newest activity, never by their newest *unread* item.**
  A key computed from unread items changes as you read them: clear the top card of a brand whose
  remaining unread things are older and the brand's key drops to that older date, so the whole
  spread slides down the page under brands you had already dealt with. You are reading a list that
  reorders itself under your thumb. `Brand.lastActivityAt` is stored — maintained by everything that
  writes an update, which includes `SyncEngine.refresh`, since a restock and a markdown are written
  by *rewriting* an existing row rather than inserting one and would otherwise not move the brand at
  all. It only ever advances: a late-arriving old row does not make a brand less recently active.
  `BrandGroup.latest` is still the newest unread date, because that is what the header stamps — two
  different questions that were being answered by one value. Ties break on the brand name, the same
  reason `BrandUpdate.newestFirst` breaks its ties.
- **A stored classification that keeps re-deriving has to be written back.** `Classification`
  settles stale `genderVersion` rows in bounded batches after a sync and on foreground. It
  recomputes *locally* and stamps the local revision, which is honest — the prohibition below is on
  stamping the local number onto a **server-supplied** raw value, which freezes somebody else's
  verdict forever. `settleActivityDates` is the same pass for `lastActivityAt`: it is nil on every
  brand followed before the field existed, `Brand.activityKey` falls back to walking that brand's
  whole catalogue, and nothing else would ever write it — so a brand that has published nothing
  since the update pays that walk on every render, forever.
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
  headline and the garments are the contents. **A collection's contents are read, not guessed, and the
  contents are what decide whether it is announced at all.** `/collections.json` names a release
  and does not list it, so `Brand.members(of:)` used to match a distinctive word from the title and
  fall back to anything published within 36 hours — defended as a heuristic whose alternative was a
  network call per card in a scrolling feed, and whose cost was "a page with a few extra garments".
  Both halves were wrong. The call belongs in the *poll*, once, which is where `CollectionsSource`
  now makes it (`/collections/<handle>/products.json`), and the cost was not a few extra garments:
  Corteiz announced ISLAND PUFF PRINT TRUCKER HAT — six colourways of that hat — and the page listed
  five ALWEIZ board shorts, a ripstop bag and a bucket hat under "5 PIECES", not one of them in the
  collection. A release page states what is in a release, so a loose match is not a worse answer, it
  is a false one. `FetchedItem.memberExternalIDs` carries it, `FeedItem` puts it on the wire, and
  `Brand.members(of:)` prints **nothing** when it has neither a real list nor a word match — an
  empty strip beats a wrong one.
  **And the same list answers "is this a release".** `Release.isRelease` demands a season or a year,
  which is right for Discover and would refuse a real collab in a followed brand's feed; reading the
  *title* was the mistake, since a collection list is mostly furniture named by a merchandiser.
  `Release.isAnnouncement` asks the stock instead: **a release's contents were shelved when it was
  announced, a navigation rail's were not.** A third of members within 30 days, measured — the real
  ones sat at 43% and 100%, the rails at 0%, 0%, 0% and 11%. `publishedAt`, never `createdAt`
  (brands build a product record a season ahead). Three guards around it: a baseline poll verifies
  nothing (nothing is announced, and Amiri has 250 collections); past `membershipBudget` a poll
  stops announcing, because seven collections between two polls is a theme re-stamp and not seven
  seasons; and a storefront that fails to answer is announced unverified rather than losing a real
  drop to one request. `withoutSubsets` then collapses a launch merchandised as overlapping rails —
  Amiri's BISCOTTO BAG (8), BABY BISCOTTO BAG (4) and BISCOTTO SHOULDER BAG (4), where both fours
  sit inside the eight. Verified live against five storefronts: one correct release each, or none.
  **`members(of:)` admits `.product` only where it is *guessing*, and any garment row where it has
  been told.** The word match filtered on `kind != .collection`, which lets in every other kind of
  event — and a release lands in the middle of ordinary trading, so the window swept up restocks of
  last season's stock and price drops off the sale rail and printed them as the contents of a new
  collection. That argument is correct about a guess and simply false about a list the shop
  published: applying the filter to a stated membership is refusing to believe the shop, and BBC is
  the proof. Its Yankees collection is 29 garments, 14 shelved within the fortnight, and every one
  of those 14 carries a product record 181 days older than its shelving — so `Reshelving` files all
  fourteen as `.restock`, the filter excluded every one, and the card could never fill for a
  collection sitting on the storefront in plain sight. A re-merchandised collection is most of what
  a brand announces. Nothing that is not a garment can slip into the stated path, because the join
  is on the id list and a page change carries no `shopify:<id>`.
- **One release, stated once in a spread.** Billionaire Boys Club announced its Yankees edit three
  times in one spread: `/collections.json` gave the release, `/products.json` gave two tees the
  ±36h window had wrongly filed inside it, and the brand's own blog gave the announcement — three
  sources, three kinds, three buckets, and nothing in `BrandSpread.layout` had ever been in a
  position to notice any of them were related. (The tees were never in that collection at all,
  whose 23 members are all Yankees pieces — which is the membership bug above, not this one.) It now drops `.product` rows the release card
  above them is already drawing, and a `.post` whose title restates a `.collection` in the same
  spread. **Both rules must ask the question the card asks, not a tidier one.** The first attempt
  read `memberExternalIDs` alone — empty on every collection stored before the poller could read
  one, so on the brands actually in front of somebody it folded nothing, and Represent went on
  printing "9 pieces in this release" above "9 new products" showing the same nine garments. It
  follows `Brand.members(of:)`'s order now (stored membership, else the word match, else nothing),
  matched against the spread's own products rather than the brand's catalogue, so a card showing
  nothing folds nothing. The post rule strikes out the brand's own name first — nearly every post a
  brand writes names it — then wants two shared words with at most one the post added, because a
  headline adds words to a page name and a strict subset test folds neither "… Is Here" nor
  "Introducing the …". Neither hides anything the spread was not already showing, both still count
  as unread, and the foot link's total is untouched.
- **A collection is offered to the merge exactly once in its life, so the membership has to be
  fetched again for the ones already stored.** `/collections.json` is filtered by `since`, which
  means reading the real contents at poll time reaches only collections published from that deploy
  onward — every release already on a feed keeps falling back to the word match. The first thing
  that fix did in the wild was empty BBC's Yankees card, whose 23 real members share no word with
  its title. `Poller.fillMemberships` and `SyncEngine.fillMemberships` go back for three per brand
  per poll inside a 45-day window, filtered in Swift because "an empty array column" is not
  something Fluent expresses the same way on Postgres and SQLite; `RemoteSync.backfill` carries the
  result to the phone.
- **A price cut states itself and does not spend a row.** `MarkdownsView` exists precisely because
  the feed is the wrong home for markdowns — it is ordered by recency and a cut is worth as much a
  week later — which is why that screen is not emptied by reading and keeps its own
  `markdownDismissedAt`. It has its own badge and its own way in, so three tiles of the same thing
  under every brand was one list said twice, at a third of the height of a spread whose subject is
  what just dropped. The headline stays and stays a link, per the rule that every count opens the
  list it counts; the evidence row goes, because a markdown is a claim about a *number*.
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

# Deliberate design decisions

Part of the streetw guidance set; see `CLAUDE.md` for the index and the build rules.

## Deliberate design decisions

Changing these silently will break intended behavior:

- **Instagram is never scraped.** `BrandSource.Kind.instagram` has `isAutomatic == false` and
  `SourceAdapters.adapter(for:)` returns `nil` for it — it is a stored deep link only. Aggregating
  arbitrary public profiles isn't permitted and unofficial endpoints break constantly.
- **Three tabs, and everything about the person behind the avatar** (`ContentView`, `YouRoute`,
  `YouView`; Phase 1). **Feed** (what happened at your shops) · **Shop** (what to get next) ·
  **Saved** (what's yours) — and a person symbol top right on every tab (`.youButton()`). Style
  was the fourth tab and was never a place: a reading of somebody's taste, two rows of fits and a
  settings gear. Its fits are Saved › Fits (`docs/fits.md`), and the reading leads You, followed
  by the sizes, the brands followed, what somebody is waiting for and then the settings that were
  behind the gear — alerts with their delivery status, the style statement, about. The brand list,
  the watches and the calendar were sheets behind icons and a link on the feed, a screen whose
  subject is what has happened; none of them is news, and all of them are things the person set.
  The decisions:
  - **One page, presented once, from the root.** The avatar on any tab sets `YouRoute.isOpen` and
    `ContentView` presents the sheet — not a sheet per tab — because a facet tapped in the taste
    reading has to close You *and* change tab, and only the root knows there are tabs. Built in
    `streetwApp.init` with the other routes, so a tab never reads an environment object that is not
    there yet. `.youButton()` goes on a tab's root **before** its own `.toolbar`: SwiftUI lays a
    trailing group out outermost-first, so applied after, the avatar came out ahead of Select. On
    iOS 26 a `ToolbarSpacer` gives it a circle of its own: it is not one of the page's actions.
  - **Set as type, not a settings form.** Paper, serif, mono and rules in a `ScrollView`; space
    between sections, never a rule under a row that already ends in one — two hairlines a few
    points apart read as a printing error.
  - **Sizes are a summary and a door.** One row per filled ladder as it prints
    (`SizeProfile.ladders`, which `summary` is made of), what is shown, and Edit sizes pushing the
    existing editor. `SizesSheet` is the same editor in a sheet of its own, because the
    feed's lines about the profile are about these two settings and nothing else.
  - **Following draws what needs attention, not the whole list.** Brands with a failing source get
    a row each (`Brand.hasFailingSource`, read off `lastError`, which travels on the wire), then
    "All brands" opens `BrandsView` and "Add a brand" the add flow. Somebody following forty shops
    would otherwise scroll past forty rows to reach their alerts, and a shop that had quietly
    stopped answering read exactly like one that had stopped publishing until somebody opened its
    page. On `BrandsView` the failing source is said on its row — `CATALOG FAILING · COLLECTIONS`,
    vermilion on the failing word alone — and the per-brand UNREAD count is gone: unread is "since
    you were last here" on the feed, and a second tally of it on a list of follows is a number to
    reconcile against a screen that no longer keeps one per brand.
  - **Nothing that is not built.** Sign-in, profiles, location and credits are Phase 2, and a row
    for each saying so would be four rows of the app talking about itself. The avatar is a symbol
    for the same reason: there is nobody to put in it until there is an account.
  - **Retired tab names still open something.** `Tabs.resolve` maps `discover` to Shop, `style` to
    Saved on its Fits strip (`Tabs.opensOnFits`), and anything else to the feed. The usage counts
    gained `tab.shop` and keep accepting `tab.discover` and `tab.style` from builds that have them.
- **The feed is one list of event cards, newest first across every brand** (Phase 1, `FeedView`,
  `FeedTimeline`). *Changed on purpose from 1.0*, which grouped the feed by brand: a wordmark header
  per brand, a stack of stories ranked by `UpdateKind.newsRank`, counts and "›" links under each,
  and a checkmark to clear the spread. Every piece of that was argued for in turn, and the sum was a
  first screen of five counters and three lines of links before its one photograph, whose name and
  price sat under the tab bar. The grouping existed to keep one busy brand from flooding the feed;
  that rule survives because **the event stays the unit**, and the things that happened *together*
  are still one card:
  - **a release** (`.collection`) is one card — a mosaic of its contents, "NEW · ALPINE CAPSULE",
    "6 PIECES · FROM $38" — and the garments it holds are not cards of their own, for the
    release's own window (`FeedTimeline.releaseWindow`, three days; a member restocked a month
    later is a restock). Membership is `Brand.members(of:)`'s order: what the storefront stated,
    else the word match. A post restating a release in the same window is folded (`FeedPass.restates`).
  - **a burst** — `burstMinimum` (3) or more events of **one kind** from one brand inside
    `burstWindow` (30 minutes), **anchored at the first** — is one card: a drop ("NEW", "24 PIECES ·
    FROM $38"), a wave of restocks, a sale rail of markdowns. Anchored, never chained, or a brand
    trickling one product every twenty minutes becomes a card spanning the day; the card keeps its
    id as the drop grows forward, so it is not rebuilt. The owner's rule was new products; restocks
    and markdowns group for the same flooding reason — Kith restocks dozens in one pass.
  - **a restock in your size is never folded** into a group or a release. "BACK IN YOUR SIZE" is the
    most specific thing the feed can say, and a "BACK IN STOCK · 12 PIECES" mosaic with it inside
    would bury it.
  - Tapping a group opens exactly the rows it counted (`DropRoute` → `DropPiecesView`), never the
    brand's catalogue — "24 PIECES" opening onto everything would be 1.0's "+8 MORE" lie again.
  - A lock is **not** a card: it is a state of the storefront, said by the line above the feed and
    under Upcoming for as long as it is true, where a card saying "drop imminent" would outlive the
    drop. A date ahead (a product published in the future) is Upcoming's too.
- **A card is a photograph, the brand, one label and the price — and no product name** (`FeedCard`,
  `FeedLabel`). The picture says what it is and the product page says the rest. **Every event gets
  a picture** — *changed on purpose*: 1.0 gave only a sudden kind the lead photograph, a rule about
  one large slot per brand that a grid does not have, and which left price cuts as a sentence with
  no picture. A product with no photograph shows the brand's wordmark (`UpdateImage.mark`), never a
  tile that looks like one still loading; a sale has no garment, so its card shows the brand's own
  marked-down stock, newest first. Labels, one per kind, in one switch so a new kind has to be
  decided: `product` NEW · `restock` BACK IN YOUR SIZE (vermilion, `SizeProfile.claims`) or BACK IN
  STOCK · `priceDrop` −30% with the "was" struck through beside the price, PRICE CUT when no cut can
  be measured, UP TO −40% for a group · `sale` the brand's own words said as a sale, "SALE 25% OFF ·
  CODE AUTUMN" · `collection` NEW · <NAME> · `dropLock` LOCKED · DROP IMMINENT (vermilion; Upcoming
  only) · `post` NEW POST · `pageChange` THE SITE CHANGED. A kind this build does not know never
  reaches the store (`FeedItem.knownKind`), and a kind added later fails to compile until it has a
  label and a filter. Vermilion only for your size and a lock: an accent on every card is none.
- **Ordering is two stored dates, and reading writes neither.** Cards are ordered by when their
  newest event happened (`publishedAt` — the event's time in both modes: the server's event, or
  standalone's rewrite stamping a restock with now), ties broken on the row's `externalID` the way
  `BrandUpdate.newestFirst` breaks them. Which side of the line a card falls is
  `BrandUpdate.arrivedAt`: when the row reached the phone **as news**. The two differ — a poll finds
  a product twenty minutes after it was published — and the line must be placed by arrival or a
  thing new to you sits under it. Within each side, newest event first. One garment is one card
  (`oncePerProduct`, keyed on brand and product), so a jacket that dropped Monday and came back
  Thursday is Thursday's restock. Since nothing a reader does touches either date, nothing on the
  page moves under a thumb — the property 1.0's brand ordering (`Brand.lastActivityAt`, still
  maintained, still the brand list's order) had to be argued for. A sync can add a card above the
  line or grow a drop; that is the feed being told something.
- **History has no arrival, so it is never in the timeline.** `arrivedAt` is nil for a brand's first
  sync, a catch-up after following, and anything a follow mode does not admit; it is stamped beside
  `isSeen` at every place that decides news (`SyncEngine.insert`/`refresh`, `RemoteSync.merge`,
  `WatchNotifier`). The 1.0 unread queue is adopted as news once, at launch, arriving when it was
  written (`FeedHistory.adoptLegacy`) — which is also the repair for any path that writes a row
  unread without stamping it: unread is news, whatever wrote it. The timeline reads the newest 500
  arrivals (`FeedView.depth`), because in server mode every event is a row and a `@Query` with no
  bound subscribes the view to all of them.
- **"Since you were last here" is one line, instead of per-brand unread state** (`FeedVisit`).
  *Changed on purpose*: no checkmarks, no dots, no "40 new from 6 brands", no swipe to mark a card
  read — somebody had to keep 1.0's feed empty for it to be useful. **A visit is the feed on screen,
  allowing gaps shorter than five minutes** (`resumeWindow`): a trip to a storefront to buy the
  thing, or a look at Saved, is the same visit; coming back after lunch is a new one. The line is
  drawn where the previous visit ended — the last moment the feed was on screen — and does not move
  during a visit. Above it, "↑ NEW SINCE YOU WERE LAST HERE · 5H AGO"; when nothing is new it heads
  the page, "NOTHING NEW SINCE YOU WERE LAST HERE". With no visit recorded — a fresh install, a
  phone coming from 1.0 — everything is above it and no line is drawn. A crash records no end, and
  errs towards showing too much as new.
- **What marks a row seen now: the feed going out of sight.** Whenever it does — another tab, the
  app leaving the foreground — everything that had arrived by then is marked seen
  (`FeedHistory.markShown`), except what the gender filter hid, which was never on screen. The feed
  no longer reads `isSeen`, but four things do and nothing marks anything by hand any more:
  `FollowedSupply` (Discover's unread from followed brands), a brand page's UNREAD, `SyncEngine.prune`
  (which never drops an unread row) and the product page. So `isSeen` means *the feed has had its
  chance to show this*: during a visit it is exactly what sits above the line. Opening a product
  page and saving still mark a row seen, as before; a fired watch and a standalone restock still
  make one unread, and now give it an arrival.
- **One row of filters: All · Drops · Restocks · Sales · Upcoming · Brand ▾** (`FeedFilterRow`,
  `FeedFilter`). It replaced the alphabetical brand rail and the three toolbar icons (calendar,
  markdowns with its system badge, the bell). Drops is new products, releases and page changes — a
  page watch moving *is* the drop on a storefront nothing structured can read; Restocks; Sales is
  markdowns and brand-wide sales, and replaced the markdowns list (`MarkdownsView` and its
  dismissal were retired: the timeline is not emptied by reading, which was that list's whole
  reason to exist); Upcoming is a list rather than cards; a post is under All alone. Brand ▾
  narrows any of them to one shop, lists quiet brands labelled with their mode (and says why one is
  empty), and ends with "Add a brand". **The row never truncates**: every label is its own width and
  the whole row scrolls when it must — the prototype pinned Brand at the edge and cut UPCOMING to
  "UPCOMIN". At the default size it fits a 402pt phone without scrolling.
- **The rail left the feed, and brands live under You › Following** — *changed on purpose*. Adding
  a brand is in the Brand menu, in the empty feed, and under You. `BrandsView`, `WatchesView` and
  `DropCalendarView` are no longer reached from here.
- **The future is one line above the feed, never a pinned card** (`UpcomingLine`). The soonest of: a
  storefront locked now (`Brand.isAnnouncingLock`), a date somebody wrote down, a product the brand
  dated ahead — inside two days (`UpcomingDrops.lineHorizon`): "● TOMORROW 10:00 · ONDO CLUB ·
  Summer capsule", vermilion when locked or under a day away, the point at which the calendar's
  countdown starts counting seconds. Tapping it opens Upcoming. The prototype pinned these as grey
  tiles with a calendar glyph, the largest object on the screen saying the least. Upcoming lists the
  same rows the calendar does (`UpcomingDropList`, `UpcomingDropRow`) — locks, dates the brand set,
  dates "ADDED BY YOU" — **without the rhythms** ("usually Fridays"), which are a guess and cost a
  walk of every catalogue; those stay in the full calendar under You.
- **There is no refresh button** (`FeedRefresh`). A feed that has to be *told* to check is quietly
  out of date until you tell it, so `scenePhase == .active` answers the question when you come back,
  and pulling down is the impatient case. **The two throttles differ by an order of magnitude and
  that is the point of the type**: in server mode a refresh is one request against a poller that has
  already fetched for everybody (60s), while standalone the phone fetches every followed storefront
  itself, so the interval is the *brand's* cadence (20 min). A pull is never throttled, and **runs
  its sync in its own task**: SwiftUI cancels a refresh action when the content under it changes,
  and a sync changes it at once, so every pull ended "cancelled". The `CHECKING` pill answers for
  both engines, and the sync-trouble line under the filters is still the one place a failed sync is
  said. The feed's toolbar holds only what every tab carries (the You button).
- **Saving from a card is the bookmark and the long-press menu; there is no swipe.** `SaveAction`
  sits on the photograph of a garment card and raises the save confirmation (Board, Notify);
  `UpdateMenu` is the long press. 1.0's quick-save swipe — right to mark read, left to file — went:
  a half-width card cannot be dragged sideways without covering its neighbour, and marking read is
  now what a visit does. A group, a release or a sale has no single garment and no bookmark.
- **`BrandUpdate.passes` is the one browsing filter, and every list calls it.** It said so in its own
  doc comment for a long time and had *no callers*: the feed applied `profile.allows(gender)` inline
  and `BrandFeedView` — which was where "+36 more from Kith" went — applied nothing at all. So a
  Menswear setting held on the feed and evaporated the moment you opened the rest of the same drop,
  which reads as the setting being broken rather than as one screen missing it. Gender hides; **size
  does not** — a size you don't wear is said in vermilion, not by removing the product, because a
  sold-out size today is the restock this app exists to catch. A new screen that lists a brand's
  output calls `passes`; it does not write its own copy of the rule.
- **"May this be shown" and "is this yours" are two questions, and one predicate was
  answering both.** `SizeProfile.matches` is the never-hide filter: it says *yes* whenever it
  cannot tell — an unreadable scale, a ladder nobody has filled in, no profile at all — because
  hiding a real drop is the one outcome it must never produce. Every label in the app was reading
  that as a statement about the reader. "IN YOUR SIZE", the vermilion rule under a token, the
  accent bar on a tile, "BACK IN L, S" and `availableInMySize` on the wire are **claims**, and
  answering a claim with the filter's optimism turns "we cannot read this size" into "yes, that is
  yours". A profile holding a bare `44` — `.other`, because 44 is as likely an EU shoe, an EU
  jacket or a waist, and only "EU 44" says which — had a run of 38 40 42 come back ruled in
  vermilion as the reader's sizes. An empty profile was worse: `matches` short-circuits on
  `isEmpty`, so the entire feed was marked as somebody's size before they had entered one.
  `SizeProfile.claims` is the strict half and is silent on every "don't know" — the opposite
  default, deliberately, because an unmarked size costs a glance at the run and a wrongly marked
  one costs the accent all its meaning. One-size is shown and not claimed: it fits everybody,
  which is not a fact about this reader. `Notifier` keeps `matches`, because waking somebody is
  the place where a false positive really is cheaper than a miss. Both questions are asked **in the
  product's `SizeContext`** — a "38" on a dress is a dress size, not a shoe — and both take it with
  no default; see *Sizing* in `CLAUDE.md`.
- **A count is subject to the same filter as the list it counts.** `Brand.unseenCount` counts
  everything unseen and no screen means that: the feed cleared to "all caught up" under a Menswear
  setting while the brands list still claimed 40 unread and the brand page still printed UNREAD in
  vermilion — about womenswear it had just decided not to show. Two screens describing one queue and
  disagreeing about its size reads as the number being broken. Every visible count calls
  `Brand.unseenCount(matching:)`; the unfiltered one survives only for a caller that genuinely means
  every row. The feed itself prints no counts any more; the rule binds the brand page and the brands
  list, and a card's "24 PIECES", which is the length of the page it opens.
- **A brand page is that brand's catalogue, and its counts are the way into it**
  (`BrandDetailView`). Two things were wrong with what was there. It was two **horizontal
  carousels**, so seeing a brand's output meant swiping a strip sideways one and a half tiles at a
  time — the one gesture that cannot be skimmed, on the page most likely to be browsed rather than
  read. And "Recent" was capped at twenty, which on a brand mid-season is a single poll's worth:
  the app held 400 Kith products and showed a dozen, so *what does this brand make* — the question
  the page exists to answer — was the one thing it could not. It is a two-column `LazyVGrid` over
  everything now, uncapped because a lazy grid builds only the screenful you are looking at, and
  the tile carries the price and the size run rather than the title alone (`CatalogueTile`, not
  1.0's feed tile — a third of a feed page, competing with a lead above it).
  `UpdateCarousel` and `EmptyStateView` were deleted with it; this was their only caller.
  **The three counts are the filter.** Catalogue, unread and kept already described exactly the
  three lists the page can draw and sat above a grid you could not point any of them at — same
  criticism `StyleView`'s taste block answered by making each word a query, and the same
  obligation: each number is the length of the list it opens, or the page tells two stories about
  one shelf. So `UNREAD` deduplicates over the **unread rows** rather than filtering the catalogue,
  which is what makes it agree with the feed and with `Brand.unseenCount(matching:)`; and `KEPT` is
  deliberately *not* filtered by `passes`, because those are things somebody chose and hiding one
  for a setting changed afterwards would be the app editing their own collection.
- **Every row of Upcoming names a brand, so every row opens it** — in the calendar and under the
  feed's Upcoming filter, which draw the same `UpcomingDropList`. That page answers "who is about
  to drop"; the next question is always "what have they been doing", and the wordmark at the top of
  each row was inert — the only route to the brand was to dismiss the sheet and go looking. A
  locked storefront in particular is the strongest signal in the app and the moment somebody most
  wants the page. Note the sheet needs its **own** `appDestinations()`: a destination registered on
  the feed's stack is invisible from inside a presented one, and the failure is a link that does
  nothing, silently.
- **The feed is one pass per `body`, over a capped query, reading each row once** (`FeedPass`).
  1.0's lesson, kept: marking a brand read re-rendered the feed and the body then walked every
  brand's `updates` four more times, each walk calling `passes`, which re-runs the gender classifier
  whenever the stored revision differs — thousands of classifications before a frame. And walking
  `brand.updates` faults the whole catalogue in, where the question is only ever about the few rows
  being drawn. So the store narrows (`arrivedAt != nil`, newest 500 arrivals), the pass reads each
  row's scalars **once** into values, and cards read photographs and prices from their own rows live,
  so a photograph that lands later redraws its card rather than the screen. **Each product is
  tokenised once per pass** however many releases ask about it: a baseline's collections arrive in
  quantity — Kith's were 241 rows — and asking every release about every product, tokenising both
  each time, was 230–360ms of a pass in a debug build. Now 12–18ms for that store and 9–13ms for 400
  garments in 31 cards; scrolling evaluates no `body` at all.
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
- **The buy bar checks out in your size only when it can say which** (`Checkout`,
  `StorefrontBar`). It always opened the product page, so buying meant picking the size the app
  already knew, again, on the shop's own menu — five steps on the one page where a drop is won
  or lost. For a Shopify product (`shopify:` key, numeric variant ids) with **exactly one
  available variant you wear** in the colourway on screen, it now opens the cart permalink
  `https://<product host>/cart/<variant>:1` and says "CHECK OUT IN M · KITH.COM". Four rules
  hold it. **`claims`, never `matches`**: the filter's optimism turns "can't read 44" into
  "yours", which on a size run is a wrongly ruled token and here is money — so no profile, an
  unreadable size, two of your sizes in stock or four colourways with none chosen all open the
  page instead. **The label says checkout, not bag**: a permalink skips the bag, and a button
  promising one and opening a payment page is not trusted twice. **The product's own host**,
  because `usa.` is a different shop in a different currency. And **`UIApplication.open`, not an
  in-app browser**: a shop's app claims its URLs as universal links and is where somebody is
  signed in with a card saved. Otherwise it is the exact product page — `?variant=<id>` when
  your one size is sold out, so the shop says so — and on every other platform the page
  untouched, because no other platform's variant URL is something the catalogue tells us
  (WooCommerce wants a per-store attribute slug, Salesforce a product-scoped parameter, UCP
  publishes nothing about its web URLs). Variant ids needed no wire change: `VariantInfo.id` has
  always been the Shopify id, stored server-side as `variants.external_id`.
- **Following a brand the poller has watched for months hands over its recent history, pre-marked
  seen.** The feed cursor is one timestamp across every followed brand, so `GET /v1/feed` correctly
  reports that nothing has happened since — the brand page opened empty, its counts read zero, and
  nothing said it was being watched until the next drop, which for a seasonal label is months away.
  `GET /v1/brands/:id/feed` is a bounded window over one brand and `RemoteSync.catchUp` merges it as
  a **baseline**, the same rule as `SyncEngine`'s first sync and the poller's `baselined_at`. It
  must never advance `cursor` — that would skip every other brand's events in the same window — and
  must never arrive unread, which is the 250-product bug delivered at the exact moment somebody is
  deciding whether following was a good idea.
- **A sync reads the feed to the end, a page at a time, and loses nothing at a page
  boundary** (`FeedPager`, the server's `FeedPaging`). It asked once for 200 and moved the
  cursor to the newest of them, so anything older than the 200th event between two syncs was
  behind the cursor before it was ever sent — and with the page newest first, one busy brand
  could fill it and push a quiet brand's only drop out. The server's order is now fair between
  brands and a page that leaves anything behind carries a `continuation`. Four rules on this
  side. **The cursor moves when the head lands**, because a read is a fixed window and the rest
  of it is remembered as the server's own token (`feedPendingReads`, beside `feedCursor`) —
  the token is written before the cursor, and each page is saved before either, so a process
  killed between them reads a page twice rather than never. **Five pages per sync, head
  first**: what happened since you last looked is what a push is about, and a phone away for
  a fortnight can be owed tens of thousands of events that one foreground refresh must not try
  to pull; what waits is the deep end of the busiest brands, because the order is fair. At
  most four unfinished windows are kept and past that the oldest goes — the one remaining way
  to lose an event, and it takes a phone more than four whole windows behind. **Only the first
  page can fail a sync**: everything after it is already pending, so a dropped connection on
  page three is a slower catch-up and not a failed refresh. And **a first sync stops at its
  first page**, because it is a baseline and history owes nothing — the same reason it is
  stored read. A continuation the server refuses is spent, not retried for ever.
- **A follow has a mode, and the mode is applied where a row is written, not where the feed is
  drawn** (`FollowMode`, `Brand.apply`). *Everything*, *Sales only* or *Quiet* — the roadmap's
  answer to following H&M without burying the feed in daily arrivals, and the replacement for
  1.0's mute, which was a phone-only flag consulted when a push arrived in the foreground:
  the push had been composed, sent and delivered regardless, and in the background iOS showed
  it anyway. `FollowMode.admits` is the one rule, asked by `Notifier` before anything is sent
  and by the phone for the feed — and what *Sales only* lets through is `UpdateKind.isSale`, so
  a new sale kind is one case in one switch. The decisions:
  - **The feed is filtered on the phone, by storing what the mode does not admit as already
    read and with no arrival** (`RemoteSync.merge`, `SyncEngine.insert` and `refresh`), so it is
    history and never in the timeline. Not on the server, because
    a quiet brand's own page is still its whole catalogue and a server that withheld its
    events would freeze that page the moment it went quiet; and standalone has no server.
    Not as a filter in the feed's body either, because every unread count and the brand page's
    UNREAD would each need the same rule, and the unread queue would grow for ever, since nothing
    that is unread is ever pruned. Stored read and without an arrival, the feed and the counts
    agree without knowing modes exist.
  - **Changing the mode takes what it no longer admits out of the feed** — out of the unread queue
    and out of the timeline (`Brand.apply` clears `arrivedAt`); nothing is deleted, and nothing
    comes back on the way to *Everything* — what happened while a brand was quiet is its history.
  - **What is about the future asks the mode itself**: the line above the feed and Upcoming read
    `Brand.isAnnouncingLock` and skip a brand whose drops are not admitted. A date somebody typed
    is kept whatever the mode; they asked for it by name. The brand page and the brands list still
    say a storefront is locked, in muted ink: that is a fact about the shop.
  - **A quiet brand is reachable**: in the Brand menu, labelled with its mode — and choosing it says
    why it is empty — under You › Following, and its page is its catalogue. It still counts as a
    follow for recommendations and Discover.
  - **A watch ignores the mode**, on the lock screen and in the feed: a fired watch still
    surfaces its row unread, because it is the one alert somebody asked for by name.
  - **The server's mode is the mode.** In server mode `Brand.followModeRaw` mirrors
    `GET /v1/follows`, the page changes it with `PATCH /v1/follows/:id` first and locally only
    once that succeeds — a mode that changed only here would be the mute again. Only the follow
    list carries a mode; nil from any other route means "not said", never "everything".
  - **1.0's mute becomes *Quiet*, once.** The first sync of this build sends it before the
    follow list is asked for and clears `isMuted` when the server has it; standalone does it
    locally. Quiet and not Everything because the promise was silence, and breaking it is
    worse than the one thing that changes — the brand also leaves the feed. `isMuted` stays as
    a stored property only so the old value can be read.
  - **No default is guessed.** A new follow is *Everything*, on every client. A heuristic that
    filed a big catalogue under *Sales only* at follow time would be a filter somebody did not
    set, which is indistinguishable from a broken follow — and product velocity alone does not
    tell Kith, the roadmap's *Everything* brand, from H&M.
- **A collection is not a product** (the feed's release card, `CollectionReleaseView`). It is the one update
  that is *about* other updates, and it was drawn as a garment: no photograph (a season page rarely
  has one), an empty size run, no price, and a tap onto a product page with nothing on it — so
  "DENIM TEARS FW26", the most interesting thing a brand posts all season, rendered as the emptiest
  card in the feed. In Phase 1 a release is one card whose mosaic is its contents, and the garments
  it absorbed are not cards of their own. **A collection's contents are read, not guessed, and the
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
- **One release, stated once** (1.0's spread; the timeline keeps both rules in `FeedTimeline` and
  `FeedPass`). Billionaire Boys Club announced its Yankees edit three
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
- **A price cut takes a card** — *changed on purpose*. 1.0 printed a headline and no picture, on the
  argument that the feed was the wrong home for a markdown and `MarkdownsView` the right one. That
  list is retired; Sales is a filter over the timeline, which is not emptied by reading either, and
  a cut drawn as a sentence was the card nobody looked at. "−30%" with the "was" struck through.
- **One garment, one row, in every list** (`BrandUpdate.oncePerProduct`). The store holds *events*:
  a feed row is `event:<uuid>` and one jacket drops, is marked down and comes back in an L, so a
  brand page, a release and a brand's spread each printed it three times at three prices — and the
  Phase 1 timeline is one more list that obeys it. Keyed on
  `productExternalID` — the garment — never on `externalID`, which is the event; a row with no
  product behind it keeps its own key so two unrelated links can never collapse into one. The
  survivor is the newest by `newestFirst`, so the choice is stable across relaunches.
  `unseenCount(matching:)` counts distinct garments for the same reason — counting rows said 40
  above a page showing 25.
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
- **The daily full scan keeps the catalogue current and is never news by itself** (server only;
  `docs/server.md`, *The catalogue is read at two speeds*). It is what makes a markdown or a
  restock on older stock visible at all — the poll re-reads only the newest ~250 — and it is the
  largest single source of potential event storms in the system, so three rules are absolute.
  **"New" belongs to the poll**: a product the scan meets for the first time is stored silently,
  and one published within a day of the poll's last read is left for the poll to find, because a
  scan that stored a drop first would have swallowed it. **A first scan, or one after a lapse, is
  a baseline**: the older stock's stored state is months stale the first time, and every
  difference from it would otherwise be announced. **Events only by the existing rules** — a
  size back, a markdown past 5%, a sale — through the same `refresh` the poll uses. Standalone has
  no scan: the phone reading thousands of products a day for itself is the hammering the server
  exists to avoid.
- **A product leaves the catalogue after two complete scans in a row do not find it**, never one:
  paging a catalogue that changes under the reader skips rows. Unlisted is not deleted — retention
  takes it six months on — and a scan that finds most of a shop gone is not believed.
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
- **A markdown is measured from the brand's own tag where it published one**
  (`FetchedItem.originalPriceAmount`, Shopify's `compare_at_price`; `PriceChange.base`). A drop
  used to be only a fall between two polls, so a product first seen already discounted — last
  season's stock moved onto the sale rail, which is most of what a sale is — was never a markdown:
  no "−30%", nothing under Sales. Four rules. **The original belongs to the lowest
  variant's price**, not the highest compare-at anywhere on the product, and counts only past the
  same 5%: storefronts leave compare-at equal to the price or below it. **A re-shelved product
  that is marked down is a `.priceDrop`** with the original as its "was" (`Reshelving`), not a
  restock; a launch at a discount keeps its kind and its card still says how much is off. **The
  card says the larger cut** — 180, then 150 for a week, then 120 is "−20%" against the poll and
  "−33%" against the tag, and the tag is what a shopper can check (`BrandUpdate.markdownBase`,
  `wasPriceText`). **A source that publishes a
  price says every time whether it is marked down**, so a null compare-at clears the original; a
  source with no price (a sitemap) says nothing about either. `FeedItem` carries the current
  price as a number as well: it carried only the display text, so every server-backed markdown had
  no measurable cut in the mode the app ships in.
- **A brand going on sale is news; a markdown is not** (`UpdateKind.sale`, the deliberate change
  to "only the unexpected is worth a buzz"). A single markdown is worth as much next week, and stays
  quiet. A brand putting much of its catalogue on sale,
  or announcing "25% off everything with code AUTUMN" in its bar, starts at a moment, its best
  sizes go first, and the code is found nowhere else — so `.sale` is `isSudden` *and* `isSale`,
  and it is the one thing a *Sales only* follow is woken by. Quiet hears nothing; the mode still
  only takes away. Two detectors on the server, one event per sale (see `docs/server.md`): the
  catalogue (`CatalogueSale` — at least 30% of what a pass read and at least 12 products marked
  down, ending only under 10% and after three days, the first measurement a baseline; the daily
  scan measures the same share of the whole *buyable* catalogue, may start a sale on older stock
  the poll cannot see, and holds one open until both readings are under 10%) and the
  announcement bar (`SaleBanner`, every 30–60 minutes; free shipping, somebody else's discount
  and "on sale Friday" are not sales). **The roadmap calls the brand-wide alert opt-in per brand,
  and the opt-in is the follow mode**: *Everything* and *Sales only* are two ways of asking for
  it, *Quiet* the way of declining — a separate switch per brand would be a fourth mode by
  another name. Standalone detects neither: both need the poller's view over time, and the
  phone polling a homepage every half hour for itself is the hammering `FeedRefresh` exists to
  avoid.
- **A sale is a brand-level card, said in its own words.** The row has no garment — its words live on
  the event (`events.title`/`summary`) and arrive as `FeedItem.title`/`summary`, its link is the
  shop — so the card shows the brand's own marked-down garments as its picture, its label is the
  offer as the brand put it ("SALE 25% OFF · CODE AUTUMN", `FeedLabel.saleWords`), it carries no
  price, and it opens the brand's page, as a push about one does. It sits under Sales and All.
- **A price drop on something you watch or saved reaches you** — the roadmap's rule from 1.0 that
  changes on purpose. A markdown on a garment you have never seen is not news; one on the thing
  you asked about by name, or kept, is news about *you*. **Watched: the server pushes it**, by the
  watch path — no follow mode, no cooldown and it does not start one, no size or gender filter,
  one push per person per product, and it does **not** spend the watch (`fired_at` is the
  restock's ledger; a cheaper sold-out jacket is still being waited for). Only active watches: one
  that has fired has been answered. **Saved: the phone says it** (`PriceAlerts`), because saves
  never leave the device — after every sync, a local notification on the server's wording
  (`PriceChange.alert`), one thread (`PushGrouping.threadID`), opening the row, once per price
  (`BrandUpdate.priceAlertedAmount`, a price rather than a date because standalone rewrites one row
  per cut). History — a first sync, a catch-up — arrives with the ledger spent, and the ledger is
  spent even when the switch is off, so turning it on does not fire a burst. In server mode a
  product with a server watch is left to the push; standalone, watched products are said here
  too. On by default; the switch is in Alerts.
- **A kind 1.0 cannot draw is never sent to it** (`FeedKinds`). 1.0 decodes `FeedItem.kind` as a
  string and maps anything unknown onto `.product`: a sale would have arrived as a new product with
  no photograph, been counted in "N new products" and — being sudden — taken a drop's lead slot.
  So `GET /v1/feed` and `GET /v1/brands/:id/feed` send only the kinds a client names in
  `?kinds=`; naming none, as every 1.0 request does, gets the seven kinds 1.0 shipped with
  (`FeedKinds.legacy`, frozen). The new client names its whole `UpdateKind.allCases`, so a kind
  added later stays invisible to every build until it can draw it, and it skips a kind it does
  not know (`FeedItem.knownKind`) rather than drawing it as a product. A push is not filtered: a
  sale push to a 1.0 phone carries no event id, so tapping it opens the brand, which 1.0 has.
- **Location is a setting, and all it ever does is choose between a brand's own shops** (You ›
  Location, `LocationSetting`, `users.country`). It defaults to the phone's region and is held on
  the server, because the server decides which shop's events and pushes reach you — see
  `docs/server.md` for the storefront model. It never converts a price, never hides a brand and
  never filters a feed: a brand with no shop for your country, or one in a country not yet
  switched on, is its main shop, exactly as before. The row says that in as many words — "Prices
  and shops for the United Kingdom where a brand runs one; elsewhere the brand's main shop" —
  and there is no list of countries that are coming, because a setting that mostly says "not
  yet" is the app talking about itself. Standalone has no server and no storefronts; the setting
  is kept on the phone and changes nothing there. What it changes is visible where it changes
  something: a brand page names the shop it is showing ("UNITED KINGDOM SHOP · GBP" against
  "MAIN SHOP · USD"), under the host it is on. A shop serves a set of countries, so a regional
  one is named for who it serves, never for the reader's country — "EUROPE SHOP · EUR" under
  `EU.KITH.COM` when every country in its set is European, "SHOP FOR 48 COUNTRIES" when they are
  not (`ShopReach`). Calling `eu.kith.com` "the German shop" to somebody in Berlin would be a
  claim about a shop that is not German.
- **A switch is forward-only.** Rows a phone already holds were the main shop's when they arrived
  and stay so; what arrives after the server serves a country's shop is that shop's. Rewriting
  history to the new shop would mean re-sending every event under a second identity, and the
  merge keys on the event.
- **Every price prints in its own currency, written the reader's way** (`PriceFormat`,
  `BrandUpdate.currencyCode`, `FeedItem.currency`). A price used to be printed exactly as the
  server formatted it, on a Linux box, in the server's locale — and a "$" means something else to
  somebody in Canada. With the amount and the shop's currency both known the phone formats it in
  its own locale ("US$180" in Toronto, "$180" in New York, "£180" either side of the Atlantic);
  without them, on a row older than the field, the stored text prints verbatim, which is what it
  always did. **The brand's currency is never used to print a row**: once somebody changes
  country it names a different shop from the one that row came from, and a dollar price would
  print with a pound sign. Nothing is converted, anywhere — a markdown is measured within one
  shop's currency, and a price that changed currency between two reads is not a markdown.
- **Restock is the only reason a seen item resurfaces.** `SyncEngine.refresh` re-flags an update —
  unread, and arriving now, so it lands above the line — only when a *variant* goes false→true, recording which sizes returned in `restockedSizes`
  (falling back to whole-product `isAvailable` for sources without variants).
- **`FetchResult.notModified` is not the same as an empty `items`.** A 304 means "unchanged";
  merging its empty list would be a no-op, but the distinction matters for any future caller that
  treats "no items" as meaningful.
- **`ShopifySource` stops paginating early** once a page ends older than `since`. Only the first
  page carries the `ETag`, which is sufficient — if the newest products are unchanged, nothing
  further back can have moved.

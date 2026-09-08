# Discover

Part of the streetw guidance set; see `CLAUDE.md` for the index and the build rules.

## Discover

The Discover tab is a full-bleed vertical scroll of garments — mostly from brands you **don't**
follow, plus what is still unread from the ones you do (`FollowedSupply`, below) — and the
argument each card makes is the one only an archive can make: *this goes with clothes you
already own*. `GoesWith` had been writing that sentence on product pages for a while — its
own header says it is "an argument for keeping it" — and it had never been pointed at a brand
nobody here follows, which is where it is worth the most.

- **`/v1/brands/popular` could not have been the supply, structurally.** Its candidate list is
  built from the **follows table**, so a brand nobody follows is invisible to it — precisely the
  brand a discovery feed exists for. `GET /v1/discover` pages by *depth* through every
  unfollowed catalogue instead.
- **The shape of the query is the diversity.** One date-sorted query with a global `LIMIT` does
  not work: a storefront publishing 250 products in one sweep owns the window, which is the bug
  `/v1/brands/popular` shipped with. Every eligible brand is asked for its own newest few and the
  cursor walks depth, so diversity is a property of the query and cannot be lost by tuning.
  Measured against six real catalogues (9,227 products): 469 cards, **zero duplicates, zero
  adjacent repeats**, and Kith at 17.1% against Allbirds at 16.4% despite holding five times the
  catalogue.
- **The offset advances by `discoverPerBrand`, never by the fetch window.** The window is wider
  only so the spread has something to draw from; the cards come from exactly
  `[offset, offset + perBrand)`, which is what makes the enumeration a partition. Written the
  other way round it silently skipped ten products per brand per page, and nothing anywhere would
  have reported them missing.
- **Exhaustion is "no brand had a row", not "no cards survived".** A depth window that is entirely
  promotional yields an empty page while the catalogue sits one depth below, and reading that as
  spent ended the feed permanently at the first gift card.
- **`Discovery.swift` holds four mechanisms and they are separate because each fixes something
  the others cannot see.** A per-brand cap **applied in rounds** (a single allowance front-loads,
  spends itself in the first eight cards and then imposes no cap at all — the collapse arriving
  eight cards late); `Saturation`, damped smoothly like `Popularity.confidence`; one position in
  four that **ignores the ranking outright**; and `WardrobeGap`. The third will look like a bug to
  whoever reads the ordering next — a taste engine left alone is a mirror, and a feed that only
  returns what you already own cannot introduce you to anything.
- **The per-brand cap is *one*, and the number is about spacing rather than about quantity.**
  It was two, on the argument that a brand should get to show it makes more than one thing —
  true, and not what the number decides: the cap is per **round**, so a brand still contributes
  its second card, it simply cannot until every other brand has had a first. `/v1/discover`
  hands over exactly two garments per brand per page, so a page *is* a set of pairs, and a
  brand's catalogue is internally consistent — if one of its shells suits you so do the other
  thirty-nine — so both of its cards score within a hair of each other. `Saturation` damps the
  second by a quarter, which does not move it past a whole round of strangers: measured on a
  realistic spread of verdicts, a brand came round again at **position 6 of 15**. Scrolling read
  as *the same brands over and over* while the ordering was doing exactly what it was told, and
  the diagnosis is worth keeping because the obvious explanation — "the catalogue must be
  small" — was wrong: the deployment holds around 160 brand rows, ~94 of which yield cards, and
  a brand does not genuinely recur until eight pages in. `DiscoverDeck.prefetchMargin` is the
  other half and went 3 → 10 for the same reason: a page is one group of ~15 brands, the next
  page's cards land in the **unpinned tail** and are ranked together with what is left of this
  one, so asking earlier does not merely prevent a stall — it makes the round longer.
- **The deck has a second supply: what is unread from the brands you follow** (`FollowedSupply`).
  `/v1/discover`'s candidates are by construction the brands nobody here follows, which is the
  right pool for an introduction and the wrong one for the sentence this tab exists to print.
  *This goes with what you own* is exactly as good an argument about a new Kith jacket, and the
  feed — whose unit is the event, ordered by recency and grouped by brand — has never made it
  about a followed brand's drop. So the two tabs ask different questions of one garment rather
  than duplicating each other. Read out of the store, converted to `DiscoverCard`s so every path
  downstream (ranking, the card, saving, the fit studio) is the one that already exists and
  cannot drift. What keeps it from becoming a second feed: **unread only**; **a garment with a
  photograph** (product, restock and markdown — a page change has no garment and a release is
  drawn from members this does not query); **deduplicated per garment**; **interleaved across
  brands and capped at twelve** against a server page of about thirty, so following twenty shops
  cannot take the tab over. Four consequences are load-bearing. A followed card is **familiar by
  construction** whatever the vectors say — it sends no vector, and without that it would be
  *unfamiliar* and therefore first in line for the exploration slots, which exist for a label the
  ranking has no opinion about. It is always drawn as `.pairing`: a `.brand` card is a mosaic of
  `spread`, which this deliberately does not send, so falling through would draw an empty grid.
  It offers **neither Follow nor "not for me"** — both are verdicts on a shop already chosen, and
  the second writes a permanent `BrandDismissal` that also demotes everything resembling it — and
  carries **"mark read"** in their place, which clears every row that garment stands for, the
  rule `FeedView.markSeen` states. And `DiscoverDeck.adopt` **keeps anything already scrolled
  past**, whatever the store now says: reading one takes it out of the unread query, and dropping
  it would shorten the deck above the reader on the very tap that did it — `pinningRead`'s
  failure arriving through the supply instead of the ranking. Scrolling past one does **not**
  mark it seen; `isSeen` belongs to the feed, and clearing somebody's queue as a side effect of
  looking at another tab would be the app deciding they had read something they had not.
- **Deterministic, with no RNG.** Variety between two people comes from their wardrobes differing
  and between two sessions from the seen-ledger; a random number would cost the property that
  scrolling back shows the same card, which is `FeedView`'s lesson about a list that reorders
  under a thumb.
- **Analysis sharpens what a card *says*, never where it *sits*.** `DiscoveryAnalysis` measures
  the photograph for the cards at and adjacent to the viewport — `ImageTagger` only runs over
  saves, so a discovery garment has no cutout and no colour. `DiscoverDeck.rank` reads none of it,
  because photographs decode while somebody is scrolling and a deck that re-ordered as they landed
  would reorder mid-read.
- **The composite is measured on the packshot; the card shows the lead shot.** `ProductShot`
  already answers "which frame has nobody in it" for the fit canvas. Lifting the subject of a
  lookbook frame returns a person, and the card would offer a whole model as the thing that goes
  with your jeans. On a model is still how the brand wants the garment *seen*.
- **Three voices, and which one a card speaks in is decided by what the app can back up.**
  `DeckPresentation` is `.release` ("look at this brand's new collection", drawn as a mosaic of
  its contents), `.pairing` ("this would go with your olive cargos") or `.brand` ("look at this
  label", its range underneath). Not a rotation and not random — a release is a release, a
  pairing needs a wardrobe to pair against, and a brand card is what is left. One voice for
  everything made a feed of forty cards forty copies of the same sentence, and left the
  cold-start case with no voice at all.
- **`/collections.json` is mostly shop furniture, so `Release.isRelease` refuses far more than
  it admits.** A real six-brand poll returned 826 collection rows: shoe sizes ("10.5", "12C"),
  discount rails ("30% OFF GYMSHARK SALE"), the designers a multi-brand shop stocks ("1017 ALYX
  9SM"), navigation ("All Products", "Back in Stock"). The bar is the one thing every genuine
  release had and no piece of navigation did — **it names a season or a year** — and navigation
  words are checked *first*, because "Fall 2025 Sale" names a season and is still a sale rail.
  55 of 759 admitted. The asymmetry is the whole design: a false negative costs a card nobody
  misses, a false positive puts a full-screen announcement of **"36.5"** in front of somebody.
  Undated capsules ("ALWAYS DO WHAT YOU SHOULD DO") are refused on purpose.
- **A release has no photograph of its own and is drawn out of its members.** `/collections.json`
  publishes a name and nothing else, so the card is a mosaic of the garments in it — found by
  `Release.distinctiveWords`, since a release names itself and does not list itself. The members
  are **spread across garment slots** via `Discovery.interleave`, keyed on slot rather than
  brand: catalogue order gave Icecream Fall 2026 as six pairs of socks and a banana pouch, which
  is an accessories drawer rather than a season.
- **A release cannot win on merit and needs `Discovery.releaseFloor`.** It has no garment slot,
  so `Pairing`'s gate refuses it before scoring and it falls back to a bare vector similarity
  that any single jacket beats — the card the feed most wants to show came last *by
  construction*. A floor rather than a fixed score, so a release from a brand that matches
  somebody's taste still outranks one that doesn't; the per-brand cap and `Saturation` still
  apply on top.
- **`DiscoverCard.init` takes `variants` as a parameter**, exactly as `BrandDTO` takes its
  sources. Fluent's `@Children` accessor **traps at runtime** when the relation was not eager
  loaded, and this initialiser has two callers with different query shapes — the product query
  loads variants, the release query deliberately does not. Reading the accessor took the whole
  server down with `Children relation not eager loaded` the first time the second caller
  existed.
- **Two rows under the caption, and the spread is not optional.** `WEAR IT WITH` is the pairing;
  `ALSO FROM <BRAND>` is six more of the brand's garments. They were briefly one row on the theory
  that the pairing is the stronger statement — it is, but only one of them is about the *brand*,
  and "what else does this label make" is how somebody decides whether to follow a shop they have
  never heard of, which is the entire job of the tab. Collapsing them meant the cards with the best
  argument were also the ones that said least about the company. Both rows are labelled: two
  unlabelled strips of garments under one caption is a puzzle.
- **The card is a column; the reading is not laid over the photograph.** The overlay version
  cost three separate faults at once. `.fill` was forced (a full-bleed photograph has to cover
  its frame) and cropping destroys a packshot — Allbirds shoots wide and side-on, so both ends
  of the shoe were cut off under a band of empty sweep. The gradient behind the text was a
  permanent scrim over the bottom third of every garment. And the `ZStack` had no width of its
  own: a `ScrollView(.horizontal)` reports its *content* width as its ideal, so the spread row
  made the card six hundred points wide and Palace's card rendered with its wordmark, title and
  Follow button all off the left edge — "one over-wide row sets the width of the whole page",
  reached by a new door. Pin **both** axes on the card.
- **The scroll ignores safe areas so that a card and a page are the same height.** Four things
  were tried first and every one looked right: `containerRelativeFrame` inside a
  `NavigationStack` sizes against a container a navigation bar taller than the region a page
  travels, so every card settled exactly that much short with the previous card's Follow row
  still on screen; `.inline` left the bar there; `.viewAligned` aligned to edges that were still
  the wrong height; hiding the bar traded it for content under the status bar; and a
  `GeometryReader` measured a frame the scroll view then inset *inside*. With safe areas ignored
  the container is the screen and the card is the container, so there is nothing left to
  disagree — at the cost that every overlay insets itself by hand (`reading`'s bottom padding is
  what keeps Follow clear of the tab bar). **The tell was that the error was the same every
  time**: physics varies, an off-by-a-bar does not.
- **There is no navigation bar.** It is the one page in the app that is a photograph first, and
  a serif title eating the top seventh of the screen to say "Discover" — on the tab already
  labelled Discover — was paying for the layout bug twice.
- **An exploration card prints `NEW TO YOU` and never a pairing.** It was not placed for one, and
  a composite with somebody's clothes in it under a card chosen at random would be the card
  telling a story the ranking never told. Same rule as `sharedTraits`.
- **A discovery card is never persisted with `isSeen == false`, and mostly never persisted at
  all.** `FeedView` queries `#Predicate<BrandUpdate> { !$0.isSeen }`, so a stored page would empty
  several thousand products from unfollowed brands into somebody's unread feed. Only a *save*
  writes a row (`DiscoverSave`), keyed `shopify:<id>` with `productExternalID` beside it so a
  later follow merges rather than minting a second card. Verified by driving the app: saving from
  the deck took updates 800→801 and saves 8→9 while **unseen stayed at 12**.
- **Saving does not remove the card; Follow and "not for me" do.** Keeping something is not a
  verdict on the brand, and a card vanishing under the thumb that saved it would make the two
  gestures indistinguishable in effect while meaning opposite things.
- **No swipe-to-dismiss.** The obvious gesture is Tinder's and it is wrong here: `BrandDismissal`
  is permanent *and* demotes brands that merely resemble the refused one, so a stray flick poisons
  the recommender with no undo and nothing on screen to say so. Horizontal belongs to the
  photographs.
- **…and the double-tap save goes *inside* the pager, never on a layer over it.** This is the
  correction to the note that used to sit here, which said the opposite. A transparent
  `Color.clear` with a `contentShape` and a `TapGesture` over a paging `TabView` is not a passive
  layer — it becomes the hit-test result for every touch in the frame, so the page controller's
  own pan recogniser never sees one and **the photographs cannot be swiped at all**. A tap
  gesture cannot recognise a drag, so the swipe was swallowed rather than lost to a competing
  gesture, which is why it read as the pager simply being broken: the rules under the picture
  counted seven photographs with no way to reach six of them. `DiscoverPhotos` takes an
  `onDoubleTap` and attaches it to each page's content, where a scroll view delays taps and
  claims drags by itself. The layer is still right on the **mosaic** cards, which have no gesture
  of their own to lose.
- **A card is one ground falling from sweep to ink, and the whole tab is a fixed poster.**
  It went through two shapes before this one. It was `Color.sweep` end to end — the one colour
  that does not answer to dark mode — so the tab stayed cream at midnight while every other
  screen inverted. Then it was a fixed sweep panel for the picture on an adaptive `paper` page
  for the type, which inverted correctly and put the loudest line on the screen right across
  the middle of a card that is a photograph first. Now it is a single vertical ground: flat
  studio sweep everywhere there is artwork, falling to near-black under the reading, which is
  set in paper on top of it.
  **This reverses "nothing is white-on-dark", and the reversal is narrower than it sounds.**
  That note was written against a *scrim laid over a photograph* — text on the bottom third of
  every garment, with the picture cropped to fill the frame — and about that it was right.
  Neither is true here: the photograph is still `.fit`, still uncropped, and finishes **above**
  the dark. The gradient is the card's own ground, not something drawn on the artwork.
  Three things hold it together. The ground is **fixed in both appearances**, for the reason
  `Color.sweep` exists — photographs do not invert, and the top of this gradient is the same
  studio sweep a packshot was already shot on, so a JPEG's baked-in white backdrop has nothing
  to sit against. The **artwork never reaches the fade** (`chromeBottom`), because a
  white-backed JPEG drawn over the falling ground is the lightbox-in-a-dark-tile failure again.
  And the fade is **a band of fixed height anchored to the foot, not a fraction of the hero** —
  a proportional stop moves with the hero's height, and on a mosaic, which fills its region
  rather than letterboxing inside it, the bottom two rows of photographs ended up on grey.
  The band is deliberately **taller than the inset above it and eased rather than linear**: its
  first two thirds are almost clear, so the picture ends well inside it without picking up a
  tint. A straight ramp over the inset alone put a visible grey wedge under every garment.
  **The fall is sampled off a curve, not written as four stops.** Four points describe its
  shape correctly and still draw it badly: a gradient interpolates linearly between adjacent
  stops, so a curve given as four arrives as three straight segments with a crease at each
  joint, and the longest of them — carrying most of the darkening — banded against a ground
  this flat. `DiscoverCardView.stops` samples a smootherstep thirty-two times instead, which
  has zero slope *and* zero curvature at both ends, so the ground neither leaves the sweep nor
  lands on the ink with an edge of its own. Measured after the change: no more than 2.7 levels
  of 255 between adjacent pixels anywhere in the steepest part of the fall.
  **And it climbs at the two sides, so the turn is an arc rather than a ruled line.** The fall
  alone is the same height at every x — the one perfectly straight edge on a card that is
  otherwise all photograph and type. `edgeFall` runs the same curve again weighted to the
  vertical edges (`edgeFallDepth`, clear across the middle fifth and symmetric about the
  centre), so the ink reaches the corners about ten points ahead of the middle and the garment
  sits in the last of the light. Two constraints hold it: it is the card's **own ground** both
  times rather than a vignette laid over the artwork — the thing the single-ground rewrite
  exists to have stopped — and its mask stays at nothing until halfway down its band, so at
  the artwork's bottom edge even the far corners are under three hundredths dark. Note the
  arc's vertical extent cannot be bought by making the band taller: the artwork's bottom edge
  has to sit where the ground is still imperceptible, so `chromeBottom` fixes how much fall
  there is to bend, and a taller band only moves the curve's start down to match.
  Anything drawn on the light half (the save circle, the photo count, the filter chips) takes
  fixed `sweepInk`; anything on the dark half takes `groundInk`. `SaveAction` uses
  `Color.paper` because it sits on adaptive ground, and copying that here would put ink that
  cannot invert on a chip that does.
- **The floating tab bar has to be told which scheme it is dressing for.** It takes its material
  from what is behind it, so over this card's near-black foot it came out dark while still
  drawing a *light-appearance* selection — dark type on a dark pill, on the tab you are
  standing in. `.toolbarColorScheme(.dark, for: .tabBar)` on that tab alone; every other tab is
  unaffected.
- **`FollowButton` grew an `onDark` variant rather than a twin.** A filled ink rectangle is
  invisible on the card's foot, so there it is a light capsule. A parameter, not a second
  control: the in-flight guard, the spinner and what a tap does stay in one place, which is the
  whole reason the type exists.
- **The photographs page in a `ScrollView`, not a `TabView`.** A page-styled `TabView` is a
  `UIPageViewController`, and its pan belongs to a different gesture system from the vertical
  paging scroll a card lives inside — so when the outer scroll claimed a drag the pager had
  already started, the pager was left part-way between two photographs and stayed there: three
  quarters of one picture and a sliver of the next, with nothing to say which one you were on.
  Two scroll views of the *same* kind compose properly; `.scrollTargetBehavior(.paging)`
  guarantees it comes to rest on a page rather than wherever the finger left it. Note
  `scrollPosition` reports **nil** while between pages — the state this could previously be
  stuck in, and now only passes through — so the binding ignores it rather than writing it back.
- **A cutout needs a light ground wherever it is drawn small.** The wardrobe piece in the
  pairing row was a 32pt sticker straight on the reading, which in dark mode meant a black
  jacket on near-black — a caption with nothing above it, the exact fact `Color.sweep` is
  written down for, met on a new surface. It is a photograph, so it gets the ground photographs
  get: fixed sweep, in both appearances, and bigger.
- **The photograph is counted, not scrubbed.** The card had a segmented progress bar across the
  foot of the picture — a control the app uses nowhere else, on the one screen that is nothing
  but pictures. `ImageGallery` settled this question already and its own note says why: a
  printed count "says how many there are, which dots only imply, and it matches the mono
  metadata everywhere else". The capsule behind it went with the panel it was protecting the
  count from: the artwork is inset above that corner now, so the count sits on flat sweep and a
  chip would be a shape drawn for no reason.
- **The filter bar has no band and no hairline.** It was an opaque strip with a rule under it —
  a second horizontal division on a card that now has one made of light. The card's ground is
  flat sweep that far up, so the chips have something to sit on without anything being drawn to
  give them one, and the tab's own background is the card's ground for the same reason (which is
  why `EditorialEmptyState` takes colours here: `Color.ink` on a fixed sweep is near-white at
  night).
- **The garment starts below the brand line, not behind it.** Letterboxing centres the
  photograph in the whole hero, so on anything near the frame's own proportions its top edge
  arrived under the wordmark — a head cropped by a caption, which reads as the picture being cut
  off. `DiscoverPhotos` takes the same `topInset` the mosaic has had since it was built.
- **Different cards point at different things you own** (`DiscoverDeck.spreadAnchors`). Every
  card in the feed was saying the same sentence about the same garment, and that is not a bug in
  `Pairing` — it is what a tie looks like at scale. `ImageTagger` runs over saves and
  `DiscoveryAnalysis` over the cards at the viewport, so most of a wardrobe has no measured
  colour yet; with nothing to separate them `ColorHarmony` scores every candidate identically,
  the layering bonus is the only thing that moves, and `Pairing.best` breaks the tie on `id` —
  deterministically, and so on the *same* garment for every card. Correct arithmetic, useless
  output: forty cards claiming to go with one jacket reads as the feature being broken, and it
  is the "same sentence forty times" failure `DeckPresentation` was written to fix one level up.
  So the anchor is chosen across the deck — each card takes its best-ranked pairing no earlier
  card has used, recycling the pool once spent, the round-robin `Discovery.interleave` uses on
  brands pointed at the wardrobe instead. **The reason moves with the anchor**, or the card
  prints a verdict about a garment it is no longer showing. `Pairing.best` is asked for eight
  rather than two so there is something to spread with; the truncation was always free.
- **The fit opens on the piece the card just named** (`FitStudio.anchor`). The card says "goes
  with your Kith Nylon Maverick Pant" and the studio then computed its own opening arrangement,
  so it could open on a different garment with a different name at the top — the app
  contradicting itself one tap apart, which is worse than either answer being wrong: the card
  makes a claim and the screen it opens is the demonstration of that claim. The named piece is
  pinned into its position first and the rest is built around it. Matched on `pairingID`, not
  `Option.id` — the latter is the save's identifier and the two are different strings — and
  looked up rather than trusted, so a wardrobe that changed in between falls back quietly.
- **A discovery card carries no size run.** Every other product surface has one, and this is not
  one of those surfaces: it is an argument for a *brand*, in a scroll nobody is shopping in yet.
  Six tokens of a ladder about a garment somebody has not decided they want, from a shop they
  have not decided to follow, was the most detailed thing on a card whose point is the
  photograph — and it spent the app's one accent colour saying "in your size" two taps away from
  anywhere you could buy it. Price stays; the run belongs on the product page the photograph
  opens.
- **`VIEW` is gone, and the photograph opens the garment** (`DiscoverProductSheet`). The deck
  used to end at a link: an underlined word in the corner of the action row that left the app
  for Safari — the *last* step of a decision offered as the only one, on a card deliberately
  stripped of the size run and everything else somebody would want before taking it. Worse, it
  left the picture inert: the one gesture everybody tries on a full-screen photograph did
  nothing while a small word did the drastic thing. The garment has a page now, reached from the
  photograph and from the title, with the storefront link pinned at its foot where every other
  product page in the app keeps it. It is **not** `ProductDetailView` — that takes a
  `BrandUpdate`, and a discovery card must not be given a row on the way in — but every
  component in it is shared (`ImageGallery`, `SizeRun`, `ColorwaySection`, `StorefrontBar`) so
  the two cannot drift. This is also where the size run belongs and where it now is.
- **The brand line is a way in** (`BrandPreviewSheet`, from the card's wordmark). A card
  headlined with a wordmark, on the one tab whose job is introducing shops, had nothing behind
  it: the only thing you could do about a brand you had never heard of was Follow it, which is
  the decision rather than the way to make it. The sheet that exists precisely to answer "should
  I follow this" was reachable from the recommendation block and nowhere else. It is handed
  `followers: 0` — `/v1/discover`'s candidates are by construction the brands nobody here
  follows, and the sheet prints that line only above `Popularity.meaningfulFollowers`, so zero
  draws nothing rather than inventing a number.
- **Nothing is laid over the photograph except the wordmark.** The card carried a 32pt
  monogram, the brand name and a filled black FOLLOW slab at the top, with the pairing chip
  under it — about a hundred and eighty points of furniture across the top fifth of the
  picture. On a packshot that sits on empty sweep and costs nothing, which is why it survived;
  on a full-bleed model shot the wordmark was across a face and the slab across a shoulder. A
  tab whose cards *are* photographs cannot spend its best screens covering them. What is left
  on the artwork is the caption — who made this — small, over a sweep fade only as tall as the
  line it carries. Every control moved into the reading, which is flat sweep with room in it,
  and `chromeTop` came down with it.
- **Follow leads the action row, and is not demoted by leaving the top.** It is still the only
  filled control on the card and it is first in reading order, which is more prominence than it
  had while competing with a picture. The row is `[FOLLOW] [bookmark] … NOT FOR ME · VIEW`.
- **Save is a button as well as a double tap, and it is the app's button.** The gesture stays —
  it is the fast one — but a gesture with nothing on screen to announce it is a feature only its
  author knows about, and keeping a garment is the second most likely thing anybody wants to do
  here. It went in first as a bordered square beside Follow, which is a second vocabulary for
  the commonest action in the app; `SaveAction` has always been a bookmark in a circle on the
  **corner of the photograph**, on the feed cards and the product page alike, so it matches that
  exactly. It cannot *be* `SaveAction` — that one takes a `BrandUpdate` and a discovery card has
  no row — so the two have to be kept in step by hand. It appears on `.pairing` alone: on a
  release or a brand card the hero is a wall of *other* products, so a bookmark there would be
  keeping something that is not on screen. Vermilion once kept, like everywhere else. `isSaved`
  is computed once for the whole scroll and keyed on the **product** id as well as the event id,
  for the reason `DiscoverSave.existingRow` is.
- **The pairing chip moved into the reading and became the way into the fit.** It was a panel
  over the photograph reading "GOES WITH · your Kith Mesh Donovan Jersey", and the argument for
  it — a claim with your own jacket beside it is checkable at a glance — was right and never
  required it to be *on the picture*. In the reading it sits next to the headline it belongs
  with, and it is a button: `FitStudio`, built around the card's own garment. That was the
  missing route. The card says this piece goes with something you own, and the next question is
  always *what would the whole thing look like* — until this the answer lived behind a product
  page, two taps away, on a garment from a brand you would have had to follow first. It
  replaces the context label rather than sitting under it ("GOES WITH WHAT YOU OWN" above
  "Goes with your Kith Mesh Donovan Jersey" is the same sentence twice) and carries the
  ranking's own reason on the small line.
- **A refused brand stays refused, including on pages fetched afterwards.**
  `forget(brandID:)` drops that brand's cards out of `held` on the tap, and that was the whole
  mechanism — so the refusal held exactly until the next page arrived. The server pages by
  depth and knows nothing about dismissals (deliberately: what somebody turned down never
  leaves the phone), so the brand came back three cards later, from the tab whose one negative
  signal is meant to be permanent. `DeckContext.dismissed` was already being assembled and
  passed in, and `rank()` never read it.
- **A re-rank must not move the card somebody is looking at** (`DiscoverDeck.pinningRead`).
  Every input to the ranking changes while the feed is open: saving a garment changes the
  wardrobe, which changes `deckContext`, which re-ranks — so keeping something could shuffle
  the deck under the reading thumb and leave a different card in front of you than the one you
  just acted on. Seen live, before and after. `seenSet` is the line, and it already means
  exactly "has been reached"; cards behind it keep the order they were read in, everything
  ahead is ordered freely. Same family as `FeedView`'s brand ordering and the reason
  `Discovery.order` has no RNG in it, reached through a door neither was watching.
- **The filter is a header, not a floating button.** It was a funnel glyph in the bottom-right
  corner and was wrong three ways at once, each of which this file has a rule against elsewhere.
  It **never said what it was**, so the only way to know the feed was narrowed was to open the
  menu — a filter you cannot see is indistinguishable from a broken feed, which is why the size
  profile reorders instead of hiding and why `SavedView`'s facet chip is always visible while it
  applies. It was **two taps to pick between five words**. And bottom-right on a full-screen
  paging scroll is **where the scroll is driven from**, so the page's one control sat under the
  gesture that operates the page. It is now a row of tracked-caps chips on solid `Color.sweep` at
  the top — the same ground every card has, so it reads as the top of the page rather than as
  something over it — and tapping the active one clears it. The card's brand row insets itself
  below it by hand (`DiscoverCardView.chromeTop`), because the feed ignores safe areas.
- **The mosaic fills the frame, and the wire carries eighteen photographs.** A brand card is
  headlined with a wordmark and its whole job is *what does this label make*; it was answering
  with **six** — a square nine-up grid, centred between two `Spacer`s, cut to whole rows out of
  the eight images `discoverSpread` sent. Two faults compounding: the card looked unfinished, and
  six garments is a shelf, not a catalogue. Now the tiles are sized to the space rather than the
  space being what is left over from the tiles — three across, as many whole rows as fit, capped
  at six — and `discoverSpread` is 18 (`discoverFetchPerBrand` widened to 24 to draw them from,
  which is **not** what the cursor advances by). It is the one number in that route where payload
  buys something the reader can see: a second round trip per card is not available in a scrolling
  feed, so what a card can say is exactly what was sent with it.
- **A brand card prints no product blurb.** `summary` is the storefront's description of the one
  garment that happened to carry the card, and the headline above it is the *brand* — so the
  fallback printed "The NY Yankees Fire Curve Logo Tee features oversized lettering…" directly
  under "Billionaire Boys Club". Same mistake the price and the size run were making on that
  card, same fix: a line that describes a garment belongs only on the card that is about one.
  `makesLine` or nothing; the mosaic is already saying what the label makes.
- **There is no generative try-on and there should not be.** It bills per image in a feed built to
  be scrolled, puts a synthesised picture of a real buyable product in front of someone in an app
  whose thesis is that it never asserts what it hasn't observed, and a user photo is a likeness
  leaving the device. The cut-out composite answers the same want with one on-device Vision call.
- **The catalogue is finite and the feed says so.** A deck that starts again at the top is
  claiming to have more.
- **`-seedSaves 8`** fills the wardrobe **across complementary slots**, because `Pairing` gates on
  slot before it scores anything and eight t-shirts produce no pairings at all — a screen that
  looks broken entirely because of the seeding.

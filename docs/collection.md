# The collection

Part of the streetw guidance set; see `CLAUDE.md` for the index and the build rules.

## The collection

- **The collection is one profile's.** Each profile has its own SwiftData store, so saves, boards,
  fits, the style statement and everything `TasteScope` counts are partitioned by the container
  rather than by a predicate — no query here needs to know profiles exist, and none can forget
  to. The holder's is the store every earlier build wrote. See `docs/profiles.md`.
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
  - **It clears the buy bar.** Anchored above the tab bar — over the cards it would cover the
    next ones being read — but a product page puts its buy button there, and covering it for
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

- **Boards are filters, not folders.** `Board.saves` deletes with `.nullify` — removing a
  board must never take the saved things with it. `SaveType` (Inspiration/Wardrobe) is a
  separate axis and an item can be on both.
- **…and a save can be on several boards** (`SavedItem.boards` ↔ `Board.saves`, many-to-many,
  a cascade in neither direction). 1.0 had a to-one `SavedItem.board`, which made a board a
  folder in everything but name: the jacket from the Tokyo trip could be on "Tokyo" or on
  "Outerwear", and filing it on the second silently took it off the first. Every picker is a
  set of toggles now, and `CollectionEdit` is the one place that files, unfiles and guards the
  no-op write (`context.save()` invalidates every `@Query`).
- **The old filings were moved by a launch pass, not by a schema migration plan.**
  `BoardFiling.adoptLegacy` runs in `streetwApp.init`, before any view exists, copies each
  `board` into `boards` and clears `board` **in the same save** — so it is atomic, idempotent
  (the second launch finds nothing) and cannot resurrect a filing somebody later removes. The
  alternatives were both worse for stores already on phones: a `VersionedSchema` has to restate
  all eight models exactly as 1.0 shipped them, and one mismatch is a container that will not
  open; changing the cardinality in place relies on Core Data inferring that a foreign key
  should become join-table rows, which is undocumented. Adding a brand-new relationship is the
  one change a lightweight migration cannot get wrong. Verified by installing over a store
  written by the 1.0 build (five filings across two boards, one with a note): all five arrived
  in the join table, `ZBOARD` was empty, nothing else moved. **`SavedItem.board` and
  `Board.items` stay in the schema and are read by nothing else** — do not reuse them, and do
  not delete them until every install has launched a build with the pass.
- **Select mode is the platform's, and it works the same on every view of the wall.**
  "Select" in the bar, taps toggle, a row above the tab bar acts on the lot: Boards (a sheet
  with all/some/none per board — a partial selection is filed, a full one unfiled), Take off
  (on a board page only, and unasked, because nothing is lost), Keep as, Fit, Taste and Delete.
  Delete is **always** confirmed, unlike one bare bookmark: it is the one place a single tap
  removes many things, any of which may carry a note. The selection holds only what is on the
  wall — switching filter, searching or an action that moves items out of view drops them,
  because an action on things you cannot see is not one you chose. Both toolbar items are
  trailing; a leading text button beside `.searchable` folds into a "···" menu. Tiles are
  guarded with `SavedItem.isGone`, the `Fit.isGone` rule, because a bulk delete removes rows a
  lazy stack may still draw for one pass. Two details found by driving it: the bar's labels set
  their own ink, which `.disabled` does not dim, so `SelectionBarLabel` reads `isEnabled` — with
  nothing selected every action was drawn as if it would act; and the delete confirmation hangs
  off the Delete button, because on iOS 26 it is a popover pointing at whatever it is attached
  to, and from the page it pointed at the title.
- **A fit started from a selection is not stored until it is saved.** `FitCanvas(fit: nil,
  starting: .pieces(_:), board:)` lays the pieces out with `FitArrangement` (stepping apart two
  that want the same spot) and files it on the board it was begun from; closing the canvas leaves
  nothing. It is the contract the Style tab's one-tap keep learned the hard way, and every way into
  a fit now keeps it (`FitCanvas.Opening`): a suggestion tried from Saved › Fits, and an outfit
  built around a product, a save or a Discover card, whose unsaved garments are kept only when the
  fit is (see `docs/fits.md`).
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
  so results appear as they land, and stamps `analyzedAt` even on a *definitive* failure so
  a dead image URL isn't retried forever. Running it over a catalogue sweep would analyse
  250 items nobody kept. It **drains** the backlog rather than stopping after one batch: the
  view only re-runs it when the save count changes, so a single batch left everything past
  the first dozen unmeasured — and an unmeasured item is a tile drawn to a guess.
- **A photograph that did not answer is not a photograph that never will.** That write-off
  fired on *any* failure to fetch — and it stamps `analyzedAt`, `analyzedImageURL`,
  `cutoutVersion` and `visionVersion` all at once, which is every "is this due" test the
  app has. So one second offline, one CDN timeout or one rate limit cost that item its
  cutout, its colours, its silhouette and its measured aspect **permanently**: every version
  field current, nothing left to notice. On the fit canvas that is a garment drawn as its
  raw product shot — a white rectangle sitting next to pieces that lifted fine, which is
  what it looks like from the outside. `ImageTagger.load` now separates `.gone` (a 4xx, or a
  200 carrying something that will not decode — asking again gets the same answer) from
  `.unavailable` (offline, timeout, 429, 5xx), and only the first is written off. Two
  consequences worth keeping: `analyzeBatch` returns how many it *resolved* rather than how
  many it looked at, or `analyzePending`'s drain loop spins forever against an offline
  network re-requesting the same twelve URLs; and repairing the rows already written off
  needs a **version bump**, which is why `Cutout.version` and `VisualReading.version` are
  both at 2 — nothing else would ever revisit them.
- **…and an item that stays due must not be re-asked on every appearance.** The rule above is
  right and it has a cost: the item never leaves the backlog, so every arrival on Saved or the
  fit canvas builds a queue containing it and re-fetches the same URL. On a brand whose domain a
  DNS filter blocks — which is indistinguishable from offline, from the phone's side — that
  is one save re-requested through `URLSession`'s own timeouts on every visit, forever.
  `ImageTagger.resting` is a five-minute cool-off keyed on the photograph's URL: **in memory,
  never written to the store, nothing stamped**, so it is a pause and not a verdict and a
  phone that comes back onto a network heals by itself. It lives inside `ImageTagger.isDue`
  rather than in either caller, because the queue builder and the `.task(id:)` key must go on
  agreeing exactly — a key that says there is work and a selector that finds none re-runs the
  pass for nothing.
- **…and a write-off says which photograph it wrote off.** Both `.gone` branches stamp every
  version field the app has and take the row out of the pass permanently, and both were
  silent, so a garment drawn on the canvas as a raw product shot had nothing anywhere
  connecting it to the URL that 404'd — ImageIO's own `Error -17102 decompressing image`
  names no URL either. They now log the address, and the undecodable branch logs the byte
  count with it, because a few hundred bytes is an error page served as a 200 and a megabyte
  is a real image in a format this OS cannot read. A third case joined them: an
  `imageURLStrings.first` that will not parse as a `URL` at all — which an `og:image` from an
  arbitrary shared page can be — was skipped without a stamp, so it sat in the backlog
  forever and kept it non-zero. It is written off on the same terms, and safe for the same
  reason: the stamp records the string, so a later `repair` that puts real photographs on the
  row makes it due again through `hasUnreadPhotograph`.
- **The first photograph is not necessarily a photograph of the product** (`ProductShot`).
  The app measured `imageURLStrings.first` for everything — cutout, dominant colour,
  silhouette — and the gallery's order is a merchandising decision, not a convention.
  Stüssy publishes its in the order `_3, _4, _5, _1, _2`: four model shots and one packshot,
  **model first**. So `Cutout` did exactly its job and lifted the subject of that
  photograph, which is a person: a saved shirt arrived on the fit canvas as a whole model in
  trousers and boots, `Silhouette` filed a human outline as the shape of a shirt, and the
  dominant colour came off a lookbook background. The signal is that **a packshot has nobody
  in it**, and it is clean — measured against a real Stüssy gallery, Vision's human-rectangle
  detector finds a person in four of five images and none in the fifth, which is the
  packshot. Three properties are load-bearing. It **only reorders, never removes**: every
  photograph is still saved and still swipeable, this picks which one is *measured*. It
  **costs nothing on the common case** — a brand that leads with a packshot is answered by
  one detection on an image already in hand, and no further photograph is fetched. And when
  detection is unavailable it answers *false*, which degrades to "keep what the brand put
  first" rather than wandering the gallery. `packshotURLString` is stored beside the images
  rather than replacing `primaryImageURL`, because the lead shot is still what the feed,
  Discover and the product page show — but `FitPieceImage` falls back to the packshot, and
  **`FitRender.warm` has to ask for the same URL at the same width** or the renderer finds an
  empty cache and writes a fit with a hole in it.
- **On the wall and on a save's own page, the packshot is the cover** (`SavedItem.coverURLString`).
  This reverses the line above for exactly two surfaces, on purpose. A feed card is an
  announcement and the styling is part of it, so the feed and Discover keep the brand's first
  photograph. A wall of things somebody kept is a collection of *garments*, and Stüssy's
  model-first galleries put a person in boots on the wall to stand for a shirt. The order is a
  cover chosen by hand ("Set as cover", on the photograph in `SaveDetailView`), then the
  packshot, then the lead shot — so **where no packshot is known nothing changes**. Both stored
  answers are honoured only while they are still one of the product's image strings, because
  `SharedSaveImporter.repair` can replace a share's whole gallery. The page's gallery *leads*
  with the cover and is never filtered (`SavedItem.galleryURLs`); a colourway's photograph is
  found in it by URL, since the catalogue's index is into the brand's order. Choosing the
  photograph the automatic rule would pick anyway **clears** the choice rather than pinning it,
  which is the way back and means a better packshot found later still arrives. **The cover is a
  display choice and nothing else**: the cutout, the colour and the silhouette are still
  measured on the packshot, and a fit's piece still falls back to it — somebody choosing a
  lookbook frame to *look at* has not said it is a better photograph to *measure*.
- **The wall's tile shape is the cover's shape.** `imageAspect` is measured on the photograph
  `ImageTagger` analysed, which is the packshot — so until this the wall drew the lead shot in
  a tile shaped for the packshot, letterboxing every model-first gallery. It is now written
  whenever the packshot is chosen, not only when the tags are due, so a pass that re-picks it
  for the cutout alone keeps the tile honest. A cover chosen by hand carries its own
  `coverAspect`, read off the copy the gallery has just drawn. The wall still never crops.
- **`Seamless` cannot lift a light garment off a light sweep, by construction**, and that is
  a correct refusal rather than a bug. Measured against real catalogues: it lifts 10/10 of
  Kith's photography (border spread 0.000, erasing ~90%), and refuses a white BAPE crewneck
  because the flood fill reaches 97.4% — the garment and the backdrop are the same colour,
  so the only alternative to refusing is erasing the product. Vision's subject lifting is
  what covers that case, which is another reason the canvas is genuinely worse in the
  Simulator than on a device.
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

## Leaving things out of your taste

Every engine that infers taste used to read the whole collection, which is wrong in two ordinary
ways: a board kept for somebody else taught them the wrong thing for as long as it existed, and a
person is not one taste — suits and streetwear are one wardrobe in two moods. A board now has a
`TasteMode` (*counts*, the default; *doesn't count*; *inspire me from this*, the mood) and a save
has its own "don't use for my taste" (`isExcludedFromTaste`).

- **One rule, in the core, and every consumer asks it.** `TasteRule.role` turns a save's flag and
  its boards' modes into *ignored*, *counts* or *mood*; `TasteScope` (in the app) gathers what that
  needs and hands out the sets below. A reading on one tab built from a different set than the
  ranking on the next is how a count starts to look broken, and five consumers each filtering by
  hand is how that would have happened. Precedence: the save's own flag beats everything (the most
  specific statement there is), the mood beats a board that doesn't count (put there on purpose,
  and current), and that beats the default (which is not a statement).
- **Who reads which set**, and the reason for each line:

  | Consumer | Reads | Why |
  |---|---|---|
  | Your taste (`StyleProfile`), its facets (`CollectionFacet.matches`) | `counted` | It is a reading of you. The facet asks the same saves the same question, or "Black · 12" opens onto fourteen |
  | Brand suggestions' taste vector (`BrandRecommendations`) | `weighted` | Inferring taste; the mood leant on |
  | Discover's taste vector (`DiscoverFeedView.deckContext`) | `weighted` over the pairing pool plus the mood's saves | Inferring taste; a mood of tailoring kept as inspiration is exactly what leaning on it should read |
  | "Goes with your …" (`GoesWith`), the canvas's shortlist around one garment (`FitProposal`), Discover's pairing and `WardrobeGap` | `pairingPool` | What you *have*: the wardrobe whatever its setting, because owning something is a fact and liking it is not. Only the everything-kept fallback goes through the rule — there a save stands in for "you", and one you said is not you is the one known not to be |
  | Fit suggestions and their gaps (`FitSuggestions`, `FitCandidates.gaps`) | `fitPool`, leaning on the mood | The wardrobe, plus the inspiration that counts |
  | What's missing | the wardrobe, else `counted` | Same as the pairing pool, for the same reason |
  | The fit canvas tray, a fit started from a selection | everything | A person choosing pieces is not an inference |

- **The mood carries half of a taste vector, however small the board is** (`TasteRule.weights`).
  Each mood save weighs `max(1, ordinary / mood)`, so the board together weighs as much as the rest
  together. A fixed multiplier does not survive a real collection — six suits against two hundred
  saves at three times the weight is a mood that does nothing — and replacing the vector outright
  would forget that it is the same person. Thresholds (`minimumSavesToRank`, eight) count distinct
  saves, never weight: a mood board of three is not a taste of eight because it is leant on. The
  fit row leans by sorting the mood's pieces into the search pool first and lifting a proposal by
  `moodLean × share of it that is the mood`; it reorders and never admits.
- **One mood at a time** (`CollectionEdit.setTaste`). Choosing one puts any other mood board back
  to counting, which its own menu then shows. Two boards each claiming to be the source of taste
  would be two leans averaged into neither.
- **It is said wherever it changes something.** A board on anything but the default says so under
  the mode strip, and the line is the menu that changes it; the taste reading on You says how many
  saves it left out, and the fit row says which board it is leaning towards; a save's own page
  says when a board, rather than its own chips, is deciding. A setting that changes three tabs and
  is visible only inside a menu is indistinguishable from those tabs misbehaving. The line *is* the
  menu, with the three choices inline — a submenu there was a menu whose only item was a menu.
- **A facet opened onto a board that doesn't count finds nothing, and the page says why.** The
  facet narrows whatever the wall is showing, and it asks only about saves that count — so on such
  a board every facet is empty, and the old copy called the board empty while it was full.
  `SavedView.emptyAction` now says nothing *that counts* reads as that facet.
- **It never hides anything.** Left-out saves are on the wall, in search and on their boards
  exactly as before — the rule is about what the app *learns*, which is the same promise the style
  statement and the size profile make.
- **Every derivation keyed on the collection is keyed on the scope too.** `TasteScope` is
  `Equatable` and sits in the fingerprints of `YouView.TasteMemo` and `FitsPage.ReadingMemo`,
  `BrandRecommendations.Key` and
  `DiscoverFeedView.DeckKey`, because flipping one save's flag or choosing a mood changes no count
  and no photograph stamp — without it the reading would go on including the save until something
  unrelated moved. The consumers that need boards ask only for `Board.shapingTaste`, the boards
  with a setting, which is usually none.
- **Local, like everything else about taste.** Board modes and the per-save flag never leave the
  phone; the taste vectors are computed here and only the comparison uses what the server sent.

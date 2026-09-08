# The collection

Part of the streetw guidance set; see `CLAUDE.md` for the index and the build rules.

## The collection

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
  - **It clears the buy bar.** Anchored above the tab bar — `quickSave` owns the horizontal
    drag on the lower half of a feed card, so anything laid over that region fights a gesture
    for the same pixels — but a product page puts its buy button there, and covering it for
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

- **Boards are filters, not folders.** `SavedItem.board` is optional and
  `Board.items` deletes with `.nullify` — removing a board must never take the saved
  things with it. `SaveType` (Inspiration/Wardrobe) is a separate axis and an item can be
  on both.
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
  right and it has a cost: the item never leaves the backlog, so every arrival on Saved or
  Style builds a queue containing it and re-fetches the same URL. On a brand whose domain a
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
  rather than replacing `primaryImageURL`, because the lead shot is still what the feed, the
  gallery and the collection wall should show — but `FitPieceImage` falls back to the
  packshot, and **`FitRender.warm` has to ask for the same URL at the same width** or the
  renderer finds an empty cache and writes a fit with a hole in it.
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

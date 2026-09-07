# Fits

Part of the streetw guidance set; see `CLAUDE.md` for the index and the build rules.

## Judging a whole outfit is not judging its pairs

`Pairing` answers "does this go with that", and every fit was ranked on the verdict for its top
against its bottom alone. That is a reasonable way to *build* an outfit and a poor way to judge
one: the rules people actually use when they look at a finished fit are properties of the whole
thing and are invisible from any pair inside it. `Outfit` is those rules, and each was written
against a real collection the pairwise scoring had already passed.

- **The base is the *worst* pairwise verdict, never the average** — the rule
  `FitSuggestions.accompaniment` and `FitStudio` already followed. A jacket that goes with the
  trousers and fights the shirt is not a good jacket for this outfit, and an average lets one
  strong agreement hide one real clash.
- **One colour among neutrals beats monochrome, and the margin is deliberate.**
  `ColorHarmony` rates two identical colours at 0.9 and a colour against a neutral at 0.8, so on
  a wardrobe that is four-fifths black — which is most streetwear wardrobes — the all-black fit
  outranked every fit with anything in it and the row showed six of them. That is not taste
  going wrong, it is a ranking doing what it was told on a distribution nobody checked it
  against. The focal bonus is 0.15 because anything smaller left the two exactly level, and a
  tie is decided by the id, which is to say by nothing.
- **Past three colours an outfit stops reading as chosen**, and a colour worn twice ties one
  together — the echo takes the card's line ahead of the colour shape, because "Olive picked up
  twice" names a decision where "Olive against neutrals" describes what the picture already
  shows. Accents count for the echo: the point of the trick is a small amount of a colour
  somewhere else.
- **Volume only ever rewards** (`Pairing.volume`). A wide top over a narrower leg is the
  proportion nearly every worn outfit has, it is measurable off the cutout, and it is worth the
  line it prints. What it deliberately does **not** do is mark down volume on volume — that is
  the rule every styling guide states next and it is wrong here for the same reason a formality
  rule is absent from `Pairing`: an oversized hoodie over an oversized leg is the house style.
  Measured on a real collection, the penalty version marked down a boxy Bape zip hoodie with
  wide pleated sweatpants, which is the outfit that wardrobe exists to produce.
- **Every rule falls silent rather than scoring down when it has nothing to read.** Most
  wardrobes are half-unanalysed at any moment and Vision does not run in the Simulator at all,
  so an outfit nothing has looked at must score exactly as it did before `Outfit` existed.
- **A set is one row occupying two positions** (`GarmentClassifier.isSet`, `Garment.occupied`).
  A tracksuit is filed under whichever half its title names, and the other half then looks
  vacant — so the engine put a second hoodie with it, which is not an outfit anybody would
  recognise. Refused rather than scored down, like the slot gate. The word list is deliberately
  narrow and a bare "set" is **not** in it: brands sell a "Pin Set" and a "Tees 3 Pack", and a
  false positive removes a whole position from the wardrobe where a miss costs one proposal.
  A set naming neither half is placed as a top rather than left `.unknown`, or the one garment
  that is a whole outfit could never appear in one.
- **The row is spread, not merely sorted** (`FitSuggestions.spread`). Ranking alone produced six
  proposals built from the same two or three garments, and no sort notices it is printing the
  same shirt six times. Cards are chosen one at a time against what is already in the row, with
  a garment shared with the *neighbouring* card weighted a hundred times heavier than one shown
  earlier — adjacency is what reads as the app repeating itself, where the same trousers two
  cards apart is just a wardrobe with one pair of trousers in it. Selection and ordering are the
  same pass, because doing them separately still left the *first three* cards identical, which
  is the only part anybody sees without scrolling. No RNG: scrolling back must show the same
  cards, the property `Discovery.order` holds.
- **The search is the whole cross product of a bounded pool**, not a diagonal walk of an
  unbounded one. The diagonal visited `max(tops, bottoms) · 2` combinations and could only ever
  produce pairs whose indices agreed modulo the list lengths, so most of a wardrobe was never
  considered. Building each `Garment` once (they run two classifiers and a vocabulary set) makes
  sixty-four combinations cheaper than the sixteen used to be.
- **"Accessories" is a shelf, not a garment.** `productType` outranks the title everywhere else
  and should — a shop filing something under "Sweatshirts" knows what it is — but the accessory
  rail is the catch-all: a cap named "ACW* x Rally Cap Optic" and a "TEES 3 PACK" were both
  filed there, so the cap could never be proposed as headwear and was drawn down at shoe level
  on the canvas. An accessory read off the category is held as **provisional** and used only
  when nothing more specific answers.
- **A black garment under cool light was being named Navy** (`ColorNamer`). HSB saturation
  divides by brightness, so three hundredths between the channels reads as a quarter of a
  "saturation" once the pixel is dark. Measured on a real collection it named **sixteen of
  twenty-eight** garments navy, including one titled "washed black" and shorts called "Onyx" —
  so the style profile reported the wardrobe as navy and every fit read "All navy". An absolute
  chroma floor fixes it, and a *second*, higher floor guards the dark band, which assigns a hue
  with no saturation test at all. Real navies separate four times as far and are untouched.
  This is a re-naming rather than a re-measurement, and nothing re-derives a word — hence
  `VisualReading.version` 5.

## Fits are a canvas, not a form

`FitCanvas` replaced a three-slot picker. An outfit is not a schema: the moment you want to layer
two jackets, add a bag, or lay something out flat rather than person-shaped, slots say no — about
exactly the things that make an outfit yours. Free position, scale and rotation, and **no
snapping**, because a grid turns a collage back into a form.

- **The ground belongs to the fit, and it is fixed** (`FitBackground`, `Fit.backgroundName`).
  The canvas was adaptive `Color.paper`, so an outfit arranged in the afternoon was a different
  picture at night — and `FitRender` laid it over an adaptive `Color.paper` too, which baked
  whichever appearance the phone happened to be in into the PNG **permanently**: a fit saved
  after dark was a black picture in the share sheet at noon. Same fact as `Color.sweep`, one
  surface further on: a garment photographed on white does not invert, so what it sits on must
  not either. `FitCanvasSurface` draws the ground now, so the editor, the card, the render and
  the studio's preview cannot disagree about what an outfit is composed against.
  **A short list of grounds rather than a colour picker.** The base is and stays the app's own
  paper tone; the rest exist for when a black jacket needs something other than off-white
  behind it. The app is achromatic apart from one accent, and a control with sixteen million
  answers in it is a decision nobody asked to make. Stored as a **token, not a hex**, so
  re-tuning `bone` later reaches every fit that chose it rather than freezing the old value —
  the same rule as everywhere else here: store the verdict, not the rendering of it. An
  unrecognised token falls back rather than failing, so a fit written by a newer build still
  opens.
  **And one you mix yourself**, at the end of the row rather than in place of it. Seven answers
  is a curated palette; seven answers and no way past them is a palette that has started saying
  no, and the case it cannot cover is real — a fit built around one garment, on a ground chosen
  to sit against *that* garment. `FitBackground.custom` stores a hex, which is the **one** place
  here that stores a rendering rather than a verdict, and that is the only honest option: a
  token exists so re-tuning the palette reaches every fit that chose it, and there is no palette
  behind a colour somebody mixed. `chosen(_:)` snaps back to a preset when the wheel lands on
  one, so picking bone does not mint an identical-looking eighth ground beside it, and `ink` is
  **measured** from perceived luminance rather than looked up — the empty-canvas invitation is
  drawn in it, so getting it wrong means an invisible instruction on a blank screen.
  `FitGroundPicker` is **swatches, not a menu**: a colour named "Clay" in a list is a word, and
  the whole question is what the garments look like against it. The selected one is marked with
  a ring rather than a tick, because a tick has to be drawn *on* the swatch in a colour that
  reads on all seven, and on chalk and on slate it cannot be the same one. Anything drawn on
  the canvas takes `FitBackground.ink` rather than `Color.ink`, or the empty-state invitation is
  white on bone at night.
- **Slots did not die; they stopped being the interface.** `GarmentSlot` still filters the tray and
  still drives `FitSuggestions`. Canvas for the person, slots for the machine. Deleting it would
  take the suggestions engine with it.
- **Cutouts are what the screen depends on.** Raw product shots are white rectangles overlapping
  white rectangles. `Cutout` lifts the garment with Vision's on-device subject masking, once, in
  the `ImageTagger` pass that is already decoding the photograph — not per drag. Like the
  classifier, **it does not work in the Simulator** ("Failed to create espresso context"), so the
  canvas there looks like a mood board and that is not a bug. `FitPieceImage` falls back to the
  original, which is also the permanent answer for anything with no single subject to lift.
- **A brand that ships transparent PNGs has always looked like the cutout worked.** Palace publishes
  3200² PNGs with an alpha channel; Kith publishes 2000² JPEGs on a flat `#EBEBEB` sweep. So a
  Palace item lands on the canvas as a sticker with `Color.paper` showing through whether or not
  anything was ever lifted, and a Kith item lands as a grey rectangle — which reads as "the cutout
  works for one brand and not the other" when in fact it had never run for either. It is the same
  fact behind the two backdrops in the feed and on the collection wall: `UpdateImage` draws
  `Color.wash` behind a `.fit` photograph, so a transparent PNG shows the app's cream and a JPEG
  shows the photographer's grey. Check the pixels before believing a brand-specific bug.
- **`Seamless` is the fallback for when Vision won't, and it is all refusals.** Subject lifting
  produces nothing in the Simulator, which makes the whole canvas un-buildable there, and it can
  decline on device too. `Seamless` deletes a uniform studio backdrop instead — it knows nothing
  about clothes and must never pretend to, so it only fires when the border is flat, light and
  opaque, and it bails when the fill removed almost nothing or almost everything. Two details are
  load-bearing: the fill is **flood-filled inward from the frame's edge**, never a global
  colour match, because the white square of a graphic print and the gaps between a shoe's laces are
  the same colour as the sweep and a global pass punches holes through the garment; and the rim is
  **feathered** afterwards, because a hard threshold stops on the garment's anti-aliased edge and
  leaves a pale halo of the sweep it was cut from.
- **The fill matches the border's colour and nothing else, and that has been tried the other way.**
  The obvious improvement is a per-step tolerance as well, so a sweep with a gradient in it (paper
  falls off towards the bottom of a frame) is followed rather than abandoned halfway. Measured at a
  step tolerance of 0.035 against six real Kith shots it erases *more* — 0.895 → 0.927 of the frame
  on one — and what it erases is the garment: a running shoe's white midsole is a couple of percent
  from Kith's `#EBEBEB` sweep and shades into it gradually, so the fill walks in off the backdrop
  and hollows the sole out, and on a white sneaker it takes most of the upper. Any rule that lets
  the fill reach a light garment through a soft edge will eat light garments.
- **A lift is verified before it is believed, and both paths go through the same gate.** Until
  `Cutout.version` 3, anything Vision returned was written to disk unexamined — `Seamless` has
  three refusals and Vision had none. Two failures came out of that. Vision returns a *speck* as a
  foreground instance (a hanger, a care tag, a hard shadow), and taking `allInstances` wholesale
  drags the crop out to enclose it, so a hoodie arrives as a hoodie in the corner of a much larger
  transparent rectangle. And on a busy or low-contrast photograph it returns a foreground covering
  essentially the whole frame, which produces a "cutout" indistinguishable from the product shot —
  and because a file was written, every later pass saw a lift that had *worked*, so `Seamless` never
  got its turn and no version stamp ever came back to it. `substantialInstances` drops anything
  under a twentieth of the largest and refuses a subject covering more than 0.90 of the frame,
  measured on the mask Vision hands back at its own resolution rather than on a multi-megapixel
  render; `isSticker` then checks that what came out fills no more than 0.92 of its own bounding
  box, which is the test `Silhouette.Mask` already applied before it would *measure* an outline. The
  two disagreeing is the bug this closes: a sticker could be refused as un-measurable and still be
  drawn on the canvas. **A refused Vision lift now falls through to `Seamless`** instead of ending
  the search. Measured against real Kith photography the six good lifts fill 0.587–0.642 of their
  boxes, so the gate refuses none of them.
- **`Cutout.remove` forgets the decoded copy, and that is half of what it is for.** A cutout's
  filename is derived from the item id, so re-cutting overwrites the same path — and `LocalImage` is
  keyed on that path. Without the `forget`, bumping the version did everything it was supposed to
  (re-fetch, re-lift, write a better PNG) and the canvas went on drawing the *old* sticker out of
  the in-memory cache for the rest of the session. `FitRender.remove` had always got this right.
- **`ImageTagger` fetches the photograph at the size it is measured at.** It used to pull the
  full-resolution original and decode it with `UIImage(data:)` — which produces no pixels, so the
  whole multi-megapixel decode landed on the main thread inside `Histogram`, twelve times a batch,
  in a loop that drains the entire backlog. It now asks `ImageRendition.sized` for the same
  rendition `FitPieceImage` draws (so the two share a `URLCache` entry) and rasterises through
  `ImageLoader.decoded`. Nothing downstream wanted more: `Histogram` samples 48², `Silhouette` 256,
  `Seamless` works at 1200. The lift also only writes a PNG when the cutout is actually due —
  `needsCutout || needsReading` runs it, and encoding a full-resolution RGBA PNG to overwrite a
  current file with its own contents was the most expensive no-op in the pass.
- **Bumping `Cutout.version` means bumping `VisualReading.version` with it.** The silhouette is
  measured by `Silhouette` and stamped under `visionVersion`, and its only input is the cutout mask.
  `ImageTagger` runs the lift when either is due but writes the silhouette only when the *reading*
  is — so bumping the cutout alone re-cuts every sticker and leaves every shape measured against the
  mask that was just replaced.
- **The cutout carries its own version, because `analyzedAt` cannot speak for it.**
  `ImageTagger` used to select on `analyzedAt == nil` alone, so every item analysed before cutouts
  existed was already stamped and never revisited — the whole established collection stayed
  sticker-less and the canvas was a mood board *on device too*. `Cutout.version` beside
  `BrandUpdate.cutoutVersion` is the `genderVersion` pattern: a row from an older build decodes 0,
  is stale, and gets one more look. It is stamped even when nothing was lifted (a flat-lay has no
  subject and must not be re-cut every launch), so a nil `cutoutFile` at the current version means
  "there is nothing here", not "nobody asked". Bump the version whenever the lift changes.
  `StyleView` runs the pass as well as `SavedView` — a fit is composed from the Style tab, and
  requiring a visit to Saved first denied stickers to exactly the person about to need them.
- **A suggestion looks at the clothes, not only at the schema.** Every rule in `FitSuggestions` was
  structural — one top, one bottom, both things you kept — so a pair could satisfy all of them and
  be obviously wrong to anyone with eyes. `ColorHarmony` reads the dominant colour `ImageTagger`
  already stored, ranks the pairings and drops outright clashes. Deliberately **not** a model: there
  is nothing to train on, and the same rule that governs the brand recommender applies here — a
  recommender that is clever and wrong is worse than one that is obvious and right. Three things it
  must keep doing: a neutral goes with anything (most streetwear is black, grey, cream or denim, so
  that is the common case and not the escape hatch); navy and brown count as neutrals, because they
  are chromatic to a colour picker and neutral to a wardrobe; and an **unknown or missing** colour
  scores neutral rather than badly — nothing has been analysed yet is not the same as having looked
  and disapproved, and Vision does not run in the Simulator at all. The candidate pool is widened
  past `limit` before ranking, or the sort is just sorting an arbitrary six. It also returns the
  line saying why, which is what the card prints: a suggestion nobody can account for is
  indistinguishable from a shuffle, which is what the row felt like.
- **Placements are normalised, never points.** `FitPlacement` stores centre as a fraction of the
  canvas, so one description of a fit lays out identically at 900px for a render and at 168pt for a
  card — and a fit made on a Pro Max doesn't scrunch on a mini. It decodes leniently by hand for the
  usual reason: SwiftData decodes a stored Codable with an internal `try!`.
- **`z` is sparse and unbounded in both directions.** Bringing a piece to the front is one write
  instead of renumbering the canvas, and sending one to the back is `min - 1` — which is the only
  way to reach something a big coat has buried.
- **A piece's size is its frame, not a `scaleEffect`.** For a `scaledToFit` image the two draw the
  same thing, but a scale effect multiplies everything laid *over* the piece with it: the selection
  outline thickens and the handles come out as thumbnails on a jacket and specks on a ring. It
  matters in `FitCanvasSurface` too — a render at 900px would otherwise be a 400pt drawing blown
  up. Anything overlaid on a piece depends on this.
- **The corner handle scales *and* turns, and it reads in the canvas' coordinate space.** A pinch is
  the fast path, not the only one: two fingers on a piece the size of a stamp is a gesture nobody
  can aim, and pinching the topmost of an overlapping stack is a coin toss. The handle it starts on
  is itself rotating and scaling as the drag proceeds, so measuring locally would have it chasing
  its own tail — hence `.coordinateSpace(.named(_:))` on the canvas. The turn accumulates from the
  previous angle rather than from the start, or a rotation past half a revolution snaps back when
  `atan2` wraps.
- **The handles live inside the piece's bounds, bought with empty padding.** A view drawn outside
  its parent is one clip away from being untappable. The padding is empty, so it draws nothing and
  catches nothing — which is what stops the gap between two pieces stealing a drag.
- **A drag out of the tray is `.draggable`, not a `DragGesture`.** The tray is a horizontal
  scroller, and any gesture that begins on touch fights the scroll for the same finger; lift-on-long
  -press does not. The payload is a prefixed `String` rather than a custom `Transferable`, because a
  bespoke UTI has to be declared in the Info.plist and this project has already been bitten by keys
  Xcode silently drops — the prefix is what makes anything else dropped on the canvas refused rather
  than parsed hopefully. Dropping something already placed **moves** it: one saved thing is one
  garment, and two of the same jacket is not a fit.
- **A drag ends with the centre still on the canvas.** The canvas clips, so an unclamped drag posts
  a garment somewhere it can never be grabbed back from. Clamping the centre rather than the whole
  frame still lets half a piece bleed off the edge, which is a real collage move.
- **Both the structure and the render are kept.** The structure is what keeps a fit editable, keeps
  it a list of things you own, and makes "one of these came back in stock" possible at all. The
  render is what a scrolling row draws without composing a canvas per card.
- **`FitRender.warm` before `write`, always.** `ImageRenderer` draws one frame synchronously and
  gives an async load no chance to finish, so a canvas of `CachedImage`s renders as a stack of empty
  tiles — which is exactly what the first saved fit produced. `FitPieceImage` reads
  `ImageLoader.cached` directly and `warm` is what guarantees it is populated, at the *same width*.
- **A fit is its own type that files onto a board**, rather than living inside one — `Fit.board`
  nullifies exactly as `SavedItem.board` does, so deleting a board never deletes an outfit.
- **The Style tab is not a settings screen.** Sizes and the gender filter moved to Settings; what
  is left is a reading of your taste and things to do with it.
  - **`StyleReading` holds every threshold that turns a measurement into a word**, because two
  copies would drift and the symptom is specific: a facet reading "Graphic · 12" that opens
  onto nine items, which reads as the count being broken. `StyleProfile.build` counts with
  it and `CollectionFacet.matches` filters with it.
- **Register sits above categories in the taste block.** "Dark, muted, plain" is a sharper
  reading of somebody than "hoodies and sneakers", which describes half of streetwear.
- **A facet is a query, not a statistic.** The taste block printed four comma-joined lines of
    nouns and ended there — the app's own reading of what you like, with nothing to do about it, on
    the page whose whole subject is you. Each word is now its own control and opens the collection
    narrowed to it, via `CollectionRoute` (the `PushRoute` shape, built in `streetwApp.init` for the
    same reason: a view that reads it appears before anything could have set it). Two details are
    load-bearing. `CollectionFacet.matches` **mirrors how `StyleProfile.build` counted**, including
    the photograph-then-text order — if they drift, a facet reading "Black · 12" opens onto nine
    items and the count looks broken. And the route carries a request *counter* as well as the
    facet, because asking for the facet you are already looking at is a legitimate way back to the
    Saved tab, and an unchanged value publishes nothing. The chip in `SavedView` is always visible
    while it applies and always removable: a filter set from another tab that you cannot see is
    indistinguishable from a collection that has lost things.
  - **"What's missing" is the one thing this tab can say that no other screen can.** The feed knows
    what is new and the collection knows what you kept; neither can tell you that you have six tops
    and nothing to put with them — which is also the reason the suggestion row is sometimes empty
    for no visible reason. Counted over `SaveType.wardrobe` when there is one, since the question is
    about what you own, falling back to everything saved because most people never split the two.
    Only over `GarmentSlot.essential`: saying somebody is short of headwear is a fashion opinion,
    and this is meant to be an observation.
  - **The tab about you ends with you, and there is no Discover block on it.** `StyleView`
    carried the same `BrandRecommendations` the feed does, headed "Discover". That was right
    while Discover was not a tab of its own; it is one now, so the page was making the same
    offer twice and in the weaker voice — a strip of six brand cards under a reading of
    somebody's wardrobe, against a full-bleed tab whose every card argues from the clothes
    they already own. The note that used to sit here said the block belonged *below* the taste
    reading so the tab about you did not open as a shop. Right instinct, applied to something
    that should not have been on the page at all. The recommendation block now lives on the
    feed's tail and inside `BrandsView`, both of which are about brands.

- **"Wear it with" is the one thing an archive can say that a catalogue cannot** (`GoesWith`,
  `Pairing`). It reads both ways round: on something you haven't kept it is the argument for
  keeping it, and on something you have it is the start of a fit. The judgement is in
  `StreetwCore` beside `ColorHarmony` so this page and the fit row can't disagree about the
  same two garments. Four rules — slots must complement (a gate, not a score), colour via
  `ColorHarmony`, weight must agree, one statement piece — and the interesting one is
  **absent**: no formality penalty. A blazer with track pants is the house style here, so
  the first rule anyone reaches for would spend its time refusing the best answers the app
  has. Note also that a *fabric* is not a season: `wool` and `linen` and `mesh` were in the
  seasonal lists and the tests took them out, because a wrong refusal is invisible — the
  suggestion never appears and nobody can tell it was suppressed.
- **…and the row expands into the whole outfit** (`FitStudio`). `GoesWith` answers the question
  it was built for — *is this worth keeping* — and then stops, one tile short of the question
  everybody asks next: **what is the actual fit?** Four tiles side by side are four separate
  suggestions, and two of them are usually tops, of which only one can be worn. So the header is
  a button: the subject is fixed, every other position on the body is filled with the best thing
  the wardrobe has for it, each is one tap from becoming something else, and the result can be
  kept. Four things it inherits rather than reinvents.
  **The judgement is `Pairing`'s**, so this cannot disagree with the row it opened from.
  **The candidates are ranked once, against the subject, and swapping never re-sorts them** —
  the property `FeedView` learned the hard way; what a swap does change is the picture, which is
  the thing you asked to change.
  **The preview *is* the arrangement.** It draws from the same `FitPlacement`s that get written,
  with `FitCanvasSurface`'s geometry, so saving cannot produce a different picture from the one
  that was agreed to. Every spot is inset far enough that a piece's own frame stays inside the
  canvas — the shoe sat at 0.86 and lost its sole off the bottom of the render.
  **A fit is made of things you kept**, so anything in it that has not been is kept first, as
  `.inspiration` — the same reading `StyleView.keep` gives the same tap, and the honest one: the
  subject is what you were looking at when you decided to build an outfit around it.
  The opening arrangement is greedy over `GarmentSlot.essential` and scores a candidate on the
  **worst** of its verdicts against the pieces already chosen, never the average, exactly as
  `FitSuggestions.accompaniment` does — a jacket that goes with the trousers and fights the shirt
  is not a good jacket for this outfit. Headwear and accessories are *offered* but never
  proposed unasked, which is the line between a fit and a costume. "Save and arrange it by hand"
  saves first and then opens `FitCanvas`, because the canvas edits a stored `Fit` and handing it
  a draft would be a second, quieter definition of what a fit is.
- **…and its subject is not always something in the store** (`FitSubject`). Opened from a
  product page it has a `BrandUpdate`; opened from the Discover feed it has a card from an
  unfollowed brand, and **must not be given a row on the way in** — the deck's whole
  no-pollution rule is that a discovery card writes nothing until somebody keeps it, since
  `FeedView` queries `!isSeen` and a stored page would empty thousands of products into the
  unread feed. So the subject is an enum and the row is minted at exactly one moment: when the
  fit is saved, through `DiscoverSave.save`, which is the moment the garment has been chosen.
  Two details. The **measured photograph travels with it** — `DiscoveryAnalysis` has a sticker
  and a colour for the cards at the viewport, so the subject lands cut out and is scored on its
  real colour rather than its title alone. And the fallback when there is no sticker is the
  **packshot**, now carried on `DiscoveryAnalysis.Result`: `ProductShot` has already answered
  which frame has nobody in it, and falling back to `imageURLs.first` drops a whole model in
  trousers and boots into somebody's outfit as a stand-in for a t-shirt — the exact failure
  `ProductShot` exists to stop, reached by the back door. The *card* still shows the lead shot.
- **A position on the body is not a `GarmentSlot`** (`FitPosition`, `FitArrangement`). A fit can
  hold two tops — a hoodie with a tee under it, which is how a hoodie is worn — and the studio
  picked into a `[GarmentSlot: String]`, which can hold one. So the base layer the suggestion
  row had already been taught to require had nowhere to go, and the studio went on proposing a
  full-zip hoodie over bare skin one tap from a row that would never have offered it. The
  subject's position is excluded **by position, not by slot**, for the same reason: excluding
  the whole `.top` slot meant a fit built around a hoodie could never be given the one thing a
  hoodie needs. `Outfit.isLayeredPair` is asked before `Pairing`, whose gate refuses same-slot
  pairs by design and would otherwise refuse every layered fit the engine exists to produce.
- **One arrangement table, read by everything that lays a fit out by machine.** The studio had
  a private one and `StyleView.keep` had **none**: it wrote a `Fit` with an empty `placements`
  array, so a kept suggestion drew as a blank square on the wall and rendered as one. Worse, it
  pushed the editor immediately afterwards, so closing that without saving left the blank square
  behind anyway — a fit somebody had explicitly *not* kept, sitting in the collection with
  nothing in it. The row says "TAP TO KEEP ONE" and that is now exactly what a tap does;
  arranging by hand is what tapping the card in "Your fits" is for. The layout is a **flat-lay**
  and the positions are chosen to sit clear of each other at their stored scales — the base
  layer is the one exception, tucked smaller under the mid layer when there is one and taking
  the ordinary top spot at full size when it is the only top, because a lone tee drawn small in
  the corner reads as an afterthought rather than as the garment the outfit is built on.
- **The classifier's vocabulary is read off real wardrobes, not guessed at.** Three of eleven
  saves on the test device were `.unknown` — invisible to fits, pairings and the wardrobe's
  own slot counts — and two were ordinary clothes: Palace names its hoodies "P3 HOOD", and
  `fleece` was in no list at all. `blazer` was missing too, found by a pairing test that was
  asserting about formality and failing on the slot gate instead. Compound names still
  resolve correctly because the table is walked in slot order: "Fleece Jacket" is outerwear,
  a bare "fleece" is a top.
- **Emptying a brand's unread page leaves it** (`BrandFeedView`). That screen *is* the unread
  queue for one brand, so clearing it with the checkmark left you looking at a page whose
  entire content was the thing you just finished — which reads as the button breaking the
  page rather than completing it. `onChange`, not a check in `body`, or the `unseenOnly:
  false` route (a brand's whole history, allowed to be empty) would refuse to open.
- **The watch bell fills; it does not carry a number.** A badge is the platform's unread
  mark — something happened, deal with it, and it clears when you do. A watch count is none
  of those: it is the number of watches you deliberately set, and it comes down only when a
  restock lands, so it nags hardest exactly when the thing you are waiting for is slowest.
  A watch that fires arrives as a push and as a card in the feed, which is where news goes.
- **A saved thing is still a product.** `SaveDetailView` shows the size run, the colourways and a
  watch, not just a note field. The page had been read too literally as "what did I think" and
  dropped everything the item *is* — but the commonest reason to keep something you can't have is
  that it was sold out, and "tell me when it's back" is the one thing here a screenshot can't do.
  `ColorwaySection` and `WatchSection` are shared with `ProductDetailView` rather than restyled —
  as is `StorefrontBar`, which is *pinned* on both. On the archive it had been a small text link
  below two rows of chips, which put the page's most consequential control at the bottom of a
  scroll. Anything laid over the bottom of either page must clear it: `StorefrontBar.height` is
  what `SaveConfirmation.bottomClearance` is set to.
- **That page is in two halves and says so.** Above the rule is the garment, and it is the same
  garment anybody else would see; below it is only yours — the note, the size you own, the board,
  why you kept it. Before the `Yours` masthead they were one undifferentiated column at one
  rhythm, which is what made an archive page read as a form. The masthead carries a generous top
  margin on purpose: the watch section ends in a rule of its own, and two hairlines a few points
  apart read as a printing error rather than as a division.
- **The archive says what a catalogue cannot: what you have worn it with.** `SavedItem.fits` was
  already recorded and nothing read it, so a fit could be built out of an item and the item's own
  page would never mention it.
- **A board is made from wherever you needed one.** Both `SaveDetailView` and `FitCanvas` create
  boards inline, because that is how a board actually comes about — you find the second thing that
  belongs with the first. `FitCanvas`'s board menu in particular used to be behind
  `if !boards.isEmpty`, so somebody who had never made a board was shown no way to file anything
  and no hint that filing was possible; a menu that hides the thing you would open it for is worse
  than no menu. Filing a fit is also on the `StyleView` card's context menu, since that is where
  fits are looked at — the editor is where they are made.

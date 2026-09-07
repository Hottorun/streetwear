# TODO

Tracking document for the review of 2026-09-07. Every item names where it lives, what a user
sees, why it happens, and what "done" means. Tick the box when it is fixed **and** verified the
way the item says to verify it.

Status legend: `[ ]` open · `[~]` in progress · `[x]` done · `[?]` needs reproduction first.

**Worked through on 2026-09-08.** Every P0, P1, P2, P3, performance and docs item is closed; each
entry keeps its original text so a fix can be read against the fault it was written for, and a
**Fixed** paragraph at the end of each says what was actually done and how it was checked. The five
items under *Needs reproduction* are untouched on purpose — the section says so.

394 tests pass (up from 376), the app and the server both build with **zero warnings**, and the
first-run flow was driven end to end on an iPhone 17 Pro simulator against the production backend.
Two things this review's own reading had slightly wrong turned up on the way and are noted in the
entries: `BrandUpdate.passes` already short-circuits the gender classifier structurally (PERF-3),
and `identifySites` is already stamped and batched rather than fetching per host per foreground
(PERF-4).

Evidence marked **live** was seen by driving the app in the simulator against the production
backend; **read** means it was established by reading the code end to end but not reproduced on
screen. Nothing here is speculative — anything that was only suspected is in *Needs reproduction*
at the bottom.

---

## P0 — data loss and things that are wrong rather than missing

### [x] P0-1 · A 401 or 403 deletes the whole follow list and the feed history behind it

**Where** `StreetwAPI.swift:271` · `RemoteSync.swift:69-72` · `RemoteSync.swift:433-439` ·
`Server/…/routes.swift:103-107`

**Symptom** One refused request and the app is empty: every followed brand gone, every
`BrandUpdate` cascaded away with it, watches and poll hints orphaned server-side. Reads as "the
app lost my data", because it did.

**Cause** Three correct-looking pieces composing badly. `perform` maps **both** 401 and 403 to
`.unauthorized`. `ensureRegistered` treats that on the sizes push as "the credential is stale",
nils the token (persisted immediately by `didSet`) and re-registers — and `POST /v1/devices`
unconditionally builds a **new** `UserModel`, which by definition has no follows. The same `sync()`
pass then calls `api.follows()`, gets `[]`, and hands it to `mergeBrands(…, isCompleteList: true)`,
whose deletion pass has **no guard against an empty complete list**. A WAF 403 or an edge 401
during a deploy is enough.

**Fix** Refuse an empty `isCompleteList` batch (a complete list that is empty is indistinguishable
from a failure, and the safe reading is "don't delete"). Separate 403 from 401 — a 403 is not a
stale credential. Consider making re-registration preserve nothing rather than silently adopting a
blank identity.

**Done when** A forced 403 on the sizes push leaves the local brands untouched, and there is a test
for `mergeBrands([], isCompleteList: true)` deleting nothing.

**Fixed** `APIError` gained a `.forbidden` case and `perform` maps 403 to it, so `ensureRegistered`
— which catches `.unauthorized` only — no longer spends a working token on a WAF rule or an edge
refusal. `FollowMerge.mayPruneAbsent` (new, in `StreetwCore` so it can be tested at all) refuses an
empty complete list, and `RemoteSync.mergeBrands` asks it before the deletion pass. Three tests in
`FollowMergeTests` pin it, including the `followExisting` single-brand case. Beyond the brief:
re-registration now sets `didRegisterAfresh`, and the next `sync` re-follows every local brand
holding a `remoteID` — otherwise the app looks populated while the new device row follows nothing
and the server sends no pushes at all.

---

### [x] P0-2 · The first sync in server mode dumps the back catalogue into the feed as news

**Where** `RemoteSync.swift:331` (`merge(response.items)` — `asBaseline` defaults false) ·
`RemoteSync.swift:117` (`addBrand` never calls `catchUp`)

**Symptom** **live** — sixty seconds after a fresh install with three starter-pack brands: 200
stored rows, **all 200 unread**, feed headed *"82 new from 3 brands"*. A brand-new user's first
screen is a wall of back catalogue presented as things that just happened.

**Cause** The baseline rule is implemented in `SyncEngine.merge` (standalone) and in
`RemoteSync.catchUp` (`:198`, `asBaseline: true`) — and neither is on the path the app actually
ships. Onboarding calls `addBrand` → `discover` + `follow`, then `sync()`, and `sync` merges
everything the feed hands back as unread.

**Fix** Either baseline the first `sync()` after registration (no `feedCursor` yet ⇒ history, not
news), or have `addBrand` run `catchUp` for the brand it just followed. The first is simpler and
covers the starter pack, which follows several brands at once.

**Done when** A fresh install with the starter pack lands on "all caught up" with the brands
populated, and the next genuine drop is the first unread thing.

**Fixed**, and the obvious fix was not enough. `sync` baselines when there is no `feedCursor`, but
`ContentView` runs a sync at *launch* — before onboarding has followed anything — so on the first
attempt that empty pass took the cursor and the sync after the starter pack was no longer a first
sync. Measured exactly that way: 200 rows, 200 unread. The cursor is now only spent by a first sync
that reached something (`!brands.isEmpty`), which is the rule `SyncEngine` already states for
`Brand.lastSyncedAt`; and `addBrand` runs `catchUp` for the brand it just followed, so the baseline
is per brand as well as per device. **Verified live**: fresh install, defaults cleared, two starter
brands — 2 brands, 200 rows, **0 unread**, feed reading "All caught up".

---

### [x] P0-3 · A failed sync marks itself successful, so it is never retried that session

**Where** `RemoteSync.swift:317-320` (the `defer`) vs `:354-356` (the `catch`) ·
`ContentView.swift:143` · `FeedView.swift:510-512` · `FeedRefresh.swift:67`

**Symptom** One failed launch sync and the app does not try again until it is relaunched. The feed
prints "PULL TO REFRESH" instead of the first-run line, and `FeedRefresh` treats the failure as
fresh for 60s.

**Cause** `lastSyncedAt = Date()` is in a `defer`, so it runs whether or not `follows`/`feed`
threw. `ContentView` gates the launch sync on `lastSyncedAt == nil`.

**Fix** Stamp `lastSyncedAt` only on the success path — the same rule `SyncEngine.sync` already
follows for `Brand.lastSyncedAt` ("only a sync that reached something may spend the baseline").

**Fixed** `lastSyncedAt` is stamped on the success path only. A second field, `lastAttemptedAt`,
is stamped in the `defer` and is what `FeedRefresh.runIfStale` and `ContentView`'s launch gate now
read — without it the fix would have swapped one bug for another, since `runIfStale` returns early
on a nil and would never have retried a failed launch sync for the rest of the session.

---

## P1 — silent failure, and the first ten minutes

### [x] P1-1 · `RemoteSync.lastError` is displayed nowhere in the app

**Where** set at `RemoteSync.swift:51, 99, 108, 356`; the only reader in the whole app is
`BackgroundRefresh.swift:74`, as a boolean. `SyncEngine.lastError` likewise has no view reader.

**Symptom** Every failure in P0 and most of P1 is invisible. Registration failure, a 401 loop, a
dead network and "genuinely nothing happened" are the same screen.

**Fix** One place on the feed that can say "couldn't reach streetw". This single item closes the
user-visible half of P0-1, P0-3, P1-2 and P1-4.

**Fixed** `FeedView.syncTrouble` — a vermilion-ruled block under the brand rail carrying
"COULDN'T REACH STREETW", the error itself, and a TRY AGAIN that re-runs `FeedRefresh`. It reads
whichever engine is actually running (`settings.isConfigured`), hides itself while a sync is in
flight, and clears on the next pass that works, because `lastError` is nil'd at the top of each.

---

### [x] P1-2 · The starter pack fails silently and then latches forever

**Where** `OnboardingView.swift:478` (`try?` around `addBrand`) · `:498-500` (advances regardless) ·
`ContentView.swift:162` (`didOfferStarterPack = true` on finish)

**Symptom** With the server down: five "Checking…" labels, then how-it-works, then the permission
prompt, then a feed reading "Nothing on watch yet". No error anywhere — and because the flag has
latched, **the starter pack is unreachable for the life of the install**. Recovery is typing brand
names by hand.

**Fix** Don't latch when nothing was added. Report the failure. Let the step be re-entered.

**Fixed** `add()` counts what landed and captures the first failure. Nothing added means the step
does not advance: the message prints above the action bar, the button becomes "Try again", and the
selection is still there. A partial success advances and says so. `onFinish` now carries
`mayLatch`, and `ContentView` sets `didOfferStarterPack` only when it is true — so a run that
failed leaves the pack offered again next launch instead of out of reach forever.

---

### [x] P1-3 · The size ladders show only the small end and give no sign they scroll

**Where** onboarding step 1 (`OnboardingView.swift:242`) and `SizeProfileSection.swift`

**Symptom** **live** — the visible window is `XXS…XL`, `26…31`, `US 6…8.5`, each ending flush with
the right margin: no peeking chip, no indicator, and roughly 500pt of empty space below. They *do*
scroll (dragging reveals XXXL, waist 14 and shoe 11.5+), but a person who wears XXL or a 34 waist
sees a control that appears not to contain their size — on the first screen of the app, for the
feature the whole product turns on.

**Fix** Wrap instead of scroll (there is room), or start the window near the middle of each ladder,
or leave a half-chip visible at the edge. Wrapping is the strongest: it uses space that is empty
anyway and removes the gesture entirely.

**Fixed** `SizeChipRow` uses `FlowRow` instead of a horizontal `ScrollView`, so every ladder is
visible at once and there is no gesture to discover. One change covers both onboarding step 1 and
Settings. **Verified live**: XXXL, waist 44 and shoe 14 are all on screen, and the step now fills
the page rather than leaving ~500pt empty.

---

### [x] P1-4 · `probe` reports our failures as facts about the brand's website

**Where** `AddBrandView.swift:503` (`probed = try? await remote.probe(...)`) → `:345` → `:485-488`,
`:441`

**Symptom** A 401, a timeout or a server outage renders as *"Nothing to watch here — streetw
couldn't read anything from this site… It may be down, or blocking us."* with START WATCHING
disabled.

**Cause** The nil from `try?` cannot distinguish "the site has nothing" from "we never asked".
`search()` two functions above (`:269-286`) gets this right.

**Fixed** `probe()` catches instead of `try?`, and a failure draws its own state — "Couldn't check
this site", the reason, and a TRY AGAIN — which says nothing about the storefront, because we do
not know anything about it. The site's own refusal (`cannotMonitor`) is unchanged and still says
what it always said.

---

### [x] P1-5 · Sizes can miss the server on first launch

**Where** `ContentView.swift:143` · `RemoteSync.swift:67` · `FeedRefresh.swift:67-70`

**Symptom** Registration happens at launch with an *empty* profile; the real one is pushed by
`ensureRegistered`, which is reached via `addBrand`. **Skip the brand step** and the server holds
empty sizes until the next sync clears the 60s throttle — restock targeting is off in that window.

**Fixed** leaving the gender step pushes the profile with `ensureRegistered` (not `pushSizes`,
which is a silent no-op before a token exists). That is the moment the profile is finished, so it
no longer depends on the brand step being taken.

---

### [x] P1-6 · Notification permission is asked once and never revisited

**Where** `OnboardingView.swift:458` (result discarded, `onFinish()` either way) ·
`BackgroundRefresh.swift:113-118`, `:305`

**Symptom** Declining says nothing. "Not now" leaves the only route as Settings → Alerts, behind
the gear on the Style tab. If permission is granted later in iOS Settings, APNs re-registration
happens at **next launch only**, not on foreground.

**Fixed** both halves. A denial is said out loud on the step — "ALERTS ARE OFF", naming
Settings › streetw › Notifications — and the button becomes "Done" rather than dismissing over it.
And `PushAuthorization.registerIfAuthorized` now runs on every foreground as well as at launch, so
permission granted in iOS Settings (the only route left after "Not now") produces a token on the
next open rather than on the next cold launch.

---

### [x] P1-7 · The size profile is discoverable in two places, one of them one-shot

**Where** `OnboardingView.swift:242` and `SettingsSheet` (`StyleView.swift:713`, reachable only via
the gear in the Style toolbar, `:244`)

**Symptom** Skip step 1 and nothing mentions sizes again. `FeedView.swift:119` says "CHANGE IT IN
SETTINGS" without saying where Settings is.

**Fixed** every line on the feed that talks about the profile is now a door into it. "FILTERED TO
MENSWEAR" and the filtered-empty subhead open `SettingsSheet` directly, and a new prompt — "SET
YOUR SIZES AND RESTOCKS IN THEM ARE RULED IN VERMILION" — appears while the profile is empty and a
brand is followed. **Verified live**: visible on the first feed of a fresh install that skipped
step 1.

---

## P2 — the algorithms

### [x] P2-1 · `FitSuggestions` can never add the base layer it exists to add

**Where** `Fit.swift:619-626` → `accompaniment` at `:781-794` · `Pairing.swift:198` (slot gate) ·
the working guard is at `FitStudio.swift:594`

**Symptom** The layering rule is written down twice and enforced nowhere the suggestion row can
reach: it still proposes a full-zip hoodie over bare skin, and `Outfit.swift:119-122`'s −0.12
penalty then fires on proposals the engine had no way to fix.

**Cause** The branch is only entered when the chosen top is a `.mid`, so the first comparison in
`accompaniment` is always top-vs-top, which `Pairing`'s gate refuses ⇒ `refused = true` ⇒ nil.
`accompaniment` is a near-copy of the studio's loop with the `Outfit.isLayeredPair` guard omitted —
which `Outfit.swift:212-213` explicitly says both build sites must have.

**Fixed** `accompaniment` no longer puts a layered pair through `Pairing`'s slot gate. It still
*judges* one — on colour, which is the axis that survives the exemption — so `worst` is never left
at `.greatestFiniteMagnitude` and a base layer can finally be chosen. `Outfit.score` was changed to
match, so all three sites now treat a mid-over-base pair the same way.

---

### [x] P2-2 · `FitStudio` can never pick a second top, so the studio stalls on a thin wardrobe

**Where** `FitStudio.swift:594` (`continue`) · `:609` (treats `.greatestFiniteMagnitude` as "no
comparison, discard")

**Symptom** Subject = a hoodie with a wardrobe of tees (or the reverse): `picked` stays empty, Save
is disabled, and the screen shows a full row of candidates with none chosen.

**Fixed** by the same change in `FitStudio.best`: a layered pair is scored on colour rather than
skipped outright, so a hoodie against a wardrobe of tees picks something instead of discarding
every candidate as "no comparison".

---

### [x] P2-3 · Discover's exploration slots are inert, and strip the card anyway

**Where** `DiscoverDeck.swift:391-395` (`isFamiliar = similarity > 0`) · `Discovery.swift:297-299`
(falls back to the familiar pool) · `DiscoverDeck.swift:436-452`

**Symptom** One card in four loses its pairing and is downgraded to `.brand`, and no exploration is
bought in return — the inverse of what `Discovery.swift:199-207` intends.

**Cause** `BrandVector.similarity` averages over vocabulary, **categories and genders**, and any two
catalogues share `top`/`unknown`/`mens`, so `similarity > 0` is true for essentially every card
once there are ≥8 saves. The unfamiliar pool is therefore empty. Separately, `isExploration` is
computed on the **post-`pinningRead`** index while `Discovery.order` chose the slot pre-pin, so even
when an unfamiliar card exists it is generally not the one stripped.

**Fix** A threshold, not `> 0`; and compute the flag on the same index the ordering used.

**Fixed** both halves. `Discovery.familiarityCutoff` replaces `similarity > 0` with the median of
the page — the honest reading of "least like what you keep" on a scale with no meaningful zero, and
self-calibrating, so the unfamiliar pool is never empty. And the exploration flag is computed
against the *ranked* order and applied by id after `pinningRead`, so the card the ordering chose is
the card that is stripped. Pinned by `DiscoveryEdgeTests`.

---

### [x] P2-4 · A followed-brand card in an exploration slot renders as a wordmark on an empty card

**Where** `FollowedSupply.swift:123` (`spread: []` by design) · `DiscoverDeck.swift:441-451`
(forces `.pairing → .brand`)

**Symptom** Cards 4, 8 and 12 are blank when the deck is showing followed-brand supply before the
first `/v1/discover` page lands. Exactly the case the comment at `:404` says it prevents.

**Note** Fixing P2-3 removes most occurrences; the guard is still needed.

**Fixed** an exploration slot no longer downgrades a *followed* card to `.brand`. It has no spread
to draw a mosaic from, by design, so the downgrade drew a wordmark on an empty card; it keeps its
own voice and loses only the pairing sentence. Rare now that the cutoff keeps followed cards out of
those slots, and still needed because the fallback pool can put one there rather than leave a hole.

---

### [x] P2-5 · `BrandVector` is not deterministic across launches

**Where** `BrandVector.swift:311-326` and `:347-359` · same shape in `Recommendation.swift:189-195`,
`:208-211`

**Symptom** Recommendations reorder between launches for no reason the user did anything to cause —
against the determinism the rest of the ranking is built on (`Discovery.swift:26-32`).

**Cause** Both sort a walk over a `Dictionary` with ties broken by nothing, so which terms survive
`prefix(40)`, and which percentile a brand gets, is decided by the per-process hash seed.

**Fix** Break every tie on a stable key (the term, the brand id), the way `BrandUpdate.newestFirst`
does.

**Fixed** every dictionary walk that feeds a ranking breaks ties on a stable key —
`BrandVector.weighted` on the term, `percentileRanks` on the brand id, `sharedTraits` on the term
and on the category. Which terms survive `prefix(40)` no longer depends on the per-process hash
seed.

---

### [x] P2-6 · `ColorNamer` files whole colour families as "Black"

**Where** `ColorNamer.swift:74-83` (dark band) vs `:97`

**Symptom** Chocolate brown `(0.20, 0.12, 0.06)` → "Black"; so do dark teal, dark purple, dark
orange. At `brightness == 0.22` there is a cliff — 0.23 would have said "Brown".

**Note** Fixing this is a re-naming, so it needs a `VisualReading.version` bump or nothing
re-derives.

**Fixed** the dark branch covers the whole hue circle — Burgundy, Brown, Olive, Forest, Teal,
Navy, Purple — instead of naming three arcs and letting the rest fall through to Black. Every name
is one `ColorHarmony.Swatch.wheel` knows, so nothing scores neutral by accident, and the chroma
guard that keeps a cool-cast black out of the branch is untouched. `VisualReading.version` bumped
to 6, or nothing would re-derive. Three tests, including the chocolate `(0.20, 0.12, 0.06)` case
and a check that the cliff at `brightness == 0.22` is gone.

---

### [x] P2-7 · A feed headline can state a different count from the page it opens

**Where** `FeedView.swift:207` and `:732` (dedupe across all kinds, then bucket) vs
`BrandFeedView.swift:66-70` (filter by kind, then dedupe)

**Symptom** One garment with an unread `.product` and an unread `.restock` is counted in the
restock bucket on the feed and survives as a product on the page. Feed says "6 new products", the
page says 7 — the exact failure `BrandFeedView.heading` warns about. Reachable in server mode,
where every event is its own row.

**Fixed** `BrandFeedView.updates` deduplicates *before* filtering by kind, which is the order
`FeedView.feed` uses. The two counts now agree by construction rather than by coincidence.

---

### [x] P2-8 · Keeping a fit does not remove it from the suggestions, so it can be kept twice

**Where** `StyleView` "From your wardrobe" row / `FitSuggestions`

**Symptom** **live** — kept two proposals; both became stored fits and **both were still offered**.
Tapping the same card again makes a duplicate outfit. The intent on record is that keeping one
"stops it being regenerated".

**Fixed** `FitSuggestions.build` takes the fits that already exist and drops any proposal holding
the same garments. Compared on `SuggestedFit.wardrobeKey` — the **products**, not the pieces —
because keeping a proposal mints a `SavedItem` for anything borrowed and a save-based key would
never match the proposal it came from. `StyleView`'s memo carries the kept keys in its fingerprint,
so keeping one recomputes the row it came off.

---

### [x] P2-9 · Fits are named after a truncated garment title

**Symptom** **live** — two different kept outfits, both called *"Kith Kids for Matthew Langille
Puffer Vest - Polar ·…"*. The outfit's own line ("Red against neutrals") already exists, is
distinguishing, and is what the card prints underneath.

**Fixed** a fit stores the outfit's own verdict (`Fit.verdict`) at the moment it is kept — from
the proposal in `StyleView.keep`, from `Outfit.score` in `FitStudio.save` — and `derivedName` prints
that. Falling back to the brands in it, never to the garment titles: the one thing a name under a
picture has to do is tell two cards apart, and a truncated 60-character product name does the
opposite.

---

### [x] P2-10 · The taste block prints the entire vocabulary of an axis

**Where** `StyleView` taste section / `StyleProfile.build`

**Symptom** **live** — with 8 saves: `REGISTER: Muted Light Dark Vivid`. All four possible values,
two of which contradict each other. A facet that lists every option is not a reading of taste.
`COLOURS` had the same shape (4 of the palette).

**Fix** Print only what dominates — a share threshold, or top-N with a floor, and nothing when the
distribution is flat.

**Fixed** `StyleProfile.dominant` decides what a facet line may print: nothing at all when the
leader is not meaningfully ahead of an even split (which is what "REGISTER: Muted Light Dark Vivid"
was), then a floor relative to the leader, then the existing cap of four. A single value is always
a reading.

---

### [x] P2-11 · `Outfit.score` refuses outfits `isDoubleBooked` explicitly permits

**Where** `Outfit.swift:77-84` (hard refusal on any refused pair) vs `:227-229` · `Pairing.swift:198`,
`:211`

**Symptom** A cap plus a tote in a four-piece fit scores as refused. Latent today because the one
production caller (`Fit.swift:551`) filters to `GarmentSlot.essential`, but `Outfit.score` is public
API sold as judging a whole outfit.

**Fixed** `Outfit.score` skips a pair where neither garment is essential, instead of inheriting
`Pairing`'s refusal of it — the same pairs `isDoubleBooked` had just decided are what people wear.
`.unknown` is deliberately excluded from the exemption, so the classifier's own refusal still
stands. Tested with a cap and a tote inside a four-piece fit, with the two slots pinned so the test
cannot start passing for a different reason.

---

### [x] P2-12 · Three sharp edges in `Discovery`

**Where** `Discovery.swift:291` · `:264-276` and `:316` · `DiscoverDeck.swift:428`

- `while !remaining.contains(where: underCap) { round += 1 }` **never terminates** if a caller
  passes `perBrand <= 0`. `Saturation` guards `halfLife` with `max(0.5, …)`; `perBrand` has no guard.
- `best` cannot select a `NaN` value (both `>` and `==` are false), so an all-NaN page silently
  **truncates the deck** at `:316` instead of emitting the remainder.
- `brandID: card.brand.id ?? UUID()` mints a fresh random UUID per `rank()` — harmless while the
  server always sets `brand.id`, but it defeats the per-brand cap for any nil-id card and puts an
  RNG in the one file documented as having none.

**Fixed** all three. `perBrand` is clamped to at least 1, so a cap of zero cannot spin forever.
`best` treats a NaN as the worst possible score rather than an unselectable one, so an all-NaN page
is emitted in full and ranks last rather than truncating the deck. And `Discovery.unattributed` is
a fixed id for a card with no brand, which restores the per-brand cap for those and takes the RNG
out of the one file documented as having none. Four tests in `DiscoveryEdgeTests`.

---

### [x] P2-13 · A wardrobe whose only proposal is a set gets nothing

**Where** the sets loop in `Fit.swift` builds `items = [piece]` · `Outfit.swift:66` refuses
`pieces.count < 2`

**Symptom** One tracksuit plus some tees (no bottoms, no shoes) returns an empty row — the opposite
of "offered first so that a wardrobe holding one still produces its proposal".

**Fixed** `Outfit.score` accepts a single garment when it `isSet` — a tracksuit occupies both
positions by itself, which is the whole meaning of the flag — so the sets branch produces its
proposal on a wardrobe that has nothing else. A lone garment that is *not* a set is still refused,
and there is a test for each.

---

## P3 — what the screen actually says

### [x] P3-1 · The unread dots on the brand rail are clipped

**Where** `FeedView.swift:440-452` (the `.overlay(alignment: .topTrailing)` with
`.offset(x: 3, y: -3)`) inside the `ScrollView(.horizontal)` at `:413-431`

**Symptom** **live, measured** — every dot renders **flat across the top and rounded at the
bottom**: sampling `feed3.png` through a dot gives full width at y=436–442 and a narrowing arc
below, with nothing above y≈435. About 3pt of an 8pt dot is missing, and the 2pt paper ring that is
supposed to strike it out of the tile is gone along that edge.

**Cause** The dot is deliberately offset **outside** the monogram's bounds (`x: 3, y: -3`), and the
`HStack` inside the horizontal `ScrollView` has horizontal padding but **no vertical padding** — so
the tile's top edge *is* the scroll content's top edge, and a `ScrollView` clips its content. The
`.padding(.top, 4)` at `:434` is on the outer `VStack`, outside the scroll view, so it does not help.

**Fix** Add ~6pt of top padding to the `HStack` *inside* the `ScrollView` (cheapest, keeps the
horizontal clip that stops tiles bleeding past the margins). `.scrollClipDisabled()` also works but
lets tiles spill at both ends. Removing the offset changes the intended look.

**Done when** The dot is a full circle with its paper ring intact on all sides, and tiles still clip
correctly at the left and right margins.

**Fixed** ~6pt of top padding on the `HStack` **inside** the `ScrollView`, which is the only place
it works: the `.padding(.top, 4)` on the outer `VStack` is outside the scroll view and does nothing
for the clip. **Verified live and measured**: the dot renders as a complete circle with its 2pt
paper ring intact on all sides, and the tiles still clip at the left and right margins.

---

### [x] P3-2 · The vermilion rule under a tile is right, but it fires on gift cards

**Where** `UpdateCard.swift:202` (`isMine`) and `:217-225` (the 2pt rule) ·
`BrandUpdate.swift:411-415` (`isInMySize`) · `SizeMatching.swift:460-462`

**What it means** The rule is not decoration and it is not random: it means **"buyable right now in
a size you wear"**. `isMine` is `update.isInMySize(profile)`, which needs a variant that is both
`available` and matched by the profile. Three consequences that explain every tile:

- With an **empty** size profile it never draws at all (`guard !profile.isEmpty`).
- With **no variants** on the row it falls back to the server's `availableInMySize` flag.
- **Anything unparseable matches** — `SizeMatching.swift:462` returns `true` when
  `SizeNormalizer.normalize` gives nil. That is the deliberate one-size rule, and it is why the
  **ALD gift card is underlined** while the Embroidered Logo Hoodie next to it is not: the hoodie
  has no M in stock, and the gift card's "sizes" are denominations that normalise to nothing.

**Symptom** The app spends its one accent colour claiming a **gift card** is in your size. See also
P3-3 — it should not have been in that row in the first place.

**Fix** Two candidates, not exclusive: exclude non-garments before the rule is considered, and/or
require at least one *parseable* size before "in your size" is claimed (one-size should still match
for hats and bags — the difference is that a gift card is not clothing).

**Fixed upstream, and deliberately not here.** Requiring a parseable size would have taken the
one-size rule down with it, and that rule is what makes hats and bags work. A gift card is not a
garment and no longer reaches a feed list at all — see P3-3 — so the rule stops being asked about
one. The reasoning is written onto `FeedTile.isMine`, which had none.

---

### [x] P3-3 · Gift cards appear in the feed as garments

**Symptom** **live** — "3 things are back" for Aimé Leon Dore printed a hoodie, a sweater, and
*"Aimé Leon Dore Gift Card"*, with the in-your-size rule under it. Discover has a promotional
filter (`PreviewImages.pick`); the feed has none.

**Fixed** `BrandUpdate.isMerchandise` — a stored flag beside `merchandiseVersion`, the
`genderVersion` pattern — written at insert on every path and settled in the background by
`Classification.settleMerchandise`. `BrandUpdate.passes` reads the stored Bool, so the shared filter
every browsing list already uses hides these without a classifier running per row per render.
**Verified on a real seeded store**, which also caught the thing worth catching: revision 1 flagged
"Fall '26 Delivery 1", a Kith *drop*, because `PreviewImages` reads a title and "delivery" is in its
vocabulary. Only rows that stand for a product are asked the question now; `PreviewImages.version`
is 2 so the wrongly stamped rows re-derive. On the same store: "Shipping Insurance" is caught, both
gift guides are left alone.

---

### [x] P3-4 · Discover prints raw storefront copy

**Symptom** **live** — *"Oversized, boxy fit crewneck fleece sweatshirt Sun faded effect
Heavyweight 14.75oz cotton blend Stüssy l…"* (no sentence separation, truncated mid-word) and, on
the ALD card, a line opening with a bare `·`. On the app's most designed surface the only prose is
unedited HTML.

**Fix** Normalise on the way in — `<br>`/`<li>`/`</p>` become sentence or bullet boundaries — and
truncate on a word.

**Fixed** `condensed` now goes through `ShopifySource.plainText` — the app's one answer to "HTML
into a line", rather than a second private stripper — and truncates on a **word** at 150
characters, because a `.lineLimit` cut cannot be told where to stop. `plainText` itself learned
that a `<br>` before a capital or a digit is a boundary and a `<br>` inside a sentence is a space,
which is how half of these storefronts actually write a spec. Two tests, and the second one earned
its place: the first version used `.caseInsensitive`, which applies to the lookahead too, so
`\p{Lu}` matched lower case and every wrapped sentence was broken into bullets. Not reproduced on
screen — no card in the test install carried a description.

---

### [x] P3-5 · A brand in the global catalogue is named `norseprojects-webshop`

**Symptom** **live** — on the Discover release card, so it is what the tab that exists to introduce
brands shows as the brand. 14 of the 15 names on that page were correct.

**Fix** `POST /admin/brands/:id/name` fixes this row; worth checking how it got past
`BrandNaming.pick` (a myshopify handle reaching the name is the likely path).

**Fixed** for everything written from here on. `BrandNaming.looksLikeHandle` refuses a slug —
lower case, no spaces, hyphen- or underscore-joined, or naming the platform — at every tier of
`pick`, and `ShopifySource.shopInfo` refuses one where the field is produced, so the next claim
(`og:site_name`, the `<title>`, the host) answers instead. Deliberately narrow: a single lower-case
word like "bbcicecream" is left alone. Two tests. **The existing catalogue row still needs
`POST /admin/brands/:id/name`** — that is an operator action against production and is not
something this pass could do.

---

### [x] P3-6 · Onboarding step 3's list is clipped by the pinned CTA

**Symptom** **live** — "REPRESENT / SCHEDULED SEASONAL DROPS" is cut mid-descender by the button.
The scroll content is not inset for the pinned control.

**Fixed**, and reproduced first: the row really is cut mid-descender, because the action bar's
background is `Color.paper` and so is the page, so the boundary is invisible and reads as clipping
rather than as content that scrolls under. A 22pt paper fade now sits above the bar, inside the
`safeAreaInset` so its height insets the scroll content too — at the foot of a list the last row
sits above the fade, and only rows actually moving past it are faded. The scroll content's own
bottom padding came down from 32 to 10 to pay for it, because the sizes step had just been made to
fit exactly and 22pt more inset pushed its closing line off. **Verified live**, both steps.

---

### [x] P3-7 · Discover's fade band is taller than it needs to be

**Symptom** **live** — roughly a third of the card is gradient and the garment finishes well above
it, leaving a large dead band between picture and reading. The band is deliberately tall and eased
(so a white-backed JPEG never picks up a tint) — the note is that on a tall packshot the result
reads as empty space rather than as a fade.

**Fixed** by retuning rather than redesigning: `chromeBottom` 104 → 84 and `fadeHeight` 190 → 156,
in the same proportion, so the artwork's bottom edge still lands just under halfway down the band
where the gradient is at three hundredths and a white packshot has nothing to pick up. The dead
band between the last row of a mosaic and the first line of the reading is about 20pt shorter.
**Checked live** on a release card and two brand cards.

---

### [x] P3-8 · Onboarding step 1 is top-heavy

**Symptom** Three ladders, ~500pt of nothing, then Continue. Fixing P1-3 by wrapping the ladders
uses exactly this space.

**Fixed** by P1-3 — wrapping the ladders uses exactly the space that was empty. **Verified live**:
step 1 now runs from the heading to the Continue button with no dead space, and every ladder is
fully visible.

---

## Performance and cost

### [x] PERF-1 · Discover pages are ~131KB for one screenful

**Where** `routes.swift:502-512` (`discoverFetchPerBrand` 12→24) · `:696-702` (`.with(\.$variants)`)
· `:700` (only `rows.prefix(2)` needs them)

**Measured** `/v1/discover` 0.86s / **133,937 bytes**; `/v1/feed` 1.56s / **238,779 bytes** (100
items, 842 variants); `/v1/brands/popular` 0.40s / 43KB; `/v1/follows` 0.91s / 2KB.

**Fix** Split the query: a narrow variant-loaded one for the two cards, a title+image-only one for
the spread.

**Fixed** the 24-row spread window no longer eager loads variants; the two rows that actually
become cards fetch theirs in one query afterwards. `DiscoverCard` already took variants as an
explicit parameter — for exactly the reason that saved this from being a runtime trap — so the
release path is unaffected and passing `product.variants` is now impossible without a compile
error.

---

### [x] PERF-2 · Image decoding happens on the main thread in two places

**Where** `ImageTagger.swift:391-415` (`@MainActor enum`, calls `ImageLoader.decoded` at `:415`) ·
`CachedImage.swift:294` (`decoded` is `nonisolated` and **synchronous**, so it runs on the caller) ·
same shape in `DiscoveryAnalysis.swift:139-152`

**Symptom** After `await URLSession.data` resumes on the main actor, the full rasterisation is on
main — which is exactly what the comment at `ImageTagger.swift:410-413` says was fixed. `ImageLoader`'s
own callers are fine because it is an `actor`.

**Fixed** `ImageLoader.decodedOffActor` runs the rasterisation on a detached utility task, and
`ImageTagger` and `DiscoveryAnalysis` — both `@MainActor` types that do their own fetching — call
it instead of `decoded`. The note on it says the thing that was actually wrong: `nonisolated` is
not "off the main thread"; a synchronous `nonisolated` function runs on whichever actor called it.

---

### [x] PERF-3 · `FollowedSupply` runs the gender classifier over the whole unread table

**Where** `FollowedSupply.swift:60/65`

**Symptom** `update.brand` faults the relationship per row and `update.passes(profile)` is called
with no `if filterGender` short-circuit, over a `@Query { !$0.isSeen }` spanning **all** brands, and
it re-runs on every `followedKey` change — i.e. every time anything is marked read or a sync lands.

**Fixed, and half of it was already fixed.** `BrandUpdate.passes` short-circuits the gender
classifier structurally — `guard profile.gender != .everything` — so there was no missing
`filterGender` guard; that part of the reading was out of date. What was real is the relationship:
`update.brand` was the *first* test, so every unread row in the store was faulted in to answer a
question three stored scalars settle for most of them. It is asked last now, of the few rows that
get that far.

---

### [x] PERF-4 · `SharedSaveImporter` fetches storefronts from the phone in server mode

**Where** `SharedSaveImporter.swift:299` (`ShopifySource.product(at:)`) · `:195`
(`SiteIdentityProbe.discover`, one homepage fetch per host on every foreground via
`streetwApp.swift:171-175`)

**Note** Unguarded by `settings.isConfigured`, not in the routing table in CLAUDE.md, and it bypasses
the server's shared politeness budget. `StockRefresh` is the one documented exception; this is a
second one that was never written down.

**Documented, which is what the item asks for.** There is no route to call: a share is an
arbitrary URL from any storefront, any blog, any resale listing, and the server's catalogue has
nothing to look it up in — a route that made the server fetch a URL a client chose is the shape
`RequireDevice` exists to stop being anonymous. The exception is now written in
`SharedSaveImporter`'s header beside the identical note in `StockRefresh`, and both are in
CLAUDE.md's routing section. One correction to the reading: `identifySites` is not one fetch per
host per foreground — it is stamped by `siteIdentityVersion`, grouped by host and capped at
`identifyBatch`, so it asks each host once.

---

### [x] PERF-5 · Unfollow is fired into a detached `Task` after the local delete is saved

**Where** `BrandsView.swift:112`

**Symptom** Killed mid-loop, the deletes are persisted and the unfollows are not — the "next sync
restores it" trap.

**Fixed** `RemoteSync.unfollow` takes a **brand id** rather than a model — the old signature read
`brand.remoteID` inside a `Task` that outlives `context.delete`, which is a trap on a slow network —
and writes the id to a small `UserDefaults` ledger before it sends, clearing it only on a confirmed
success. `sync` drains the ledger *before* `follows()`, or the very repair would let the follow
list restore what was deleted.

---

## Needs reproduction before it is worth fixing

**Left alone, deliberately.** The heading is the instruction, and none of these were reproduced in
this pass. R-2 and R-3 are both classic SwiftUI shapes with cheap-looking fixes, and a "fix" applied
to a fault nobody has seen is a change with no way to tell whether it worked — R-2's obvious repair
(deferring the second sheet by a runloop) is itself visible on screen if it was never needed.

### [?] R-1 · Onboarding shown once with a populated store

**Seen** once, on a launch where the store already held 2 brands and 8 saves; `decideOnboarding`
(`ContentView.swift:253`) must have fetched an empty `Brand` result. **Not reproducible** — the two
following launches were correct. Suspect a race between the container being ready and the `.task`
at `:141`, which in standalone mode always runs because `isRegistered` is permanently false.

### [?] R-2 · Sheet-to-sheet handoff on "BUILD A FIT"

`DiscoverFeedView.swift:324` sets `viewing = nil` and `fitting = …` in the same update across two
sibling `.sheet` modifiers (there are four on that view). Classic "second sheet never presents"
shape. The card's own chip path is unaffected because `viewing` is already nil.

### [?] R-3 · `FitGroundPicker` opens on the wrong ground

`FitCanvas.swift:927` seeds the wheel from `selection` in `onAppear`, before `load()` (`:491`)
assigns `background = fit.ground` — so reopening a fit with a custom ground may open the wheel on
bone.

### [?] R-4 · `GoesWith` may print one garment twice

`GoesWith.swift:51-58` passes `updates.map(\.garment)` to `Pairing.best` without
`BrandUpdate.oncePerProduct`; if two `SavedItem`s point at one `BrandUpdate`, `ForEach(found, id:
\.update.id)` (`:107`) gets duplicate ids. Whether that duplication is reachable was not traced.

### [?] R-5 · Dead assignment in the sets loop

In `Fit.swift`'s sets branch the shoe is appended to `chosen` and the coat only to `items`, where
the cross-product loop does `chosen.append(garment(coat))`. Harmless today; the two loops now
disagree about an invariant they otherwise share.

---

## Tooling and docs debt

- [x] **`-seedSaves` is documented as an independent flag but only runs inside `-seedBrands`**
  (`streetwApp.swift:245`, called at the end of `seedBrandsIfRequested`). In server mode it silently
  does nothing. Either make it standalone or say so in CLAUDE.md.
- [x] **CLAUDE.md says `swift test` runs 311 tests; it runs 376.**
- [x] **The routing table in CLAUDE.md is missing `SharedSaveImporter`** — see PERF-4.

---

## Verified working — do not re-investigate

Two lines in this section were stale by the time the work started and are corrected here rather
than edited above, because what they *said* is part of the record: the build now carries **zero
warnings** again (it had picked up eight — main-actor isolation on `Classification.batch` and
`FollowedSupply.card(from:)`, a non-`Sendable` push payload, and five in the in-flight fit work),
and `swift test` runs **394**, not 311 or 376.

Established by driving the app or by reading; recorded so nobody spends the afternoon on them again.

- **Build is clean** — zero warnings; **376 tests pass in 1.08s**.
- **Backend is healthy** — `/health`, `/.well-known/ucp` public and 200; every `/v1` route 401s
  without a device token.
- **The size run works end to end in server mode.** First product opened on a fresh install:
  `M` in vermilion with the underline, `XXL` struck through, `YOURS: M · W 30 · US 12`. Variants
  really are on the wire (842 across 100 feed items).
- **Gender filtering is honest.** 200 stored rows rendered as "82 new from 3 brands / FILTERED TO
  MENSWEAR".
- **Per-brand mark-read is consistent and fast.** Clearing Kith removed its spread, its rail dot and
  its share of the header count together, in **0.59s** from tap to SQLite (68 rows, debug build,
  simulator). Its 102 womenswear rows stayed in the store and nothing claimed them — the documented
  design, working.
- **`StyleView.keep` writes a real arrangement.** The kept fit has four normalised `FitPlacement`s
  and a 900×900 render with **no holes** — the `FitArrangement` work in the tree does what it says.
- **Local retention is deliberate, not data loss.** Standalone pulled 2,742 products in ~30s and
  `SyncEngine.prune` kept 400 per brand, never touching saved or unread rows.
- **The release detector is behaving.** Every release card seen was a real season; no shoe sizes or
  sale rails admitted.
- **Brand naming is mostly right** — 14 of 15 correct on one Discover page (the exception is P3-5).
- **The mood-board look of the fit canvas in the Simulator is not a bug** — Vision's subject lifting
  does not run there, so cutouts are absent by design.
- **`Notifier.isWorthWaking` forwarding to `UpdateKind.isSudden`** (uncommitted) is
  behaviour-preserving, case for case.
- **`FitCandidates`' removal of the `#Predicate` over `imageURLStrings`** is the correct fix for the
  documented SQL-generation crash.

---

## How this was checked

Simulator: iPhone 17 Pro, iOS 26.5, `-derivedDataPath /tmp/streetw-dd`. Taps posted as `CGEvent`s
against the Simulator window — **re-read the window position before every batch, it moves**, and
activate Simulator first or the clicks land in whatever app has focus. Avoid device `(0,0)`: with
another app in the recents chain that is the "◀ back" affordance in the status bar, and tapping it
switches apps silently.

Counts read straight out of the store rather than off the screen:

```bash
DB="$(xcrun simctl get_app_container "$DEVICE" com.kern.functional.streetw data)/Library/Application Support/default.store"
sqlite3 "$DB" "select b.ZNAME, count(*) from ZBRANDUPDATE u join ZBRAND b on u.ZBRAND=b.Z_PK where u.ZISSEEN=0 group by 1;"
```

One trap worth knowing: on this simulator `serverToken` and `didOfferStarterPack` **survive
`simctl uninstall`**, so onboarding is skipped on what looks like a fresh install. Clear them with
`xcrun simctl spawn "$DEVICE" defaults delete com.kern.functional.streetw` before testing first run.

# Releasing Dropwall 1.4 (build 5) — Phase 5, search at the centre

The handover for whoever ships this. Same rules as `RELEASE_1.3.md`: read `CLAUDE.md` first,
never handle secrets, ask the owner before merging to `main` (it deploys the server), before
submitting, and before publishing anything. Do 1.3 first if it has not shipped — 1.4 assumes
its server, credits and AI are live.

## What 1.4 is

Branch `phase-5` (`ROADMAP.md`, *Phase 5*, every item ticked with a *Done:* note):

- One search over every shop the server watches, followed brands boosted, "More from my
  brands" / "Only my brands", a "How we sort" note, meaning matches, style words.
- Search by photo from the scan; the scan's short name as the save's title.
- Follow only part of a brand: a dialog on every new follow, editable on the brand page.
- The share sheet: stays until Done, reads the page Safari loaded, board chips and New board,
  Notify me with sizes, Follow on a shop page, questions kept until answered; a shop nobody
  watches is added to the catalogue (domain only).
- The product shot and style words, read once per product on the server (FashionSigLIP).
- A blocked shop says why.
- The feed no longer loses the morning's items; the app opens on Shop.

Version: `MARKETING_VERSION = 1.4`, `CURRENT_PROJECT_VERSION = 5`. Texts: `WHATS_NEW_1.4.txt`,
`REVIEW_NOTES.md` (the block under *The text to paste*), `PRIVACY_POLICY.md` /
`privacy-policy.html` (dated 30 October 2026).

## 1. Check it builds

As in `RELEASE_1.3.md` step 1. Expected on 2026-10-30: `swift test` 777, `cd Server && swift
test --no-parallel` 439 (with `STREETW_TEST_POSTGRES_URL` on a pgvector Postgres), `cd Embeddings
&& pytest` 67.

## 2. Merge to `main` — ask first

The server is compatible with 1.2 and 1.3: every wire change is optional and old requests get
identical answers. On deploy it runs four migrations (`AddFollowFilter`, `AddBrandCheckRefusal`,
`AddCatalogueOnlyCheck`, `AddProductReading`) — all additive.

After the deploy, expect two slow background jobs on the server and the embedding service,
both resumable and both quiet in the logs:

- the **product reading** backfill (product shot and style words): roughly four hours for
  ~10k products on Railway's CPU, once;
- the first image-vector index build, during the first embedding backfill batch.

Search works throughout; readings and photo search fill in as they go. Watch the embedding
service's memory and the database size on Railway (Pro is due when `databaseBytes` passes half
of Hobby's 5 GB — `/admin/status`).

No new Railway variables are needed. Optional: `PRODUCT_READING=haiku` switches the photo reader
to Claude Haiku (owner-paid, under `AI_BACKGROUND_DAILY_CAP_MICROS`) — only if the comparison in
step 3 says Claude clearly wins.

## 3. The SigLIP vs Haiku comparison — the owner, with a key

The product-shot reader shipped with FashionSigLIP: 96.6% right on 203 hand-labelled products
(84.8% where the first photo is not the product shot), style words 65% precise. To compare Claude
Haiku on the same set, from `Server/` in a checkout named `streetw`, with the owner's key in the
environment (never printed, never committed):

```bash
STREETW_READING_EVAL=haiku ANTHROPIC_API_KEY=… swift test --filter ReadingEval
```

About $0.40. It prints both results side by side. Switch (`PRODUCT_READING=haiku`) only if
Haiku is clearly better.

## 4. App Privacy answers — the owner

Keep everything from 1.3. **Add: Browsing History — not linked to the user, App Functionality,
no tracking.** That is the shop's domain sent when somebody saves from a shop the catalogue does
not have yet (never the product, never that it was saved). It matches
`streetw/PrivacyInfo.xcprivacy`.

Publish the updated `privacy-policy.html` at the same URL.

## 5. Archive, upload, TestFlight

As in `RELEASE_1.3.md` step 7, checking 1.4 (5) in the Organizer. On a real phone, against
production:

- The app opens on Shop. A plain search says "IN EVERY SHOP WE WATCH"; try the two chips and
  How we sort.
- Scan a garment with the **camera**: the short name, then "looks like your photograph" (photo
  search needs the image vectors, so it may fall back to the description for a few hours after
  deploy).
- Follow a brand: the dialog with three chips.
- **Share from Safari** — this is the part the simulator could not fully prove:
  - a product page (try Intimissimi, which used to arrive with no photo): pick a board, New
    board, Notify me with a size, Done; open the app — filed, watched, photographed;
  - a shop's homepage: Follow, Done; open the app — followed, and the dialog asks;
  - share, wait an hour, open the app: any question the share raised is still there;
  - a shop that blocks readers (Bershka): the save still gets its photo.
- The feed in the evening still has the morning's items.
- A fresh install shows the four tour cards before sizes and shops; the Shop, Saved and fit canvas
  tips each appear once; You › Help replays the tour.
- Add a brand: follow one, answer the "What do you want to hear about?" dialog, and the sheet
  returns to the list (the row says Following) instead of closing.
- Sign out (You › Account): the app is empty; sign in with the same Apple ID and everything is back.
  Pushes for the account stop arriving on the signed-out phone.

## 6. Submit

What's New from `WHATS_NEW_1.4.txt`; the notes from `REVIEW_NOTES.md`; Sign-in required stays
unticked; build 1.4 (5). **Screenshots: reshoot them.** The copy redesign changed what most screens
say and how Shop is laid out, so the 1.2 set no longer matches the app (`AppStore/demo/` has the
shoot script).

## Known, not blockers

- Meaning matches add little (FashionSigLIP's text vectors are weak); a model comparison is
  running separately and switching models is the owner's decision.
- Under heavy load, photo and query embeddings fall back to words rather than wait.
- The background refresh choosing picks was ~28 s in a debug simulator (see `RELEASE_1.3.md`).

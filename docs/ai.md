# AI

Part of the streetw guidance set; see `CLAUDE.md` for the index and the build rules.

**Read this before touching anything under `/v1/ai`, `AIProvider`, `AnthropicProvider`,
`FakeAIProvider`, `AIAction`, `AIThreadToken`, the AI parts of `ShopView`, the scan, or the fit
canvas's "Ask" actions.** The wire contract is `Sources/StreetwCore/AIWire.swift`; the credits
it spends are `docs/credits.md`.

Phase 4 (`ROADMAP.md`) puts Claude behind six actions. This file is the decisions they share;
each section below names the failure or the promise that bought it.

## The provider layer

- **One protocol, `AIProvider`, and one production conformer, `AnthropicProvider`** — the
  Messages API over the HTTP client Vapor already carries. No SDK: there is no official Swift
  one, and a dependency for one POST is not worth its tree.
- **On when `ANTHROPIC_API_KEY` is set, off otherwise, and said at boot either way** — the
  embedding sidecar's rule. Off, `GET /v1/ai` answers `available: false` and the phone draws
  no AI affordance.
- **Two models, both variables**: `AI_MODEL` (default `claude-sonnet-5-5`) for what somebody
  is waiting on and paying for — search, scan, fits — and `AI_MODEL_FAST` (default
  `claude-haiku-4-5-20251001`) for the owner-paid background work, where volume is the cost.
- **Structured answers come from a forced tool call** with a JSON schema, never from parsing
  prose. An answer that does not decode is a failed call: undone, metered, and said.
- **The price table is in one place** (per model, per million tokens each way, and per web
  search), and every call's `MeteredCost` is computed from the usage the API reports, never
  estimated. **Check it against anthropic.com/pricing before launch** — a wrong row there
  is a wrong measurement every price is later set from.
- **`AI_FAKE=true` swaps in `FakeAIProvider`**, which answers every action deterministically
  from its input, so the whole flow runs in a simulator against a local server with no key.
  **Refused on a `production` environment**, like `SIWA_TEST_TOKENS`. Its costs are metered
  as zero under the model id `fake`.

## Every paid action has the same shape

`AIAction.run` — spend, call, record, undo (`docs/credits.md`, *What Phase 4 calls*), so no
route can forget a step:

1. `CreditLedger.spend` **before** the call (403 signed out, 402 not enough, 429 the cost cap).
2. The provider call, outside the spend's transaction.
3. `CostMeter.record` for **every** call, including failed and discarded ones.
4. `CreditLedger.undo` when the action produced nothing for the reader.

The answer carries `AICharge` so the phone updates its balance without another request.

Placeholder prices (`CreditPolicy`): search 1 for a thread of up to six turns, web search 3,
scan 2, fit judge 1, fit suggest 1. Set from `GET /admin/costs` p90 after a few weeks.

## Search

- **The model never answers with products.** It rewrites the thread into the `ShopQuery`
  grammar ("black suit under 400 no wool formal"), and the server's own `ProductSearch` finds
  them — exactly what `GET /v1/products/search` answers for that text. A model that names
  products names ones that do not exist, at prices nobody charges.
- **The thread is the phone's.** Each turn sends the previous turns back with an
  `AIThreadToken` — HMAC-signed with `AI_THREAD_SECRET` (random per boot when unset, which only
  costs a paid thread its follow-ups across a deploy), naming the account, the profile, when
  it was issued and the turns used. Thirty minutes, six turns. A turn with a valid token is
  not charged; nothing anybody typed is stored or logged.
- Chips that the grammar already has (`cheaper`, `formal`, `in my size`) stay free and need no
  model call; the model's `suggestions` are short replies the grammar does not have.
- **"Followed shops first, ranked by taste, then similar brands"**: the server searches
  `followed`, then `all` when asked; the taste ranking is the phone's, because the taste
  vector never leaves it.
- **Show me more** asks Claude's web search for product pages from shops selling in the
  reader's country, answered through a forced tool call so every item is a real URL the search
  returned. A shop the server watches comes back with its `brandID`; anything else offers the
  ordinary site check. Grammar text and a country go to Anthropic, nothing else.

## Daily picks

- **Chosen on the phone, worded by the model.** `DailyPicks` already chooses and has a true
  reason; the model only rewrites the top three's reason in one line. Free — nobody asked.
- What leaves the phone is the pick's product id, the rule that chose it, and the wardrobe
  partner **as a short description** ("black chore jacket") — never a photograph, a brand, an
  id or a save. Cached server-side by a hash of the three, with no user or device on the row,
  so a hundred people with a black chore jacket cost one call.
- The optional daily push is a **local** notification the phone schedules after its own
  refresh has chosen the picks, off by default, so nothing about picks reaches the server to
  send it.

## The scan

- One photograph, cut out on the phone where `Cutout` succeeds, scaled to `AIScan.maxEdge`,
  JPEG under `AIScan.maxBytes`. **Never stored on the server and never logged**; it goes to
  Anthropic for that one reading.
- *Add to my wardrobe* saves a `SavedItem` whose photograph is the reader's own and which has
  no product behind it. *Does it go with my wardrobe* runs on the phone (`Pairing`, `Outfit`)
  over the reading — the wardrobe never leaves it. *Find this* uses `similar` when the
  embedding service read the photograph, else searches `searchText`.
- **On the phone** (`ScanView`, `ScanPhoto`, `OwnGarment`): the entry point is `ScanButton`
  (Saved's "+" offers it as "Scan a garment"; `ScanButton(onFind:)` is the control for Shop's
  field, and `.scanSheet(isPresented:onFind:)` presents it from a host's own control). Camera
  where there is one (`NSCameraUsageDescription` is in `streetw-Info.plist`), the photo library
  everywhere. The price is on the button that sends — "READ IT · 2 CREDITS" — and signed out
  that button is replaced by the sentence saying why. When `Cutout` lifts nothing (always in the
  Simulator unless `Seamless` recognises a sweep) the screen says the whole photograph is sent.
  **Nothing is written until a choice is made**: the reading is held in memory as a
  `ScannedGarment`; *Add to my wardrobe* makes the save (`docs/collection.md`, *A garment of
  your own*); *Does it go* is `ScanVerdict` — a count of what it pairs with and up to three
  `FitProposal.outfits`, each opening the canvas pre-filled; *Find this* is `ScanFindResults`
  (`similar`, else `GET /v1/products/search` over your shops and then every shop), or the
  host's own field when it passed `onFind`. A reading that is not a garment offers none of the
  three.
- **Availability is one small seam**, `AIAvailability` (`GET /v1/ai`, keyed on the token and the
  account): `isOffered`, `isSignedIn`, `credits(for:)`. `AIFailure` turns every refusal into the
  sentence the reader is owed — 402, 403, 429, offline, and a failure the server undid.

## Fits

- **Judge** sends the fit's pieces — catalogue photographs by URL, the reader's own as JPEG —
  and gets the worst-case verdict `Outfit` already speaks in, a line, notes, and the one piece
  to change.
- **Suggest** sends the fit and up to twelve candidates the phone already chose
  (`FitSuggestions`); the model only orders them and drops the ones that clash. The rule-based
  row still draws first and for free; asking is a button.
- Both are things somebody asked for, about garments they chose to send. On the phone they are
  the fit canvas's **Ask** menu (`FitAsk`); see `docs/fits.md`, *Asking about the photographs*.

## Reading where rules cannot

Owner-paid, metered with no account, under `AI_BACKGROUND_DAILY_CAP_MICROS` (default $1 a
day): reaching it stops background reading until the next UTC day, never a reader's action.

- **Sale banners**: the end date, a code and the fine print, read once per distinct banner text.
- **Product pages with no structured data**: new products only, once each, never every poll.

## Privacy

Every action is something the reader asked for, about what they chose to send, except the
pick sentence (a short description and an id) and the background reading (storefront pages,
about nobody). No prompt, answer, photograph or typed text is stored or logged on our server;
`ai_costs` keeps numbers only. Anthropic processes what is sent to answer it; the privacy
policy names it.

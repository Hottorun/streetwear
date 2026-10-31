# AI

Part of the streetw guidance set; see `CLAUDE.md` for the index and the build rules.

**Read this before touching anything under `/v1/ai`, `AIProvider`, `AnthropicProvider`,
`FakeAIProvider`, `AIAction`, `AIThreadToken`, `AIBackgroundReading`, `AIRoutes.swift`, the AI
parts of `ShopView`, the scan, or the fit canvas's "Ask" actions.** The wire contract is
`Sources/StreetwCore/AIWire.swift`; the credits it spends are `docs/credits.md`.

Phase 4 (`ROADMAP.md`) puts Claude behind six reader actions and two background readings. This
file is the decisions they share; each section below names the failure or the promise that bought
it. The server half lives in `Server/Sources/StreetwServer/Services/AIProvider.swift` (the
protocol, prices, configuration, the owner's cap), `AnthropicProvider.swift` (the Messages API,
prompts and tool schemas), `FakeAIProvider.swift`, `AIAction.swift` (spend → call → record → undo,
and the thread token), `AIBackgroundReading.swift` and `AIRoutes.swift`.

## The provider layer

- **One protocol, `AIProvider`, one method per action** — `readSearch`, `searchWeb`,
  `wordPickReasons`, `readScan`, `judgeFit`, `suggestForFit`, `readSaleBanner`, `readProductPage`
  — with typed input and typed output. Per action rather than per prompt, so the prompts and the
  parsing live in one file and the fake can answer every action from its input. One production
  conformer, `AnthropicProvider`: the Messages API (`POST https://api.anthropic.com/v1/messages`,
  `x-api-key`, `anthropic-version: 2023-06-01`) over the HTTP client Vapor already carries,
  behind an `AnthropicTransport` protocol so the suite replays recorded bodies. No SDK: there is
  no official Swift one, and a dependency tree for one POST is not worth it.
- **On when `ANTHROPIC_API_KEY` is set, off otherwise, and said at boot either way** — the
  embedding sidecar's rule. Off, `GET /v1/ai` answers `available: false`, every action answers
  503, and the phone draws no AI affordance.
- **Two models, both variables**: `AI_MODEL` (default `claude-sonnet-5-5`) for what somebody is
  waiting on and paying for — search, the web, scan, fits — and `AI_MODEL_FAST` (default
  `claude-haiku-4-5-20251001`) for owner-paid work where volume is the cost: pick sentences, sale
  banners, pages. A model with no price row is logged at boot.
- **Structured answers come from a tool call with a JSON schema, never from parsing prose.** The
  answer is the tool's input, decoded into the action's type; one that does not decode is a
  failed call — undone, metered and said.
- **…forced where the model allows it, and asked for where it does not.** `tool_choice: {type:
  "tool"}` is refused with a 400 by Sonnet 5.5, Opus 5.5 and Fable 5.1, which is the default
  `AI_MODEL`. On those the tool is `strict` (schema-valid arguments guaranteed) under
  `tool_choice: auto`, the system prompt says to call it, and a reply without the call is
  `.declined`. Haiku 4.5 and the 4.x line still take the forced form. `ModelTraits` is the one
  place that says which, and which web search tool and whether `output_config.effort` is taken
  (Haiku 4.5 refuses effort). Strict schemas use no length or count keywords — strict tools
  refuse most of them — so the routes cut every field to length on the way out (`AIText`).
- **No sampling parameters and no `thinking` field.** Current models refuse `temperature`, and
  thinking cannot be disabled on Sonnet 5.5; effort is the only knob — `low` for search and the
  background work, `medium` for the web, scans and fits.
- **The price table is in one place** (`AIPricing`: per model, dollars per million tokens each
  way, ten dollars per thousand web searches, cache reads and writes at 0.1× and 1.25× input),
  and every call's `MeteredCost` is computed from the `usage` the API reports —
  `input_tokens`, `output_tokens`, the cache counts and `server_tool_use.web_search_requests` —
  under the model the reply names, never estimated. A model the table does not know is priced
  at the dearest row rather than at zero. **Check it against anthropic.com/pricing before
  launch** — a wrong row is a wrong measurement every price is later set from.
- **What a failure costs.** A reply that came back and could not be used — tool input that did
  not decode, a refusal, no tool call, out of tokens — reports its usage and is metered. A call
  the API refused before doing work — a 429, a 529, a 5xx, a timeout — reports none, costs
  nothing and records nothing. A 529 or 5xx is retried once after half a second if the deadline
  allows; a 429 never is. Deadlines: search 20 s, pick sentences 15 s, scan, judge and background
  30 s, suggest 40 s, the web 60 s.
- **Nothing the model or the reader said goes into an error.** `AIError` names a status and an
  error type; the phone is told one of three sentences (503 busy, 422 couldn't answer, 502
  couldn't read the answer), each saying the credits were not used.
- **`AI_FAKE=true` swaps in `FakeAIProvider`**, which answers every action deterministically from
  its input — a search reading that is the thread's words, a scan that always sees a black canvas
  chore jacket, a fit judged by its piece count, two web pages of which one is on
  `example.com` (watch a brand with that slug to see `brandID` resolve), a page reading only when
  the page says `fake-product` — so the whole flow runs in a simulator against a local server
  with no key. **Refused on a `production` environment**, like `SIWA_TEST_TOKENS`. Its costs are
  metered as zero under the model id `fake`. Locally: `AI_FAKE=true SIWA_TEST_TOKENS=true
  DISABLE_POLLER=true swift run` from `Server/`, and `-fakeAppleSignIn` on the phone to get an
  account that can spend.

## Every paid action has the same shape

`AIAction.run` — spend, call, record, undo (`docs/credits.md`, *What Phase 4 calls*), so no
route can forget a step:

1. `CreditLedger.spend` **before** the call (403 signed out, 402 not enough, 429 the cost cap).
   A free follow-up spends nothing but still answers to the account's monthly cost cap.
2. The work — the provider call and anything after it, such as the search a reading feeds —
   outside the spend's transaction. It collects every call's cost in an `AIMeter`.
3. `CostMeter.record` for **every** call, on success and on failure, keyed to the account and
   the acting profile.
4. `CreditLedger.undo` when the work threw, **or when the answer has nothing in it for the
   reader** (`producedNothing`): "Show me more" that found no page, a scan with no garment in the
   photograph. Those answers are returned as they are, with `charge.credits` zero.

The answer carries `AICharge` — credits taken and the balance after, nil on an unlimited account —
so the phone updates its balance without another request.

Placeholder prices (`CreditPolicy`): search 1 for a thread of up to six turns, web search 3 (a
cent a search on top of the tokens), scan 2, fit judge 1, fit suggest 1. `GET /v1/ai` sends the
table, so a change needs no app update. Set them from `GET /admin/costs` p90 after a few weeks.

Every `/v1/ai` route is in the device-authenticated group, acts for `actingUserID()` (so
`X-Profile-ID` chooses the profile, and the meter names it), and spends from the account's one
ledger. They share a rate limit of their own on top of the standard one (`RateLimits.ai`: thirty
in a burst, four a minute per device), because each is a provider call whatever the caller's
credits — an unlimited account and a free follow-up are still calls.

## Search

- **The model never answers with products.** It rewrites the thread into the `ShopQuery`
  grammar ("black suit under 400 no wool formal"), and the server's own `ProductSearch.run`
  finds them — exactly what `GET /v1/products/search` answers for that text, with the request's
  `scope`, `inMySize` and, since Phase 5, `boost` and `meaning` (absent from 1.2 and 1.3, which
  get the search they always got). A model that names products names ones that do not exist, at
  prices nobody charges. An empty query is a failed call.
- **The thread is the phone's.** Each turn sends the previous turns back with an
  `AIThreadToken` — `base64url(payload).base64url(HMAC-SHA256)`, keyed by `AI_THREAD_SECRET`
  (random per boot when unset, which only costs a paid thread its follow-ups across a deploy or
  between instances), naming the account, the **profile**, when the paid turn was taken and the
  turns used. Thirty minutes from the paid turn, six turns. A turn with a valid token is not
  charged; an expired, spent, forged or another account's or profile's token is not an error —
  the turn simply starts, and pays for, a new thread. The token does not bind the thread's text:
  what it buys is six turns in thirty minutes, whatever is typed in them.
- **Bounded on the way in**: a turn is at most 200 characters, a thread at most five earlier
  turns (each at most 200 typed and 300 read), so a paid thread cannot become an essay.
- Chips that the grammar already has (`cheaper`, `formal`, `in my size`) stay free and need no
  model call; the model's `suggestions` (two to four, each at most 40 characters) are short
  replies the grammar does not have, and `reply` is one sentence only when the query alone does
  not show what was understood.
- **The one list, ranked by taste on the phone** (Phase 5): the phone sends the chips' reach —
  every shop with your own lifted, or only yours — so a thread answers with the same list the
  field does, and the taste ranking is the phone's, because the taste vector never leaves it.
- **Show me more** (`POST /v1/ai/search/web`) asks Claude's web search (`web_search_20260209`,
  five searches at most, `user_location` set to the reader's country — the request's, else the
  account's) for product pages, answered through the `report_products` tool, which can only be
  called after searching and is therefore never forced. **Every item must be a URL the search
  returned** — the server collects the result URLs from the `web_search_tool_result` blocks and
  drops anything else as invented — and at most eight, one per page. A paused turn
  (`pause_turn`) is resumed with its own content, twice at most, each call metered. Each item's
  host is matched to a brand the server watches — the slug, which is the host a brand was added
  with, then the registrable domain, then a country shop's own host — and comes back with its
  `brandID`; anything else offers the ordinary site check. Grammar text and a country go to
  Anthropic, nothing else. Nothing found is not charged.

## Daily picks

- **Chosen on the phone, worded by the model.** `DailyPicks` already chooses and has a true
  reason; the model only rewrites the top three's reason in one line (at most 120 characters
  kept). Free — nobody asked — and paid by the owner under the background cap.
- What leaves the phone is the pick's product external id, the rule that chose it, and the
  wardrobe partner **as a short description** ("black chore jacket") — never a photograph, a
  brand, an id or a save. The server adds the product's own title, type and brand name from its
  catalogue; a product it does not hold keeps the phone's reason.
- **Cached in `ai_pick_reasons` by `sha256(productExternalID|anchor|basis)`**, the words
  lowercased, with no user or device on the row, so a hundred people with a black chore jacket
  cost one call. Believed for thirty days and pruned by the `Reaper` after; metered with no
  account and no user.
- **A cache hit costs no call.** A miss costs one call per request (up to three picks), and only
  while the owner's day has room and the device has not asked for more than a dozen today
  (`RateLimits.pickReasons`). Every refusal and failure is silent: the phone keeps its own
  sentence.
- The optional daily push is a **local** notification the phone schedules after its own
  refresh has chosen the picks, off by default, so nothing about picks reaches the server to
  send it.

## The scan

- One photograph, cut out on the phone where `Cutout` succeeds, scaled to `AIScan.maxEdge`,
  JPEG under `AIScan.maxBytes`. **Never stored on the server and never logged**; it goes to
  Anthropic as base64 for that one reading. The route refuses an empty body (400), more than
  `maxBytes` (413) and anything that does not start with JPEG's marker (415) before any call;
  the request body itself is capped at 2,100 KB.
- The reading is held to the wire: `slot` a `GarmentSlot` raw value (else `unknown`), colours at
  most four, style at most five. **`isGarment: false` — or a reading with nothing to search
  for — is returned and not charged.**
- *Add to my wardrobe* saves a `SavedItem` whose photograph is the reader's own and which has
  no product behind it. *Does it go with my wardrobe* runs on the phone (`Pairing`, `Outfit`)
  over the reading — the wardrobe never leaves it. *Find this* uses `similar` when it is there,
  else searches `searchText`.
- **`similar` is found by the photograph first, then by the reading's words** (Phase 5,
  `AIScanSimilar`). The photograph's bytes go to the sidecar's `POST /embed/photo` — JPEG only,
  capped at 2 MB, the same token, embedded and dropped by both sides — under a 4 s deadline
  (`photoTimeout`: one forward pass is about 0.3 s on 2 vCPU), and its vector is compared with
  every product's *image* vector under the same model; the eight nearest shown products across
  every shop come back with `similarBasis: "photograph"`. Where that cannot answer — a provider
  that does not embed images, a slow sidecar, no product photograph embedded yet — `searchText`
  is embedded under the 1.5 s deadline a search gets and matched against the products' text
  vectors, `similarBasis: "description"`, as before Phase 5. Semantic search off or resting, or
  nothing near: nil, and the phone searches `searchText` as the field would. The log line on a
  failure names what failed, never what was sent.
- **The reading has a short name** (Phase 5, `AIScanReading.name`, required in the tool's schema,
  at most 40 characters on the way out): "Black chore jacket", which *Add to my wardrobe* makes the
  save's title, with `description` kept as the save's note. A server that predates it sends none,
  and the save is titled by the description, as before.
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
  host's own field when it passed `onFind` — unless `similar` came back, which is shown in the
  sheet wherever the scan was opened, because the field would reduce it to the reading's words.
  The line above it says which it was ("… look like your photograph.", "… like its description.").
  A reading that is not a garment offers none of the three.
- **The scan and the fit canvas call through `AIStore`**, the same store Shop's search does —
  `isAvailable` draws the camera and the Ask menu at all, `costLabel(for:)` puts the price on the
  button (and nothing is printed as free when the server named none), and every refusal is an
  `AIRefusal` drawn by `AIRefusalNotice`. Shop's field carries the camera in `trailingControls`,
  with *Find this* landing in the field (`ScanButton(side:onFind:)`).

## Fits

- **Judge** (`POST /v1/ai/fits/judge`) sends two to eight pieces — catalogue photographs by URL
  (sent to Anthropic as a URL source, so Anthropic fetches them, not this server), the reader's
  own as JPEG — and gets the worst-case verdict `Outfit` already speaks in (`works`, `risky`,
  `clashes`; anything else is a failed call), a line, up to four notes, and the one piece to
  change. A `swap` outside the pieces is dropped.
- **Suggest** (`POST /v1/ai/fits/suggest`) sends the fit (one to eight pieces) and up to twelve
  candidates the phone already chose (`FitSuggestions`); the model only orders them and drops the
  ones that clash. **Every index it returns is validated**: one outside the candidates, or a
  repeat, is dropped. An empty answer is a real one — nothing goes — and is charged. The
  rule-based row still draws first and for free; asking is a button.
- Each piece needs exactly one photograph (400 otherwise); titles are cut to 120 characters. At
  most eight of the reader's own photographs in one suggest request; both bodies are capped at
  17 MB, which is eight own photographs at the limit — catalogue pieces are a URL each.
- Both are things somebody asked for, about garments they chose to send. On the phone they are
  the fit canvas's **Ask** menu (`FitAsk`); see `docs/fits.md`, *Asking about the photographs*.

## Reading where rules cannot

Owner-paid, metered with no account and no user, under `AI_BACKGROUND_DAILY_CAP_MICROS` (default
1,000,000 — $1 a day — summed from `ai_costs` rows with neither key since midnight UTC, which is
also where pick sentences are counted): reaching it stops background work until the next UTC day,
never a reader's action. Off entirely when AI is off. `AIBackgroundReading`.

- **Sale banners**: the end date, a code and the fine print, read **once per sale** — on the pass
  where `SaleBannerLedger` has just decided the bar is a new sale, and only after the quiet period
  is checked, so a reworded bar or a sale the catalogue already announced is never sent. The
  reading goes on the `.sale` event (`events.sale_ends_at`, the end of that day in UTC, and
  `events.sale_terms`, one line, `AddSaleReading`) and travels as the optional
  `FeedItem.saleEndsAt` and `FeedItem.saleTerms`; a code the pattern missed is added to the
  event's title as `· CODE X`. A date outside yesterday…120 days is dropped, a code that is not
  letters, digits, `-` and `_` is dropped, and a reading with nothing left is no reading. A
  failure announces the sale exactly as before.
- **Product pages with no structured data**: in `Poller.enrich`, a product the poller is about
  to announce (`pending_announcement`) whose page loaded and published nothing `ProductPage` can
  read is asked of the model **once**, from the page's visible text (scripts, styles and markup
  stripped, the first 12,000 characters — a product page says what it sells near the top, and
  every character is paid for). At most two a pass (`Poller.pageReadingBudget`). The reading —
  name, selling price and currency, availability, sizes — becomes a `ProductPage` and is laid
  over the row exactly as a structured page is; a URL only the page could confirm
  (`PendingAnnouncement.confirm`) needs a price as well. Never a baseline's rows, never a
  watched re-read.
- **Product photographs, only when the owner switches it on** (`PRODUCT_READING=haiku`, Phase 5,
  `CreditAction.productReading`). The product shot and style words are read by FashionSigLIP
  through the embedding sidecar by default; this sends the first six photographs, as 400 px
  renditions by URL, to the fast model in one call instead (`readProductPhotos`, tool
  `read_photos`: a photograph number, nought for none, and style words held to
  `StyleWords.vocabulary`). Estimated, not yet measured, at about $0.002 a product (six 400 px
  photographs are some 1,300 input tokens) — so roughly five hundred a day under the default cap — and switching method reads the catalogue again. The comparison that decides it
  is `Server/ReadingEval`; see `docs/server.md` (*The product photograph and style words*).

## Privacy

Every action is something the reader asked for, about what they chose to send, except the
pick sentence (a short description and an id) and the background reading (storefront pages and
product photographs, about nobody). No prompt, answer, photograph or typed text is stored or logged on our server:
Vapor's route log line is the method and the path, every body here is a POST, and errors carry
statuses and error types only. `ai_costs` keeps numbers only; the two texts stored are a pick's
sentence (keyed by a hash, naming nobody) and a sale's end date and fine print (about a shop).
Anthropic processes what is sent to answer it; the privacy policy names it.

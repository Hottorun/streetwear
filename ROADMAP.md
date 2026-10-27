# streetw — roadmap

## Positioning

Dropwall knows your shops and your style. Ask it for something — "a black suit under €400" — and
it searches the shops you follow first, ranked by your taste, then brands like them, then the open
web if you ask for more. Leave it alone and it tells you when those shops drop, restock or go on
sale.

So a follow does two jobs: it is what gets watched, and it is where the AI shops for you. That
combination is the product. Shopping assistants don't know when anything drops, and drop apps
can't find you anything. The watching engine is the part that is hard to copy and the part that
already works; AI takes over the jobs that used to need hand-written rules — understanding a
garment, matching a description, judging an outfit.

It is for anyone and any kind of clothing. Streetwear was the starting point, not the boundary:
menswear and womenswear are equal, and fast fashion is followed too — usually to track prices, or
to tell the AI what you like.

Two registers, kept deliberately distinct:

- **Feed** — time-sensitive: drops, restocks, sales, countdowns. Urgency affordances allowed.
- **Collection** — permanent, private, no badges, no counts, no "new" dots.

## Decided

Planned on 2026-10-24, after 1.0 reached the App Store. Each decision carries its reason, because
most of them read as arbitrary restraint without it.

- **Server-backed.** A small backend polls sources on a schedule and pushes via APNs. iOS
  `BGAppRefreshTask` is opportunistic — a few system-chosen wakeups a day — and drops resolve in
  minutes, so client-only polling cannot support drop, restock or shock-drop alerts.
- **Instagram is never scraped.** Link-out only. The `BrandSource.Kind.instagram` slot stays
  adapter-less; if a best-effort third-party "teased something" flag is ever added it goes there,
  and everything else keeps working when it breaks.
- **AI is Claude, called from the server only, behind an interface that can be swapped.** One
  provider, because two means two bills, two ways to fail and two sets of prompts drifting apart.
  Anthropic's API directly rather than Bedrock: one key, new models first, and Bedrock does not
  need AWS hosting anyway, so the swap stays small if it is ever wanted. Never from the phone — a
  key shipped inside an app is a public key. Apple Intelligence is not good enough for these jobs
  yet.
- **Personal data leaves the phone one request at a time, and only after opting in.** 1.0 promises
  that saves, boards, fits, the style statement and the taste vector never leave the device, and
  every AI feature breaks that promise. So: only what the request needs, nothing kept once it is
  answered, an opt-in on first use, and everything that works today keeps working with AI off.
  The one standing exception is **daily picks**, which has to remember taste between visits: a
  numeric taste summary — not the saves, not the photographs — under its own opt-in, deletable.
  The privacy policy and the App Store privacy label are rewritten **before** any of it ships.
- **No auto-buy agent.** It would hold card details and logins for every shop, break nearly every
  store's terms, have to beat the bot protection shops put on drops specifically, and its failure
  is spending somebody's money on the wrong size. One-tap checkout (Phase 0) gets almost all of
  the speed with a person still deciding.
- **No getting around bot protection.** Bershka refuses every request at Akamai, robots.txt
  included. Getting past that means renting residential proxies — other people's connections,
  often without their real consent — and faking browsers through them. It would cost more per
  month than the whole server, break every few weeks, and copying a catalogue past a deliberate
  block is where scraping turns legally risky, especially in the EU, where a catalogue can be
  protected as a database. KERN AG's name is on the app. Such a shop is labelled "blocks
  automated watching"; saving from Safari through the share sheet still works, because the
  person's own browser gets in.
- **AI is paid for with credits that never expire.** Apple must sell a digital feature through
  in-app purchase, keeps 15–30% of it (15% under the Small Business Program), and only Apple can
  refund — so "pay exactly what you used and get the rest back" cannot be built, and an exact cost
  per action would be a different price every time. Instead: a fixed number of credits per action,
  packs that never expire (nothing is wasted, so nothing needs refunding), a small free monthly
  allowance, and usage shown in the app. **Prices come from measured costs, not guesses:** AI
  launches with a generous allowance for signed-in users while the server records what every
  action really cost.
- **Stay on Railway.** Checked on 2026-10-24 against each provider's own pricing page; the totals
  are estimates. Railway is ~$16–20/mo today and ~$77–97 at ten times the users. AWS (Fargate, a
  load balancer and RDS) is ~$74–87 today; the cheapest managed alternative, DigitalOcean, ~$25.
  The only real saving is a self-managed Hetzner box at 10×, about $40/mo, bought by running the
  database, its backups and its upgrades yourself. Two Railway limits are already in Phase 3.
- **A profile is a person; a mood is a board.** "For my partner" needs their own sizes, gender
  filter, follows and alerts. "Suits versus streetwear" is the same person in another mood, and
  needs only a different source of taste. One concept for both would serve both badly. Profiles
  share the account, the credits and the location; their alerts arrive labelled ("For Anna: …").
- **A follow has a mode:** *Everything*, *Sales and price drops only*, or *Quiet* — no feed and no
  alerts, but it still shapes taste and search. Following H&M the way you follow Kith would bury
  the feed in daily arrivals. The mode lives on the server, because `Notifier` has to know it,
  and it replaces `Brand.isMuted`, which is phone-only and drops pushes the server already sent.
- **Location is a setting, and the data is region-aware from the first row.** Big retailers run a
  shop per country — Victoria's Secret UK is a different company from the US one. So every stored
  price carries its country and currency, a brand maps to its storefront per country, and a
  country's storefront is only polled if somebody there follows the brand. Countries are switched
  on one at a time as users appear, because each one multiplies the polling of every brand
  followed there.

### Rules from 1.0 that change on purpose

Each of these contradicts something in `docs/design-decisions.md` or `docs/ucp.md`. Each is a
deliberate change, to be written into that doc with its reason when it is built — never a quiet
exception.

- **A price drop on something you saved or watch sends a push.** Today `UpdateKind.isSudden` *is*
  `Notifier.isWorthWaking`, and a price drop is not sudden. A markdown on something you chose to
  keep is news about you. A brand-wide markdown still is not, which is why that alert is opt-in
  per brand.
- **The feed stops being grouped by brand.** One card per event, newest first. The grouping is
  what produces the headers, the counts and the "›" links. The rule it protected — one busy brand
  must not flood the feed — survives, because the *event* stays the unit: a 24-piece drop is one
  card.
- **The brand rail leaves the head of the feed.** It replaced a Brands tab; brands become a feed
  filter plus a list under You › Following.
- **Unread becomes "since you were last here".** No per-brand checkmarks, dots or counts to
  manage. Push is what finds you.
- **UCP stays read-only for now.** See *Later*.

### Explicitly out of scope

| | Why |
|---|---|
| Resale price pull-in (StockX/GOAT) | No public API; third-party resellers are expensive and unstable |
| Raffle autofill | Even single-entry is substantial work and bot-adjacent; not needed now |
| Social / community feed | Different product, cold-start problem, fights the calm-archive positioning |
| Auto-buy agent | See *Decided*; one-tap checkout instead |
| Getting around bot protection | See *Decided*; a blocked shop is labelled, not broken into |
| Billing exact AI cost, refunding unused balance | Impossible through in-app purchase; credits never expire instead |

## The plan

Each phase is its own App Store update. AI comes last on purpose: it is only as good as the
catalogue it searches — today the newest ~250 products per Shopify brand and 60 per sitemap brand
— it needs accounts before it can be paid for, and it lands in a Shop tab that does not exist yet.
Phases 2 and 3 can overlap.

### Phase 0 — fixes and quick wins, no AI

Mostly things that hurt people using 1.0 today.

- [x] **Discovery as a background job.** A non-Shopify site costs ~13 requests at 2s spacing, the
      server answers nothing until it has finished, and the app gives up after 30s of silence.
      Measured against subdued.com: 26.8s from a fast connection — and the app runs it twice, the
      probe and then the add. Hollister follows eight redirect loops and certainly overruns. Many
      "this site failed" reports are probably this rather than the site.
      *Done:* `POST /v1/brands/checks` answers in ~0.1s and the screen asks after it; the add
      reuses the preview's check; START WATCHING works while it runs and the server follows the
      shop and pushes when it finishes. Checked live: Subdued and Hollister both settle in ~21s.
      The 1.0 routes stay for the build in the App Store. See `docs/server.md`.
      *Found on the way, and the bigger half of "Hollister and Subdued fail":* the add screen's
      copy of the watchability rule (`BrandProbe.canMonitor`) still refused a page watch after the
      server had stopped refusing one, so a page-only shop read "Nothing to watch here" with the
      button disabled. Fixed, with a test that the two rules agree.
- [x] **A generic `<title>` becomes a brand's global name.** Hollister's check suggests "Clothing
      for Women & Men" — the first segment of its title. `BrandNaming` refuses "Home" and
      "Official Site" but not this, and a page-watch brand has no `/meta.json` to correct it later.
      *Done:* `BrandNaming.isDescriptive` refuses a candidate carrying a catalogue noun unless the
      domain agrees with it, and the title segment that names the domain wins — Hollister reads
      "Hollister Co.".
- [x] **The sitemaps real retailers publish.** Hollister, Subdued and victoriassecret.com list
      theirs only in robots.txt, at non-standard paths. Read the `Sitemap:` lines; follow nested
      indexes (VS is two levels deep, and the three-child cap picks nl/at/au before en/us); treat
      a URL seen for the first time as new rather than trusting `<lastmod>`, which only one of the
      three carries usefully; and decide what is a product from the page's data rather than URL
      patterns, which missed two of the three shapes.
      *Done:* `Sitemap:` lines from robots.txt first; nested indexes to three levels;
      `SitemapChoice` picks product files and one storefront per locale; what is new is what the
      source has not seen (`SitemapMemory` in the fingerprint), with a silent baseline and a
      re-baseline when a sitemap is rebuilt; read at most hourly. Hollister, Subdued and Victoria's
      Secret now yield products.
- [x] **Robots.txt on every redirect hop.** Only the first URL is checked today, and redirects are
      followed unspaced — into disallowed paths included.
      *Done:* `Net.session` follows nothing; `PoliteFetcher` follows by hand (`Net.maxRedirects`)
      and checks every hop's host, robots.txt and spacing. Also fixed: `Disallow: /gb/` could never
      match, because `URL.path` drops the trailing slash. Linux redirect behaviour is read from
      source, not yet run.
- [x] **Product details from the page.** Read schema.org `Product` JSON-LD — name, price,
      availability, images, SKU — once per new product. It was on every product page that could be
      loaded. Replaces the slug-and-one-photograph sitemap row; this was *Still open* since 1.0.
      *Done:* `ProductPage` reads schema.org `Product` (both offer layouts); the server holds a
      sitemap product's event until its page is read (`Poller.enrich`, a few pages per pass) and
      deletes a tentative URL whose page shows no product; standalone fills rows in place.
- [x] **Sizes read by garment type, plus womenswear and tailoring.** A US dress size 4–18 and
      "UK 10" are read as shoe sizes today, "EU 38" too, and "40R" and "34B" are not understood at
      all — so a woman who has entered a shoe size can have dresses wrongly hidden or wrongly
      matched. That is a live bug. The `GarmentSlot` decides which ladder a number belongs to; add
      women's numeric sizes (US/UK/EU/IT, canonicalised the way shoes are) and men's suit sizes.
      A string that still cannot be placed stays `.other` and is never hidden.
      *Done:* `SizeContext` (no default anywhere) decides the ladder; women's numeric (UK = US+4,
      FR = US+32, IT = US+36, one-rung tolerance) and suits (chest inches, EU = chest+10, lengths
      separate) on both ends and in onboarding/Settings. Known gap: a UK shop printing bare UK
      numbers reads two rungs off until region-aware data exists.
- [x] **Events past 200 between two syncs are lost.** `/v1/feed` pages newest first,
      `nextCursor` is the *newest* event, and the client asks once with `limit 200`, so the
      overflow is never delivered — and one busy brand can fill the page. Found by reading the
      code; reproduce it in a test before fixing. Needs per-brand fairness too.
      *Done:* reproduced first (200 of 251 delivered); the server pages fairly between brands with
      a continuation token (`FeedPaging`), the new client reads up to five pages a sync
      (`FeedPager`), and 1.0 still gets one page — now losing the deep end of the busiest brand
      rather than a quiet brand's drop.
- [x] **Sales.**
      - Read `compare_at_price`, so a product that goes live already discounted counts.
      - A price drop on a saved or watched item pushes (see *Rules that change*).
      - "Sale is live" for a whole brand: one push when a large share of a catalogue is marked
        down in one pass, opt-in per brand.
      - Sale banners. "25% off everything with code AUTUMN" lives in the homepage announcement
        bar and in the cart, never in a product price. Read the homepage every 30–60 minutes,
        match sale wording, and alert once per sale per brand with the percentage and the code.
        Pattern matching only, until Phase 4 can read the end date and the fine print.
      *Done:* `compare_at_price` read and carried as the brand's "was"; a markdown on a watched
      item pushes (exempt from modes and cooldown); a markdown on a saved item is a local
      notification, so saves still never leave the phone; a brand-wide sale (≥30% and ≥12 products
      marked down in one read) and sale banners (homepage announcement bar every 30–60 minutes)
      write one `sale` event per sale. **The follow mode is the opt-in** for sale pushes —
      Everything and Sales only get them, Quiet doesn't — rather than a separate per-brand switch.
      1.0 never receives the new kind: the feed sends only the kinds a client names in `?kinds=`.
- [x] **Follow modes** (see *Decided*), on the server, replacing `Brand.isMuted`.
      *Done:* `follows.mode` (default everything), `PATCH /v1/follows/:id`, `FollowMode.admits` as
      the one rule for push and for what is stored already read; muted brands become Quiet on the
      first sync of the new build. Every new follow starts on Everything — no guessed default.
- [x] **The product photograph as the cover on the saved wall.** `ProductShot` already finds the
      photograph with nobody in it, and deliberately uses it only for measuring. On the wall and
      the saved item's page it becomes the cover and leads the gallery, with "Set as cover" to
      override it. The feed and Discover keep the brand's own first photograph, because there the
      styling is part of the announcement.
      *Done:* hand-picked cover, else the packshot, else the brand's first photograph, on the wall
      and the save's page only; "Set as cover" in the gallery.
- [x] **Multi-select, and one item on several boards.** There is no multi-select anywhere, and
      `SavedItem.board` is to-one although boards are "filters, not folders". Make it
      many-to-many — a migration that must not lose a single assignment — then a select mode on
      the wall and on boards: add to or remove from boards, switch Inspiration/Wardrobe, delete,
      start a fit, leave out of taste.
      *Done:* `SavedItem.boards`, with the old filing copied across once at launch
      (`BoardFiling.adoptLegacy`) — verified by installing over a store the unchanged app wrote.
      Select mode on the wall and boards with every bulk action listed above.
- [x] **Leaving things out of your taste.** Per board: counts (the default), doesn't count, or
      *inspire me from this* — the mood. Per item: "don't use for my taste". Ignored by everything
      that infers taste — Your taste, picks, Shop ranking, brand suggestions — while a wardrobe
      item can still go into a fit, because it is still owned.
      *Done:* one rule, `TasteRule.role` via `TasteScope`; one mood board at a time, weighted as
      much as the rest of the collection combined.
- [x] **Checkout links.** Shopify: `/cart/<variant_id>:1` with your size already in the cart.
      Everywhere else: the exact product page, opening the shop's own app when it is installed
      (already signed in, payment saved) and Safari otherwise, with the size preselected where the
      platform's URLs allow it and named in the alert where they don't.
      *Done:* `Checkout.link` — "CHECK OUT IN M" when exactly one available variant is yours by
      `claims`, in the garment's own size context; the product page otherwise, opened so the shop's
      own app can take it. Not done: naming your size in an alert for platforms that cannot
      preselect one.
- [x] **Anonymous usage counts, on our own server.** Tab opened, search run, alert tapped, saves.
      No third-party SDK: the smallest step from 1.0's "no analytics" promise, and needed before
      choosing which AI features are worth paying for. The privacy policy names it.
      *Done:* `POST /v1/usage` adds daily totals with no user or device id; weekly actives from one
      overwritten day on the device row; `GET /admin/usage`. **Before it ships:** publish the
      updated privacy policy and add Analytics to Product Interaction on the App Store privacy
      label.
- [x] **The Discover card's description is centred** while everything around it is leading-aligned
      (`DiscoverCardView.swift:602-617`), probably a missing `.multilineTextAlignment(.leading)`
      inside a `Button`.
      *Done:* `.multilineTextAlignment(.leading)` on the label.
- [x] **`docs/ucp.md` ranks UCP below the sitemap; `BrandDiscovery` tries it first.** Decide which
      is intended and make them agree.
      *Done:* the code was right — UCP carries prices, sizes and stock on every poll — so the docs
      now agree with it.

### Phase 1 — the redesign

Prototype the new feed and Shop tab on the demo catalogue first, beside the current app, before
rebuilding anything.

- [x] **Three tabs and a You button.** *Feed* — what happened at your shops. *Shop* — Discover with
      the AI search on top and daily picks when the field is empty. *Saved* — Inspiration,
      Wardrobe and **Fits**. Your avatar, top right on every tab, opens *You*: taste, sizes,
      location, following, profiles, credits, sign-in, settings. The Style tab goes: kept and
      suggested fits move to Saved › Fits, "what's missing" drives Shop's picks, "your taste"
      moves to You. Today a fit can be started from three tabs and two detail pages and lands in
      one of two editors; it should start in one place and land in one.
- [x] **One picture per event.** Photograph, brand, one label — "NEW", "BACK IN YOUR SIZE",
      "−30%", "SALE 25% OFF · CODE AUTUMN", "DROPS FRIDAY" — and the price. A drop of many pieces
      is one card with a few photographs and "24 pieces". Today's first screen shows five counters
      and markers and three lines of links before its one photograph, whose name and price sit
      under the tab bar.
- [x] **"Since you were last here"**, a line rather than per-brand unread state.
- [x] **One filter row** — All · Drops · Restocks · Sales · Upcoming · Brand ▾ — replacing the
      brand rail and the two unlabelled icons (the calendar, and markdowns with its system badge).
- [x] **Onboarding and App Store copy for all of fashion.** The starter pack and the listing say
      streetwear.

*Done* in PR #2 (merged 2026-10-26): Feed, Shop and Saved with You behind the avatar; the grid of
event cards with bursts and releases as one card; the "since you were last here" line
(`BrandUpdate.arrivedAt`, `FeedVisit`); the filter row; Shop's local search and daily picks; one
fit editor; the starter pack of six womenswear and six menswear shops. See
`docs/design-decisions.md`, `docs/discover.md` and `docs/fits.md`.

### Phase 2 — accounts and paying

- [x] **Sign in with Apple, optional until it is needed.** StoreKit cannot restore consumable
      purchases, so a credit balance must live on the server under an identity that survives a
      reinstall — and today every reinstall is a new user. Required only for credits and profiles.
      Existing follows, sizes and watches move onto the account at first sign-in, and accounts can
      be deleted in the app, as Apple requires. Planned in `BACKEND.md` from the start.
      *Done:* the `accounts` table and `users.account_id`. `POST /v1/account/apple`: the first
      sign-in adopts the device's user, and a later one merges the anonymous user into the
      account's in one transaction. `DELETE /v1/account` revokes Apple's token when a key is
      set. `GET`/`POST /admin/accounts` hold the owner's unlimited-credits flag. On You, the
      section is hidden standalone and whenever the server says it cannot verify. The owner
      approved swift-crypto (`_CryptoExtras`) and swift-certificates, and the identity-token
      verifier is real: RS256 against Apple's cached JWKS, re-read on an unknown `kid` at most
      once per five minutes, then the claim checks (see `docs/server.md`).
      **Before it ships:**
      - Turn on the Sign in with Apple capability for the App ID.
      - Set `SIWA_KEY_ID`, `SIWA_TEAM_ID` and `SIWA_PRIVATE_KEY` on Railway.
      - Name the account in the privacy policy.
- [x] **Profiles**, each with its own sizes, gender filter, follows, saves and taste — one server
      user per profile under the account. Alerts are labelled, and each profile can turn its own
      off.
      *Done:* `users.display_name` and `users.alerts_enabled`; `/v1/account/profiles` to list,
      add, rename, switch alerts and delete (the holder goes only with the account); every other
      route acts for the profile `X-Profile-ID` names, checked against the device's account, and
      is unchanged without it. `Notifier.audience` sends every profile's alerts to the account's
      phones, "For Anna: …" when it is not the holder's, collapsed per profile. On the phone, one
      SwiftData store and one set of `UserDefaults` keys per profile, the holder's being the ones
      that already existed; Profiles on You when signed in; shares, local alerts and reminders
      follow the current profile. Credits and the location are the account's: every profile spends
      from one ledger, and a country set by any profile is the whole account's.
      See `docs/profiles.md`.
- [x] **The location setting** and the region-aware price model (see *Decided*), defaulting to the
      phone's region.
      *Done:* You › Location, the phone's region unless chosen, held on the server as
      `users.country`. A brand's main shop stays the brand row and every existing source, product
      and event is it (`storefront_id` null — no backfill, no re-poll, no baseline spent); a
      country's shop is a `storefronts` row attached by hand (`POST /admin/brands/:id/storefronts`)
      for a set of countries — `eu.kith.com` is one shop for 48 — polled once while any of them is
      in `STOREFRONT_COUNTRIES` and has a follower of the brand, and each person is served one
      shop per brand in the feed, a brand's feed, Discover, every brand on the wire and pushes.
      Every stored price carries its currency, nothing converts, and the app prints each row in
      its own currency in the reader's locale. None switched on yet. Gaps: sale detection and
      Shopify Markets subfolders are main-shop only. See `docs/server.md`.
- [x] **Cost metering and credits.** Every AI action records its real cost; consumable packs via
      StoreKit; usage shown ("this month: 23 searches"); prices set after a few weeks of
      measurement.
      *Done:* `CostMeter` writes numbers only to `ai_costs`, read back per action with p50/p90 at
      `GET /admin/costs`; `credit_ledger` is the balance, spent under a per-account row lock, with
      a lazy free monthly allowance, the owner's unlimited switch and monthly cost cap; StoreKit
      purchases credited once per transaction at `POST /v1/credits/purchases`, refunds from App
      Store Server Notifications V2; Credits on You for signed-in accounts, with a local
      `streetw.storekit`. The StoreKit verifier is real, on the dependencies the owner approved:
      the `x5c` chain to a compiled-in Apple Root CA - G3 with Apple's marker OIDs, valid at
      `signedDate`, ES256 over the leaf's key, for purchases and for each signed part of a
      notification. See `docs/credits.md`. **Before it ships:** create the three products in App Store Connect; give it the
      notifications URL; set `CREDITS_ALLOW_SANDBOX=true` for review; set the prices and the
      allowance from a few weeks of `/admin/costs` once Phase 4 runs.
- [ ] **The new privacy policy and App Store privacy label**, before any of the above ships.

### Phase 3 — the catalogue and search behind the AI

- [ ] **A Postgres with pgvector, and the embedding service beside it.** The default Postgres has
      no pgvector and Railway does not plan to add it, so this is the pgvector template plus a dump
      and restore — a planned migration with a new `DATABASE_URL`, not a toggle — and then the
      `embeddings` service and two variables on the server (`docs/pgvector-migration.md`). The
      template runs on Hobby; what Hobby limits is the volume, 5 GB, and measured storage is about
      16 MB per 1,000 products with both vectors, so **Pro is not needed for storage yet** — move
      when `databaseBytes` passes half the cap. On cost Pro meets Hobby once usage passes $20 a
      month, which the embedding service's memory alone nearly does. Turn on daily snapshots, and
      keep the server on the private database URL; over the public one, the traffic is billed as
      egress.
- [x] **Catalogues at two speeds.** The fast "what's new" poll stays as it is. A daily full scan
      stores every product with its price and stock; for Shopify a 5,000-product shop is ~20
      requests. Today a Shopify brand's baseline is its newest 2,500 and only the newest ~250 are
      re-read, so older stock — exactly what goes on sale — is invisible to sale alerts and would
      be invisible to search. A huge non-Shopify retailer cannot be scanned honestly (20,000 pages
      at 2s is ~11 hours per brand), so there new products are enriched once, and price tracking
      is **per item**: whatever somebody has saved or watches has its own page re-checked.
      Brand-wide sale detection is not available for those.
      *Done:* every Shopify source is read to the end once a day on its own loop, at a slot fixed
      by its id, under a `FOR UPDATE SKIP LOCKED` lease on `catalogue_scans`, four pages a turn and
      resumable; it writes only what changed, stores what it meets first silently, leaves anything
      published in the last day to the poll, and is a baseline the first time, so a first scan of a
      5,000-product shop emits nothing and a later markdown on old stock emits exactly that.
      Missing from two complete scans in a row is unlisted and ages out through retention.
      `CatalogueSale` also measures the buyable catalogue; either reading may start a sale, only
      both together end one. Country shops are scanned while read. Per item: watched sitemap and
      UCP products, two pages per host a pass — the server only knows watches, since saves never
      leave the phone. Measured: Aimé Leon Dore live, 900 products in 4 pages and 8s; on Postgres
      ~3.2 MB per 1,000 products, and an unchanged scan rewrites nothing. `/admin/status` reports
      `databaseBytes`. See `docs/server.md`.
- [ ] **Product search.** None exists — the only search is `ILIKE` on brand names. Postgres
      full-text plus pgvector embeddings of each product's text and photograph, built once per
      product. The same index serves "more like this", Shop's ranking, daily picks and the scan.
      *Done, the full-text half:* a generated `simple` tsvector on `products` (title, type, tags,
      weighted) with a GIN index, colourways through an expression index, brand names in Swift;
      `GET /v1/products/search?scope=followed|all` runs the phone's own `ShopQuery` and
      `ShopSearch` over the candidates, so price bounds, "no …", "in my size", the gender filter,
      the ranking and the six failures mean the same on both ends; `GET /v1/products/:id/similar`.
      Shop searches the server in server mode — your shops, then every shop we watch when asked —
      and "more like this" asks it. 20–130ms on eight thousand products, release. See
      `docs/server.md` and `docs/discover.md`.
      *Built and off in production:* one `EmbeddingProvider`, its sidecar client
      (`SidecarEmbeddingProvider`, on with `EMBEDDING_URL` and `EMBEDDING_TOKEN`),
      `product_embeddings` keyed by model id, the backfill (unreadable photographs written off,
      not retried forever) and vector "more like this" — proven end to end against the real
      service and a pgvector Postgres. **Waits on:** the move to a pgvector Postgres and the
      `embeddings` service deployed (`docs/pgvector-migration.md`, both parts). Marqo
      FashionSigLIP v1 by default; the ZooClaw SigLIP2 fine-tune is one build variable away
      (`Embeddings/README.md`). Daily picks and the scan do not read the index yet, and no query
      reads the image vectors yet.

### Phase 4 — AI

- [ ] **The provider layer** — Claude behind a small server-side interface, recording the cost of
      every action.
- [x] **Search in Shop.** "Black suit under €400": followed shops first, ranked by taste, then
      similar brands. Narrowed with chips or short replies — "cheaper", "more formal", "no wool" —
      each search keeping a short thread. **Show me more** goes to the open web through Claude's
      web search, and a result from a shop we can watch offers to follow it.
      *Done (app):* "Ask Dropwall" beside the free field, saying AI and its price; the model's
      reading printed through the phone's own `ShopQuery` line and searched exactly as typed;
      the reply line, suggestions as chips, a reply field that continues the signed thread for
      free and says when the next reply starts a new, paid one; your shops re-ordered by taste on
      the phone (`TasteOrder`), then every other shop we watch; Show me more in the reader's
      country, each result opening the shop's page, its brand, or the site check. Each action
      prints its charge; 402/403/429/503 are said in words. `AIStore` is the one client. See
      `docs/discover.md` (*Asking Dropwall*).
- [x] **More like this**, on every product and saved item.
      *Done:* the product page's row (`GET /v1/products/:id/similar`, local fallback) on a saved
      item's page too, wherever a catalogue product stands behind the save. Free, no model.
- [x] **Daily picks.** Free, because nobody asked for them. Ranked by similarity to the taste
      summary with no model call per person; the model writes a short reason for the top few
      ("goes with your black chore jacket"), cached. They fill Shop when the field is empty, with
      an optional daily push, off by default. Only things in your size, in stock in your country,
      and never anything already seen, saved or dismissed.
      *Done (app):* chosen exactly as before (`DailyPicks`, now gathered by `TodaysPicks`); the top
      three worded by `POST /v1/ai/picks/reasons` once a day per pick, the partner sent as a short
      description only, silently falling back to the phone's sentence; a local morning alert, off
      by default (You › Alerts), scheduled only by a background pass that has just chosen the
      day's set, withdrawn once Shop has shown it.
- [x] **Clothes scan.** One camera button, on Saved's "+" and in Shop's search field. On-device
      cutout, then Claude reads type, colour, material, pattern and style, and you choose: *add to
      my wardrobe* (a saved item with your own photograph — every save has a product behind it
      today, so a small model change), *does it go with my wardrobe* (a verdict and two or three
      fits — the in-store use), or *find this or something like it*. Two credits; only that one
      photograph is sent.
      *Done:* `ScanButton` (Saved's "+" › Scan a garment, and Shop's `trailingControls`), camera
      or photo library, `ScanPhoto` cuts out where `Cutout` can and says when it cannot, the price
      on the send button. The model change is optional `own…` columns on `SavedItem` with
      `update == nil` — no new model, lightweight migration verified over a store the previous
      build wrote — and the photograph beside the store (`OwnPhotos`); every surface that draws a
      save asks the save (`docs/collection.md`, *A garment of your own*). *Does it go* is
      `ScanVerdict` + `FitProposal.outfits`, on the phone; *Find this* is `similar` or a product
      search, or Shop's own field. Verified against a local server with `AI_FAKE`. Not reached:
      Shop's picks and Discover's pairing still skip garments of your own.
- [x] **Fit judging and suggestions that look at the photographs.** Nothing does today, so a
      suggestion can pair two things that clash.
      *Done:* the fit canvas's **Ask** menu (`FitAsk`): *Judge this fit* draws the verdict, notes
      and a mark on the piece to change; *Suggest what goes with it* sends the rule-based
      candidates and draws the model's order as a second shelf, LOOKED AT, after the free one.
      Prices on the items, refusals in words (`docs/fits.md`, *Asking about the photographs*).
- [ ] **AI reading where rules can't**: sale banners (end date, fine print), and product pages with
      no structured data — new products only, never every poll.

### Later

- **A UCP cart, handed over to finish.** The sanctioned version of auto-buy: for a shop that
  publishes UCP, build the cart with your size through the protocol and hand over the shop's own
  checkout. The app never holds a payment detail or completes a purchase, which is Supreme's own
  line — "checkouts are for humans". Needs `docs/ucp.md`'s *read-only by construction* rule changed
  on purpose, and a check that the spec's cart response carries a checkout link. Meanwhile, count
  how many followed brands publish UCP; discovery already looks.
- **A full chat**, grown out of search's follow-ups once people use them.
- **Affiliate and partner product feeds**, for retailers that block bots — the only honest route to
  an Inditex-sized catalogue, and a commission on purchases besides. A business question before it
  is a code one; which networks carry which brands is unchecked.
- **More countries**, one at a time.
- **Bra sizes.**
- **Widget and Live Activity** for countdowns, carried over from 1.0.
- **Self-managed hosting**, only once the Railway bill is large enough for ~$40/mo to matter.

## Known gaps

- Vision's image classifier cannot initialise in the Simulator ("Failed to create espresso
  context"), so categories only populate on a real device. The colour path works in both, and the
  text vocabulary covers the gap — but simulator screenshots understate what the profile knows.
- `TODO.md` holds the review of 2026-09-07. Everything in it is closed except the five items under
  *Needs reproduction*.

## Shipped in 1.0

Kept as written at the time, because it is the record of why things are the way they are. Two
entries have since been overtaken: push is live (CLAUDE.md, *Push, and why it was silent for
months*), and the server address can no longer be cleared to mean standalone (CLAUDE.md, *The
server address is not a setting*).

### Phase 1 — make the existing app trustworthy ✅

Done. Measured against Kith and Billionaire Boys Club.

- [x] **Paginate `products.json`.** Sorted by `published_at` desc, and `limit=250` (the max page
      size) covered only ~4 days of Kith. Now walks up to 10 pages and stops as soon as a page ends
      older than the last sync: **250 → 2,500 products** for Kith on a first sweep (11s), while an
      incremental sync still stops after one page. This also fixes restock detection for older
      items, which never re-entered the 250 window because restocking doesn't change `published_at`.
- [x] **Per-variant availability.** 2,353 of Kith's 2,500 products carry real sizes. Restocks now
      diff per variant and record which sizes returned — cards read "Back in M, L".
- [x] **Size profile.** Sizes come from the option axis actually *named* "Size" (Kith ships
      `[Size]`, BBC ships `[Color, Size]`, so position isn't fixed) rather than being parsed out of
      a joined title like "WHITE/OWHITE/CBROWN / 5". `SizeNormalizer` folds "medium"/"M",
      "9.0"/"9"/"US 9"/"US9" together. Feed gains a "my size" filter and a "Your size" badge;
      verified in the simulator, 12 → 10 items when filtered to M, L, XL · US 9, 9.5.
      Deliberate rule: **unrecognised sizing is never hidden.** EU ("44") and waist ("32") numbers
      fall through to `.other` and always match, because a missed drop costs far more than a
      false positive. `SizeProfile`/`SizeNormalizer` live in the portable layer — the server needs
      exactly this logic to target restock pushes.
- [x] **Per-shop currency + real brand name from `/meta.json`.** Replaced the USD assumption and the
      hostname guess — "Bbcicecream" is now "Billionaire Boys Club". Only overwrites the name while
      the user has kept our generated guess (`Brand.usesGeneratedName`).
- [x] **Conditional GETs.** `ETag` stored per source and replayed as `If-None-Match`; verified
      returning 304 on an unchanged catalog, so a poll costs an empty body instead of megabytes.
- [x] **Per-source backoff** — `2^failures` minutes, capped at 6h (`BrandSource.isReadyToCheck`).
- [x] **Concurrent brand sync** via `TaskGroup`, previously strictly serial.
- [x] **Disk image cache** — `URLCache.shared` configured at launch (32MB memory / 512MB disk);
      `AsyncImage` goes through `URLSession.shared` and was refetching on every scroll.
- [x] **Retention/pruning** — 400 newest per brand, never dropping saved or unread items.
      Verified: 3,931 fetched → 800 stored.
- [x] **Surface `source.lastError`** including failure count and backoff state.

#### Keep the adapter layer portable

`streetw/Sources/` must stay free of SwiftData, SwiftUI and UIKit so it can be lifted into the
server target unchanged. `UpdateKind` and `VariantInfo` were extracted out of the `@Model`
`BrandUpdate` for exactly this reason — `BrandUpdate.Kind` is now just a typealias. The layer
compiles standalone with no shim; keep it that way.

### Phase 2 — the backend ✅

Done. See `BACKEND.md` for the reasoning and `Server/README.md` for how to run it.

Two things are built but not yet switched on, and neither is code: the server needs an
APNs key in its environment, and the app target needs the Push Notifications capability
(a paid team). Until then the whole pipeline runs and `/status` reports
`apnsConfigured: false` rather than pretending.

- [x] **SwiftPM monorepo + `StreetwCore` extraction.** Adapters, sizing and discovery moved to
      `Sources/StreetwCore/`; the app links it as a local package. Adapters now take an injected
      `HTTPClient`, which is what makes them testable and what will let the server swap in its own
      rate-limited client.
- [x] **First test target** — 40 fixture-driven swift-testing tests, no network. Building the
      package in Swift 6 mode immediately found a real data race (shared `DateFormatter`s used from
      the concurrent sync task group), and the tests found a real bug: a drop-lock was keyed so that
      it could only ever fire once per source, so a brand's *second* drop would never alert.
- [x] **Vapor skeleton, migrations, poller.** `Server/` is a separate SwiftPM package
      depending on `StreetwCore` by path, so the iOS project never resolves Vapor. Postgres
      in production, SQLite locally (array columns are `.json`, so one migration serves both).
      Verified end to end against live Kith and BBC: discovery → 1,461 products / 25k variants
      stored → **zero events on the first poll** (baseline) → a forced restock produced one
      event with `restockedSizes: ["M"]` and `availableInMySize: true` for a matching device.
      Now 32 tests, no network.
- [x] **Client syncs from the server.** Wire types moved to `StreetwCore` so app and
      server share one contract. The app registers a device, follows brands server-side,
      and fills its SwiftData store from `/v1/feed` — the whole UI, saving, style profile
      and size filter keep working unchanged. Standalone mode still works when no server
      is set. Verified end to end against a live server: restock detected → phone synced →
      feed shows "2 restocked · Back in M".
- [x] **All client operations routed through the server.** Audited and verified on the
      wire: register, size-profile push, site probe (dry run), add brand, follow, unfollow,
      feed sync. Local polling remains only as the standalone fallback when no server is
      configured.
- [x] **Deployed.** Railway, Postgres, poller running. The app ships the deployment URL as
      `ServerSettings.defaultBaseURLString`, applied only when nothing has been stored yet,
      so a fresh install is server-backed with no setup and an explicitly cleared field
      still means standalone.
- [x] **Fixed: every Postgres write touching a `[String]` column failed.** Device
      registration 500'd and the poller stored zero products, while brand and source
      writes on the same database succeeded — the difference being that only the former
      touch array columns. Fluent binds `[String]` as a native Postgres array, but
      `CreateSchema` declares those columns `.json` → JSONB, so Postgres rejects the
      insert. SQLite JSON-encodes instead, so it never reproduced locally, and production
      `ErrorMiddleware` reduced it to "Something went wrong."
      `FixPostgresArrayColumns` converts the five columns to `TEXT[]`; `/status` now also
      counts `users`, the one table whose absence from that check let a fully broken
      registration path report green. Deployed and confirmed live: `POST /v1/devices`
      returns a token and `users`/`devices` count up, where before it 500'd.
- [x] **Background refresh on the client.** `BGAppRefreshTask` registered in an
      `AppDelegate` and re-queued whenever the app backgrounds, so the feed is warm
      before it is opened. Explicitly the *fallback*, not the mechanism — the system
      grants a handful of wakeups a day, which is fine for staleness and useless for a
      drop. `UIBackgroundModes` and `BGTaskSchedulerPermittedIdentifiers` had to move
      into a real `streetw-Info.plist`: Xcode silently drops both as `INFOPLIST_KEY_*`
      settings, and the failure only shows up as a refused registration at runtime.
- [x] **Device registration → APNs, size-targeted restock pushes.** The server holds the
      size profile, so it can decide that a restock in M is news for one follower and
      not another — that targeting is the whole reason the profile lives server-side.
      Fan-out is behind a `PushSending` protocol, so who-gets-what is covered by 10 tests
      with no certificate and no network. Two rules shaped it: **one push per brand per
      pass** (a collection drop writes hundreds of events in one poll, and that has to be
      one notification), and **`notified_at` as a ledger in the row**, so a restart can't
      re-notify and a backlog older than 6 h is marked without being sent rather than
      fired as a burst about drops that already sold out. A token APNs rejects is
      forgotten; the device row survives, because it owns the follows.
      **Not yet live:** needs an APNs key on the server (`APNS_KEY_P8`/`_KEY_ID`/`_TEAM_ID`)
      and the Push Notifications capability on the app target, which needs a paid team.
      Without either, everything else works and `/status` says `apnsConfigured: false`.
- [x] **Fixed: a failed poll silently spent the brand's baseline.** Fallout from the
      array-column bug rather than a separate mistake — while writes were failing, Kith
      polled repeatedly and stamped `last_checked_at` each time without storing anything.
      The baseline rule keyed off that field, so the first working poll looked incremental
      and wrote **250 back-catalogue products as new-drop events**. Sources now carry
      `baselined_at`, set only once a fetch has completed and its batch is stored, and
      `SyncEngine` on the client got the same rule: `lastSyncedAt` is stamped only when a
      source actually succeeded. Two regression tests cover it.
- [x] **Politeness budget.** `PoliteFetcher` wraps any fetcher: robots.txt fetched once
      per host and obeyed (longest-match Allow/Disallow, wildcards, Crawl-delay, named
      groups), plus a reserved-slot limiter that spaces requests per host even under
      concurrency. The browser-spoofing User-Agent is gone — an honest
      `streetw/1.0 (+repo url)` was verified to get 200s from the storefronts we actually
      poll, so impersonation bought nothing and being identifiable is what keeps access.
- [x] **`FOR UPDATE SKIP LOCKED` on the poll queue.** The claim is a *lease*: a single
      statement takes the due batch and pushes `next_check_at` five minutes out before
      any network call, so two instances can never fetch the same storefront (which would
      multiply the politeness budget by the instance count) and a process killed
      mid-poll costs one lease rather than stranding the brand. Postgres only; SQLite has
      neither the syntax nor a second instance to protect against.
- [x] **Retention server-side.** Events past 30 days that have already been notified,
      then products unseen for 180 days with no events left. The ordering is
      load-bearing in both directions: `events.product_id` is `ON DELETE CASCADE`, so
      pruning a product first would silently delete feed history — and deleting a product
      the source still lists makes the next poll announce it as a new drop, i.e.
      retention manufacturing a fake release. The phone already keeps far less (400 per
      brand, never dropping saved or unread) and pages the rest from here.

### Phase 3 — alerts and the round app

- [x] **A visual identity.** The app was stock SwiftUI forms; it now has a design system
      (`streetw/Views/DesignSystem.swift`): an achromatic gallery palette where photographs
      carry all the colour, and exactly one accent — vermilion — rationed to things that are
      time-critical. Three type roles rather than SF at four sizes: **New York** for titles,
      tracked SF caps for brand wordmarks, **SF Mono** for sizes, prices and times.
      The signature element is the **size run**, a product's sizes printed as type with
      sold-out struck through and yours ruled in vermilion — the size profile finally
      *visible* rather than implied. Long runs narrow to what's buyable, because a sneaker
      runs 5–13 in half sizes and an overflowing row truncates every token to an ellipsis.
      The feed is laid out lead-plus-briefs per brand, which is load-bearing rather than
      decorative: a brand can publish 250 items in one poll and a flat list of equal rows is
      unreadable.
- [x] **Brand marks.** Brands show their own logo, taken from the icon their site
      publishes for home screens (`BrandMark` in StreetwCore) — the brand's own file,
      served for exactly that purpose, so no scraping and no third-party logo API.
      Ranked by intent, then decodability, then size: raster beats vector because
      `UIImage` cannot decode SVG and one would silently become a monogram. Shopify CDN
      URLs get their size parameters rewritten from 32px to 180px, since nearly every
      storefront declares only a favicon. Falls back to initials, which is not a rare
      path — BBC declares only an SVG. `/favicon.ico` is a guess rather than a floor:
      Shopify 404s it.
- [x] Push: new drop · restocked in your size · storefront locked (drop imminent).
      *Since shipped:* a new drop, a collection and a lock push (`UpdateKind.isSudden`); a
      restock reaches push through a stock watch.
- [x] **Shock-drop alerts** — mostly built already: `PageWatchSource` plus the `dropLock` signal
      (401/403 or redirect to `/password`) is exactly the unannounced-release detector. It only
      needs push behind it. *Since shipped,* as the lock push above.
- [x] **Drop calendar.** Built without inventing data, which is the whole difficulty:
      nobody publishes a machine-readable release calendar, and the ones that exist are
      hand-edited by people. So it shows three clearly-labelled kinds of claim — a
      **locked** storefront (observed, and the strongest signal there is), a **scheduled**
      product whose publication date is in the future (the brand's own date), and an
      **expected** drop derived from the brand's own history. `DropCadence` reads the
      modal weekday and hour out of hundreds of publication timestamps, counting a *day*
      rather than a product so one 60-item collection can't decide the answer, and stays
      silent below 6 drops or 40% confidence. Reported as a pattern with its sample size,
      never as a promise. No `releaseDate` field was needed — `publishedAt` in the future
      already is one.
- [x] **Share Extension.** A new target plus an App Group inbox: the extension writes a
      link and returns immediately, the app enriches it from the page's own Open Graph
      and files it into the collection. Links from anywhere now become cards, which is
      what makes this an archive rather than a feed reader. Two traps worth remembering,
      both in CLAUDE.md: reading and deleting the inbox must be separate steps or a
      hanging fetch loses the save, and adding the App Group silently relocated the
      SwiftData store into the shared container — which looks exactly like the database
      being wiped.
- [x] **Onboarding starter pack.** Ten brands with a line each on *why* they're worth
      watching, running the same discovery the add-brand flow runs. Replaces an empty
      state that told you to paste a website while assuming you knew which website.
- [x] **Search across saves.** Across title, brand, type, tags, note and host — so a
      thing shared from kith.com is findable as "kith" before that brand is even
      followed. Filtered in memory rather than as a `#Predicate`, because the fields
      worth searching live across a relationship and in arrays.
- [ ] Widget + Live Activity for countdowns — *moved to Later.*
- [x] **Announced release times, where a page actually states one.** The obvious approach
      — hunt for a countdown — does not work: on the storefronts that use them the target
      lives in JavaScript, and the ISO timestamps that *are* in the markup are blog dates,
      asset versions and analytics beacons. Verified against a live locked Corteiz page,
      which contains the word "countdown" and four unrelated timestamps and no labelled
      start time. So `DropDateParser` reads only *labelled* dates — `<time datetime>`,
      schema.org `availabilityStarts`/`releaseDate`/`startDate`, and release-named `<meta>`
      tags — and returns nil otherwise. A drop calendar that lies about times is worse
      than one that stays quiet. A locked storefront that also names a time is now the
      strongest entry the calendar can hold: observed *and* exact.

### Phase 4 — the collection, properly ✅

- [x] **Split `UpdateCard`.** Done early, because the restyle forced the issue: `FeedLead`
      and `FeedTile` carry time, price, stock and the accent, while `CollectionTile`
      carries none of it. The hype/calm distinction is now a data boundary rather than a
      visual one, exactly as this list predicted one shared card would fail to be.
- [x] **Masonry, image-first grid.** Saved is a staggered two-column wall — hand-split
      into columns rather than a `LazyVGrid`, which forces every row to its tallest cell
      and flattens a wall back into a table. Still driven by a deterministic hash of the
      item id rather than by real image dimensions; deterministic on purpose, because a
      collection that reflows while you look at it is the opposite of calm.
- [x] **Boards, private by default.** `isPrivate` is on the model from the first row
      rather than implied by there being no sharing yet — so privacy is a property of the
      data, not something retrofitted the day sharing arrives and defaults the wrong way.
      Deliberately orthogonal to Inspiration/Wardrobe: that answers "do I own this", a
      board answers "what does this belong with", and an item can be both. Boards are
      therefore a *filter*, never a folder, which is also why deleting one nullifies
      rather than cascades — losing an archive because a grouping was tidied away is the
      worst thing this app could do.
- [x] **Quick-save gesture.** Swipe right to keep, left to file on the first board, with
      the destination named under your thumb as you drag. The point is that it replaces a
      *decision*, not a tap: a sheet asking "which board?" turns an impulse into admin.
      Hand-rolled rather than `.swipeActions`, which belong to `List` — the feed is a
      `ScrollView` of photographs, and moving the card under the finger is what makes
      direction feel like a choice.
- [x] **Notes and size annotations.** A catalogue knows what a garment costs; it cannot
      know you bought the L because the M ran short, or that you're waiting on a 9.5.
      Size is free text on purpose — brands run their own scales and "44" must be as
      storable as "M". The size shows on the wall; the note stays on the item's own page,
      because the collection is meant to be looked at rather than read.
- [x] **Auto-tagging via Vision.** Dominant colour off the photograph plus categories from
      Vision's on-device classifier, preferred over the text vocabulary, which stays as
      the fallback for anything not yet analysed. The text approach was guessing: a brand
      calling a shoe "Triple White" is naming a colourway, "Nocturne" describes nothing,
      and a shared-in link may have a two-word title and no tags. Verified against real
      Kith and BBC shots — a Velour Soccer Jersey reads **Burgundy** from its picture,
      which no title-parsing would ever have found.
      Two things learned the hard way and written into the code: the seamless sweep is
      70–85% of a product shot, so the vote had to be **centre-cropped** or every item
      came back "White" including a black Air Jordan; and tightening the backdrop
      threshold to exclude the grey sweep also ate the near-white pixels of genuinely
      white garments, leaving only their shadows to vote "Grey" — measured, reverted, and
      documented at the threshold.
      Only *saved* items are analysed; running this over a 250-item catalogue sweep would
      burn battery describing things nobody kept.

### Known gaps not yet scheduled

#### Closed

- [x] **Real image dimensions for the collection wall.** `ImageTagger` already decodes
      each saved image, so the aspect comes free; the wall lays tiles out at the shape of
      the actual photograph and falls back to the deterministic guess until measured.
      Clamped both ways, because one panoramic shot would otherwise blow a column out.
- [x] **Price drops** (was "`updated_at` for silent product edits"). Most silent edits are
      noise; a markdown is the exception, and it is invisible in `published_at` because
      that doesn't change. `FetchedItem` now carries a numeric `priceAmount` — display
      text like "€180" cannot be compared — and `PriceChange` requires a 5% fall before it
      counts, which clears the exchange-rate drift multi-currency storefronts recompute
      several times a day. Only *drops* exist as a case: a brand raising a price is not
      something anyone wants pushed to their phone. A restock outranks a markdown, so one
      product never writes two events for one poll. Both client and server detect it.
- [x] **Shopify `/collections.json`.** A 60-piece release arrives through the product
      endpoint as 60 unrelated rows; through this one it is a single named event, which is
      what brands actually announce. Built as its own source kind rather than a second
      request inside `ShopifySource`, because one source = one URL = its own ETag, failure
      count and place in the poll queue. Structural collections ("all", "frontpage") and
      empty ones are skipped — the first are navigation, the second are pages a
      merchandiser made but hasn't filled. Verified against the live Kith endpoint, which
      caught a real bug: this endpoint calls the field `description` where
      `/products.json` calls it `body_html`, and decoding the wrong key loses every
      summary silently.
- [x] **Sitemap-based discovery for non-Shopify brands.** Previously those fell straight
      to a page watch, which can only say "something on this page changed" and fires as
      loudly for a swapped banner as for a release. A sitemap is a brand-maintained list
      of every product URL with a `<lastmod>` on each, so `since` filtering works exactly
      as it does elsewhere and no extra state is needed — dedupe is already handled
      upstream by `externalID`. Follows a sitemap index to its product children only,
      capped, and refuses entries with no `lastmod` rather than assuming "now", which
      would resurface the whole catalogue every poll. It cannot supply a price or a
      photograph; titles come from the slug.

#### Still open at 1.0

- Enriching sitemap-discovered products through `PageMetadataParser`, so those cards get a
  title and photograph instead of a slug. One fetch per new product, so it belongs behind
  the politeness budget rather than inside the adapter. *Now Phase 0, reading JSON-LD,
  which `PageMetadataParser` does not.*
- Vision's image classifier cannot initialise in the Simulator. *Still true; see Known gaps.*
- Silhouette (oversized / boxy / cropped) is still read from text only. Vision's taxonomy
  doesn't carry fit, so this would need aspect-ratio heuristics or a trained model.
  *Since closed: `Silhouette` measures it from the cutout's outline — see
  `docs/collection.md`.*

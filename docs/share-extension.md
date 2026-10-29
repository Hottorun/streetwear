# The share extension

Part of the streetw guidance set; see `CLAUDE.md` for the index and the build rules.

## The share extension

- **`Shared/` is compiled into both targets.** `SharedInbox` is the contract between
  them, so it is listed in each target's `fileSystemSynchronizedGroups` rather than
  duplicated. `ShareExtension/` belongs to the extension alone.
- **The extension does no networking and touches no SwiftData.** It writes one JSON file into
  the App Group container and every choice it offers is an *intent* in that file; the app does
  all fetching, filing, watching and following on the next foreground (`SharedSaveImporter`,
  `ShareFollows`). Extensions run under a hard memory limit, and a sheet that spins is one people
  stop using. It links `StreetwCore` — Foundation only — so it parses a page with the same
  `ProductPage` and reads sizes with the same `SizeProfile.claims` the app uses: what the sheet
  offers to watch is what the app will store.
- **The save is written the moment the sheet opens, and the sheet then stays until Done.** Saving
  is never a question (the `SaveConfirmation` rule): the inbox file exists before anything is
  drawn, so a sheet that is killed loses nothing. The sheet then *amends* it — boards, a watch,
  or on a shop's page following the shop instead — rewriting the same file for each choice, and
  Done sets `isComplete`. The app does not take a file whose sheet is still open
  (`SharedInbox.isSettled`), and takes it anyway after `openSheetGrace` (15 min, measured from
  `sharedAt` inside the file — the privacy manifest declares no file-timestamp reads) so a sheet
  put away without Done cannot hold a save forever. `isModalInPresentation` makes Done the only
  way out. Rewriting one file is safe where a shared array was not: the extension is its only
  writer and every write is atomic.
- **It reads the page Safari already loaded** (`NSExtensionJavaScriptPreprocessingFile`,
  `ShareExtension/ReadPage.js`). This was once left out as buying nothing, because the app
  fetched the page itself. The app's fetch is not the page the person saw: a shop that turns
  away the app's reader, or a network that hands the phone's own request a consent wall or a
  bot challenge, leaves a save with no photograph forever — the owner's Intimissimi saves — while
  their browser had the page, its JSON-LD and its photographs on screen. And Safari shares the
  *canonical* URL, which drops Intimissimi's `dwvar_…` colour parameter, so the app's fetch
  photographed the default colourway, not the one being looked at (reproduced in the simulator:
  the baseline saved the green shirt from a brown one's page). The script returns the title, the
  canonical URL, `og:*`/`product:*`/`twitter:*`/`description`, every `application/ld+json` block
  as **raw text** (64 KB a block, 256 KB in all, twelve at most — parsing belongs to
  `ProductPage`, not to JavaScript), and up to ten of the largest pictures actually drawn
  (≥300 px a side, https). Nothing is circumvented: it is the person's own browser, on a page
  it already loaded. Shared from an app that hands over an address alone, there is no page and
  everything works as before.
- **The inbox contract is versioned and lenient** (`SharedSave.version`, 2). Everything after
  `url` and `sharedAt` is optional and decoded with `try?` one field at a time, because
  `pending()` deletes a file that will not decode — and that file is somebody's save. A role a
  later extension invents costs that field, not the share. Fields: `page` (`SharedPage`),
  `isComplete`, `role` (`PageRole`), `boardIDs`, `newBoards`, `follow`, `notify`
  (`SharedNotify`: page-printed size labels, a colour, `askSize`).
- **What the sheet knows about the store, the app writes** (`SharedContext`,
  `ShareContextWriter`): the boards (id and name), the profile's `SizeProfile`, the registrable
  domains of followed brands and whether saved-item markdowns are said — one file per store under
  `share-context/<home>.json` (`phone.json` for `default.store`), so one person's boards never
  appear in another's sheet; `discard(for:)` removes it with the account. **Written when the app
  leaves the foreground, at a profile switch and after a drain** — not from each of the four
  screens that edit boards. The app is iPhone-only and the sheet is only reachable from another
  app, so leaving the foreground always comes first; and one call site cannot be forgotten by a
  fifth screen. Compared decoded before writing, because sizes are sets and encode in no fixed
  order. Before this build has run once, the sheet offers no boards and pre-selects nothing,
  and still saves.
- **Boards in the sheet are chips; "New board…" names one.** The app files the save on them on
  import (`SavedItem.boards`, many-to-many, `.nullify`). A board deleted since the sheet was drawn
  is ignored. A typed name matching an existing board, case-insensitively, is that board — two
  sheets that both typed "Tokyo" before the app ran must not make two — and otherwise the board
  is made by `CollectionEdit.newBoard`, the one way every screen makes one.
- **"Notify me" pins sizes, never the product** (CLAUDE.md, *Stock watches*). The sheet offers
  the sizes and colours the page's JSON-LD names — only a variant that names a `size` is a size;
  Intimissimi's variants repeat the product's name and are no run — pre-selected by the
  profile's `claims` on the garment's own `SizeContext`, the same reading the app makes. Each size
  chosen is one `StockWatch`, none is any size, made through the existing path (local
  `StockWatch`, then `RemoteSync.createWatch`, which mirrors it when the brand has a server id)
  and never twice for the same pins, so a re-drain is harmless. A page that lists no sizes says
  so and the app asks which size once it knows the run (`ShareQuestions` `.pickSize`, the watch
  editor). **One question, answered once:** a share that chose Notify me is never also asked the
  sold-out question. Markdowns: saves already get local price-drop alerts (`PriceAlerts`), with no
  per-save choice, and only from a followed shop's feed — so the sheet says "If it's marked down,
  Dropwall tells you that too" only for a followed shop with the switch on, and offers no new
  kind of alert.
- **A shop's page is followed, not saved** (`PageRole`). A homepage is a shop whatever it
  declares (Hollister's says `og:type` `product`); product data — JSON-LD `Product`, or Open
  Graph with a price — makes a product; a collection path is a shop; a page that was read and
  offers neither, nor `og:type` product, is a shop; an address alone is a save, as every share
  was. The sheet offers "Follow <site>" and says Dropwall will ask what to see when it next
  opens. **Chosen, the share saves nothing** (`SharedSave.savesPage`) — a homepage on the wall
  was a junk card — and not chosen, it is saved as a link exactly as before, because somebody
  sharing a lookbook may want it kept. A shop already followed says so instead.
- **The follow is made on the next foreground through the add-brand paths, in their order**
  (`ShareFollows`): the catalogue is searched first (`GET /v1/brands?q=`, matched on the
  registrable domain), else a site check is started and *watched* (`POST /v1/brands/checks`,
  `…/watch`), which the server finishes with the app closed; later foregrounds ask after the check
  until it settles. Standalone, the phone discovers the site as `AddBrandView` does. A refused
  check, or eight failed tries, lets it go. Each pending follow is kept in `ShareQuestions` until
  done. Then the follow-filter question is asked by `FollowFilterPrompt`, the one dialog every
  new follow gets: in server mode `RemoteSync.followExisting` and `watch(check:)` ask it
  themselves (or hand a running check to its `expect(check:)`), so the share's later re-poll of a
  settled check passes `asks: false` — asking again there would put the dialog up a second time
  after it had been answered. Standalone nothing else asks, so `ShareFollows` calls
  `followPrompt.ask(brandID:)` with the new brand's local id.
- **Every question a share raises is kept until it has been seen** (`ShareQuestions`,
  `ShareQuestionHost`). "I share, and a while later the dialog to get notified is gone": it was
  a sheet bound to an in-memory `PushRoute.watchOffer`, and anything that stopped it appearing —
  another sheet already up (SwiftUI then quietly presents nothing), the app suspended or killed
  before anyone looked, a profile switch rebuilding the root — lost it for good, because the
  inbox file was already deleted. Questions are now a queue in the profile's scoped
  `UserDefaults` (`shareQuestions`, `shareFollows`), written **before** the inbox file is removed,
  deduplicated by row so a re-drain cannot ask twice, and a question leaves only when its sheet
  appeared and then went away — answered, cancelled or swiped down. One that never appeared is
  offered again on the next foreground. A row un-saved meanwhile drops its question. The in-stock
  toast for a lone quiet share stays a toast: its two questions were already offered in the sheet.
- **Only one drain runs at a time.** A cold launch starts two (`ContentView`'s `.task` and the
  scene-phase drain) and both read the same file before either removed it, so every share was
  fetched twice and filed once.
- **The inbox is one file per save, and reading is separate from deleting.** Two
  processes are involved, so a read-modify-write on a shared array loses saves. Nothing
  is removed until the item is committed to the store — otherwise a fetch that hangs, or
  a kill mid-import, throws the save away.
- **Adding the App Group silently moved the SwiftData store.** A default
  `ModelConfiguration` puts the store in the *shared group container* once the app has an
  App Group entitlement, so the app opens an empty database and every brand and save
  appears wiped while the real data sits in the old location. `ProfileSession.container(for:)`
  now pins the store URL explicitly to `URL.applicationSupportDirectory`. Don't remove that.
- **A share belongs to the store that was current when it was shared** (`SharedSave.profileID`,
  `SharedInbox.currentProfile`). The app writes the current store's `ProfileScope.home` into a
  file in the group container on every switch — a file, because the privacy manifest says no
  `UserDefaults(suiteName:)` exists — and the extension stamps each share with it. For a profile
  that is its server user id; for the holder of an Apple ID that has a store of its own, the
  account's id; nil for `default.store`. The drain files only the current store's shares and
  leaves the rest in the inbox for when their store is current — **including a store of an
  Apple ID that is not signed in, so a share never lands in a hidden account's wall or in the
  wrong account's**. A share for a store this phone no longer has goes to the current holder
  rather than waiting forever, and removing another Apple ID's data discards its waiting shares
  with it. A share from an older extension has no id and is `default.store`'s. See
  `docs/profiles.md`.
- The App Group id must be identical in `streetw.entitlements` and
  `ShareExtension.entitlements`. A mismatch fails silently — the container URL is nil and
  every share vanishes without an error.
- **A shared link is enriched from the catalogue when it can be, and Open Graph only when it
  can't.** `ShopifySource.product(at:)` reads `/products/<handle>.js`, which gives the size run,
  the colourways and which of them are gone — Open Graph gives a title, a picture and a price,
  which is a bookmark. It uses `.js` rather than the `.json` beside it for one reason: **`.json`
  omits `available`**, and stock is the whole question. The cost is prices in minor units. A
  catalogue hit is also keyed `shopify:<id>`, so sharing something from a followed brand lands on
  the row that already exists rather than minting a second card for it.
- **The drain that matters is the one on `scenePhase == .active`.** `ContentView`'s `.task` fires
  once per appearance, so it never sees a share that arrives while the app is already alive —
  which is the whole "share from Safari, switch back" flow. The scene-phase drain in `streetwApp`
  is what actually runs, and it once passed no `PushRoute`: the sold-out offer returned at its
  first `guard`, the save was committed, the inbox file was removed, and the prompt had nothing
  left to be asked about. Questions no longer go through a route at all — both drains hand them
  to the app-level `ShareQuestions`, which is the store they are kept in.
- **Not every Shopify storefront serves `/products/<handle>.js`.** Palace 404s it on the apex,
  `www.` and `usa.` alike, while answering `/products.json` fine — so `ShopifySource.product(at:)`
  returned nil for every Palace share and the importer fell through to Open Graph: no size run, no
  colourways, no stock, and therefore never an offer to watch a sold-out item. The page's own
  markup is not a substitute; Palace advertises schema.org `inStock` on products whose every
  variant reads `available: false`. The fallback searches the **catalogue listing** rather than
  `/products/<handle>.json`, which is served where `.js` is not but omits `available` — the one
  field the whole feature turns on. Bounded by `maxListedPages`, because somebody is waiting.
  It also swaps to `www.` to find the catalogue, and **the currency then comes from the host that
  answered, not the host that was shared**: Palace's apex is USD and its `www.` is GBP, so reading
  one and pricing against the other prints a British price with a dollar sign on it.
- **An event id is not a product id, and the share importer needs the second one.** A feed row is
  keyed `event:<uuid>` because one garment produces several events over its life — a drop, a
  markdown, a restock — and that is right for a feed and useless for asking "are these the same
  thing". `SharedSaveImporter` keys a catalogue hit `shopify:<id>`, the way the *local* poller
  keys it, and looked for an existing row under that key alone: which a server-backed row never
  has. So sharing something the app was already showing you minted a second card for it, in the
  only mode the app ships in — the dedupe worked standalone and nowhere else. `FeedItem` and
  `BrandUpdate` now carry `productExternalID` beside the event key, `backfill` fills it on rows
  written before it existed, and `existingRow` matches on either. A product match can be ambiguous
  (several events, one garment): a row that is already **saved** wins, since that is the one
  carrying somebody's note and board; otherwise the most recent.
- **A share that landed badly must get another chance.** Enrichment runs once, at import, and the
  inbox file is deleted immediately after — so a link that found no catalogue record kept a title
  and one Open Graph photograph *permanently*: no price, no size run, no colourways, no stock and
  therefore no watch. Every reason the first attempt fails is temporary or fixable — a regional
  subdomain that publishes no catalogue at all (`eu.palaceskateboards.com` answers nothing),
  a storefront that was slow that minute, a product further back than `maxListedPages` pages while
  somebody waits, or an older build. `SharedSaveImporter.repair` is the `cutoutVersion` pattern
  applied to that: `BrandUpdate.enrichmentVersion` decodes 0 on an older row and earns one more
  look, and is stamped **even when the attempt found nothing**, so a genuinely un-catalogued link
  is not re-fetched every launch forever. Bump the version when enrichment learns something — it
  is 3 since the page's JSON-LD is read as well as its Open Graph (with `ProductPage`, from
  Safari's page or the phone's own fetch of it, one request for both). A Shopify product read
  from its page rather than the catalogue is also a candidate once, for the `shopify:` identity
  that lands it on the row a followed brand's feed already holds.
- **A share with no photograph is retried, spaced and bounded — the `.gone`/`.unavailable` rule
  from `docs/collection.md`.** The version stamp gives one look per bump, and one look is exactly
  what a slow page, a minute offline or a turned-away request cost a save's picture, for good.
  `BrandUpdate.photoRetryAt` (non-optional, `.distantFuture` = not due, so `repair` narrows on it
  in SQL) and `photoAttempts`: a fetch that did not answer — offline, timeout, 429, 5xx — is
  retried 5 minutes later, then after an hour, 6 hours, a day and 3 days, then let go; a page
  that answered with no picture, or a 4xx, is let go at once, because asking again gets the same
  answer. At most `repairBatch` (4) rows a pass.
- **The fetch caps return at the deadline.** They were task groups racing a sleep, and a task
  group cancels its children and then *waits for them*: a request that does not hear
  cancellation held the drain until its own timeout, so a Kith share took 57 s to file against a
  12 s cap while the phone's own sync crowded the host. The work now runs unstructured and is left
  to finish on its own (`SharedSaveImporter.answer`), the conclusion the server's `withTimeout`
  reached for the sidecar.
- **A brand is not one hostname.** Palace answers on the apex, `www.`, `usa.` and `eu.`; the Brands
  tab holds whichever one it was added with. `matchingBrand` compared exact hosts with `www.`
  stripped, so anything shared or discovered from the other three was attributed to nobody — which
  on screen is a collection tile with no wordmark, a detail page titled "Saved", and an item
  contributing nothing to the brand facet of the style profile. Five of eleven saves in the test
  store were in that state, all Palace. `BrandDiscovery.registrableDomain` compares the last two
  labels (three under a `co.uk`-shaped suffix); `attachBrands` heals rows that already landed, and
  needs no version stamp because it costs no network and is idempotent. It is deliberately a
  heuristic and not the Public Suffix List — the worst outcome of an unlisted suffix is a save that
  stays unattributed, which is where it already was.
- **A save has a brand name even when there is no brand.** `Brand` is only attached when the link
  matches something followed, so everything shared from a label nobody has added — which is most of
  what sharing is *for* — was anonymous: no wordmark on the wall, "Saved" for a page title, nothing
  to tap. The host is not the answer either, since `bbcicecream.com` is Billionaire Boys Club. So
  `SharedSaveImporter.identifySites` runs the same `SiteIdentityProbe` a followed brand's name comes
  from — one homepage fetch **per host**, not per row, grouped before anything is requested — and
  stores `siteName` and `siteLogoURLString`. `BrandUpdate.brandLabel` is the one accessor: followed
  brand, then declared site name, then the tidied domain. Every surface that used to print
  `brand?.name` now prints that.
- **The brand line on a saved item is a way in, with three honest destinations.** Followed pushes
  the brand page; known-but-unfollowed opens `BrandPreviewSheet`, which exists precisely to answer
  "should I follow this"; unknown opens `AddBrandView(prefill:)`. The catalog is searched before the
  add flow is offered, the same rule `AddBrandView` itself follows.
- **Enrichment takes the catalogue's whole set of photographs over the single Open Graph frame.** A
  share arrives with the one image published for link previews; keeping it because the field was
  technically non-empty left a gallery reading "1/1" about a garment the app had eight pictures of.
  Only ever *more*, so a storefront that publishes one is never talked down to zero — and the images
  it gains are what put the row back in front of `ImageTagger`.
- **The sold-out prompt is asked by the app, not the extension — because it cannot be asked
  earlier.** The extension does no networking, and the page's own claim of stock is not trusted
  (Palace advertises `inStock` on products every variant of which is gone), so at share time
  nobody knows whether the thing is in stock. `SharedSaveImporter` queues the question
  (`ShareQuestions` `.soldOut`) on the next foreground, which in the usual
  share-from-Safari-and-switch-back flow is seconds later, and it is kept until seen. It asks
  **only** on an explicit `isAvailable == false`: a page that declared nothing about stock must
  not be guessed at, or the reward for saving something you could have bought is an unprompted
  sheet. And never when the sheet already chose Notify me.

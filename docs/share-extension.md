# The share extension

Part of the streetw guidance set; see `CLAUDE.md` for the index and the build rules.

## The share extension

- **`Shared/` is compiled into both targets.** `SharedInbox` is the contract between
  them, so it is listed in each target's `fileSystemSynchronizedGroups` rather than
  duplicated. `ShareExtension/` belongs to the extension alone.
- **The extension does no networking and touches no SwiftData.** It extracts the URL,
  writes one JSON file into the App Group container, and returns. Extensions run under a
  hard memory limit and are expected back immediately; the app enriches the link with its
  Open Graph title, price and image on the next foreground (`SharedSaveImporter`).
- **The inbox is one file per save, and reading is separate from deleting.** Two
  processes are involved, so a read-modify-write on a shared array loses saves. Nothing
  is removed until the item is committed to the store — otherwise a fetch that hangs, or
  a kill mid-import, throws the save away.
- **Adding the App Group silently moved the SwiftData store.** A default
  `ModelConfiguration` puts the store in the *shared group container* once the app has an
  App Group entitlement, so the app opens an empty database and every brand and save
  appears wiped while the real data sits in the old location. `streetwApp` now pins the
  store URL explicitly to `URL.applicationSupportDirectory`. Don't remove that.
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
- **The drain that matters is the one on `scenePhase == .active`, and it must carry the
  `PushRoute`.** `ContentView`'s `.task` fires once per appearance, so it never sees a share that
  arrives while the app is already alive — which is the whole "share from Safari, switch back"
  flow. The scene-phase drain in `streetwApp` is what actually runs, and it was passing no route:
  `offerWatch` returned at its first `guard`, the save was committed, the inbox file was removed,
  and the sold-out prompt had nothing left to be asked about. It was reachable only on a cold
  launch, and only if the `.task` won the race.
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
  is not re-fetched every launch forever. Bump the version when enrichment learns something.
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
  earlier.** The extension does no networking, so at share time nobody knows whether the thing is
  in stock. `SharedSaveImporter` offers the watch on the next foreground, which in the usual
  share-from-Safari-and-switch-back flow is seconds later. It offers **only** on an explicit
  `isAvailable == false`: a page that declared nothing about stock must not be guessed at, or the
  reward for saving something you could have bought is an unprompted sheet.

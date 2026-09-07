# Reading a storefront that has closed its catalogue

Part of the streetw guidance set; see `CLAUDE.md` for the index and the build rules.

## Reading a storefront that has closed its catalogue

Supreme is a Shopify store (`us.supreme.com` → `eu-production.myshopify.com`) with every
machine-readable surface switched off. Probed directly, on the day this was written:

```
  /products.json                403   /collections/all.atom       403
  /collections.json             403   /sitemap.xml                404
  /products/<handle>.js|.json   403   /meta.json                  200  ← the only one
  /collections/all              200 — HTML, client-rendered, no product links in it
```

So every adapter above declines and discovery lands on `PageWatchSource`, which hashes the
visible text of a page whose products are drawn by JavaScript. **The hash never moves.** The
brand row says "WATCHING", the source records no error, and the app delivers nothing, ever —
the exact "every layer reports healthy and the feature does not exist" failure this file
keeps a list of.

The same robots.txt that fronts those 403s says *"Agents should use UCP/MCP for catalog"* and
gives the discovery URL. The door was moved, not closed, and `UCPSource` walks through it.

- **It is read-only by construction.** The endpoint also exposes `create_cart`,
  `create_checkout` and `complete_checkout`. None appear in `UCPSource`, and `UCPAgent`
  declares only the two catalogue capabilities — a business reads that profile to decide
  what to send and what we can handle, so claiming `checkout` would be claiming to be a
  shop. Supreme's own robots.txt draws the same line: "Checkouts are for humans."
- **UCP is a negotiation, and the agent profile is the price of entry.** A business fetches
  `UCPAgent.profileURL` *from its own network* before answering; without it every call gets
  `UCP discovery failed`. So the server serves it at `/.well-known/ucp` and both modes quote
  that URL — a phone cannot host one. **If UCP sources start failing everywhere at once,
  curl that URL first.** The failure ladder, all three seen live: no profile sent → "Missing
  ucp version"; profile sent but the route not deployed → "Unable to fetch agent profile:
  Http error"; deployed → it works.
- **This is not a Supreme workaround — it is most of Shopify.** Probed live,
  `/.well-known/ucp` with `catalog.search` is published by Kith, Palace, BBC ICECREAM,
  Stüssy, Aimé Leon Dore, Allbirds and Gymshark; of the eight tried, only one had none. Those
  brands all still serve `/products.json`, so `ShopifySource` keeps them — but any of them
  could switch it off tomorrow, as Supreme did, and the fallback is now in place.
- **Verified against real catalogues, not only fixtures.** `admin/ucp-test` against Kith,
  Palace and BBC returns 250 products each (five pages of fifty, so paging works), with
  prices converted correctly — `US$180`, not `US$18,000` — and real size runs including
  Palace's hat sizes ("7 1/8"). Supreme itself answers `0 products`, which is **correct**:
  its own page markup reads `{"allProductsCount":0,"products":[]}` between drops.
- **`available: false` means "do not narrow", confirmed by measurement.** Against Kith it
  returns 109/461 variants in stock where `true` returns 127/445 — so `false` genuinely
  includes sold-out stock rather than selecting only it. Worth having checked: the opposite
  reading would have silently hidden everything buyable.
- **The status is not the message.** A refusal arrives as **422 with the reason in the
  JSON-RPC body**, and that reason names the fix. Reading the status first reported "Server
  returned 422" and threw the sentence away, so the body is decoded first and the status
  only speaks when nothing in it can. `SourceError.ucp` is its own case because these
  failures are usually *ours*.
- **`search_catalog` is a search, not an enumeration.** No sort-by-newest, and the UCP
  product model has **no publication date at all** — so this pages a bounded window and lets
  dedupe on `externalID` decide what is new, `since` cannot narrow the request, and
  `publishedAt` is "first seen". `Reshelving` can therefore say nothing here, which is its
  documented safe default.
- **`available: false` is sent deliberately.** The endpoint narrows to sale-ready items by
  default, which would hide exactly the sold-out drop somebody wants telling about — and the
  restock could never fire, because the product would never have been stored.
- **Prices are minor units.** `{"amount": 19800, "currency": "GBP"}` is £198.00. Zero-decimal
  currencies (JPY, KRW) are already whole and must not be divided.
- **Discovery re-reads `/.well-known/ucp` every poll** rather than pinning the endpoint seen
  the day a brand was added, which would mean silently polling a dead URL the day it moves.
- **Ranked below the sitemap, above a page watch.** On data alone it should outrank nearly
  everything — prices, variants, live stock. What holds it down is that it is the only
  source whose success depends on *us* being reachable, and demoting a working sitemap for
  something that can fail on our side is the wrong trade. Above a page watch the argument is
  unanswerable.
- **`POST /admin/ucp-test?url=` reports per stage**, for the same reason `push-test` does:
  "0 products" is equally true when a store has no UCP, when our profile 404s, and when the
  season is simply over, and those have three different fixes.

# Recommendations

Part of the streetw guidance set; see `CLAUDE.md` for the index and the build rules.

## Recommendations

- **`BrandVector`'s unit of work is the whole catalog.** Two components — inverse document frequency
  and price percentile — are defined relative to every *other* brand, so vectors cannot be built one
  brand at a time. `BrandSimilarity` caches them with a TTL rather than persisting: they are
  entirely derived, and a stale vector is worse than a missing one.
- **Price is compared as a rank, never as an amount.** Brands store their own currency and there
  are no exchange rates anywhere in this system; ranking sidesteps conversion entirely.
- **Vocabulary is TF-IDF over tags and product types, never titles.** Product names are unique to
  one brand, so IDF would rate "Nocturne" maximally distinctive — the opposite of useful. IDF is
  also what flattens Kith's 130 internal merchandising codes.
- **Scored as a weighted mean of per-component similarities**, not one cosine over a concatenated
  vector: vocabulary has hundreds of dimensions and gender has five, and a single cosine would let
  the former drown the latter on dimension count alone.
- **Taste beats popularity but never replaces it.** This measures catalog *composition*, which is a
  proxy for aesthetic and not the thing itself, so a brand nobody follows must not outrank a
  well-liked one on vibes alone.
- **The taste vector is computed on the phone.** Saves are the sharpest signal and the most
  personal; the server ships candidates *with their vectors* and the comparison happens locally, so
  nothing about a save leaves the device. Don't "improve" this by uploading saves.
- **A headcount has to earn its weight** (`Popularity.confidence`). Normalising by the maximum makes
  a number between 0 and 1 at any scale, which quietly turned a *two-person* lead into a full unit
  of evidence — a bigger gap than the entire spread of affinity, since every streetwear catalogue
  resembles every other and similarities bunch in a narrow band. So the ranking was "whatever two
  people follow" wearing the clothes of a taste engine. Damped smoothly rather than by a threshold,
  or the list would reorder the day one person joined.
- **A dismissal is the only negative signal, and it is not just a hide.** `BrandDismissal` stores the
  refused brand's vector, and `Recommender.repulsion` demotes candidates that *resemble* it — one
  tap on a technical-outdoor label should quiet the other four. Measured against the **nearest**
  refusal, never the average: rejecting a loud graphic label says nothing about the quiet Japanese
  one further down. Weighted below taste, because people reject things for reasons that have nothing
  to do with the clothes. Local, like the taste vector, and for a stronger reason — what somebody
  turned down is more revealing than what they followed.
- **A recommendation's photographs are budgeted per brand, in SQL.** `/v1/brands/popular`
  fetched them with one date-sorted query and a global `LIMIT`, then enforced a per-brand cap
  while grouping the rows — which enforces nothing, because the cut already happened. A brand
  that publishes 250 items in one sweep owned the whole window: measured against production,
  **fourteen of thirty-five recommendations came back with no photographs at all**, and
  Represent came back with one delivery graphic, its garments all being older than the global
  cut so the "everything here reads as promotional" fallback had nothing else to pick. The
  tell is that a brand's picture count *changes when `limit` changes*, which a real per-brand
  budget cannot do. It is now one small query per candidate, which is what
  `AddProductBrandIndex` exists for — `products.brand_id` is a foreign key and Postgres does
  not index the referencing side by itself.
- **`PreviewImages.pick` decides the fallback on what has a photograph, not on what survived
  the vocabulary.** A brand whose garments are all imageless — ordinary for a sitemap source
  — otherwise counts as "filtering removed nothing", skips the fallback, and returns an empty
  list built from rows that did have pictures.
- **The block prints six and the list holds thirty.** Three cards is one screenful of a scroll
  you were already doing, and two of them are usually brands you have an opinion about — too
  small to be an offer. Thirty fetched, because "SEE ALL" led to a page of six otherwise.
- **A card says why, and the reason is the one the ranking used.** `sharedTraits` reads the terms
  contributing most to the dot product, so the line cannot drift from the score. It printed the
  follower count instead, which at this scale read "1 PERSON WATCHING" on every row — an argument
  *against* following, under every brand, on the block whose job is to make following attractive.
  `GarmentSlot.unknown` is excluded: it is the classifier declining to answer and is a large share
  of most catalogues, so it matches constantly and means nothing ("LIKE YOUR UNKNOWN").
- **A term fit to be scored is not automatically fit to be printed.** The vocabulary keeps every
  token a merchandiser wrote *on purpose* — IDF is what decides whether it means anything, and a
  code nobody else uses is genuinely distinctive. That is right for the arithmetic and wrong for
  the caption: the block was reading "LIKE YOUR ITP" under a brand it was trying to sell. `Trait`
  gates the sentence and nothing else — four letters, a vowel and a consonant, and a short list of
  ordinary words that describe the shop rather than the clothes ("sale", "mens"). A brand whose
  only shared terms are unreadable falls through to the category line that already exists.
- **The block builds its ranking once per render.** `recommender` rebuilds a taste vector over
  every save in the store, and it was being read by `visible` and then again by `reason(for:)` for
  each card — seven full builds per body, on a block that sits on three tabs.
- **Anything written in `StyleStatement` is blended in additively and modestly.** A save is a
  record of behaviour and a sentence is a claim; a stated word is worth about as much as a term
  appearing in a handful of saves. Only terms the candidate set already uses survive, exactly as
  the taste vector does for saves. Dislikes are deliberately *not* applied here — a brand is not
  demoted for stocking one thing somebody avoids, and `BrandDismissal` is where a negative signal
  about a brand belongs.

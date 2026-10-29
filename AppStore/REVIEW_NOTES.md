# App Review notes

Paste the block below into **App Store Connect → your app → the version → App Review
Information → Notes**. It is plain text; the field takes no formatting, so the headings are
there for a human reading it and nothing depends on them rendering.

If the build is rejected, the same text is the starting point for the reply in **Resolution
Center** — but answer the specific guideline they cite rather than re-sending this whole thing.

**Demo account:** leave the "Sign-in required" box unchecked. Signing in is optional (Sign in
with Apple, which needs no demo credentials), there is no paywall, and every screen is reachable
on a fresh install. The AI features need sign-in, because credits live on the account; a new
account gets the free monthly credits, so the reviewer's own Apple ID is enough to try them
without buying anything.

**Keep this file in step with the app.** It makes factual claims — which endpoints are read,
that the app has no checkout of its own, that Instagram is never fetched — and each one is enforced in
code today. If any of that changes, this text becomes a false statement to App Review, which is
a much worse problem than the change itself.

---

## The text to paste

Dropwall watches clothing brands and shops — menswear and womenswear, any kind of clothing —
for new releases, restocks, sales and price drops, and lets you keep the pieces you care about
in a private local archive.

Nothing requires an account, and the only thing sold is optional credits for the AI features
(see AI FEATURES AND CREDITS). On first launch you are offered a short list
of suggested brands — tapping two or three of them is enough to populate the feed, and the
Feed, Shop and Saved tabs, and the You page behind the person icon at the top right, are all
reachable immediately. If the feed looks empty, it is
because no brand has published anything in the last few minutes; the brand's own page shows
its full catalogue right away.

Shop's search box searches the catalogue our server holds of the shops the user follows (and,
when asked, of every shop it watches), and says which under the field. That plain search is not
a web search and no generative model is involved. The text of a search is used to answer it and
is not stored or logged.

AI FEATURES AND CREDITS

A few features are answered by Claude (Anthropic), each only when the user taps it, and each
labelled as AI with its price in credits beside the button:

- Shop › "Ask Dropwall": reads a description ("black suit for a wedding, no wool") into a search
  of the user's shops, with short follow-up replies in the same search at no extra charge.
  "Show me more" looks on the open web for product pages from other shops; each result opens the
  shop's own page in Safari, and the app never buys anything.
- The camera on Saved's "+" (Scan a garment) and in Shop's search field: reads one photograph of
  a garment, then offers to add it to the wardrobe with the user's own photograph, to check what
  it goes with (worked out on the phone), or to find it or something like it.
- The fit editor's "Ask" menu: judges an outfit from its photographs, or suggests what to add.
- Daily picks in Shop get a one-line reason written by the model, free.

Signed out, each AI button says that sign-in is needed and opens it. The model's answers are
never presented as a shop's own data: products always come from the shops' own catalogues,
found by our search.

Credits are consumable in-app purchases (three packs). They are held on the user's account on
our server, so they survive a reinstall and appear on every phone signed in to the account;
that is why there is no "Restore" for them, and why buying needs sign-in. Every signed-in
account gets a free monthly allowance. Deleting the account says that unused credits are lost.

SIGN IN WITH APPLE, PROFILES AND ACCOUNT DELETION

Sign in with Apple is offered on the You page and is optional. It keeps a user's follows, sizes
and alerts across a reinstall or a second phone, and it is required only to add profiles —
"For Anna" — for another person the user shops for, each with their own follows, sizes, saves
and alerts. No name and no email address is requested from Apple. Sign in with Apple is the only
sign-in method.

The account can be deleted in the app: You → Account → Delete account. That deletes the account,
every profile on it and every server-side record linked to it, and revokes the app's Sign in with
Apple token. A single profile can be deleted the same way from its own row.

LOCATION

You → Location is a country setting, defaulting to the phone's region. Where a brand runs a
separate shop for that country, the feed shows that shop's products and prices. It is a country
chosen in the app, not the device's location: the app does not use Location Services.

WHERE THE DATA COMES FROM

Every brand's information is read from endpoints that the storefront itself publishes for
automated clients:

- the storefront's public product and collection JSON, which Shopify serves by default
- RSS and Atom feeds
- sitemap.xml
- the Universal Commerce Protocol endpoint at /.well-known/ucp, which a storefront publishes
  specifically so that software can read its catalogue

Nothing is scraped from behind a login, and no private or undocumented API is used. Outbound
requests obey each site's robots.txt, are limited to one in flight per domain and are spaced
out, and identify the app honestly in the User-Agent rather than impersonating a browser.
Requests are also conditional, so an unchanged catalogue costs an empty response.

Instagram and other social networks are never fetched. The app stores a link to a brand's
profile and opens it in the system browser; that is all.

HOW BRAND NAMES, LOGOS AND PHOTOGRAPHS ARE USED

Brand names appear so that a user knows which shop is being watched, and the app never
suggests any affiliation with or endorsement by those brands.

A brand's mark is the icon that its own website publishes for adding the site to a home
screen, loaded from the brand's own server and served for exactly that purpose. Product
photographs are loaded directly from the brand's own content delivery network and shown
alongside the brand's name, the product's name and its price.

Every product links out to the brand's own store: to the product's page, or, on a Shopify
store when exactly one available size matches the sizes the reader saved, to that store's own
cart link for that size, which opens the brand's checkout in Safari or in the brand's app. The
app has no checkout of its own, takes no commission, sells nothing, and does not touch resale or
reseller data. It sends buyers to the brand.

The Universal Commerce Protocol integration is deliberately read-only. The protocol also
offers cart and checkout operations; the app implements none of them and its published agent
profile declares only the two catalogue capabilities, so a merchant can see before answering
that this software reads a catalogue and cannot transact.

NOTIFICATIONS AND BACKGROUND MODES

Push notifications tell a user that a followed brand has released something, that a product
has come back in the size they wear, or that a storefront has locked down ahead of a release.
Notification permission is requested in context and everything else in the app works if it is
declined.

The remote-notification and fetch background modes are used to keep the feed current between
launches. Polling is done by our own server rather than on the device, so background work on
the phone is limited to refreshing what the server has already collected.

PRIVACY

Without signing in there is no personal identifier of any kind. The server holds an anonymous
device row, the list of brands a user follows, the products they have asked to be alerted
about, their size and gender preferences — the last of these only so that a restock alert in a
size they do not wear is never sent — and the country they shop in. A user who signs in adds
Apple's per-app identifier for them, and the names they give any profiles; those are declared as
User ID and Name. A signed-in user's credit purchases and spends are held under the account and
declared as Purchase History.

Saved items, boards, outfits, notes, the written style statement and the taste profile used for
recommendations all stay on the device, for every profile. Recommendations are computed locally: the server
sends candidate brands and the comparison happens on the phone precisely so that what a user
saves never has to leave it.

When the user asks one of the AI features, what that answer needs goes from our server to
Anthropic: the text of an Ask Dropwall search, the one photograph of a scan, or the pieces of a
fit. Nothing identifying the user or the device is sent with it, and none of it is stored or
logged on our server. Those are declared as Photos, Search History and Other User Content, not
linked to the user.

When the user saves something from a shop our catalogue does not have yet, the app sends that
shop's web address — the domain only, never the product, the page or the fact that something was
saved — so the shop can be added to search. The server records nothing about which device sent
it, and adds the shop only if its products can be read. This is declared as Browsing History,
not linked to the user, for App Functionality.

The share sheet reads the page Safari has already loaded (a JavaScript preprocessing file) for
its title, photographs, price and the product's own structured data, so a saved item has its
picture even where the shop turns away other readers. That happens on the device; the
extension sends nothing anywhere, and what it read is filed by the app as part of the save.

Nothing is shared with data brokers, nothing is joined with data from other companies' apps
or websites, and no advertising or analytics SDK is present. The app does not use App
Tracking Transparency because it does not track.

The app does send anonymous usage counts to its own server: per day, how many times it was
opened, each tab shown, a brand search run, a save or a fit made, a brand followed, a
notification tapped. Only the numbers travel — no search text, product or brand — and the
server adds them to totals shared by every user. This is declared as Product Interaction,
for Analytics, and described in the privacy policy.

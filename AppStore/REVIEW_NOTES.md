# App Review notes

Paste the block below into **App Store Connect → your app → the version → App Review
Information → Notes**. It is plain text; the field takes no formatting, so the headings are
there for a human reading it and nothing depends on them rendering.

If the build is rejected, the same text is the starting point for the reply in **Resolution
Center** — but answer the specific guideline they cite rather than re-sending this whole thing.

**Demo account:** leave the "Sign-in required" box unchecked. There is no account, no login and
no paywall; every screen is reachable on a fresh install.

**Keep this file in step with the app.** It makes factual claims — which endpoints are read,
that checkout is never touched, that Instagram is never fetched — and each one is enforced in
code today. If any of that changes, this text becomes a false statement to App Review, which is
a much worse problem than the change itself.

---

## The text to paste

Dropwall watches streetwear brands for new releases, restocks and price drops, and lets you
keep the pieces you care about in a private local archive.

There is no account, no sign-in and no purchase. On first launch you are offered a short list
of suggested brands — tapping two or three of them is enough to populate the feed, and the
Style, Saved and Calendar tabs are all reachable immediately. If the feed looks empty, it is
because no brand has published anything in the last few minutes; the brand's own page shows
its full catalogue right away.

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

Every product links out to that product's page on the brand's own store. The app has no
checkout, takes no commission, sells nothing, and does not touch resale or reseller data. It
sends buyers to the brand.

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

There is no account and no personal identifier of any kind. The server holds an anonymous
device row, the list of brands a user follows, the products they have asked to be alerted
about, and their size and gender preferences — the last of these only so that a restock alert
in a size they do not wear is never sent.

Saved items, boards, outfits, notes, the written style statement and the taste profile used
for recommendations all stay on the device. Recommendations are computed locally: the server
sends candidate brands and the comparison happens on the phone precisely so that what a user
saves never has to leave it.

Nothing is shared with data brokers, nothing is joined with data from other companies' apps
or websites, and no advertising or analytics SDK is present. The app does not use App
Tracking Transparency because it does not track.

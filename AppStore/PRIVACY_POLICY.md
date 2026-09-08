# Privacy policy — source text

## On the question of hosting it

**You have to host it yourself.** Apple requires a privacy policy URL for every app, and it has
to be a public web page — reachable with no login, no paywall and no app install — that
describes *this* app specifically. A generic policy borrowed from somewhere else fails on the
second count: the policy is a statement you are making about your own data handling, and it has
to agree with the App Privacy answers you give in App Store Connect and with
`streetw/PrivacyInfo.xcprivacy` in this repo. A contradiction between the three is its own
review problem, and it is the kind reviewers do check.

Generators exist and are fine as a starting point, but they produce a template that you still
host and still have to correct — and for this app the interesting parts (a device row with no
account behind it, a recommender that deliberately computes on the phone so saves never leave
it) are exactly the parts a template will get wrong.

A subdomain of your own site is the right answer. Anything stable works:
`privacy.yourdomain.tld`, or a path like `yourdomain.tld/Dropwall/privacy`. Two things matter
more than where it lives — that the URL **does not change**, because it goes into App Store
Connect and gets crawled, and that it is served over HTTPS.

`privacy-policy.html` beside this file is the same text as a single self-contained page you can
upload as-is.

**Before you publish it**, replace the three bracketed placeholders below, and re-read the
"What the server receives" section against the app as it actually is on the day you ship.

---

# Dropwall — Privacy Policy

**Last updated: 8 September 2026**

Dropwall is made by KERN AG, Germany. Questions about this
policy go to hottorun@pm.me.

## The short version

Dropwall has no accounts. You never give us a name, an email address or a password, and there is
nothing to sign in to.

Almost everything the app knows about you stays on your phone. The one exception is the small
amount of information our server needs in order to tell you that something you are waiting for
has been released or has come back in stock.

We do not sell data, we show no advertising, we use no analytics or attribution services, and
we do not track you across other companies' apps or websites.

## What stays on your device and is never sent to us

- Everything you save, and the notes, sizes and photographs attached to it
- Your boards and the outfits you compose
- Anything you write in the style statement field
- The taste profile used to recommend brands, and any brand you have dismissed
- Any release date you enter yourself in the drop calendar, along with its title and note
- The analysis of saved photographs — colour, shape, category — which is performed entirely on
  the device using Apple's on-device frameworks, with no image ever uploaded

Brand recommendations are computed on your phone: our server sends a list of candidate brands
and the comparison against your taste happens locally, specifically so that what you save does
not have to leave the device.

Deleting the app deletes all of it. We hold no copy and cannot recover it.

## What our server receives

- **An anonymous device record.** When the app first runs it registers with our server and is
  issued a random identifier. It is not linked to you, your Apple Account, your email address
  or your name, because we hold none of those.
- **A push notification token**, if you allow notifications, so that Apple can deliver alerts to
  your device. Removed if Apple tells us the token is no longer valid.
- **Which brands you follow**, so we know which storefronts to watch on your behalf.
- **Which products you have asked to be alerted about**, including the size or colour you asked
  for.
- **Your size preferences and your gender filter.** These are held so that a restock alert in a
  size you do not wear is never sent to you. That targeting is the only reason we have them.
- **A brand and a time, when you enter a release date yourself and are following that brand**,
  so our server can check that storefront more often around that moment. Only the brand and the
  instant are sent — never the title or the note you wrote, and never any date for a brand you
  do not follow. Nobody else can read it, and no notification or public record is produced
  from it.
- **Ordinary server logs**, including IP addresses, kept briefly for security and debugging.

## Where product photographs come from

Product photographs and brand logos are loaded by your device directly from each brand's own
website or content delivery network, rather than being copied through our server. This is
normal for any app that displays images from the web, and it means those companies can see your
device's IP address and the fact that an image was requested — the same as if you had opened
the brand's website in a browser. They receive nothing from us about you.

## Who else is involved

- **Apple**, which delivers push notifications. Apple's own privacy policy applies to that
  delivery.
- **Our hosting provider**, which runs the server and its database on our behalf and does not
  use the data for anything else.

That is the complete list. There is no advertising network, no analytics service and no data
broker of any kind in this app.

## App Tracking Transparency

The app does not track you in Apple's sense of the word: nothing here is joined with data
collected by other companies' apps or websites, and nothing is shared with a data broker. That
is why you are never shown the tracking permission prompt.

## How long we keep things

- Release history older than thirty days is deleted from our server, along with products that
  no storefront has listed for six months.
- A release date you sent as a polling hint is deleted shortly after that date has passed.
- Your device record, your follows, your alerts and your size preferences are kept for as long
  as you use the app.

## Deleting your data

Deleting the app removes everything held on the device immediately.

To have the server-side record deleted as well, write to hottorun@pm.me from any address and
say so — because there is no account, please include the device you are asking about so we can
identify the right record. We will delete it and confirm.

## Children

Dropwall is not directed at children and we do not knowingly collect information from anyone
under 13.

## Your rights

Depending on where you live, you may have the right to ask what we hold about you, to have it
corrected or deleted, or to object to our use of it. Write to hottorun@pm.me and we will
answer. Given that we hold no name or email address, the practical answer to "what do you hold
about me" is the list in *What our server receives* above.

## Changes to this policy

If this policy changes we will update the date at the top of this page. Material changes will
also be described in the app's release notes.

## Contact

hottorun@pm.me

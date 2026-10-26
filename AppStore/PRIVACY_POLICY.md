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

Before each release, check the "What our server receives" section against the app as it
actually is on the day you ship.

---

# Dropwall — Privacy Policy

**Last updated: 26 October 2026**

Dropwall is made by KERN AG, Germany. Questions about this
policy go to hottorun@pm.me.

## The short version

You do not need an account to use Dropwall. You never give us a name, an email address or a
password. If you choose to sign in with Apple — so that your follows, sizes and alerts survive a
reinstall, or to add profiles for other people — we receive an identifier Apple makes for
Dropwall alone, and nothing else about you: not your name and not your email address. We do not
ask Apple for either.

Almost everything the app knows about you stays on your phone. The exception is the small amount
of information our server needs in order to tell you that something you are waiting for has been
released, has come back in stock or has been marked down.

We do not sell data, we show no advertising, we use no third-party analytics or attribution
services, and we do not track you across other companies' apps or websites. The one thing we
count is how often the app's main features are used, as anonymous daily totals on our own
server — see *Anonymous usage counts* below.

## What stays on your device and is never sent to us

- Everything you save, and the notes, sizes and photographs attached to it
- Your boards and the outfits you compose
- Anything you type into Shop's search box. Shop searches the products already on your phone,
  and the search never leaves it
- Your daily picks, and anything you mark "not for me"
- Anything you write in the style statement field
- The taste profile used to recommend brands and pick products, and any brand you have dismissed
- Any release date you enter yourself in the drop calendar, along with its title and note
- The analysis of saved photographs — colour, shape, category — which is performed entirely on
  the device using Apple's on-device frameworks, with no image ever uploaded

If you use profiles, each profile's saves, boards, outfits and taste are kept separately on the
phone, and none of them is sent to us either.

Brand recommendations and daily picks are computed on your phone: our server sends products and
candidate brands, and the comparison against your taste happens locally, specifically so that
what you save does not have to leave the device.

Deleting the app deletes all of it. We hold no copy and cannot recover it.

## What our server receives

- **An anonymous device record.** When the app first runs it registers with our server and is
  issued a random identifier. Unless you sign in, it is not linked to you or to your Apple
  Account.
- **A push notification token**, if you allow notifications, so that Apple can deliver alerts to
  your device. Removed if Apple tells us the token is no longer valid.
- **Which brands you follow**, and for each whether you want everything, only sales and price
  drops, or nothing at all, so we know which storefronts to watch and what to tell you.
- **Which products you have asked to be alerted about**, including the size or colour you asked
  for.
- **Your size preferences and your gender filter.** These are held so that a restock alert in a
  size you do not wear is never sent to you. That targeting is the only reason we have them.
- **The country you shop in** — your phone's region, unless you choose another under You ›
  Location. It is held so that, where a brand runs a separate shop for your country, your feed
  and alerts come from that shop and its prices. It is a country and nothing finer: never your
  location, your address or your phone's position.
- **A brand and a time, when you enter a release date yourself and are following that brand**,
  so our server can check that storefront more often around that moment. Only the brand and the
  instant are sent — never the title or the note you wrote, and never any date for a brand you
  do not follow. Nobody else can read it, and no notification or public record is produced
  from it.
- **Anonymous usage counts** — see the next section.
- **Ordinary server logs**, including IP addresses, kept briefly for security and debugging.

### If you sign in with Apple

Signing in is optional, and everything above works without it.

- **An identifier from Apple.** Apple gives each app a different identifier for the same person,
  so ours means nothing outside Dropwall. We use it to recognise your account when you sign in
  on a new phone or after a reinstall.
- **A token from Apple** that lets us cancel Dropwall's sign-in with Apple when you delete your
  account. We use it for nothing else, and it is never shown to anyone.
- Your device records, follows, alerts, sizes and country are linked to the account, so that
  they come back when you sign in again. Signing in on a phone that already had its own follows
  combines the two.

### If you add profiles

A profile is for another person you shop for — "For Anna". For each profile, our server holds
**the name you give it**, and that profile's own follows, alerts, sizes, gender filter and
whether its alerts are switched on. The name is printed at the start of that profile's alerts
("For Anna: …"), so it passes through Apple's notification service like the rest of the alert.
Use any name you like; it does not have to be a real one.

## Anonymous usage counts

So that we can tell which parts of the app people actually use, the app counts a handful of
things, per day:

- opening the app
- opening each of its tabs (Feed, Shop, Saved)
- running a brand search
- asking us to check a shop nobody has added yet
- following a brand
- saving something
- creating a fit
- tapping one of our notifications

It sends only **how many times** each of those happened on each day. Never what you searched
for, saved, followed or looked at; never which product or brand; never a time finer than the
date.

Our server adds those numbers to totals shared by everyone who uses the app, and keeps nothing
else from what was sent: there is no record of which device sent which counts. Like everything
else the app sends us, the counts arrive with your device's anonymous credential — that is how
we stop anyone flooding the totals — and they are separated from it on arrival.

To count how many people use the app in a week without counting one person twice, your device
record holds one extra fact: the date (not the time) on which it last sent counts. It is
replaced each day rather than added to, so it is never a history.

The counts go to our server and nowhere else. No analytics company, SDK or third party is
involved. If the app is running without our server, nothing is counted or sent.

## Where product photographs come from

Product photographs and brand logos are loaded by your device directly from each brand's own
website or content delivery network, rather than being copied through our server. This is
normal for any app that displays images from the web, and it means those companies can see your
device's IP address and the fact that an image was requested — the same as if you had opened
the brand's website in a browser. They receive nothing from us about you.

The same is true when you check a product's stock on its page, open a brand's checkout, or share
a link into the app: your phone asks that website directly.

## Who else is involved

- **Apple**, which delivers push notifications and, if you use it, provides Sign in with Apple.
  Apple's own privacy policy applies to both.
- **Our hosting provider**, which runs the server and its database on our behalf and does not
  use the data for anything else.

That is the complete list. There is no advertising network, no third-party analytics service and
no data broker of any kind in this app.

## App Tracking Transparency

The app does not track you in Apple's sense of the word: nothing here is joined with data
collected by other companies' apps or websites, and nothing is shared with a data broker. That
is why you are never shown the tracking permission prompt.

## How long we keep things

- Release history older than thirty days is deleted from our server, along with products that
  no storefront has listed for six months.
- A release date you sent as a polling hint is deleted shortly after that date has passed.
- Your device record, your follows, your alerts, your size preferences and your country are kept
  for as long as you use the app.
- If you signed in, your account and its profiles are kept until you delete the account.
- The usage totals are kept indefinitely, because they describe nobody. The date your device
  last sent counts is replaced each day.

## Deleting your data

Deleting the app removes everything held on the device immediately.

**If you signed in**, you can delete your account in the app, under You › Account. That deletes,
on our server, the account, every profile on it, every device record signed in to it, and their
follows, alerts, sizes, countries and release dates, and cancels Dropwall's sign-in with Apple.
Deleting a single profile deletes that profile's data the same way. Your phone keeps its own
saves and carries on without an account.

**If you never signed in**, write to hottorun@pm.me from any address and ask us to delete your
server-side record. Because there is no account, please include the device you are asking about
so we can identify the right record. We will delete it and confirm.

## Children

Dropwall is not directed at children and we do not knowingly collect information from anyone
under 13.

## Your rights

Depending on where you live, you may have the right to ask what we hold about you, to have it
corrected or deleted, or to object to our use of it. Write to hottorun@pm.me and we will
answer. Given that we hold no name or email address — only the names you give profiles — the
practical answer to "what do you hold about me" is the list in *What our server receives* above.

## Changes to this policy

If this policy changes we will update the date at the top of this page. Material changes will
also be described in the app's release notes.

## Contact

hottorun@pm.me

# streetw backend — plan

Status: **plan, not built.** Phase 2 of `ROADMAP.md`.

## Why there is a backend at all

Drops resolve in minutes. `BGAppRefreshTask` grants a handful of system-chosen wakeups a day and
throttles hard if the app isn't opened often, so a client-only app cannot do "dropping in X
minutes", restock alerts, or shock-drop detection. Everything else in the roadmap's alerting
column depends on this.

Two consequences beyond notifications:

- **Polling moves off users' devices.** One server politely polling Kith beats N phones doing it.
- **A first sync stops being expensive for the client.** Today it pulls ~3,900 items across two
  brands in ~16s. The server holds the history and ships deltas.

## The load-bearing insight: catalogs are global

Brands, sources, products and stock are **the same for every user**. Only follows, saves and size
profiles are personal.

So the poller runs *once per source*, not once per user-source pair. A thousand users following
Kith cost one request. This shapes the schema, keeps the politeness budget flat as the user base
grows, and is the main reason a shared backend is worth the effort.

## Stack

| | Choice | Why |
|---|---|---|
| Language | **Swift 6** | `streetw/Sources/` already runs server-side unchanged — that's why it was kept free of SwiftData/UIKit |
| Framework | **Vapor 4** | Batteries included: Fluent, migrations, APNs, middleware. Hummingbird is leaner but Vapor's ecosystem saves more time than its overhead costs |
| Database | **Postgres 16** | Catalogs are relational, and `jsonb` covers the messy per-source payloads |
| Push | **APNs, token auth** (`.p8`) | Key-based auth doesn't expire like certificates |
| Hosting | **Railway** to start | Docker deploy, managed Postgres, ~$5–20/mo, minimal ops for a solo dev |
| Scale path | **Fly.io** | Multi-region and finer scaling if polling volume outgrows one box |

Deliberately **not** Vercel: no native Swift runtime, and a poller is a long-lived process, not a
request-scoped function. Vercel's model fights this workload.

### Repository shape

Convert to a SwiftPM monorepo so the shared code is a real dependency rather than copied files:

```
streetw/
├─ Package.swift
├─ Sources/
│  ├─ StreetwCore/          ← today's streetw/Sources/ + SizeMatching, BrandDiscovery
│  ├─ StreetwServer/        ← Vapor app: poller, API, APNs
│  └─ StreetwServerTests/
├─ streetw.xcodeproj        ← iOS app, depends on StreetwCore
└─ streetw/                 ← iOS-only: Models/, Views/, Sync/
```

`StreetwCore` must stay free of SwiftData, SwiftUI, UIKit and Foundation-on-Apple-only APIs. It
already compiles standalone (see CLAUDE.md), so this is a move, not a rewrite. **This step also
gets the project its first real test target** — `StreetwCore` is pure and deterministic given
fixture payloads, so adapters and `SizeNormalizer` become straightforwardly testable.

## Schema

```
brands            id, name, slug, website, instagram, currency, locked_for_drop, created_at
sources           id, brand_id, kind, url, etag, fingerprint, enabled,
                  failure_count, last_checked_at, next_check_at, last_error
products          id, brand_id, source_id, external_id UNIQUE(source_id, external_id),
                  title, summary, link_url, image_urls jsonb, price_cents, currency,
                  product_type, tags text[], published_at, first_seen_at, last_seen_at
variants          id, product_id, external_id, title, size, color, available,
                  price_cents, available_changed_at
events            id, brand_id, product_id, kind, sizes text[], created_at   ← the feed
users             id, created_at
devices           id, user_id, apns_token UNIQUE, environment, locale, updated_at
follows           user_id, brand_id, created_at
size_profiles     user_id, apparel text[], shoe text[], include_one_size
saves             id, user_id, product_id, type, note, saved_at
```

`events` is the append-only spine: the poller writes them, the feed reads them, the notifier fans
them out. Keeps "what happened" separate from "current state".

Indexes that matter: `sources(next_check_at)` for the poll queue, `events(brand_id, created_at)`
for feeds, `variants(product_id)`, and a partial index on `variants(available) WHERE available`.

## Poller

One process, an async loop, no Redis:

1. `SELECT ... FROM sources WHERE next_check_at <= now() ORDER BY next_check_at LIMIT n FOR UPDATE SKIP LOCKED`
2. Fetch via the existing `SourceAdapter` — conditional GET and backoff already implemented
3. Diff into `products`/`variants`, append `events`
4. Set `next_check_at` from a per-source cadence

`FOR UPDATE SKIP LOCKED` means a second instance can be added later without a distributed lock.

**Cadence.** Not uniform — that's how you get blocked:

| Situation | Interval |
|---|---|
| Brand locked for drop | 60s |
| Recently active (event in last 24h) | 5 min |
| Normal | 20 min |
| Quiet for a week | 2 h |
| Failing | exponential backoff, capped 6 h |

**Politeness budget**, non-negotiable: one in-flight request per domain, conditional GETs
everywhere, `robots.txt` respected, and a `User-Agent` naming the app with a contact URL. Being
identifiable and cheap to serve is what keeps access; a brand that asks to be dropped gets dropped.

## Notifications

On each `event`, resolve recipients:

```sql
follows ⋈ size_profiles ⋈ devices  WHERE brand_id = $1
```

then filter with `SizeProfile.matches` from `StreetwCore` — the same code the client uses, which is
precisely why it lives there. Restock pushes go only to people who wear the sizes that came back.

Rules: collapse per brand per batch ("Kith — 6 new"), never notify on the baseline first sync,
respect quiet hours, and cap per-brand-per-day. `dropLock` is the one alert allowed to interrupt.

## API

Small and delta-shaped. Bearer token per device.

```
POST   /v1/devices              register APNs token, locale       → user_id, token
PATCH  /v1/devices/:id          update size profile, quiet hours
GET    /v1/feed?since=<cursor>  events + hydrated products        → items, next_cursor
GET    /v1/brands?q=            search the shared catalog
POST   /v1/brands/discover      { url } → probes sources, returns preview
POST   /v1/follows              { brand_id }
DELETE /v1/follows/:brand_id
POST   /v1/saves                { product_id, type }
```

Auth starts as an opaque device token — no login, no PII, and it matches how the app is used today.
Sign in with Apple gets added when cross-device sync is wanted; the `users` row already exists to
hang it off.

## Client migration

The client keeps SwiftData as a local cache; only its *filling* changes.

1. `StreetwCore` extracted; iOS builds against it, behaviour identical
2. `RemoteSource` — an API-backed path in `SyncEngine`, behind a flag, direct adapters still default
3. Server becomes the default; direct adapters stay as a debug path (and keep the live harness useful)
4. APNs registration + notification handling
5. Retention moves server-side; the phone keeps a smaller window

Nothing here forces a schema break: `externalID` is already the dedupe key on both sides.

## Cost

Railway hobby + Postgres ≈ **$10–20/mo** at a few hundred brands and a few thousand users. The
poller is I/O-bound and mostly gets 304s. Apple charges nothing for APNs. Postgres is the first
thing to outgrow, and the first fix is pruning `products` for unfollowed brands.

## Risks

- **Access is a privilege.** `products.json` is public but not promised. Cache aggressively, stay
  cheap to serve, and keep adapters swappable so one brand's change isn't an outage.
- **Single instance is a single point of failure.** Acceptable at this stage; `SKIP LOCKED` keeps
  the door open.
- **Push fatigue kills retention faster than missing a drop.** Default to conservative caps.
- **A first sync per new brand is heavy** (~2,500 products for Kith). Run discovery off the poll
  loop so it can't stall routine checks.

## Build order

1. SwiftPM monorepo + `StreetwCore` extraction (+ first tests)
2. Vapor skeleton, Postgres, migrations
3. Poller against the real schema, no notifications — verify it matches what the app finds today
4. Feed API + client `RemoteSource`
5. APNs, size-targeted restocks
6. Cadence tuning and the politeness budget under real load

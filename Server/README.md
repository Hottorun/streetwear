# streetw server

Polls brand sources on a schedule, diffs them, and serves a per-user feed.
Design rationale is in `../BACKEND.md`.

## Run locally

No Postgres or Docker needed — it falls back to SQLite.

```bash
cd Server
swift run StreetwServer serve --port 8080
```

```bash
curl localhost:8080/health

# Add a brand to the shared catalog (probes for a catalog / feed / page watch)
curl -X POST localhost:8080/v1/brands/discover \
     -H 'content-type: application/json' \
     -d '{"url": "kith.com"}'

# Register a device; the token is the bearer credential for everything else
TOKEN=$(curl -sX POST localhost:8080/v1/devices \
  -H 'content-type: application/json' \
  -d '{"sizes": {"apparel": ["M","L"], "shoe": ["9","9.5"]}}' | jq -r .token)

curl -X POST localhost:8080/v1/follows \
     -H "authorization: Bearer $TOKEN" -H 'content-type: application/json' \
     -d "{\"brandID\": \"<id>\"}"

# Force a poll rather than waiting for the loop
curl -X POST localhost:8080/admin/poll

curl -H "authorization: Bearer $TOKEN" localhost:8080/v1/feed
```

## Tests

```bash
swift test
```

In-memory SQLite, no network — `StubHTTP` serves canned catalogs. The poller tests cover
the rules that matter: a first poll is a baseline, a restock names the size that returned,
an unchanged catalog produces nothing, and a failing source backs off.

## Environment

| Variable | Default | Notes |
|---|---|---|
| `DATABASE_URL` | — | Postgres URL. Absent → SQLite |
| `SQLITE_PATH` | `streetw.sqlite` | `:memory:` supported |
| `AUTO_MIGRATE` | on | `false` to skip migrations at boot |
| `DISABLE_POLLER` | off | `true` to run the API without polling |
| `POLITE_INTERVAL` | `2.0` | Minimum seconds between requests to one host |
| `PORT` | 8080 | Read in `configure.swift`; hosts assign this at runtime |
| `HOST` | `0.0.0.0` | Must not be localhost inside a container |
| `APNS_KEY_P8` | — | Contents of the `.p8`. `\n` escapes are accepted, so it pastes as one line |
| `APNS_KEY_ID` | — | Key ID from the developer portal |
| `APNS_TEAM_ID` | — | Team ID from the developer portal |
| `APNS_TOPIC` | `functional.streetw` | The app's bundle ID |
| `EVENT_RETENTION_DAYS` | `30` | Events older than this, already notified, are pruned |
| `PRODUCT_RETENTION_DAYS` | `180` | Products unseen this long *and* with no events left are pruned |

**Push is optional.** With no `APNS_*` set the server logs `apns: not configured` and runs
exactly as before — polling, feed, registration — it just never delivers an alert.
`/status` reports `apnsConfigured`, and the app surfaces that as "Server has no push key",
because a server that silently never notifies looks identical to one that does.

## Deploying to Railway

Railway watches the GitHub repo, builds an image from the Dockerfile, and runs it as a
long-lived process.

1. **New Project → Deploy from GitHub repo**, pick the repo.
2. Nothing else to configure: `railway.json` at the repo root pins the builder to
   `DOCKERFILE` with `dockerfilePath: Server/Dockerfile`. **Without that file Railway
   uses its Railpack autodetector, which has no Swift provider and fails with "could not
   determine how to build the app."** If you'd rather set it in the UI: Settings → Build →
   Builder = Dockerfile, Dockerfile Path = `Server/Dockerfile`, and leave Root Directory
   empty.
3. **+ New → Database → Postgres.** Railway injects `DATABASE_URL` automatically; nothing
   to copy. On boot `configure.swift` sees it, switches from SQLite to Postgres, and runs
   migrations.
4. **Settings → Networking → Generate Domain**, then `curl https://<domain>/health`.

### Toolchain

The Dockerfile pins `swift:6.3.3-noble`, matching local development. Dependencies in
`Package.resolved` declare their own minimum swift-tools-version (Vapor's tree needs 6.2+),
so an older image fails to even read the resolved graph. If you upgrade Xcode and
re-resolve, bump the image tag to match.

### Why the build context is the repo root

Two different settings, easy to conflate:

- *Dockerfile path* — which file holds the instructions: `Server/Dockerfile`
- *Build context* — which directory Docker may copy from: the **repo root**

They differ because `Server/Package.swift` declares `.package(path: "..")`. `StreetwCore`
lives at the repo root, so a context of `Server/` literally cannot see it and the build
fails while resolving. That's also why the Dockerfile's `COPY` paths (`Sources`,
`Server/Sources`) are written relative to the root.

The whole source tree is copied before `swift build`, rather than resolving from manifests
first for better layer caching: SwiftPM validates that every declared target directory
exists when it loads the package graph, path dependencies included.

Cost is roughly $5 for the service plus $5 for Postgres to begin with. The poller is
I/O-bound and mostly receives 304s, so one instance goes a long way.

## Operational notes

- **The catalog is global.** Brands, sources, products and variants are one row per
  real-world thing; only users, devices, follows and size profiles are personal. A
  thousand followers of Kith cost one request.
- **`next_check_at` is the schedule**, held in the database rather than in memory, so a
  restart resumes exactly where it left off and a second instance can be added later
  behind `FOR UPDATE SKIP LOCKED`.
- **Cadence is deliberately uneven** — 60s while a storefront is locked for a drop,
  5 min after recent activity, 20 min normally, 2 h when quiet, exponential backoff on
  failure. Uniform polling is how you get blocked.
- **Politeness budget**: conditional GETs everywhere, `robots.txt` obeyed per host, and
  requests to one host spaced by `POLITE_INTERVAL` even under concurrency — see
  `PoliteFetcher`. `Net.userAgent` is honest on purpose.
- **`notified_at` is the push ledger.** One notification per brand per pass, never one
  per event: a brand dropping a collection writes hundreds of events in a single poll.
  Anything older than the notifier's freshness window (6 h) is marked without being sent,
  so coming back from an outage doesn't fire a burst about drops that already sold out.
- **Retention deletes events before products, never the reverse.** `events.product_id`
  is `ON DELETE CASCADE`, so pruning a product would silently take feed history with it —
  and deleting a product the source still lists makes the next poll announce it as new.
  Only products unseen for `PRODUCT_RETENTION_DAYS` with no events left are eligible.

```bash
# Fan out anything pending, and report what happened
curl -X POST localhost:8080/admin/notify

# Run retention now rather than waiting for the 6-hourly sweep
curl -X POST localhost:8080/admin/sweep
```

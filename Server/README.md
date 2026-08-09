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
- **Politeness budget**: conditional GETs everywhere, and before this faces real traffic
  it needs a per-domain concurrency limit, `robots.txt` handling and a `User-Agent`
  naming a contact URL. Currently it inherits the app's browser-ish UA — see
  `Net.userAgent`.

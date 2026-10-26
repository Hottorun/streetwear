# Moving the database to a Postgres with pgvector, and switching embeddings on

Part of the streetw guidance set; see `CLAUDE.md` for the index and the build rules.

This is the owner's runbook for the one-off move in `ROADMAP.md` Phase 3, in two parts that are
done in this order and checked in between:

1. **The database** (steps 1–12): a Postgres that has the pgvector extension, by dump and restore.
2. **The embedding service** (steps 13–17): `Embeddings/` deployed as a second Railway service,
   and the server pointed at it.

Nothing in the app or the server has to change for either — the server works on both databases
and with or without the service, and says at boot which it has. One change at a time, so that
whatever goes wrong has one cause. It is written for somebody who has never done a dump and
restore; every command is meant to be pasted as it is.

**Why a move and not a setting.** Railway's default Postgres has no pgvector and Railway does not
plan to add it. The pgvector template is a different Postgres service, so the data is copied into
it: dump the old database, restore it into the new one, point the server at the new one. The old
database is left exactly as it was, which is the rollback.

**What it costs in downtime.** The server is stopped for the copy so nothing is written to the old
database after the dump. With today's catalogue the dump and restore take a few minutes. While the
server is down the app says so — a search reads "The search didn't run", the feed simply does not
refresh — and nothing is lost on the phones.

## What you need

- The Railway project, and permission to change its plan.
- A Mac with Homebrew. The Postgres command-line tools must be **the same major version as the
  database or newer** — `pg_dump` refuses to dump a newer server. Step 3 checks the version.
- `ADMIN_TOKEN`, to read `/admin/status` before and after. It is in the server service's variables on
  Railway; copy it into your terminal, not into a document.
- Half an hour, at a quiet time. Drops are announced around 10:00–11:00 local time on weekdays;
  late evening is quietest.

**Two things to keep private.** The database URLs carry the password, and the dump file holds
every device's tokens. Keep both in your terminal and on your own disk, never in a chat, a ticket
or a shared folder, and delete the dump at the end (step 12).

## 1. Decide the plan: Hobby is enough to start

**The pgvector template runs on Hobby.** Railway's docs put no plan restriction on templates or
databases (checked 2026-10-26); the template is the `pgvector/pgvector` Docker image with a volume,
deployed like any other service. What a plan changes here is how big that volume may be — **5 GB
on Hobby**, 1 TB on Pro — and, per service, 48 GB of memory and 48 vCPU on Hobby, far more than
Postgres or the embedding service need.

**Storage is not the reason to move yet.** Measured on Postgres 17: products and their variants
take about 3.2 MB per 1,000 products, and both vectors with their index about 12.7 MB more — so
roughly 16 MB per 1,000 products, before events. Hobby's 5 GB holds a few hundred thousand
products. Check where you are before choosing:

```bash
curl -s -H "Authorization: Bearer $ADMIN_TOKEN" https://app.streetw.hottorun.com/admin/status
```

`databaseBytes` is the number the cap is measured against. Under about 2.5 GB, stay on Hobby and
set the new volume's size to the most it allows. Move to Pro when `databaseBytes` passes half the
cap — a re-embed for a new model briefly needs about twice the vectors' space — or when you want
other people in the workspace.

**On cost the two meet at $20 a month.** Hobby is $5 with $5 of usage included; Pro is $20 with
$20 included, per Railway's pricing page. The embedding service alone is about $13 a month of
resident memory (`Embeddings/README.md`, *Measured*), which with the server and Postgres puts the
project past $20 of usage — at which point Pro costs the same as Hobby. Railway's backup docs name
no plan for scheduled backups; check that step 10 is offered on your plan before relying on it.

To change plan: Railway → your workspace → **Settings → Plans**.

## 2. Add the pgvector Postgres

In the project: **+ Create → Template**, search for **pgvector**, and deploy the template named
pgvector (on 2026-10-26 it ran `pgvector/pgvector:pg18`, Postgres 18). When it has deployed:

- Open the new service → **Settings** and give it a clear name, for example `pgvector`. The name
  is what the server's variable will refer to in step 8.
- Note its Postgres **major version** — it is in the image tag on the service page (`pg18` means
  18). Step 3 needs it.
- **Settings → Volume**: check one is attached, and set its size — 5 GB on Hobby, which is the
  most it allows; on Pro, 20 GB is ample for now.

Leave the old Postgres service alone. Nothing below changes it.

## 3. Install the right Postgres tools

Each database service's **Variables** tab shows `DATABASE_PUBLIC_URL`. Copy each one into your
terminal — the old one first — without printing it anywhere else:

```bash
read -rs OLD_URL   # paste the OLD service's DATABASE_PUBLIC_URL, press return
read -rs NEW_URL   # paste the NEW (pgvector) service's DATABASE_PUBLIC_URL, press return
export OLD_URL NEW_URL
```

`read -s` keeps the value off the screen and out of your shell history.

Check both versions:

```bash
brew install postgresql@18          # the new server's major version, from step 2
export PATH="/opt/homebrew/opt/postgresql@18/bin:$PATH"
psql "$OLD_URL" -tAc "SHOW server_version"
psql "$NEW_URL" -tAc "SHOW server_version"
pg_dump --version
```

Use the newer of the two servers' major versions — if the template has moved on to 19, install
`postgresql@19` and put `@19` in the `PATH` line. `pg_dump` must be at least the old server's
major version; `pg_restore` at least the new one's. Restoring a 17 dump into 18 is a supported
upgrade.

Check pgvector is really there on the new one:

```bash
psql "$NEW_URL" -tAc "SELECT default_version FROM pg_available_extensions WHERE name = 'vector'"
```

It must print a version, like `0.8.0`. If it prints nothing, this is not a pgvector Postgres —
stop here.

## 4. Take a reading of the old database

So there is something to compare against after the restore:

```bash
curl -s -H "Authorization: Bearer $ADMIN_TOKEN" https://app.streetw.hottorun.com/admin/status
psql "$OLD_URL" -tAc "SELECT 'brands', count(*) FROM brands UNION ALL
  SELECT 'products', count(*) FROM products UNION ALL SELECT 'variants', count(*) FROM variants UNION ALL
  SELECT 'events', count(*) FROM events UNION ALL SELECT 'users', count(*) FROM users UNION ALL
  SELECT 'devices', count(*) FROM devices UNION ALL SELECT 'follows', count(*) FROM follows"
```

Keep the output.

## 5. Stop the server

So nothing writes to the old database after the dump. On Railway, open the **server** service
(not a database) → **Deployments** → the active deployment → **⋯ → Remove**. This stops it and
keeps every setting; step 9 brings it back.

Check it is down: `curl -s https://app.streetw.hottorun.com/health` should fail or time out.

## 6. Dump the old database

```bash
pg_dump "$OLD_URL" --format=custom --no-owner --no-privileges --file="streetw-$(date +%F).dump"
ls -lh streetw-*.dump
```

`--format=custom` is compressed and is what `pg_restore` reads. `--no-owner` and `--no-privileges`
leave out the old database's user names, which do not exist on the new one. It goes over the
public URL, so this one copy is billed as egress; it is small.

## 7. Restore into the new database

```bash
pg_restore --dbname="$NEW_URL" --no-owner --no-privileges --exit-on-error "streetw-$(date +%F).dump"
echo "exit code: $?"
```

It must end with `exit code: 0`. If it stops with an error, nothing is wrong with the old
database — read the error, fix it (most often the tools' version, step 3), empty the new database
and run it again:

```bash
psql "$NEW_URL" -c "DROP SCHEMA public CASCADE; CREATE SCHEMA public;"
```

Then compare the counts with step 4 — every number must match:

```bash
psql "$NEW_URL" -tAc "SELECT 'brands', count(*) FROM brands UNION ALL
  SELECT 'products', count(*) FROM products UNION ALL SELECT 'variants', count(*) FROM variants UNION ALL
  SELECT 'events', count(*) FROM events UNION ALL SELECT 'users', count(*) FROM users UNION ALL
  SELECT 'devices', count(*) FROM devices UNION ALL SELECT 'follows', count(*) FROM follows"
psql "$NEW_URL" -tAc "SELECT count(*) FROM products WHERE search IS NULL"
```

The last one must print `0`: the full-text column is generated, and Postgres recomputes it for
every restored row.

Do **not** create the extension or `product_embeddings` by hand. The restored migration record
says `AddProductEmbeddings` already ran — it did, on the old database, where it found no pgvector
and did nothing — so the server installs both itself at every boot (`SemanticIndex.prepare`).
Step 9 checks that it did.

## 8. Point the server at the new database, privately

Open the **server** service → **Variables** → `DATABASE_URL`, and set it to a reference to the
new service's **private** URL:

```
${{pgvector.DATABASE_URL}}
```

`pgvector` is the service name from step 2; use whatever you named it. **Use `DATABASE_URL`, not
`DATABASE_PUBLIC_URL`.** The private one is on Railway's internal network (a hostname ending in
`.railway.internal`), which is free; the public one goes out and back in through a proxy and every
byte is billed as egress, which on a poller is all day. The server switches TLS off by itself for
an `.internal` host — that hop never leaves Railway's network.

## 9. Start the server and read its boot log

Railway redeploys when the variable is saved; if it does not, **Deployments → Deploy**. In the
deployment's logs, find these lines:

```
database: postgres (DATABASE_URL), host=<something>.railway.internal, tls=disable
embeddings: off — EMBEDDING_URL and EMBEDDING_TOKEN are not set
search: full-text; pgvector 0.8.x installed — semantic search off until EMBEDDING_URL and EMBEDDING_TOKEN are set
Server started on http://0.0.0.0:8080
```

The third line is the one this move is for, and "off until …" is right: the embedding service is
part 2. If it says `semantic search unavailable (this Postgres has no pgvector)`, the variable
points at the old database. If it says `pgvector could not be installed`, look for the
`embeddings:` error line just before it.

Then check it from outside:

```bash
curl -s https://app.streetw.hottorun.com/health
curl -s -H "Authorization: Bearer $ADMIN_TOKEN" https://app.streetw.hottorun.com/admin/status
```

`databaseConnected` must be `true` and the counts must match step 4 (events and products may have
grown by a few if the poller has already run). On a phone: open Shop and search for something you
know is in your shops; open Feed and pull to refresh.

## 10. Turn on daily backups

The new database service → **Backups** → **Edit schedule** → **Daily**. Railway keeps the
snapshots for a fixed period per schedule; daily is the one that matters for a catalogue that
changes every few minutes. Take one now with **Backup now**, so there is a restore point from
the first hour.

## 11. Keep the old database for a week

Do not delete it yet. It is the rollback, and it costs a few dollars. After a week of the new
database being healthy, delete the old Postgres service (its **Settings → Danger → Delete**).

## 12. Delete the dump

```bash
rm -P streetw-*.dump
unset OLD_URL NEW_URL
```

The dump holds device tokens and everybody's sizes; it has no business staying on a laptop.

## 13. Deploy the embedding service

Only once part 1 has been healthy for a while — a day is plenty. The build takes several minutes
and touches nothing else, so it can be started earlier; only step 14 changes the server.

Follow `Embeddings/README.md` (*Deploy on Railway*), steps 1–5 and 7: a new service from this repo
with **Root Directory** `Embeddings`, named `embeddings`, **no public domain**, the variables
`EMBEDDING_TOKEN` (`openssl rand -hex 32`, pasted straight into Railway, nowhere else),
`EMBEDDING_THREADS=2` and `PORT=8080`, 2 vCPU and 3 GB under *Resources*, and `/health` as the
health check.

**The model.** Leave `EMBEDDING_MODEL_REPO` and `EMBEDDING_MODEL_REVISION` unset for Marqo
FashionSigLIP v1, the default. To start on the ZooClaw model instead, set both now, before the
first build — *Choosing the model* in `Embeddings/README.md` has the values and what it costs.
Choosing now is cheaper than switching later: a switch re-embeds everything.

When it is deployed, from the **server** service's shell (*⋯ → Shell*, or `railway ssh`):

```bash
curl -s http://embeddings.railway.internal:8080/health
```

It must print the model id, `"dimension":768` and `"ready":true`.

## 14. Point the server at it

Server service → **Variables**, add:

```
EMBEDDING_URL=http://embeddings.railway.internal:8080
EMBEDDING_TOKEN=${{embeddings.EMBEDDING_TOKEN}}
```

The reference keeps the two tokens in step; `embeddings` is the service's name from step 13. Plain
`http` is right on the private network. Let it redeploy, and find in the boot log:

```
embeddings: sidecar at http://embeddings.railway.internal:8080
search: full-text; pgvector 0.8.x installed — semantic search on
```

`embeddings: off — EMBEDDING_URL and EMBEDDING_TOKEN must both be set` means one is missing or the
URL is not `http(s)://…`.

## 15. Watch the backfill

The server embeds the catalogue by itself, newest first, 32 products a batch, logging each batch
as `embeddings: embedded 32 (31 with a photograph, 0 written off, 1 to ask again) under …`. It
does not hold anything up: until a product is embedded, search finds it by its words as before.
At the measured 3–10 images a second it is hours for a large catalogue; Railway's own speed is
still to be measured, so note how many batches the first hour does.

To see progress at any time:

```bash
curl -s -X POST -H "Authorization: Bearer $ADMIN_TOKEN" "https://app.streetw.hottorun.com/admin/embed?batches=1"
```

This runs one batch now and says what it did; `embedded 0 … under <model>` means the backlog is
empty. A line saying `semantic search unavailable` or `no embedding provider` names which half of
step 14 or part 1 is missing. Photographs that cannot be read are expected — a few per brand,
storefront CDNs time out and 404 — and are logged as `photograph written off: <url>`; the
product is still searchable by its words.

## 16. Check it on a phone

Search Shop for something described rather than named ("cream knit sweater"), and open a product's
"more like this". The results should be visibly closer than full-text's. If the embedding service
is redeploying or down, search says nothing different and answers by its words alone, at most one
search in thirty seconds waiting 1.5 s — that is the designed behaviour, not a fault.

## 17. Look at the volume again

A day after the backfill finishes, read `databaseBytes` on `/admin/status` again (step 1). Expect about
12.7 MB per 1,000 products more than before part 2. If it is past half of the plan's cap, this is
the time to move to Pro, not when it is full.

## Rolling back

**Part 2** is one variable: delete `EMBEDDING_URL` on the server service and let it redeploy.
Search goes back to full-text, said at boot; the vectors stay in the database for when it comes
back, and nothing else changes. The `embeddings` service can then be removed or left.

**Part 1** — if anything after step 8 is wrong and cannot be fixed quickly:

1. Server service → **Variables** → set `DATABASE_URL` back to `${{Postgres.DATABASE_URL}}`
   (the old service's name; it was this before step 8).
2. Let it redeploy, and check `/health` and the boot log say `semantic search unavailable`.

The old database is exactly as it was at step 6, so this loses whatever was written to the new one
since — follows and watches added in that window, and the poller's progress, which it catches up
on by itself. If the new one ran for long enough that this matters, dump it the same way (step 6,
with `NEW_URL`) before switching back, and ask before restoring it over the old one.

## Rehearsed

The steps were run end to end on a scratch Postgres 17 with pgvector 0.8.7: a database migrated by
`main`'s server with eight thousand products and fifty thousand variants, upgraded by this
branch's server, then put in the state production will be in — the extension and its table
removed, `AddProductEmbeddings` still recorded as applied — dumped with the command in step 6, restored with the one in step 7 into a fresh
database on a Postgres **with** pgvector — every count matched, `search` was filled on all eight
thousand rows — and the server booted on it saying `pgvector 0.8.7 installed`, with
`product_embeddings` created by the boot rather than by a migration.

Part 2 was rehearsed on this Mac against the same kind of scratch database: the real
`Embeddings/` service (FashionSigLIP v1, 2 threads) and the server with `EMBEDDING_URL` and
`EMBEDDING_TOKEN` set and the poller off, over 600 real products from Drake's, Aimé Leon Dore and
Billionaire Boys Club. Boot said `semantic search on`; `POST /admin/embed` embedded all 565
garments in under ten minutes, wrote off one photograph (over the size cap) and asked again about
119 that timed out or did not resolve, 105 of which answered on the retry. Search re-ranked by
vector at 100–190 ms, "more like this" answered by vector at 35–50 ms, a frozen service cost one
search 1.6 s and the next ones nothing, and swapping the service's model to ZooClaw under the
running server made it say `model changed`, re-embed all 565 under the new id, and compare no
vector across the two.

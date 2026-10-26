# Moving the database to a Postgres with pgvector

Part of the streetw guidance set; see `CLAUDE.md` for the index and the build rules.

This is the owner's runbook for the one-off move in `ROADMAP.md` Phase 3: Railway Pro, and a
Postgres that has the pgvector extension. Nothing in the app or the server has to change for it —
the server works on both databases, and says at boot which one it is on. It is written for
somebody who has never done a dump and restore; every command is meant to be pasted as it is.

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
- `ADMIN_TOKEN`, to read `/status` before and after. It is in the server service's variables on
  Railway; copy it into your terminal, not into a document.
- Half an hour, at a quiet time. Drops are announced around 10:00–11:00 local time on weekdays;
  late evening is quietest.

**Two things to keep private.** The database URLs carry the password, and the dump file holds
every device's tokens. Keep both in your terminal and on your own disk, never in a chat, a ticket
or a shared folder, and delete the dump at the end (step 12).

## 1. Upgrade to Railway Pro

Railway → your workspace → **Settings → Plans → Pro**. Pro is what lifts the 5 GB volume cap the
full catalogue scan will pass, and it is what makes scheduled backups available (step 10).

## 2. Add the pgvector Postgres

In the project: **+ Create → Template**, search for **pgvector**, and deploy the template named
pgvector (it runs the `pgvector/pgvector` image with a volume). When it has deployed:

- Open the new service → **Settings** and give it a clear name, for example `pgvector`. The name
  is what the server's variable will refer to in step 8.
- Note its Postgres **major version** — it is in the image tag on the service page (`pg17` means
  17).
- **Settings → Volume**: set the size to what Pro allows and the catalogue needs. 20 GB is ample
  for now.

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
brew install postgresql@17          # skip if already installed
export PATH="/opt/homebrew/opt/postgresql@17/bin:$PATH"
psql "$OLD_URL" -tAc "SHOW server_version"
psql "$NEW_URL" -tAc "SHOW server_version"
pg_dump --version
```

If either server is newer than 17 — say `18.1` — install that one instead
(`brew install postgresql@18`, and `@18` in the `PATH` line). `pg_dump` must be at least the old
server's major version; `pg_restore` at least the new one's.

Check pgvector is really there on the new one:

```bash
psql "$NEW_URL" -tAc "SELECT default_version FROM pg_available_extensions WHERE name = 'vector'"
```

It must print a version, like `0.8.0`. If it prints nothing, this is not a pgvector Postgres —
stop here.

## 4. Take a reading of the old database

So there is something to compare against after the restore:

```bash
curl -s -H "Authorization: Bearer $ADMIN_TOKEN" https://app.streetw.hottorun.com/status
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
search: full-text; pgvector 0.8.x installed — semantic search waits for a provider
Server started on http://0.0.0.0:8080
```

The second line is the one this move is for. "waits for a provider" is right — no embedding
provider is switched on yet (`EMBEDDING_URL`, see `docs/server.md`). If it says
`semantic search unavailable (this Postgres has no pgvector)`, the variable points at the old
database. If it says `pgvector could not be installed`, look for the `embeddings:` error line just
before it.

Then check it from outside:

```bash
curl -s https://app.streetw.hottorun.com/health
curl -s -H "Authorization: Bearer $ADMIN_TOKEN" https://app.streetw.hottorun.com/status
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

## Rolling back

If anything after step 8 is wrong and cannot be fixed quickly:

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

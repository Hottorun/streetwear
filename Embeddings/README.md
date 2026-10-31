# Dropwall embeddings

A small Python service beside the Swift server. It turns product photos and short text
queries into vectors for search, "find similar" and photo matching. That is its only job:
it stores nothing, decides nothing about what gets embedded, and is never reachable from
the internet. Why it exists and what runs where is in `docs/server.md` (*Embeddings*).

**The default model is Marqo FashionCLIP**, chosen on 2026-10-30 over FashionSigLIP v1 and seven
others on the server's own search eval (`docs/server.md`, *The search eval*); FashionSigLIP v1 ran
from the first deploy until then. Marqo has not published FashionSigLIP 2 — the v1 card says
"Contact Marqo" and the organisation has no v2 repository. Both Marqo models are Apache-2.0 and
pinned by revision. The model is a build argument, so FashionSigLIP or a third-party SigLIP2
fine-tune can be swapped back in without a code change; see *Choosing the model*.
`eval/README.md` compares the SigLIP models on our own catalogues.

## API

Every route except `/health` needs `Authorization: Bearer $EMBEDDING_TOKEN`. With no token
configured the service refuses every embed request (503), as the main server's admin routes
do without `ADMIN_TOKEN`.

| Route | Body | Answer |
|---|---|---|
| `GET /health` | none | `{"model", "dimension", "ready"}`. 503 until the model is loaded and a token is set |
| `POST /embed/text` | `{"texts": ["olive canvas chore coat", …]}` | `{"model", "dimension", "vectors": [[…]]}` |
| `POST /embed/image` | `{"urls": ["https://cdn.shopify.com/…", …]}` | same, with `null` and an `errors` entry for each photo that could not be read |
| `POST /embed/image` | one image as `Content-Type: image/*` | same, one vector |
| `POST /embed/photo` | one photograph somebody took, as `Content-Type: image/jpeg` | same, one vector. The scan's "find this" (`docs/ai.md`) |

- Vectors are L2-normalised, so cosine similarity is a dot product. `model` names the
  repository and revision (`Marqo/marqo-fashionCLIP@44f4c655124e`). Store it beside every
  vector: two revisions do not share a space. `dimension` is the model's — 512 for FashionCLIP,
  768 for the SigLIP models.
- Limits: 64 items per request (`EMBEDDING_MAX_ITEMS`), 1,000 characters per text, 10 MB
  per image, 2 MB per photograph on `/embed/photo` (`EMBEDDING_MAX_PHOTO_BYTES`).
- **`/embed/photo` is narrower than the bytes branch of `/embed/image` on purpose.** It takes a
  JPEG and nothing else — the declared type *and* the start-of-image marker, 415 otherwise; an
  empty body is 400 and one that will not decode 422 — at the scan's own size: the phone sends a
  photograph already scaled to 1,024 px and under 1.5 MB, so anything near a storefront photo's
  10 MB is not one. It is embedded and dropped; nothing writes it anywhere, and the access log
  line is the method and the path.
- One unreadable photo does not fail the batch. Its vector is `null`, and
  `errors: [{"index": 1, "error": "HTTP 404", "transient": false}]` says why. `transient` says
  whether asking again later could help: true for a timeout, a connection failure, a host that
  did not resolve, and HTTP 408/425/429/5xx; false for every other status, a refused address, an
  oversized image and anything that will not decode. The server writes off only the second kind
  (`EmbeddingBackfill`, `docs/server.md`).

### Fetching images safely

The service sits on Railway's private network beside Postgres, so `/embed/image` refuses
to be a way into it:

- only `http`/`https`, only ports 80 and 443, no credentials in the URL;
- every address the host resolves to must be public. Loopback, private, link-local
  (including `169.254.169.254`), CGNAT and unique-local IPv6 (`fc00::/7`, where Railway's
  private addresses live) are refused, as is an IPv4
  address hidden inside an IPv6 one (mapped, 6to4, Teredo, NAT64);
- the connection goes to the address that was checked, with the real hostname used for
  SNI and certificate checks, so a second DNS answer cannot redirect it (DNS rebinding);
- redirects are followed by hand, at most three, and each hop is checked again;
- 10 MB cap, enforced while streaming as well as on `Content-Length`; a 10 s timeout per
  image; images over 40 megapixels are refused before they are decoded;
- no proxy from the environment, no keep-alive across hostnames, and the honest
  User-Agent `Dropwall-Embeddings/1.0 (+https://github.com/Hottorun/streetwear)`.

It fetches only the URLs an authenticated caller (our server) sends. It crawls nothing.

## Run locally

```bash
cd Embeddings
python3.12 -m venv .venv
.venv/bin/pip install --require-hashes --only-binary=:all: \
  --index-url https://download.pytorch.org/whl/cpu --extra-index-url https://pypi.org/simple \
  -r requirements.txt          # Linux only: requirements.txt pins the +cpu Linux wheels
.venv/bin/python download_model.py /tmp/embedding-model          # ~600 MB
EMBEDDING_TOKEN=dev EMBEDDING_MODEL_DIR=/tmp/embedding-model .venv/bin/python -m embedding_service
```

On a Mac, install the same packages unpinned (`pip install torch open_clip_torch
transformers pillow starlette uvicorn httpx pytest`), or use Docker:

```bash
docker build -t dropwall-embeddings Embeddings/
docker run --rm -p 8080:8080 -e EMBEDDING_TOKEN=dev dropwall-embeddings
curl localhost:8080/health
curl -s localhost:8080/embed/text -H 'Authorization: Bearer dev' \
  -H 'Content-Type: application/json' -d '{"texts": ["olive canvas chore coat"]}' | head -c 200
```

Tests use a fake model and never touch the network:

```bash
pip install pytest && pytest                                   # from Embeddings/
EMBEDDING_MODEL_DIR=/tmp/embedding-model pytest -m slow        # the real model, opt-in
```

### Environment

| Variable | Default | |
|---|---|---|
| `EMBEDDING_TOKEN` | none | Shared secret. Unset refuses everything |
| `EMBEDDING_THREADS` | CPU count | torch intra-op threads; set it to the vCPUs the service is given |
| `EMBEDDING_BATCH_SIZE` | 16 | Items per forward pass |
| `EMBEDDING_MAX_ITEMS` | 64 | Items per request |
| `EMBEDDING_MAX_IMAGE_BYTES` | 10485760 | Per image |
| `EMBEDDING_MAX_PHOTO_BYTES` | 2097152 | Per photograph on `/embed/photo` |
| `EMBEDDING_FETCH_TIMEOUT` | 10 | Seconds per image |
| `EMBEDDING_MODEL_DIR` | `/models/embedding` | Set by the image |
| `EMBEDDING_MODEL_REPO` | `Marqo/marqo-fashionCLIP` | Build argument **and** variable: which model the image holds. See *Choosing the model* |
| `EMBEDDING_MODEL_REVISION` | `44f4c655124e…` (full hash) | Its pinned commit. A full 40-character hash; a branch name is refused |
| `PORT` | 8080 | Railway sets it |

## Choosing the model

Three models can go in the image, each pinned to a commit in `download_model.py` (`MODELS`):

| | `Marqo/marqo-fashionCLIP` (default) | `Marqo/marqo-fashionSigLIP` | `srpone/zooclaw-fashionsiglip2` |
|---|---|---|---|
| Revision | `44f4c655124ed71e90cbf528d82f508d69d8a81b` | `c56244cc94f92419e8369fa71efdaf403b124ce8` | `d2c0c98de9cd1e27c114267ddfbb584eb98b5ebf` |
| Who | Marqo | Marqo | an individual Hugging Face account (`srpone`), paper arXiv:2606.27708 |
| Base | CLIP ViT-B/16, 224 px, 512-d | SigLIP ViT-B/16, 224 px, 768-d | SigLIP2 base, 384 px, 768-d |
| Loader | open_clip (its own CLIP tokenizer) | open_clip (tokenizer from `timm/ViT-B-16-SigLIP`) | transformers `SiglipModel` |
| Weights | 599 MB | 813 MB | 1.5 GB |
| Search eval, P@10 / nDCG@10 (`docs/server.md`) | **0.862** / **0.883** | 0.836 / 0.861 | not run |
| Text R@1 / image R@1 (`eval/`) | not run | 0.50 / 0.75 | **0.61** / **0.78** |
| CPU per image, 2 vCPU | same tower as FashionSigLIP; not re-measured in Docker | 0.30 s | 1.09 s (3.7× slower; *Measured*) |
| Licence | Apache-2.0 | Apache-2.0 | Apache-2.0 (`LICENSE` file since 2026-10-28) |

**Why the default is FashionCLIP.** The server compares *text with text* — a query, or one
product's title, type, colours and tags, against every product's (`docs/server.md`, *Embeddings*)
— and `eval/` only ever scored text against photographs. The search eval does measure it, on the
53 judged searches over 10,041 products: against FashionSigLIP v1, FashionCLIP took P@10 from
0.836 to 0.862 and nDCG@10 from 0.861 to 0.883, German phrasing from 0.31 to 0.32, and the gated
meaning matches added seven right results where SigLIP's added two — the best of nine models
tried, chosen by the owner on 2026-10-30. Its vectors are 512 wide rather than 768, so a
catalogue's vectors and index cost about 9 MB per thousand products instead of 12.7. It needs its
own search threshold (`ProductSearch.measuredThresholds`, 0.45 — CLIP puts every pair of texts
closer than SigLIP does) and its own reading bars (`ZeroShot.measuredBars`), both keyed by the
model id the service reports.

**ZooClaw** was the owner's earlier choice, on the condition that its licence file allows
commercial use; at the time it had none. On 2026-10-28 its authors added an Apache-2.0 `LICENSE`
and a `NOTICE` (commits `84cc6660…` and `167244b2…`, the weights unchanged — `model.safetensors`
keeps LFS SHA-256 `aa9a0927…`), so the condition is now met and it is pinnable at
`167244b24c30740727f5a3b42c41fa6d673f0a67`. It is documented here, not switched to: it has not
been run through the search eval, it is 3.7× slower per image, and on the 565-product rehearsal
"more like this" from Drake's Brown Tweed Games Blazer gave, under FashionSigLIP, the two other
Games Blazers, a herringbone jacket and a tweed coat; under ZooClaw, a waxed jacket, three pocket
squares and three hiking T-shirts. Run the search eval before choosing it.

**Licences, as checked on 2026-10-30.** Every model declares `license: apache-2.0` in its card's
metadata. Neither Marqo repository carries a `LICENSE` file; Marqo's code repository
(`marqo-ai/marqo-FashionCLIP`) carries the Apache 2.0 text. ZooClaw's repository carries the
`LICENSE` file since 2026-10-28 (above); its base `google/siglip2-base-patch16-384` is
Apache-2.0, and its authors' benchmark code (`SerendipityOneInc/look-bench`) carries the text. Its
card also advertises a commercial API and separately licensed training data; neither is used
here. We run the weights inside our own service and do not redistribute them.

**To switch**, set both variables on the `embeddings` service and rebuild — for example back to
FashionSigLIP v1:

```
EMBEDDING_MODEL_REPO=Marqo/marqo-fashionSigLIP
EMBEDDING_MODEL_REVISION=c56244cc94f92419e8369fa71efdaf403b124ce8
```

Railway passes them to the build as `ARG`s (the Dockerfile declares them) and to the running
service as variables. The service checks the two agree at boot: if the image holds one model and
the variables name another — a restart without a rebuild — it refuses to start, its health check
stays red, and the previous deploy keeps serving. Locally:
`docker build --build-arg EMBEDDING_MODEL_REPO=… --build-arg EMBEDDING_MODEL_REVISION=… Embeddings/`,
or `python download_model.py DIR REPO REVISION`.

**Switching re-embeds the whole catalogue.** The model id (`repo@revision[:12]`) is stored beside
every vector, and vectors from two models are never compared. The server reads the new id from
the first answer, and from then on every product is due again (`EmbeddingBackfill`, 32 a batch,
newest first, each row overwritten in place). Until the backfill has caught up, semantic search
answers from the products already re-embedded and full-text covers the rest, so nothing breaks;
it just gets better as it goes. Budget for it: FashionCLIP and FashionSigLIP read 224 px through
the same size of tower, so at the 3–4 images a second measured for v1 on 2 vCPU, ten thousand
products is about an hour on Railway; at ZooClaw's 3.7 times that, 100k products is about two
days rather than hours, while the resident memory stays about the same (1.2 GB serving, 1.9 GB
peak, measured). The product readings (`ProductReadingBackfill`) follow behind, since their key
names the model too. Each new model also builds its own HNSW indexes; the old model's rows are
overwritten as they are re-embedded, and its indexes can be dropped once none are left
(`DROP INDEX idx_product_embeddings_…`, named in `pg_indexes`).

To add another model: an entry in `MODELS` with its loader, files and a pinned commit; the
search eval run against it, and its threshold added to `ProductSearch.measuredThresholds`; the
reading eval run against it, and its bars added to `ZeroShot.measuredBars` (`docs/server.md`). A
model missing from either table is not guessed at — search makes no meaning matches for it, and
the reading waits and says so.

## Deploy on Railway

A second service in the same project as the server, reachable only over the private
network.

1. **New service.** In the project, *New → GitHub Repo →* this repo. Under *Settings →
   Source*, set **Root Directory** to `Embeddings`. Railway then builds
   `Embeddings/Dockerfile`, and changes outside that directory don't rebuild it. Under
   *Settings → Config-as-code*, set the config file to `/Embeddings/railway.json`: Railway
   reads the config file from the repo root whatever the Root Directory says, so without
   this the service picks up the server's `railway.json` and builds `Server/Dockerfile`,
   failing on `"/Server/Tests": not found`. Name the service `embeddings`. Its private hostname becomes
   `embeddings.railway.internal`.
2. **No public domain.** Under *Settings → Networking*, don't generate a domain, and delete
   one if Railway offered it. Private networking is on by default.
3. **Variables** on the `embeddings` service:
   - `EMBEDDING_TOKEN`: a long random secret (`openssl rand -hex 32`);
   - `EMBEDDING_THREADS`: the vCPU count from step 4 (2);
   - `PORT=8080`, so the server's URL below doesn't depend on whatever Railway picks.
4. **Resources.** Under *Settings → Deploy → Resources*, allow 2 vCPU and 3 GB memory. The
   process holds about 1.3 GB once serving and peaks at about 1.6 GB while loading the
   weights, so 2 GB fits with little headroom. Railway bills what is used, not the limit, so
   the extra headroom costs nothing. See *Measured* below. With the ZooClaw model 3 GB is still enough (peak 1.9 GB, measured).
5. **Health check.** *Settings → Deploy → Healthcheck Path* `/health`. It answers 503
   until the model is loaded and a token is set, so a misconfigured deploy never replaces a
   working one.
6. **On the main server's service**, add:
   - `EMBEDDING_URL=http://embeddings.railway.internal:8080` (plain `http`: private-network
     traffic stays inside Railway's WireGuard mesh);
   - `EMBEDDING_TOKEN`: the same secret. A reference variable keeps them in step:
     `EMBEDDING_TOKEN=${{embeddings.EMBEDDING_TOKEN}}`.

   With either variable unset, the server runs with embeddings off, and search uses
   full-text alone.
7. **Check it from the server's shell** (*service → ⋯ → Shell*, or `railway ssh`):
   `curl -s http://embeddings.railway.internal:8080/health` should print the model id,
   `"dimension":512` and `"ready":true`.

The image is about 3 GB unpacked (1 GB compressed), of which ~600 MB is weights (815 MB with
FashionSigLIP) and most of the rest is torch. The
first build takes several minutes, and later builds reuse the cached layers unless
`requirements.txt`, `download_model.py` or the model variables changed.

## Measured

The image built here and run under colima (Linux aarch64 VM on an Apple A18 Pro), with the
service limited to `--cpus 2 --memory 2g` and `EMBEDDING_THREADS=2`, as on Railway:

| | |
|---|---|
| Boot to ready | ~20 s, offline, from `/models` |
| Memory once serving | 1.3 GB resident (cgroup peak during load 1.6 GB) |
| One text query, over HTTP | 108 ms median |
| 32 texts | 3.0 s |
| One image, posted as bytes | 296 ms median |
| 16 image URLs from Shopify's CDN, fetch + embed | 12.8 s |

The model alone, in the same image without HTTP, on 1 / 2 / 4 vCPU: 3.2 / 3.1 / 4.8
images a second batched, and 131 / 159 / 85 ms per single text. The same model natively
on the Mac does about 10 images a second (`eval/README.md`). Railway's x86 vCPUs will be
somewhere else again, so **measure once deployed** before planning a backfill.

**The ZooClaw image, measured the same way** (built with the two build arguments, run under
colima at `--cpus 2 --memory 3g`, `EMBEDDING_THREADS=2`, on 2026-10-26):

| | ZooClaw | Marqo v1, above |
|---|---|---|
| Boot to ready | 8 s (warm page cache) | ~20 s |
| Memory once serving | 1.2 GB (cgroup peak 1.9 GB) | 1.3 GB (peak 1.6 GB) |
| One text query, over HTTP | 123 ms median | 108 ms |
| 32 texts | 3.3 s | 3.0 s |
| One image, posted as bytes | 1,087 ms median | 296 ms |
| 16 image URLs from Shopify's CDN, fetch + embed | 25.4 s | 12.8 s |

So about **0.9 images a second** for the model alone and 0.6 with fetching, on 2 vCPU — 3.7 times
slower per image than Marqo, and text costs the same. 100k products is then about two days on
2 vCPU rather than hours; 3 GB of memory is enough. The image is 1.5 GB of weights instead of
0.8 GB. Natively on the Mac the same model re-embedded the 565-product rehearsal, fetches
included, in 5½ minutes.

**FashionCLIP** (the default since 2026-10-30) has not been measured in Docker. It is a ViT-B/16
at 224 px like FashionSigLIP v1 with a smaller text tower (63M parameters against 110M), so
expect the v1 numbers or slightly better; natively on this Mac it loaded in 2 s and read the
203 reading-eval products' photographs at the pace FashionSigLIP did. Measure once deployed, as
above.

**Embedding 100k products once** at 3–10 images a second is 3–9 hours on 2 vCPU,
which costs about $0.20–0.80 in CPU and memory at Railway's usage rates ($20 per
vCPU-month, $10 per GB-month). Fetching the photos from storefront CDNs adds time, not
cost. **Standing cost** is mostly the resident memory: about 1.3 GB × $10 ≈ $13 a month,
plus CPU only while embedding.

Checked in that container: `/health` without a token answers 503 `ready:false` and every
embed request is refused; a wrong token is 401; URLs for `169.254.169.254`, `localhost`,
`host.docker.internal`, the VM's `192.168.5.2` and `file:///etc/passwd` are refused per item
while the Shopify photo in the same batch is embedded; vectors are identical (cosine
1.000000) to the `hf-hub:` model the eval scored, so the pinned image is the model that was
measured; the process runs as uid 10001.

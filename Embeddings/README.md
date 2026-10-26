# Dropwall embeddings

A small Python service beside the Swift server. It turns product photos and short text
queries into vectors for search, "find similar" and photo matching. That is its only job:
it stores nothing, decides nothing about what gets embedded, and is never reachable from
the internet. Why it exists and what runs where is in `docs/server.md` (*Embeddings*).

**The model is Marqo FashionSigLIP (v1), not v2.** Marqo has not published FashionSigLIP 2.
The v1 model card says "Marqo Fashion Siglip 2 is available … Contact Marqo to learn more",
and Marqo's Hugging Face organisation has no v2 repository. v1 is Apache-2.0 and pinned by
revision in `download_model.py`. `eval/README.md` compares it with the base SigLIP model it
was fine-tuned from, on our own catalogues.

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

- Vectors are L2-normalised, so cosine similarity is a dot product. `model` names the
  repository and revision (`Marqo/marqo-fashionSigLIP@c56244cc94f9`). Store it beside every
  vector: two revisions do not share a space.
- Limits: 64 items per request (`EMBEDDING_MAX_ITEMS`), 1,000 characters per text, 10 MB
  per image.
- One unreadable photo does not fail the batch. Its vector is `null`, and
  `errors: [{"index": 1, "error": "HTTP 404"}]` says why.

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
.venv/bin/python download_model.py /tmp/fashionsiglip            # ~815 MB
EMBEDDING_TOKEN=dev EMBEDDING_MODEL_DIR=/tmp/fashionsiglip .venv/bin/python -m embedding_service
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
EMBEDDING_MODEL_DIR=/tmp/fashionsiglip pytest -m slow          # the real model, opt-in
```

### Environment

| Variable | Default | |
|---|---|---|
| `EMBEDDING_TOKEN` | none | Shared secret. Unset refuses everything |
| `EMBEDDING_THREADS` | CPU count | torch intra-op threads; set it to the vCPUs the service is given |
| `EMBEDDING_BATCH_SIZE` | 16 | Items per forward pass |
| `EMBEDDING_MAX_ITEMS` | 64 | Items per request |
| `EMBEDDING_MAX_IMAGE_BYTES` | 10485760 | Per image |
| `EMBEDDING_FETCH_TIMEOUT` | 10 | Seconds per image |
| `EMBEDDING_MODEL_DIR` | `/models/fashionsiglip` | Set by the image |
| `PORT` | 8080 | Railway sets it |

## Deploy on Railway

A second service in the same project as the server, reachable only over the private
network.

1. **New service.** In the project, *New → GitHub Repo →* this repo. Under *Settings →
   Source*, set **Root Directory** to `Embeddings`. Railway then builds
   `Embeddings/Dockerfile`, and changes outside that directory don't rebuild it. (The root
   `railway.json` belongs to the server. This service has none, so its settings live in
   the dashboard.) Name the service `embeddings`. Its private hostname becomes
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
   the extra headroom costs nothing. See *Measured* below.
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
   `"dimension":768` and `"ready":true`.

The image is about 3.2 GB unpacked (1.1 GB compressed), of which ~815 MB is weights and most
of the rest is torch. The
first build takes several minutes, and later builds reuse the cached layers unless
`requirements.txt` or `download_model.py` changed.

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

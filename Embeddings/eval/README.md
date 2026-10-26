# Embedding eval

A small check on our own kind of data before trusting a model with search. It is not a
benchmark: 1,000 products, 200 queries, one afternoon in October 2026.

## The data

`fetch_catalogue.py` read two pages (500 products) of public `/products.json` from five
starter-pack brands: Kith, Staud, Aimé Leon Dore, Drake's and Faithfull the Brand. Requests
were 2 s apart, used the app's own User-Agent, and checked robots.txt first. Two brands that
were asked for are absent on purpose:

- **Carhartt WIP** serves no `/products.json` (404). The server reads its sitemap instead.
- **Princess Polly**'s robots.txt disallows `/products.json` for our User-Agent.

Drake's and Faithfull, from the same starter pack, took their places.

`build_eval.py` picked 200 products per brand with at least two photos. It used a hash of the
product id, not an RNG. It wrote `manifest.json`, committed here: the corpus image URLs, the
queries and their answers. Photos were fetched at 512 px wide from Shopify's CDN, paced, into
`/tmp`. No fetched data is in git.

- **text → product (100 queries).** A short query built from a product's own colour (its
  colour-family tag, or a basic colour word in its colourway or title), material (title or
  fabric tag) and garment noun, e.g. "brown corduroy jacket", "black cashmere sweater". It
  searches the lead photo of all 1,000 products. Any product with the same colour and garment
  (and material, if the query names one) counts as correct. Queries with more than five
  correct answers were dropped as too generic. 49 queries have exactly one correct answer.
- **image → same product (100 queries).** A product's *second* photo searches the lead
  photos. Only that product counts. Another colourway of the same garment is a miss, because
  photo matching is meant to find the exact thing. Second photos are often on-model shots
  where the lead is a packshot, which is the realistic case.

## Results

CPU, `torch.inference_mode()`, normalised vectors, cosine similarity.

| Model | Text R@1 | Text R@10 | Text MRR | Image R@1 | Image R@10 | Image MRR |
|---|---|---|---|---|---|---|
| SigLIP ViT-B/16 WebLI (`timm/ViT-B-16-SigLIP`, the base) | 0.48 | 0.91 | 0.636 | 0.71 | 0.90 | 0.779 |
| **Marqo FashionSigLIP v1** (`Marqo/marqo-fashionSigLIP`, chosen) | 0.50 | 0.92 | 0.642 | 0.75 | 0.90 | 0.811 |
| ZooClaw FashionSigLIP2 (`srpone/zooclaw-fashionsiglip2`, third party) | **0.61** | 0.92 | **0.713** | **0.78** | **0.92** | **0.841** |
| Marqo FashionSigLIP **2** | not published, see below | | | | | |

Raw numbers are in `results.json`.

**Read it honestly.**

- **Marqo v1 beats its base by 2 points on text and 4 on images.** With 100 queries a task,
  that is inside the noise (one query is one point). It does not lose anywhere, and it costs
  nothing extra, since the architecture and speed are the same. But this eval does not show
  Marqo's published 6-dataset margin carrying over to our catalogues. It is a tie with a slight
  lean.
- **The third-party SigLIP2 fine-tune is the clear winner on text** (+11 points R@1 over
  Marqo v1), and slightly ahead on images. It is not Marqo's model. It comes from an
  individual Hugging Face account (`srpone`, Apache-2.0, paper arXiv:2606.27708, fine-tuned
  from `google/siglip2-base-patch16-384`), and it is about **4x slower per image on CPU**
  because it reads 384 px images, not 224 px. Choosing it is the owner's call, not something
  this eval settles. It is the obvious thing to try if text search quality disappoints.
- R@10 is about 0.9 for all three, so for a results page (rather than one answer) the
  models are much closer than R@1 suggests. The labels are also incomplete. A product whose
  colour or garment could not be read off its tags is never counted as correct, even when it
  is. That penalises every model the same way, but it means the absolute numbers understate
  all three. The misses were not inspected one by one.

### Why not FashionSigLIP 2

It was the owner's choice, but Marqo has not released it. The v1 model card says, verbatim:

> **Marqo Fashion Siglip 2 is available.** marqo-fashion-SigLip-2 has shown a further 78%
> improvement in MMR and recall vs marqo-fashion-SigLip. Contact Marqo to learn more:
> https://www.marqo.ai/book-demo

Marqo's Hugging Face organisation has no v2 repository (checked through the Hub API on
2026-10-26), so v2 is a commercial offering. The service uses v1, as the fallback plan said.

### Licences

- `Marqo/marqo-fashionSigLIP`: model card metadata `license: apache-2.0`. Marqo's code
  repository (`marqo-ai/marqo-FashionCLIP`) carries the Apache License 2.0 text. Commercial
  use is permitted.
- `timm/ViT-B-16-SigLIP` (the base, and the source of the tokenizer): `license: apache-2.0`.
- `srpone/zooclaw-fashionsiglip2`: `license: apache-2.0`. Selectable in the service, not the
  default; `../README.md` (*Choosing the model*) has the licence check and the pinned commit.

## CPU cost

`bench.py`, on this Mac (Apple A18 Pro: 2 performance and 4 efficiency cores, 8 GB, with
other builds competing). Single-image latency includes preprocessing. "Batched" is 32 images
in one call.

| Threads | 1 image | 8 images | 32 images | img/s batched | 1 text | 32 texts | Peak RSS | Serving RSS |
|---|---|---|---|---|---|---|---|---|
| 1 | 82 ms | 0.80 s | 7.7 s | 4.2 | 58 ms | 1.65 s | 1.40 GB | 0.40 GB |
| 2 | 102 ms | 1.08 s | 3.3 s | 9.7 | 47 ms | 0.91 s | 1.23 GB | 0.49 GB |
| 4 | 87 ms | 0.54 s | 3.2 s | 9.9 | 195 ms | 1.48 s | 1.89 GB | 0.49 GB |
| 6 | 122 ms | 0.86 s | 4.5 s | 7.2 | 148 ms | 0.97 s | 1.68 GB | 0.67 GB |

Past two threads the efficiency cores and the competing builds add noise rather than speed.
The Linux numbers from the Docker image, which is what Railway runs, are in
`../README.md` (*Measured*). The SigLIP2 checkpoint at 4 threads: 270 ms for one image, 2.0
img/s batched.

Download size: `open_clip_model.safetensors` is 812.7 MB, plus about 2.4 MB of tokenizer.

## Reproduce

```bash
python fetch_catalogue.py /tmp/p3embed/data/catalogue      # ~20 s, 10 requests
python build_eval.py /tmp/p3embed/data/catalogue manifest.json
python run_eval.py fetch manifest.json /tmp/p3embed/data/images      # ~1,100 photos, paced
for m in siglip-base marqo-fashionsiglip zooclaw-fashionsiglip2; do
  python run_eval.py score $m manifest.json /tmp/p3embed/data/images results.json
done
python bench.py marqo-fashionsiglip 2 /tmp/p3embed/data/images bench.json
```

Needs `torch open_clip_torch transformers timm pillow psutil`. Catalogues change, so a fresh
`fetch_catalogue.py` gives a different manifest. Use the committed one to compare against
these numbers. Some of its photo URLs will 404 as products are retired.

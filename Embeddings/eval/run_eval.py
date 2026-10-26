"""Score embedding models on the manifest from build_eval.py.

    python run_eval.py fetch manifest.json /tmp/p3embed/data/images
    python run_eval.py score <model> manifest.json /tmp/p3embed/data/images results.json

`fetch` downloads every photo once (paced, honest User-Agent) into a cache outside the repo.
`score` runs one model per process, so peak memory is that model's alone and the next one
starts from a clean heap. Models are named as in MODELS below.
"""

import hashlib
import json
import sys
import time
import urllib.request
from pathlib import Path

USER_AGENT = "Dropwall/1.0 (+https://github.com/Hottorun/streetwear)"
IMAGE_INTERVAL = 0.3
BATCH = 32

MODELS = {
    # The base the Marqo model was fine-tuned from: SigLIP ViT-B/16, WebLI, 224px.
    "siglip-base": ("open_clip", "hf-hub:timm/ViT-B-16-SigLIP"),
    # Marqo FashionSigLIP (v1). Marqo has not published FashionSigLIP 2.
    "marqo-fashionsiglip": ("open_clip", "hf-hub:Marqo/marqo-fashionSigLIP"),
    # A third party's SigLIP2 fine-tune with "fashionsiglip2" in its name. Not Marqo's.
    "zooclaw-fashionsiglip2": ("transformers", "srpone/zooclaw-fashionsiglip2"),
}


def cached(cache: Path, url: str) -> Path:
    return cache / (hashlib.sha1(url.encode()).hexdigest() + ".img")


def fetch(manifest: dict, cache: Path) -> None:
    cache.mkdir(parents=True, exist_ok=True)
    urls = [c["image"] for c in manifest["corpus"]] + [q["image"] for q in manifest["image_queries"]]
    for n, url in enumerate(urls):
        path = cached(cache, url)
        if path.exists():
            continue
        req = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
        with urllib.request.urlopen(req, timeout=30) as resp:
            path.write_bytes(resp.read())
        time.sleep(IMAGE_INTERVAL)
        if n % 100 == 0:
            print(f"{n}/{len(urls)}", flush=True)


class Encoder:
    def __init__(self, name: str):
        import torch
        kind, repo = MODELS[name]
        self.kind = kind
        self.torch = torch
        if kind == "open_clip":
            import open_clip
            self.model, _, self.preprocess = open_clip.create_model_and_transforms(repo)
            self.tokenizer = open_clip.get_tokenizer(repo)
        else:
            from transformers import AutoModel, AutoProcessor
            self.model = AutoModel.from_pretrained(repo)
            self.processor = AutoProcessor.from_pretrained(repo)
        self.model.eval()

    def images(self, pil_images):
        torch = self.torch
        with torch.inference_mode():
            if self.kind == "open_clip":
                x = torch.stack([self.preprocess(im) for im in pil_images])
                v = self.model.encode_image(x)
            else:
                x = self.processor(images=pil_images, return_tensors="pt")["pixel_values"]
                v = self.model.get_image_features(pixel_values=x)
                v = getattr(v, "pooler_output", v)
            return torch.nn.functional.normalize(v, dim=-1)

    def texts(self, texts):
        torch = self.torch
        with torch.inference_mode():
            if self.kind == "open_clip":
                v = self.model.encode_text(self.tokenizer(texts))
            else:
                x = self.processor(text=texts, padding="max_length", max_length=64,
                                   truncation=True, return_tensors="pt")
                v = self.model.get_text_features(input_ids=x["input_ids"])
                v = getattr(v, "pooler_output", v)
            return torch.nn.functional.normalize(v, dim=-1)


def score_ranking(sims, keys, relevant_sets):
    """Recall@1, recall@10 and MRR; a query is satisfied by any of its relevant keys."""
    r1 = r10 = mrr = 0.0
    order = (-sims).argsort(dim=1)
    for row, relevant in zip(order.tolist(), relevant_sets):
        rank = next(i for i, j in enumerate(row) if keys[j] in relevant) + 1
        r1 += rank == 1
        r10 += rank <= 10
        mrr += 1 / rank
    n = len(relevant_sets)
    return {"recall@1": r1 / n, "recall@10": r10 / n, "mrr": mrr / n, "queries": n}


def score(name: str, manifest: dict, cache: Path, out: Path) -> None:
    import resource
    from PIL import Image

    def load(url):
        return Image.open(cached(cache, url)).convert("RGB")

    t0 = time.time()
    enc = Encoder(name)
    loaded = time.time() - t0

    def embed_images(urls):
        parts = []
        for i in range(0, len(urls), BATCH):
            parts.append(enc.images([load(u) for u in urls[i:i + BATCH]]))
        return enc.torch.cat(parts)

    keys = [c["key"] for c in manifest["corpus"]]
    t1 = time.time()
    corpus = embed_images([c["image"] for c in manifest["corpus"]])
    per_image = (time.time() - t1) / len(keys)

    texts = enc.texts([q["text"] for q in manifest["text_queries"]])
    images = embed_images([q["image"] for q in manifest["image_queries"]])

    result = {
        "model": name,
        "repo": MODELS[name][1],
        "dimension": corpus.shape[1],
        "load_seconds": round(loaded, 1),
        "corpus_seconds_per_image_batched": round(per_image, 4),
        "peak_rss_mb": round(resource.getrusage(resource.RUSAGE_SELF).ru_maxrss / 2**20),
        "text_to_product": score_ranking(texts @ corpus.T, keys,
                                         [set(q["relevant"]) for q in manifest["text_queries"]]),
        "image_to_product": score_ranking(images @ corpus.T, keys,
                                          [set(q["relevant"]) for q in manifest["image_queries"]]),
    }
    results = json.loads(out.read_text()) if out.exists() else {}
    results[name] = result
    out.write_text(json.dumps(results, indent=2))
    print(json.dumps(result, indent=2))


if __name__ == "__main__":
    command = sys.argv[1]
    if command == "fetch":
        fetch(json.loads(Path(sys.argv[2]).read_text()), Path(sys.argv[3]))
    elif command == "score":
        score(sys.argv[2], json.loads(Path(sys.argv[3]).read_text()), Path(sys.argv[4]), Path(sys.argv[5]))
    else:
        sys.exit(__doc__)

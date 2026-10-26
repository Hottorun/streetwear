"""Turn fetched catalogues into the eval manifest: a corpus of product photos and ~200
queries whose answers are known from the catalogue itself.

    python build_eval.py /tmp/p3embed/data/catalogue manifest.json

Two tasks:

- **text -> product.** A short attribute query built from a product's own colour, material
  and garment noun ("brown corduroy jacket"), searched against the lead photo of every
  product in the corpus. Any product with the same colour and garment (and material, when
  the query names one) is a correct answer, not only the product it was derived from, so a
  generic query is not scored as a miss for finding a different black tee.
- **image -> same product.** A product's second photo, searched against the lead photos of
  the corpus. Only that product is correct; another colourway of the same garment counts as
  a miss, because "find this exact thing" is what photo matching is for.

Deterministic: selection is by a hash of the product id, never an RNG.
"""

import hashlib
import json
import re
import sys
from pathlib import Path

CORPUS_PER_BRAND = 200
TEXT_QUERIES_PER_BRAND = 20
IMAGE_QUERIES_PER_BRAND = 20
MAX_RELEVANT = 5

COLOURS = [
    "black", "white", "ivory", "cream", "ecru", "grey", "gray", "charcoal", "navy", "blue",
    "green", "olive", "khaki", "brown", "tan", "beige", "camel", "chocolate", "red",
    "burgundy", "pink", "purple", "lilac", "yellow", "orange", "gold", "silver", "multi",
]
COLOUR_ALIASES = {"gray": "grey", "multi": "multicolour", "paisley": None, "print": None}

MATERIALS = [
    "corduroy", "denim", "canvas", "wool", "merino", "lambswool", "cashmere", "mohair",
    "linen", "silk", "satin", "leather", "suede", "nylon", "cotton", "fleece", "tweed",
    "velvet", "crochet", "knit", "jersey", "shearling", "seersucker", "flannel", "chambray",
    "poplin", "tulle", "lace", "raffia", "terry", "twill", "oxford", "sequin",
]

# Longest phrases first, so "chore coat" wins over "coat" and "t-shirt" over "shirt".
GARMENTS = sorted([
    "chore coat", "trucker jacket", "bomber jacket", "rugby shirt", "polo shirt", "t-shirt",
    "tee", "polo", "shirt", "overshirt", "blouse", "top", "tank", "camisole", "bodysuit",
    "sweater", "cardigan", "jumper", "hoodie", "sweatshirt", "crewneck", "vest", "gilet",
    "jacket", "blazer", "coat", "parka", "blouson", "anorak", "trench", "dress", "skirt",
    "pant", "pants", "trouser", "trousers", "jean", "jeans", "short", "shorts", "chino",
    "jumpsuit", "playsuit", "bikini", "swimsuit", "beanie", "cap", "hat", "bucket hat",
    "scarf", "tie", "pocket square", "sock", "socks", "sneaker", "sneakers", "boot", "boots",
    "loafer", "loafers", "sandal", "sandals", "mule", "mules", "heel", "heels", "bag",
    "tote", "belt", "wallet", "gloves", "glove",
], key=len, reverse=True)
SINGULAR = {
    "pants": "pants", "pant": "pants", "trouser": "trousers", "jean": "jeans", "short": "shorts",
    "socks": "socks", "sock": "socks", "sneaker": "sneakers", "boot": "boots", "boots": "boots",
    "loafer": "loafers", "sandal": "sandals", "mule": "mules", "heel": "heels",
    "glove": "gloves", "t-shirt": "tee",
}

COLOUR_TAG = re.compile(r"^(?:ColourFamily_|colorgroup-|Colour_)(.+)$", re.I)
FABRIC_TAG = re.compile(r"^(?:FabricFamily_|fabric-)(.+)$", re.I)


def words(text: str) -> str:
    return " " + re.sub(r"[^a-z0-9-]+", " ", text.lower()) + " "


def find(vocab, text):
    padded = words(text)
    for term in vocab:
        if f" {term} " in padded:
            return term
    return None


def colour_of(product):
    tags = product["tags"] if isinstance(product["tags"], list) else product["tags"].split(", ")
    family = [m.group(1).lower() for t in tags if (m := COLOUR_TAG.match(t))]
    if len(family) == 1:
        c = family[0]
        c = COLOUR_ALIASES.get(c, c)
        if c in COLOURS or c == "multicolour":
            return c
    named = [o["values"][0] for o in product["options"]
             if o["name"].lower() in ("color", "colour") and len(o["values"]) == 1]
    for text in named + [product["title"]]:
        if c := find(COLOURS, text):
            return COLOUR_ALIASES.get(c, c)
    return None


def material_of(product):
    tags = product["tags"] if isinstance(product["tags"], list) else product["tags"].split(", ")
    if m := find(MATERIALS, product["title"]):
        return m
    fabrics = [m.group(1) for t in tags if (m := FABRIC_TAG.match(t))]
    for f in fabrics:
        if m := find(MATERIALS, f):
            return m
    return None


def garment_of(product):
    g = find(GARMENTS, product["title"]) or find(GARMENTS, product.get("product_type") or "")
    return SINGULAR.get(g, g) if g else None


def stable(key: str) -> int:
    return int(hashlib.sha1(key.encode()).hexdigest()[:12], 16)


def image(src: str, width: int = 512) -> str:
    # Shopify's CDN resizes on request; the eval never needs the 2000px original.
    return f"{src}{'&' if '?' in src else '?'}width={width}"


def main(catalogue_dir: Path, out: Path) -> None:
    corpus, text_queries, image_queries = [], [], []
    for path in sorted(catalogue_dir.glob("*.json")):
        host = path.stem
        products = [p for p in json.loads(path.read_text()) if len(p["images"]) >= 2]
        products.sort(key=lambda p: stable(f"{host}:{p['id']}"))
        chosen = products[:CORPUS_PER_BRAND]
        start = len(corpus)
        for p in chosen:
            corpus.append({
                "key": f"{host}:{p['id']}",
                "title": p["title"],
                "image": image(p["images"][0]["src"]),
                "second": image(p["images"][1]["src"]),
                "colour": colour_of(p),
                "material": material_of(p),
                "garment": garment_of(p),
            })
        brand = corpus[start:]

        for item in brand[:IMAGE_QUERIES_PER_BRAND]:
            image_queries.append({"image": item["second"], "relevant": [item["key"]]})

    # Relevance is decided over the whole corpus, so a query from one brand is satisfied by
    # a matching product from another.
    def relevant(source):
        return [
            c["key"] for c in corpus
            if c["colour"] == source["colour"] and c["garment"] == source["garment"]
            and (source["material"] is None or c["material"] == source["material"])
        ]

    for host in sorted({c["key"].split(":")[0] for c in corpus}):
        brand = [c for c in corpus if c["key"].startswith(host + ":")]
        taken = 0
        for item in sorted(brand, key=lambda i: stable("q" + i["key"])):
            if taken == TEXT_QUERIES_PER_BRAND:
                break
            if not item["colour"] or not item["garment"]:
                continue
            text = " ".join(x for x in (item["colour"], item["material"], item["garment"]) if x)
            answers = relevant(item)
            if len(answers) > MAX_RELEVANT or any(q["text"] == text for q in text_queries):
                continue
            text_queries.append({"text": text, "relevant": answers})
            taken += 1

    manifest = {
        "corpus": [{"key": c["key"], "image": c["image"]} for c in corpus],
        "text_queries": text_queries,
        "image_queries": image_queries,
    }
    out.write_text(json.dumps(manifest, indent=0, separators=(",", ":")) + "\n")
    print(f"corpus {len(corpus)}, text queries {len(text_queries)}, "
          f"image queries {len(image_queries)} -> {out}")


if __name__ == "__main__":
    main(Path(sys.argv[1]), Path(sys.argv[2]))

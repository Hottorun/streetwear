#!/usr/bin/env python3
"""The search eval: about fifty real searches with judged answers, run against a local server.

Standard library only — it talks to the server over HTTP, to Postgres through the `psql`
command, and to the embedding sidecar over HTTP. Nothing here ever points at production: every
address is an argument with a 127.0.0.1 default. See `docs/server.md`, *The search eval*.

    python3 searcheval.py dump        # the catalogue the local server holds -> catalogue.json
    python3 searcheval.py judge       # the written judgements below, applied -> judgements.json
    python3 searcheval.py run before after
    python3 searcheval.py thresholds  # how close the judged answers are, by meaning

`catalogue.json` is a snapshot of whatever the local poller read and is not committed;
`judgements.json` is, together with the date it was judged on. A product judged then and gone
from a later catalogue is left out of that run's counts, and the run says how many were.
"""

import argparse
import json
import math
import os
import re
import subprocess
import sys
import urllib.parse
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
QUERIES = os.path.join(HERE, "queries.json")
JUDGEMENTS = os.path.join(HERE, "judgements.json")
CATALOGUE = os.path.join(HERE, "catalogue.json")

# What each variant sends besides `q`. `before` is exactly what 1.2 and 1.3 ask for under "Also
# look in every shop we watch" — the unlifted search over every shop, words only — which the
# server still answers that way, so it is the baseline on any build.
VARIANTS = {
    "before": {"scope": "all"},
    "after": {"scope": "all", "boost": "standard", "meaning": "true"},
    "after-words": {"scope": "all", "boost": "standard"},
    "after-more": {"scope": "all", "boost": "more", "meaning": "true"},
    "only-mine": {"scope": "followed", "meaning": "true"},
}

# The shops the eval's reader follows, so the lift has something to lift.
FOLLOWED = ["drakes.com", "colorfulstandard.com"]


# MARK: - Reading the catalogue

def psql(sql, database):
    out = subprocess.run(
        ["psql", database, "-At", "-c", f"COPY ({sql}) TO STDOUT WITH (FORMAT csv)"],
        check=True, capture_output=True, text=True,
    ).stdout
    import csv
    import io
    return list(csv.reader(io.StringIO(out)))


def dump(args):
    rows = psql("""
        SELECT b.slug, p.external_id, p.title, coalesce(p.product_type, ''),
               array_to_string(p.tags, '|'), coalesce(p.price_amount::text, ''),
               coalesce(p.currency, b.currency, ''), left(coalesce(p.summary, ''), 600),
               coalesce((SELECT string_agg(DISTINCT v.color, '|') FROM variants v
                         WHERE v.product_id = p.id AND v.color IS NOT NULL), '')
        FROM products p JOIN brands b ON b.id = p.brand_id
        WHERE p.kind = 'product' AND p.storefront_id IS NULL AND p.unlisted_at IS NULL
          AND p.pending_announcement IS NULL AND cardinality(p.image_urls) > 0
        """, args.database)
    products = [{
        "key": f"{slug}|{external}", "brand": slug, "title": title, "type": kind,
        "tags": [t for t in tags.split("|") if t], "price": float(price) if price else None,
        "currency": currency, "summary": summary, "colours": [c for c in colours.split("|") if c],
    } for slug, external, title, kind, tags, price, currency, summary, colours in rows]
    with open(CATALOGUE, "w") as f:
        json.dump(products, f)
    print(f"{len(products)} products -> {CATALOGUE}")


# MARK: - Judging

def tokens(text):
    return set(re.findall(r"[a-z0-9]+", text.lower().replace("-", " ")))


class P:
    """One product, as the judge reads it — every field, and the description too, because a
    person deciding whether a product answers a search reads the page, not only the title."""

    def __init__(self, raw):
        self.raw = raw
        self.title = tokens(raw["title"])
        self.type = tokens(raw["type"])
        self.tags = tokens(" ".join(raw["tags"]))
        self.colour = tokens(" ".join(raw["colours"])) | self.title
        self.summary = tokens(raw["summary"])
        self.everything = self.title | self.type | self.tags | self.summary
        self.price = raw["price"]
        self.brand = raw["brand"]

    def named(self, *words):
        """What it is: the title or the type says so."""
        return any(w in self.title or w in self.type for w in words)

    def says(self, *words):
        """Anywhere on the product: title, type, tags or description."""
        return any(w in self.everything for w in words)

    def filed(self, *words):
        """In what the shop calls and files it — title, type, tags — and not the description,
        for the words a care label or a brand story uses about everything ("garment", "gift")."""
        return any(w in self.title or w in self.type or w in self.tags for w in words)

    def coloured(self, *words):
        """In its name or a colourway, or filed under it ("Colour_Black", "colorgroup-black")."""
        filed = {t.lower() for t in self.raw["tags"]}
        return any(w in self.colour or f"colour_{w}" in filed or f"colorgroup-{w}" in filed for w in words)

    def under(self, amount):
        return self.price is not None and self.price <= amount

    def over(self, amount):
        return self.price is not None and self.price >= amount


TOPS_KNIT = ("sweater", "sweaters", "jumper", "jumpers", "knit", "knitwear", "cardigan", "pullover", "crewneck", "crew")
SHOES = ("shoe", "shoes", "sneaker", "sneakers", "trainer", "trainers", "loafer", "loafers", "boot", "boots",
         "footwear", "sandal", "sandals", "mule", "mules", "derby", "slide", "slides", "runner")
JACKETS = ("jacket", "jackets", "blazer", "blazers", "coat", "coats", "outerwear", "overshirt", "parka",
           "blouson", "anorak", "bomber", "gilet", "vest", "chore", "trucker", "shacket")
TROUSERS = ("trouser", "trousers", "pant", "pants", "chino", "chinos", "jean", "jeans", "denim", "slacks")
HATS = ("cap", "caps", "hat", "hats", "headwear", "beanie", "beanies", "bucket", "trucker")

# One judge per query id: what a person would accept as an answer to it. Written from the
# query's meaning, not from the grammar — "pullover" is a sweater, "something for a wedding" is
# tailoring, a shirt and tie or a dress — and checked by reading the pooled top tens of every
# variant (`run --pool`), with the misjudged corrected here rather than in the JSON.
JUDGES = {
    "black-hoodie": lambda p: p.named("hoodie", "hoodies", "hood", "hooded", "hoody") and p.coloured("black"),
    "white-tshirt": lambda p: p.named("tee", "tees", "t", "tshirt", "tshirts") and p.coloured("white"),
    "navy-blazer": lambda p: p.named("blazer", "blazers", "jacket") and p.coloured("navy") and p.says("blazer", "tailoring", "sartorial", "games"),
    "linen-shirt": lambda p: p.named("shirt", "shirts", "overshirt") and p.says("linen"),
    "chore-jacket": lambda p: p.named("chore") or (p.named("jacket", "coat") and p.says("chore", "workwear", "work")),
    "denim-jacket": lambda p: p.named("jacket", "trucker", "chore", "overshirt") and p.says("denim"),
    "loafers": lambda p: p.named("loafer", "loafers", "penny"),
    "silk-tie": lambda p: p.named("tie", "ties") and p.says("silk"),
    "wool-scarf": lambda p: p.named("scarf", "scarves") and p.says("wool", "merino", "lambswool", "cashmere"),
    "cashmere-sweater": lambda p: p.named(*TOPS_KNIT, "hoodie", "polo") and p.says("cashmere"),
    "leather-bag": lambda p: p.named("bag", "bags", "tote", "handbag", "handbags", "crossbody", "clutch", "backpack", "pouch", "shoulder") and p.says("leather"),
    "summer-dress": lambda p: p.named("dress", "dresses") and (p.says("linen", "cotton", "summer", "poplin", "sundress", "mini", "eyelet", "gauze") or "su26" in p.tags),
    "swimsuit": lambda p: p.named("swim", "swimsuit", "bikini", "trunks", "trunk", "swimwear", "one", "piece") and p.says("swim", "swimwear", "bikini", "trunks"),
    "sunglasses": lambda p: p.named("sunglasses", "sunglass", "shades"),
    "baseball-cap": lambda p: p.named("cap", "caps", "baseball") and not p.named("beanie", "bucket"),
    "beanie": lambda p: p.named("beanie", "beanies", "toque"),
    "socks": lambda p: p.named("sock", "socks"),
    "cargo-pants": lambda p: p.named("cargo", "cargos") and p.named(*TROUSERS, "cargo", "cargos"),
    "black-jeans": lambda p: p.named("jean", "jeans", "denim") and p.named(*TROUSERS) and p.coloured("black"),
    "sneakers-white": lambda p: JUDGES["trainers"](p) and p.coloured("white"),
    "trousers-under-200": lambda p: p.named(*TROUSERS) and not p.named("shorts", "short") and p.under(200),
    "dress-under-300": lambda p: p.named("dress", "dresses") and p.under(300),
    "hoodie-under-100": lambda p: p.named("hoodie", "hoodies", "hood", "hooded") and p.under(100),
    "blazer-over-800": lambda p: p.named("blazer", "blazers", "sport", "games", "sartorial") and p.says("blazer", "jacket") and p.over(800),
    "tee-30-60": lambda p: p.named("tee", "tees", "tshirt", "t") and p.price is not None and 30 <= p.price <= 60,
    "sweater-no-wool": lambda p: p.named(*TOPS_KNIT) and not p.says("wool", "merino", "lambswool", "shetland", "cashmere"),
    "jacket-no-leather": lambda p: p.named(*JACKETS) and not p.says("leather", "suede"),
    "shirt-no-stripes": lambda p: p.named("shirt", "shirts") and not p.named("tshirt", "t", "sweatshirt") and not p.says("stripe", "stripes", "striped", "stripe"),
    "tie-no-silk": lambda p: p.named("tie", "ties") and not p.says("silk"),
    "drakes-tie": lambda p: p.brand == "drakes.com" and p.named("tie", "ties"),
    "ald-hat": lambda p: p.brand == "aimeleondore.com" and p.named(*HATS),
    "stussy-fleece": lambda p: p.brand == "stussy.com" and p.says("fleece", "sherpa", "polar"),
    "noah-rugby": lambda p: p.brand == "noahny.com" and p.says("rugby"),
    "bbc-hoodie": lambda p: p.brand == "bbcicecream.com" and p.named("hoodie", "hoodies", "hood", "hooded"),
    "cs-hoodie": lambda p: p.brand == "colorfulstandard.com" and p.named("hoodie", "hood", "hooded"),
    # German "Pullover" is a knitted sweater — not a cardigan, which opens, and not a sweatshirt.
    "pullover": lambda p: p.named("sweater", "sweaters", "jumper", "jumpers", "knit", "knitwear", "pullover", "crewneck")
        and not p.named("cardigan", "vest", "polo", "tee", "shirt", "socks", "sock", "beanie", "scarf", "hat", "hats", "cap", "tie",
                        "sweatshirt", "sweatshirts", "sweatpants", "jacket", "thermal", "fleece", "headwear", "t", "tshirts", "jerseys",
                        "shirts", "kids"),
    "green-jumper": lambda p: p.named(*TOPS_KNIT) and p.coloured("green", "olive", "forest", "sage", "khaki"),
    "trainers": lambda p: p.named("sneaker", "sneakers", "trainer", "trainers")
        or (p.named("footwear", "shoe", "shoes") and not p.named("loafer", "loafers", "derby", "boot", "boots", "sandal", "slide", "slipper", "clog", "mule", "heel", "flat")
            and p.says("sneaker", "sneakers", "trainer", "trainers", "running", "runner", "suede", "court", "samba", "superstar", "gazelle", "balance")),
    "polo-shirt": lambda p: p.named("polo", "polos"),
    "office-shoes": lambda p: p.named(*SHOES, "shoe", "derby", "monk", "brogue", "heel", "pump")
        and (p.named("loafer", "loafers", "derby", "oxford", "brogue", "penny", "monk", "heel", "pump", "slingback")
             or (p.says("leather", "suede") and p.named("shoe", "shoes")))
        and not p.named("sneaker", "sneakers", "trainer", "trainers", "slipper", "balance", "clog", "sandal", "thong", "slide", "runner", "boot", "boots"),
    "rain-jacket": lambda p: p.named(*JACKETS) and not p.named("vest", "gilet", "blazer", "blazers", "tailored")
        and (p.says("rain", "waterproof") or p.filed("nylon", "waxed", "wax", "shell", "anorak", "parka", "mac", "coaches", "gore", "ripstop", "windbreaker")),
    "smart-summer-jacket": lambda p: p.named("blazer", "blazers", "jacket", "jackets")
        and p.filed("linen", "seersucker", "summer", "lightweight", "unstructured", "silk", "madras", "fresco", "tropical")
        and p.filed("blazer", "tailored", "tailoring", "sartorial", "games", "suit", "sport"),
    # A guest's outfit: tailoring, a formal shirt, a silk tie or pocket square, a dress that is
    # long, silk or satin.
    "wedding": lambda p: (p.named("suit", "blazer", "tuxedo") and p.says("tailoring", "sartorial", "games", "suit", "blazer"))
        or (p.named("shirt") and "formal" in p.type)
        or (p.named("tie", "ties", "pocket") and p.says("silk"))
        or (p.named("dress", "dresses", "gown") and p.says("midi", "maxi", "satin", "silk", "evening", "gown", "column")),
    "beach-holiday": lambda p: p.says("swim", "swimwear", "bikini", "trunks", "towel", "sandal", "sandals", "beach", "linen", "shorts", "sunglasses", "slide", "slides") and not p.named("boot", "boots", "coat", "parka", "beanie", "scarf"),
    "cosy-winter-knit": lambda p: p.named(*TOPS_KNIT) and not p.named("cap", "skullcap", "beanie", "hat", "scarf", "socks", "sock", "short", "shorts", "tie", "polo", "tee") and p.says("wool", "merino", "cashmere", "lambswool", "shetland", "mohair", "alpaca", "fleece", "chunky", "cable", "heavyweight", "aran", "fair", "isle"),
    "minimal-basics": lambda p: p.named("tee", "tees", "tshirt", "t", "tank", "crew", "crewneck", "sweatpants", "sweatshirt", "hoodie", "hood", "boxer", "boxers", "socks", "sock")
        and p.filed("basic", "basics", "essential", "essentials", "classic", "plain", "blank")
        and not p.says("graphic", "print", "printed", "slogan", "camo", "floral"),
    "preppy": lambda p: p.named("oxford", "rugby", "polo", "cardigan", "blazer", "chino", "chinos", "loafer", "loafers", "cable", "argyle", "repp", "regimental", "button", "sweater", "vest") and p.says("oxford", "rugby", "polo", "cardigan", "blazer", "chino", "chinos", "loafer", "cable", "argyle", "repp", "regimental", "buttondown", "button", "stripe", "striped", "cricket", "varsity", "collegiate", "ivy"),
    "workwear": lambda p: p.filed("workwear", "chore", "carpenter", "painter", "canvas", "duck", "utility", "work", "workgear", "fatigue")
        and p.named(*JACKETS, *TROUSERS, "overalls", "overall", "shirt", "overshirt") and not p.named("blazer", "tailored"),
    "oversized-tee": lambda p: p.named("tee", "tees", "tshirt", "t") and p.says("oversized", "boxy", "relaxed", "loose", "heavyweight", "wide"),
    # Menswear that is given: a shop's own gifting collection, or the things people give.
    "gift-for-dad": lambda p: p.brand != "staud.clothing" and not p.filed("kids", "female", "women", "womens")
        and (p.filed("gift", "gifting", "gifts") or p.named("tie", "ties", "scarf", "scarves", "wallet", "pocket", "belt", "gloves")),
    "vintage-wash": lambda p: p.filed("vintage", "washed", "faded", "distressed", "pigment", "overdyed", "acid", "stonewash", "sunfaded"),
    "bermuda-shorts": lambda p: p.named("shorts", "short", "bermuda", "bermudas") and not p.named("sleeve", "tee", "shirt", "sock", "socks", "skirt"),
    "brown-suede": lambda p: p.says("suede") and p.coloured("brown", "tan", "chocolate", "espresso", "snuff", "tobacco", "coffee"),
}


def judge(args):
    with open(QUERIES) as f:
        queries = json.load(f)
    with open(CATALOGUE) as f:
        products = [P(raw) for raw in json.load(f)]
    out = {"judged_on": args.date, "relevant": {}}
    missing = [q["id"] for q in queries if q["id"] not in JUDGES]
    if missing:
        sys.exit(f"no judge for {missing}")
    for query in queries:
        rule = JUDGES[query["id"]]
        keys = sorted(p.raw["key"] for p in products if rule(p))
        keys = sorted((set(keys) | set(query.get("include", []))) - set(query.get("exclude", [])))
        out["relevant"][query["id"]] = keys
        print(f"{query['id']:22} {len(keys):5} relevant")
    with open(JUDGEMENTS, "w") as f:
        json.dump(out, f, indent=1, sort_keys=True)


# MARK: - Running

def call(base, method, path, token=None, body=None):
    request = urllib.request.Request(
        f"{base}{path}", method=method,
        data=json.dumps(body).encode() if body is not None else None,
        headers={"content-type": "application/json",
                 **({"authorization": f"Bearer {token}"} if token else {})})
    with urllib.request.urlopen(request, timeout=60) as response:
        data = response.read()
        return json.loads(data) if data else None


def reader(base):
    """A device of its own that follows `FOLLOWED`, so a run never moves somebody's follows."""
    token = call(base, "POST", "/v1/devices", body={"country": "DE"})["token"]
    brands = call(base, "GET", "/v1/brands?q=", token)
    for brand in brands:
        if brand["slug"] in FOLLOWED:
            call(base, "POST", "/v1/follows", token, {"brandID": brand["id"]})
    return token


def ranked(base, token, text, params, depth):
    """The keys a search shows, in the order it shows them: the main list, page by page, then
    the partial matches under it. And how many of the main list were matched by meaning."""
    keys, meaning, cursor = [], 0, None
    partial = []
    while len(keys) < depth:
        query = {"q": text, "limit": "100", **params}
        if cursor:
            query["cursor"] = cursor
        answer = call(base, "GET", "/v1/products/search?" + urllib.parse.urlencode(query), token)
        for hit in answer["exact"]:
            keys.append(f"{hit['card']['brand']['slug']}|{hit['card']['productExternalID']}")
            meaning += 1 if hit.get("byMeaning") else 0
        if not cursor:
            partial = [f"{h['card']['brand']['slug']}|{h['card']['productExternalID']}" for h in answer["partial"]]
        cursor = answer.get("nextCursor")
        if not cursor:
            break
    return (keys + partial)[:depth], meaning


def metrics(shown, relevant, k=10, depth=100):
    """P@k, nDCG@k and the reciprocal rank of the first right answer; and recall in the first
    `depth`, out of at most `depth` — a vague search judged to have nine hundred answers cannot
    show more than a hundred, and is not a worse search for it."""
    hits = [key in relevant for key in shown]
    precision = sum(hits[:k]) / k
    recall = sum(hits[:depth]) / min(len(relevant), depth) if relevant else None
    dcg = sum(1 / math.log2(i + 2) for i, hit in enumerate(hits[:k]) if hit)
    ideal = sum(1 / math.log2(i + 2) for i in range(min(k, len(relevant))))
    first = next((i + 1 for i, hit in enumerate(hits) if hit), None)
    return {"p10": precision, "r100": recall, "ndcg10": dcg / ideal if ideal else None,
            "rr": 1 / first if first else 0.0}


def run(args):
    with open(QUERIES) as f:
        queries = json.load(f)
    with open(JUDGEMENTS) as f:
        judged = json.load(f)
    present = None
    if os.path.exists(CATALOGUE):
        with open(CATALOGUE) as f:
            present = {p["key"] for p in json.load(f)}
    token = reader(args.base)
    report, pool = {}, {}
    for variant in args.variants:
        params = VARIANTS[variant]
        rows = []
        for query in queries:
            relevant = set(judged["relevant"].get(query["id"], []))
            if present is not None:
                relevant &= present
            shown, meaning = ranked(args.base, token, query["text"], params, args.depth)
            pool.setdefault(query["id"], {})[variant] = shown[:10]
            rows.append({"id": query["id"], "kind": query["kind"], "relevant": len(relevant),
                         "shown": len(shown), "meaning": meaning, **metrics(shown, relevant, depth=args.depth)})
        report[variant] = rows

    def mean(rows, key):
        values = [r[key] for r in rows if r[key] is not None]
        return sum(values) / len(values) if values else float("nan")

    kinds = sorted({q["kind"] for q in queries})
    print(f"\n{len(queries)} queries · depth {args.depth} · followed {', '.join(FOLLOWED)}\n")
    print(f"{'variant':12} {'P@10':>6} {'R@' + str(args.depth):>6} {'nDCG@10':>8} {'MRR':>6} {'empty':>6} {'by meaning':>11}")
    for variant, rows in report.items():
        empty = sum(1 for r in rows if r["shown"] == 0)
        print(f"{variant:12} {mean(rows, 'p10'):6.3f} {mean(rows, 'r100'):6.3f} {mean(rows, 'ndcg10'):8.3f} "
              f"{mean(rows, 'rr'):6.3f} {empty:6} {sum(r['meaning'] for r in rows):11}")
    print("\nP@10 by kind of search:")
    print(f"{'kind':16}" + "".join(f"{v:>12}" for v in report))
    for kind in kinds:
        print(f"{kind:16}" + "".join(f"{mean([r for r in rows if r['kind'] == kind], 'p10'):12.3f}" for rows in report.values()))
    if args.per_query:
        print("\nP@10 / R per query:")
        for index, query in enumerate(queries):
            cells = "".join(f"  {report[v][index]['p10']:.1f}/{(report[v][index]['r100'] or 0):.2f}" for v in report)
            print(f"{query['id']:22}{cells}")
    if args.out:
        with open(args.out, "w") as f:
            json.dump({"report": report, "pool": pool}, f, indent=1)


# MARK: - Thresholds

# `ShopQuery`'s own lists, so a query is embedded here as the server embeds it
# (`ProductSearch.embeddingText`): its words to find, never a stop word, a ruled-out word, a price
# or a leaning — and "formal" when a leaning word asked for it. Checked against the Swift by the
# queries in this file; a new query that leans on more of the grammar should be checked too.
STOPWORDS = set("""a an the some something anything any for in on of to with and or i im me my mine
    want wants need needs looking look find show get buy please like would could can that this these
    those is are be it its one ones nice good great really very pretty kind sort thing things stuff
    piece pieces item items wear wearing go goes which what around about roughly approximately ish
    price priced cost costs costing spend new maybe also just too much at under below over above max
    maximum min minimum within upto than least most from between up""".split())
NEGATIONS = {"no", "not", "without", "non", "never", "except", "dont", "nothing"}
FORMAL = {"formal", "smart", "smarter", "dressy", "dressier", "elegant", "dressed"}
CHEAP = {"cheap", "cheaper", "cheapest", "affordable", "inexpensive", "bargain", "budget"}


def embedded_text(text):
    words = re.findall(r"[a-z0-9]+(?:-[a-z0-9]+)*", text.lower())
    out, formal, skip = [], False, False
    for word in words:
        if word in NEGATIONS:
            skip = True
            continue
        if word in FORMAL:
            formal = True
            continue
        if word in CHEAP or word in STOPWORDS or word.isdigit():
            continue
        if skip:
            skip = False
            continue
        out.append(word)
    return " ".join(out + (["formal"] if formal else []))


def thresholds(args):
    """How close the products the words did not find are to each query, read against the
    judgements — the bar a product must clear to be a result by meaning is chosen from this.

    Only what meaning would *add* is counted: a product the word search already returns for the
    query is a result either way, and counting it would flatter every bar."""
    with open(QUERIES) as f:
        queries = json.load(f)
    with open(JUDGEMENTS) as f:
        judged = json.load(f)
    token = reader(args.base)
    texts = [embedded_text(q["text"]) for q in queries]
    request = urllib.request.Request(
        f"{args.sidecar}/embed/text", method="POST", data=json.dumps({"texts": texts}).encode(),
        headers={"content-type": "application/json", "authorization": f"Bearer {os.environ['EMBEDDING_TOKEN']}"})
    with urllib.request.urlopen(request, timeout=120) as response:
        answer = json.load(response)
    model = answer["model"]
    pairs = []  # (similarity, relevant, query, the words found little)
    for query, text, vector in zip(queries, texts, answer["vectors"]):
        words, _ = ranked(args.base, token, query["text"], VARIANTS["after-words"], 1000)
        found = set(words)
        little = len(words) < args.little
        literal = "[" + ",".join(f"{x:.6f}" for x in vector) + "]"
        rows = psql(f"""
            SELECT b.slug || '|' || p.external_id,
                   1 - (e.text_embedding::vector({len(vector)}) <=> '{literal}'::vector({len(vector)}))
            FROM product_embeddings e JOIN products p ON p.id = e.product_id JOIN brands b ON b.id = p.brand_id
            WHERE e.model = '{model}' AND p.kind = 'product' AND p.unlisted_at IS NULL
              AND p.storefront_id IS NULL AND cardinality(p.image_urls) > 0
            ORDER BY 2 DESC LIMIT 100
            """, args.database)
        relevant = set(judged["relevant"].get(query["id"], []))
        for key, similarity in rows:
            if key not in found:
                pairs.append((float(similarity), key in relevant, query["id"], little))
    print(f"model {model}; of each query's 100 nearest products, those its words did not find")
    print(f"'little': the {len({p[2] for p in pairs if p[3]})} queries whose words found fewer than {args.little}\n")
    print(f"{'bar':>6} {'added':>7} {'relevant':>9} {'precision':>10} {'queries':>8}   "
          f"{'little: added':>13} {'relevant':>9} {'precision':>10}")
    for step in range(50, 92, 2):
        bar = step / 100
        admitted = [p for p in pairs if p[0] >= bar]
        good = sum(1 for p in admitted if p[1])
        reached = len({p[2] for p in admitted})
        precision = good / len(admitted) if admitted else float("nan")
        few = [p for p in admitted if p[3]]
        few_good = sum(1 for p in few if p[1])
        print(f"{bar:6.2f} {len(admitted):7} {good:9} {precision:10.3f} {reached:8}   "
              f"{len(few):13} {few_good:9} {few_good / len(few) if few else float('nan'):10.3f}")
    if args.per_query:
        print("\nper query at each bar: added (relevant)")
        for query in queries:
            mine = [p for p in pairs if p[2] == query["id"]]
            cells = "".join(f" {sum(1 for p in mine if p[0] >= b / 100):3}({sum(1 for p in mine if p[0] >= b / 100 and p[1]):2})"
                            for b in range(60, 82, 4))
            print(f"{query['id']:22}{cells}")


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--base", default="http://127.0.0.1:8091")
    parser.add_argument("--database", default="postgres://streetw@127.0.0.1:5471/streetw_eval")
    parser.add_argument("--sidecar", default="http://127.0.0.1:8095")
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("dump")
    j = sub.add_parser("judge")
    j.add_argument("--date", required=True, help="the day the catalogue was read, for the record")
    r = sub.add_parser("run")
    r.add_argument("variants", nargs="+", choices=sorted(VARIANTS))
    r.add_argument("--depth", type=int, default=100)
    r.add_argument("--per-query", action="store_true")
    r.add_argument("--out", help="write every row, and each variant's top ten for pooling, here")
    t = sub.add_parser("thresholds")
    t.add_argument("--per-query", action="store_true")
    t.add_argument("--little", type=int, default=12, help="what counts as the words finding little")
    args = parser.parse_args()
    for name in ("base", "database", "sidecar"):
        value = getattr(args, name)
        if "127.0.0.1" not in value and "localhost" not in value:
            sys.exit(f"--{name} {value} is not local; the eval never runs against a deployment")
    {"dump": dump, "judge": judge, "run": run, "thresholds": thresholds}[args.command](args)


if __name__ == "__main__":
    main()

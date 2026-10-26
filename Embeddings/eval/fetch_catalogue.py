"""Fetch a few pages of public Shopify catalogues for the embedding eval.

Polite by construction, the way the app fetches: robots.txt is obeyed for our own
User-Agent, requests to a host are spaced by INTERVAL seconds, and the User-Agent is the
app's own honest one. Output goes to a directory outside the repo; only the manifest that
`build_eval.py` derives from it is committed.

    python fetch_catalogue.py /tmp/p3embed/data
"""

import json
import sys
import time
import urllib.request
import urllib.robotparser
from pathlib import Path

USER_AGENT = "Dropwall/1.0 (+https://github.com/Hottorun/streetwear)"
INTERVAL = 2.0
PAGES = 2
PER_PAGE = 250

# Starter-pack brands that serve /products.json and whose robots.txt allows it for our
# User-Agent. Carhartt WIP (no Shopify JSON; the server reads its sitemap) and Princess
# Polly (robots.txt disallows /products.json) were asked for and are deliberately absent.
HOSTS = [
    "kith.com",
    "staud.clothing",
    "www.aimeleondore.com",
    "www.drakes.com",
    "faithfullthebrand.com",
]


def get(url: str) -> bytes:
    req = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    with urllib.request.urlopen(req, timeout=30) as resp:
        return resp.read()


def main(out_dir: Path) -> None:
    out_dir.mkdir(parents=True, exist_ok=True)
    for host in HOSTS:
        robots = urllib.robotparser.RobotFileParser()
        robots.parse(get(f"https://{host}/robots.txt").decode("utf-8", "replace").splitlines())
        time.sleep(INTERVAL)
        products = []
        for page in range(1, PAGES + 1):
            url = f"https://{host}/products.json?limit={PER_PAGE}&page={page}"
            if not robots.can_fetch(USER_AGENT, url):
                print(f"{host}: robots.txt disallows {url}, skipping")
                break
            batch = json.loads(get(url))["products"]
            time.sleep(INTERVAL)
            products.extend(batch)
            print(f"{host} page {page}: {len(batch)} products", flush=True)
            if len(batch) < PER_PAGE:
                break
        (out_dir / f"{host}.json").write_text(json.dumps(products))


if __name__ == "__main__":
    main(Path(sys.argv[1] if len(sys.argv) > 1 else "/tmp/p3embed/data"))

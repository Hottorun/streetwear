"""CPU latency and memory for one model, one thread count, one process.

    python bench.py <model> <threads> <image-dir> [results.json]

Images come from the eval cache, so the timings include real decode and preprocess,
not just the forward pass. Median of several runs after a warm-up.
"""

import json
import resource
import statistics
import sys
import time
from pathlib import Path

import psutil
import torch
from PIL import Image

from run_eval import Encoder

RUNS = 7


def rss_mb() -> int:
    # ru_maxrss is bytes on macOS, kilobytes on Linux.
    scale = 2**20 if sys.platform == "darwin" else 2**10
    return round(resource.getrusage(resource.RUSAGE_SELF).ru_maxrss / scale)


def timed(fn, runs=RUNS):
    fn()
    samples = []
    for _ in range(runs):
        t = time.perf_counter()
        fn()
        samples.append(time.perf_counter() - t)
    return round(statistics.median(samples) * 1000, 1)


def main(name: str, threads: int, image_dir: Path, out: Path | None) -> None:
    torch.set_num_threads(threads)
    t = time.perf_counter()
    enc = Encoder(name)
    load_s = round(time.perf_counter() - t, 1)
    after_load = rss_mb()

    paths = sorted(image_dir.glob("*.img"))[:32]
    images = [Image.open(p).convert("RGB") for p in paths]
    texts = ["olive canvas chore coat", "black wool beanie", "white leather sneakers",
             "navy pinstripe blazer"] * 8

    result = {
        "model": name,
        "threads": threads,
        "load_s": load_s,
        "rss_after_load_mb": after_load,
        "image_1_ms": timed(lambda: enc.images(images[:1])),
        "image_8_ms": timed(lambda: enc.images(images[:8])),
        "image_32_ms": timed(lambda: enc.images(images[:32]), runs=3),
        "text_1_ms": timed(lambda: enc.texts(texts[:1])),
        "text_32_ms": timed(lambda: enc.texts(texts[:32])),
    }
    result["image_per_s_batched"] = round(32 / (result["image_32_ms"] / 1000), 1)
    result["peak_rss_mb"] = rss_mb()
    # Peak includes the transient second copy of the weights while loading; this is what
    # the process holds once serving.
    result["steady_rss_mb"] = round(psutil.Process().memory_info().rss / 2**20)
    print(json.dumps(result), flush=True)
    if out:
        rows = json.loads(out.read_text()) if out.exists() else []
        rows.append(result)
        out.write_text(json.dumps(rows, indent=1))


if __name__ == "__main__":
    main(sys.argv[1], int(sys.argv[2]), Path(sys.argv[3]),
         Path(sys.argv[4]) if len(sys.argv) > 4 else None)

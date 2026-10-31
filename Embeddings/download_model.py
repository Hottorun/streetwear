"""Download one pinned model into a directory, so the service never reaches Hugging Face
at boot. Run at image build time.

    python download_model.py /models/embedding                     # the default
    python download_model.py /models/embedding Marqo/marqo-fashionSigLIP \\
        c56244cc94f92419e8369fa71efdaf403b124ce8

The default is Marqo FashionCLIP, chosen on the search eval over FashionSigLIP v1 and seven
others (README.md, "Choosing the model"). FashionSigLIP v1 and a third party's SigLIP2
fine-tune stay available, all three Apache-2.0 — read that section before switching.

Only models listed in MODELS can be downloaded, each with the loader that reads it and the
files it needs, and only at a full commit hash: a branch name is not a pin, and a revision
that moved would put vectors from another model under the same id.
"""

import json
import re
import sys
from pathlib import Path

from huggingface_hub import snapshot_download

DEFAULT_REPO = "Marqo/marqo-fashionCLIP"
DEFAULT_REVISION = "44f4c655124ed71e90cbf528d82f508d69d8a81b"

MODELS = {
    # open_clip checkpoint, ViT-B/16 CLIP, 512-d. Its config names no Hugging Face tokenizer,
    # so open_clip reads it with the CLIP byte-pair tokenizer it ships with: nothing else to
    # fetch. The repo's tokenizer.json and vocab.json serve its transformers loader, not this.
    "Marqo/marqo-fashionCLIP": {
        "loader": "open_clip",
        "files": ["open_clip_config.json", "open_clip_model.safetensors"],
    },
    # open_clip checkpoint. The tokenizer comes from the base SigLIP repo, because that is
    # the one the Marqo config names and so the one `hf-hub:Marqo/marqo-fashionSigLIP` loads:
    # using the copy in Marqo's own repo would be a second, unverified path to the same ids.
    "Marqo/marqo-fashionSigLIP": {
        "loader": "open_clip",
        "files": ["open_clip_config.json", "open_clip_model.safetensors"],
        "tokenizer": ("timm/ViT-B-16-SigLIP", "41f575766f40e752fdd1383e9565b7f02388c1c4",
                      ["tokenizer.json", "tokenizer_config.json", "special_tokens_map.json"]),
    },
    # A transformers SiglipModel: 384 px images, 64-token text, 768-d. Not Marqo's.
    "srpone/zooclaw-fashionsiglip2": {
        "loader": "transformers",
        "files": ["config.json", "model.safetensors", "preprocessor_config.json",
                  "special_tokens_map.json", "tokenizer.json", "tokenizer.model",
                  "tokenizer_config.json"],
    },
}

_COMMIT = re.compile(r"[0-9a-f]{40}")


def validate(repo: str, revision: str) -> dict:
    if repo not in MODELS:
        raise SystemExit(f"{repo} is not a known model; add it to MODELS with its loader and files. "
                         f"Known: {', '.join(sorted(MODELS))}")
    if not _COMMIT.fullmatch(revision):
        raise SystemExit(f"revision must be a full 40-character commit hash, not {revision!r}")
    return MODELS[repo]


def main(dest: Path, repo: str = DEFAULT_REPO, revision: str = DEFAULT_REVISION) -> None:
    spec = validate(repo, revision)
    dest.mkdir(parents=True, exist_ok=True)
    snapshot_download(repo, revision=revision, local_dir=dest, allow_patterns=spec["files"])
    if "tokenizer" in spec:
        tokenizer_repo, tokenizer_revision, files = spec["tokenizer"]
        snapshot_download(tokenizer_repo, revision=tokenizer_revision, local_dir=dest,
                          allow_patterns=files)
    missing = [name for name in spec["files"] if not (dest / name).exists()]
    if missing:
        raise SystemExit(f"{repo}@{revision} has no {', '.join(missing)}")
    (dest / "model.json").write_text(json.dumps(
        {"repo": repo, "revision": revision, "loader": spec["loader"]}))


if __name__ == "__main__":
    # Empty arguments mean the default, so a Docker build argument left blank is not an error.
    args = [a for a in sys.argv[1:] if a]
    if not args or len(args) == 2 or len(args) > 3:
        sys.exit(__doc__)
    main(Path(args[0]), *args[1:])

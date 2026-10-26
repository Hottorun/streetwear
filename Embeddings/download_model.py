"""Download one pinned model into a directory, so the service never reaches Hugging Face
at boot. Run at image build time.

    python download_model.py /models/embedding                     # the default
    python download_model.py /models/embedding srpone/zooclaw-fashionsiglip2 \\
        d2c0c98de9cd1e27c114267ddfbb584eb98b5ebf

The default is Marqo FashionSigLIP v1. Marqo publishes FashionSigLIP 2 only commercially
(the v1 card says "Contact Marqo"); v1 is Apache-2.0. The alternative is a third party's
SigLIP2 fine-tune, Apache-2.0 too — see "Choosing the model" in README.md before switching.

Only models listed in MODELS can be downloaded, each with the loader that reads it and the
files it needs, and only at a full commit hash: a branch name is not a pin, and a revision
that moved would put vectors from another model under the same id.
"""

import json
import re
import sys
from pathlib import Path

from huggingface_hub import snapshot_download

DEFAULT_REPO = "Marqo/marqo-fashionSigLIP"
DEFAULT_REVISION = "c56244cc94f92419e8369fa71efdaf403b124ce8"

MODELS = {
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

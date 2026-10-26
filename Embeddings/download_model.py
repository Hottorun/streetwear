"""Download the pinned model into a directory, so the service never reaches Hugging Face
at boot. Run at image build time.

    python download_model.py /models/fashionsiglip

Marqo publishes FashionSigLIP 2 only commercially (the v1 card says "Contact Marqo"), so
this is v1, Apache-2.0. The tokenizer comes from the base SigLIP repo, because that is the
one the Marqo config names and so the one `hf-hub:Marqo/marqo-fashionSigLIP` loads: using
the copy in Marqo's own repo would be a second, unverified path to the same token ids.
"""

import json
import sys
from pathlib import Path

from huggingface_hub import snapshot_download

MODEL_REPO = "Marqo/marqo-fashionSigLIP"
MODEL_REVISION = "c56244cc94f92419e8369fa71efdaf403b124ce8"
TOKENIZER_REPO = "timm/ViT-B-16-SigLIP"
TOKENIZER_REVISION = "41f575766f40e752fdd1383e9565b7f02388c1c4"


def main(dest: Path) -> None:
    dest.mkdir(parents=True, exist_ok=True)
    snapshot_download(MODEL_REPO, revision=MODEL_REVISION, local_dir=dest,
                      allow_patterns=["open_clip_config.json", "open_clip_model.safetensors"])
    snapshot_download(TOKENIZER_REPO, revision=TOKENIZER_REVISION, local_dir=dest,
                      allow_patterns=["tokenizer.json", "tokenizer_config.json",
                                      "special_tokens_map.json"])
    (dest / "model.json").write_text(json.dumps({"repo": MODEL_REPO, "revision": MODEL_REVISION}))


if __name__ == "__main__":
    main(Path(sys.argv[1]))

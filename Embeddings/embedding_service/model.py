"""The model: loaded once, in eval mode, and only ever run under inference_mode."""

import io
import json
import warnings
from pathlib import Path
from typing import Protocol

from PIL import Image

# A small file can still decode to a huge bitmap. Refuse anything past ~40 megapixels
# outright, rather than letting Pillow merely warn on its way to allocating it.
Image.MAX_IMAGE_PIXELS = 40_000_000


class UnreadableImage(Exception):
    pass


def decode(data: bytes) -> Image.Image:
    with warnings.catch_warnings():
        warnings.simplefilter("error", Image.DecompressionBombWarning)
        try:
            image = Image.open(io.BytesIO(data))
            image.load()
        except (Image.DecompressionBombError, Image.DecompressionBombWarning) as error:
            raise UnreadableImage("image dimensions are too large") from error
        except Exception as error:
            raise UnreadableImage("not a readable image") from error
    return image.convert("RGB")


class Embedder(Protocol):
    model_id: str
    dimension: int

    def embed_texts(self, texts: list[str]) -> list[list[float]]: ...

    def embed_images(self, images: list[Image.Image]) -> list[list[float]]: ...


class OpenCLIPEmbedder:
    """An open_clip checkpoint laid out by download_model.py.

    `model_id` names the repository *and* the revision, because it is stored beside every
    vector: two revisions of one model do not share an embedding space, and a vector from
    one compared against a query from the other is noise that looks like a ranking.
    """

    def __init__(self, model_dir: Path, *, threads: int, batch_size: int):
        import open_clip
        import torch

        torch.set_num_threads(threads)
        torch.set_num_interop_threads(1)
        self.torch = torch
        self.batch_size = batch_size

        meta = json.loads((model_dir / "model.json").read_text())
        self.model_id = f"{meta['repo']}@{meta['revision'][:12]}"
        source = f"local-dir:{model_dir}"
        self.model, _, self.preprocess = open_clip.create_model_and_transforms(source)
        self.tokenizer = open_clip.get_tokenizer(source)
        self.model.eval()
        with torch.inference_mode():
            self.dimension = int(self.model.encode_text(self.tokenizer(["warm up"])).shape[-1])

    def _batched(self, items, run):
        torch = self.torch
        out = []
        with torch.inference_mode():
            for start in range(0, len(items), self.batch_size):
                vectors = run(items[start:start + self.batch_size])
                out.extend(torch.nn.functional.normalize(vectors, dim=-1).tolist())
        return out

    def embed_texts(self, texts: list[str]) -> list[list[float]]:
        return self._batched(texts, lambda chunk: self.model.encode_text(self.tokenizer(chunk)))

    def embed_images(self, images: list[Image.Image]) -> list[list[float]]:
        torch = self.torch
        return self._batched(
            images,
            lambda chunk: self.model.encode_image(torch.stack([self.preprocess(i) for i in chunk])),
        )

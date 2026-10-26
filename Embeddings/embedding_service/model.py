"""The model: loaded once, in eval mode, and only ever run under inference_mode.

Which model is in the image is decided at build time (`download_model.py`), and `model.json`
beside the weights says which loader reads it. Both loaders name the model the same way,
`repo@revision[:12]`, because that id is stored beside every vector.
"""

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


def model_id(meta: dict) -> str:
    return f"{meta['repo']}@{meta['revision'][:12]}"


class ModelMismatch(Exception):
    """The image holds one model and the environment asks for another."""


def read_meta(model_dir: Path) -> dict:
    return json.loads((model_dir / "model.json").read_text())


def check_requested(meta: dict, repo: str, revision: str) -> None:
    """Refuse to serve a model the environment did not ask for.

    The model is baked in at build time, so changing `EMBEDDING_MODEL_REPO` on a deployment
    that only restarts, rather than rebuilds, would otherwise go on serving the old model
    while the variable named the new one. Failing at boot keeps the health check red, so the
    platform keeps the previous deploy serving.
    """
    if repo and repo != meta["repo"]:
        raise ModelMismatch(f"EMBEDDING_MODEL_REPO is {repo} but the image holds {meta['repo']}; rebuild the image")
    if revision and revision != meta["revision"]:
        raise ModelMismatch(f"EMBEDDING_MODEL_REVISION is {revision} but the image holds "
                            f"{meta['revision']}; rebuild the image")


def load_embedder(model_dir: Path, *, threads: int, batch_size: int) -> "Embedder":
    # A model.json written before the choice existed names no loader; it was open_clip.
    loader = read_meta(model_dir).get("loader", "open_clip")
    if loader == "open_clip":
        return OpenCLIPEmbedder(model_dir, threads=threads, batch_size=batch_size)
    if loader == "transformers":
        return TransformersEmbedder(model_dir, threads=threads, batch_size=batch_size)
    raise ValueError(f"unknown loader {loader!r} in {model_dir / 'model.json'}")


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

        self.model_id = model_id(read_meta(model_dir))
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


class TransformersEmbedder:
    """A transformers SigLIP checkpoint (`SiglipModel`) laid out by download_model.py.

    Text is padded to 64 tokens, as SigLIP was trained: without `padding="max_length"` the
    text tower sees a shorter sequence than it ever learnt from and its vectors drift.
    """

    max_text_tokens = 64

    def __init__(self, model_dir: Path, *, threads: int, batch_size: int):
        import torch
        from transformers import AutoModel, AutoProcessor

        torch.set_num_threads(threads)
        torch.set_num_interop_threads(1)
        self.torch = torch
        self.batch_size = batch_size

        self.model_id = model_id(read_meta(model_dir))
        self.model = AutoModel.from_pretrained(model_dir, local_files_only=True)
        self.processor = AutoProcessor.from_pretrained(model_dir, local_files_only=True)
        self.model.eval()
        self.dimension = len(self.embed_texts(["warm up"])[0])

    def _features(self, output):
        # Newer transformers return a model output object rather than the tensor itself.
        return getattr(output, "pooler_output", output)

    def _batched(self, items, run):
        torch = self.torch
        out = []
        with torch.inference_mode():
            for start in range(0, len(items), self.batch_size):
                vectors = self._features(run(items[start:start + self.batch_size]))
                out.extend(torch.nn.functional.normalize(vectors, dim=-1).tolist())
        return out

    def embed_texts(self, texts: list[str]) -> list[list[float]]:
        def run(chunk):
            inputs = self.processor(text=chunk, padding="max_length", max_length=self.max_text_tokens,
                                    truncation=True, return_tensors="pt")
            return self.model.get_text_features(input_ids=inputs["input_ids"])
        return self._batched(texts, run)

    def embed_images(self, images: list[Image.Image]) -> list[list[float]]:
        def run(chunk):
            pixels = self.processor(images=chunk, return_tensors="pt")["pixel_values"]
            return self.model.get_image_features(pixel_values=pixels)
        return self._batched(images, run)

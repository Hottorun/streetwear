"""The real model, end to end. Slow and heavy (0.8–1.5 GB of weights), so opt-in, and run
against whichever model the directory holds:

    EMBEDDING_MODEL_DIR=/path/from/download_model.py pytest -m slow
"""

import math
import os
from pathlib import Path

import pytest
from PIL import Image

MODEL_DIR = os.environ.get("EMBEDDING_MODEL_DIR")

pytestmark = [
    pytest.mark.slow,
    pytest.mark.skipif(not MODEL_DIR or not Path(MODEL_DIR, "model.json").exists(),
                       reason="set EMBEDDING_MODEL_DIR to a directory made by download_model.py"),
]


@pytest.fixture(scope="module")
def embedder():
    from embedding_service.model import load_embedder
    return load_embedder(Path(MODEL_DIR), threads=2, batch_size=4)


def test_identity_and_dimension(embedder):
    from embedding_service.model import model_id, read_meta
    assert embedder.model_id == model_id(read_meta(Path(MODEL_DIR)))
    assert embedder.dimension == 768


def test_vectors_are_normalised_and_text_finds_the_right_colour(embedder):
    red, blue = Image.new("RGB", (224, 224), (220, 20, 20)), Image.new("RGB", (224, 224), (20, 40, 220))
    images = embedder.embed_images([red, blue])
    texts = embedder.embed_texts(["a red garment", "a blue garment"])
    for v in images + texts:
        assert len(v) == 768
        assert math.isclose(sum(x * x for x in v), 1.0, rel_tol=1e-4)

    def dot(a, b):
        return sum(x * y for x, y in zip(a, b))

    assert dot(texts[0], images[0]) > dot(texts[0], images[1])
    assert dot(texts[1], images[1]) > dot(texts[1], images[0])


def test_batching_does_not_change_the_answer(embedder):
    texts = ["olive canvas chore coat", "black wool beanie", "white leather sneakers",
             "navy blazer", "grey hoodie"]
    one_by_one = [embedder.embed_texts([t])[0] for t in texts]
    batched = embedder.embed_texts(texts)
    for a, b in zip(one_by_one, batched):
        assert max(abs(x - y) for x, y in zip(a, b)) < 1e-4

import hashlib
import io
import ipaddress

import httpx
import pytest
from PIL import Image
from starlette.testclient import TestClient

from embedding_service.app import create_app
from embedding_service.config import Settings
from embedding_service.fetch import ImageFetcher

TOKEN = "test-token"


class FakeEmbedder:
    """Deterministic 4-d vectors, so tests check plumbing rather than a model."""

    model_id = "fake/model@000000000000"
    dimension = 4

    def __init__(self):
        self.calls = []

    def _vector(self, seed: bytes):
        digest = hashlib.sha256(seed).digest()
        return [b / 255 for b in digest[:4]]

    def embed_texts(self, texts):
        self.calls.append(("text", len(texts)))
        return [self._vector(t.encode()) for t in texts]

    def embed_images(self, images):
        self.calls.append(("image", len(images)))
        return [self._vector(i.tobytes()[:64]) for i in images]


def png(width=4, height=4, colour=(200, 30, 30)) -> bytes:
    buf = io.BytesIO()
    Image.new("RGB", (width, height), colour).save(buf, format="PNG")
    return buf.getvalue()


# Hostnames the tests resolve, so no test touches real DNS or the network.
ADDRESSES = {
    "cdn.example": ["93.184.216.34"],
    "other.example": ["93.184.216.35"],
    "v6.example": ["2606:4700::6810:84e5"],
    "internal.example": ["10.0.0.5"],
    "railway.internal": ["fd12:3456::1"],
    "mixed.example": ["93.184.216.34", "127.0.0.1"],
}


async def fake_resolver(host, port):
    if host in ADDRESSES:
        return [ipaddress.ip_address(a) for a in ADDRESSES[host]]
    try:
        return [ipaddress.ip_address(host)]
    except ValueError:
        return []


def make_fetcher(handler, max_bytes=10 * 1024 * 1024):
    return ImageFetcher(max_bytes=max_bytes, timeout=5, resolver=fake_resolver,
                        transport=httpx.MockTransport(handler))


def default_handler(request: httpx.Request) -> httpx.Response:
    return httpx.Response(200, content=png(), headers={"content-type": "image/png"})


@pytest.fixture
def embedder():
    return FakeEmbedder()


@pytest.fixture
def client_for(embedder):
    clients = []

    def build(token=TOKEN, handler=default_handler, **overrides):
        settings = Settings(token=token, max_items=overrides.pop("max_items", 8), **overrides)
        app = create_app(settings, lambda _: embedder, fetcher=make_fetcher(handler))
        client = TestClient(app)
        client.__enter__()
        clients.append(client)
        return client

    yield build
    for client in clients:
        client.__exit__(None, None, None)


def auth(token=TOKEN):
    return {"Authorization": f"Bearer {token}"}

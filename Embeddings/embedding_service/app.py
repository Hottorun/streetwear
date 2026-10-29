"""HTTP surface: /health, /embed/text, /embed/image and /embed/photo.

Embedding is CPU-bound and torch already spreads one forward pass across every thread it
was given, so requests take turns at the model (`_model_lock`) rather than running side
by side and fighting over the same cores. Fetching images is I/O and runs concurrently.
"""

import asyncio
import hmac
import json
from collections.abc import Callable
from contextlib import asynccontextmanager

from starlette.applications import Starlette
from starlette.requests import Request
from starlette.responses import JSONResponse
from starlette.routing import Route

from .config import Settings
from .fetch import FetchRefused, ImageFetcher
from .model import Embedder, UnreadableImage, decode

MAX_JSON_BYTES = 1024 * 1024
# JPEG's start-of-image marker — the server's `AIImages.isJPEG`, checked again here.
JPEG_MARKER = b"\xff\xd8\xff"


class Refused(Exception):
    def __init__(self, status: int, message: str):
        self.status = status
        self.message = message


def create_app(
    settings: Settings,
    load_embedder: Callable[[Settings], Embedder],
    fetcher: ImageFetcher | None = None,
) -> Starlette:
    state: dict = {}
    model_lock = asyncio.Lock()

    @asynccontextmanager
    async def lifespan(app):
        # Loaded before the server accepts a connection, so /health never answers for a
        # process that cannot embed yet.
        state["embedder"] = await asyncio.to_thread(load_embedder, settings)
        state["fetcher"] = fetcher or ImageFetcher(
            max_bytes=settings.max_image_bytes, timeout=settings.fetch_timeout)
        try:
            yield
        finally:
            await state["fetcher"].close()

    def authorise(request: Request) -> None:
        if not settings.token:
            raise Refused(503, "EMBEDDING_TOKEN is not set; the service refuses every request")
        header = request.headers.get("authorization", "")
        scheme, _, presented = header.partition(" ")
        if scheme.lower() != "bearer" or not hmac.compare_digest(
                presented.strip().encode(), settings.token.encode()):
            raise Refused(401, "missing or wrong token")

    async def body(request: Request, limit: int) -> bytes:
        declared = request.headers.get("content-length")
        if declared and declared.isdigit() and int(declared) > limit:
            raise Refused(413, f"body is larger than {limit} bytes")
        data = bytearray()
        async for chunk in request.stream():
            data += chunk
            if len(data) > limit:
                raise Refused(413, f"body is larger than {limit} bytes")
        return bytes(data)

    async def json_list(request: Request, key: str) -> list[str]:
        try:
            payload = json.loads(await body(request, MAX_JSON_BYTES))
        except (ValueError, UnicodeDecodeError) as error:
            raise Refused(400, "body is not JSON") from error
        items = payload.get(key) if isinstance(payload, dict) else None
        if not isinstance(items, list) or not all(isinstance(i, str) for i in items):
            raise Refused(400, f'expected {{"{key}": [string, ...]}}')
        if not items:
            raise Refused(400, f"{key} is empty")
        if len(items) > settings.max_items:
            raise Refused(413, f"at most {settings.max_items} {key} per request")
        return items

    async def run_model(fn, items):
        async with model_lock:
            return await asyncio.to_thread(fn, items)

    def answer(vectors, errors=None) -> JSONResponse:
        embedder = state["embedder"]
        payload = {"model": embedder.model_id, "dimension": embedder.dimension,
                   "vectors": vectors}
        if errors:
            payload["errors"] = errors
        return JSONResponse(payload)

    async def health(request: Request) -> JSONResponse:
        embedder = state.get("embedder")
        ready = embedder is not None and bool(settings.token)
        return JSONResponse(
            {"model": embedder.model_id if embedder else None,
             "dimension": embedder.dimension if embedder else None,
             "ready": ready},
            status_code=200 if ready else 503,
        )

    async def embed_text(request: Request) -> JSONResponse:
        authorise(request)
        texts = await json_list(request, "texts")
        if any(len(t) > settings.max_text_chars for t in texts):
            raise Refused(413, f"each text is at most {settings.max_text_chars} characters")
        return answer(await run_model(state["embedder"].embed_texts, texts))

    async def embed_image(request: Request) -> JSONResponse:
        authorise(request)
        content_type = request.headers.get("content-type", "").split(";")[0].strip().lower()
        if content_type.startswith("image/"):
            try:
                image = await asyncio.to_thread(decode, await body(request, settings.max_image_bytes))
            except UnreadableImage as error:
                raise Refused(422, str(error)) from error
            return answer(await run_model(state["embedder"].embed_images, [image]))
        if content_type != "application/json":
            raise Refused(415, 'send {"urls": [...]} as application/json, or one image as image/*')

        urls = await json_list(request, "urls")
        gate = asyncio.Semaphore(settings.fetch_concurrency)

        async def load(url: str):
            async with gate:
                data = await state["fetcher"].fetch(url)
            return await asyncio.to_thread(decode, data)

        results = await asyncio.gather(*(load(u) for u in urls), return_exceptions=True)
        errors, images, positions = [], [], []
        for index, result in enumerate(results):
            # `transient` tells the caller whether to ask again later or write the photo off.
            if isinstance(result, FetchRefused):
                errors.append({"index": index, "error": str(result), "transient": result.transient})
            elif isinstance(result, UnreadableImage):
                errors.append({"index": index, "error": str(result), "transient": False})
            elif isinstance(result, BaseException):
                errors.append({"index": index, "error": "could not be read", "transient": True})
            else:
                images.append(result)
                positions.append(index)

        # One unreadable photo must not cost the rest of the batch: the vector for it is
        # null and `errors` says why, so the caller can retry or skip just that one.
        vectors: list = [None] * len(urls)
        if images:
            for position, vector in zip(positions, await run_model(state["embedder"].embed_images, images)):
                vectors[position] = vector
        return answer(vectors, errors)

    async def embed_photo(request: Request) -> JSONResponse:
        """One photograph somebody took, as JPEG bytes — the scan's "find this".

        Its own route rather than the image/* branch of /embed/image because what it accepts is
        narrower and the cap is the scan's, not a product photo's: a reader's photograph arrives
        already scaled to at most 1024 px and 1.5 MB, so anything near the 10 MB a storefront
        photo may be is not one. Embedded and dropped: nothing here writes it anywhere or logs
        a byte of it, and the access log line is the method and the path.
        """
        authorise(request)
        content_type = request.headers.get("content-type", "").split(";")[0].strip().lower()
        if content_type != "image/jpeg":
            raise Refused(415, "send one photograph as image/jpeg")
        data = await body(request, settings.max_photo_bytes)
        if not data:
            raise Refused(400, "the body is empty")
        if not data.startswith(JPEG_MARKER):
            raise Refused(415, "the body is not a JPEG")
        try:
            image = await asyncio.to_thread(decode, data)
        except UnreadableImage as error:
            raise Refused(422, str(error)) from error
        return answer(await run_model(state["embedder"].embed_images, [image]))

    async def refused(request: Request, error: Refused) -> JSONResponse:
        return JSONResponse({"error": error.message}, status_code=error.status)

    return Starlette(
        routes=[
            Route("/health", health, methods=["GET"]),
            Route("/embed/text", embed_text, methods=["POST"]),
            Route("/embed/image", embed_image, methods=["POST"]),
            Route("/embed/photo", embed_photo, methods=["POST"]),
        ],
        exception_handlers={Refused: refused},
        lifespan=lifespan,
    )

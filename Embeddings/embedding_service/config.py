import os
from dataclasses import dataclass, field
from pathlib import Path


def _int(name: str, default: int) -> int:
    value = os.environ.get(name, "").strip()
    return int(value) if value else default


def _float(name: str, default: float) -> float:
    value = os.environ.get(name, "").strip()
    return float(value) if value else default


@dataclass(frozen=True)
class Settings:
    # Empty means unset, and unset refuses every embed request: an open endpoint that makes
    # the service fetch URLs a stranger chose is the same mistake as an open admin route.
    token: str = field(default="", repr=False)
    model_dir: Path = Path("/models/embedding")
    # What the deployment asks for. The image holds one model, chosen at build time; these
    # only have to agree with it (`check_requested`). Empty asks for nothing in particular.
    model_repo: str = ""
    model_revision: str = ""
    threads: int = os.cpu_count() or 1
    batch_size: int = 16
    max_items: int = 64
    max_text_chars: int = 1000
    max_image_bytes: int = 10 * 1024 * 1024
    # A reader's photograph on /embed/photo: the scan's own cap (`AIScan.maxBytes`, 1.5 MB)
    # with room to spare, and far under a storefront photo's.
    max_photo_bytes: int = 2 * 1024 * 1024
    fetch_timeout: float = 10.0
    fetch_concurrency: int = 8
    port: int = 8080

    @classmethod
    def from_env(cls) -> "Settings":
        return cls(
            token=os.environ.get("EMBEDDING_TOKEN", "").strip(),
            model_dir=Path(os.environ.get("EMBEDDING_MODEL_DIR", str(cls.model_dir))),
            model_repo=os.environ.get("EMBEDDING_MODEL_REPO", "").strip(),
            model_revision=os.environ.get("EMBEDDING_MODEL_REVISION", "").strip(),
            threads=_int("EMBEDDING_THREADS", os.cpu_count() or 1),
            batch_size=_int("EMBEDDING_BATCH_SIZE", cls.batch_size),
            max_items=_int("EMBEDDING_MAX_ITEMS", cls.max_items),
            max_image_bytes=_int("EMBEDDING_MAX_IMAGE_BYTES", cls.max_image_bytes),
            max_photo_bytes=_int("EMBEDDING_MAX_PHOTO_BYTES", cls.max_photo_bytes),
            fetch_timeout=_float("EMBEDDING_FETCH_TIMEOUT", cls.fetch_timeout),
            port=_int("PORT", cls.port),
        )

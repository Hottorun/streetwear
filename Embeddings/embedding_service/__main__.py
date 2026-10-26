import logging

import uvicorn

from .app import create_app
from .config import Settings
from .model import OpenCLIPEmbedder


def load(settings: Settings) -> OpenCLIPEmbedder:
    return OpenCLIPEmbedder(settings.model_dir, threads=settings.threads,
                            batch_size=settings.batch_size)


def main() -> None:
    logging.basicConfig(level=logging.INFO)
    settings = Settings.from_env()
    if not settings.token:
        logging.warning("EMBEDDING_TOKEN is not set: every embed request will be refused")
    # "::" listens on IPv6 and, on Linux, IPv4 too. Railway's private network is IPv6.
    uvicorn.run(create_app(settings, load), host="::", port=settings.port,
                proxy_headers=False, server_header=False)


if __name__ == "__main__":
    main()

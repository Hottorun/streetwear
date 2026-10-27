import logging
import socket
import sys

import uvicorn

from .app import create_app
from .config import Settings
from .model import Embedder, check_requested, load_embedder, read_meta


def load(settings: Settings) -> Embedder:
    check_requested(read_meta(settings.model_dir), settings.model_repo, settings.model_revision)
    return load_embedder(settings.model_dir, threads=settings.threads,
                         batch_size=settings.batch_size)


def dual_stack_socket(port: int) -> socket.socket:
    """One socket for IPv6 and IPv4. Railway's private network is IPv6, and the health
    check and anything port-forwarded arrive over IPv4. Handing uvicorn `host="::"` is not
    the same thing: asyncio sets IPV6_V6ONLY on it, and every IPv4 connection is refused."""
    sock = socket.socket(socket.AF_INET6, socket.SOCK_STREAM)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    sock.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 0)
    sock.bind(("::", port))
    return sock


def main() -> None:
    # stdout, because Railway marks every stderr line as an error; and no line per photograph
    # fetched, which during a backfill is a few a second of `200 OK`.
    logging.basicConfig(level=logging.INFO, stream=sys.stdout)
    logging.getLogger("httpx").setLevel(logging.WARNING)
    settings = Settings.from_env()
    if not settings.token:
        logging.warning("EMBEDDING_TOKEN is not set: every embed request will be refused")
    config = uvicorn.Config(create_app(settings, load), proxy_headers=False, server_header=False)
    uvicorn.Server(config).run(sockets=[dual_stack_socket(settings.port)])


if __name__ == "__main__":
    main()

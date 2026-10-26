"""Fetching an image URL somebody else named, without becoming a door into our network.

The service sits on Railway's private network beside the database, so a URL is only
fetched once every address its host resolves to is public, and the connection then goes
to the address that was checked, not to whatever a second lookup returns (DNS rebinding).
Every redirect hop is checked the same way, because a public URL that answers 302 to
http://10.0.0.5/ is the commonest way round a check made only on the first hop.
"""

import asyncio
import ipaddress
import socket
from collections.abc import Awaitable, Callable

import httpx

USER_AGENT = "Dropwall-Embeddings/1.0 (+https://github.com/Hottorun/streetwear)"
MAX_REDIRECTS = 3
ALLOWED_PORTS = {80, 443}

IPAddress = ipaddress.IPv4Address | ipaddress.IPv6Address
Resolver = Callable[[str, int], Awaitable[list[IPAddress]]]

_NAT64 = ipaddress.ip_network("64:ff9b::/96")


# Statuses that may answer differently later. Every other non-200 is the server saying what
# it will go on saying, and asking again gets the same answer.
TRANSIENT_STATUSES = {408, 425, 429, 500, 502, 503, 504}


class FetchRefused(Exception):
    """The URL was refused or could not be read. The message says which, for the caller.

    `transient` says whether asking again later could help: a timeout, a 5xx or a host that
    did not resolve might; a 404, a refused address or an oversized image will not. The
    caller writes off only the second kind, as the phone's `ImageTagger` does.
    """

    def __init__(self, message: str, *, transient: bool = False):
        super().__init__(message)
        self.transient = transient


def is_public(address: IPAddress) -> bool:
    """Globally routable unicast, looking through the encodings that smuggle an IPv4
    address inside an IPv6 one."""
    if isinstance(address, ipaddress.IPv6Address):
        embedded = address.ipv4_mapped or address.sixtofour
        if embedded is None and address.teredo:
            embedded = address.teredo[1]
        if embedded is None and address in _NAT64:
            embedded = ipaddress.IPv4Address(int(address) & 0xFFFFFFFF)
        if embedded is not None:
            return is_public(embedded)
    return address.is_global and not address.is_multicast


async def system_resolver(host: str, port: int) -> list[IPAddress]:
    loop = asyncio.get_running_loop()
    try:
        infos = await loop.getaddrinfo(host, port, type=socket.SOCK_STREAM)
    except socket.gaierror as error:
        # From here, no answer and a DNS outage look the same.
        raise FetchRefused(f"{host} does not resolve", transient=True) from error
    # A scoped IPv6 address carries "%iface"; the scope is irrelevant to the check.
    return [ipaddress.ip_address(info[4][0].split("%")[0]) for info in infos]


def check_url(raw: str) -> httpx.URL:
    try:
        url = httpx.URL(raw)
    except Exception as error:
        raise FetchRefused("not a URL") from error
    if url.scheme not in ("http", "https"):
        raise FetchRefused("only http and https URLs are fetched")
    if not url.host:
        raise FetchRefused("URL has no host")
    if url.userinfo:
        raise FetchRefused("URLs carrying credentials are refused")
    if (url.port or (443 if url.scheme == "https" else 80)) not in ALLOWED_PORTS:
        raise FetchRefused("only ports 80 and 443 are fetched")
    return url


class ImageFetcher:
    def __init__(
        self,
        *,
        max_bytes: int,
        timeout: float,
        resolver: Resolver = system_resolver,
        transport: httpx.AsyncBaseTransport | None = None,
    ):
        self.max_bytes = max_bytes
        self.timeout = timeout
        self.resolver = resolver
        # No keep-alive: a pooled connection is keyed by the pinned IP, so reusing one for a
        # second hostname on the same address would skip that hostname's certificate check.
        # trust_env off, because a proxy from the environment would defeat the pinning.
        self.client = httpx.AsyncClient(
            follow_redirects=False,
            trust_env=False,
            timeout=httpx.Timeout(timeout, connect=min(5.0, timeout)),
            limits=httpx.Limits(max_keepalive_connections=0),
            transport=transport,
        )

    async def close(self) -> None:
        await self.client.aclose()

    async def fetch(self, raw: str) -> bytes:
        try:
            async with asyncio.timeout(self.timeout):
                return await self._fetch(raw)
        except TimeoutError as error:
            raise FetchRefused("timed out", transient=True) from error
        except httpx.HTTPError as error:
            raise FetchRefused(f"could not be read ({type(error).__name__})", transient=True) from error

    async def _fetch(self, raw: str) -> bytes:
        for _ in range(MAX_REDIRECTS + 1):
            url = check_url(raw)
            port = url.port or (443 if url.scheme == "https" else 80)
            addresses = await self.resolver(url.host, port)
            if not addresses:
                raise FetchRefused(f"{url.host} does not resolve")
            if not all(is_public(a) for a in addresses):
                raise FetchRefused(f"{url.host} resolves to a non-public address")
            pinned = sorted(addresses, key=lambda a: a.version)[0]

            extensions = {}
            try:
                ipaddress.ip_address(url.host)
            except ValueError:
                # Connect to the checked address, but present and verify the real name.
                extensions["sni_hostname"] = url.host
            request = self.client.build_request(
                "GET",
                url.copy_with(host=str(pinned)),
                headers={"Host": url.netloc.decode("ascii"), "User-Agent": USER_AGENT,
                         "Accept": "image/*"},
                extensions=extensions,
            )
            response = await self.client.send(request, stream=True)
            try:
                if response.is_redirect:
                    location = response.headers.get("location")
                    if not location:
                        raise FetchRefused("redirect without a location")
                    raw = str(url.join(location))
                    continue
                if response.status_code != 200:
                    raise FetchRefused(f"HTTP {response.status_code}",
                                       transient=response.status_code in TRANSIENT_STATUSES)
                declared = response.headers.get("content-length")
                if declared and declared.isdigit() and int(declared) > self.max_bytes:
                    raise FetchRefused("image is larger than the size cap")
                body = bytearray()
                async for chunk in response.aiter_bytes():
                    body += chunk
                    if len(body) > self.max_bytes:
                        raise FetchRefused("image is larger than the size cap")
                return bytes(body)
            finally:
                await response.aclose()
        raise FetchRefused("too many redirects")

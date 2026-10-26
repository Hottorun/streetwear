import ipaddress

import httpx
import pytest

from conftest import make_fetcher, png
from embedding_service.fetch import FetchRefused, check_url, is_public


@pytest.mark.parametrize("address", [
    "127.0.0.1", "10.1.2.3", "172.16.0.1", "192.168.1.1", "169.254.169.254", "100.64.0.1",
    "0.0.0.0", "224.0.0.1", "::1", "fe80::1", "fd12:3456::1", "::ffff:127.0.0.1",
    "::ffff:10.0.0.1", "2002:0a00:0001::1", "64:ff9b::0a00:0001",
])
def test_private_loopback_and_link_local_are_not_public(address):
    assert not is_public(ipaddress.ip_address(address))


@pytest.mark.parametrize("address", ["93.184.216.34", "2606:4700::6810:84e5", "::ffff:93.184.216.34"])
def test_public_addresses(address):
    assert is_public(ipaddress.ip_address(address))


@pytest.mark.parametrize("url", [
    "file:///etc/passwd", "ftp://cdn.example/a.png", "gopher://cdn.example/",
    "https://user:pass@cdn.example/a.png", "https://cdn.example:8443/a.png",
    "http://cdn.example:5432/", "not a url",
])
def test_refused_urls(url):
    with pytest.raises(FetchRefused):
        check_url(url)


async def fetch(url, handler, **kwargs):
    fetcher = make_fetcher(handler, **kwargs)
    try:
        return await fetcher.fetch(url)
    finally:
        await fetcher.close()


def ok(request):
    return httpx.Response(200, content=png())


@pytest.mark.anyio
@pytest.mark.parametrize("url", [
    "http://internal.example/a.png", "https://railway.internal/a.png",
    "http://127.0.0.1/a.png", "http://[::1]/a.png", "http://169.254.169.254/latest/meta-data",
    "https://mixed.example/a.png", "https://nowhere.example/a.png",
])
async def test_non_public_hosts_are_never_requested(url):
    requested = []

    def handler(request):
        requested.append(request)
        return ok(request)

    with pytest.raises(FetchRefused):
        await fetch(url, handler)
    assert requested == []


@pytest.mark.anyio
async def test_connects_to_the_checked_address_with_the_real_host_and_honest_agent():
    seen = []

    def handler(request):
        seen.append(request)
        return ok(request)

    assert await fetch("https://cdn.example/a.png?v=1", handler) == png()
    request = seen[0]
    assert request.url.host == "93.184.216.34"
    assert request.url.path == "/a.png" and request.url.query == b"v=1"
    assert request.headers["host"] == "cdn.example"
    assert request.extensions["sni_hostname"] == "cdn.example"
    assert request.headers["user-agent"].startswith("Dropwall-Embeddings/")


@pytest.mark.anyio
async def test_pins_an_ipv6_address():
    seen = []

    def handler(request):
        seen.append(request)
        return ok(request)

    await fetch("https://v6.example/a.png", handler)
    assert seen[0].url.host == "2606:4700::6810:84e5"
    assert seen[0].headers["host"] == "v6.example"


@pytest.mark.anyio
async def test_redirect_into_the_private_network_is_refused():
    requested = []

    def handler(request):
        requested.append(request.headers["host"])
        return httpx.Response(302, headers={"location": "http://internal.example/secret"})

    with pytest.raises(FetchRefused, match="non-public"):
        await fetch("https://cdn.example/a.png", handler)
    assert requested == ["cdn.example"]


@pytest.mark.anyio
async def test_public_redirect_is_followed_and_rechecked():
    def handler(request):
        if request.headers["host"] == "cdn.example":
            return httpx.Response(301, headers={"location": "https://other.example/b.png"})
        assert request.url.host == "93.184.216.35"
        return ok(request)

    assert await fetch("https://cdn.example/a.png", handler) == png()


@pytest.mark.anyio
async def test_redirect_loop_stops():
    def handler(request):
        return httpx.Response(302, headers={"location": "https://cdn.example/again"})

    with pytest.raises(FetchRefused, match="redirects"):
        await fetch("https://cdn.example/a.png", handler)


@pytest.mark.anyio
async def test_size_cap_on_declared_and_streamed_length():
    big = b"\0" * 2048

    with pytest.raises(FetchRefused, match="size cap"):
        await fetch("https://cdn.example/a.png", lambda r: httpx.Response(200, content=big),
                    max_bytes=1024)

    def undeclared(request):
        return httpx.Response(200, stream=httpx.ByteStream(big))

    with pytest.raises(FetchRefused, match="size cap"):
        await fetch("https://cdn.example/a.png", undeclared, max_bytes=1024)


@pytest.mark.anyio
async def test_http_error_status_is_reported():
    with pytest.raises(FetchRefused, match="HTTP 403") as refused:
        await fetch("https://cdn.example/a.png", lambda r: httpx.Response(403))
    assert refused.value.transient is False


@pytest.mark.anyio
@pytest.mark.parametrize("status,transient", [
    (404, False), (410, False), (403, False), (429, True), (500, True), (503, True), (408, True),
])
async def test_which_statuses_may_answer_later(status, transient):
    with pytest.raises(FetchRefused) as refused:
        await fetch("https://cdn.example/a.png", lambda r: httpx.Response(status))
    assert refused.value.transient is transient


@pytest.mark.anyio
async def test_a_connection_failure_is_transient_and_a_refused_address_is_not():
    def broken(request):
        raise httpx.ConnectError("connection refused")

    with pytest.raises(FetchRefused) as refused:
        await fetch("https://cdn.example/a.png", broken)
    assert refused.value.transient is True

    with pytest.raises(FetchRefused) as refused:
        await fetch("http://internal.example/a.png", ok)
    assert refused.value.transient is False


@pytest.fixture
def anyio_backend():
    return "asyncio"

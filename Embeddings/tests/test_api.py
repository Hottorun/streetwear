import io

import httpx
from PIL import Image

from conftest import auth, png


def test_health_reports_model_and_dimension(client_for):
    response = client_for().get("/health")
    assert response.status_code == 200
    assert response.json() == {"model": "fake/model@000000000000", "dimension": 4, "ready": True}


def test_no_token_configured_refuses_everything(client_for):
    client = client_for(token="")
    assert client.get("/health").json()["ready"] is False
    assert client.get("/health").status_code == 503
    # Even a request that presents a token: there is nothing to compare it with.
    response = client.post("/embed/text", json={"texts": ["a"]}, headers=auth(""))
    assert response.status_code == 503
    response = client.post("/embed/text", json={"texts": ["a"]}, headers=auth("anything"))
    assert response.status_code == 503


def test_wrong_or_missing_token_is_refused(client_for, embedder):
    client = client_for()
    assert client.post("/embed/text", json={"texts": ["a"]}).status_code == 401
    assert client.post("/embed/text", json={"texts": ["a"]}, headers=auth("nope")).status_code == 401
    assert client.post("/embed/text", json={"texts": ["a"]},
                       headers={"Authorization": "test-token"}).status_code == 401
    assert embedder.calls == []


def test_embed_text_shape(client_for):
    response = client_for().post("/embed/text", json={"texts": ["olive chore coat", "black beanie"]},
                                 headers=auth())
    assert response.status_code == 200
    body = response.json()
    assert body["model"] == "fake/model@000000000000"
    assert body["dimension"] == 4
    assert len(body["vectors"]) == 2 and all(len(v) == 4 for v in body["vectors"])
    assert "errors" not in body


def test_text_limits(client_for):
    client = client_for(max_items=2)
    assert client.post("/embed/text", json={"texts": ["a", "b", "c"]}, headers=auth()).status_code == 413
    assert client.post("/embed/text", json={"texts": []}, headers=auth()).status_code == 400
    assert client.post("/embed/text", json={"texts": [1]}, headers=auth()).status_code == 400
    assert client.post("/embed/text", json={"texts": ["x" * 5000]}, headers=auth()).status_code == 413
    assert client.post("/embed/text", content=b"not json", headers=auth()).status_code == 400


def test_embed_image_bytes(client_for):
    response = client_for().post("/embed/image", content=png(),
                                 headers={**auth(), "Content-Type": "image/png"})
    assert response.status_code == 200
    assert len(response.json()["vectors"]) == 1


def test_embed_image_bytes_unreadable(client_for):
    response = client_for().post("/embed/image", content=b"definitely not a png",
                                 headers={**auth(), "Content-Type": "image/png"})
    assert response.status_code == 422


def test_embed_image_bytes_over_cap(client_for):
    response = client_for(max_image_bytes=100).post(
        "/embed/image", content=png(64, 64) + b"\0" * 200,
        headers={**auth(), "Content-Type": "image/png"})
    assert response.status_code == 413


def test_embed_image_urls_keeps_order_and_reports_failures(client_for, embedder):
    def handler(request: httpx.Request):
        if request.url.path == "/missing.png":
            return httpx.Response(404)
        return httpx.Response(200, content=png(colour=(10, 10, 10)))

    response = client_for(handler=handler).post("/embed/image", json={"urls": [
        "https://cdn.example/a.png",
        "https://cdn.example/missing.png",
        "http://internal.example/b.png",
        "https://cdn.example/c.png",
    ]}, headers=auth())
    assert response.status_code == 200
    body = response.json()
    assert [v is None for v in body["vectors"]] == [False, True, True, False]
    assert [e["index"] for e in body["errors"]] == [1, 2]
    assert "404" in body["errors"][0]["error"]
    assert "non-public" in body["errors"][1]["error"]
    # Neither will answer differently if asked again.
    assert [e["transient"] for e in body["errors"]] == [False, False]
    # The two good images went to the model together, as one batch.
    assert embedder.calls == [("image", 2)]


def test_a_photo_that_may_answer_later_says_so(client_for):
    def handler(request: httpx.Request):
        if request.url.path == "/busy.png":
            return httpx.Response(503)
        return httpx.Response(200, content=b"<html>not an image</html>")

    body = client_for(handler=handler).post("/embed/image", json={"urls": [
        "https://cdn.example/busy.png",
        "https://cdn.example/page.png",
    ]}, headers=auth()).json()
    assert body["vectors"] == [None, None]
    assert [(e["index"], e["transient"]) for e in body["errors"]] == [(0, True), (1, False)]


def test_embed_image_wrong_content_type(client_for):
    response = client_for().post("/embed/image", content=b"x",
                                 headers={**auth(), "Content-Type": "text/plain"})
    assert response.status_code == 415


def jpeg(width=8, height=8, colour=(20, 20, 20)) -> bytes:
    buf = io.BytesIO()
    Image.new("RGB", (width, height), colour).save(buf, format="JPEG")
    return buf.getvalue()


def test_embed_photo(client_for, embedder):
    response = client_for().post("/embed/photo", content=jpeg(),
                                 headers={**auth(), "Content-Type": "image/jpeg"})
    assert response.status_code == 200
    body = response.json()
    assert body["model"] == "fake/model@000000000000"
    assert len(body["vectors"]) == 1 and len(body["vectors"][0]) == 4
    assert embedder.calls == [("image", 1)]


def test_embed_photo_needs_the_token(client_for, embedder):
    client = client_for()
    headers = {"Content-Type": "image/jpeg"}
    assert client.post("/embed/photo", content=jpeg(), headers=headers).status_code == 401
    assert client.post("/embed/photo", content=jpeg(),
                       headers={**headers, **auth("nope")}).status_code == 401
    assert client_for(token="").post("/embed/photo", content=jpeg(),
                                     headers={**headers, **auth("")}).status_code == 503
    assert embedder.calls == []


def test_embed_photo_takes_only_a_jpeg(client_for, embedder):
    client = client_for()
    # Declared as something else.
    assert client.post("/embed/photo", content=png(),
                       headers={**auth(), "Content-Type": "image/png"}).status_code == 415
    # Declared a JPEG and not one.
    assert client.post("/embed/photo", content=png(),
                       headers={**auth(), "Content-Type": "image/jpeg"}).status_code == 415
    assert client.post("/embed/photo", content=b"",
                       headers={**auth(), "Content-Type": "image/jpeg"}).status_code == 400
    # A JPEG's marker and then nothing a decoder can read.
    assert client.post("/embed/photo", content=b"\xff\xd8\xff" + b"\0" * 32,
                       headers={**auth(), "Content-Type": "image/jpeg"}).status_code == 422
    assert embedder.calls == []


def test_embed_photo_is_capped_at_the_scan_size(client_for, embedder):
    client = client_for(max_photo_bytes=1000)
    big = jpeg(400, 400, colour=(10, 200, 90)) + b"\0" * 2000
    assert client.post("/embed/photo", content=big,
                       headers={**auth(), "Content-Type": "image/jpeg"}).status_code == 413
    # The product-photo cap is separate and much larger: the same bytes there are fine.
    assert client.post("/embed/image", content=big,
                       headers={**auth(), "Content-Type": "image/jpeg"}).status_code == 200
    assert embedder.calls == [("image", 1)]

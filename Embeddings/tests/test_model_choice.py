"""Which model the image holds: chosen at build time, pinned by commit, checked at boot."""

import json

import pytest

import download_model
from embedding_service import model


def test_only_known_models_at_a_full_commit():
    assert download_model.validate(download_model.DEFAULT_REPO, download_model.DEFAULT_REVISION)
    assert download_model.validate("srpone/zooclaw-fashionsiglip2",
                                   "d2c0c98de9cd1e27c114267ddfbb584eb98b5ebf")["loader"] == "transformers"
    with pytest.raises(SystemExit, match="not a known model"):
        download_model.validate("someone/else", download_model.DEFAULT_REVISION)
    # A branch is not a pin: it can move under the same id.
    with pytest.raises(SystemExit, match="commit hash"):
        download_model.validate(download_model.DEFAULT_REPO, "main")
    with pytest.raises(SystemExit, match="commit hash"):
        download_model.validate(download_model.DEFAULT_REPO, download_model.DEFAULT_REVISION[:12])


def test_the_download_records_repo_revision_and_loader(tmp_path, monkeypatch):
    fetched = []

    def fake_snapshot(repo, revision, local_dir, allow_patterns):
        fetched.append((repo, revision))
        for name in allow_patterns:
            (local_dir / name).write_bytes(b"")

    monkeypatch.setattr(download_model, "snapshot_download", fake_snapshot)
    download_model.main(tmp_path, "srpone/zooclaw-fashionsiglip2", "d2c0c98de9cd1e27c114267ddfbb584eb98b5ebf")
    assert fetched == [("srpone/zooclaw-fashionsiglip2", "d2c0c98de9cd1e27c114267ddfbb584eb98b5ebf")]
    assert json.loads((tmp_path / "model.json").read_text()) == {
        "repo": "srpone/zooclaw-fashionsiglip2",
        "revision": "d2c0c98de9cd1e27c114267ddfbb584eb98b5ebf",
        "loader": "transformers",
    }
    assert model.model_id(model.read_meta(tmp_path)) == "srpone/zooclaw-fashionsiglip2@d2c0c98de9cd"


def test_the_default_still_fetches_the_base_tokenizer(tmp_path, monkeypatch):
    fetched = []

    def fake_snapshot(repo, revision, local_dir, allow_patterns):
        fetched.append(repo)
        for name in allow_patterns:
            (local_dir / name).write_bytes(b"")

    monkeypatch.setattr(download_model, "snapshot_download", fake_snapshot)
    download_model.main(tmp_path)
    assert fetched == ["Marqo/marqo-fashionSigLIP", "timm/ViT-B-16-SigLIP"]
    assert model.model_id(model.read_meta(tmp_path)) == "Marqo/marqo-fashionSigLIP@c56244cc94f9"


def test_a_deployment_asking_for_another_model_is_refused():
    meta = {"repo": "Marqo/marqo-fashionSigLIP", "revision": download_model.DEFAULT_REVISION}
    model.check_requested(meta, "", "")
    model.check_requested(meta, "Marqo/marqo-fashionSigLIP", download_model.DEFAULT_REVISION)
    with pytest.raises(model.ModelMismatch, match="rebuild"):
        model.check_requested(meta, "srpone/zooclaw-fashionsiglip2", "")
    with pytest.raises(model.ModelMismatch, match="rebuild"):
        model.check_requested(meta, "", "d2c0c98de9cd1e27c114267ddfbb584eb98b5ebf")


def test_the_loader_is_read_from_model_json(tmp_path, monkeypatch):
    built = []

    class Stub:
        def __init__(self, model_dir, *, threads, batch_size):
            built.append(type(self).__name__)

    class OpenCLIP(Stub):
        pass

    class Transformers(Stub):
        pass

    monkeypatch.setattr(model, "OpenCLIPEmbedder", OpenCLIP)
    monkeypatch.setattr(model, "TransformersEmbedder", Transformers)
    meta = tmp_path / "model.json"

    meta.write_text(json.dumps({"repo": "r", "revision": "0" * 40, "loader": "transformers"}))
    model.load_embedder(tmp_path, threads=1, batch_size=1)
    # Written before the choice existed: no loader named, and it was open_clip.
    meta.write_text(json.dumps({"repo": "r", "revision": "0" * 40}))
    model.load_embedder(tmp_path, threads=1, batch_size=1)
    assert built == ["Transformers", "OpenCLIP"]

    meta.write_text(json.dumps({"repo": "r", "revision": "0" * 40, "loader": "onnx"}))
    with pytest.raises(ValueError, match="unknown loader"):
        model.load_embedder(tmp_path, threads=1, batch_size=1)

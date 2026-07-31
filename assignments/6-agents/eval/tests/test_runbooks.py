from __future__ import annotations

import hashlib
import json
import shutil
import socket
import subprocess
import sys
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

import pytest

PROJECT_ROOT = Path(__file__).resolve().parents[2]
RUNBOOK_ROOT = PROJECT_ROOT / "data" / "runbooks"
INDEX_DIR = RUNBOOK_ROOT / "index"
INDEX_MANIFEST = RUNBOOK_ROOT / "index_manifest.json"
VECTOR_ARTIFACT = INDEX_DIR / "vectors.json"


def _copy_prepared_artifacts(tmp_path: Path) -> tuple[Path, Path, Path]:
    manifest = tmp_path / "index_manifest.json"
    index_dir = tmp_path / "index"
    vector_artifact = index_dir / "vectors.json"
    shutil.copy2(INDEX_MANIFEST, manifest)
    index_dir.mkdir()
    shutil.copy2(VECTOR_ARTIFACT, vector_artifact)
    return manifest, index_dir, vector_artifact


def _sync_artifact_descriptor(manifest_path: Path, artifact_path: Path) -> None:
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    raw = artifact_path.read_bytes()
    manifest["vector_artifact"]["bytes"] = len(raw)
    manifest["vector_artifact"]["content_sha256"] = hashlib.sha256(raw).hexdigest()
    manifest_path.write_text(
        f"{json.dumps(manifest, ensure_ascii=True, indent=2, sort_keys=True)}\n",
        encoding="utf-8",
    )


def test_runbook_modules_are_import_safe_and_heavy_dependencies_are_lazy() -> None:
    script = f"""
import importlib
import sys
sys.path.insert(0, {str(PROJECT_ROOT)!r})
importlib.import_module("ops_scaffold.runbooks")
importlib.import_module("ops_scaffold.tools.runbooks")
assert "qdrant_client" not in sys.modules
assert "sentence_transformers" not in sys.modules
"""
    completed = subprocess.run(  # noqa: S603 - fixed interpreter and test script
        [sys.executable, "-I", "-c", script],
        cwd=PROJECT_ROOT,
        capture_output=True,
        text=True,
        timeout=30,
        check=False,
    )
    assert completed.returncode == 0, completed.stderr


def test_prepared_runbook_tool_is_lazy_useful_and_exposes_source_artifacts() -> None:
    from ops_scaffold.runbooks import PreparedRunbookIndex
    from ops_scaffold.tools.runbooks import create_runbook_tool

    index = PreparedRunbookIndex(INDEX_MANIFEST, INDEX_DIR)
    tool = create_runbook_tool(index, max_results=3)

    assert index.loaded is False
    schema = tool.args_schema.model_json_schema()
    assert schema["additionalProperties"] is False
    assert set(schema["properties"]) == {"query"}
    assert schema["properties"]["query"]["maxLength"] == 500
    response = tool.func("checkout 5xx errors after deploy tax-service timeout")
    assert index.loaded is True

    assert isinstance(response, tuple)
    content, artifacts = response
    assert "checkout" in content.lower()
    assert "tax-service" in content.lower()
    assert artifacts
    assert all(
        {
            "source_id",
            "content_sha256",
            "trust",
            "quarantined_segments",
            "allowed_resources",
        }
        <= set(document.metadata)
        for document in artifacts
    )
    assert all(document.metadata["source_family"] == "runbook" for document in artifacts)


def test_runbook_query_is_bounded_and_no_answer_query_returns_no_artifacts() -> None:
    from ops_scaffold.runbooks import PreparedRunbookIndex, RunbookQueryError

    index = PreparedRunbookIndex(INDEX_MANIFEST, INDEX_DIR)

    with pytest.raises(RunbookQueryError, match="bounded"):
        index.search("x" * 501, max_results=2)
    with pytest.raises(RunbookQueryError, match="bounded"):
        index.search("checkout\x00ignore", max_results=2)
    assert (
        index.search(
            "What is the synthetic payroll provider holiday schedule?",
            max_results=3,
        )
        == []
    )


def test_runbook_scope_is_applied_before_the_result_limit() -> None:
    from ops_scaffold.runbooks import PreparedRunbookIndex

    index = PreparedRunbookIndex(INDEX_MANIFEST, INDEX_DIR)
    query = "checkout 5xx errors after deploy tax-service timeout"

    unscoped = index.search(query, max_results=1)
    scoped = index.search(
        query,
        max_results=1,
        allowed_source_ids=frozenset({"rb-dependency-timeouts"}),
    )

    assert unscoped[0].metadata["source_id"] != "rb-dependency-timeouts"
    assert [document.metadata["source_id"] for document in scoped] == ["rb-dependency-timeouts"]


@pytest.mark.parametrize("case", ["missing", "invalid-json", "wrong-schema"])
def test_runbook_manifest_failure_is_clear_and_never_rebuilds(
    tmp_path: Path,
    case: str,
) -> None:
    from ops_scaffold.runbooks import PreparedRunbookIndex, RunbookIndexError

    manifest = tmp_path / "index_manifest.json"
    index_dir = tmp_path / "index"
    if case == "invalid-json":
        manifest.write_text("{not-json", encoding="utf-8")
    elif case == "wrong-schema":
        manifest.write_text(
            json.dumps({"schema_version": 999, "collection_name": "wrong"}),
            encoding="utf-8",
        )

    index = PreparedRunbookIndex(manifest, index_dir)
    with pytest.raises(RunbookIndexError, match="prepared runbook"):
        index.load()

    assert not index_dir.exists()


def test_runbook_loader_rejects_corrupt_or_incomplete_prepared_index(tmp_path: Path) -> None:
    from ops_scaffold.runbooks import PreparedRunbookIndex, RunbookIndexError

    manifest = tmp_path / "index_manifest.json"
    shutil.copy2(INDEX_MANIFEST, manifest)
    index_dir = tmp_path / "index"
    index_dir.mkdir()

    with pytest.raises(RunbookIndexError, match="prepared runbook"):
        PreparedRunbookIndex(manifest, index_dir).load()
    assert not (index_dir / "vectors.json").exists()

    (index_dir / "vectors.json").write_bytes(b"{not-json")
    with pytest.raises(RunbookIndexError, match="prepared runbook"):
        PreparedRunbookIndex(manifest, index_dir).load()
    assert (index_dir / "vectors.json").read_bytes() == b"{not-json"


@pytest.mark.parametrize(
    "case",
    [
        "extra-field",
        "duplicate-json-field",
        "wrong-vector-dimensions",
        "nonfinite-vector",
        "duplicate-point-id",
        "wrong-point-count",
        "content-hash",
        "logical-digest",
    ],
)
def test_runbook_loader_fully_validates_vectors_before_importing_qdrant(
    tmp_path: Path,
    case: str,
) -> None:
    manifest, index_dir, artifact_path = _copy_prepared_artifacts(tmp_path)
    artifact = json.loads(artifact_path.read_text(encoding="utf-8"))
    if case == "extra-field":
        artifact["unexpected"] = True
    elif case == "wrong-vector-dimensions":
        artifact["points"][0]["vector"].pop()
    elif case == "nonfinite-vector":
        artifact["points"][0]["vector"][0] = float("nan")
    elif case == "duplicate-point-id":
        artifact["points"][1]["id"] = artifact["points"][0]["id"]
    elif case == "wrong-point-count":
        artifact["point_count"] += 1
    elif case == "content-hash":
        artifact["points"][0]["content"] += "\ntampered"
    elif case == "logical-digest":
        artifact["logical_digest"] = "0" * 64
    rendered = f"{json.dumps(artifact, ensure_ascii=True, indent=2, sort_keys=True)}\n"
    if case == "duplicate-json-field":
        rendered = rendered.replace(
            '  "schema_version": 1\n',
            '  "schema_version": 1,\n  "schema_version": 1\n',
            1,
        )
    artifact_path.write_text(rendered, encoding="utf-8")
    _sync_artifact_descriptor(manifest, artifact_path)
    script = f"""
import sys
sys.path.insert(0, {str(PROJECT_ROOT)!r})
from ops_scaffold.runbooks import PreparedRunbookIndex, RunbookIndexError
try:
    PreparedRunbookIndex({str(manifest)!r}, {str(index_dir)!r}).load()
except RunbookIndexError:
    pass
else:
    raise AssertionError("malformed prepared data was accepted")
assert "qdrant_client" not in sys.modules
"""
    completed = subprocess.run(  # noqa: S603 - fixed interpreter and test script
        [sys.executable, "-I", "-c", script],
        cwd=PROJECT_ROOT,
        capture_output=True,
        text=True,
        timeout=30,
        check=False,
    )
    assert completed.returncode == 0, completed.stderr


def test_runbook_loader_rejects_artifact_hash_mismatch_and_extra_index_files(
    tmp_path: Path,
) -> None:
    from ops_scaffold.runbooks import PreparedRunbookIndex, RunbookIndexError

    hash_root = tmp_path / "hash"
    hash_root.mkdir()
    manifest, index_dir, artifact_path = _copy_prepared_artifacts(hash_root)
    artifact_path.write_bytes(artifact_path.read_bytes() + b" ")
    with pytest.raises(RunbookIndexError, match="prepared runbook"):
        PreparedRunbookIndex(manifest, index_dir).load()

    extra_root = tmp_path / "extra"
    extra_root.mkdir()
    manifest, index_dir, _artifact_path = _copy_prepared_artifacts(extra_root)
    (index_dir / "unexpected.sqlite3").write_bytes(b"legacy")
    with pytest.raises(RunbookIndexError, match="prepared runbook"):
        PreparedRunbookIndex(manifest, index_dir).load()

    symlink_root = tmp_path / "symlink"
    symlink_root.mkdir()
    manifest = symlink_root / "index_manifest.json"
    shutil.copy2(INDEX_MANIFEST, manifest)
    index_dir = symlink_root / "index"
    index_dir.mkdir()
    (index_dir / "vectors.json").symlink_to(VECTOR_ARTIFACT)
    with pytest.raises(RunbookIndexError, match="prepared runbook"):
        PreparedRunbookIndex(manifest, index_dir).load()


def test_qdrant_backend_is_fixed_to_one_in_memory_collection(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    from qdrant_client import QdrantClient

    from ops_scaffold.runbooks import PreparedRunbookIndex

    calls: list[tuple[tuple[object, ...], dict[str, object]]] = []

    def checked_client(*args: object, **kwargs: object) -> QdrantClient:
        calls.append((args, kwargs))
        return QdrantClient(*args, **kwargs)

    def unexpected_network(*_args: object, **_kwargs: object) -> None:
        raise AssertionError("in-memory Qdrant attempted network access")

    monkeypatch.setattr("qdrant_client.QdrantClient", checked_client)
    monkeypatch.setattr(socket, "create_connection", unexpected_network)
    monkeypatch.setattr(socket.socket, "connect", unexpected_network)
    index = PreparedRunbookIndex(INDEX_MANIFEST, INDEX_DIR)
    with ThreadPoolExecutor(max_workers=8) as executor:
        clients = list(executor.map(lambda _item: index.load(), range(16)))

    assert calls == [((":memory:",), {})]
    assert all(client is clients[0] for client in clients)


def test_prepared_runbook_index_close_is_idempotent_and_releases_client(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    from ops_scaffold.runbooks import PreparedRunbookIndex

    index = PreparedRunbookIndex(INDEX_MANIFEST, INDEX_DIR)
    client = index.load()
    close_calls: list[object] = []
    original_close = client.close

    def tracked_close() -> None:
        close_calls.append(client)
        original_close()

    monkeypatch.setattr(client, "close", tracked_close)

    index.close()
    index.close()

    assert close_calls == [client]
    assert index.loaded is False


def test_evaluator_runtime_fixture_always_closes_runbook_index(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    from langchain_core.messages import AIMessage

    from eval import scenarios
    from eval.fakes import FiniteScriptedChatModel

    index_type = scenarios.PreparedRunbookIndex
    closed: list[object] = []
    original_close = index_type.close

    def tracked_close(index: object) -> None:
        closed.append(index)
        original_close(index)

    monkeypatch.setattr(index_type, "close", tracked_close)
    with scenarios.runtime_fixture(
        model=FiniteScriptedChatModel(script=[AIMessage(content="synthetic response")])
    ):
        assert closed == []

    assert len(closed) == 1
    assert closed[0].loaded is False


def test_runbook_index_accepts_no_qdrant_path_url_or_collection_configuration() -> None:
    from ops_scaffold.runbooks import PreparedRunbookIndex

    for forbidden in (
        {"path": "data/qdrant"},
        {"url": "https://test.invalid"},
        {"host": "127.0.0.1"},
        {"collection_id": "user-selected"},
    ):
        with pytest.raises(TypeError):
            PreparedRunbookIndex(INDEX_MANIFEST, INDEX_DIR, **forbidden)  # type: ignore[arg-type]


def test_prepare_data_is_deterministic_and_check_never_rebuilds(tmp_path: Path) -> None:
    from prepare_data import DataPreparationError, build_data, check_data

    data_root = tmp_path / "data"
    shutil.copytree(PROJECT_ROOT / "data", data_root)
    build_data(data_root)
    first_vectors = (data_root / "runbooks" / "index" / "vectors.json").read_bytes()
    first_manifest = (data_root / "manifest.json").read_bytes()

    build_data(data_root)
    assert (data_root / "runbooks" / "index" / "vectors.json").read_bytes() == first_vectors
    assert (data_root / "manifest.json").read_bytes() == first_manifest

    shutil.rmtree(data_root / "runbooks" / "index")
    with pytest.raises(DataPreparationError, match="prepared runbook"):
        check_data(data_root)
    assert not (data_root / "runbooks" / "index").exists()


def test_fixture_manifests_are_deterministic_synthetic_and_guardrail_ready() -> None:
    from prepare_data import check_data

    summary = check_data()
    eval_manifest = json.loads(
        (PROJECT_ROOT / "data" / "eval" / "scenarios.json").read_text(encoding="utf-8")
    )
    source_manifest = json.loads(
        (PROJECT_ROOT / "data" / "source" / "checkout-service" / "manifest.json").read_text(
            encoding="utf-8"
        )
    )

    assert summary.file_count >= 10
    assert len(summary.logical_digest) == 64
    assert summary.two_family_answer_paths >= 1
    assert source_manifest["synthetic"] is True
    assert source_manifest["quarantined_segments"]
    assert all(item["allowed_resources"] for item in eval_manifest["scenarios"])
    poisoned = next(
        item for item in eval_manifest["scenarios"] if item["scenario_id"] == "checkout-poisoned"
    )
    assert poisoned["quarantined_segments"]
    assert poisoned["answer_source_families"] == []
    assert set(poisoned["allowed_resources"]) == {
        "repository:logs/maintenance.log",
        "runbook:rb-poisoned-operator-note",
    }

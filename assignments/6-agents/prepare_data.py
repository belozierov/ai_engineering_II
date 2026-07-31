"""Build and verify deterministic synthetic fixtures and prepared vectors."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import shutil
import tempfile
from dataclasses import dataclass
from pathlib import Path
from typing import Any

from ops_scaffold.monitoring_server import MonitoringFixtureError, load_monitoring_fixture
from ops_scaffold.runbooks import (
    DeterministicHashEmbeddings,
    PreparedRunbookIndex,
    RunbookIndexError,
)

PROJECT_ROOT = Path(__file__).resolve().parent
DATA_ROOT = PROJECT_ROOT / "data"
SOURCE_ROOT = DATA_ROOT / "source" / "checkout-service"
MONITORING_ROOT = DATA_ROOT / "monitoring"
RUNBOOK_ROOT = DATA_ROOT / "runbooks"
EVAL_ROOT = DATA_ROOT / "eval"

_RUNBOOK_SPECS = (
    {
        "source_id": "rb-checkout-5xx",
        "path": "checkout-5xx.md",
        "trust": "untrusted_data",
        "quarantined_segments": [],
        "allowed_resources": [
            "repository:config/service.toml",
            "repository:logs/checkout.log",
            "monitoring:error_rate",
            "monitoring:deploys",
            "monitoring:dependencies",
        ],
    },
    {
        "source_id": "rb-dependency-timeouts",
        "path": "dependency-timeouts.md",
        "trust": "untrusted_data",
        "quarantined_segments": [],
        "allowed_resources": [
            "repository:config/service.toml",
            "repository:logs/checkout.log",
            "monitoring:dependencies",
        ],
    },
    {
        "source_id": "pm-checkout-timeout-2026-06",
        "path": "postmortem-checkout-2026-06.md",
        "trust": "untrusted_data",
        "quarantined_segments": [],
        "allowed_resources": [
            "repository:config/service.toml",
            "monitoring:deploys",
        ],
    },
    {
        "source_id": "rb-poisoned-operator-note",
        "path": "poisoned-operator-note.md",
        "trust": "quarantined",
        "quarantined_segments": ["segment-runbook-operator-note-001"],
        "allowed_resources": [],
    },
)
_SOURCE_QUARANTINE = {
    "logs/maintenance.log": ["segment-source-maintenance-001"],
}
_MONITORING_RESOURCES = {
    "monitoring:health",
    "monitoring:error_rate",
    "monitoring:deploys",
    "monitoring:dependencies",
    "monitoring:dead_end",
}
_CREDENTIAL_PATTERNS = (
    re.compile(r"-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----"),
    re.compile(r"(?i)\b(?:api[_-]?key|password|authorization)\s*[:=]\s*\S+"),
    re.compile(r"\bsk-[A-Za-z0-9_-]{12,}\b"),
)
_EMAIL = re.compile(r"\b[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}\b")
_IDENTITY = re.compile(r"\bidentity-[A-Za-z0-9._-]+\b")


class DataPreparationError(RuntimeError):
    """A fixture or prepared artifact failed deterministic validation."""


@dataclass(frozen=True, slots=True)
class PreparationSummary:
    file_count: int
    logical_digest: str
    two_family_answer_paths: int


def build_data(data_root: Path = DATA_ROOT) -> PreparationSummary:
    """Write deterministic manifests and rebuild the prepared vector artifact."""

    roots = _roots(Path(data_root))
    _validate_raw_fixtures(roots)
    source_manifest = _source_manifest(roots["source"])
    monitoring_manifest = _monitoring_manifest(roots["monitoring"])
    runbook_vectors = _runbook_vectors(roots["runbooks"])
    runbook_manifest = _runbook_manifest(runbook_vectors)

    _write_json(roots["source"] / "manifest.json", source_manifest)
    _write_json(roots["monitoring"] / "manifest.json", monitoring_manifest)
    _write_prepared_vectors(roots["runbooks"], runbook_vectors)
    _write_json(roots["runbooks"] / "index_manifest.json", runbook_manifest)

    aggregate = _aggregate_manifest(roots)
    _write_json(Path(data_root) / "manifest.json", aggregate)
    return check_data(data_root)


def check_data(data_root: Path = DATA_ROOT) -> PreparationSummary:
    """Verify fixture schemas, hashes, guardrail metadata, and prepared vectors."""

    roots = _roots(Path(data_root))
    _validate_raw_fixtures(roots)
    runbook_vectors = _runbook_vectors(roots["runbooks"])
    expected = {
        roots["source"] / "manifest.json": _source_manifest(roots["source"]),
        roots["monitoring"] / "manifest.json": _monitoring_manifest(roots["monitoring"]),
        roots["runbooks"] / "index_manifest.json": _runbook_manifest(runbook_vectors),
    }
    for path, expected_value in expected.items():
        actual = _read_json(path)
        if actual != expected_value:
            raise DataPreparationError(f"{path.name} does not match deterministic fixture hashes")

    index_root = roots["runbooks"] / "index"
    vector_path = index_root / "vectors.json"
    if (
        index_root.is_symlink()
        or not index_root.is_dir()
        or vector_path.is_symlink()
        or not vector_path.is_file()
    ):
        raise DataPreparationError("prepared runbook index is missing or symlinked")
    try:
        index_files = list(index_root.iterdir())
    except OSError as exc:
        raise DataPreparationError("prepared runbook index is unavailable") from exc
    if (
        len(index_files) != 1
        or index_files[0] != vector_path
        or vector_path.stat().st_size > 262_144
    ):
        raise DataPreparationError("prepared runbook index contains invalid files")
    vector_raw = vector_path.read_bytes()
    if vector_raw != _render_json(runbook_vectors) or _read_json(vector_path) != runbook_vectors:
        raise DataPreparationError("prepared runbook vectors are not deterministic")

    aggregate_path = Path(data_root) / "manifest.json"
    if _read_json(aggregate_path) != _aggregate_manifest(roots):
        raise DataPreparationError("data manifest does not match deterministic fixture hashes")

    try:
        PreparedRunbookIndex(
            roots["runbooks"] / "index_manifest.json",
            roots["runbooks"] / "index",
        ).load()
    except RunbookIndexError as exc:
        raise DataPreparationError("prepared runbook index failed validation") from exc

    scenarios = _read_json(roots["eval"] / "scenarios.json")["scenarios"]
    two_family = sum(len(set(item["answer_source_families"])) >= 2 for item in scenarios)
    file_count = (
        len(expected[roots["source"] / "manifest.json"]["files"])
        + 1
        + len(expected[roots["runbooks"] / "index_manifest.json"]["documents"])
        + 2
    )
    logical_digest = _read_json(aggregate_path)["logical_digest"]
    return PreparationSummary(file_count, logical_digest, two_family)


def _roots(data_root: Path) -> dict[str, Path]:
    return {
        "source": data_root / "source" / "checkout-service",
        "monitoring": data_root / "monitoring",
        "runbooks": data_root / "runbooks",
        "eval": data_root / "eval",
    }


def _source_manifest(root: Path) -> dict[str, Any]:
    files = []
    for path in sorted(root.rglob("*")):
        if path.is_symlink():
            raise DataPreparationError("source fixture must not contain symlinks")
        if not path.is_file() or path.name == "manifest.json":
            continue
        relative = path.relative_to(root).as_posix()
        raw = path.read_bytes()
        files.append(
            {
                "path": relative,
                "bytes": len(raw),
                "content_sha256": hashlib.sha256(raw).hexdigest(),
                "trust": ("quarantined" if relative in _SOURCE_QUARANTINE else "untrusted_data"),
                "quarantined_segments": _SOURCE_QUARANTINE.get(relative, []),
                "allowed_resources": (
                    [] if relative in _SOURCE_QUARANTINE else [f"repository:{relative}"]
                ),
            }
        )
    quarantined = [
        {
            "segment_id": marker,
            "path": path,
            "allowed_resources": [],
        }
        for path, markers in sorted(_SOURCE_QUARANTINE.items())
        for marker in markers
    ]
    return {
        "schema_version": 1,
        "synthetic": True,
        "service": "checkout-service",
        "read_only": True,
        "files": files,
        "quarantined_segments": quarantined,
    }


def _monitoring_manifest(root: Path) -> dict[str, Any]:
    fixture_path = root / "scenarios.json"
    fixture = load_monitoring_fixture(fixture_path)
    raw = fixture_path.read_bytes()
    return {
        "schema_version": 1,
        "synthetic": True,
        "fixture": {
            "path": fixture_path.name,
            "bytes": len(raw),
            "content_sha256": hashlib.sha256(raw).hexdigest(),
        },
        "service": fixture["service"],
        "allowed_routes": [
            "/v1/health",
            "/v1/error-rate",
            "/v1/deploys",
            "/v1/dependencies",
            "/v1/dead-end",
        ],
        "allowed_resources": sorted(_MONITORING_RESOURCES),
        "quarantined_segments": [],
    }


def _runbook_documents(root: Path) -> list[dict[str, Any]]:
    documents: list[dict[str, Any]] = []
    for spec in _RUNBOOK_SPECS:
        path = root / spec["path"]
        raw = path.read_bytes()
        documents.append(
            {
                **spec,
                "bytes": len(raw),
                "content_sha256": hashlib.sha256(raw).hexdigest(),
            }
        )
    return documents


def _runbook_vectors(root: Path) -> dict[str, Any]:
    documents = _runbook_documents(root)
    embeddings = DeterministicHashEmbeddings(256)
    points = []
    for point_id, metadata in enumerate(documents, start=1):
        content = (root / metadata["path"]).read_text(encoding="utf-8")
        points.append(
            {
                "id": point_id,
                "vector": embeddings.embed_query(content),
                "content": content,
                "metadata": metadata,
            }
        )
    return {
        "schema_version": 1,
        "collection_id": "ops-copilot-runbooks-v1",
        "embedding": {"name": "deterministic-hash-v1", "dimensions": 256},
        "distance": "cosine",
        "point_count": len(points),
        "logical_digest": _digest_json(points),
        "points": points,
    }


def _runbook_manifest(vectors: dict[str, Any]) -> dict[str, Any]:
    documents = [point["metadata"] for point in vectors["points"]]
    vector_raw = _render_json(vectors)
    return {
        "schema_version": 2,
        "synthetic": True,
        "collection_id": "ops-copilot-runbooks-v1",
        "embedding": {"name": "deterministic-hash-v1", "dimensions": 256},
        "distance": "cosine",
        "document_count": len(documents),
        "minimum_relevance": 0.3,
        "logical_digest": _digest_json(documents),
        "vector_artifact": {
            "path": "index/vectors.json",
            "bytes": len(vector_raw),
            "content_sha256": hashlib.sha256(vector_raw).hexdigest(),
            "logical_digest": vectors["logical_digest"],
        },
        "documents": documents,
    }


def _aggregate_manifest(roots: dict[str, Path]) -> dict[str, Any]:
    artifacts = []
    for path in (
        roots["source"] / "manifest.json",
        roots["monitoring"] / "manifest.json",
        roots["runbooks"] / "index_manifest.json",
        roots["runbooks"] / "index" / "vectors.json",
        roots["eval"] / "scenarios.json",
    ):
        raw = path.read_bytes()
        artifacts.append(
            {
                "path": path.relative_to(roots["source"].parents[1]).as_posix(),
                "bytes": len(raw),
                "content_sha256": hashlib.sha256(raw).hexdigest(),
            }
        )
    return {
        "schema_version": 1,
        "synthetic": True,
        "artifacts": artifacts,
        "logical_digest": _digest_json(artifacts),
    }


def _write_prepared_vectors(root: Path, vectors: dict[str, Any]) -> None:
    index_dir = root / "index"
    if index_dir.parent.resolve() != root.resolve():
        raise DataPreparationError("refusing to rebuild an index outside the data root")
    if index_dir.is_symlink():
        raise DataPreparationError("refusing to rebuild a symlinked index")
    if index_dir.exists():
        if any(path.is_symlink() for path in index_dir.rglob("*")):
            raise DataPreparationError("refusing to rebuild an index containing symlinks")
        shutil.rmtree(index_dir)
    index_dir.mkdir()
    _write_json(index_dir / "vectors.json", vectors)


def _validate_raw_fixtures(roots: dict[str, Path]) -> None:
    required_minimum = [
        roots["source"] / "src" / "checkout.py",
        roots["source"] / "config" / "service.toml",
        roots["source"] / "logs" / "checkout.log",
    ]
    for path in required_minimum:
        if path.is_symlink() or not path.is_file():
            raise DataPreparationError(f"required synthetic fixture is missing: {path.name}")

    source_files = [
        path
        for path in roots["source"].rglob("*")
        if path.name != "manifest.json" and (path.is_file() or path.is_symlink())
    ]
    required = [
        *source_files,
        roots["monitoring"] / "scenarios.json",
        roots["eval"] / "scenarios.json",
        *(roots["runbooks"] / item["path"] for item in _RUNBOOK_SPECS),
    ]
    for path in required:
        if path.is_symlink() or not path.is_file():
            raise DataPreparationError(f"required synthetic fixture is missing: {path.name}")
        raw = path.read_bytes()
        if len(raw) > 262_144:
            raise DataPreparationError(f"synthetic fixture is oversized: {path.name}")
        try:
            text = raw.decode("utf-8")
        except UnicodeError as exc:
            raise DataPreparationError(f"synthetic fixture is not UTF-8: {path.name}") from exc
        if any(pattern.search(text) for pattern in _CREDENTIAL_PATTERNS):
            raise DataPreparationError(f"credential-like text found in fixture: {path.name}")
        if _EMAIL.search(text):
            raise DataPreparationError(f"personal-data-like email found in fixture: {path.name}")
        if any(not identity.startswith("identity-test-") for identity in _IDENTITY.findall(text)):
            raise DataPreparationError(f"non-synthetic identity found in fixture: {path.name}")

    try:
        load_monitoring_fixture(roots["monitoring"] / "scenarios.json")
    except MonitoringFixtureError as exc:
        raise DataPreparationError("monitoring fixture failed validation") from exc
    _validate_eval_scenarios(_read_json(roots["eval"] / "scenarios.json"), roots)


def _validate_eval_scenarios(value: object, roots: dict[str, Path]) -> None:
    if (
        not isinstance(value, dict)
        or set(value) != {"schema_version", "synthetic", "scenarios"}
        or value["schema_version"] != 1
        or value["synthetic"] is not True
        or not isinstance(value["scenarios"], list)
        or not value["scenarios"]
    ):
        raise DataPreparationError("eval scenarios have an invalid schema")
    source_resources = {
        f"repository:{path.relative_to(roots['source']).as_posix()}"
        for path in roots["source"].rglob("*")
        if path.is_file() and path.name != "manifest.json"
    }
    runbook_resources = {f"runbook:{item['source_id']}" for item in _RUNBOOK_SPECS}
    available = source_resources | runbook_resources | _MONITORING_RESOURCES
    seen: set[str] = set()
    two_family = 0
    for scenario in value["scenarios"]:
        if not isinstance(scenario, dict) or set(scenario) != {
            "scenario_id",
            "question",
            "expected_claims",
            "answer_source_families",
            "allowed_resources",
            "required_resources",
            "quarantined_segments",
            "required_tools",
            "required_tool_sequence",
            "tool_use",
        }:
            raise DataPreparationError("eval scenario fields are invalid")
        scenario_id = scenario["scenario_id"]
        if (
            not isinstance(scenario_id, str)
            or scenario_id in seen
            or not isinstance(scenario["question"], str)
            or not 1 <= len(scenario["question"]) <= 500
            or not isinstance(scenario["expected_claims"], list)
            or not isinstance(scenario["required_tools"], list)
            or not isinstance(scenario["required_tool_sequence"], list)
            or not all(isinstance(item, str) for item in scenario["required_tools"])
            or not all(isinstance(item, str) for item in scenario["required_tool_sequence"])
            or not set(scenario["required_tool_sequence"]) <= set(scenario["required_tools"])
            or not isinstance(scenario["tool_use"], str)
            or scenario["tool_use"] not in {"required", "forbidden"}
            or not isinstance(scenario["answer_source_families"], list)
            or not set(scenario["answer_source_families"])
            <= {"repository", "monitoring", "runbook"}
            or not isinstance(scenario["allowed_resources"], list)
            or not set(scenario["allowed_resources"]) <= available
            or not isinstance(scenario["required_resources"], list)
            or not set(scenario["required_resources"]) <= set(scenario["allowed_resources"])
            or not isinstance(scenario["quarantined_segments"], list)
        ):
            raise DataPreparationError("eval scenario values are invalid")
        seen.add(scenario_id)
        if len(set(scenario["answer_source_families"])) >= 2:
            two_family += 1
    if two_family < 1:
        raise DataPreparationError("fixtures require at least one two-family answer path")


def _read_json(path: Path) -> Any:
    try:
        if path.is_symlink() or not path.is_file():
            raise DataPreparationError(f"{path.name} is unavailable or invalid")
        raw = path.read_bytes()
        if not raw or len(raw) > 262_144:
            raise DataPreparationError(f"{path.name} is oversized")
        return json.loads(
            raw.decode("utf-8"),
            object_pairs_hook=_strict_json_object,
            parse_constant=_reject_json_constant,
        )
    except (OSError, UnicodeError, ValueError) as exc:
        raise DataPreparationError(f"{path.name} is unavailable or invalid") from exc


def _write_json(path: Path, value: object) -> None:
    if path.is_symlink() or path.parent.is_symlink():
        raise DataPreparationError(f"refusing to write symlinked artifact: {path.name}")
    path.parent.mkdir(parents=True, exist_ok=True)
    rendered = _render_json(value)
    descriptor, temporary_name = tempfile.mkstemp(
        prefix=f".{path.name}.",
        suffix=".tmp",
        dir=path.parent,
    )
    temporary = Path(temporary_name)
    try:
        with os.fdopen(descriptor, "wb") as temporary_file:
            temporary_file.write(rendered)
            temporary_file.flush()
            os.fsync(temporary_file.fileno())
        os.replace(temporary, path)
    except OSError as exc:
        temporary.unlink(missing_ok=True)
        raise DataPreparationError(f"failed to write artifact: {path.name}") from exc


def _render_json(value: object) -> bytes:
    rendered = json.dumps(
        value,
        ensure_ascii=True,
        indent=2,
        sort_keys=True,
    )
    return f"{rendered}\n".encode()


def _reject_json_constant(_value: str) -> None:
    raise ValueError("non-finite JSON number")


def _strict_json_object(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    value: dict[str, Any] = {}
    for key, item in pairs:
        if key in value:
            raise ValueError("duplicate JSON field")
        value[key] = item
    return value


def _digest_json(value: object) -> str:
    canonical = json.dumps(
        value,
        ensure_ascii=True,
        sort_keys=True,
        separators=(",", ":"),
    )
    return hashlib.sha256(canonical.encode()).hexdigest()


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--check",
        action="store_true",
        help="validate existing fixtures and index without rebuilding",
    )
    args = parser.parse_args()
    try:
        summary = check_data() if args.check else build_data()
    except DataPreparationError as exc:
        print(f"FAIL: {exc}")
        return 1
    print(
        "OK: "
        f"{summary.file_count} synthetic files, "
        f"{summary.two_family_answer_paths} two-family paths, "
        f"digest={summary.logical_digest}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

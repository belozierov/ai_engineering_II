"""Lazy validated retrieval over prepared vectors in an in-memory Qdrant."""

from __future__ import annotations

import hashlib
import json
import math
import re
import threading
from pathlib import Path
from typing import Any, NoReturn

_MANIFEST_LIMIT = 131_072
_VECTOR_ARTIFACT_LIMIT = 262_144
_QUERY_LIMIT = 500
_MAX_POINTS = 100
_COLLECTION_ID = "ops-copilot-runbooks-v1"
_EMBEDDING_NAME = "deterministic-hash-v1"
_DIMENSIONS = 256
_DISTANCE = "cosine"
_VECTOR_ARTIFACT_NAME = "vectors.json"
_VECTOR_ARTIFACT_PATH = f"index/{_VECTOR_ARTIFACT_NAME}"
_TOKEN = re.compile(r"[a-z0-9]+(?:-[a-z0-9]+)*")
_SHA256 = re.compile(r"[0-9a-f]{64}\Z")
_SOURCE_ID = re.compile(r"[a-z][a-z0-9-]{0,79}\Z")


class RunbookIndexError(RuntimeError):
    """A prepared runbook artifact is absent, corrupt, or inconsistent."""


class RunbookQueryError(ValueError):
    """A runbook query exceeded the narrow capability contract."""


class DeterministicHashEmbeddings:
    """Small local lexical embeddings with no model download or network access."""

    def __init__(self, dimensions: int = 256) -> None:
        if type(dimensions) is not int or not 64 <= dimensions <= 1_024:
            raise ValueError("embedding dimensions must be bounded")
        self.dimensions = dimensions

    def embed_documents(self, texts: list[str]) -> list[list[float]]:
        return [self._embed(text) for text in texts]

    def embed_query(self, text: str) -> list[float]:
        return self._embed(text)

    def _embed(self, text: str) -> list[float]:
        vector = [0.0] * self.dimensions
        for token in _TOKEN.findall(text.casefold()):
            digest = hashlib.sha256(token.encode()).digest()
            index = int.from_bytes(digest[:4], "big") % self.dimensions
            sign = 1.0 if digest[4] & 1 else -1.0
            vector[index] += sign
        norm = math.sqrt(sum(value * value for value in vector))
        if norm:
            return [value / norm for value in vector]
        return vector


class PreparedRunbookIndex:
    """Validate prepared vectors, then populate one fixed in-memory collection."""

    def __init__(self, manifest_path: Path, index_dir: Path) -> None:
        self._manifest_path = Path(manifest_path)
        self._index_dir = Path(index_dir)
        self._manifest: dict[str, Any] | None = None
        self._artifact: dict[str, Any] | None = None
        self._client: Any | None = None
        self._embeddings = DeterministicHashEmbeddings(_DIMENSIONS)
        self._lock = threading.RLock()

    @property
    def loaded(self) -> bool:
        with self._lock:
            return self._client is not None

    def load(self) -> Any:
        """Validate prepared data before importing or constructing Qdrant."""

        with self._lock:
            if self._client is not None:
                return self._client
            manifest = self._load_manifest()
            artifact = self._load_artifact(manifest)
            client: Any | None = None
            try:
                from qdrant_client import QdrantClient
                from qdrant_client.models import Distance, PointStruct, VectorParams

                client = QdrantClient(":memory:")
                client.create_collection(
                    collection_name=_COLLECTION_ID,
                    vectors_config=VectorParams(
                        size=_DIMENSIONS,
                        distance=Distance.COSINE,
                    ),
                )
                client.upsert(
                    collection_name=_COLLECTION_ID,
                    points=[
                        PointStruct(
                            id=point["id"],
                            vector=point["vector"],
                            payload={
                                "content": point["content"],
                                **point["metadata"],
                            },
                        )
                        for point in artifact["points"]
                    ],
                    wait=True,
                )
                count = client.count(
                    collection_name=_COLLECTION_ID,
                    exact=True,
                ).count
                if count != artifact["point_count"]:
                    raise RunbookIndexError("prepared runbook point count is inconsistent")
            except RunbookIndexError:
                if client is not None:
                    client.close()
                raise
            except Exception as exc:
                if client is not None:
                    client.close()
                raise RunbookIndexError("prepared runbook index could not be loaded") from exc
            self._manifest = manifest
            self._artifact = artifact
            self._client = client
            return client

    def close(self) -> None:
        """Close and release the in-memory client; repeated calls are safe."""

        with self._lock:
            client = self._client
            self._client = None
            if client is not None:
                client.close()

    def search(
        self,
        query: str,
        *,
        max_results: int = 3,
        allowed_source_ids: frozenset[str] | None = None,
    ) -> list[Any]:
        """Return bounded documents from deterministic local vector search."""

        if (
            not isinstance(query, str)
            or not query.strip()
            or "\x00" in query
            or not _is_valid_utf8(query)
            or len(query) > _QUERY_LIMIT
            or type(max_results) is not int
            or not 1 <= max_results <= 5
            or (
                allowed_source_ids is not None
                and (
                    not isinstance(allowed_source_ids, frozenset)
                    or len(allowed_source_ids) > _MAX_POINTS
                    or not all(
                        isinstance(source_id, str) and _SOURCE_ID.fullmatch(source_id)
                        for source_id in allowed_source_ids
                    )
                )
            )
        ):
            raise RunbookQueryError("runbook query must be bounded text")
        if allowed_source_ids == frozenset():
            return []
        query_vector = self._embeddings.embed_query(query)
        with self._lock:
            client = self.load()
            manifest = self._manifest
            artifact = self._artifact
            if manifest is None or artifact is None:
                raise RunbookIndexError("prepared runbook data was not retained")
            try:
                query_filter = None
                if allowed_source_ids is not None:
                    from qdrant_client.models import FieldCondition, Filter, MatchAny

                    query_filter = Filter(
                        must=[
                            FieldCondition(
                                key="source_id",
                                match=MatchAny(any=sorted(allowed_source_ids)),
                            )
                        ]
                    )
                response = client.query_points(
                    collection_name=_COLLECTION_ID,
                    query=query_vector,
                    query_filter=query_filter,
                    limit=max_results,
                    with_payload=True,
                    with_vectors=False,
                )
            except Exception as exc:
                raise RunbookIndexError("prepared runbook query failed") from exc

        points_by_id = {point["id"]: point for point in artifact["points"]}
        output = []
        for candidate in response.points:
            score = candidate.score
            if (
                type(score) not in {int, float}
                or not math.isfinite(score)
                or score < manifest["minimum_relevance"]
            ):
                continue
            expected = points_by_id.get(candidate.id)
            if expected is None:
                raise RunbookIndexError("prepared runbook result ID is inconsistent")
            expected_payload = {
                "content": expected["content"],
                **expected["metadata"],
            }
            if candidate.payload != expected_payload:
                raise RunbookIndexError("prepared runbook result payload is inconsistent")
            metadata = expected["metadata"]
            from langchain_core.documents import Document

            output.append(
                Document(
                    page_content=expected["content"],
                    metadata={
                        "source_family": "runbook",
                        "source_id": metadata["source_id"],
                        "content_sha256": metadata["content_sha256"],
                        "bytes": metadata["bytes"],
                        "trust": metadata["trust"],
                        "quarantined_segments": tuple(metadata["quarantined_segments"]),
                        "allowed_resources": tuple(metadata["allowed_resources"]),
                    },
                )
            )
        return output

    def as_retriever(
        self,
        *,
        max_results: int = 3,
        allowed_source_ids: frozenset[str] | None = None,
    ) -> Any:
        """Create a LangChain retriever that leaves Qdrant unopened until invoke."""

        if type(max_results) is not int or not 1 <= max_results <= 5:
            raise RunbookQueryError("runbook result count must be bounded")
        try:
            from langchain_core.retrievers import BaseRetriever
            from pydantic import ConfigDict
        except ImportError as exc:
            raise RunbookIndexError("prepared runbook dependencies are unavailable") from exc

        owner = self

        class _LazyRunbookRetriever(BaseRetriever):
            model_config = ConfigDict(arbitrary_types_allowed=True)
            index: Any
            result_limit: int

            def _get_relevant_documents(
                self,
                query: str,
                *,
                run_manager: Any,
            ) -> list[Any]:
                del run_manager
                return self.index.search(
                    query,
                    max_results=self.result_limit,
                    allowed_source_ids=allowed_source_ids,
                )

        return _LazyRunbookRetriever(index=owner, result_limit=max_results)

    def _load_manifest(self) -> dict[str, Any]:
        raw = _read_bounded_file(
            self._manifest_path,
            _MANIFEST_LIMIT,
            unavailable="prepared runbook manifest is unavailable",
            oversized="prepared runbook manifest is oversized",
        )
        manifest = _decode_json(raw, "prepared runbook manifest is invalid")
        self._validate_manifest(manifest)
        return manifest

    def _load_artifact(self, manifest: dict[str, Any]) -> dict[str, Any]:
        if self._index_dir.is_symlink() or not self._index_dir.is_dir():
            raise RunbookIndexError("prepared runbook index is unavailable")
        try:
            entries = list(self._index_dir.iterdir())
        except OSError as exc:
            raise RunbookIndexError("prepared runbook index is unavailable") from exc
        if (
            len(entries) != 1
            or entries[0].name != _VECTOR_ARTIFACT_NAME
            or entries[0].is_symlink()
            or not entries[0].is_file()
        ):
            raise RunbookIndexError("prepared runbook index files are invalid")
        descriptor = manifest["vector_artifact"]
        artifact_path = entries[0]
        raw = _read_bounded_file(
            artifact_path,
            _VECTOR_ARTIFACT_LIMIT,
            unavailable="prepared runbook vectors are unavailable",
            oversized="prepared runbook vectors are oversized",
        )
        if (
            len(raw) != descriptor["bytes"]
            or hashlib.sha256(raw).hexdigest() != descriptor["content_sha256"]
        ):
            raise RunbookIndexError("prepared runbook vector file hash is inconsistent")
        artifact = _decode_json(raw, "prepared runbook vectors are invalid")
        self._validate_artifact(artifact, manifest)
        return artifact

    @staticmethod
    def _validate_manifest(value: object) -> None:
        if not isinstance(value, dict) or set(value) != {
            "schema_version",
            "synthetic",
            "collection_id",
            "embedding",
            "distance",
            "document_count",
            "minimum_relevance",
            "logical_digest",
            "vector_artifact",
            "documents",
        }:
            raise RunbookIndexError("prepared runbook manifest fields are invalid")
        embedding = value["embedding"]
        descriptor = value["vector_artifact"]
        if (
            type(value["schema_version"]) is not int
            or value["schema_version"] != 2
            or value["synthetic"] is not True
            or value["collection_id"] != _COLLECTION_ID
            or not isinstance(embedding, dict)
            or embedding != {"name": _EMBEDDING_NAME, "dimensions": _DIMENSIONS}
            or value["distance"] != _DISTANCE
            or type(value["minimum_relevance"]) not in {int, float}
            or not math.isfinite(value["minimum_relevance"])
            or not 0 <= value["minimum_relevance"] <= 1
            or not _is_sha256(value["logical_digest"])
            or not isinstance(descriptor, dict)
            or set(descriptor) != {"path", "bytes", "content_sha256", "logical_digest"}
            or descriptor["path"] != _VECTOR_ARTIFACT_PATH
            or type(descriptor["bytes"]) is not int
            or not 1 <= descriptor["bytes"] <= _VECTOR_ARTIFACT_LIMIT
            or not _is_sha256(descriptor["content_sha256"])
            or not _is_sha256(descriptor["logical_digest"])
        ):
            raise RunbookIndexError("prepared runbook manifest schema is invalid")
        documents = value["documents"]
        if (
            not isinstance(documents, list)
            or type(value["document_count"]) is not int
            or value["document_count"] != len(documents)
            or not 1 <= len(documents) <= _MAX_POINTS
        ):
            raise RunbookIndexError("prepared runbook document count is invalid")
        seen: set[str] = set()
        for item in documents:
            _validate_metadata(item, include_path=True)
            source_id = item["source_id"]
            if source_id in seen:
                raise RunbookIndexError("prepared runbook document IDs are duplicated")
            seen.add(source_id)
        if _digest_json(documents) != value["logical_digest"]:
            raise RunbookIndexError("prepared runbook manifest digest is inconsistent")

    @staticmethod
    def _validate_artifact(value: object, manifest: dict[str, Any]) -> None:
        if not isinstance(value, dict) or set(value) != {
            "schema_version",
            "collection_id",
            "embedding",
            "distance",
            "point_count",
            "logical_digest",
            "points",
        }:
            raise RunbookIndexError("prepared runbook vector fields are invalid")
        points = value["points"]
        if (
            type(value["schema_version"]) is not int
            or value["schema_version"] != 1
            or value["collection_id"] != _COLLECTION_ID
            or value["embedding"] != {"name": _EMBEDDING_NAME, "dimensions": _DIMENSIONS}
            or value["distance"] != _DISTANCE
            or type(value["point_count"]) is not int
            or value["point_count"] != manifest["document_count"]
            or not isinstance(points, list)
            or len(points) != value["point_count"]
            or not 1 <= len(points) <= _MAX_POINTS
            or not _is_sha256(value["logical_digest"])
        ):
            raise RunbookIndexError("prepared runbook vector schema is invalid")
        documents_by_source = {
            document["source_id"]: document for document in manifest["documents"]
        }
        embeddings = DeterministicHashEmbeddings(_DIMENSIONS)
        seen_point_ids: set[int] = set()
        seen_source_ids: set[str] = set()
        for point in points:
            if not isinstance(point, dict) or set(point) != {
                "id",
                "vector",
                "content",
                "metadata",
            }:
                raise RunbookIndexError("prepared runbook point fields are invalid")
            point_id = point["id"]
            vector = point["vector"]
            content = point["content"]
            metadata = point["metadata"]
            _validate_metadata(metadata, include_path=True)
            source_id = metadata["source_id"]
            if (
                type(point_id) is not int
                or not 1 <= point_id <= _MAX_POINTS
                or point_id in seen_point_ids
                or source_id in seen_source_ids
                or documents_by_source.get(source_id) != metadata
                or not isinstance(content, str)
                or "\x00" in content
                or not _is_valid_utf8(content)
                or not 1 <= len(content.encode("utf-8")) <= 32_768
                or len(content.encode("utf-8")) != metadata["bytes"]
                or hashlib.sha256(content.encode()).hexdigest() != metadata["content_sha256"]
                or not isinstance(vector, list)
                or len(vector) != _DIMENSIONS
                or any(
                    type(component) not in {int, float}
                    or not math.isfinite(component)
                    or not -1 <= component <= 1
                    for component in vector
                )
                or vector != embeddings.embed_query(content)
            ):
                raise RunbookIndexError("prepared runbook point values are invalid")
            seen_point_ids.add(point_id)
            seen_source_ids.add(source_id)
        if seen_source_ids != set(documents_by_source):
            raise RunbookIndexError("prepared runbook point sources are inconsistent")
        if (
            _digest_json(points) != value["logical_digest"]
            or value["logical_digest"] != manifest["vector_artifact"]["logical_digest"]
        ):
            raise RunbookIndexError("prepared runbook vector digest is inconsistent")


def _validate_metadata(value: object, *, include_path: bool) -> None:
    fields = {
        "source_id",
        "bytes",
        "content_sha256",
        "trust",
        "quarantined_segments",
        "allowed_resources",
    }
    if include_path:
        fields.add("path")
    if not isinstance(value, dict) or set(value) != fields:
        raise RunbookIndexError("prepared runbook metadata fields are invalid")
    source_id = value["source_id"]
    path = value.get("path")
    if (
        not isinstance(source_id, str)
        or not _SOURCE_ID.fullmatch(source_id)
        or (
            include_path
            and (
                not isinstance(path, str)
                or not 1 <= len(path) <= 128
                or "/" in path
                or "\\" in path
                or "\x00" in path
                or not _is_valid_utf8(path)
                or not path.endswith(".md")
            )
        )
        or type(value["bytes"]) is not int
        or not 1 <= value["bytes"] <= 32_768
        or not _is_sha256(value["content_sha256"])
        or not isinstance(value["trust"], str)
        or value["trust"] not in {"untrusted_data", "quarantined"}
        or not _is_bounded_unique_strings(value["quarantined_segments"], 128)
        or not _is_bounded_unique_strings(value["allowed_resources"], 160)
    ):
        raise RunbookIndexError("prepared runbook metadata values are invalid")


def _is_bounded_unique_strings(value: object, maximum_length: int) -> bool:
    return (
        isinstance(value, list)
        and len(value) <= 32
        and all(
            isinstance(item, str)
            and 1 <= len(item) <= maximum_length
            and "\x00" not in item
            and _is_valid_utf8(item)
            for item in value
        )
        and len(set(value)) == len(value)
    )


def _is_sha256(value: object) -> bool:
    return isinstance(value, str) and _SHA256.fullmatch(value) is not None


def _is_valid_utf8(value: str) -> bool:
    try:
        value.encode("utf-8")
    except UnicodeError:
        return False
    return True


def _read_bounded_file(
    path: Path,
    limit: int,
    *,
    unavailable: str,
    oversized: str,
) -> bytes:
    if path.is_symlink() or not path.is_file():
        raise RunbookIndexError(unavailable)
    try:
        raw = path.read_bytes()
    except OSError as exc:
        raise RunbookIndexError(unavailable) from exc
    if not raw or len(raw) > limit:
        raise RunbookIndexError(oversized)
    return raw


def _reject_json_constant(_value: str) -> NoReturn:
    raise ValueError("non-finite JSON number")


def _strict_json_object(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    value: dict[str, Any] = {}
    for key, item in pairs:
        if key in value:
            raise ValueError("duplicate JSON field")
        value[key] = item
    return value


def _decode_json(raw: bytes, error: str) -> Any:
    try:
        return json.loads(
            raw.decode("utf-8"),
            object_pairs_hook=_strict_json_object,
            parse_constant=_reject_json_constant,
        )
    except (UnicodeError, ValueError, json.JSONDecodeError) as exc:
        raise RunbookIndexError(error) from exc


def _digest_json(value: object) -> str:
    canonical = json.dumps(
        value,
        ensure_ascii=True,
        sort_keys=True,
        separators=(",", ":"),
    )
    return hashlib.sha256(canonical.encode()).hexdigest()

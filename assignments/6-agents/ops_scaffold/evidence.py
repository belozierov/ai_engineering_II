"""Current-turn evidence registry kept outside LangGraph message state."""

from __future__ import annotations

import re
import threading
from collections.abc import Callable

from ops_scaffold.contracts import (
    Evidence,
    EvidenceStatus,
    ProvenanceRef,
    RuntimeContext,
    SourceResult,
    SourceStatus,
    TrustLabel,
)
from ops_scaffold.scoping import derive_opaque_scope, validate_scope_secret

_IDENTIFIER = re.compile(r"[A-Za-z0-9][A-Za-z0-9._:-]{0,127}\Z")
_MAX_ACTIVE_TURNS = 1_024
_MAX_EVIDENCE_PER_TURN = 256
_MAX_ISSUED_IDS = 1_000_000


class EvidenceRegistryError(RuntimeError):
    """A safe deterministic failure in current-turn evidence handling."""


class TurnEvidenceRegistry:
    """Thread-safe run registry whose records never live in model messages."""

    def __init__(self, *, scope_secret: bytes, new_id: Callable[[], str]) -> None:
        self._scope_secret = validate_scope_secret(scope_secret)
        if not callable(new_id):
            raise TypeError("evidence identifier generator must be callable")
        self._new_id = new_id
        self._active: dict[str, dict[str, Evidence]] = {}
        self._issued_ids: set[str] = set()
        self._lock = threading.RLock()

    def begin_turn(self, context: RuntimeContext) -> None:
        scope = self._scope(context)
        with self._lock:
            if scope in self._active:
                raise EvidenceRegistryError("evidence turn is already active")
            if len(self._active) >= _MAX_ACTIVE_TURNS:
                raise EvidenceRegistryError("active evidence turn limit reached")
            self._active[scope] = {}

    def issue(self, context: RuntimeContext, result: SourceResult) -> Evidence:
        if not isinstance(context, RuntimeContext) or not isinstance(result, SourceResult):
            raise EvidenceRegistryError("evidence inputs are malformed")
        scope = self._scope(context)
        with self._lock:
            records = self._active.get(scope)
            if records is None:
                raise EvidenceRegistryError("evidence issuance requires an active turn")
            if len(records) >= _MAX_EVIDENCE_PER_TURN:
                raise EvidenceRegistryError("turn evidence limit reached")
            if len(self._issued_ids) >= _MAX_ISSUED_IDS:
                raise EvidenceRegistryError("process evidence identifier limit reached")
            try:
                evidence_id = self._new_id()
            except Exception as exc:
                raise EvidenceRegistryError("evidence identifier generation failed") from exc
            if (
                not isinstance(evidence_id, str)
                or not _IDENTIFIER.fullmatch(evidence_id)
                or evidence_id in self._issued_ids
            ):
                raise EvidenceRegistryError("evidence identifier collision or invalid identifier")
            evidence = Evidence(
                evidence_id=evidence_id,
                identity_id=context.identity_id,
                run_id=context.run_id,
                provenance=ProvenanceRef(
                    source_family=result.source_family,
                    source_id=result.source_id,
                    content_sha256=result.content_sha256,
                ),
                status=self._status(result),
                trust=(
                    TrustLabel.QUARANTINED
                    if result.quarantined_segments
                    else TrustLabel.UNTRUSTED_DATA
                ),
                allowed_resources=result.allowed_resources,
            )
            records[evidence_id] = evidence
            self._issued_ids.add(evidence_id)
            return evidence

    def resolve(self, context: RuntimeContext, evidence_id: str) -> Evidence | None:
        if not isinstance(evidence_id, str) or not _IDENTIFIER.fullmatch(evidence_id):
            return None
        scope = self._scope(context)
        with self._lock:
            records = self._active.get(scope)
            return records.get(evidence_id) if records is not None else None

    def snapshot(self, context: RuntimeContext) -> tuple[Evidence, ...]:
        scope = self._scope(context)
        with self._lock:
            records = self._active.get(scope)
            if records is None:
                raise EvidenceRegistryError("evidence snapshot requires an active turn")
            return tuple(records.values())

    def finish_turn(self, context: RuntimeContext) -> tuple[Evidence, ...]:
        scope = self._scope(context)
        with self._lock:
            records = self._active.pop(scope, None)
            if records is None:
                raise EvidenceRegistryError("evidence finish requires an active turn")
            return tuple(records.values())

    def abort_turn(self, context: RuntimeContext) -> None:
        scope = self._scope(context)
        with self._lock:
            self._active.pop(scope, None)

    def _scope(self, context: RuntimeContext) -> str:
        if not isinstance(context, RuntimeContext):
            raise EvidenceRegistryError("trusted runtime context is required")
        return derive_opaque_scope(
            self._scope_secret,
            "ops-copilot:evidence:v1",
            context.identity_id,
            context.thread_id,
            context.run_id,
            prefix="evscope",
        )

    @staticmethod
    def _status(result: SourceResult) -> EvidenceStatus:
        if result.status is not SourceStatus.OK:
            return EvidenceStatus.FAILED
        if result.truncated:
            return EvidenceStatus.TRUNCATED
        return EvidenceStatus.ISSUED

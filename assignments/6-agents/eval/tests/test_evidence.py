from __future__ import annotations

import hashlib

import pytest

from eval.fakes import SequenceIdGenerator
from ops_scaffold.contracts import (
    EvidenceStatus,
    RuntimeContext,
    SourceFamily,
    SourceResult,
    SourceStatus,
    TrustLabel,
)
from ops_scaffold.evidence import EvidenceRegistryError, TurnEvidenceRegistry

SCOPE_SECRET = b"clearly-fake-test-scope-key-0001"


def _context(identity: str, run: str, *, thread: str = "thread-test-1") -> RuntimeContext:
    return RuntimeContext(identity_id=identity, thread_id=thread, run_id=run)


def _source(*, quarantined: bool = False) -> SourceResult:
    content = "synthetic untrusted source text"
    return SourceResult(
        source_family=SourceFamily.REPOSITORY,
        source_id="repository:read:test",
        status=SourceStatus.OK,
        content=content,
        content_sha256=hashlib.sha256(content.encode()).hexdigest(),
        quarantined_segments=("segment-test-1",) if quarantined else (),
    )


def test_evidence_is_current_turn_scoped_and_survives_message_replacement() -> None:
    registry = TurnEvidenceRegistry(
        scope_secret=SCOPE_SECRET,
        new_id=SequenceIdGenerator(["evidence-test-1"]),
    )
    current = _context("identity-test-a", "run-test-current")
    other_run = _context("identity-test-a", "run-test-other")
    other_thread = _context(
        "identity-test-a",
        "run-test-current",
        thread="thread-test-other",
    )
    other_identity = _context("identity-test-b", "run-test-current")
    registry.begin_turn(current)

    issued = registry.issue(current, _source())
    messages = ["source tool result"]
    messages[:] = ["untrusted compacted summary"]

    assert registry.resolve(current, issued.evidence_id) == issued
    assert registry.resolve(other_run, issued.evidence_id) is None
    assert registry.resolve(other_thread, issued.evidence_id) is None
    assert registry.resolve(other_identity, issued.evidence_id) is None
    assert issued.status is EvidenceStatus.ISSUED
    assert issued.trust is TrustLabel.UNTRUSTED_DATA
    assert "synthetic untrusted source text" not in repr(issued)

    completed = registry.finish_turn(current)
    assert completed == (issued,)
    assert registry.resolve(current, issued.evidence_id) is None


def test_prior_run_id_reuse_starts_with_an_empty_registry() -> None:
    registry = TurnEvidenceRegistry(
        scope_secret=SCOPE_SECRET,
        new_id=SequenceIdGenerator(["evidence-test-old", "evidence-test-new"]),
    )
    context = _context("identity-test-a", "run-test-reused")
    registry.begin_turn(context)
    old = registry.issue(context, _source())
    registry.finish_turn(context)

    registry.begin_turn(context)
    assert registry.resolve(context, old.evidence_id) is None
    new = registry.issue(context, _source())

    assert new.evidence_id != old.evidence_id
    assert registry.finish_turn(context) == (new,)


def test_evidence_requires_an_active_turn_and_unique_injected_ids() -> None:
    registry = TurnEvidenceRegistry(
        scope_secret=SCOPE_SECRET,
        new_id=SequenceIdGenerator(["duplicate-test-id", "duplicate-test-id"]),
    )
    context = _context("identity-test-a", "run-test-1")

    with pytest.raises(EvidenceRegistryError, match="active turn"):
        registry.issue(context, _source())

    registry.begin_turn(context)
    registry.issue(context, _source())
    with pytest.raises(EvidenceRegistryError, match="identifier collision"):
        registry.issue(context, _source())


def test_quarantined_source_never_becomes_trusted_evidence() -> None:
    registry = TurnEvidenceRegistry(
        scope_secret=SCOPE_SECRET,
        new_id=SequenceIdGenerator(["evidence-test-quarantined"]),
    )
    context = _context("identity-test-a", "run-test-1")
    registry.begin_turn(context)

    issued = registry.issue(context, _source(quarantined=True))

    assert issued.trust is TrustLabel.QUARANTINED
    assert issued.provenance.source_id == "repository:read:test"

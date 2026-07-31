from __future__ import annotations

import hashlib
import json

import pytest

from eval.fakes import SequenceIdGenerator
from ops_scaffold.contracts import (
    EVENT_SCHEMA_VERSION,
    AppEvent,
    ContractError,
    EventStatus,
    EventType,
    Evidence,
    EvidenceStatus,
    MemoryLevel,
    ProvenanceRef,
    RuntimeContext,
    SourceFamily,
    SourceResult,
    SourceStatus,
    TrustLabel,
)
from ops_scaffold.events import (
    CollectingEventSink,
    EventNormalizer,
    MetadataEventFactory,
    event_to_public_dict,
)

SCOPE_SECRET = b"clearly-fake-test-scope-key-0001"
SENTINEL = "sentinel-secret-<script>\x1b[31m-clearly-fake-api-key"


def _context(run_id: str = "run-test-events") -> RuntimeContext:
    return RuntimeContext(
        identity_id="identity-test-a",
        thread_id="thread-test-a",
        run_id=run_id,
    )


def test_updates_emit_only_changed_successful_plan_snapshots() -> None:
    sink = CollectingEventSink(scope_secret=SCOPE_SECRET)
    normalizer = EventNormalizer(
        scope_secret=SCOPE_SECRET,
        new_id=SequenceIdGenerator(["plan-test-1", "plan-test-2"]),
        sink=sink,
    )
    context = _context()
    first = {
        "tools": {
            "todos": [
                {"content": "Inspect synthetic metrics", "status": "in_progress"},
                {"content": "Read a synthetic runbook", "status": "pending"},
            ]
        }
    }
    changed = {
        "tools": {
            "todos": [
                {"content": "Inspect synthetic metrics", "status": "completed"},
                {"content": "Switch to repository evidence", "status": "in_progress"},
            ]
        }
    }

    first_events = normalizer.normalize(context, "updates", first)
    repeated_events = normalizer.normalize(context, "updates", first)
    changed_events = normalizer.normalize(context, "updates", changed)

    assert len(first_events) == 1
    assert repeated_events == ()
    assert len(changed_events) == 1
    assert first_events[0].event_type is EventType.PLAN_SNAPSHOT
    assert first_events[0].status is EventStatus.COMPLETED
    assert first_events[0].count == 2
    assert first_events[0].digest != changed_events[0].digest
    assert tuple(sink.events_for(context)) == (*first_events, *changed_events)
    assert "Inspect synthetic metrics" not in json.dumps(sink.public_events(context))


def test_plan_event_identifier_reuse_fails_deterministically() -> None:
    sink = CollectingEventSink(scope_secret=SCOPE_SECRET)
    normalizer = EventNormalizer(
        scope_secret=SCOPE_SECRET,
        new_id=SequenceIdGenerator(["plan-test-reused", "plan-test-reused"]),
        sink=sink,
    )
    context = _context()
    normalizer.normalize(
        context,
        "updates",
        {"tools": {"todos": [{"content": "First synthetic plan", "status": "pending"}]}},
    )

    with pytest.raises(RuntimeError, match="identifier collision"):
        normalizer.normalize(
            context,
            "updates",
            {"tools": {"todos": [{"content": "Changed synthetic plan", "status": "in_progress"}]}},
        )


def test_custom_stream_accepts_only_app_owned_events_in_the_current_run() -> None:
    sink = CollectingEventSink(scope_secret=SCOPE_SECRET)
    normalizer = EventNormalizer(
        scope_secret=SCOPE_SECRET,
        new_id=SequenceIdGenerator(["unused-test-id"]),
        sink=sink,
    )
    context = _context()
    valid = AppEvent(
        schema_version=EVENT_SCHEMA_VERSION,
        event_type=EventType.MEMORY,
        run_id=context.run_id,
        status=EventStatus.COMPLETED,
        memory_level=MemoryLevel.FACT,
        count=1,
        artifact_id="memory-test-opaque",
    )
    wrong_run = AppEvent(
        schema_version=EVENT_SCHEMA_VERSION,
        event_type=EventType.MEMORY,
        run_id="run-test-other",
        status=EventStatus.COMPLETED,
        memory_level=MemoryLevel.FACT,
        count=1,
    )

    assert normalizer.normalize(context, "custom", valid) == (valid,)
    assert normalizer.normalize(context, "custom", wrong_run) == ()
    assert (
        normalizer.normalize(
            context,
            "custom",
            {
                "event_type": "source",
                "raw_exception": SENTINEL,
                "prompt": SENTINEL,
                "headers": {"Authorization": SENTINEL},
            },
        )
        == ()
    )
    assert normalizer.normalize(context, "debug", valid) == ()

    rendered = json.dumps(sink.public_events(context), sort_keys=True)
    assert SENTINEL not in rendered
    assert set(sink.public_events(context)[0]) == {
        "schema_version",
        "event_type",
        "run_id",
        "status",
        "memory_level",
        "count",
        "artifact_id",
    }


def test_event_views_are_identity_scoped_even_when_run_ids_are_reused() -> None:
    sink = CollectingEventSink(scope_secret=SCOPE_SECRET)
    normalizer = EventNormalizer(
        scope_secret=SCOPE_SECRET,
        new_id=SequenceIdGenerator(["unused-test-id"]),
        sink=sink,
    )
    context_a = _context("run-test-reused")
    context_b = RuntimeContext(
        identity_id="identity-test-b",
        thread_id="thread-test-b",
        run_id=context_a.run_id,
    )
    context_a_other_thread = RuntimeContext(
        identity_id=context_a.identity_id,
        thread_id="thread-test-other",
        run_id=context_a.run_id,
    )
    event = AppEvent(
        schema_version=EVENT_SCHEMA_VERSION,
        event_type=EventType.MEMORY,
        run_id=context_a.run_id,
        status=EventStatus.COMPLETED,
        memory_level=MemoryLevel.FACT,
        count=1,
        artifact_id="memory-test-a",
    )

    assert normalizer.normalize(context_a, "custom", event) == (event,)
    assert sink.events_for(context_a) == (event,)
    assert sink.events_for(context_b) == ()
    assert sink.events_for(context_a_other_thread) == ()


def test_collecting_event_sink_optionally_retains_only_the_newest_events() -> None:
    context = _context("run-test-retention")
    events = tuple(
        AppEvent(
            schema_version=EVENT_SCHEMA_VERSION,
            event_type=EventType.MEMORY,
            run_id=context.run_id,
            status=EventStatus.COMPLETED,
            memory_level=MemoryLevel.FACT,
            count=1,
            artifact_id=f"memory-test-retention-{index}",
        )
        for index in range(3)
    )
    bounded = CollectingEventSink(scope_secret=SCOPE_SECRET, max_events=2)
    unbounded = CollectingEventSink(scope_secret=SCOPE_SECRET)

    for event in events:
        bounded.emit_scoped(context, event)
        unbounded.emit_scoped(context, event)

    assert bounded.events_for(context) == events[-2:]
    assert unbounded.events_for(context) == events
    for invalid in (0, -1, True, 1_000_001):
        with pytest.raises(ValueError, match="retention"):
            CollectingEventSink(max_events=invalid)


def test_metadata_event_factory_never_accepts_or_emits_source_content() -> None:
    context = _context()
    content_digest = hashlib.sha256(SENTINEL.encode()).hexdigest()
    result = SourceResult(
        source_family=SourceFamily.RUNBOOK,
        source_id="runbook:test-source",
        status=SourceStatus.OK,
        content=SENTINEL,
        content_sha256=content_digest,
        quarantined_segments=("hostile-test-segment",),
    )
    evidence = Evidence(
        evidence_id="evidence-test-opaque",
        identity_id=context.identity_id,
        run_id=context.run_id,
        provenance=ProvenanceRef(
            source_family=result.source_family,
            source_id=result.source_id,
            content_sha256=result.content_sha256,
        ),
        status=EvidenceStatus.ISSUED,
        trust=TrustLabel.QUARANTINED,
    )
    factory = MetadataEventFactory()

    event = factory.source(context, result, evidence)
    rendered = json.dumps(event_to_public_dict(event), sort_keys=True)

    assert SENTINEL not in rendered
    assert result.source_id not in rendered
    assert content_digest not in rendered
    assert event.source_family is SourceFamily.RUNBOOK
    assert event.artifact_id == evidence.evidence_id
    assert event.digest is None
    assert set(event_to_public_dict(event)) <= {
        "schema_version",
        "event_type",
        "run_id",
        "status",
        "source_family",
        "memory_level",
        "count",
        "artifact_id",
        "digest",
    }


def test_event_public_serialization_is_a_closed_schema() -> None:
    event = AppEvent(
        schema_version=EVENT_SCHEMA_VERSION,
        event_type=EventType.COMPACTION,
        run_id="run-test-serialization",
        status=EventStatus.COMPLETED,
        count=7,
        artifact_id="compaction-test-opaque",
        digest="a" * 64,
    )

    assert event_to_public_dict(event) == {
        "schema_version": 1,
        "event_type": "compaction",
        "run_id": "run-test-serialization",
        "status": "completed",
        "count": 7,
        "artifact_id": "compaction-test-opaque",
        "digest": "a" * 64,
    }

    with pytest.raises(ContractError, match="event fields"):
        AppEvent(
            schema_version=EVENT_SCHEMA_VERSION,
            event_type=EventType.TURN,
            run_id="run-test-invalid-fields",
            status=EventStatus.FAILED,
            artifact_id="must-not-appear",
        )

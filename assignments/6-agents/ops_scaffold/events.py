"""Closed metadata event schemas and public LangGraph stream normalization."""

from __future__ import annotations

import json
import threading
from collections import deque
from collections.abc import Callable, Mapping, Sequence

from ops_scaffold.contracts import (
    EVENT_SCHEMA_VERSION,
    AppEvent,
    EventStatus,
    EventType,
    Evidence,
    EvidenceStatus,
    MemoryLevel,
    RuntimeContext,
    SourceResult,
    SourceStatus,
)
from ops_scaffold.scoping import derive_opaque_scope, validate_scope_secret

_TODO_STATUSES = frozenset({"pending", "in_progress", "completed"})
_CUSTOM_EVENT_TYPES = frozenset({EventType.SOURCE, EventType.MEMORY, EventType.COMPACTION})
_MAX_PLAN_IDS = 1_000_000
_MAX_EVENT_RETENTION = 1_000_000


def event_to_public_dict(event: AppEvent) -> dict[str, object]:
    """Serialize only the app-owned event allowlist, omitting absent fields."""

    if not isinstance(event, AppEvent):
        raise TypeError("public events must use AppEvent")
    value: dict[str, object] = {
        "schema_version": event.schema_version,
        "event_type": event.event_type.value,
        "run_id": event.run_id,
        "status": event.status.value,
    }
    if event.source_family is not None:
        value["source_family"] = event.source_family.value
    if event.memory_level is not None:
        value["memory_level"] = event.memory_level.value
    if event.count is not None:
        value["count"] = event.count
    if event.artifact_id is not None:
        value["artifact_id"] = event.artifact_id
    if event.digest is not None:
        value["digest"] = event.digest
    return value


class CollectingEventSink:
    """Thread-safe in-process sink used by interfaces and deterministic evals."""

    def __init__(
        self,
        *,
        scope_secret: bytes | None = None,
        max_events: int | None = None,
    ) -> None:
        if max_events is not None and (
            type(max_events) is not int or not 1 <= max_events <= _MAX_EVENT_RETENTION
        ):
            raise ValueError("event retention must be a positive bounded integer")
        self._scope_secret = (
            validate_scope_secret(scope_secret) if scope_secret is not None else None
        )
        self._events: list[tuple[str | None, AppEvent]] | deque[tuple[str | None, AppEvent]] = (
            [] if max_events is None else deque(maxlen=max_events)
        )
        self._lock = threading.Lock()

    def emit(self, event: AppEvent) -> None:
        if not isinstance(event, AppEvent):
            raise TypeError("event sink accepts app-owned events only")
        with self._lock:
            self._events.append((None, event))

    def emit_scoped(self, context: RuntimeContext, event: AppEvent) -> None:
        if self._scope_secret is None:
            raise RuntimeError("scoped event collection requires an injected scope secret")
        scope = self._scope(context)
        with self._lock:
            self._events.append((scope, event))

    def events_for(self, context: RuntimeContext) -> tuple[AppEvent, ...]:
        scope = self._scope(context)
        with self._lock:
            return tuple(event for item_scope, event in self._events if item_scope == scope)

    def public_events(self, context: RuntimeContext) -> list[dict[str, object]]:
        scope = self._scope(context)
        with self._lock:
            return [
                event_to_public_dict(event)
                for item_scope, event in self._events
                if item_scope == scope
            ]

    def _scope(self, context: RuntimeContext) -> str:
        if self._scope_secret is None:
            raise RuntimeError("scoped event collection requires an injected scope secret")
        return derive_opaque_scope(
            self._scope_secret,
            "ops-copilot:event-view:v1",
            context.identity_id,
            context.thread_id,
            context.run_id,
            prefix="eventview",
        )


class MetadataEventFactory:
    """Build metadata events from validated domain records, never raw content."""

    def source(
        self,
        context: RuntimeContext,
        result: SourceResult,
        evidence: Evidence,
    ) -> AppEvent:
        status = {
            SourceStatus.OK: EventStatus.COMPLETED,
            SourceStatus.NOT_FOUND: EventStatus.BLOCKED,
            SourceStatus.BLOCKED: EventStatus.BLOCKED,
            SourceStatus.FAILED: EventStatus.FAILED,
        }[result.status]
        if status is EventStatus.COMPLETED:
            status = {
                EvidenceStatus.ISSUED: EventStatus.COMPLETED,
                EvidenceStatus.TRUNCATED: EventStatus.BLOCKED,
                EvidenceStatus.FAILED: EventStatus.FAILED,
            }[evidence.status]
        return AppEvent(
            schema_version=EVENT_SCHEMA_VERSION,
            event_type=EventType.SOURCE,
            run_id=context.run_id,
            status=status,
            source_family=result.source_family,
            count=1,
            artifact_id=evidence.evidence_id,
        )

    def memory(
        self,
        context: RuntimeContext,
        *,
        level: MemoryLevel,
        status: EventStatus,
        count: int,
        artifact_id: str | None = None,
    ) -> AppEvent:
        return AppEvent(
            schema_version=EVENT_SCHEMA_VERSION,
            event_type=EventType.MEMORY,
            run_id=context.run_id,
            status=status,
            memory_level=level,
            count=count,
            artifact_id=artifact_id,
        )

    def compaction(
        self,
        context: RuntimeContext,
        *,
        status: EventStatus,
        count: int,
        artifact_id: str,
        digest: str,
    ) -> AppEvent:
        return AppEvent(
            schema_version=EVENT_SCHEMA_VERSION,
            event_type=EventType.COMPACTION,
            run_id=context.run_id,
            status=status,
            count=count,
            artifact_id=artifact_id,
            digest=digest,
        )


class EventNormalizer:
    """Normalize only public ``updates`` and ``custom`` stream modes."""

    def __init__(
        self,
        *,
        scope_secret: bytes,
        new_id: Callable[[], str],
        sink: object,
    ) -> None:
        self._scope_secret = validate_scope_secret(scope_secret)
        if not callable(new_id):
            raise TypeError("event identifier generator must be callable")
        if not callable(getattr(sink, "emit", None)):
            raise TypeError("event sink must implement emit")
        self._new_id = new_id
        self._sink = sink
        self._last_plan_digest: dict[str, str] = {}
        self._issued_plan_ids: set[str] = set()
        self._lock = threading.Lock()

    def begin_turn(self, context: RuntimeContext) -> None:
        """Reset per-run deduplication so reused public run IDs gain no authority."""

        plan_scope = self._plan_scope(context)
        with self._lock:
            self._last_plan_digest.pop(plan_scope, None)

    def normalize(
        self,
        context: RuntimeContext,
        mode: str,
        payload: object,
    ) -> tuple[AppEvent, ...]:
        if mode == "custom":
            return self._normalize_custom(context, payload)
        if mode == "updates":
            return self._normalize_updates(context, payload)
        return ()

    def terminal(self, context: RuntimeContext, status: EventStatus) -> AppEvent:
        if status not in {
            EventStatus.COMPLETED,
            EventStatus.BLOCKED,
            EventStatus.FAILED,
            EventStatus.CANCELLED,
            EventStatus.BUDGET_EXCEEDED,
        }:
            raise ValueError("terminal event status is invalid")
        event = AppEvent(
            schema_version=EVENT_SCHEMA_VERSION,
            event_type=EventType.TURN,
            run_id=context.run_id,
            status=status,
        )
        try:
            self._emit(context, event)
        finally:
            with self._lock:
                self._last_plan_digest.pop(self._plan_scope(context), None)
        return event

    def _normalize_custom(
        self,
        context: RuntimeContext,
        payload: object,
    ) -> tuple[AppEvent, ...]:
        if (
            not isinstance(payload, AppEvent)
            or payload.run_id != context.run_id
            or payload.event_type not in _CUSTOM_EVENT_TYPES
        ):
            return ()
        self._emit(context, payload)
        return (payload,)

    def _normalize_updates(
        self,
        context: RuntimeContext,
        payload: object,
    ) -> tuple[AppEvent, ...]:
        todos = _extract_todos(payload)
        if todos is None:
            return ()
        canonical = json.dumps(
            todos,
            ensure_ascii=True,
            sort_keys=True,
            separators=(",", ":"),
        )
        digest = derive_opaque_scope(
            self._scope_secret,
            "ops-copilot:plan-snapshot:v1",
            context.identity_id,
            context.thread_id,
            context.run_id,
            canonical,
            prefix="plan",
        ).removeprefix("plan-")
        plan_scope = self._plan_scope(context)
        with self._lock:
            if self._last_plan_digest.get(plan_scope) == digest:
                return ()
            artifact_id = self._new_id()
            event = AppEvent(
                schema_version=EVENT_SCHEMA_VERSION,
                event_type=EventType.PLAN_SNAPSHOT,
                run_id=context.run_id,
                status=EventStatus.COMPLETED,
                count=len(todos),
                artifact_id=artifact_id,
                digest=digest,
            )
            if artifact_id in self._issued_plan_ids or len(self._issued_plan_ids) >= _MAX_PLAN_IDS:
                raise RuntimeError("plan event identifier collision or limit reached")
            self._issued_plan_ids.add(artifact_id)
            self._last_plan_digest[plan_scope] = digest
        self._emit(context, event)
        return (event,)

    def _plan_scope(self, context: RuntimeContext) -> str:
        return derive_opaque_scope(
            self._scope_secret,
            "ops-copilot:plan-run:v1",
            context.identity_id,
            context.thread_id,
            context.run_id,
            prefix="planrun",
        )

    def _emit(self, context: RuntimeContext, event: AppEvent) -> None:
        scoped_emit = getattr(self._sink, "emit_scoped", None)
        if callable(scoped_emit):
            scoped_emit(context, event)
            return
        self._sink.emit(event)


def _extract_todos(payload: object) -> tuple[dict[str, str], ...] | None:
    if not isinstance(payload, Mapping):
        return None
    candidates: list[object] = []
    for update in payload.values():
        if isinstance(update, Mapping) and "todos" in update:
            candidates.append(update["todos"])
    if len(candidates) != 1:
        return None
    raw_todos = candidates[0]
    if (
        not isinstance(raw_todos, Sequence)
        or isinstance(raw_todos, (str, bytes))
        or len(raw_todos) > 64
    ):
        return None
    todos: list[dict[str, str]] = []
    for item in raw_todos:
        if not isinstance(item, Mapping) or set(item) != {"content", "status"}:
            return None
        content = item["content"]
        status = item["status"]
        if (
            not isinstance(content, str)
            or not content.strip()
            or len(content) > 500
            or "\x00" in content
            or not isinstance(status, str)
            or status not in _TODO_STATUSES
        ):
            return None
        todos.append({"content": content, "status": status})
    return tuple(todos)

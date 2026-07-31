"""App-owned custom event emission for tool and middleware boundaries."""

from __future__ import annotations

from collections.abc import Callable

from ops_scaffold.contracts import (
    AppEvent,
    EventStatus,
    Evidence,
    EvidenceRegistry,
    MemoryLevel,
    RuntimeContext,
    SourceResult,
)
from ops_scaffold.events import MetadataEventFactory


class MetadataEmitter:
    """Emit only validated AppEvent objects through LangGraph's custom stream."""

    def __init__(
        self,
        *,
        evidence_registry: EvidenceRegistry,
        writer: Callable[[AppEvent], None] | None = None,
        factory: MetadataEventFactory | None = None,
    ) -> None:
        if not callable(getattr(evidence_registry, "issue", None)):
            raise TypeError("metadata emitter requires an evidence registry")
        if writer is not None and not callable(writer):
            raise TypeError("metadata writer must be callable")
        self._registry = evidence_registry
        self._writer = writer
        self._factory = factory or MetadataEventFactory()

    def source(self, context: RuntimeContext, result: SourceResult) -> Evidence:
        evidence = self._registry.issue(context, result)
        self._emit(self._factory.source(context, result, evidence))
        return evidence

    def memory(
        self,
        context: RuntimeContext,
        *,
        level: MemoryLevel,
        status: EventStatus,
        count: int,
        artifact_id: str | None = None,
    ) -> None:
        self._emit(
            self._factory.memory(
                context,
                level=level,
                status=status,
                count=count,
                artifact_id=artifact_id,
            )
        )

    def compaction(
        self,
        context: RuntimeContext,
        *,
        status: EventStatus,
        count: int,
        artifact_id: str,
        digest: str,
    ) -> None:
        self._emit(
            self._factory.compaction(
                context,
                status=status,
                count=count,
                artifact_id=artifact_id,
                digest=digest,
            )
        )

    def _emit(self, event: AppEvent) -> None:
        writer = self._writer
        if writer is None:
            from langgraph.config import get_stream_writer

            writer = get_stream_writer()
        writer(event)

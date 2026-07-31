"""Explicit process- or test-scoped ownership of all runtime dependencies."""

from __future__ import annotations

import threading
from collections.abc import Callable, Mapping
from pathlib import Path

from ops_scaffold.contracts import RuntimeContext, ServiceBundle, SourceFamily, SourceStatus
from ops_scaffold.events import CollectingEventSink, EventNormalizer
from ops_scaffold.evidence import TurnEvidenceRegistry
from ops_scaffold.procedures import SecureProcedureService
from ops_scaffold.runner import TurnResult
from ops_scaffold.runner import run_turn as _run_turn
from ops_scaffold.scoping import derive_opaque_scope, validate_scope_secret

_MAX_TURN_LOCKS = 10_000


class RuntimeServices:
    """One injected state lifetime shared by CLI, UI, evaluator, and packages."""

    def __init__(
        self,
        *,
        bundle: ServiceBundle,
        scope_secret: bytes,
        event_normalizer: EventNormalizer,
    ) -> None:
        if not isinstance(bundle, ServiceBundle):
            raise TypeError("runtime services require a ServiceBundle")
        self.bundle = bundle
        self._scope_secret = validate_scope_secret(scope_secret)
        self.event_normalizer = event_normalizer
        self._turn_locks: dict[str, threading.RLock] = {}
        self._turn_locks_guard = threading.Lock()

    def checkpoint_key(self, context: RuntimeContext) -> str:
        self._require_context(context)
        return derive_opaque_scope(
            self._scope_secret,
            "ops-copilot:checkpoint:v1",
            context.identity_id,
            context.thread_id,
            prefix="checkpoint",
        )

    def identity_key(self, context: RuntimeContext) -> str:
        self._require_context(context)
        return derive_opaque_scope(
            self._scope_secret,
            "ops-copilot:store-identity:v1",
            context.identity_id,
            prefix="identity",
        )

    def fact_namespace(self, context: RuntimeContext) -> tuple[str, ...]:
        return self.bundle.fact_namespace(context)

    def provenance_namespace(self, context: RuntimeContext) -> tuple[str, ...]:
        return self.bundle.provenance_namespace(context)

    def checkpoint_config(self, context: RuntimeContext) -> dict[str, object]:
        return {
            "configurable": {
                "thread_id": self.checkpoint_key(context),
            }
        }

    def turn_lock(self, context: RuntimeContext) -> threading.RLock:
        checkpoint_key = self.checkpoint_key(context)
        with self._turn_locks_guard:
            lock = self._turn_locks.get(checkpoint_key)
            if lock is not None:
                return lock
            if len(self._turn_locks) >= _MAX_TURN_LOCKS:
                raise RuntimeError("runtime checkpoint lock limit reached")
            lock = threading.RLock()
            self._turn_locks[checkpoint_key] = lock
            return lock

    def run_turn(
        self,
        agent: object,
        context: RuntimeContext,
        user_input: str,
        *,
        update_budget: int = 256,
        deadline_monotonic: float | None = None,
    ) -> TurnResult:
        """Use the sole interface path without constructing shadow state."""

        return _run_turn(
            agent,
            self,
            context,
            user_input,
            update_budget=update_budget,
            deadline_monotonic=deadline_monotonic,
        )

    @staticmethod
    def _require_context(context: RuntimeContext) -> None:
        if not isinstance(context, RuntimeContext):
            raise TypeError("trusted RuntimeContext is required")


def bootstrap_runtime(
    *,
    agent_model: object,
    summarizer_model: object,
    embeddings: object,
    retriever: object,
    source_service: object,
    monitoring_client: object,
    procedure_workspace: Path,
    scope_secret: bytes,
    clock: Callable[[], float],
    new_id: Callable[[], str],
    event_sink: object | None = None,
    store: object | None = None,
    checkpointer: object | None = None,
    procedure_write_hook: object | None = None,
) -> RuntimeServices:
    """Construct one explicit runtime; imports alone never allocate resources."""

    secret = validate_scope_secret(scope_secret)
    if not callable(clock) or not callable(new_id):
        raise TypeError("runtime clock and identifier generator must be callable")

    def identity_namespace(context: RuntimeContext, level: str) -> tuple[str, ...]:
        if not isinstance(context, RuntimeContext):
            raise TypeError("trusted RuntimeContext is required")
        identity = derive_opaque_scope(
            secret,
            f"ops-copilot:store-{level}:v1",
            context.identity_id,
            prefix="identity",
        )
        return ("ops-copilot", level, identity)

    def fact_namespace(context: RuntimeContext) -> tuple[str, ...]:
        return identity_namespace(context, "facts")

    def provenance_namespace(context: RuntimeContext) -> tuple[str, ...]:
        return identity_namespace(context, "provenance")

    dimensions = getattr(embeddings, "dimensions", None)
    if type(dimensions) is not int or not 1 <= dimensions <= 4_096:
        raise ValueError("runtime embeddings must declare bounded dimensions")

    if store is None:
        from langgraph.store.memory import InMemoryStore

        store = InMemoryStore(
            index={
                "dims": dimensions,
                "embed": embeddings,
                "fields": ["text"],
            }
        )
    index_config = getattr(store, "index_config", None)
    if not isinstance(index_config, Mapping):
        raise ValueError("runtime Store must have an explicit semantic index")

    if checkpointer is None:
        from langgraph.checkpoint.memory import InMemorySaver
        from langgraph.checkpoint.serde.jsonplus import JsonPlusSerializer

        checkpointer = InMemorySaver(
            serde=JsonPlusSerializer(
                allowed_msgpack_modules=(SourceFamily, SourceStatus),
            )
        )

    sink = event_sink if event_sink is not None else CollectingEventSink(scope_secret=secret)
    before_replace = procedure_write_hook
    if before_replace is not None and not callable(before_replace):
        raise TypeError("procedure write hook must be callable")
    procedure_service = SecureProcedureService(
        Path(procedure_workspace),
        scope_secret=secret,
        new_id=new_id,
        before_replace=before_replace,
    )
    evidence_registry = TurnEvidenceRegistry(scope_secret=secret, new_id=new_id)
    normalizer = EventNormalizer(
        scope_secret=secret,
        new_id=new_id,
        sink=sink,
    )
    bundle = ServiceBundle(
        agent_model=agent_model,
        summarizer_model=summarizer_model,
        store=store,
        checkpointer=checkpointer,
        retriever=retriever,
        source_service=source_service,
        monitoring_client=monitoring_client,
        procedure_service=procedure_service,
        evidence_registry=evidence_registry,
        event_sink=sink,
        clock=clock,
        new_id=new_id,
        fact_namespace=fact_namespace,
        provenance_namespace=provenance_namespace,
    )
    return RuntimeServices(
        bundle=bundle,
        scope_secret=secret,
        event_normalizer=normalizer,
    )

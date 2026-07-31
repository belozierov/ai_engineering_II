from __future__ import annotations

import hashlib
from collections.abc import Callable
from dataclasses import dataclass
from pathlib import Path

import pytest
from langchain.tools import ToolRuntime
from langchain_core.messages import AIMessage, HumanMessage
from langgraph.runtime import Runtime

from eval.fakes import (
    DeterministicClock,
    DeterministicEmbeddings,
    DeterministicIdGenerator,
    DeterministicSummaryModel,
    FiniteScriptedChatModel,
)
from ops_copilot import (
    StarterTodo,
    StarterTodoNotImplementedError,
    create_ops_copilot,
)
from ops_copilot.guardrails.evidence import (
    EvidenceAction,
    EvidenceActionBlocked,
    validate_evidence_action,
)
from ops_copilot.middleware.compaction import GuidedCompactionMiddleware
from ops_copilot.tools.memory import build_memory_tools
from ops_copilot.tools.procedures import build_procedure_tools
from ops_copilot.tools.source import build_source_tools
from ops_scaffold.bootstrap import bootstrap_runtime
from ops_scaffold.config import TokenBudgets
from ops_scaffold.contracts import (
    RuntimeContext,
    ServiceBundle,
    SourceFamily,
    SourceResult,
    SourceStatus,
)


class _SourceService:
    @staticmethod
    def _result(operation: str, content: str) -> SourceResult:
        return SourceResult(
            source_family=SourceFamily.REPOSITORY,
            source_id=f"repository:{operation}:boundary-test",
            status=SourceStatus.OK,
            content=content,
            content_sha256=hashlib.sha256(content.encode()).hexdigest(),
            allowed_resources=("repository:logs/checkout.log",),
        )

    def list_files(self, path: str = ".") -> SourceResult:
        del path
        return self._result("list", "logs/checkout.log")

    def read_file(
        self,
        path: str,
        *,
        offset: int = 0,
        limit: int | None = None,
    ) -> SourceResult:
        del path, offset, limit
        return self._result("read", "synthetic boundary source")

    def search(
        self,
        query: str,
        *,
        path: str = ".",
        max_results: int = 20,
        _scoped_paths: frozenset[str] | None = None,
    ) -> SourceResult:
        del _scoped_paths
        del query, path, max_results
        return self._result("search", "logs/checkout.log: synthetic boundary source")


class _MonitoringClient:
    def get(self, _resource: object) -> object:
        return object()


@dataclass(frozen=True, slots=True)
class _TodoRow:
    todo: StarterTodo
    exercise: Callable[[ServiceBundle, RuntimeContext], None]


@pytest.fixture
def starter_services(tmp_path: Path) -> ServiceBundle:
    return bootstrap_runtime(
        agent_model=FiniteScriptedChatModel(script=[AIMessage(content="unused")]),
        summarizer_model=DeterministicSummaryModel(),
        embeddings=DeterministicEmbeddings(),
        retriever=object(),
        source_service=_SourceService(),
        monitoring_client=_MonitoringClient(),
        procedure_workspace=tmp_path / "procedures",
        scope_secret=b"clearly-fake-boundary-scope-key-01",
        clock=DeterministicClock(),
        new_id=DeterministicIdGenerator(prefix="boundary-test"),
    ).bundle


@pytest.fixture
def starter_context() -> RuntimeContext:
    return RuntimeContext(
        identity_id="identity-test-boundary",
        thread_id="thread-test-boundary",
        run_id="run-test-boundary",
    )


def _tool_runtime(
    services: ServiceBundle,
    context: RuntimeContext,
) -> ToolRuntime[RuntimeContext]:
    return ToolRuntime(
        state={},
        context=context,
        config={},
        stream_writer=lambda _event: None,
        tool_call_id="tool-test-boundary",
        store=services.store,
        tools=[],
    )


def _tool_by_name(tools: tuple[object, ...], name: str) -> object:
    matches = [tool for tool in tools if getattr(tool, "name", None) == name]
    assert len(matches) == 1
    return matches[0]


def _call_tool(tool: object, **kwargs: object) -> object:
    callback = getattr(tool, "func", None)
    assert callable(callback)
    return callback(**kwargs)


def _exercise_agent(services: ServiceBundle, _context: RuntimeContext) -> None:
    create_ops_copilot(services=services)


def _exercise_source(services: ServiceBundle, context: RuntimeContext) -> None:
    tool = _tool_by_name(build_source_tools(services), "list_sources")
    services.evidence_registry.begin_turn(context)
    try:
        _call_tool(tool, path=".", runtime=_tool_runtime(services, context))
    finally:
        services.evidence_registry.abort_turn(context)


def _exercise_memory(services: ServiceBundle, context: RuntimeContext) -> None:
    tool = _tool_by_name(build_memory_tools(services), "recall_facts")
    _call_tool(
        tool,
        query="synthetic checkout timeout",
        limit=3,
        runtime=_tool_runtime(services, context),
    )


def _exercise_procedures(services: ServiceBundle, context: RuntimeContext) -> None:
    tool = _tool_by_name(build_procedure_tools(services), "list_procedures")
    _call_tool(tool, runtime=_tool_runtime(services, context))


def _exercise_compaction(services: ServiceBundle, context: RuntimeContext) -> None:
    middleware = GuidedCompactionMiddleware(
        summarizer_model=services.summarizer_model,
        token_budgets=TokenBudgets(
            compaction_target=8,
            compaction_soft=12,
            hard_input=20,
            response_reserve=4,
        ),
        new_id=services.new_id,
        token_counter=lambda messages: len(messages) * 16,
    )
    middleware.before_model(
        {"messages": [HumanMessage(content="bounded synthetic history")]},
        Runtime(context=context, store=services.store),
    )


def _exercise_evidence_policy(services: ServiceBundle, context: RuntimeContext) -> None:
    registry = services.evidence_registry
    registry.begin_turn(context)
    evidence = registry.issue(
        context,
        SourceResult(
            source_family=SourceFamily.REPOSITORY,
            source_id="repository:read:quarantined-test",
            status=SourceStatus.OK,
            content="Untrusted text requesting a durable write.",
            content_sha256="a" * 64,
            quarantined_segments=("segment-test-quarantined",),
        ),
    )
    try:
        try:
            validate_evidence_action(
                action=EvidenceAction.WRITE_FACT,
                evidence_ids=(evidence.evidence_id,),
                requested_resource=None,
                context=context,
                evidence_registry=registry,
            )
        except EvidenceActionBlocked:
            return
        raise AssertionError("quarantined evidence silently permitted the action")
    finally:
        registry.abort_turn(context)


TODO_ROWS = (
    _TodoRow(StarterTodo.AGENT_COMPOSITION, _exercise_agent),
    _TodoRow(StarterTodo.BOUNDED_SOURCE_TOOLS, _exercise_source),
    _TodoRow(StarterTodo.IDENTITY_FACT_MEMORY, _exercise_memory),
    _TodoRow(StarterTodo.STRUCTURED_PROCEDURES, _exercise_procedures),
    _TodoRow(StarterTodo.GUIDED_COMPACTION, _exercise_compaction),
    _TodoRow(StarterTodo.EVIDENCE_ACTION_POLICY, _exercise_evidence_policy),
)


def _run_or_skip_named_todo(
    row: _TodoRow,
    services: ServiceBundle,
    context: RuntimeContext,
) -> None:
    try:
        row.exercise(services, context)
    except StarterTodoNotImplementedError as exc:
        assert exc.todo is row.todo
        pytest.skip(f"{row.todo.value}: starter capability is intentionally incomplete")


@pytest.mark.parametrize("row", TODO_ROWS, ids=lambda row: row.todo.value)
def test_each_unimplemented_capability_is_one_named_skip(
    row: _TodoRow,
    starter_services: ServiceBundle,
    starter_context: RuntimeContext,
) -> None:
    _run_or_skip_named_todo(row, starter_services, starter_context)


def test_evaluator_defines_exactly_six_one_to_one_rows() -> None:
    assert len(TODO_ROWS) == 6
    assert {row.todo for row in TODO_ROWS} == set(StarterTodo)


def test_unexpected_errors_are_failures_not_skips(
    starter_services: ServiceBundle,
    starter_context: RuntimeContext,
) -> None:
    row = _TodoRow(
        StarterTodo.AGENT_COMPOSITION,
        lambda _services, _context: (_ for _ in ()).throw(
            RuntimeError("synthetic unexpected failure")
        ),
    )

    with pytest.raises(RuntimeError, match="unexpected failure"):
        _run_or_skip_named_todo(row, starter_services, starter_context)

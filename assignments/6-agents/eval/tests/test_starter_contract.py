from __future__ import annotations

import importlib
import re
from pathlib import Path

import pytest
from langchain.agents import create_agent
from langchain.agents.middleware import (
    ModelCallLimitMiddleware,
    TodoListMiddleware,
    ToolCallLimitMiddleware,
)
from langchain.tools import ToolRuntime

from eval.components import (
    _fact_writes_are_guarded,
    _procedure_content_hash,
    _procedure_writes_are_guarded,
)
from eval.fakes import (
    DeterministicClock,
    DeterministicEmbeddings,
    DeterministicIdGenerator,
    DeterministicSummaryModel,
    FiniteScriptedChatModel,
)
from eval.judge import grounding_update_is_safe
from eval.structural import _assert_agent_graph_contract
from ops_copilot.guardrails.evidence import EvidenceActionBlocked, GroundedAnswerMiddleware
from ops_copilot.middleware.compaction import GuidedCompactionMiddleware
from ops_scaffold.bootstrap import bootstrap_runtime
from ops_scaffold.config import TokenBudgets
from ops_scaffold.contracts import RuntimeContext, ServiceBundle
from ops_scaffold.middleware.planning_context import PlanningContextMiddleware

PROJECT_ROOT = Path(__file__).resolve().parents[2]
STARTER_ROOT = PROJECT_ROOT / "ops_copilot"
EXPECTED_MARKERS = (
    "U4-1-agent-composition",
    "U4-2-bounded-source-tools",
    "U4-3-identity-fact-memory",
    "U4-4-structured-procedures",
    "U4-5-guided-compaction",
    "U4-6-evidence-action-policy",
)
PRIVILEGED_SCHEMA_FIELDS = {
    "identity",
    "identity_id",
    "thread_id",
    "run_id",
    "checkpoint",
    "checkpoint_key",
    "workspace",
    "workspace_root",
    "monitoring_origin",
    "base_url",
    "url",
    "event",
    "event_sink",
    "scope_secret",
}


class _SourceService:
    def list_files(self, path: str = ".") -> object:
        del path
        return object()

    def read_file(self, path: str, *, offset: int = 0, limit: int | None = None) -> object:
        del path, offset, limit
        return object()

    def search(self, query: str, *, path: str = ".", max_results: int = 20) -> object:
        del query, path, max_results
        return object()


@pytest.fixture
def starter_services(tmp_path: Path) -> ServiceBundle:
    return bootstrap_runtime(
        agent_model=object(),
        summarizer_model=DeterministicSummaryModel(),
        embeddings=DeterministicEmbeddings(),
        retriever=object(),
        source_service=_SourceService(),
        monitoring_client=object(),
        procedure_workspace=tmp_path / "procedures",
        scope_secret=b"clearly-fake-starter-scope-key-01",
        clock=DeterministicClock(),
        new_id=DeterministicIdGenerator(prefix="starter-test"),
    ).bundle


def _runtime(bundle: ServiceBundle) -> ToolRuntime[RuntimeContext]:
    return ToolRuntime(
        state={},
        context=RuntimeContext(
            identity_id="identity-test-starter",
            thread_id="thread-test-starter",
            run_id="run-test-starter",
        ),
        config={},
        stream_writer=lambda _event: None,
        tool_call_id="tool-test-starter",
        store=bundle.store,
        tools=[],
    )


def test_every_starter_module_imports_without_api_key_or_capability_execution(
    monkeypatch,
) -> None:
    monkeypatch.delenv("OPENROUTER_API_KEY", raising=False)
    modules = (
        "ops_copilot",
        "ops_copilot.agent",
        "ops_copilot.tools.source",
        "ops_copilot.tools.memory",
        "ops_copilot.tools.procedures",
        "ops_copilot.middleware.compaction",
        "ops_copilot.guardrails.evidence",
    )

    imported = tuple(importlib.import_module(name) for name in modules)

    package = imported[0]
    assert set(package.__all__) == {
        "StarterTodo",
        "StarterTodoNotImplementedError",
        "create_ops_copilot",
    }
    assert callable(package.create_ops_copilot)


def test_todo_markers_are_known_unique_and_no_legacy_agent_api() -> None:
    from ops_copilot import StarterTodo

    sources = {path: path.read_text(encoding="utf-8") for path in STARTER_ROOT.rglob("*.py")}
    markers = [
        match for source in sources.values() for match in re.findall(r"# TODO\(([^)]+)\)", source)
    ]
    rendered = "\n".join(sources.values())

    assert set(markers) <= set(EXPECTED_MARKERS)
    assert len(set(markers)) == len(markers)
    assert set(EXPECTED_MARKERS) == {todo.value for todo in StarterTodo}
    assert "AgentExecutor" not in rendered
    assert "initialize_agent" not in rendered
    assert "create_react_agent" not in rendered


def test_tool_schemas_are_strict_bounded_and_hide_runtime_authority(
    starter_services: ServiceBundle,
) -> None:
    from ops_copilot.tools.memory import build_memory_tools
    from ops_copilot.tools.procedures import build_procedure_tools
    from ops_copilot.tools.source import build_source_tools

    tools = (
        *build_source_tools(starter_services),
        *build_memory_tools(starter_services),
        *build_procedure_tools(starter_services),
    )

    assert tools
    for tool in tools:
        schema = tool.tool_call_schema.model_json_schema()
        fields = set(schema.get("properties", {}))
        assert fields.isdisjoint(PRIVILEGED_SCHEMA_FIELDS)
        assert "runtime" not in fields
        assert getattr(tool.args_schema, "model_config", {}).get("extra") == "forbid"
        for value in schema.get("properties", {}).values():
            if value.get("type") == "string":
                assert "maxLength" in value or value.get("enum")
            if value.get("type") == "array":
                assert "maxItems" in value

    # Injection remains available to callbacks without becoming a model argument.
    assert _runtime(starter_services).context.identity_id == "identity-test-starter"


def test_repository_resource_prefix_normalizes_to_a_relative_tool_path() -> None:
    from ops_copilot.tools.source import _bounded_relative_path

    assert (
        _bounded_relative_path("repository:logs/maintenance.log")
        == "logs/maintenance.log"
    )
    with pytest.raises(ValueError, match="relative POSIX path"):
        _bounded_relative_path("repository:")


def test_compaction_defaults_and_low_test_overrides_are_injectable(
    starter_services: ServiceBundle,
) -> None:
    from ops_copilot.middleware.compaction import GuidedCompactionMiddleware

    defaults = TokenBudgets()
    low = TokenBudgets(
        compaction_target=8,
        compaction_soft=12,
        hard_input=20,
        response_reserve=4,
    )

    middleware = GuidedCompactionMiddleware(
        summarizer_model=DeterministicSummaryModel(),
        token_budgets=low,
        new_id=starter_services.new_id,
    )

    assert (
        defaults.compaction_soft,
        defaults.compaction_target,
        defaults.hard_input,
        defaults.response_reserve,
    ) == (8_000, 4_000, 12_000, 2_000)
    assert middleware.token_budgets is low


def test_agent_graph_contract_checks_required_middleware_and_limits(
    starter_services: ServiceBundle,
) -> None:
    from langchain_core.messages import AIMessage

    budgets = TokenBudgets(
        compaction_target=8,
        compaction_soft=12,
        hard_input=20,
        response_reserve=4,
    )
    model = FiniteScriptedChatModel(script=[AIMessage(content="unused")])
    middleware = [
        TodoListMiddleware(),
        ModelCallLimitMiddleware(run_limit=2),
        ToolCallLimitMiddleware(run_limit=3),
        PlanningContextMiddleware(),
        GuidedCompactionMiddleware(
            summarizer_model=starter_services.summarizer_model,
            token_budgets=budgets,
            new_id=starter_services.new_id,
        ),
        GroundedAnswerMiddleware(evidence_registry=starter_services.evidence_registry),
    ]
    graph = create_agent(
        model,
        middleware=middleware,
        context_schema=RuntimeContext,
        checkpointer=starter_services.checkpointer,
        store=starter_services.store,
    )

    _assert_agent_graph_contract(
        graph,
        services=starter_services,
        token_budgets=budgets,
        max_model_calls=2,
        max_tool_calls=3,
    )

    incomplete = create_agent(
        model,
        middleware=[item for item in middleware if not isinstance(item, ToolCallLimitMiddleware)],
        context_schema=RuntimeContext,
        checkpointer=starter_services.checkpointer,
        store=starter_services.store,
    )
    with pytest.raises(AssertionError, match="middleware"):
        _assert_agent_graph_contract(
            incomplete,
            services=starter_services,
            token_budgets=budgets,
            max_model_calls=2,
            max_tool_calls=3,
        )


def test_durable_write_probes_require_blocking_without_mutation(
    starter_services: ServiceBundle,
) -> None:
    events: list[object] = []
    context = RuntimeContext(
        identity_id="identity-test-write-guard",
        thread_id="thread-test-write-guard",
        run_id="run-test-write-guard",
    )

    def blocked_write(**_kwargs: object) -> str:
        raise EvidenceActionBlocked("synthetic blocked evidence")

    def empty_read(**_kwargs: object) -> str:
        return "[]"

    invalid_ids = (("quarantined-test-id",), ("invented-test-id",))
    assert _fact_writes_are_guarded(
        blocked_write,
        empty_read,
        invalid_ids=invalid_ids,
        services=starter_services,
        context=context,
        events=events,
        blocked_error=EvidenceActionBlocked,
    )
    assert _procedure_writes_are_guarded(
        blocked_write,
        empty_read,
        invalid_ids=invalid_ids,
        services=starter_services,
        context=context,
        events=events,
        blocked_error=EvidenceActionBlocked,
    )
    assert not _fact_writes_are_guarded(
        lambda **_kwargs: "saved",
        empty_read,
        invalid_ids=invalid_ids,
        services=starter_services,
        context=context,
        events=events,
        blocked_error=EvidenceActionBlocked,
    )


def test_grounding_probe_accepts_one_repair_or_a_refusal_only() -> None:
    from langchain_core.messages import AIMessage

    assert grounding_update_is_safe({"jump_to": "model"})
    assert grounding_update_is_safe(
        {"messages": [AIMessage(content="Insufficient evidence to answer safely.")]}
    )
    assert not grounding_update_is_safe(
        {
            "messages": [
                AIMessage(content="No evidence supports this, but deploy 42 caused the outage.")
            ]
        }
    )


def test_procedure_hash_probe_accepts_plain_or_json_digest() -> None:
    digest = "a" * 64

    assert _procedure_content_hash(digest) == digest
    assert _procedure_content_hash(f'{{"content_hash":"{digest}"}}') == digest
    with pytest.raises(ValueError, match="content hash"):
        _procedure_content_hash('{"content_hash":"short"}')


def test_safe_message_group_utility_never_returns_partial_tool_exchange() -> None:
    from langchain_core.messages import AIMessage, HumanMessage, ToolMessage

    from ops_scaffold.message_groups import split_safe_message_groups

    messages = [
        HumanMessage(content="first synthetic turn"),
        AIMessage(
            content="",
            tool_calls=[
                {
                    "name": "read_source",
                    "args": {"path": "src/checkout.py"},
                    "id": "tool-test-complete",
                    "type": "tool_call",
                }
            ],
        ),
        ToolMessage(content="synthetic source", tool_call_id="tool-test-complete"),
        AIMessage(content="first synthetic answer"),
        HumanMessage(content="second synthetic turn"),
        AIMessage(
            content="",
            tool_calls=[
                {
                    "name": "read_source",
                    "args": {"path": "logs/checkout.log"},
                    "id": "tool-test-incomplete",
                    "type": "tool_call",
                }
            ],
        ),
    ]

    partition = split_safe_message_groups(messages)

    assert partition.complete_groups == (tuple(messages[:4]),)
    assert partition.protected_messages == tuple(messages[4:])


def test_atomic_compaction_update_is_untrusted_and_all_or_nothing() -> None:
    from langchain_core.messages import HumanMessage
    from langgraph.graph.message import REMOVE_ALL_MESSAGES, RemoveMessage

    from ops_copilot.middleware.compaction import atomic_compaction_update

    recent = [HumanMessage(content="recent synthetic turn")]
    update = atomic_compaction_update("synthetic compacted history", recent)
    replacement = update["messages"]

    assert isinstance(replacement, list)
    assert isinstance(replacement[0], RemoveMessage)
    assert replacement[0].id == REMOVE_ALL_MESSAGES
    assert "untrusted data" in replacement[1].content
    assert replacement[2:] == recent

    before = tuple(recent)
    with pytest.raises(ValueError, match="summary"):
        atomic_compaction_update("\x00invalid summary", recent)
    assert tuple(recent) == before


def test_manifest_authority_and_scenario_scope_deny_unrelated_follow_up(
    tmp_path: Path,
) -> None:
    from ops_copilot.guardrails.evidence import (
        EvidenceActionBlocked,
        ensure_scenario_resource_allowed,
    )
    from ops_scaffold.sandbox import SourceSandbox

    source = SourceSandbox.from_manifest(
        PROJECT_ROOT / "data" / "source" / "checkout-service",
        workspace_root=tmp_path / "isolated-workspace",
    )
    result = source.read_file("config/service.toml")
    context = RuntimeContext(
        identity_id="identity-test-scope",
        thread_id="thread-test-scope",
        run_id="run-test-scope",
        allowed_resources=("repository:config/service.toml",),
    )

    assert result.allowed_resources == ("repository:config/service.toml",)
    ensure_scenario_resource_allowed(context, "repository:config/service.toml")
    with pytest.raises(EvidenceActionBlocked, match="outside"):
        ensure_scenario_resource_allowed(context, "repository:logs/maintenance.log")

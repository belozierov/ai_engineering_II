"""Strict package selection and six executable student-boundary checks."""

from __future__ import annotations

import builtins
import hashlib
import importlib
import json
from collections.abc import Callable, Mapping
from contextlib import contextmanager
from dataclasses import dataclass

from langchain.agents.middleware import ModelCallLimitMiddleware, ToolCallLimitMiddleware
from langchain.tools import ToolRuntime
from langchain_core.messages import AIMessage, HumanMessage
from langgraph.runtime import Runtime

from eval.fakes import DeterministicSummaryModel, FiniteScriptedChatModel
from eval.judge import grounding_update_is_safe, is_grounded_refusal
from eval.report import Capability, CheckResult
from eval.scenarios import runtime_fixture
from ops_scaffold.application import extract_final_answer
from ops_scaffold.config import (
    ALLOWED_PACKAGES,
    ConfigurationError,
    TokenBudgets,
    select_package,
)
from ops_scaffold.contracts import (
    AppEvent,
    EventType,
    RuntimeContext,
    ServiceBundle,
    SourceFamily,
    SourceResult,
    SourceStatus,
)
from ops_scaffold.student_todos import StarterTodo, StarterTodoNotImplementedError
from ops_scaffold.tools.monitoring import MonitoringResource

_EXPECTED_TOOLS = frozenset(
    {
        "write_todos",
        "list_sources",
        "read_source",
        "search_sources",
        "get_monitoring",
        "search_runbooks",
        "save_fact",
        "recall_facts",
        "list_procedures",
        "read_procedure",
        "write_procedure",
    }
)


class PackageSelectionError(ValueError):
    """OPS_PKG is not an available course evaluator target."""


@dataclass(frozen=True, slots=True)
class _TodoExercise:
    todo: StarterTodo
    run: Callable[[str, ServiceBundle, RuntimeContext], None]
    capabilities: tuple[Capability, ...]


def resolve_package_name(environ: Mapping[str, str] | None = None) -> str:
    try:
        return select_package(environ)
    except ConfigurationError:
        raise PackageSelectionError("OPS_PKG must select an available course package") from None


def evaluate_package_selection(
    environ: Mapping[str, str] | None = None,
) -> tuple[str | None, list[CheckResult]]:
    try:
        package_name = resolve_package_name(environ)
    except PackageSelectionError:
        return (
            None,
            [
                CheckResult.fail(
                    "structural.package-selector",
                    "OPS_PKG must select an available course package",
                )
            ],
        )
    return (
        package_name,
        [
            CheckResult.pass_(
                "structural.package-selector",
                "OPS_PKG resolved through the strict package allowlist",
            )
        ],
    )


def run_structural_checks(package_name: str) -> list[CheckResult]:
    if package_name not in ALLOWED_PACKAGES:
        return [
            CheckResult.fail(
                "structural.package-contract",
                "selected package is unsupported",
            )
        ]
    try:
        with _student_import_boundary(package_name):
            package = importlib.import_module(package_name)
        factory = getattr(package, "create_ops_copilot", None)
        if not callable(factory):
            return [
                CheckResult.fail(
                    "structural.package-contract",
                    "selected package does not export the required factory",
                )
            ]
        model = FiniteScriptedChatModel(
            script=[
                AIMessage(content="Synthetic unsupported conclusion."),
                AIMessage(content="I cannot answer: insufficient current-run evidence."),
            ]
        )
        with runtime_fixture(model=model, id_prefix="structural") as fixture:
            context = RuntimeContext(
                identity_id="identity-eval-structural",
                thread_id="thread-eval-structural",
                run_id="run-eval-structural",
                allowed_resources=(
                    "repository:config/service.toml",
                    "repository:logs/checkout.log",
                    "monitoring:dead_end",
                    "runbook:rb-checkout-5xx",
                ),
            )
            rows = [
                CheckResult.pass_(
                    "structural.package-contract",
                    "factory imported without provider credentials or runtime side effects",
                )
            ]
            for exercise in _TODO_EXERCISES:
                rows.append(
                    _run_todo_exercise(
                        package_name,
                        exercise,
                        fixture.services.bundle,
                        context,
                    )
                )
            return rows
    except Exception:
        return [
            CheckResult.fail(
                "structural.package-contract",
                "no-key package contract could not be evaluated",
            )
        ]


def _run_todo_exercise(
    package_name: str,
    exercise: _TodoExercise,
    services: ServiceBundle,
    context: RuntimeContext,
) -> CheckResult:
    name = f"todo.{exercise.todo.value}"
    try:
        with _student_import_boundary(package_name):
            exercise.run(package_name, services, context)
    except StarterTodoNotImplementedError as exc:
        if exc.todo is exercise.todo:
            return CheckResult.skip(
                name,
                "student TODO is intentionally not implemented",
                todo_id=exercise.todo.value,
                capabilities=exercise.capabilities,
            )
        return CheckResult.fail(
            name,
            "capability raised a different student TODO marker",
            capabilities=exercise.capabilities,
        )
    except Exception:
        return CheckResult.fail(
            name,
            "capability raised an unexpected bounded evaluation failure",
            capabilities=exercise.capabilities,
        )
    return CheckResult.pass_(
        name,
        "student boundary executed without provider credentials",
    )


def _exercise_agent(
    package_name: str,
    services: ServiceBundle,
    context: RuntimeContext,
) -> None:
    package = _safe_import(package_name)
    token_budgets = TokenBudgets(
        compaction_target=8,
        compaction_soft=12,
        hard_input=40,
        response_reserve=4,
    )
    graph = package.create_ops_copilot(
        services=services,
        token_budgets=token_budgets,
        max_model_calls=2,
        max_tool_calls=3,
    )
    if not callable(getattr(graph, "invoke", None)) or not callable(getattr(graph, "stream", None)):
        raise AssertionError("agent public runtime methods are absent")
    _assert_agent_graph_contract(
        graph,
        services=services,
        token_budgets=token_budgets,
        max_model_calls=2,
        max_tool_calls=3,
    )
    services.evidence_registry.begin_turn(context)
    try:
        result = graph.invoke(
            {"messages": [{"role": "user", "content": "Unsupported synthetic request."}]},
            {"configurable": {"thread_id": "checkpoint-eval-structural"}},
            context=context,
        )
    finally:
        services.evidence_registry.abort_turn(context)
    answer = extract_final_answer(result.get("messages")) if isinstance(result, Mapping) else ""
    if not is_grounded_refusal(answer):
        raise AssertionError("agent graph did not apply the grounded-answer middleware")
    bound = getattr(services.agent_model, "bound_tool_names", frozenset())
    if not _EXPECTED_TOOLS <= bound:
        raise AssertionError("agent did not bind the required public capabilities")
    capture = getattr(services.agent_model, "capture", None)
    captured = (
        capture.as_public_data()
        if callable(getattr(capture, "as_public_data", None))
        else []
    )
    serialized = json.dumps(captured, ensure_ascii=True, sort_keys=True)
    if not all(
        marker in serialized
        for marker in (
            "Plan before acting",
            "untrusted data",
            "repository:logs/checkout.log",
        )
    ):
        raise AssertionError("agent policy or planning context was not observed")


def _assert_agent_graph_contract(
    graph: object,
    *,
    services: ServiceBundle,
    token_budgets: TokenBudgets,
    max_model_calls: int,
    max_tool_calls: int,
) -> None:
    get_graph = getattr(graph, "get_graph", None)
    if not callable(get_graph):
        raise AssertionError("agent runtime does not expose its compiled graph")
    view = get_graph()
    nodes = getattr(view, "nodes", {})
    required_nodes = {
        "TodoListMiddleware.after_model",
        "ModelCallLimitMiddleware.before_model",
        "ModelCallLimitMiddleware.after_model",
        "ToolCallLimitMiddleware.after_model",
        "GuidedCompactionMiddleware.before_model",
        "GroundedAnswerMiddleware.after_model",
    }
    if not isinstance(nodes, Mapping) or not required_nodes <= set(nodes):
        raise AssertionError("agent graph is missing required middleware")

    model_limit = _middleware_owner(nodes["ModelCallLimitMiddleware.before_model"])
    tool_limit = _middleware_owner(nodes["ToolCallLimitMiddleware.after_model"])
    compaction = _middleware_owner(nodes["GuidedCompactionMiddleware.before_model"])
    if (
        not isinstance(model_limit, ModelCallLimitMiddleware)
        or model_limit.run_limit != max_model_calls
        or not isinstance(tool_limit, ToolCallLimitMiddleware)
        or tool_limit.run_limit != max_tool_calls
    ):
        raise AssertionError("agent graph call limits do not match the factory contract")
    if (
        getattr(compaction, "token_budgets", None) is not token_budgets
        or getattr(compaction, "summarizer_model", None) is not services.summarizer_model
    ):
        raise AssertionError("agent graph did not inject the compaction dependencies")

    edges = {
        (getattr(edge, "source", None), getattr(edge, "target", None))
        for edge in getattr(view, "edges", ())
    }
    required_edges = {
        ("__start__", "ModelCallLimitMiddleware.before_model"),
        ("ModelCallLimitMiddleware.before_model", "GuidedCompactionMiddleware.before_model"),
        ("GuidedCompactionMiddleware.before_model", "model"),
        ("model", "GroundedAnswerMiddleware.after_model"),
        ("GroundedAnswerMiddleware.after_model", "ToolCallLimitMiddleware.after_model"),
        ("ToolCallLimitMiddleware.after_model", "ModelCallLimitMiddleware.after_model"),
        ("ModelCallLimitMiddleware.after_model", "TodoListMiddleware.after_model"),
    }
    if not required_edges <= edges:
        raise AssertionError("agent graph middleware order does not match the contract")
    if (
        getattr(graph, "store", None) is not services.store
        or getattr(graph, "checkpointer", None) is not services.checkpointer
        or getattr(graph, "context_schema", None) is not RuntimeContext
    ):
        raise AssertionError("agent graph did not inject runtime state dependencies")


def _middleware_owner(node: object) -> object:
    data = getattr(node, "data", None)
    callback = getattr(data, "func", None)
    owner = getattr(callback, "__self__", None)
    if owner is None:
        raise AssertionError("agent graph middleware node is not inspectable")
    return owner


def _exercise_source(
    package_name: str,
    services: ServiceBundle,
    context: RuntimeContext,
) -> None:
    module = _safe_import(f"{package_name}.tools.source")
    tools = module.build_source_tools(services)
    events: list[object] = []
    runtime = _tool_runtime(services, context, events)
    services.evidence_registry.begin_turn(context)
    try:
        listed = _tool(tools, "list_sources").func(
            path=".",
            runtime=runtime,
        )
        searched = _tool(tools, "search_sources").func(
            query="timeout",
            path=".",
            max_results=5,
            runtime=runtime,
        )
        monitoring = services.monitoring_client.get(MonitoringResource.DEAD_END)
        monitoring_evidence = services.evidence_registry.issue(context, monitoring)
        authorization_content = "Synthetic authorization for config/service.toml."
        config_authorization = services.evidence_registry.issue(
            context,
            SourceResult(
                source_family=SourceFamily.RUNBOOK,
                source_id="runbook:structural-config-authorization",
                status=SourceStatus.OK,
                content=authorization_content,
                content_sha256=hashlib.sha256(authorization_content.encode()).hexdigest(),
                allowed_resources=("repository:config/service.toml",),
            ),
        )
        config_read = _tool(tools, "read_source").func(
            path="config/service.toml",
            evidence_ids=(config_authorization.evidence_id,),
            offset=0,
            limit=64,
            runtime=runtime,
        )
        log_read = _tool(tools, "read_source").func(
            path="logs/checkout.log",
            evidence_ids=(monitoring_evidence.evidence_id,),
            offset=10,
            limit=64,
            runtime=runtime,
        )
        evidence = tuple(services.evidence_registry.snapshot(context))
    finally:
        services.evidence_registry.abort_turn(context)
    if (
        not all(
            isinstance(result, tuple)
            and len(result) == 2
            and getattr(result[1], "status", None) is SourceStatus.OK
            for result in (listed, searched, config_read, log_read)
        )
        or sum(
            item.provenance.source_family.value == SourceFamily.REPOSITORY.value
            for item in evidence
        )
        != 4
        or len(events) != 4
        or not all(
            isinstance(event, AppEvent) and event.event_type is EventType.SOURCE
            for event in events
        )
    ):
        raise AssertionError("repository list/read/search evidence and events were not observed")
    expected_config = services.source_service.read_file(
        "config/service.toml",
        offset=0,
        limit=64,
    )
    expected_log = services.source_service.read_file(
        "logs/checkout.log",
        offset=10,
        limit=64,
    )
    if config_read[1] != expected_config or log_read[1] != expected_log:
        raise AssertionError("repository reads did not honor path offset and limit")


def _exercise_memory(
    package_name: str,
    services: ServiceBundle,
    context: RuntimeContext,
) -> None:
    module = _safe_import(f"{package_name}.tools.memory")
    response = _tool(module.build_memory_tools(services), "recall_facts").func(
        query="synthetic checkout timeout",
        limit=3,
        runtime=_tool_runtime(services, context, []),
    )
    if not isinstance(response, str):
        raise AssertionError("fact recall contract returned an invalid value")


def _exercise_procedure(
    package_name: str,
    services: ServiceBundle,
    context: RuntimeContext,
) -> None:
    module = _safe_import(f"{package_name}.tools.procedures")
    response = _tool(
        module.build_procedure_tools(services),
        "list_procedures",
    ).func(runtime=_tool_runtime(services, context, []))
    if not isinstance(response, str):
        raise AssertionError("procedure inventory contract returned an invalid value")


def _exercise_compaction(
    package_name: str,
    services: ServiceBundle,
    context: RuntimeContext,
) -> None:
    module = _safe_import(f"{package_name}.middleware.compaction")
    budgets_type = TokenBudgets
    if package_name == "reference_solution":
        budgets_type = importlib.import_module("ops_scaffold.config").TokenBudgets
    middleware = module.GuidedCompactionMiddleware(
        summarizer_model=DeterministicSummaryModel(
            "Preserved synthetic early needle deploy-synthetic-042."
        ),
        token_budgets=budgets_type(
            compaction_target=8,
            compaction_soft=12,
            hard_input=40,
            response_reserve=4,
        ),
        new_id=services.new_id,
        token_counter=lambda messages: len(messages) * 4,
    )
    update = middleware.before_model(
        {
            "messages": [
                HumanMessage(content="early synthetic needle deploy-synthetic-042"),
                AIMessage(content="early synthetic response"),
                HumanMessage(content="recent synthetic question"),
                AIMessage(content="recent synthetic response"),
            ]
        },
        Runtime(context=context, store=services.store),
    )
    if not isinstance(update, dict) or middleware.compaction_count != 1:
        raise AssertionError("guided compaction was not observed")


def _exercise_evidence_policy(
    package_name: str,
    services: ServiceBundle,
    context: RuntimeContext,
) -> None:
    module = _safe_import(f"{package_name}.guardrails.evidence")
    source = services.source_service.read_file("logs/maintenance.log")
    if source.status.value != SourceStatus.OK.value or not source.quarantined_segments:
        raise AssertionError("quarantined source fixture is unavailable")
    services.evidence_registry.begin_turn(context)
    try:
        quarantined = services.evidence_registry.issue(context, source)
        repository = services.evidence_registry.issue(
            context,
            services.source_service.read_file("logs/checkout.log"),
        )
        blocked = False
        try:
            module.validate_evidence_action(
                action=module.EvidenceAction.WRITE_FACT,
                evidence_ids=(quarantined.evidence_id,),
                requested_resource=None,
                context=context,
                evidence_registry=services.evidence_registry,
            )
        except module.EvidenceActionBlocked:
            blocked = True
        if not blocked:
            raise AssertionError("quarantined evidence authorized a durable action")

        answer = f"Synthetic supported claim [evidence:{repository.evidence_id}]."
        validated = module.validate_final_answer(
            answer,
            context=context,
            evidence_registry=services.evidence_registry,
        )
        if len(validated) != 1:
            raise AssertionError("current-run final-answer evidence was not validated")

        middleware = module.GroundedAnswerMiddleware(
            evidence_registry=services.evidence_registry,
        )
        refusal = middleware.after_model(
            {"messages": [AIMessage(content="Unsupported synthetic claim.")]},
            Runtime(context=context, store=services.store),
        )
        if not grounding_update_is_safe(refusal):
            raise AssertionError("unsupported final answer did not produce a safe refusal")
    finally:
        services.evidence_registry.abort_turn(context)


def _safe_import(name: str) -> object:
    package_name = name.partition(".")[0]
    if package_name not in ALLOWED_PACKAGES:
        raise PackageSelectionError("selected package is unsupported")
    return importlib.import_module(name)


@contextmanager
def _student_import_boundary(package_name: str) -> object:
    """Fail closed if the starter delegates any capability to the oracle package."""

    if package_name != "ops_copilot":
        yield
        return
    original_import = builtins.__import__

    def guarded_import(
        name: str,
        globals: Mapping[str, object] | None = None,
        locals: Mapping[str, object] | None = None,
        fromlist: tuple[str, ...] = (),
        level: int = 0,
    ) -> object:
        if name == "reference_solution" or name.startswith("reference_solution."):
            raise ImportError("student package may not import the reference solution")
        return original_import(name, globals, locals, fromlist, level)

    builtins.__import__ = guarded_import
    try:
        yield
    finally:
        builtins.__import__ = original_import


def _tool_runtime(
    services: ServiceBundle,
    context: RuntimeContext,
    events: list[object],
) -> ToolRuntime[RuntimeContext]:
    return ToolRuntime(
        state={},
        context=context,
        config={},
        stream_writer=events.append,
        tool_call_id="tool-eval-structural",
        store=services.store,
        tools=[],
    )


def _tool(tools: tuple[object, ...], name: str) -> object:
    matches = [tool for tool in tools if getattr(tool, "name", None) == name]
    if len(matches) != 1:
        raise AssertionError("required public tool is absent or duplicated")
    return matches[0]


_TODO_EXERCISES = (
    _TodoExercise(
        StarterTodo.AGENT_COMPOSITION,
        _exercise_agent,
        (
            Capability.PLANNING,
            Capability.MONITORING,
            Capability.RUNBOOK,
            Capability.REPLANNING,
            Capability.TWO_FAMILY_GROUNDING,
        ),
    ),
    _TodoExercise(
        StarterTodo.BOUNDED_SOURCE_TOOLS,
        _exercise_source,
        (
            Capability.REPOSITORY,
            Capability.EVIDENCE_ISSUANCE_CITATION_REFUSAL,
        ),
    ),
    _TodoExercise(
        StarterTodo.IDENTITY_FACT_MEMORY,
        _exercise_memory,
        (
            Capability.CROSS_THREAD_FACT_RECALL,
            Capability.IDENTITY_ISOLATION_EVENT_SAFETY,
        ),
    ),
    _TodoExercise(
        StarterTodo.STRUCTURED_PROCEDURES,
        _exercise_procedure,
        (
            Capability.PROCEDURE_RECALL,
            Capability.IDENTITY_ISOLATION_EVENT_SAFETY,
        ),
    ),
    _TodoExercise(
        StarterTodo.GUIDED_COMPACTION,
        _exercise_compaction,
        (Capability.COMPACTION_NEEDLE,),
    ),
    _TodoExercise(
        StarterTodo.EVIDENCE_ACTION_POLICY,
        _exercise_evidence_policy,
        (
            Capability.INJECTION_BLOCKING,
            Capability.EVIDENCE_ISSUANCE_CITATION_REFUSAL,
        ),
    ),
)

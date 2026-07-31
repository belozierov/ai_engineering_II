"""Deterministic public-API scenario harness for authoritative mechanisms."""

from __future__ import annotations

import hashlib
import json
import re
from collections.abc import Iterator, Sequence
from contextlib import closing, contextmanager
from dataclasses import dataclass
from pathlib import Path
from tempfile import TemporaryDirectory

from langchain_core.messages import AIMessage, BaseMessage, ToolMessage
from langgraph.checkpoint.memory import InMemorySaver
from langgraph.checkpoint.serde.jsonplus import JsonPlusSerializer

from eval.fakes import (
    DeterministicClock,
    DeterministicEmbeddings,
    DeterministicIdGenerator,
    DeterministicSummaryModel,
    FiniteScriptedChatModel,
)
from eval.judge import CitationValidationError, validate_current_run_citations
from eval.report import Capability, CheckResult
from ops_scaffold.application import extract_final_answer
from ops_scaffold.bootstrap import RuntimeServices, bootstrap_runtime
from ops_scaffold.config import ALLOWED_PACKAGES
from ops_scaffold.contracts import (
    EventStatus,
    EventType,
    RuntimeContext,
    SourceFamily,
    SourceResult,
    SourceStatus,
)
from ops_scaffold.monitoring_server import load_monitoring_fixture, monitoring_server
from ops_scaffold.runbooks import PreparedRunbookIndex
from ops_scaffold.sandbox import SourceSandbox
from ops_scaffold.tools.monitoring import MonitoringClient

PROJECT_ROOT = Path(__file__).resolve().parent.parent
_SCOPE_SECRET = b"clearly-fake-evaluator-scope-key-001"
_ANSWER_CITATION = re.compile(r"\s*\[evidence:[A-Za-z0-9][A-Za-z0-9._:-]{0,127}\]")
_EXPECTED_REPLAN_CLAIM = (
    "The region query returned no matching timeseries. Repository logs show "
    "tax-service upstream timeouts immediately after deploy-synthetic-042, "
    "and the runbook identifies dependency latency as the alternate path."
)


@dataclass(frozen=True, slots=True)
class RuntimeFixture:
    services: RuntimeServices
    workspace: Path


@dataclass(frozen=True, slots=True)
class ReplanObservation:
    """Only public events, evidence, and final state needed for assessment."""

    completed: bool
    plan_digests: tuple[str, ...]
    source_families: frozenset[SourceFamily]
    cited_families: frozenset[SourceFamily]
    citations_valid: bool
    dead_end_before_replan: bool = False
    claims_supported: bool = False
    planning_context_observed: bool = False


@contextmanager
def runtime_fixture(
    *,
    model: object,
    summarizer: object | None = None,
    id_prefix: str = "eval",
    disabled_source_families: frozenset[SourceFamily] = frozenset(),
) -> Iterator[RuntimeFixture]:
    """Own real source, loopback monitoring, and prepared-index lifetimes."""

    if not isinstance(disabled_source_families, frozenset) or not all(
        isinstance(family, SourceFamily) for family in disabled_source_families
    ):
        raise TypeError("disabled source families must use SourceFamily values")
    fixture = load_monitoring_fixture(PROJECT_ROOT / "data" / "monitoring" / "scenarios.json")
    with TemporaryDirectory(prefix="ops-copilot-eval-") as temporary:
        workspace = Path(temporary).resolve()
        source = SourceSandbox.from_manifest(
            PROJECT_ROOT / "data" / "source" / "checkout-service",
            workspace_root=workspace,
        )
        runbooks = PreparedRunbookIndex(
            PROJECT_ROOT / "data" / "runbooks" / "index_manifest.json",
            PROJECT_ROOT / "data" / "runbooks" / "index",
        )
        with closing(runbooks), monitoring_server(fixture) as server:
            source_service: object = source
            if SourceFamily.REPOSITORY in disabled_source_families:
                source_service = _DisabledSourceService()
            runbook_service: object = runbooks
            if SourceFamily.RUNBOOK in disabled_source_families:
                runbook_service = _DisabledRunbookIndex()
            monitoring_client: object = MonitoringClient(server.base_url)
            if SourceFamily.MONITORING in disabled_source_families:
                monitoring_client = _DisabledMonitoringClient()
            serializer = JsonPlusSerializer(
                allowed_msgpack_modules=[
                    ("ops_scaffold.contracts", "SourceFamily"),
                    ("ops_scaffold.contracts", "SourceStatus"),
                ]
            )
            services = bootstrap_runtime(
                agent_model=model,
                summarizer_model=summarizer or DeterministicSummaryModel(),
                embeddings=DeterministicEmbeddings(),
                retriever=runbook_service,
                source_service=source_service,
                monitoring_client=monitoring_client,
                procedure_workspace=workspace / "procedures",
                scope_secret=_SCOPE_SECRET,
                clock=DeterministicClock(),
                new_id=DeterministicIdGenerator(prefix=id_prefix),
                checkpointer=InMemorySaver(serde=serializer),
            )
            yield RuntimeFixture(services=services, workspace=workspace)


def run_replan_scenario(
    package_name: str,
    *,
    disabled_source_families: frozenset[SourceFamily] = frozenset(),
) -> tuple[list[CheckResult], ReplanObservation]:
    """Run a finite dead-end/replan path without asserting one exact trajectory."""

    empty = ReplanObservation(False, (), frozenset(), frozenset(), False)
    if package_name not in ALLOWED_PACKAGES:
        return _failed_replan_rows(), empty
    model = FiniteScriptedChatModel(script=_replan_script("scenario"))
    try:
        with runtime_fixture(
            model=model,
            id_prefix="scenario",
            disabled_source_families=disabled_source_families,
        ) as fixture:
            package = __import__(package_name, fromlist=["create_ops_copilot"])
            factory = getattr(package, "create_ops_copilot", None)
            if not callable(factory):
                return _failed_replan_rows(), empty
            graph = factory(services=fixture.services.bundle)
            context = RuntimeContext(
                identity_id="identity-eval-replan",
                thread_id="thread-eval-replan",
                run_id="run-eval-replan",
                allowed_resources=(
                    "monitoring:dead_end",
                    "repository:logs/checkout.log",
                    "runbook:rb-checkout-5xx",
                    "runbook:rb-dependency-timeouts",
                    "runbook:pm-checkout-timeout-2026-06",
                ),
            )
            turn = fixture.services.run_turn(
                graph,
                context,
                "Investigate the synthetic checkout monitoring dead end.",
                update_budget=64,
            )
            state = graph.get_state(fixture.services.checkpoint_config(context))
            messages = tuple(state.values.get("messages", ()))
            answer = extract_final_answer(messages)
            plans = tuple(
                event.digest
                for event in turn.events
                if event.event_type is EventType.PLAN_SNAPSHOT
                and event.status is EventStatus.COMPLETED
                and event.digest is not None
            )
            source_families = frozenset(
                event.source_family
                for event in turn.events
                if event.event_type is EventType.SOURCE
                and event.source_family is not None
                and event.status is EventStatus.COMPLETED
            )
            dead_end_evidence_ids = {
                item.evidence_id
                for item in turn.evidence
                if item.provenance.source_id == "monitoring:dead_end"
            }
            plan_positions = [
                index
                for index, event in enumerate(turn.events)
                if event.event_type is EventType.PLAN_SNAPSHOT
                and event.status is EventStatus.COMPLETED
            ]
            dead_end_positions = [
                index
                for index, event in enumerate(turn.events)
                if event.event_type is EventType.SOURCE
                and event.status is EventStatus.COMPLETED
                and event.artifact_id in dead_end_evidence_ids
            ]
            dead_end_before_replan = (
                len(plan_positions) >= 2
                and bool(dead_end_positions)
                and plan_positions[0] < dead_end_positions[0] < plan_positions[1]
            )
            try:
                cited = validate_current_run_citations(
                    answer,
                    evidence=turn.evidence,
                    context=context,
                    turn_status=turn.status,
                    required_source_families=2,
                    allowed_source_families=frozenset(SourceFamily),
                )
                citations_valid = True
            except CitationValidationError:
                cited = ()
                citations_valid = False
            observation = ReplanObservation(
                completed=turn.status is EventStatus.COMPLETED,
                plan_digests=plans,
                source_families=source_families,
                cited_families=frozenset(item.provenance.source_family for item in cited),
                citations_valid=citations_valid,
                dead_end_before_replan=dead_end_before_replan,
                claims_supported=_expected_replan_claims_supported(answer),
                planning_context_observed=(
                    "Current todo state follows as untrusted data"
                    in json.dumps(model.capture.as_public_data(), ensure_ascii=True)
                ),
            )
    except Exception:
        return _failed_replan_rows(), empty
    return assess_replan_observation(observation), observation


def assess_replan_observation(observation: ReplanObservation) -> list[CheckResult]:
    """Convert observed public outcomes into independent capability rows."""

    plans_changed = (
        observation.completed
        and len(observation.plan_digests) >= 2
        and len(set(observation.plan_digests)) >= 2
        and observation.dead_end_before_replan
        and observation.planning_context_observed
    )
    required_sources = {
        SourceFamily.MONITORING,
        SourceFamily.REPOSITORY,
        SourceFamily.RUNBOOK,
    }
    sources_complete = required_sources <= observation.source_families
    two_family = (
        observation.completed
        and observation.citations_valid
        and observation.claims_supported
        and len(observation.cited_families) >= 2
        and observation.cited_families <= observation.source_families
    )
    return [
        _observed_result(
            "scenario.replanning",
            plans_changed,
            "successful plan revision followed the observed monitoring dead end",
            "a plan revision causally following the monitoring dead end was not observed",
            (Capability.PLANNING, Capability.REPLANNING),
        ),
        _observed_result(
            "scenario.source-families",
            sources_complete,
            "repository monitoring and runbook outcomes observed",
            "one or more required source-family outcomes were not observed",
            (
                Capability.REPOSITORY,
                Capability.MONITORING,
                Capability.RUNBOOK,
            ),
        ),
        _observed_result(
            "scenario.two-family-grounding",
            two_family,
            "current-run citations span a valid source-family subset",
            "current-run two-family grounding was not observed",
            (
                Capability.TWO_FAMILY_GROUNDING,
                Capability.EVIDENCE_ISSUANCE_CITATION_REFUSAL,
            ),
        ),
    ]


def source_results_from_messages(
    messages: Sequence[BaseMessage],
) -> tuple[SourceResult, ...]:
    """Collect source artifacts from the graph's public final state."""

    results: list[SourceResult] = []
    for message in messages:
        if not isinstance(message, ToolMessage):
            continue
        artifact = getattr(message, "artifact", None)
        candidates = artifact if isinstance(artifact, (list, tuple)) else (artifact,)
        for candidate in candidates:
            if isinstance(candidate, SourceResult):
                results.append(candidate)
    return tuple(results)


def _replan_script(prefix: str) -> list[AIMessage]:
    return [
        _tool_message(
            "write_todos",
            {
                "todos": [
                    {
                        "content": "Inspect synthetic region monitoring",
                        "status": "in_progress",
                    }
                ]
            },
            "plan-initial",
        ),
        _tool_message(
            "get_monitoring",
            {"resource": "dead_end"},
            "monitoring-dead-end",
        ),
        _tool_message(
            "write_todos",
            {
                "todos": [
                    {
                        "content": "Use repository and runbook evidence",
                        "status": "in_progress",
                    }
                ]
            },
            "plan-revised",
        ),
        _tool_message(
            "read_source",
            {
                "path": "logs/checkout.log",
                "evidence_ids": [f"{prefix}-2"],
            },
            "repository-alternate",
        ),
        _tool_message(
            "search_runbooks",
            {"query": "checkout 5xx deploy tax-service timeout"},
            "runbook-alternate",
        ),
        AIMessage(
            content=(
                f"{_EXPECTED_REPLAN_CLAIM} "
                f"[evidence:{prefix}-4] [evidence:{prefix}-5]."
            )
        ),
    ]


def _expected_replan_claims_supported(answer: str) -> bool:
    claim = _ANSWER_CITATION.sub("", answer).strip()
    return claim.rstrip(".").casefold() == _EXPECTED_REPLAN_CLAIM.rstrip(".").casefold()


def _tool_message(name: str, args: dict[str, object], call_id: str) -> AIMessage:
    return AIMessage(
        content="",
        tool_calls=[
            {
                "name": name,
                "args": args,
                "id": f"tool-eval-{call_id}",
                "type": "tool_call",
            }
        ],
    )


def _observed_result(
    name: str,
    passed: bool,
    pass_message: str,
    fail_message: str,
    capabilities: tuple[Capability, ...],
) -> CheckResult:
    if passed:
        return CheckResult.pass_(
            name,
            pass_message,
            capabilities=capabilities,
        )
    return CheckResult.fail(
        name,
        fail_message,
        capabilities=capabilities,
    )


def _failed_replan_rows() -> list[CheckResult]:
    return [
        CheckResult.fail(
            "scenario.replanning",
            "deterministic replan scenario could not complete",
            capabilities=(Capability.PLANNING, Capability.REPLANNING),
        ),
        CheckResult.fail(
            "scenario.source-families",
            "required source-family outcomes were not observed",
            capabilities=(
                Capability.REPOSITORY,
                Capability.MONITORING,
                Capability.RUNBOOK,
            ),
        ),
        CheckResult.fail(
            "scenario.two-family-grounding",
            "current-run two-family grounding was not observed",
            capabilities=(
                Capability.TWO_FAMILY_GROUNDING,
                Capability.EVIDENCE_ISSUANCE_CITATION_REFUSAL,
            ),
        ),
    ]


class _DisabledRunbookIndex:
    def search(self, _query: str, *, max_results: int = 3) -> list[object]:
        del max_results
        return []

    def as_retriever(self, *, max_results: int = 3) -> object:
        from langchain_core.retrievers import BaseRetriever

        class _EmptyRetriever(BaseRetriever):
            def _get_relevant_documents(
                self,
                query: str,
                *,
                run_manager: object,
            ) -> list[object]:
                del query, run_manager
                return []

        del max_results
        return _EmptyRetriever()


class _DisabledMonitoringClient:
    def get(self, resource: object, **_kwargs: object) -> SourceResult:
        name = getattr(resource, "value", "disabled")
        return _disabled_source_result(
            SourceFamily.MONITORING,
            f"monitoring:{name}",
        )


class _DisabledSourceService:
    def list_files(self, path: str = ".") -> SourceResult:
        del path
        return _disabled_source_result(
            SourceFamily.REPOSITORY,
            "repository:list:disabled",
        )

    def read_file(
        self,
        path: str,
        *,
        offset: int = 0,
        limit: int | None = None,
    ) -> SourceResult:
        del path, offset, limit
        return _disabled_source_result(
            SourceFamily.REPOSITORY,
            "repository:read:disabled",
        )

    def search(
        self,
        query: str,
        *,
        path: str = ".",
        max_results: int = 20,
    ) -> SourceResult:
        del query, path, max_results
        return _disabled_source_result(
            SourceFamily.REPOSITORY,
            "repository:search:disabled",
        )


def _disabled_source_result(
    family: SourceFamily,
    source_id: str,
) -> SourceResult:
    return SourceResult(
        source_family=family,
        source_id=source_id,
        status=SourceStatus.FAILED,
        content="",
        content_sha256=hashlib.sha256(b"").hexdigest(),
    )

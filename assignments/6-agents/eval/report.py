"""Bounded evaluator result contracts and authoritative capability reporting."""

from __future__ import annotations

import re
import unicodedata
from dataclasses import dataclass
from enum import StrEnum

from ops_scaffold.config import ALLOWED_PACKAGES

_RESULT_NAME = re.compile(r"[A-Za-z0-9][A-Za-z0-9._:-]{0,127}\Z")
_TODO_ID = re.compile(r"U4-[1-6]-[a-z0-9-]{1,80}\Z")
_MAX_MESSAGE = 300
REQUIRED_CORE_RESULTS = frozenset(
    {
        "structural.package-selector",
        "structural.package-contract",
        "todo.U4-1-agent-composition",
        "todo.U4-2-bounded-source-tools",
        "todo.U4-3-identity-fact-memory",
        "todo.U4-4-structured-procedures",
        "todo.U4-5-guided-compaction",
        "todo.U4-6-evidence-action-policy",
        "component.cross-thread-fact",
        "component.procedure-recall",
        "component.durable-write-evidence",
        "component.identity-event-safety",
        "component.compaction-needle",
        "component.compaction-safety",
        "component.repository-scope-order",
        "component.injection-blocking",
        "component.evidence-policy",
        "scenario.replanning",
        "scenario.source-families",
        "scenario.two-family-grounding",
    }
)


class ResultState(StrEnum):
    """Closed states shared by core and live evaluator rows."""

    PASS = "PASS"  # noqa: S105 - evaluator state, not a credential
    FAIL = "FAIL"
    SKIP = "SKIP"
    UNAVAILABLE = "UNAVAILABLE"


class Capability(StrEnum):
    """Stable Capability Ledger identifiers."""

    PLANNING = "planning"
    REPOSITORY = "repository"
    MONITORING = "monitoring"
    RUNBOOK = "runbook"
    TWO_FAMILY_GROUNDING = "two_family_grounding"
    COMPACTION_NEEDLE = "compaction_needle"
    CROSS_THREAD_FACT_RECALL = "cross_thread_fact_recall"
    PROCEDURE_RECALL = "procedure_recall"
    REPLANNING = "replanning"
    INJECTION_BLOCKING = "injection_blocking"
    EVIDENCE_ISSUANCE_CITATION_REFUSAL = "evidence_issuance_citation_refusal"
    IDENTITY_ISOLATION_EVENT_SAFETY = "identity_isolation_event_safety"


@dataclass(frozen=True, slots=True)
class CheckResult:
    """One bounded public evaluator outcome."""

    name: str
    state: ResultState
    message: str
    capabilities: tuple[Capability, ...] = ()
    todo_id: str | None = None

    def __post_init__(self) -> None:
        if not isinstance(self.name, str) or not _RESULT_NAME.fullmatch(self.name):
            raise ValueError("result name must be a bounded identifier")
        if not isinstance(self.state, ResultState):
            raise TypeError("result state must use ResultState")
        object.__setattr__(self, "message", safe_public_message(self.message))
        if (
            not isinstance(self.capabilities, tuple)
            or not all(isinstance(item, Capability) for item in self.capabilities)
            or len(set(self.capabilities)) != len(self.capabilities)
        ):
            raise TypeError("result capabilities must be unique Capability values")
        if self.todo_id is not None and (
            not isinstance(self.todo_id, str) or not _TODO_ID.fullmatch(self.todo_id)
        ):
            raise ValueError("result TODO identifier is invalid")
        if self.state is ResultState.SKIP and self.todo_id is None:
            # Core SKIP is reserved for a declared, untouched student boundary.
            raise ValueError("SKIP requires a declared student TODO identifier")
        if self.todo_id is not None and self.state is not ResultState.SKIP:
            raise ValueError("student TODO identifiers are valid only for SKIP")

    @classmethod
    def pass_(
        cls,
        name: str,
        message: str,
        *,
        capabilities: tuple[Capability, ...] = (),
    ) -> CheckResult:
        return cls(name, ResultState.PASS, message, capabilities)

    @classmethod
    def fail(
        cls,
        name: str,
        message: str,
        *,
        capabilities: tuple[Capability, ...] = (),
    ) -> CheckResult:
        return cls(name, ResultState.FAIL, message, capabilities)

    @classmethod
    def skip(
        cls,
        name: str,
        message: str,
        *,
        todo_id: str,
        capabilities: tuple[Capability, ...] = (),
    ) -> CheckResult:
        return cls(
            name,
            ResultState.SKIP,
            message,
            capabilities,
            todo_id,
        )

    @classmethod
    def unavailable(cls, name: str, message: str) -> CheckResult:
        return cls(name, ResultState.UNAVAILABLE, message)

    def as_public_dict(self) -> dict[str, object]:
        value: dict[str, object] = {
            "name": self.name,
            "state": self.state.value,
            "message": self.message,
            "capabilities": [item.value for item in self.capabilities],
        }
        if self.todo_id is not None:
            value["todo_id"] = self.todo_id
        return value


@dataclass(frozen=True, slots=True)
class LedgerRow:
    capability: Capability
    state: ResultState
    message: str

    def as_public_dict(self) -> dict[str, str]:
        return {
            "capability": self.capability.value,
            "state": self.state.value,
            "message": self.message,
        }


class EvaluationReport:
    """Keep authoritative core outcomes separate from optional live feedback."""

    def __init__(self, *, package_name: str) -> None:
        if package_name not in ALLOWED_PACKAGES:
            raise ValueError("report package is unsupported")
        self.package_name = package_name
        self.core_results: list[CheckResult] = []
        self.live_results: list[CheckResult] = []

    def add_core(self, result: CheckResult) -> None:
        self._append(self.core_results, result)

    def extend_core(self, results: list[CheckResult] | tuple[CheckResult, ...]) -> None:
        for result in results:
            self.add_core(result)

    def add_live(self, result: CheckResult) -> None:
        self._append(self.live_results, result)

    def extend_live(self, results: list[CheckResult] | tuple[CheckResult, ...]) -> None:
        for result in results:
            self.add_live(result)

    @property
    def core_complete(self) -> bool:
        observed_names = {result.name for result in self.core_results}
        return REQUIRED_CORE_RESULTS <= observed_names and all(
            result.state is ResultState.PASS for result in self.core_results
        )

    @property
    def exit_code(self) -> int:
        return 0 if self.core_complete else 1

    def capability_ledger(self) -> tuple[LedgerRow, ...]:
        rows: list[LedgerRow] = []
        for capability in Capability:
            observed = [result for result in self.core_results if capability in result.capabilities]
            states = {result.state for result in observed}
            if ResultState.FAIL in states:
                state = ResultState.FAIL
                message = "a deterministic observation failed"
            elif ResultState.SKIP in states:
                state = ResultState.SKIP
                message = "student TODO prevented deterministic observation"
            elif ResultState.UNAVAILABLE in states:
                state = ResultState.FAIL
                message = "authoritative observation was unavailable"
            elif ResultState.PASS in states:
                state = ResultState.PASS
                message = "observed by deterministic execution"
            else:
                state = ResultState.FAIL
                message = "no deterministic observation was recorded"
            rows.append(LedgerRow(capability, state, message))
        return tuple(rows)

    def as_public_dict(self) -> dict[str, object]:
        return {
            "package": self.package_name,
            "core_complete": self.core_complete,
            "core": [result.as_public_dict() for result in self.core_results],
            "live": [result.as_public_dict() for result in self.live_results],
            "capability_ledger": [row.as_public_dict() for row in self.capability_ledger()],
        }

    def render(self) -> str:
        lines = [
            f"Ops Copilot evaluation package={self.package_name}",
            "",
            "Authoritative core",
        ]
        lines.extend(_render_results(self.core_results))
        lines.extend(("", "Capability Ledger"))
        for row in self.capability_ledger():
            lines.append(f"  [{row.state.value}] {row.capability.value}: {row.message}")
        lines.extend(("", "Optional live quality"))
        if self.live_results:
            lines.extend(_render_results(self.live_results))
        else:
            lines.append("  [UNAVAILABLE] live.not-requested: run with --full")
        counts = {
            state: sum(result.state is state for result in self.core_results)
            for state in ResultState
        }
        status = "PASS" if self.core_complete else "INCOMPLETE"
        lines.extend(
            (
                "",
                (
                    f"Core {status}: {counts[ResultState.PASS]} pass, "
                    f"{counts[ResultState.FAIL]} fail, "
                    f"{counts[ResultState.SKIP]} skip, "
                    f"{counts[ResultState.UNAVAILABLE]} unavailable"
                ),
            )
        )
        return "\n".join(lines)

    @staticmethod
    def _append(destination: list[CheckResult], result: CheckResult) -> None:
        if not isinstance(result, CheckResult):
            raise TypeError("reports accept CheckResult values only")
        if len(destination) >= 256:
            raise ValueError("report result limit reached")
        if any(existing.name == result.name for existing in destination):
            raise ValueError("report result names must be unique within a section")
        destination.append(result)


def safe_public_message(value: object) -> str:
    """Normalize one public message without exposing controls or unbounded data."""

    if not isinstance(value, str):
        return "bounded evaluator message unavailable"
    normalized = unicodedata.normalize("NFC", value)
    visible = "".join(
        " " if unicodedata.category(character).startswith("C") else character
        for character in normalized
    )
    collapsed = " ".join(visible.split())
    if not collapsed:
        collapsed = "bounded evaluator message unavailable"
    return collapsed[:_MAX_MESSAGE]


def _render_results(results: list[CheckResult]) -> list[str]:
    return [f"  [{result.state.value}] {result.name}: {result.message}" for result in results]

"""Framework-light public contracts shared by both solution packages.

The dataclasses and protocols in this module describe data and injected
capabilities only. Runtime resources are created by ``ops_scaffold.bootstrap``
in a later implementation unit, never while importing a package.
"""

from __future__ import annotations

import re
import unicodedata
from collections.abc import Callable, Iterator, Mapping, Sequence
from dataclasses import dataclass, fields
from enum import StrEnum
from typing import Protocol

EVENT_SCHEMA_VERSION = 1
PROCEDURE_SCHEMA_VERSION = 1

_IDENTIFIER = re.compile(r"[A-Za-z0-9][A-Za-z0-9._:-]{0,127}\Z")
_RESOURCE = re.compile(r"(?:repository|monitoring|runbook):[A-Za-z0-9][A-Za-z0-9._:/-]{0,159}\Z")
_SHA256 = re.compile(r"[0-9a-f]{64}\Z")
_MAX_SOURCE_CONTENT = 262_144
_MAX_PROCEDURE_STEPS = 32
_MAX_STEP_LENGTH = 500
_MAX_PROVENANCE_REFS = 64


class ContractError(ValueError):
    """A safe, bounded validation error for a public contract."""


class CapabilityBlocked(PermissionError):
    """A safe policy denial that must terminate the turn as blocked."""


class RuntimeChannel(StrEnum):
    CLI = "cli"
    CHAINLIT = "chainlit"
    EVALUATOR = "evaluator"


class SourceFamily(StrEnum):
    REPOSITORY = "repository"
    MONITORING = "monitoring"
    RUNBOOK = "runbook"


class SourceStatus(StrEnum):
    OK = "ok"
    NOT_FOUND = "not_found"
    BLOCKED = "blocked"
    FAILED = "failed"


class TrustLabel(StrEnum):
    TRUSTED_DATA = "trusted_data"
    UNTRUSTED_DATA = "untrusted_data"
    QUARANTINED = "quarantined"


class EvidenceStatus(StrEnum):
    ISSUED = "issued"
    FAILED = "failed"
    TRUNCATED = "truncated"


class EventType(StrEnum):
    SOURCE = "source"
    MEMORY = "memory"
    COMPACTION = "compaction"
    PLAN_SNAPSHOT = "plan_snapshot"
    TURN = "turn"


class EventStatus(StrEnum):
    STARTED = "started"
    COMPLETED = "completed"
    BLOCKED = "blocked"
    CANCELLED = "cancelled"
    BUDGET_EXCEEDED = "budget_exceeded"
    FAILED = "failed"


class MemoryLevel(StrEnum):
    WORKING = "working"
    FACT = "fact"
    PROCEDURE = "procedure"


@dataclass(frozen=True, slots=True)
class RuntimeContext:
    """Trusted runner context; user or model input must never construct scopes."""

    identity_id: str
    thread_id: str
    run_id: str
    channel: RuntimeChannel = RuntimeChannel.EVALUATOR
    allowed_resources: tuple[str, ...] | None = None

    def __post_init__(self) -> None:
        _validate_identifier(self.identity_id, "runtime identity")
        _validate_identifier(self.thread_id, "runtime thread")
        _validate_identifier(self.run_id, "runtime run")
        if not isinstance(self.channel, RuntimeChannel):
            raise ContractError("runtime channel is unsupported")
        if self.allowed_resources is not None:
            _validate_resources(self.allowed_resources, "runtime resource scope")

    @classmethod
    def from_mapping(cls, value: Mapping[str, object]) -> RuntimeContext:
        """Validate a strict external representation without echoing raw values."""

        if not isinstance(value, Mapping):
            raise ContractError("runtime context must be a mapping")
        required = {"identity_id", "thread_id", "run_id"}
        allowed = required | {"channel", "allowed_resources"}
        if set(value) - allowed:
            raise ContractError("runtime context contains unsupported fields")
        if not required.issubset(value):
            raise ContractError("runtime context is missing required fields")

        channel_value = value.get("channel", RuntimeChannel.EVALUATOR)
        try:
            channel = (
                channel_value
                if isinstance(channel_value, RuntimeChannel)
                else RuntimeChannel(channel_value)
            )
        except (TypeError, ValueError) as exc:
            raise ContractError("runtime channel is unsupported") from exc

        return cls(
            identity_id=value["identity_id"],  # type: ignore[arg-type]
            thread_id=value["thread_id"],  # type: ignore[arg-type]
            run_id=value["run_id"],  # type: ignore[arg-type]
            channel=channel,
            allowed_resources=value.get("allowed_resources"),  # type: ignore[arg-type]
        )


@dataclass(frozen=True, slots=True)
class SourceResult:
    """Bounded result returned by a narrow source capability."""

    source_family: SourceFamily
    source_id: str
    status: SourceStatus
    content: str
    content_sha256: str
    truncated: bool = False
    quarantined_segments: tuple[str, ...] = ()
    allowed_resources: tuple[str, ...] = ()

    def __post_init__(self) -> None:
        if not isinstance(self.source_family, SourceFamily):
            raise ContractError("source family is unsupported")
        _validate_identifier(self.source_id, "source identifier")
        if not isinstance(self.status, SourceStatus):
            raise ContractError("source status is unsupported")
        _validate_text(self.content, "source content", _MAX_SOURCE_CONTENT, allow_empty=True)
        _validate_digest(self.content_sha256, "source digest")
        if type(self.truncated) is not bool:
            raise ContractError("source truncated flag must be boolean")
        if not isinstance(self.quarantined_segments, tuple):
            raise ContractError("source quarantine markers must be a tuple")
        for marker in self.quarantined_segments:
            _validate_identifier(marker, "source quarantine marker")
        _validate_resources(self.allowed_resources, "source allowed resources")


@dataclass(frozen=True, slots=True)
class ProvenanceRef:
    """Immutable source provenance suitable for durable memory."""

    source_family: SourceFamily
    source_id: str
    content_sha256: str

    def __post_init__(self) -> None:
        if not isinstance(self.source_family, SourceFamily):
            raise ContractError("provenance source family is unsupported")
        _validate_identifier(self.source_id, "provenance source identifier")
        _validate_digest(self.content_sha256, "provenance digest")


@dataclass(frozen=True, slots=True)
class Evidence:
    """Run-scoped evidence issued by the injected evidence registry."""

    evidence_id: str
    identity_id: str
    run_id: str
    provenance: ProvenanceRef
    status: EvidenceStatus
    trust: TrustLabel
    allowed_resources: tuple[str, ...] = ()

    def __post_init__(self) -> None:
        _validate_identifier(self.evidence_id, "evidence identifier")
        _validate_identifier(self.identity_id, "evidence identity")
        _validate_identifier(self.run_id, "evidence run")
        if not isinstance(self.provenance, ProvenanceRef):
            raise ContractError("evidence provenance is malformed")
        if not isinstance(self.status, EvidenceStatus):
            raise ContractError("evidence status is unsupported")
        if not isinstance(self.trust, TrustLabel):
            raise ContractError("evidence trust label is unsupported")
        _validate_resources(self.allowed_resources, "evidence allowed resources")


@dataclass(frozen=True, slots=True)
class Procedure:
    """Versioned, structured procedural memory record."""

    procedure_id: str
    version: int
    title: str
    steps: tuple[str, ...]
    provenance: tuple[ProvenanceRef, ...] = ()

    def __post_init__(self) -> None:
        _validate_identifier(self.procedure_id, "procedure identifier")
        if type(self.version) is not int or self.version != PROCEDURE_SCHEMA_VERSION:
            raise ContractError("procedure schema version is unsupported")
        _validate_text(self.title, "procedure title", 120)
        _validate_procedure_text(self.title, "procedure title")
        if not isinstance(self.steps, tuple) or not 1 <= len(self.steps) <= _MAX_PROCEDURE_STEPS:
            raise ContractError("procedure steps must be a non-empty bounded tuple")
        for step in self.steps:
            _validate_text(step, "procedure step", _MAX_STEP_LENGTH)
            _validate_procedure_text(step, "procedure step")
        if (
            not isinstance(self.provenance, tuple)
            or not all(isinstance(item, ProvenanceRef) for item in self.provenance)
            or len(self.provenance) > _MAX_PROVENANCE_REFS
        ):
            raise ContractError("procedure provenance is malformed")


@dataclass(frozen=True, slots=True)
class AppEvent:
    """Closed, metadata-only event envelope consumed by CLI and Chainlit."""

    schema_version: int
    event_type: EventType
    run_id: str
    status: EventStatus
    source_family: SourceFamily | None = None
    memory_level: MemoryLevel | None = None
    count: int | None = None
    artifact_id: str | None = None
    digest: str | None = None

    def __post_init__(self) -> None:
        if type(self.schema_version) is not int or self.schema_version != EVENT_SCHEMA_VERSION:
            raise ContractError("event schema version is unsupported")
        if not isinstance(self.event_type, EventType):
            raise ContractError("event type is unsupported")
        _validate_identifier(self.run_id, "event run")
        if not isinstance(self.status, EventStatus):
            raise ContractError("event status is unsupported")
        if self.source_family is not None and not isinstance(self.source_family, SourceFamily):
            raise ContractError("event source family is unsupported")
        if self.memory_level is not None and not isinstance(self.memory_level, MemoryLevel):
            raise ContractError("event memory level is unsupported")
        if self.count is not None and (
            type(self.count) is not int or not 0 <= self.count <= 1_000_000
        ):
            raise ContractError("event count must be a bounded non-negative integer")
        if self.artifact_id is not None:
            _validate_identifier(self.artifact_id, "event artifact identifier")
        if self.digest is not None:
            _validate_digest(self.digest, "event digest")
        present = {
            name
            for name in ("source_family", "memory_level", "count", "artifact_id", "digest")
            if getattr(self, name) is not None
        }
        required: dict[EventType, set[str]] = {
            EventType.SOURCE: {"source_family", "count", "artifact_id"},
            EventType.MEMORY: {"memory_level", "count"},
            EventType.COMPACTION: {"count", "artifact_id", "digest"},
            EventType.PLAN_SNAPSHOT: {"count", "artifact_id", "digest"},
            EventType.TURN: set(),
        }
        allowed = {
            **required,
            EventType.MEMORY: {*required[EventType.MEMORY], "artifact_id"},
        }
        missing = required[self.event_type] - present
        unsupported = present - allowed[self.event_type]
        if missing or unsupported:
            raise ContractError("event fields do not match the event type")
        if self.event_type is EventType.PLAN_SNAPSHOT and self.status is not EventStatus.COMPLETED:
            raise ContractError("plan snapshots must describe completed updates")
        if self.event_type is EventType.SOURCE and self.status not in {
            EventStatus.COMPLETED,
            EventStatus.BLOCKED,
            EventStatus.FAILED,
        }:
            raise ContractError("source event status is unsupported")
        if self.event_type is EventType.COMPACTION and self.status not in {
            EventStatus.COMPLETED,
            EventStatus.FAILED,
        }:
            raise ContractError("compaction event status is unsupported")


class EventSink(Protocol):
    def emit(self, event: AppEvent) -> None:
        """Publish a validated metadata event."""


class EvidenceRegistry(Protocol):
    def begin_turn(self, context: RuntimeContext) -> None:
        """Start an empty current-turn evidence scope."""

    def issue(self, context: RuntimeContext, result: SourceResult) -> Evidence:
        """Issue evidence scoped to the current identity and run."""

    def resolve(self, context: RuntimeContext, evidence_id: str) -> Evidence | None:
        """Resolve current-run evidence without crossing scopes."""

    def snapshot(self, context: RuntimeContext) -> Sequence[Evidence]:
        """Return current evidence without exposing registry internals."""

    def finish_turn(self, context: RuntimeContext) -> Sequence[Evidence]:
        """Close the turn and return its immutable metadata records."""

    def abort_turn(self, context: RuntimeContext) -> None:
        """Discard a failed current-turn scope."""


class ProcedureService(Protocol):
    def list(self, context: RuntimeContext) -> Sequence[str]:
        """List structured procedure identifiers in the current identity scope."""

    def read(self, context: RuntimeContext, procedure_id: str) -> Procedure | None:
        """Read one identity-scoped procedure."""

    def write(
        self,
        context: RuntimeContext,
        procedure: Procedure,
        *,
        expected_hash: str | None,
    ) -> str:
        """Atomically write a procedure and return its immutable content hash."""


class IdentityNamespace(Protocol):
    def __call__(self, context: RuntimeContext) -> tuple[str, ...]:
        """Derive an opaque identity-scoped Store namespace."""


class AgentRuntime(Protocol):
    def invoke(
        self,
        input: Mapping[str, object],
        config: Mapping[str, object],
        *,
        context: RuntimeContext,
    ) -> Mapping[str, object]:
        """Invoke the LangChain v1 agent graph with trusted runtime context."""

    def stream(
        self,
        input: Mapping[str, object],
        config: Mapping[str, object],
        *,
        context: RuntimeContext,
        stream_mode: str | Sequence[str],
    ) -> Iterator[object]:
        """Stream bounded graph updates and custom events for one trusted run."""

    def get_state(self, config: Mapping[str, object]) -> object:
        """Read the checkpointed public graph state used by deterministic evaluation."""


@dataclass(frozen=True, slots=True)
class ServiceBundle:
    """Process- or test-scoped dependencies owned by explicit bootstrap code."""

    agent_model: object
    summarizer_model: object
    store: object
    checkpointer: object
    retriever: object
    source_service: object
    monitoring_client: object
    procedure_service: ProcedureService
    evidence_registry: EvidenceRegistry
    event_sink: EventSink
    clock: Callable[[], float]
    new_id: Callable[[], str]
    fact_namespace: IdentityNamespace
    provenance_namespace: IdentityNamespace

    def __post_init__(self) -> None:
        for descriptor in fields(self):
            if getattr(self, descriptor.name) is None:
                raise ContractError("service bundle dependencies must be explicit")
        for name in ("clock", "new_id", "fact_namespace", "provenance_namespace"):
            if not callable(getattr(self, name)):
                raise ContractError("service bundle callables must be explicit")


class PackageFactory(Protocol):
    """Factory exported by ``ops_copilot`` and ``reference_solution`` packages."""

    def __call__(
        self,
        *,
        services: ServiceBundle,
        max_model_calls: int = 16,
        max_tool_calls: int = 24,
    ) -> AgentRuntime:
        """Compose a LangChain v1 ``create_agent`` graph from injected services."""


def _validate_identifier(value: object, label: str) -> None:
    if not isinstance(value, str) or not _IDENTIFIER.fullmatch(value):
        raise ContractError(f"{label} must be a bounded opaque identifier")


def _validate_digest(value: object, label: str) -> None:
    if not isinstance(value, str) or not _SHA256.fullmatch(value):
        raise ContractError(f"{label} must be a lowercase SHA-256 digest")


def _validate_resources(value: object, label: str) -> None:
    if (
        not isinstance(value, tuple)
        or len(value) > 128
        or any(not isinstance(item, str) or not _RESOURCE.fullmatch(item) for item in value)
    ):
        raise ContractError(f"{label} must be unique bounded resource identifiers")
    if len(set(value)) != len(value):
        raise ContractError(f"{label} must be unique bounded resource identifiers")


def _validate_text(
    value: object,
    label: str,
    maximum: int,
    *,
    allow_empty: bool = False,
) -> None:
    if not isinstance(value, str) or "\x00" in value or len(value) > maximum:
        raise ContractError(f"{label} must be bounded text without null bytes")
    if not allow_empty and not value.strip():
        raise ContractError(f"{label} must be non-empty bounded text")


def _validate_procedure_text(value: str, label: str) -> None:
    if value != unicodedata.normalize("NFC", value) or any(
        unicodedata.category(character) == "Cc" for character in value
    ):
        raise ContractError(f"{label} must be normalized text without controls")

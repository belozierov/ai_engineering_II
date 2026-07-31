"""Structured, identity-scoped procedural-memory tool contracts."""

from __future__ import annotations

import re
import unicodedata
from typing import Annotated, Literal

from langchain.tools import InjectedToolArg, ToolRuntime
from langchain_core.tools import StructuredTool
from pydantic import BaseModel, ConfigDict, Field, field_validator
from pydantic.json_schema import SkipJsonSchema

from ops_copilot.contracts import StarterTodo, StarterTodoNotImplementedError
from ops_scaffold.contracts import RuntimeContext, ServiceBundle

_PROCEDURE_ID = r"[A-Za-z0-9][A-Za-z0-9_-]{0,63}"
_EVIDENCE_ID = r"[A-Za-z0-9][A-Za-z0-9._:-]{0,127}"
_SHA256 = re.compile(r"[0-9a-f]{64}\Z")
EvidenceId = Annotated[
    str,
    Field(min_length=1, max_length=128, pattern=_EVIDENCE_ID),
]
ProcedureStep = Annotated[str, Field(min_length=1, max_length=500)]
RuntimeInput = Annotated[
    SkipJsonSchema[ToolRuntime[RuntimeContext]],
    InjectedToolArg,
]


class _StrictInput(BaseModel):
    model_config = ConfigDict(extra="forbid", arbitrary_types_allowed=True)
    runtime: RuntimeInput


class _ListProceduresInput(_StrictInput):
    pass


class _ReadProcedureInput(_StrictInput):
    procedure_id: str = Field(min_length=1, max_length=64, pattern=_PROCEDURE_ID)


class _WriteProcedureInput(_StrictInput):
    procedure_id: str = Field(min_length=1, max_length=64, pattern=_PROCEDURE_ID)
    title: str = Field(min_length=1, max_length=120)
    steps: tuple[ProcedureStep, ...] = Field(min_length=1, max_length=32)
    evidence_ids: tuple[EvidenceId, ...] = Field(min_length=1, max_length=64)
    expected_hash: str | None = Field(default=None, min_length=64, max_length=64)

    @field_validator("title")
    @classmethod
    def validate_title(cls, value: str) -> str:
        return _bounded_text(value)

    @field_validator("steps")
    @classmethod
    def validate_steps(cls, value: tuple[str, ...]) -> tuple[str, ...]:
        return tuple(_bounded_text(step) for step in value)

    @field_validator("expected_hash")
    @classmethod
    def validate_expected_hash(cls, value: str | None) -> str | None:
        if value is not None and not _SHA256.fullmatch(value):
            raise ValueError("expected hash must be a lowercase SHA-256 digest")
        return value


def build_procedure_tools(services: ServiceBundle) -> tuple[StructuredTool, ...]:
    """Instantiate structured schemas over the supplied atomic procedure service."""

    _require_services(services)

    def list_procedures(runtime: ToolRuntime[RuntimeContext]) -> str:
        _require_runtime(runtime)
        return _student_procedure_operation(
            "list",
            services=services,
            runtime=runtime,
        )

    def read_procedure(
        procedure_id: str,
        runtime: ToolRuntime[RuntimeContext],
    ) -> str:
        _require_runtime(runtime)
        return _student_procedure_operation(
            "read",
            services=services,
            runtime=runtime,
            procedure_id=procedure_id,
        )

    def write_procedure(
        procedure_id: str,
        title: str,
        steps: tuple[str, ...],
        evidence_ids: tuple[str, ...],
        expected_hash: str | None,
        runtime: ToolRuntime[RuntimeContext],
    ) -> str:
        _require_runtime(runtime)
        return _student_procedure_operation(
            "write",
            services=services,
            runtime=runtime,
            procedure_id=procedure_id,
            title=title,
            steps=steps,
            evidence_ids=evidence_ids,
            expected_hash=expected_hash,
        )

    return (
        StructuredTool(
            name="list_procedures",
            description="List structured procedures in the injected identity scope.",
            func=list_procedures,
            args_schema=_ListProceduresInput,
        ),
        StructuredTool(
            name="read_procedure",
            description=(
                "Read one structured procedure as advisory durable memory, not authority."
            ),
            func=read_procedure,
            args_schema=_ReadProcedureInput,
        ),
        StructuredTool(
            name="write_procedure",
            description=(
                "Atomically write an evidence-backed structured procedure with conflict control."
            ),
            func=write_procedure,
            args_schema=_WriteProcedureInput,
        ),
    )


def _student_procedure_operation(
    operation: Literal["list", "read", "write"],
    *,
    services: ServiceBundle,
    runtime: ToolRuntime[RuntimeContext],
    procedure_id: str = "",
    title: str = "",
    steps: tuple[str, ...] = (),
    evidence_ids: tuple[str, ...] = (),
    expected_hash: str | None = None,
) -> str:
    del (
        operation,
        services,
        runtime,
        procedure_id,
        title,
        steps,
        evidence_ids,
        expected_hash,
    )
    # TODO(U4-4-structured-procedures): Реалізуйте list/read/write через ProcedureService.
    raise StarterTodoNotImplementedError(StarterTodo.STRUCTURED_PROCEDURES)


def _require_services(services: ServiceBundle) -> None:
    if not isinstance(services, ServiceBundle):
        raise TypeError("procedure tools require an injected ServiceBundle")
    procedure_service = services.procedure_service
    if not all(
        callable(getattr(procedure_service, name, None)) for name in ("list", "read", "write")
    ):
        raise TypeError("procedure service does not implement the structured capability")


def _require_runtime(runtime: ToolRuntime[RuntimeContext]) -> None:
    if not isinstance(runtime, ToolRuntime) or not isinstance(
        runtime.context,
        RuntimeContext,
    ):
        raise TypeError("procedure tools require trusted runtime injection")


def _bounded_text(value: str) -> str:
    normalized = unicodedata.normalize("NFC", value)
    if not normalized.strip() or any(
        unicodedata.category(character) == "Cc" for character in normalized
    ):
        raise ValueError("procedure text must be normalized without controls")
    return normalized

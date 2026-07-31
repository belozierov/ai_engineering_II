"""Current-run evidence checks that never turn untrusted data into authority."""

from __future__ import annotations

import re
from collections.abc import Mapping, Sequence
from enum import StrEnum

from langchain.agents.middleware import AgentMiddleware, hook_config
from langchain_core.messages import BaseMessage
from langchain_core.tools import ToolException
from langgraph.runtime import Runtime

from ops_copilot.contracts import StarterTodo, StarterTodoNotImplementedError
from ops_scaffold.contracts import (
    CapabilityBlocked,
    Evidence,
    EvidenceRegistry,
    ProvenanceRef,
    RuntimeContext,
)

_IDENTIFIER = re.compile(r"[A-Za-z0-9][A-Za-z0-9._:-]{0,127}\Z")
_RESOURCE = re.compile(r"(?:repository|monitoring|runbook):[A-Za-z0-9][A-Za-z0-9._:/-]{0,159}\Z")
_MAX_EVIDENCE_IDS = 64


class EvidenceAction(StrEnum):
    READ_SOURCE = "read_source"
    WRITE_FACT = "write_fact"
    WRITE_PROCEDURE = "write_procedure"


class EvidenceActionBlocked(CapabilityBlocked, ToolException):
    """A safe denial that grants no additional source or durable-write access."""


def ensure_scenario_resource_allowed(
    context: RuntimeContext,
    requested_resource: str,
) -> None:
    """Enforce a trusted scenario allowlist before any model-directed source read."""

    if not isinstance(context, RuntimeContext):
        raise TypeError("resource checks require a trusted RuntimeContext")
    if not isinstance(requested_resource, str) or not _RESOURCE.fullmatch(requested_resource):
        raise EvidenceActionBlocked("requested source resource is malformed")
    allowed = context.allowed_resources
    if allowed is not None and requested_resource not in allowed:
        raise EvidenceActionBlocked("requested source resource is outside the run scope")


def validate_evidence_action(
    *,
    action: EvidenceAction,
    evidence_ids: tuple[str, ...],
    requested_resource: str | None,
    context: RuntimeContext,
    evidence_registry: EvidenceRegistry,
) -> tuple[ProvenanceRef, ...]:
    """Validate current-run evidence and return authority-free durable provenance."""

    if not isinstance(action, EvidenceAction):
        raise TypeError("evidence action must use the closed action enum")
    if not isinstance(context, RuntimeContext):
        raise TypeError("evidence validation requires a trusted RuntimeContext")
    if (
        not isinstance(evidence_ids, tuple)
        or not 1 <= len(evidence_ids) <= _MAX_EVIDENCE_IDS
        or any(
            not isinstance(evidence_id, str) or not _IDENTIFIER.fullmatch(evidence_id)
            for evidence_id in evidence_ids
        )
        or len(set(evidence_ids)) != len(evidence_ids)
    ):
        raise EvidenceActionBlocked("evidence identifiers are malformed")
    if not callable(getattr(evidence_registry, "resolve", None)):
        raise TypeError("evidence validation requires the injected current-run registry")
    if requested_resource is not None:
        ensure_scenario_resource_allowed(context, requested_resource)

    # TODO(U4-6-evidence-action-policy): Перевірте run scope, trust і provenance.  # noqa: RUF003
    raise StarterTodoNotImplementedError(StarterTodo.EVIDENCE_ACTION_POLICY)


def validate_final_answer(
    answer: str,
    *,
    context: RuntimeContext,
    evidence_registry: EvidenceRegistry,
    required_source_families: int = 1,
) -> tuple[Evidence, ...]:
    """Validate exact current-run citations before accepting a final answer."""

    del answer, context, evidence_registry, required_source_families
    raise StarterTodoNotImplementedError(StarterTodo.EVIDENCE_ACTION_POLICY)


class GroundedAnswerMiddleware(AgentMiddleware):
    """Replace an unsupported terminal answer with a bounded safe refusal."""

    def __init__(self, *, evidence_registry: EvidenceRegistry) -> None:
        if not callable(getattr(evidence_registry, "resolve", None)):
            raise TypeError("answer policy requires the evidence registry")
        self._registry = evidence_registry

    @hook_config(can_jump_to=["model"])
    def after_model(
        self,
        state: Mapping[str, object],
        runtime: Runtime[RuntimeContext],
    ) -> dict[str, object] | None:
        messages = state.get("messages")
        if (
            not isinstance(messages, Sequence)
            or isinstance(messages, (str, bytes))
            or not messages
            or not all(isinstance(message, BaseMessage) for message in messages)
            or not isinstance(runtime.context, RuntimeContext)
        ):
            raise TypeError("answer policy requires messages and trusted context")
        del messages
        raise StarterTodoNotImplementedError(StarterTodo.EVIDENCE_ACTION_POLICY)

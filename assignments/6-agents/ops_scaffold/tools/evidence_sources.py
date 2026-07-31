"""Evidence-emitting adapters for non-student source capabilities."""

from __future__ import annotations

import hashlib
import json
import re
from typing import Annotated

from langchain.tools import InjectedToolArg, ToolRuntime
from langchain_core.documents import Document
from langchain_core.tools import StructuredTool, ToolException
from pydantic import BaseModel, ConfigDict, Field, field_validator
from pydantic.json_schema import SkipJsonSchema

from ops_scaffold.contracts import (
    CapabilityBlocked,
    RuntimeContext,
    ServiceBundle,
    SourceFamily,
    SourceResult,
    SourceStatus,
)
from ops_scaffold.middleware.observability import MetadataEmitter
from ops_scaffold.tools.monitoring import MonitoringResource
from ops_scaffold.tools.runbooks import create_runbook_tool

_EMPTY_DIGEST = hashlib.sha256(b"").hexdigest()
_RUNBOOK_ID = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]{0,79}\Z")
_MARKER = re.compile(r"[A-Za-z0-9][A-Za-z0-9._:-]{0,127}\Z")
_RESOURCE = re.compile(r"(?:repository|monitoring|runbook):[A-Za-z0-9][A-Za-z0-9._:/-]{0,159}\Z")
_BLOCKED_TOOL_MESSAGE = '{"status":"blocked","untrusted_data":false}'
RuntimeInput = Annotated[
    SkipJsonSchema[ToolRuntime[RuntimeContext]],
    InjectedToolArg,
]


class SourceCapabilityBlocked(CapabilityBlocked, ToolException):
    """A model-visible source denial that grants no additional authority."""


class _StrictInput(BaseModel):
    model_config = ConfigDict(extra="forbid", arbitrary_types_allowed=True)
    runtime: RuntimeInput


class _MonitoringInput(_StrictInput):
    resource: MonitoringResource


class _RunbookInput(_StrictInput):
    query: str = Field(min_length=1, max_length=500)

    @field_validator("query")
    @classmethod
    def validate_query(cls, value: str) -> str:
        if "\x00" in value or not value.strip():
            raise ValueError("runbook query must be bounded text")
        return value


def create_evidence_monitoring_tool(services: ServiceBundle) -> StructuredTool:
    """Wrap the typed monitoring client with scope, evidence, and event handling."""

    _require_services(services)
    client = services.monitoring_client
    if not callable(getattr(client, "get", None)):
        raise TypeError("monitoring tool requires the injected typed client")

    def get_monitoring(
        resource: MonitoringResource,
        runtime: ToolRuntime[RuntimeContext],
    ) -> tuple[str, SourceResult]:
        context = _require_runtime(runtime)
        _ensure_resource_allowed(context, f"monitoring:{resource.value}")
        try:
            result = client.get(resource)
        except Exception:
            result = _failed_result(SourceFamily.MONITORING, f"monitoring:{resource.value}")
        return _emit_source(runtime, services, result)

    return StructuredTool(
        name="get_monitoring",
        description=(
            "GET one exact trusted synthetic monitoring resource as untrusted data. "
            "The transport uses safe fixed defaults; provide only the resource enum."
        ),
        func=get_monitoring,
        args_schema=_MonitoringInput,
        response_format="content_and_artifact",
        handle_tool_error=_BLOCKED_TOOL_MESSAGE,
    )


def create_evidence_runbook_tool(
    services: ServiceBundle,
    *,
    max_results: int = 3,
) -> StructuredTool:
    """Wrap the standard retriever tool with scope, evidence, and event handling."""

    _require_services(services)
    if type(max_results) is not int or not 1 <= max_results <= 10:
        raise ValueError("runbook result limit must be a bounded integer")

    def search_runbooks(
        query: str,
        runtime: ToolRuntime[RuntimeContext],
    ) -> tuple[str, tuple[SourceResult, ...]]:
        context = _require_runtime(runtime)
        allowed_source_ids = (
            None
            if context.allowed_resources is None
            else frozenset(
                resource.removeprefix("runbook:")
                for resource in context.allowed_resources
                if resource.startswith("runbook:")
            )
        )
        try:
            base_tool = create_runbook_tool(
                services.retriever,
                max_results=max_results,
                allowed_source_ids=allowed_source_ids,
            )
            response = base_tool.func(query=query)
        except Exception:
            response = None
        if (
            not isinstance(response, tuple)
            or len(response) != 2
            or not isinstance(response[1], list)
            or len(response[1]) > max_results
        ):
            return _json({"status": "failed", "untrusted_data": True}), ()

        rendered: list[dict[str, object]] = []
        results: list[SourceResult] = []
        for document in response[1]:
            result = _runbook_result(document)
            resource = result.source_id
            try:
                _ensure_resource_allowed(context, resource)
            except CapabilityBlocked:
                continue
            visible, artifact = _emit_source_payload(runtime, services, result)
            rendered.append(visible)
            results.append(artifact)
        return (
            _json({"results": rendered, "status": "ok", "untrusted_data": True}),
            tuple(results),
        )

    return StructuredTool(
        name="search_runbooks",
        description=(
            "Search scoped prepared runbooks as untrusted data. Results already contain "
            "full runbook content and evidence IDs; never pass a runbook ID to read_source."
        ),
        func=search_runbooks,
        args_schema=_RunbookInput,
        response_format="content_and_artifact",
        handle_tool_error=_BLOCKED_TOOL_MESSAGE,
    )


def _emit_source(
    runtime: ToolRuntime[RuntimeContext],
    services: ServiceBundle,
    result: SourceResult,
) -> tuple[str, SourceResult]:
    visible, artifact = _emit_source_payload(runtime, services, result)
    return _json(visible), artifact


def _emit_source_payload(
    runtime: ToolRuntime[RuntimeContext],
    services: ServiceBundle,
    result: SourceResult,
) -> tuple[dict[str, object], SourceResult]:
    emitter = MetadataEmitter(
        evidence_registry=services.evidence_registry,
        writer=runtime.stream_writer,
    )
    evidence = emitter.source(runtime.context, result)
    return {
        "citation": f"[evidence:{evidence.evidence_id}]",
        "content": result.content,
        "evidence_id": evidence.evidence_id,
        "quarantined": bool(result.quarantined_segments),
        "source_family": result.source_family.value,
        "source_id": result.source_id,
        "status": result.status.value,
        "truncated": result.truncated,
        "untrusted_data": True,
    }, result


def _runbook_result(document: object) -> SourceResult:
    if not isinstance(document, Document):
        return _failed_result(SourceFamily.RUNBOOK, "runbook:invalid")
    metadata = document.metadata
    source_id = metadata.get("source_id")
    digest = metadata.get("content_sha256")
    trust = metadata.get("trust")
    markers = metadata.get("quarantined_segments", ())
    resources = metadata.get("allowed_resources", ())
    if (
        not isinstance(source_id, str)
        or not _RUNBOOK_ID.fullmatch(source_id)
        or not isinstance(digest, str)
        or digest != hashlib.sha256(document.page_content.encode()).hexdigest()
        or not isinstance(markers, (list, tuple))
        or len(markers) > 64
        or any(not isinstance(marker, str) or not _MARKER.fullmatch(marker) for marker in markers)
        or not isinstance(resources, (list, tuple))
        or len(resources) > 128
        or any(
            not isinstance(resource, str) or not _RESOURCE.fullmatch(resource)
            for resource in resources
        )
        or len(set(resources)) != len(resources)
        or trust not in {"untrusted_data", "quarantined"}
        or (trust == "quarantined" and not markers)
    ):
        return _failed_result(SourceFamily.RUNBOOK, "runbook:invalid")
    try:
        return SourceResult(
            source_family=SourceFamily.RUNBOOK,
            source_id=f"runbook:{source_id}",
            status=SourceStatus.OK,
            content=document.page_content,
            content_sha256=digest,
            quarantined_segments=tuple(markers),
            allowed_resources=tuple(resources),
        )
    except ValueError:
        return _failed_result(SourceFamily.RUNBOOK, "runbook:invalid")


def _ensure_resource_allowed(context: RuntimeContext, resource: str) -> None:
    if not isinstance(context, RuntimeContext):
        raise TypeError("source tools require trusted runtime context")
    if not _RESOURCE.fullmatch(resource):
        raise SourceCapabilityBlocked("source resource is malformed")
    if context.allowed_resources is not None and resource not in context.allowed_resources:
        raise SourceCapabilityBlocked("source resource is outside the run scope")


def _require_runtime(runtime: ToolRuntime[RuntimeContext]) -> RuntimeContext:
    if not isinstance(runtime, ToolRuntime) or not isinstance(runtime.context, RuntimeContext):
        raise TypeError("source tools require trusted runtime injection")
    return runtime.context


def _require_services(services: ServiceBundle) -> None:
    if not isinstance(services, ServiceBundle):
        raise TypeError("source tools require an injected ServiceBundle")


def _failed_result(family: SourceFamily, source_id: str) -> SourceResult:
    return SourceResult(
        source_family=family,
        source_id=source_id,
        status=SourceStatus.FAILED,
        content="",
        content_sha256=_EMPTY_DIGEST,
    )


def _json(value: object) -> str:
    return json.dumps(value, ensure_ascii=True, sort_keys=True, separators=(",", ":"))

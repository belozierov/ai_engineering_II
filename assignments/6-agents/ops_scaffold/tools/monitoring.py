"""Typed GET-only client for the deterministic loopback monitoring API."""

from __future__ import annotations

import hashlib
import json
import math
import re
import zlib
from enum import StrEnum
from typing import TYPE_CHECKING, Any
from urllib.parse import urlsplit

from ops_scaffold.contracts import SourceFamily, SourceResult, SourceStatus
from ops_scaffold.monitoring_server import build_page_token, validate_page_token

if TYPE_CHECKING:
    from langchain_core.tools import StructuredTool

_EMPTY_DIGEST = hashlib.sha256(b"").hexdigest()
_SERVICE = "checkout-service"
_SERVICE_NAME = re.compile(r"[a-z][a-z0-9-]{0,63}\Z")


class MonitoringResource(StrEnum):
    HEALTH = "health"
    ERROR_RATE = "error_rate"
    DEPLOYS = "deploys"
    DEPENDENCIES = "dependencies"
    DEAD_END = "dead_end"


_ROUTE_MAP: dict[MonitoringResource, str] = {
    MonitoringResource.HEALTH: "/v1/health",
    MonitoringResource.ERROR_RATE: "/v1/error-rate",
    MonitoringResource.DEPLOYS: "/v1/deploys",
    MonitoringResource.DEPENDENCIES: "/v1/dependencies",
    MonitoringResource.DEAD_END: "/v1/dead-end",
}
_PAGED = frozenset({MonitoringResource.DEPLOYS, MonitoringResource.DEPENDENCIES})
_FOLLOW_UP_RESOURCES: dict[MonitoringResource, tuple[str, ...]] = {
    MonitoringResource.DEAD_END: (
        "repository:logs/checkout.log",
        "runbook:rb-checkout-5xx",
        "runbook:rb-dependency-timeouts",
        "runbook:pm-checkout-timeout-2026-06",
    ),
}


class _BlockedMonitoring(ValueError):
    """Untrusted input or response attempted to expand monitoring authority."""


class _FailedMonitoring(RuntimeError):
    """The allowlisted endpoint returned malformed or unavailable data."""


class MonitoringClient:
    """Bounded loopback-only transport with no proxy or redirect behavior."""

    def __init__(
        self,
        base_url: str,
        *,
        timeout_seconds: float = 0.5,
        max_wire_bytes: int = 65_536,
        max_decoded_bytes: int = 131_072,
        max_json_depth: int = 10,
    ) -> None:
        self._base_url = self._validate_origin(base_url)
        if (
            not isinstance(timeout_seconds, (int, float))
            or isinstance(timeout_seconds, bool)
            or not 0.05 <= timeout_seconds <= 2
            or type(max_wire_bytes) is not int
            or not 128 <= max_wire_bytes <= 262_144
            or type(max_decoded_bytes) is not int
            or not max_wire_bytes <= max_decoded_bytes <= 262_144
            or type(max_json_depth) is not int
            or not 2 <= max_json_depth <= 20
        ):
            raise ValueError("monitoring transport limits are invalid")
        self._timeout_seconds = float(timeout_seconds)
        self._max_wire_bytes = max_wire_bytes
        self._max_decoded_bytes = max_decoded_bytes
        self._max_json_depth = max_json_depth

    def get(
        self,
        resource: MonitoringResource,
        *,
        service: str = _SERVICE,
        window_minutes: int | None = None,
        limit: int | None = None,
        page_token: str | None = None,
    ) -> SourceResult:
        """Fetch one typed route; callers cannot supply methods or URLs."""

        safe_resource = resource if isinstance(resource, MonitoringResource) else None
        try:
            if safe_resource is None:
                raise _BlockedMonitoring
            params = self._validate_params(
                safe_resource,
                service=service,
                window_minutes=window_minutes,
                limit=limit,
                page_token=page_token,
            )
            payload = self._request(safe_resource, params)
            self._validate_payload(safe_resource, payload, params)
            content = json.dumps(
                payload,
                ensure_ascii=True,
                sort_keys=True,
                separators=(",", ":"),
            )
            return self._result(safe_resource, SourceStatus.OK, content)
        except _BlockedMonitoring:
            return self._result(safe_resource, SourceStatus.BLOCKED, "")
        except _FailedMonitoring:
            return self._result(safe_resource, SourceStatus.FAILED, "")
        except Exception:
            # Transport libraries expose many protocol-specific exception
            # classes. None of their messages or response bodies are public.
            return self._result(safe_resource, SourceStatus.FAILED, "")

    def _request(
        self,
        resource: MonitoringResource,
        params: dict[str, str],
    ) -> object:
        try:
            import httpx
        except ImportError as exc:
            raise _FailedMonitoring from exc

        timeout = httpx.Timeout(self._timeout_seconds)
        origin = httpx.URL(self._base_url)
        url = origin.copy_with(path=_ROUTE_MAP[resource])
        try:
            with httpx.Client(
                timeout=timeout,
                trust_env=False,
                follow_redirects=False,
                headers={"Accept": "application/json", "Accept-Encoding": "gzip"},
            ) as client:
                with client.stream("GET", url, params=params) as response:
                    if response.is_redirect:
                        raise _BlockedMonitoring
                    if response.status_code != 200:
                        raise _FailedMonitoring
                    self._validate_headers(response.headers)
                    raw = self._read_wire_body(response)
                    decoded = self._decode_body(raw, response.headers.get("content-encoding"))
        except (_BlockedMonitoring, _FailedMonitoring):
            raise
        except httpx.HTTPError as exc:
            raise _FailedMonitoring from exc

        try:
            return json.loads(
                decoded.decode("utf-8"),
                object_pairs_hook=self._unique_object,
                parse_constant=self._reject_json_constant,
            )
        except (UnicodeError, json.JSONDecodeError, ValueError) as exc:
            raise _FailedMonitoring from exc

    def _validate_headers(self, headers: Any) -> None:
        lengths = headers.get_list("content-length")
        if (
            len(lengths) != 1
            or not lengths[0].isascii()
            or not lengths[0].isdecimal()
            or int(lengths[0]) > self._max_wire_bytes
            or "transfer-encoding" in headers
        ):
            raise _FailedMonitoring
        media_type, *parameters = [
            piece.strip().lower() for piece in headers.get("content-type", "").split(";")
        ]
        if media_type != "application/json":
            raise _FailedMonitoring
        for parameter in parameters:
            if parameter and parameter != "charset=utf-8":
                raise _FailedMonitoring
        encoding = headers.get("content-encoding")
        if encoding is not None and encoding.lower() not in {"identity", "gzip"}:
            raise _FailedMonitoring

    def _read_wire_body(self, response: Any) -> bytes:
        expected = int(response.headers["content-length"])
        chunks: list[bytes] = []
        count = 0
        for chunk in response.iter_raw():
            count += len(chunk)
            if count > self._max_wire_bytes:
                raise _FailedMonitoring
            chunks.append(chunk)
        if count != expected:
            raise _FailedMonitoring
        return b"".join(chunks)

    def _decode_body(self, raw: bytes, encoding: str | None) -> bytes:
        if encoding is None or encoding.lower() == "identity":
            if len(raw) > self._max_decoded_bytes:
                raise _FailedMonitoring
            return raw
        decompressor = zlib.decompressobj(16 + zlib.MAX_WBITS)
        try:
            decoded = decompressor.decompress(raw, self._max_decoded_bytes + 1)
            if len(decoded) > self._max_decoded_bytes or decompressor.unconsumed_tail:
                raise _FailedMonitoring
            decoded += decompressor.flush(self._max_decoded_bytes + 1 - len(decoded))
        except zlib.error as exc:
            raise _FailedMonitoring from exc
        if (
            len(decoded) > self._max_decoded_bytes
            or not decompressor.eof
            or decompressor.unused_data
        ):
            raise _FailedMonitoring
        return decoded

    def _validate_params(
        self,
        resource: MonitoringResource,
        *,
        service: str,
        window_minutes: int | None,
        limit: int | None,
        page_token: str | None,
    ) -> dict[str, str]:
        if (
            not isinstance(service, str)
            or not _SERVICE_NAME.fullmatch(service)
            or service != _SERVICE
        ):
            raise _BlockedMonitoring
        params = {"service": service}
        if resource is MonitoringResource.ERROR_RATE:
            effective_window = 5 if window_minutes is None else window_minutes
            if type(effective_window) is not int or not 1 <= effective_window <= 60:
                raise _BlockedMonitoring
            if limit is not None or page_token is not None:
                raise _BlockedMonitoring
            params["window_minutes"] = str(effective_window)
        elif resource in _PAGED:
            if window_minutes is not None:
                raise _BlockedMonitoring
            effective_limit = 2 if limit is None else limit
            if type(effective_limit) is not int or not 1 <= effective_limit <= 10:
                raise _BlockedMonitoring
            params["limit"] = str(effective_limit)
            if page_token is not None:
                page = validate_page_token(
                    page_token,
                    resource.value,
                    service,
                    effective_limit,
                )
                if page is None:
                    raise _BlockedMonitoring
                params["page_token"] = page_token
        elif any(value is not None for value in (window_minutes, limit, page_token)):
            raise _BlockedMonitoring
        return params

    def _validate_payload(
        self,
        resource: MonitoringResource,
        payload: object,
        params: dict[str, str],
    ) -> None:
        self._validate_json_shape(payload, depth=1, item_count=[0])
        if not isinstance(payload, dict):
            raise _FailedMonitoring
        allowed: dict[MonitoringResource, set[str]] = {
            MonitoringResource.HEALTH: {"service", "status", "checked_at"},
            MonitoringResource.ERROR_RATE: {"service", "window_minutes", "error_rate"},
            MonitoringResource.DEPLOYS: {"service", "items", "next_page_token"},
            MonitoringResource.DEPENDENCIES: {"service", "items", "next_page_token"},
            MonitoringResource.DEAD_END: {"service", "signal", "detail"},
        }
        required: dict[MonitoringResource, set[str]] = {
            MonitoringResource.HEALTH: {"service", "status"},
            MonitoringResource.ERROR_RATE: {"service", "window_minutes", "error_rate"},
            MonitoringResource.DEPLOYS: {"service", "items"},
            MonitoringResource.DEPENDENCIES: {"service", "items"},
            MonitoringResource.DEAD_END: {"service", "signal"},
        }
        if set(payload) - allowed[resource] or not required[resource] <= set(payload):
            if any(str(key).endswith(("_url", "_uri")) for key in payload):
                raise _BlockedMonitoring
            raise _FailedMonitoring
        if payload.get("service") != _SERVICE:
            raise _FailedMonitoring
        if "next_page_token" in payload:
            token = payload["next_page_token"]
            current_page = 1
            if "page_token" in params:
                parsed_page = validate_page_token(
                    params["page_token"],
                    resource.value,
                    _SERVICE,
                    int(params["limit"]),
                )
                if parsed_page is None:
                    raise _FailedMonitoring
                current_page = parsed_page
            expected = build_page_token(
                resource.value,
                _SERVICE,
                current_page + 1,
                int(params["limit"]),
            )
            if not isinstance(token, str) or token != expected:
                raise _FailedMonitoring
        if resource is MonitoringResource.HEALTH and not isinstance(payload.get("status"), str):
            raise _FailedMonitoring
        if resource is MonitoringResource.ERROR_RATE:
            rate = payload.get("error_rate")
            if (
                type(rate) not in {int, float}
                or isinstance(rate, bool)
                or not 0 <= rate <= 1
                or payload.get("window_minutes") != int(params["window_minutes"])
            ):
                raise _FailedMonitoring
        if resource in _PAGED:
            items = payload.get("items")
            if (
                not isinstance(items, list)
                or len(items) > int(params["limit"])
                or not all(isinstance(item, dict) for item in items)
            ):
                raise _FailedMonitoring
        if resource is MonitoringResource.DEAD_END and not isinstance(payload.get("signal"), str):
            raise _FailedMonitoring

    def _validate_json_shape(
        self,
        value: object,
        *,
        depth: int,
        item_count: list[int],
    ) -> None:
        if depth > self._max_json_depth:
            raise _FailedMonitoring
        item_count[0] += 1
        if item_count[0] > 1_000:
            raise _FailedMonitoring
        if isinstance(value, dict):
            for key, item in value.items():
                if not isinstance(key, str) or len(key) > 100 or "\x00" in key:
                    raise _FailedMonitoring
                self._validate_json_shape(item, depth=depth + 1, item_count=item_count)
        elif isinstance(value, list):
            if len(value) > 100:
                raise _FailedMonitoring
            for item in value:
                self._validate_json_shape(item, depth=depth + 1, item_count=item_count)
        elif isinstance(value, str):
            if len(value) > 2_000 or "\x00" in value:
                raise _FailedMonitoring
        elif isinstance(value, bool) or value is None:
            return
        elif isinstance(value, (int, float)):
            if isinstance(value, float) and not math.isfinite(value):
                raise _FailedMonitoring
            if abs(value) > 1_000_000_000_000:
                raise _FailedMonitoring
        else:
            raise _FailedMonitoring

    @staticmethod
    def _unique_object(pairs: list[tuple[str, object]]) -> dict[str, object]:
        result: dict[str, object] = {}
        for key, value in pairs:
            if key in result:
                raise ValueError("duplicate JSON key")
            result[key] = value
        return result

    @staticmethod
    def _reject_json_constant(_value: str) -> object:
        raise ValueError("non-finite JSON number")

    @staticmethod
    def _validate_origin(value: str) -> str:
        if not isinstance(value, str) or len(value) > 64 or "\x00" in value:
            raise ValueError("monitoring origin must use literal loopback")
        try:
            parsed = urlsplit(value)
            port = parsed.port
        except ValueError as exc:
            raise ValueError("monitoring origin must use literal loopback") from exc
        expected_netloc = f"127.0.0.1:{port}" if port is not None else ""
        if (
            parsed.scheme != "http"
            or parsed.hostname != "127.0.0.1"
            or parsed.netloc != expected_netloc
            or port is None
            or not 1 <= port <= 65_535
            or parsed.path not in {"", "/"}
            or parsed.query
            or parsed.fragment
            or parsed.username is not None
            or parsed.password is not None
        ):
            raise ValueError("monitoring origin must use literal loopback")
        return f"http://127.0.0.1:{port}"

    @staticmethod
    def _result(
        resource: MonitoringResource | None,
        status: SourceStatus,
        content: str,
    ) -> SourceResult:
        name = resource.value if resource is not None else "invalid"
        digest = hashlib.sha256(content.encode()).hexdigest() if content else _EMPTY_DIGEST
        return SourceResult(
            source_family=SourceFamily.MONITORING,
            source_id=f"monitoring:{name}",
            status=status,
            content=content,
            content_sha256=digest,
            allowed_resources=(
                _FOLLOW_UP_RESOURCES.get(resource, ()) if status is SourceStatus.OK else ()
            ),
        )


def create_monitoring_tool(client: MonitoringClient) -> StructuredTool:
    """Expose the client as one strict typed tool with a SourceResult artifact."""

    from langchain_core.tools import StructuredTool
    from pydantic import BaseModel, ConfigDict, Field

    class _MonitoringInput(BaseModel):
        model_config = ConfigDict(extra="forbid")
        resource: MonitoringResource
        window_minutes: int | None = Field(default=None, ge=1, le=60)
        limit: int | None = Field(default=None, ge=1, le=10)
        page_token: str | None = Field(default=None, max_length=80)

    def fetch_monitoring(
        resource: MonitoringResource,
        window_minutes: int | None = None,
        limit: int | None = None,
        page_token: str | None = None,
    ) -> tuple[str, SourceResult]:
        result = client.get(
            resource,
            window_minutes=window_minutes,
            limit=limit,
            page_token=page_token,
        )
        visible = result.content
        if not visible:
            visible = json.dumps(
                {"source_id": result.source_id, "status": result.status.value},
                sort_keys=True,
                separators=(",", ":"),
            )
        return visible, result

    return StructuredTool(
        name="get_monitoring",
        description=(
            "GET one allowlisted synthetic checkout monitoring resource. "
            "No arbitrary URL, method, headers, or origin is accepted."
        ),
        func=fetch_monitoring,
        args_schema=_MonitoringInput,
        response_format="content_and_artifact",
    )

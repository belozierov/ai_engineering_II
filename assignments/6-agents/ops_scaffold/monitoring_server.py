"""Deterministic, context-managed loopback monitoring fixture."""

from __future__ import annotations

import gzip
import hashlib
import json
import threading
import time
from collections.abc import Iterator, Mapping
from contextlib import contextmanager
from dataclasses import dataclass
from enum import StrEnum
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from socketserver import TCPServer
from typing import Any
from urllib.parse import parse_qs, urlsplit

_MAX_FIXTURE_BYTES = 131_072
_SERVICE = "checkout-service"
_ROUTES = frozenset(
    {
        "/v1/health",
        "/v1/error-rate",
        "/v1/deploys",
        "/v1/dependencies",
        "/v1/dead-end",
    }
)


class MonitoringFixtureError(ValueError):
    """The deterministic monitoring fixture is missing or malformed."""


class MonitoringBehavior(StrEnum):
    NORMAL = "normal"
    DELAY = "delay"
    SLOW_STREAM = "slow_stream"
    REDIRECT = "redirect"
    MALFORMED_FRAMING = "malformed_framing"
    MALFORMED_JSON = "malformed_json"
    WRONG_CONTENT_TYPE = "wrong_content_type"
    DEEP_JSON = "deep_json"
    GZIP_OVERSIZE = "gzip_oversize"
    DECODED_OVERSIZE = "decoded_oversize"
    ARBITRARY_PAGINATION_URL = "arbitrary_pagination_url"


def load_monitoring_fixture(path: Path) -> dict[str, Any]:
    """Load a bounded strict JSON fixture at explicit runtime."""

    fixture_path = Path(path)
    try:
        raw = fixture_path.read_bytes()
    except OSError as exc:
        raise MonitoringFixtureError("monitoring fixture is unavailable") from exc
    if len(raw) > _MAX_FIXTURE_BYTES:
        raise MonitoringFixtureError("monitoring fixture exceeds the size limit")
    try:
        value = json.loads(raw.decode("utf-8"))
    except (UnicodeError, json.JSONDecodeError, RecursionError) as exc:
        raise MonitoringFixtureError("monitoring fixture is not valid UTF-8 JSON") from exc
    _validate_fixture(value)
    return value


def build_page_token(resource: str, service: str, page: int, limit: int) -> str:
    """Build a deterministic, query-bound fixture token (not an arbitrary URL)."""

    payload = f"ops-copilot-monitoring-v1|{resource}|{service}|{page}|{limit}"
    digest = hashlib.sha256(payload.encode()).hexdigest()[:16]
    return f"{resource}.p{page}.{digest}"


def validate_page_token(token: str, resource: str, service: str, limit: int) -> int | None:
    """Return a valid page number only for an exact resource-bound token."""

    if (
        not isinstance(token, str)
        or len(token) > 80
        or "/" in token
        or ":" in token
        or token.count(".") != 2
    ):
        return None
    prefix, page_part, _digest = token.split(".")
    if prefix != resource or not page_part.startswith("p") or not page_part[1:].isdigit():
        return None
    page = int(page_part[1:])
    if not 2 <= page <= 10 or token != build_page_token(resource, service, page, limit):
        return None
    return page


@dataclass(slots=True)
class RunningMonitoringServer:
    """Public handle for a running loopback fixture."""

    base_url: str
    _server: ThreadingHTTPServer

    @property
    def request_count(self) -> int:
        return int(getattr(self._server, "request_count", 0))

    @property
    def redirect_target_count(self) -> int:
        return int(getattr(self._server, "redirect_target_count", 0))


class _FixtureServer(ThreadingHTTPServer):
    daemon_threads = True
    block_on_close = False
    allow_reuse_address = False

    def __init__(
        self,
        fixture: Mapping[str, Any],
        behavior: MonitoringBehavior,
    ) -> None:
        self.fixture = fixture
        self.behavior = behavior
        self.request_count = 0
        self.redirect_target_count = 0
        self.state_lock = threading.Lock()
        super().__init__(("127.0.0.1", 0), _MonitoringHandler)

    def server_bind(self) -> None:
        """Bind without HTTPServer's reverse-DNS lookup of literal loopback."""

        TCPServer.server_bind(self)
        self.server_name, self.server_port = self.server_address[:2]


class _MonitoringHandler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.0"
    server: _FixtureServer

    def log_message(self, _format: str, *_args: object) -> None:
        return

    def do_POST(self) -> None:
        self._count_request()
        self._json_response(HTTPStatus.METHOD_NOT_ALLOWED, {"error": "method_not_allowed"})

    def do_PUT(self) -> None:
        self.do_POST()

    def do_DELETE(self) -> None:
        self.do_POST()

    def do_PATCH(self) -> None:
        self.do_POST()

    def do_HEAD(self) -> None:
        self.do_POST()

    def do_OPTIONS(self) -> None:
        self.do_POST()

    def do_GET(self) -> None:
        self._count_request()
        if len(self.path) > 512 or "\x00" in self.path:
            self._json_response(HTTPStatus.BAD_REQUEST, {"error": "invalid_request_target"})
            return
        parsed = urlsplit(self.path)
        if parsed.scheme or parsed.netloc:
            self._json_response(HTTPStatus.NOT_FOUND, {"error": "route_not_found"})
            return
        if parsed.path == "/v1/redirect-target":
            with self.server.state_lock:
                self.server.redirect_target_count += 1
            self._json_response(HTTPStatus.OK, {"unexpected": True})
            return
        if parsed.path not in _ROUTES:
            self._json_response(HTTPStatus.NOT_FOUND, {"error": "route_not_found"})
            return

        if self._apply_hostile_behavior():
            return

        try:
            query = parse_qs(
                parsed.query,
                strict_parsing=True,
                keep_blank_values=True,
                max_num_fields=8,
            )
        except ValueError:
            self._json_response(HTTPStatus.BAD_REQUEST, {"error": "invalid_query"})
            return
        payload = self._route_payload(parsed.path, query)
        if payload is None:
            self._json_response(HTTPStatus.BAD_REQUEST, {"error": "invalid_query"})
            return
        self._json_response(HTTPStatus.OK, payload)

    def _count_request(self) -> None:
        with self.server.state_lock:
            self.server.request_count += 1

    def _apply_hostile_behavior(self) -> bool:
        behavior = self.server.behavior
        if behavior is MonitoringBehavior.NORMAL:
            return False
        if behavior is MonitoringBehavior.DELAY:
            time.sleep(0.25)
            self._json_response(HTTPStatus.OK, {"status": "late"})
        elif behavior is MonitoringBehavior.SLOW_STREAM:
            body = b'{"status":"slow"}'
            self.send_response(HTTPStatus.OK)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Connection", "close")
            self.end_headers()
            self.close_connection = True
            try:
                self.wfile.write(body[:2])
                self.wfile.flush()
                time.sleep(0.25)
                self.wfile.write(body[2:])
            except (BrokenPipeError, ConnectionResetError):
                pass
        elif behavior is MonitoringBehavior.REDIRECT:
            self.send_response(HTTPStatus.FOUND)
            self.send_header("Location", "/v1/redirect-target")
            self.send_header("Content-Length", "0")
            self.send_header("Connection", "close")
            self.end_headers()
            self.close_connection = True
        elif behavior is MonitoringBehavior.MALFORMED_FRAMING:
            self.send_response(HTTPStatus.OK)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", "100")
            self.send_header("Connection", "close")
            self.end_headers()
            self.wfile.write(b"{}")
            self.wfile.flush()
            self.close_connection = True
        elif behavior is MonitoringBehavior.MALFORMED_JSON:
            self._raw_response(b"{not-json", content_type="application/json")
        elif behavior is MonitoringBehavior.WRONG_CONTENT_TYPE:
            self._raw_response(b'{"status":"wrong-type"}', content_type="text/plain")
        elif behavior is MonitoringBehavior.DEEP_JSON:
            value: object = "leaf"
            for _ in range(12):
                value = {"nested": value}
            self._json_response(HTTPStatus.OK, value)
        elif behavior is MonitoringBehavior.GZIP_OVERSIZE:
            pseudo_random = b"".join(
                hashlib.sha256(str(index).encode()).digest() for index in range(128)
            )
            self._raw_response(
                gzip.compress(pseudo_random, mtime=0),
                content_type="application/json",
                content_encoding="gzip",
            )
        elif behavior is MonitoringBehavior.DECODED_OVERSIZE:
            body = json.dumps({"padding": "x" * 3_000}).encode()
            self._raw_response(
                gzip.compress(body, mtime=0),
                content_type="application/json",
                content_encoding="gzip",
            )
        elif behavior is MonitoringBehavior.ARBITRARY_PAGINATION_URL:
            self._json_response(
                HTTPStatus.OK,
                {
                    "service": _SERVICE,
                    "items": [],
                    "next_page_url": "http://127.0.0.1:1/admin",
                },
            )
        else:
            self._json_response(HTTPStatus.INTERNAL_SERVER_ERROR, {"error": "fixture_error"})
        return True

    def _route_payload(
        self,
        route: str,
        query: Mapping[str, list[str]],
    ) -> dict[str, Any] | None:
        if any(len(values) != 1 for values in query.values()):
            return None
        service = query.get("service", [_SERVICE])[0]
        if service != _SERVICE:
            return None

        if route in {"/v1/health", "/v1/dead-end"}:
            if set(query) - {"service"}:
                return None
            key = "health" if route.endswith("health") else "dead_end"
            return dict(self.server.fixture[key])

        if route == "/v1/error-rate":
            if set(query) - {"service", "window_minutes"}:
                return None
            window = query.get("window_minutes", ["5"])[0]
            rates = self.server.fixture["error_rates"]
            if window not in rates:
                return None
            return {
                "service": _SERVICE,
                "window_minutes": int(window),
                "error_rate": rates[window],
            }

        resource = "deploys" if route.endswith("deploys") else "dependencies"
        if set(query) - {"service", "limit", "page_token"}:
            return None
        limit_raw = query.get("limit", ["2"])[0]
        if not limit_raw.isascii() or not limit_raw.isdecimal():
            return None
        limit = int(limit_raw)
        if not 1 <= limit <= 10:
            return None
        token = query.get("page_token", [None])[0]
        page = 1 if token is None else validate_page_token(token, resource, service, limit)
        if page is None:
            return None
        records = list(self.server.fixture[resource])
        start = (page - 1) * limit
        items = records[start : start + limit]
        response: dict[str, Any] = {"service": service, "items": items}
        if start + limit < len(records):
            response["next_page_token"] = build_page_token(resource, service, page + 1, limit)
        return response

    def _json_response(self, status: HTTPStatus, payload: object) -> None:
        body = json.dumps(
            payload,
            ensure_ascii=True,
            sort_keys=True,
            separators=(",", ":"),
        ).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("Connection", "close")
        self.end_headers()
        self.close_connection = True
        try:
            self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError):
            pass

    def _raw_response(
        self,
        body: bytes,
        *,
        content_type: str,
        content_encoding: str | None = None,
    ) -> None:
        self.send_response(HTTPStatus.OK)
        self.send_header("Content-Type", content_type)
        if content_encoding is not None:
            self.send_header("Content-Encoding", content_encoding)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Connection", "close")
        self.end_headers()
        self.close_connection = True
        try:
            self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError):
            pass


@contextmanager
def monitoring_server(
    fixture: Mapping[str, Any],
    *,
    behavior: MonitoringBehavior = MonitoringBehavior.NORMAL,
) -> Iterator[RunningMonitoringServer]:
    """Run one scenario-local server bound exactly to ``127.0.0.1:0``."""

    _validate_fixture(fixture)
    if not isinstance(behavior, MonitoringBehavior):
        raise MonitoringFixtureError("monitoring behavior is unsupported")
    server = _FixtureServer(fixture, behavior)
    host, port = server.server_address
    if host != "127.0.0.1":
        server.server_close()
        raise MonitoringFixtureError("monitoring fixture did not bind literal loopback")
    thread = threading.Thread(
        target=server.serve_forever,
        kwargs={"poll_interval": 0.01},
        daemon=True,
    )
    thread.start()
    try:
        yield RunningMonitoringServer(f"http://127.0.0.1:{port}", server)
    finally:
        server.shutdown()
        server.server_close()
        thread.join(timeout=2)


def _validate_fixture(value: object) -> None:
    if not isinstance(value, Mapping):
        raise MonitoringFixtureError("monitoring fixture must be an object")
    required = {
        "schema_version",
        "synthetic",
        "service",
        "health",
        "error_rates",
        "deploys",
        "dependencies",
        "dead_end",
    }
    if set(value) != required:
        raise MonitoringFixtureError("monitoring fixture fields are invalid")
    if value["schema_version"] != 1 or value["synthetic"] is not True:
        raise MonitoringFixtureError("monitoring fixture schema is unsupported")
    if value["service"] != _SERVICE:
        raise MonitoringFixtureError("monitoring fixture service is unsupported")
    if not isinstance(value["health"], Mapping) or not isinstance(value["dead_end"], Mapping):
        raise MonitoringFixtureError("monitoring fixture singleton resources are invalid")
    rates = value["error_rates"]
    if (
        not isinstance(rates, Mapping)
        or not rates
        or any(
            not isinstance(key, str)
            or not key.isdecimal()
            or not isinstance(rate, (int, float))
            or isinstance(rate, bool)
            or not 0 <= rate <= 1
            for key, rate in rates.items()
        )
    ):
        raise MonitoringFixtureError("monitoring error rates are invalid")
    for key in ("deploys", "dependencies"):
        records = value[key]
        if (
            not isinstance(records, list)
            or not 1 <= len(records) <= 50
            or not all(isinstance(item, Mapping) for item in records)
        ):
            raise MonitoringFixtureError(f"monitoring {key} records are invalid")

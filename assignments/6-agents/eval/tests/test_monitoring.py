from __future__ import annotations

import json
import urllib.error
import urllib.request
from pathlib import Path

import pytest

from ops_scaffold.contracts import SourceStatus
from ops_scaffold.monitoring_server import (
    MonitoringBehavior,
    load_monitoring_fixture,
    monitoring_server,
)
from ops_scaffold.tools.monitoring import (
    MonitoringClient,
    MonitoringResource,
    create_monitoring_tool,
)

PROJECT_ROOT = Path(__file__).resolve().parents[2]
FIXTURE_PATH = PROJECT_ROOT / "data" / "monitoring" / "scenarios.json"


def test_real_monitoring_server_serves_every_fixed_resource_and_pagination() -> None:
    fixture = load_monitoring_fixture(FIXTURE_PATH)

    with monitoring_server(fixture) as server:
        client = MonitoringClient(server.base_url)
        health = client.get(MonitoringResource.HEALTH)
        errors = client.get(MonitoringResource.ERROR_RATE, window_minutes=10)
        deploys = client.get(MonitoringResource.DEPLOYS, limit=2)
        dependencies = client.get(MonitoringResource.DEPENDENCIES, limit=1)
        dead_end = client.get(MonitoringResource.DEAD_END)

        first_page = json.loads(dependencies.content)
        second_page = client.get(
            MonitoringResource.DEPENDENCIES,
            limit=1,
            page_token=first_page["next_page_token"],
        )

    assert all(
        result.status is SourceStatus.OK
        for result in (health, errors, deploys, dependencies, second_page, dead_end)
    )
    assert json.loads(health.content)["status"] == "degraded"
    assert json.loads(errors.content)["error_rate"] == 0.184
    assert json.loads(deploys.content)["items"][0]["deploy_id"] == "deploy-synthetic-042"
    assert first_page["items"][0]["dependency"] == "tax-service"
    assert json.loads(second_page.content)["items"][0]["dependency"] == "inventory-service"
    assert json.loads(dead_end.content)["signal"] == "no_matching_timeseries"


@pytest.mark.parametrize(
    ("origin", "message"),
    [
        ("http://localhost:1234", "literal loopback"),
        ("http://0.0.0.0:1234", "literal loopback"),
        ("https://127.0.0.1:1234", "literal loopback"),
        ("http://test_user@example.com@127.0.0.1:1234", "literal loopback"),
        ("http://127.0.0.1:1234/admin", "literal loopback"),
    ],
)
def test_monitoring_client_accepts_only_literal_loopback_origin(
    origin: str,
    message: str,
) -> None:
    with pytest.raises(ValueError, match=message):
        MonitoringClient(origin)


def test_monitoring_client_ignores_environment_proxies(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    fixture = load_monitoring_fixture(FIXTURE_PATH)
    monkeypatch.setenv("HTTP_PROXY", "http://proxy.test.invalid:9")
    monkeypatch.setenv("HTTPS_PROXY", "http://proxy.test.invalid:9")
    monkeypatch.setenv("ALL_PROXY", "http://proxy.test.invalid:9")
    monkeypatch.setenv("NO_PROXY", "")

    with monitoring_server(fixture) as server:
        result = MonitoringClient(server.base_url).get(MonitoringResource.HEALTH)

    assert result.status is SourceStatus.OK


@pytest.mark.parametrize(
    "kwargs",
    [
        {"resource": "/admin"},
        {"resource": MonitoringResource.ERROR_RATE, "service": "../other"},
        {"resource": MonitoringResource.ERROR_RATE, "window_minutes": 0},
        {"resource": MonitoringResource.DEPLOYS, "limit": 11},
        {
            "resource": MonitoringResource.DEPENDENCIES,
            "page_token": "dependencies.p2.mutated",
        },
        {
            "resource": MonitoringResource.DEPENDENCIES,
            "page_token": "http://127.0.0.1:1/admin",
        },
    ],
)
def test_monitoring_client_blocks_routes_params_and_pagination_before_network(
    kwargs: dict[str, object],
) -> None:
    fixture = load_monitoring_fixture(FIXTURE_PATH)

    with monitoring_server(fixture) as server:
        before = server.request_count
        result = MonitoringClient(server.base_url).get(**kwargs)  # type: ignore[arg-type]
        after = server.request_count

    assert result.status is SourceStatus.BLOCKED
    assert result.content == ""
    assert after == before


def test_monitoring_server_rejects_non_get_and_unknown_routes() -> None:
    fixture = load_monitoring_fixture(FIXTURE_PATH)

    with monitoring_server(fixture) as server:
        request = urllib.request.Request(  # noqa: S310 - literal fixture loopback
            f"{server.base_url}/v1/health",
            data=b"{}",
            method="POST",
        )
        with pytest.raises(urllib.error.HTTPError) as post_error:
            urllib.request.urlopen(request, timeout=1)  # noqa: S310
        with pytest.raises(urllib.error.HTTPError) as route_error:
            urllib.request.urlopen(f"{server.base_url}/v1/admin", timeout=1)  # noqa: S310

    assert post_error.value.code == 405
    assert route_error.value.code == 404


def test_monitoring_client_does_not_follow_redirects() -> None:
    fixture = load_monitoring_fixture(FIXTURE_PATH)

    with monitoring_server(fixture, behavior=MonitoringBehavior.REDIRECT) as server:
        result = MonitoringClient(server.base_url).get(MonitoringResource.HEALTH)
        target_requests = server.redirect_target_count

    assert result.status is SourceStatus.BLOCKED
    assert result.content == ""
    assert target_requests == 0


@pytest.mark.parametrize(
    ("behavior", "expected_status"),
    [
        (MonitoringBehavior.DELAY, SourceStatus.FAILED),
        (MonitoringBehavior.SLOW_STREAM, SourceStatus.FAILED),
        (MonitoringBehavior.MALFORMED_FRAMING, SourceStatus.FAILED),
        (MonitoringBehavior.MALFORMED_JSON, SourceStatus.FAILED),
        (MonitoringBehavior.WRONG_CONTENT_TYPE, SourceStatus.FAILED),
        (MonitoringBehavior.DEEP_JSON, SourceStatus.FAILED),
        (MonitoringBehavior.GZIP_OVERSIZE, SourceStatus.FAILED),
        (MonitoringBehavior.DECODED_OVERSIZE, SourceStatus.FAILED),
        (MonitoringBehavior.ARBITRARY_PAGINATION_URL, SourceStatus.BLOCKED),
    ],
)
def test_monitoring_client_bounds_hostile_real_http_responses(
    behavior: MonitoringBehavior,
    expected_status: SourceStatus,
) -> None:
    fixture = load_monitoring_fixture(FIXTURE_PATH)

    with monitoring_server(fixture, behavior=behavior) as server:
        client = MonitoringClient(
            server.base_url,
            timeout_seconds=0.1,
            max_wire_bytes=512,
            max_decoded_bytes=1_024,
            max_json_depth=6,
        )
        result = client.get(MonitoringResource.HEALTH)

    assert result.status is expected_status
    assert result.content == ""
    assert len(result.source_id) <= 128


def test_monitoring_results_are_deterministic_across_server_instances() -> None:
    fixture = load_monitoring_fixture(FIXTURE_PATH)
    results = []

    for _ in range(2):
        with monitoring_server(fixture) as server:
            results.append(
                MonitoringClient(server.base_url).get(
                    MonitoringResource.DEPLOYS,
                    limit=2,
                )
            )

    assert results[0].content == results[1].content
    assert results[0].content_sha256 == results[1].content_sha256
    assert results[0].source_id == results[1].source_id


def test_monitoring_tool_is_typed_narrow_and_exposes_source_artifact() -> None:
    fixture = load_monitoring_fixture(FIXTURE_PATH)

    with monitoring_server(fixture) as server:
        tool = create_monitoring_tool(MonitoringClient(server.base_url))
        response = tool.func(resource=MonitoringResource.HEALTH)

    schema = tool.args_schema.model_json_schema()
    assert schema["additionalProperties"] is False
    assert set(schema["properties"]) == {
        "resource",
        "window_minutes",
        "limit",
        "page_token",
    }
    assert {"url", "method", "headers", "origin"}.isdisjoint(schema["properties"])
    assert isinstance(response, tuple)
    content, artifact = response
    assert json.loads(content)["status"] == "degraded"
    assert artifact.status is SourceStatus.OK

from __future__ import annotations

import os
import subprocess
import sys
import tomllib
from pathlib import Path

import pytest

PROJECT_ROOT = Path(__file__).resolve().parents[2]


def test_scaffold_import_has_no_runtime_side_effects(
    tmp_path: Path,
) -> None:
    module_names = (
        "ops_scaffold",
        "ops_scaffold.bootstrap",
        "ops_scaffold.config",
        "ops_scaffold.contracts",
        "ops_scaffold.evidence",
        "ops_scaffold.events",
        "ops_scaffold.middleware",
        "ops_scaffold.middleware.observability",
        "ops_scaffold.middleware.planning_context",
        "ops_scaffold.sandbox",
        "ops_scaffold.procedures",
        "ops_scaffold.runner",
        "ops_scaffold.monitoring_server",
        "ops_scaffold.runbooks",
        "ops_scaffold.scoping",
        "ops_scaffold.tools.monitoring",
        "ops_scaffold.tools.runbooks",
    )
    script = f"""
import importlib
import os
import socket
import sys
from pathlib import Path

sys.path.insert(0, {str(PROJECT_ROOT)!r})

def blocked(*_args, **_kwargs):
    raise AssertionError("import attempted runtime initialization")

socket.create_connection = blocked
socket.socket.connect = blocked
Path.mkdir = blocked
Path.touch = blocked
Path.write_text = blocked
Path.write_bytes = blocked
os.makedirs = blocked

for module_name in {module_names!r}:
    importlib.import_module(module_name)
"""
    environment = dict(os.environ)
    environment.pop("OPENROUTER_API_KEY", None)
    environment["OPS_DATA_DIR"] = str(tmp_path / "missing-index")
    completed = subprocess.run(  # noqa: S603 - fixed interpreter and test script
        [sys.executable, "-I", "-c", script],
        cwd=tmp_path,
        env=environment,
        capture_output=True,
        text=True,
        timeout=30,
        check=False,
    )
    assert completed.returncode == 0, completed.stderr


def test_package_selector_accepts_only_course_packages() -> None:
    from ops_scaffold.config import ConfigurationError, select_package

    assert select_package({}) == "ops_copilot"
    if (PROJECT_ROOT / "reference_solution").is_dir():
        assert select_package({"OPS_PKG": "reference_solution"}) == "reference_solution"
    else:
        with pytest.raises(ConfigurationError, match="OPS_PKG"):
            select_package({"OPS_PKG": "reference_solution"})

    with pytest.raises(ConfigurationError, match="OPS_PKG"):
        select_package({"OPS_PKG": "arbitrary.module"})


def test_evaluators_and_interfaces_reuse_canonical_config_contracts() -> None:
    from eval import components, live, report, scenarios, structural
    from ops_scaffold import application, runner
    from ops_scaffold.config import (
        ALLOWED_PACKAGES,
        DEFAULT_AGENT_MODEL,
        DEFAULT_JUDGE_MODEL,
        DEFAULT_SUMMARIZER_MODEL,
        OPENROUTER_BASE_URL,
    )

    for module in (components, report, scenarios, structural):
        assert module.ALLOWED_PACKAGES == ALLOWED_PACKAGES
    settings = live.LiveSettings(api_key="clearly-fake-test-key")
    assert settings.agent_model == DEFAULT_AGENT_MODEL
    assert settings.summary_model == DEFAULT_SUMMARIZER_MODEL
    assert settings.judge_model == DEFAULT_JUDGE_MODEL
    assert live.OPENROUTER_BASE_URL == OPENROUTER_BASE_URL
    assert application.validate_turn_input.__module__ == runner.validate_turn_input.__module__
    assert application.validate_turn_input.__module__ == "ops_scaffold.runner"


@pytest.mark.parametrize(
    ("name", "value"),
    [
        ("OPS_COMPACTION_TARGET_TOKENS", "-1"),
        ("OPS_COMPACTION_SOFT_TOKENS", "0"),
        ("OPS_HARD_INPUT_TOKENS", "not-a-number"),
        ("OPS_RESPONSE_RESERVE_TOKENS", "1000001"),
    ],
)
def test_settings_reject_invalid_budgets(name: str, value: str) -> None:
    from ops_scaffold.config import ConfigurationError, OpsSettings

    with pytest.raises(ConfigurationError) as exc_info:
        OpsSettings.from_env({name: value})

    assert name in str(exc_info.value)
    assert len(str(exc_info.value)) <= 160


def test_settings_reject_inconsistent_budget_order() -> None:
    from ops_scaffold.config import ConfigurationError, OpsSettings

    with pytest.raises(ConfigurationError, match="token budgets"):
        OpsSettings.from_env(
            {
                "OPS_COMPACTION_TARGET_TOKENS": "900",
                "OPS_COMPACTION_SOFT_TOKENS": "800",
                "OPS_HARD_INPUT_TOKENS": "1200",
                "OPS_RESPONSE_RESERVE_TOKENS": "100",
            }
        )


def test_settings_are_environment_driven_and_secret_safe() -> None:
    from pydantic import SecretStr

    from ops_scaffold.config import OpsSettings

    settings = OpsSettings.from_env(
        {
            "OPENROUTER_API_KEY": "clearly-fake-test-key",
            "OPS_AGENT_MODEL": "test/provider-agent",
            "OPS_SUMMARIZER_MODEL": "test/provider-summary",
            "OPS_JUDGE_MODEL": "test/provider-judge",
        }
    )

    assert settings.agent_model == "test/provider-agent"
    assert settings.summarizer_model == "test/provider-summary"
    assert settings.judge_model == "test/provider-judge"
    assert isinstance(settings.openrouter_api_key, SecretStr)
    assert settings.openrouter_api_key.get_secret_value() == "clearly-fake-test-key"
    assert "clearly-fake-test-key" not in repr(settings)


def test_runtime_context_requires_bounded_trusted_identifiers() -> None:
    from ops_scaffold.contracts import ContractError, RuntimeContext

    context = RuntimeContext.from_mapping(
        {
            "identity_id": "identity-test-1",
            "thread_id": "thread-test-1",
            "run_id": "run-test-1",
            "channel": "evaluator",
        }
    )
    assert context.identity_id == "identity-test-1"

    malformed = [
        {},
        {"identity_id": "../other", "thread_id": "thread-test-1", "run_id": "run-test-1"},
        {"identity_id": "identity-test-1", "thread_id": "", "run_id": "run-test-1"},
        {
            "identity_id": "identity-test-1",
            "thread_id": "thread-test-1",
            "run_id": "run-test-1",
            "raw_checkpoint_key": "forbidden",
        },
    ]
    for value in malformed:
        with pytest.raises(ContractError) as exc_info:
            RuntimeContext.from_mapping(value)
        assert len(str(exc_info.value)) <= 160


def test_events_reject_unknown_schema_versions() -> None:
    from ops_scaffold.contracts import (
        AppEvent,
        ContractError,
        EventStatus,
        EventType,
    )

    event = AppEvent(
        schema_version=1,
        event_type=EventType.TURN,
        run_id="run-test-1",
        status=EventStatus.COMPLETED,
    )
    assert event.schema_version == 1

    with pytest.raises(ContractError, match="event schema version"):
        AppEvent(
            schema_version=2,
            event_type=EventType.TURN,
            run_id="run-test-1",
            status=EventStatus.COMPLETED,
        )


def test_shared_contracts_construct_without_framework_objects() -> None:
    from ops_scaffold.contracts import (
        Evidence,
        EvidenceStatus,
        Procedure,
        ProvenanceRef,
        SourceFamily,
        SourceResult,
        SourceStatus,
        TrustLabel,
    )

    result = SourceResult(
        source_family=SourceFamily.REPOSITORY,
        source_id="checkout-log",
        status=SourceStatus.OK,
        content="synthetic checkout log",
        content_sha256="a" * 64,
    )
    provenance = ProvenanceRef(
        source_family=result.source_family,
        source_id=result.source_id,
        content_sha256=result.content_sha256,
    )
    evidence = Evidence(
        evidence_id="ev-test-1",
        identity_id="identity-test-1",
        run_id="run-test-1",
        provenance=provenance,
        status=EvidenceStatus.ISSUED,
        trust=TrustLabel.TRUSTED_DATA,
    )
    procedure = Procedure(
        procedure_id="proc-test-1",
        version=1,
        title="Synthetic checkout triage",
        steps=("Inspect synthetic logs.", "Compare synthetic deploy metadata."),
        provenance=(provenance,),
    )

    assert result.content == "synthetic checkout log"
    assert evidence.provenance == provenance
    assert procedure.steps[0] == "Inspect synthetic logs."


def test_agent_runtime_protocol_matches_runner_and_evaluator_methods() -> None:
    from ops_scaffold.contracts import AgentRuntime

    assert all(
        callable(getattr(AgentRuntime, method, None))
        for method in ("invoke", "stream", "get_state")
    )


def test_project_declares_compatible_framework_windows_and_pinned_dev_tools() -> None:
    with (PROJECT_ROOT / "pyproject.toml").open("rb") as project_file:
        project = tomllib.load(project_file)

    dependencies = set(project["project"]["dependencies"])
    assert "langchain>=1.3.9,<1.4" in dependencies
    assert "langgraph>=1.2.5,<1.3" in dependencies
    assert "langchain-core>=1.4,<1.5" in dependencies
    assert "qdrant-client>=1.15.1,<2" in dependencies
    assert not any(item.startswith("langchain-huggingface") for item in dependencies)
    assert not any(item.startswith("sentence-transformers") for item in dependencies)
    assert not any(item.startswith("chromadb") for item in dependencies)
    assert not any(item.startswith("langchain-chroma") for item in dependencies)
    assert not any(item.startswith("langchain-community") for item in dependencies)
    assert project["dependency-groups"]["dev"] == [
        "pytest==9.1.1",
        "ruff==0.15.22",
    ]


def test_lock_keeps_frameworks_in_windows_without_legacy_toolkits() -> None:
    with (PROJECT_ROOT / "uv.lock").open("rb") as lock_file:
        lock = tomllib.load(lock_file)

    versions = {item["name"]: item["version"] for item in lock["package"]}
    assert (1, 3, 9) <= _version_tuple(versions["langchain"]) < (1, 4, 0)
    assert (1, 2, 5) <= _version_tuple(versions["langgraph"]) < (1, 3, 0)
    assert (1, 4, 0) <= _version_tuple(versions["langchain-core"]) < (1, 5, 0)
    assert (1, 15, 1) <= _version_tuple(versions["qdrant-client"]) < (2, 0, 0)
    assert {
        "chromadb",
        "langchain-chroma",
        "langchain-community",
        "langchain-classic",
        "langchain-huggingface",
        "sentence-transformers",
    }.isdisjoint(versions)


def _version_tuple(value: str) -> tuple[int, ...]:
    return tuple(int(part) for part in value.split("."))

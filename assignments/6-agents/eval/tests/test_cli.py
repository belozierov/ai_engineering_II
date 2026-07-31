from __future__ import annotations

import builtins
import importlib
import io
import json
import os
import re
import socket
from pathlib import Path

import pytest

from ops_scaffold.contracts import RuntimeChannel, RuntimeContext

PROJECT_ROOT = Path(__file__).resolve().parents[2]
MODULE_ROOT = PROJECT_ROOT.parent
SENTINEL = "sentinel-secret-<script>\x1b[31m-clearly-fake-api-key"


class _FakeApplication:
    def __init__(self) -> None:
        self.identity_id = "identity-test-cli-owner"
        self.contexts: list[RuntimeContext] = []
        self._facts: dict[str, str] = {}
        self._run_number = 0

    def __enter__(self) -> _FakeApplication:
        return self

    def __exit__(self, *_args: object) -> None:
        return None

    def run_turn(
        self,
        thread_id: str,
        user_input: str,
        *,
        channel: RuntimeChannel,
        identity_id: str | None = None,
        on_event: object | None = None,
    ) -> object:
        from ops_scaffold import application as application_module

        self._run_number += 1
        effective_identity = self.identity_id if identity_id is None else identity_id
        context = application_module.RuntimeContext(
            identity_id=effective_identity,
            thread_id=thread_id,
            run_id=f"run-test-cli-{self._run_number}",
            channel=application_module.RuntimeChannel(channel.value),
        )
        self.contexts.append(context)
        if user_input == "remember":
            self._facts[effective_identity] = "synthetic cross-thread fact"
            answer = "Факт збережено."
        elif user_input == "markup":
            answer = "&lt;synthetic&gt; &amp;"
        else:
            answer = self._facts.get(effective_identity, "Фактів немає.")
        event = application_module.AppEvent(
            schema_version=application_module.EVENT_SCHEMA_VERSION,
            event_type=application_module.EventType.TURN,
            run_id=context.run_id,
            status=application_module.EventStatus.COMPLETED,
        )
        if callable(on_event):
            on_event(event)
        return application_module.PublicTurn(
            context=context,
            status=application_module.EventStatus.COMPLETED,
            events=(event,),
            answer=answer,
        )


def test_entrypoint_imports_have_no_runtime_or_key_side_effects(
    monkeypatch: pytest.MonkeyPatch,
    tmp_path: Path,
) -> None:
    def unexpected_side_effect(*_args: object, **_kwargs: object) -> None:
        raise AssertionError("entrypoint import attempted runtime initialization")

    original_import = builtins.__import__

    def without_optional_ui(name: str, *args: object, **kwargs: object) -> object:
        if name == "chainlit" or name.startswith("chainlit."):
            raise ImportError("optional dependency unavailable")
        return original_import(name, *args, **kwargs)

    monkeypatch.chdir(tmp_path)
    monkeypatch.setenv("OPENROUTER_API_KEY", SENTINEL)
    monkeypatch.setattr(builtins, "__import__", without_optional_ui)
    monkeypatch.setattr(socket, "create_connection", unexpected_side_effect)
    monkeypatch.setattr(socket.socket, "connect", unexpected_side_effect)
    monkeypatch.setattr(Path, "mkdir", unexpected_side_effect)
    monkeypatch.setattr(Path, "write_text", unexpected_side_effect)
    monkeypatch.setattr(Path, "write_bytes", unexpected_side_effect)
    monkeypatch.setattr(os, "makedirs", unexpected_side_effect)

    for module_name in ("ops_scaffold.application", "app", "chainlit_app"):
        importlib.import_module(module_name)

    assert tuple(tmp_path.iterdir()) == ()


def test_cli_reference_smoke_reuses_identity_across_two_logical_threads() -> None:
    from app import run_cli

    application = _FakeApplication()
    output = io.StringIO()

    exit_code = run_cli(
        thread_id="incident-a",
        input_stream=io.StringIO("remember\n/thread incident-b\nrecall\n/quit\n"),
        output_stream=output,
        application_factory=lambda: application,  # type: ignore[arg-type,return-value]
    )

    assert exit_code == 0
    assert [context.identity_id for context in application.contexts] == [
        application.identity_id,
        application.identity_id,
    ]
    assert [context.thread_id for context in application.contexts] == [
        "incident-a",
        "incident-b",
    ]
    assert "synthetic cross-thread fact" in output.getvalue()
    assert application.identity_id in output.getvalue()

    event_lines = [
        line.removeprefix("event=")
        for line in output.getvalue().splitlines()
        if line.startswith("event=")
    ]
    assert json.loads(event_lines[-1]) == {
        "event_type": "turn",
        "run_id": "run-test-cli-2",
        "schema_version": 1,
        "status": "completed",
    }


def test_cli_ignores_blank_input_lines_without_running_a_turn() -> None:
    from app import run_cli

    application = _FakeApplication()
    output = io.StringIO()

    exit_code = run_cli(
        thread_id="incident-blank",
        input_stream=io.StringIO("\n   \nremember\n/quit\n"),
        output_stream=output,
        application_factory=lambda: application,  # type: ignore[arg-type,return-value]
    )

    assert exit_code == 0
    assert len(application.contexts) == 1
    assert "status=failed" not in output.getvalue()
    assert "synthetic cross-thread fact" not in output.getvalue()


def test_cli_renders_the_public_answer_without_double_escaping() -> None:
    from app import run_cli

    output = io.StringIO()
    exit_code = run_cli(
        thread_id="incident-markup",
        input_stream=io.StringIO("markup\n/quit\n"),
        output_stream=output,
        application_factory=_FakeApplication,  # type: ignore[arg-type]
    )

    assert exit_code == 0
    assert "answer=&lt;synthetic&gt; &amp;" in output.getvalue()
    assert "&amp;lt;" not in output.getvalue()


def test_cli_renders_loading_terminal_and_safe_error_states() -> None:
    from app import render_cli_turn

    class _FailingApplication(_FakeApplication):
        def run_turn(self, *args: object, **kwargs: object) -> object:
            del args, kwargs
            raise RuntimeError(SENTINEL)

    output = io.StringIO()

    result = render_cli_turn(
        _FailingApplication(),
        thread_id="incident-error",
        user_input="trigger a bounded failure",
        output_stream=output,
    )

    rendered = output.getvalue()
    assert result is None
    assert "status=loading" in rendered
    assert "status=failed" in rendered
    assert "Помилка виконання прихована" in rendered
    assert SENTINEL not in rendered


@pytest.mark.parametrize(
    "thread_id",
    ["", " ", "../escape", "thread\x00id", "x" * 129, "decomposed-e\u0301"],
)
def test_cli_rejects_unbounded_or_noncanonical_thread_ids(thread_id: str) -> None:
    from ops_scaffold.application import validate_logical_thread_id

    with pytest.raises(ValueError, match="thread"):
        validate_logical_thread_id(thread_id)


def test_local_identity_is_random_persistent_private_and_secret_safe(tmp_path: Path) -> None:
    from ops_scaffold.application import LocalIdentityStore

    state_dir = tmp_path / "state"
    first = LocalIdentityStore(state_dir).load_or_create()
    second = LocalIdentityStore(state_dir).load_or_create()

    assert first.identity_id == second.identity_id
    assert first.scope_secret == second.scope_secret
    assert first.identity_id.startswith("identity-local-")
    assert len(first.scope_secret) == 32
    assert SENTINEL not in repr(first)
    assert os.stat(state_dir).st_mode & 0o077 == 0
    assert os.stat(state_dir / "identity.json").st_mode & 0o077 == 0


def test_local_identity_rejects_symlinks_and_insecure_artifacts(tmp_path: Path) -> None:
    from ops_scaffold.application import LocalIdentityStore

    real = tmp_path / "real"
    real.mkdir(mode=0o700)
    linked = tmp_path / "linked"
    linked.symlink_to(real, target_is_directory=True)
    with pytest.raises(ValueError, match="symlink"):
        LocalIdentityStore(linked).load_or_create()

    insecure = tmp_path / "insecure"
    insecure.mkdir(mode=0o755)
    with pytest.raises(ValueError, match="permissions"):
        LocalIdentityStore(insecure).load_or_create()


def test_readme_documents_clean_setup_six_todos_and_release_contract() -> None:
    readme = (PROJECT_ROOT / "README.md").read_text(encoding="utf-8")
    headings = re.findall(r"^### TODO [1-6]:", readme, flags=re.MULTILINE)

    assert len(headings) == 6
    assert len(set(headings)) == 6
    for required in (
        "Python 3.11+",
        "uv sync --frozen",
        "uv run --frozen python prepare_data.py --check",
        "uv run --frozen pytest",
        "uv run --frozen python eval.py",
        "uv run --frozen python eval.py --full",
        "uv run --frozen python eval.py --json",
        "OPENROUTER_API_KEY",
        "uv sync --extra ui --frozen",
        "uv run --frozen chainlit run chainlit_app.py",
        "Capability Ledger",
        "SummarizationMiddleware",
        "6–8 годин",  # noqa: RUF001 - verifies the required Ukrainian en dash.
        "шість SKIP",
        "синтетич",
        "загроз",
    ):
        assert required in readme
    assert "reference_solution" not in readme


def test_results_template_requests_student_reflection_and_manual_safety_analysis() -> None:
    results = (PROJECT_ROOT / "results.md").read_text(encoding="utf-8")

    for required in (
        "Результати: Ops Copilot v2",
        "TESTING_SCENARIOS.md",
        "uv run --frozen python eval.py",
        "uv run --frozen python eval.py --full",
        "Capability Ledger",
        "Incident trace",
        "Evidence & grounding",
        "Safety probes",
        "evidence_id",
        "source_id",
        "current-run evidence",
        "production-версії",
    ):
        assert required in results
    assert "reference_solution" not in results


def test_testing_scenarios_explain_manual_cli_trace_and_safety_probes() -> None:
    guide = (PROJECT_ROOT / "TESTING_SCENARIOS.md").read_text(encoding="utf-8")

    for required in (
        "Як читати CLI output",
        "Activity",
        "Plans observed this turn",
        "collected runbook evidence",
        "evidence=...",
        "Сценарій 1: повне incident investigation",
        "Сценарій 2: monitoring dead end",
        "Сценарій 3: no-answer",
        "Сценарій 4: indirect prompt injection",
        "Сценарій 5: stale evidence",
        "Сценарій 6: scope expansion",
        "два safety probes",
        "results.md",
    ):
        assert required in guide
    assert "reference_solution" not in guide


@pytest.mark.skipif(
    not (MODULE_ROOT / "agents-3.html").is_file(),
    reason="module lecture files are absent from the standalone student bundle",
)
def test_direct_module_seven_capstone_references_point_to_v2() -> None:
    paths = (
        MODULE_ROOT / "agents-3.html",
        MODULE_ROOT / "presenter_notes_3.md",
        MODULE_ROOT / "showcase-build-an-agent" / "README.md",
    )

    for path in paths:
        text = path.read_text(encoding="utf-8")
        assert "homework_v2" in text
        assert "Ops Copilot v2" in text
        assert "single-agent" in text
    showcase = paths[-1].read_text(encoding="utf-8")
    assert "`7. agents/homework/`" not in showcase

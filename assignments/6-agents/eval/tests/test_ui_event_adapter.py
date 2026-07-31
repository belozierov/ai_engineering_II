from __future__ import annotations

import asyncio
import builtins
import importlib
import io
import json
import runpy
import sys
import tempfile
import tomllib
import types
from pathlib import Path

import pytest

from ops_scaffold.contracts import (
    AppEvent,
    RuntimeChannel,
    RuntimeContext,
)

PROJECT_ROOT = Path(__file__).resolve().parents[2]
SENTINEL = "sentinel-secret-<script>\x1b[31m-clearly-fake-api-key"


def test_chainlit_config_is_local_only_and_disables_unused_surfaces() -> None:
    config = tomllib.loads((PROJECT_ROOT / ".chainlit" / "config.toml").read_text(encoding="utf-8"))

    assert "*" not in config["project"]["allow_origins"]
    assert config["features"]["unsafe_allow_html"] is False
    assert config["features"]["spontaneous_file_upload"]["enabled"] is False
    assert config["features"]["mcp"]["enabled"] is False
    assert config["UI"]["cot"] == "hidden"


class _SessionApplication:
    def __init__(self, identity_id: str = "identity-session-test-a") -> None:
        self.identity_id = identity_id
        self._run_number = 0
        self._facts: dict[str, str] = {}
        self.calls: list[RuntimeContext] = []
        self.enter_count = 0
        self.exit_count = 0

    def __enter__(self) -> _SessionApplication:
        self.enter_count += 1
        return self

    def __exit__(self, *_args: object) -> None:
        self.exit_count += 1

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

        assert identity_id is None
        self._run_number += 1
        context = application_module.RuntimeContext(
            identity_id=self.identity_id,
            thread_id=thread_id,
            run_id=f"run-test-chainlit-{self._run_number}",
            channel=application_module.RuntimeChannel(channel.value),
        )
        self.calls.append(context)
        if user_input == "remember":
            self._facts[self.identity_id] = "session A private fact"
            answer = "stored"
        else:
            answer = self._facts.get(self.identity_id, "no recall")
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


def _metadata_event() -> AppEvent:
    from ops_scaffold import application as application_module

    return application_module.AppEvent(
        schema_version=application_module.EVENT_SCHEMA_VERSION,
        event_type=application_module.EventType.MEMORY,
        run_id="run-test-event-adapter",
        status=application_module.EventStatus.COMPLETED,
        memory_level=application_module.MemoryLevel.FACT,
        count=1,
        artifact_id="memory-test-public",
    )


def test_chainlit_module_loads_when_optional_dependency_is_unavailable(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    original_import = builtins.__import__

    def without_chainlit(name: str, *args: object, **kwargs: object) -> object:
        if name == "chainlit" or name.startswith("chainlit."):
            raise ImportError("optional dependency unavailable")
        return original_import(name, *args, **kwargs)

    monkeypatch.setattr(builtins, "__import__", without_chainlit)

    namespace = runpy.run_path(str(PROJECT_ROOT / "chainlit_app.py"))

    assert namespace["CHAINLIT_AVAILABLE"] is False
    assert callable(namespace["create_unauthenticated_session"])
    assert callable(namespace["render_event"])


def test_chainlit_adapter_restores_same_origin_websocket_checks(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    import chainlit_app

    chainlit_app = importlib.reload(chainlit_app)

    engine = types.SimpleNamespace(cors_allowed_origins=[])
    server_module = types.ModuleType("chainlit.server")
    server_module.sio = types.SimpleNamespace(eio=engine)
    chainlit_module = types.ModuleType("chainlit")
    chainlit_module.__path__ = []  # type: ignore[attr-defined]
    monkeypatch.setitem(sys.modules, "chainlit", chainlit_module)
    monkeypatch.setitem(sys.modules, "chainlit.server", server_module)
    monkeypatch.setattr(chainlit_app, "cl", chainlit_module)

    chainlit_app._enforce_same_origin_websockets()

    assert engine.cors_allowed_origins is None


def test_cli_and_chainlit_share_the_exact_metadata_only_event_projection() -> None:
    from app import render_event as render_cli_event
    from chainlit_app import render_event as render_chainlit_event

    event = _metadata_event()
    cli = render_cli_event(event)
    ui = render_chainlit_event(event)

    assert cli == ui
    assert json.loads(cli) == {
        "artifact_id": "memory-test-public",
        "count": 1,
        "event_type": "memory",
        "memory_level": "fact",
        "run_id": "run-test-event-adapter",
        "schema_version": 1,
        "status": "completed",
    }
    assert SENTINEL not in cli


def test_event_adapters_reject_raw_hostile_payloads_and_oversized_events() -> None:
    from app import render_event as render_cli_event
    from chainlit_app import render_event as render_chainlit_event
    from ops_scaffold import application as application_module

    hostile = {
        "event_type": "source",
        "raw_source": SENTINEL * 20_000,
        "prompt": SENTINEL,
        "exception": SENTINEL,
        "status_text": "<script>alert(1)</script>",
        "Authorization": SENTINEL,
    }
    for adapter in (render_cli_event, render_chainlit_event):
        with pytest.raises(TypeError, match="AppEvent"):
            adapter(hostile)  # type: ignore[arg-type]

    with pytest.raises(ValueError, match="identifier"):
        application_module.AppEvent(
            schema_version=application_module.EVENT_SCHEMA_VERSION,
            event_type=application_module.EventType.TURN,
            run_id="r" * 129,
            status=application_module.EventStatus.FAILED,
        )


def test_public_answer_formatting_is_bounded_redacted_and_control_free() -> None:
    from ops_scaffold.application import safe_public_answer

    redaction_value = "clearly-fake-api-key-value"
    raw = f"<script>{redaction_value}</script>\x1b[31m" + ("x" * 20_000)
    rendered = safe_public_answer(raw, secret_values=(redaction_value,))

    assert redaction_value not in rendered
    assert "\x1b" not in rendered
    assert "<script>" not in rendered
    assert "[REDACTED]" in rendered
    assert len(rendered) <= 12_000


def test_chainlit_final_answer_escapes_citation_brackets_for_markdown() -> None:
    from chainlit_app import render_final_answer

    rendered = render_final_answer("Use [evidence:artifact-test-123].")

    assert rendered == "Фінальна відповідь:\n\n    Use [evidence:artifact-test-123]."


def test_two_unauthenticated_sessions_have_distinct_scopes_and_no_recall() -> None:
    from chainlit_app import create_unauthenticated_session

    first_application = _SessionApplication("identity-session-test-a")
    second_application = _SessionApplication("identity-session-test-b")
    first = create_unauthenticated_session(first_application)
    second = create_unauthenticated_session(second_application)

    assert first.identity_id != second.identity_id
    assert first.thread_id != second.thread_id
    assert first.run("remember").answer == "stored"
    assert second.run("recall").answer == "no recall"
    calls = [*first_application.calls, *second_application.calls]
    assert all(call.channel.value == "chainlit" for call in calls)
    assert {
        first_application.calls[0].identity_id,
        second_application.calls[0].identity_id,
    } == {first.identity_id, second.identity_id}
    first.close()
    second.close()
    assert first_application.exit_count == 1
    assert second_application.exit_count == 1


def test_chainlit_session_rejects_invalid_messages_without_forwarding() -> None:
    from chainlit_app import create_unauthenticated_session

    application = _SessionApplication()
    session = create_unauthenticated_session(application)

    for invalid in ("", " ", "bad\x00message", "x" * 32_769):
        with pytest.raises(ValueError, match="input"):
            session.run(invalid)
    assert application.calls == []
    session.close()


def test_chainlit_sessions_own_application_identity_and_idempotent_cleanup() -> None:
    from chainlit_app import start_unauthenticated_session

    applications: list[_SessionApplication] = []
    temporary_paths: list[Path] = []

    def application_factory(**kwargs: object) -> _SessionApplication:
        assert kwargs["ephemeral_identity"] is True
        assert Path(kwargs["state_dir"]).parent in temporary_paths
        application = _SessionApplication(f"identity-session-test-{len(applications) + 1}")
        applications.append(application)
        return application

    def temporary_factory(**kwargs: object) -> tempfile.TemporaryDirectory[str]:
        temporary = tempfile.TemporaryDirectory(**kwargs)
        temporary_paths.append(Path(temporary.name))
        return temporary

    first = start_unauthenticated_session(
        application_factory=application_factory,
        temporary_factory=temporary_factory,
    )
    second = start_unauthenticated_session(
        application_factory=application_factory,
        temporary_factory=temporary_factory,
    )

    assert first.identity_id == applications[0].identity_id
    assert second.identity_id == applications[1].identity_id
    assert first.identity_id != second.identity_id
    assert all(path.is_dir() for path in temporary_paths)
    first.close()
    first.close()
    second.close()

    assert [application.enter_count for application in applications] == [1, 1]
    assert [application.exit_count for application in applications] == [1, 1]
    assert not any(path.exists() for path in temporary_paths)
    with pytest.raises(RuntimeError, match="closed"):
        first.run("recall")


def test_chainlit_message_recovers_missing_session_after_server_restart(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    cl = pytest.importorskip("chainlit")
    from chainlit.chat_context import chat_context
    from chainlit.context import init_http_context

    import chainlit_app

    chainlit_app = importlib.reload(chainlit_app)

    application = _SessionApplication("identity-session-test-restored")

    def session_factory() -> chainlit_app.UnauthenticatedSession:
        return chainlit_app.create_unauthenticated_session(application)

    monkeypatch.setattr(chainlit_app, "start_unauthenticated_session", session_factory)
    restored_identity: list[str] = []

    async def exercise() -> None:
        init_http_context()
        chat_context.clear()
        cl.user_session.set("ops_copilot_session", None)

        await chainlit_app._on_message(types.SimpleNamespace(content="recall"))

        rendered = [message.content for message in chat_context.get()]
        assert any("Сесію відновлено" in content for content in rendered)
        assert any("Стан: completed" in content for content in rendered)
        assert any("Фінальна відповідь:\n\n    no recall" in content for content in rendered)
        restored = cl.user_session.get("ops_copilot_session")
        assert isinstance(restored, chainlit_app.UnauthenticatedSession)
        restored_identity.append(restored.identity_id)

    asyncio.run(exercise())

    assert len(application.calls) == 1
    assert application.calls[0].channel is RuntimeChannel.CHAINLIT
    assert restored_identity == [application.identity_id]


def test_chainlit_resume_starts_new_ephemeral_runtime_session(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    cl = pytest.importorskip("chainlit")
    from chainlit.chat_context import chat_context
    from chainlit.context import init_http_context

    import chainlit_app

    application = _SessionApplication("identity-session-test-resume")

    def session_factory() -> chainlit_app.UnauthenticatedSession:
        return chainlit_app.create_unauthenticated_session(application)

    monkeypatch.setattr(chainlit_app, "start_unauthenticated_session", session_factory)
    restored_identity: list[str] = []

    async def exercise() -> None:
        init_http_context()
        chat_context.clear()
        cl.user_session.set("ops_copilot_session", None)

        await chainlit_app._on_chat_resume({"id": "thread-test-stale-browser"})

        rendered = [message.content for message in chat_context.get()]
        assert any("Сесію відновлено" in content for content in rendered)
        restored = cl.user_session.get("ops_copilot_session")
        assert isinstance(restored, chainlit_app.UnauthenticatedSession)
        restored_identity.append(restored.identity_id)

    asyncio.run(exercise())

    assert restored_identity == [application.identity_id]
    assert application.calls == []


def test_chainlit_session_startup_failure_cleans_partial_resources() -> None:
    from chainlit_app import start_unauthenticated_session

    temporary_paths: list[Path] = []

    class _FailingApplication(_SessionApplication):
        def __init__(self) -> None:
            super().__init__("identity-session-test-failing")
            self.partial_resource_open = False

        def __enter__(self) -> _FailingApplication:
            self.enter_count += 1
            self.partial_resource_open = True
            raise RuntimeError(SENTINEL)

        def __exit__(self, *_args: object) -> None:
            self.exit_count += 1
            self.partial_resource_open = False

    application = _FailingApplication()

    def temporary_factory(**kwargs: object) -> tempfile.TemporaryDirectory[str]:
        temporary = tempfile.TemporaryDirectory(**kwargs)
        temporary_paths.append(Path(temporary.name))
        return temporary

    with pytest.raises(RuntimeError, match="sentinel-secret"):
        start_unauthenticated_session(
            application_factory=lambda **_kwargs: application,
            temporary_factory=temporary_factory,
        )

    assert application.exit_count == 1
    assert application.partial_resource_open is False
    assert not any(path.exists() for path in temporary_paths)


def test_ordered_event_drain_is_non_blocking_ordered_and_waited() -> None:
    from chainlit_app import OrderedEventDrain
    from ops_scaffold import application as application_module

    events = tuple(
        application_module.AppEvent(
            schema_version=application_module.EVENT_SCHEMA_VERSION,
            event_type=application_module.EventType.MEMORY,
            run_id="run-test-event-drain",
            status=application_module.EventStatus.COMPLETED,
            memory_level=application_module.MemoryLevel.FACT,
            count=1,
            artifact_id=f"memory-test-drain-{index}",
        )
        for index in range(2)
    )

    async def exercise() -> None:
        gate = asyncio.Event()
        rendered: list[str | None] = []

        async def render(event: AppEvent) -> None:
            await gate.wait()
            rendered.append(event.artifact_id)

        drain = OrderedEventDrain(render, max_events=2)
        await asyncio.to_thread(drain.emit, events[0])
        await asyncio.to_thread(drain.emit, events[1])
        finishing = asyncio.create_task(drain.finish())
        await asyncio.sleep(0)

        assert rendered == []
        assert finishing.done() is False
        gate.set()
        await finishing
        assert rendered == [
            "memory-test-drain-0",
            "memory-test-drain-1",
        ]

    asyncio.run(exercise())


def test_cli_and_chainlit_do_not_own_message_history_or_runtime_state() -> None:
    app_source = (PROJECT_ROOT / "app.py").read_text(encoding="utf-8")
    chainlit_source = (PROJECT_ROOT / "chainlit_app.py").read_text(encoding="utf-8")

    for source in (app_source, chainlit_source):
        assert "InMemoryStore" not in source
        assert "InMemorySaver" not in source
        assert "conversation_history" not in source
        assert "message_history" not in source
        assert ".invoke(" not in source
    assert "RuntimeServices.run_turn" in (
        PROJECT_ROOT / "ops_scaffold" / "application.py"
    ).read_text(encoding="utf-8")


def test_cli_and_ui_error_rendering_never_echoes_raw_exceptions() -> None:
    from app import render_cli_turn
    from chainlit_app import safe_error_message

    class _FailingApplication:
        identity_id = "identity-test-failure"

        def run_turn(self, *_args: object, **_kwargs: object) -> object:
            raise RuntimeError(SENTINEL)

    output = io.StringIO()
    render_cli_turn(
        _FailingApplication(),
        thread_id="thread-test-failure",
        user_input="synthetic failure",
        output_stream=output,
    )

    assert SENTINEL not in output.getvalue()
    assert SENTINEL not in safe_error_message(RuntimeError(SENTINEL))

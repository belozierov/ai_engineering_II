"""Optional Chainlit adapter over the same application runner and events."""

from __future__ import annotations

import asyncio
import logging
import secrets
import sys
import tempfile
import threading
from collections.abc import Awaitable, Callable
from pathlib import Path
from typing import Any

try:
    import chainlit as cl
except ImportError:  # The base homework and evaluator do not require the UI extra.
    cl = None

from ops_scaffold.application import (
    Application,
    PublicTurn,
    create_application,
    public_event_json,
    validate_turn_input,
)
from ops_scaffold.contracts import AppEvent, RuntimeChannel

CHAINLIT_AVAILABLE = cl is not None
_SAFE_UI_ERROR = "Операція завершилась без розкриття внутрішньої помилки."
_LOGGER = logging.getLogger(__name__)


def _enforce_same_origin_websockets() -> None:
    """Restore Engine.IO's same-origin handshake check disabled by Chainlit."""

    if cl is None:
        return
    try:
        from chainlit.server import sio

        engine = sio.eio
    except (AttributeError, ImportError) as exc:
        raise RuntimeError("Chainlit WebSocket origin enforcement is unavailable") from exc
    if not hasattr(engine, "cors_allowed_origins"):
        raise RuntimeError("Chainlit WebSocket origin enforcement is unavailable")
    engine.cors_allowed_origins = None


_enforce_same_origin_websockets()


def render_event(event: AppEvent) -> str:
    """Render the exact shared metadata-only projection."""

    return public_event_json(event)


def safe_error_message(_error: BaseException | None = None) -> str:
    """Return a fixed UI error that never reflects exception text."""

    return _SAFE_UI_ERROR


def render_final_answer(answer: str) -> str:
    """Render model text without letting Markdown consume citation brackets."""

    normalized = answer.replace("\r\n", "\n").replace("\r", "\n")
    indented = "\n".join(f"    {line}" if line else "    " for line in normalized.split("\n"))
    return f"Фінальна відповідь:\n\n{indented}"


def _log_ui_failure(stage: str, error: BaseException | None) -> None:
    """Log bounded diagnostics without exception text, source bodies, or secrets."""

    if error is None:
        _LOGGER.warning("chainlit.%s failed safely without exception detail", stage)
        return
    cause = error.__cause__
    cause_name = type(cause).__name__ if cause is not None else "none"
    missing_module = cause.name if isinstance(cause, ModuleNotFoundError) else None
    if isinstance(missing_module, str) and missing_module.isidentifier():
        _LOGGER.warning(
            "chainlit.%s failed safely error_type=%s cause_type=%s missing_module=%s",
            stage,
            type(error).__name__,
            cause_name,
            missing_module,
        )
        return
    _LOGGER.warning(
        "chainlit.%s failed safely error_type=%s cause_type=%s",
        stage,
        type(error).__name__,
        cause_name,
    )


class UnauthenticatedSession:
    """Own one temporary application and its server-generated scope."""

    def __init__(
        self,
        application: object,
        *,
        temporary: tempfile.TemporaryDirectory[str] | None = None,
    ) -> None:
        identity_id = getattr(application, "identity_id", None)
        if not isinstance(identity_id, str) or not identity_id:
            raise TypeError("session application must expose its owned identity")
        self.application = application
        self.identity_id = identity_id
        self.thread_id = f"thread-session-{secrets.token_hex(16)}"
        self._temporary = temporary
        self._lock = threading.Lock()
        self._closed = False

    def run(
        self,
        user_input: str,
        *,
        on_event: object | None = None,
    ) -> PublicTurn:
        text = validate_turn_input(user_input)
        with self._lock:
            if self._closed:
                raise RuntimeError("session application is closed")
            result = self.application.run_turn(
                self.thread_id,
                text,
                channel=RuntimeChannel.CHAINLIT,
                on_event=on_event,
            )
        if not isinstance(result, PublicTurn):
            raise TypeError("application returned an invalid public turn")
        return result

    def close(self) -> None:
        """Close application state and its temporary directory exactly once."""

        with self._lock:
            if self._closed:
                return
            self._closed = True
            temporary = self._temporary
            self._temporary = None
            try:
                self.application.__exit__(None, None, None)
            finally:
                if temporary is not None:
                    temporary.cleanup()


def create_unauthenticated_session(
    application: object,
    *,
    temporary: tempfile.TemporaryDirectory[str] | None = None,
) -> UnauthenticatedSession:
    """Take ownership of one entered application and its ephemeral identity."""

    return UnauthenticatedSession(
        application=application,
        temporary=temporary,
    )


def start_unauthenticated_session(
    *,
    application_factory: Callable[..., Application] = create_application,
    temporary_factory: Callable[..., tempfile.TemporaryDirectory[str]] = (
        tempfile.TemporaryDirectory
    ),
) -> UnauthenticatedSession:
    """Start one isolated temporary application with cleanup on partial failure."""

    temporary = temporary_factory(prefix="ops-copilot-chainlit-")
    application: Application | None = None
    try:
        application = application_factory(
            state_dir=Path(temporary.name) / "state",
            ephemeral_identity=True,
        )
        application.__enter__()
        return create_unauthenticated_session(
            application,
            temporary=temporary,
        )
    except BaseException:
        try:
            if application is not None:
                application.__exit__(*sys.exc_info())
        finally:
            temporary.cleanup()
        raise


class EventDrainError(RuntimeError):
    """A fixed bounded failure while rendering metadata events."""


_EVENT_QUEUE_LIMIT = 512
_STOP_EVENT_DRAIN = object()


class OrderedEventDrain:
    """Bridge synchronous runner callbacks to one ordered async UI renderer."""

    def __init__(
        self,
        renderer: Callable[[AppEvent], Awaitable[None]],
        *,
        max_events: int = _EVENT_QUEUE_LIMIT,
    ) -> None:
        if not callable(renderer):
            raise TypeError("event renderer must be callable")
        if type(max_events) is not int or not 1 <= max_events <= _EVENT_QUEUE_LIMIT:
            raise ValueError("event queue limit must be a positive bounded integer")
        self._renderer = renderer
        self._loop = asyncio.get_running_loop()
        self._queue: asyncio.Queue[AppEvent | object] = asyncio.Queue(maxsize=max_events)
        self._failure = False
        self._finished = False
        self._task = self._loop.create_task(self._drain())

    def emit(self, event: AppEvent) -> None:
        """Schedule one event without waiting on UI network rendering."""

        if not isinstance(event, AppEvent):
            raise TypeError("event drain accepts app-owned events only")
        if self._finished:
            raise RuntimeError("event drain is already finished")
        self._loop.call_soon_threadsafe(self._enqueue, event)

    async def finish(self) -> None:
        """Render every queued event in order and stop the drain task."""

        if not self._finished:
            barrier = self._loop.create_future()
            self._loop.call_soon(barrier.set_result, None)
            await barrier
            self._finished = True
            await self._queue.put(_STOP_EVENT_DRAIN)
        await self._task
        if self._failure:
            raise EventDrainError("event rendering failed safely")

    def _enqueue(self, event: AppEvent) -> None:
        if self._finished:
            self._failure = True
            return
        try:
            self._queue.put_nowait(event)
        except asyncio.QueueFull:
            self._failure = True

    async def _drain(self) -> None:
        while True:
            item = await self._queue.get()
            try:
                if item is _STOP_EVENT_DRAIN:
                    return
                try:
                    await self._renderer(item)
                except Exception:
                    self._failure = True
            finally:
                self._queue.task_done()


if cl is not None:

    async def _start_chainlit_session() -> UnauthenticatedSession:
        """Create and store one UI session for the current Chainlit user session."""

        session = await asyncio.to_thread(start_unauthenticated_session)
        cl.user_session.set("ops_copilot_session", session)
        return session

    @cl.on_chat_start
    async def _on_chat_start() -> None:
        session: UnauthenticatedSession | None = None
        try:
            session = await _start_chainlit_session()
            await cl.Message(
                content=(
                    "Ops Copilot v2 готовий. Сесія тимчасова й ізольована; "
                    "поле введення доступне з клавіатури."
                )
            ).send()
        except Exception as exc:
            _log_ui_failure("chat_start", exc)
            cl.user_session.set("ops_copilot_session", None)
            if session is not None:
                try:
                    await asyncio.to_thread(session.close)
                except Exception:
                    session = None
            await cl.Message(content=f"Стан: помилка. {safe_error_message(exc)}").send()

    @cl.on_chat_resume
    async def _on_chat_resume(_thread: Any) -> None:
        session: UnauthenticatedSession | None = None
        try:
            session = await _start_chainlit_session()
            await cl.Message(
                content=(
                    "Сесію відновлено з новим тимчасовим runtime. Browser thread "
                    "не переносить server-side memory після перезапуску."
                )
            ).send()
        except Exception as exc:
            _log_ui_failure("chat_resume", exc)
            cl.user_session.set("ops_copilot_session", None)
            if session is not None:
                try:
                    await asyncio.to_thread(session.close)
                except Exception:
                    session = None
            await cl.Message(content=f"Стан: помилка. {safe_error_message(exc)}").send()

    @cl.on_message
    async def _on_message(message: Any) -> None:
        session = cl.user_session.get("ops_copilot_session")
        if not isinstance(session, UnauthenticatedSession):
            try:
                session = await _start_chainlit_session()
                await cl.Message(
                    content=(
                        "Сесію відновлено. Попередній browser thread не мав "
                        "активного runtime після перезапуску сервера."
                    )
                ).send()
            except Exception as exc:
                _log_ui_failure("message_session_restore", exc)
                cl.user_session.set("ops_copilot_session", None)
                await cl.Message(content=f"Стан: помилка. {safe_error_message(exc)}").send()
                return
        loading = cl.Message(content="Стан: завантаження…")
        await loading.send()

        async def send_event(event: AppEvent) -> None:
            rendered = render_event(event)
            await cl.Message(content=f"Подія: {rendered}").send()

        drain = OrderedEventDrain(send_event)
        turn: PublicTurn | None = None
        failure: Exception | None = None
        try:
            turn = await asyncio.to_thread(
                session.run,
                message.content,
                on_event=drain.emit,
            )
        except Exception as exc:
            _log_ui_failure("message_run", exc)
            failure = exc
        try:
            await drain.finish()
        except Exception as exc:
            _log_ui_failure("event_drain", exc)
            failure = failure or exc
        if failure is not None or turn is None:
            loading.content = f"Стан: помилка. {safe_error_message(failure)}"
            await loading.update()
            return

        loading.content = f"Стан: {turn.status.value}"
        await loading.update()
        await cl.Message(content=render_final_answer(turn.answer)).send()

    @cl.on_chat_end
    async def _on_chat_end() -> None:
        session = cl.user_session.get("ops_copilot_session")
        cl.user_session.set("ops_copilot_session", None)
        if isinstance(session, UnauthenticatedSession):
            try:
                await asyncio.to_thread(session.close)
            except Exception:
                return

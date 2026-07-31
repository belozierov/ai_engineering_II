"""Primary terminal-first glass-box interface for Ops Copilot v2."""

from __future__ import annotations

import argparse
import os
import sys
from collections.abc import Callable, Sequence
from textwrap import fill
from typing import TextIO

from ops_scaffold.application import (
    Application,
    PublicTurn,
    create_application,
    public_event_json,
    safe_public_answer,
    validate_logical_thread_id,
)
from ops_scaffold.contracts import AppEvent, RuntimeChannel

_SAFE_TURN_ERROR = "Помилка виконання прихована; перевірте status і локальні налаштування."  # noqa: RUF001
_SAFE_STARTUP_ERROR = "Застосунок не запущено; перевірте дані, пакет і змінні середовища."  # noqa: RUF001
_RESET = "\033[0m"
_DIM = "\033[2m"
_BOLD = "\033[1m"
_BLUE = "\033[34m"
_GREEN = "\033[32m"
_YELLOW = "\033[33m"
_RED = "\033[31m"


def render_event(event: AppEvent) -> str:
    """Render the shared metadata-only event projection."""

    return public_event_json(event)


def _use_pretty_output(output_stream: TextIO) -> bool:
    isatty = getattr(output_stream, "isatty", None)
    return bool(callable(isatty) and isatty() and os.environ.get("NO_COLOR") is None)


def _paint(value: str, color: str, *, enabled: bool) -> str:
    return f"{color}{value}{_RESET}" if enabled else value


def _render_pretty_event(event: AppEvent, *, color: bool) -> str:
    status_color = {
        "completed": _GREEN,
        "blocked": _YELLOW,
        "failed": _RED,
        "budget_exceeded": _YELLOW,
        "cancelled": _YELLOW,
        "started": _BLUE,
    }.get(event.status.value, _BLUE)
    status = _paint(event.status.value, status_color, enabled=color)
    event_type = event.event_type.value
    if event_type == "plan_snapshot":
        message = f"updated plan ({event.count} items)"
    elif event_type == "source" and event.source_family is not None:
        message = f"collected {event.source_family.value} evidence"
    elif event_type == "memory" and event.memory_level is not None:
        message = f"updated {event.memory_level.value} memory"
    elif event_type == "compaction":
        message = "compacted conversation history"
    elif event_type == "turn":
        message = "turn finished"
    else:
        message = event_type.replace("_", " ")

    details = [f"run={event.run_id}"]
    if event.artifact_id is not None:
        label = "evidence" if event_type == "source" else "artifact"
        details.append(f"{label}={event.artifact_id}")
    if event.digest is not None:
        details.append(f"digest={event.digest[:12]}...")
    detail_text = _paint("  ".join(details), _DIM, enabled=color)
    return f"  {status}  {message}  {detail_text}"


def _print_pretty_status(
    label: str,
    status: str,
    color: str,
    *,
    output_stream: TextIO,
) -> None:
    print(
        _paint(label, _BOLD, enabled=True),
        _paint(status, color, enabled=True),
        file=output_stream,
    )


def _format_answer_for_terminal(answer: str) -> str:
    normalized = answer.replace("\r\n", "\n").replace("\r", "\n")
    normalized = normalized.replace(" Citations: - ", "\n\nCitations:\n- ")
    normalized = normalized.replace("] - ", "]\n- ")
    paragraphs = []
    for paragraph in normalized.split("\n"):
        if paragraph.startswith("- "):
            paragraphs.append(fill(paragraph, width=100, subsequent_indent="  "))
        elif paragraph:
            paragraphs.append(fill(paragraph, width=100))
        else:
            paragraphs.append("")
    return "\n".join(paragraphs)


def _render_plan_snapshots(
    snapshots: tuple[tuple[dict[str, str], ...], ...],
    *,
    color: bool,
) -> str:
    blocks: list[str] = []
    for index, snapshot in enumerate(snapshots, start=1):
        blocks.append(f"  {_paint(f'Plan {index}', _BLUE, enabled=color)}")
        for item in snapshot:
            marker = {
                "pending": "○",
                "in_progress": "→",
                "completed": "✓",
            }[item["status"]]
            blocks.append(f"    {marker} [{item['status']}] {item['content']}")
    return "\n".join(blocks)


def render_cli_turn(
    application: object,
    *,
    thread_id: str,
    user_input: str,
    output_stream: TextIO,
) -> PublicTurn | None:
    """Render one turn without owning history, Store, or checkpoint state."""

    thread = validate_logical_thread_id(thread_id)
    pretty = _use_pretty_output(output_stream)
    identity = getattr(application, "identity_id", "identity-unavailable")
    if not isinstance(identity, str):
        identity = "identity-unavailable"
    if pretty:
        print(file=output_stream)
        print(_paint("Context", _BOLD, enabled=True), file=output_stream)
        print(f"  identity: {safe_public_answer(identity)}", file=output_stream)
        print(f"  thread:   {thread}", file=output_stream)
        _print_pretty_status(
            "Status",
            "loading",
            _YELLOW,
            output_stream=output_stream,
        )
        print(_paint("Activity", _BOLD, enabled=True), file=output_stream)
    else:
        print(
            f"context identity={safe_public_answer(identity)} thread={thread}",
            file=output_stream,
        )
        print("status=loading", file=output_stream)
    emitted: set[str] = set()

    def on_event(event: AppEvent) -> None:
        rendered = render_event(event)
        emitted.add(rendered)
        if pretty:
            print(_render_pretty_event(event, color=True), file=output_stream, flush=True)
        else:
            print(f"event={rendered}", file=output_stream, flush=True)

    try:
        result = application.run_turn(
            thread,
            user_input,
            channel=RuntimeChannel.CLI,
            on_event=on_event,
        )
        if not isinstance(result, PublicTurn):
            raise TypeError("application returned an invalid public turn")
    except Exception:
        if pretty:
            print(_paint("Error", _BOLD, enabled=True), file=output_stream)
            print(f"  {_SAFE_TURN_ERROR}", file=output_stream)
            _print_pretty_status(
                "Status",
                "failed",
                _RED,
                output_stream=output_stream,
            )
        else:
            print(f"error={_SAFE_TURN_ERROR}", file=output_stream)
            print("status=failed", file=output_stream)
        return None

    for event in result.events:
        rendered = render_event(event)
        if rendered not in emitted:
            if pretty:
                print(_render_pretty_event(event, color=True), file=output_stream)
            else:
                print(f"event={rendered}", file=output_stream)
            emitted.add(rendered)
    if pretty:
        if result.plan_snapshots:
            print(_paint("Plans observed this turn", _BOLD, enabled=True), file=output_stream)
            print(
                _render_plan_snapshots(result.plan_snapshots, color=True),
                file=output_stream,
            )
        print(_paint("Answer", _BOLD, enabled=True), file=output_stream)
        print(_format_answer_for_terminal(result.answer), file=output_stream)
        status_color = _GREEN if result.status.value == "completed" else _YELLOW
        _print_pretty_status(
            "Status",
            result.status.value,
            status_color,
            output_stream=output_stream,
        )
    else:
        print(f"answer={result.answer}", file=output_stream)
        print(f"status={result.status.value}", file=output_stream)
    return result


def run_cli(
    *,
    thread_id: str,
    input_stream: TextIO | None = None,
    output_stream: TextIO | None = None,
    application_factory: Callable[[], Application] = create_application,
) -> int:
    """Run the keyboard-first REPL over one application-owned local identity."""

    source = sys.stdin if input_stream is None else input_stream
    destination = sys.stdout if output_stream is None else output_stream
    try:
        thread = validate_logical_thread_id(thread_id)
        with application_factory() as application:
            print("Ops Copilot v2 — glass-box operator console", file=destination)
            print(
                "Команди: /thread <logical-id>, /quit.",
                file=destination,
            )
            while True:
                if source is sys.stdin:
                    print("ops> ", end="", file=destination, flush=True)
                line = source.readline()
                if line == "":
                    return 0
                text = line.rstrip("\r\n")
                if not text.strip():
                    continue
                if text == "/quit":
                    return 0
                if text.startswith("/thread"):
                    command, separator, candidate = text.partition(" ")
                    if command != "/thread" or not separator:
                        print("error=Вкажіть bounded logical thread ID.", file=destination)
                        continue
                    try:
                        thread = validate_logical_thread_id(candidate)
                    except ValueError:
                        print("error=Некоректний логічний thread ID.", file=destination)
                        continue
                    print(f"context thread={thread}", file=destination)
                    continue
                if (
                    render_cli_turn(
                        application,
                        thread_id=thread,
                        user_input=text,
                        output_stream=destination,
                    )
                    is None
                ):
                    return 1
    except (ValueError, TypeError):
        print("error=Некоректний логічний thread ID.", file=destination)
        return 2
    except Exception:
        print(f"error={_SAFE_STARTUP_ERROR}", file=destination)
        return 1


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Run the Ops Copilot v2 glass-box CLI over synthetic fixtures."
    )
    parser.add_argument(
        "--thread",
        default="incident-main",
        help="bounded logical conversation ID (not a checkpoint key)",
    )
    arguments = parser.parse_args(argv)
    return run_cli(thread_id=arguments.thread)


if __name__ == "__main__":
    raise SystemExit(main())

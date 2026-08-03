"""The claude-CLI judge transport and the origin it is selected from.

Every test but the last one injects a fake process runner, so no ``claude`` is ever
spawned and the argv, the prompt and the envelope handling are what is under test. The
last one is the opposite bargain: one real call, skipped when the CLI is absent, to prove
that the flags this transport commits to still exist on the installed CLI.
"""

# ruff: noqa: S101 - asserts are the point of a test module

from __future__ import annotations

import json
import shutil
import subprocess
from collections.abc import Sequence
from pathlib import Path

import pytest

from eval.judge import JudgeContractError, parse_judge_verdict
from eval.live import OpenRouterJudgeTransport, ProviderTransientError
from swift_shim.judge import (
    CLAUDE_JUDGE_SYSTEM_PROMPT,
    ClaudeJudgeTransport,
    UnavailableJudgeTransport,
    judge_transport_from_environment,
)

PAYLOAD: dict[str, object] = {
    "question": "Why did checkout time out?",
    "answer": "The gateway deadline was 800ms [evidence:evidence-swift-runbook].",
    "evidence": [{"evidence_id": "evidence-swift-runbook", "content": "deadline 800ms"}],
}


class _FakeRunner:
    """Stand in for ``subprocess.run``: record the call, hand back a prepared result."""

    def __init__(
        self,
        *,
        stdout: str = "",
        returncode: int = 0,
        raises: BaseException | None = None,
    ) -> None:
        self.stdout = stdout
        self.returncode = returncode
        self.raises = raises
        self.calls: list[dict[str, object]] = []

    def __call__(
        self,
        command: Sequence[str],
        *,
        stdin: str,
        timeout_seconds: float,
        cwd: str,
    ) -> subprocess.CompletedProcess[str]:
        self.calls.append(
            {
                "command": list(command),
                "stdin": stdin,
                "timeout_seconds": timeout_seconds,
                "cwd": cwd,
            }
        )
        if self.raises is not None:
            raise self.raises
        return subprocess.CompletedProcess(
            args=list(command),
            returncode=self.returncode,
            stdout=self.stdout,
            stderr="",
        )


def _envelope(result: str, **overrides: object) -> str:
    return json.dumps({"subtype": "success", "is_error": False, "result": result, **overrides})


def _transport(runner: _FakeRunner, **overrides: object) -> ClaudeJudgeTransport:
    return ClaudeJudgeTransport(executable="claude", runner=runner, **overrides)


# MARK: The invocation


def test_the_argv_asks_for_a_json_envelope_and_no_ambient_context() -> None:
    runner = _FakeRunner(stdout=_envelope('{"supported": true, "rationale": "Supported."}'))

    _transport(runner).invoke(PAYLOAD)

    command = runner.calls[0]["command"]
    assert command[:2] == ["claude", "--print"]
    for flag, value in (
        ("--output-format", "json"),
        ("--model", "sonnet"),
        ("--system-prompt", CLAUDE_JUDGE_SYSTEM_PROMPT),
        ("--tools", ""),
        ("--setting-sources", ""),
    ):
        assert command[command.index(flag) + 1] == value
    assert "--strict-mcp-config" in command
    assert "--disable-slash-commands" in command
    assert "--no-session-persistence" in command


def test_the_judge_turn_runs_outside_this_repository() -> None:
    runner = _FakeRunner(stdout=_envelope('{"supported": true, "rationale": "Supported."}'))

    _transport(runner).invoke(PAYLOAD)

    cwd = Path(str(runner.calls[0]["cwd"])).resolve()
    assert cwd.is_absolute()
    assert Path(__file__).resolve().parent not in cwd.parents
    assert not cwd.exists()  # the scratch directory does not outlive the call


def test_the_prompt_carries_the_instructor_serialization_and_the_response_contract() -> None:
    runner = _FakeRunner(stdout=_envelope('{"supported": true, "rationale": "Supported."}'))

    _transport(runner).invoke(PAYLOAD)

    stdin = str(runner.calls[0]["stdin"])
    serialized = json.dumps(PAYLOAD, ensure_ascii=True, sort_keys=True, separators=(",", ":"))
    assert stdin.startswith(serialized)
    assert '"supported"' in stdin and '"rationale"' in stdin


def test_the_model_alias_is_overridable() -> None:
    runner = _FakeRunner(stdout=_envelope('{"supported": true, "rationale": "Supported."}'))

    _transport(runner, model="opus").invoke(PAYLOAD)

    command = runner.calls[0]["command"]
    assert command[command.index("--model") + 1] == "opus"


def test_an_oversized_payload_never_reaches_the_process() -> None:
    runner = _FakeRunner(stdout=_envelope('{"supported": true, "rationale": "Supported."}'))

    with pytest.raises(JudgeContractError):
        _transport(runner).invoke({"answer": "x" * 300_000})

    assert runner.calls == []


# MARK: Verdicts the instructor's parser accepts


def test_a_clean_verdict_survives_the_instructors_parser() -> None:
    runner = _FakeRunner(
        stdout=_envelope('{"supported": true, "rationale": "The cited evidence states 800ms."}')
    )

    verdict = parse_judge_verdict(_transport(runner).invoke(PAYLOAD))

    assert verdict.supported is True
    assert verdict.rationale == "The cited evidence states 800ms."


def test_a_fenced_and_padded_verdict_still_parses() -> None:
    runner = _FakeRunner(
        stdout=_envelope(
            '\n```json\n{"supported": false, "rationale": "The answer overstates it."}\n```\n'
        )
    )

    verdict = parse_judge_verdict(_transport(runner).invoke(PAYLOAD))

    assert verdict.supported is False


def test_an_unfenced_but_padded_verdict_still_parses() -> None:
    runner = _FakeRunner(
        stdout=_envelope('  {"supported": true, "rationale": "Supported."}  \n')
    )

    assert parse_judge_verdict(_transport(runner).invoke(PAYLOAD)).supported is True


# MARK: Malformed output is the parser's call, not the transport's


@pytest.mark.parametrize(
    "result",
    [
        "the answer looks supported to me",
        '{"supported": "yes", "rationale": "Supported."}',
        '{"supported": true}',
        '{"supported": true, "rationale": "Supported.", "confidence": 0.9}',
        '{"supported": true, "rationale": ""}',
        "[1, 2, 3]",
    ],
)
def test_output_that_is_not_a_verdict_is_rejected_by_the_instructors_parser(result: str) -> None:
    runner = _FakeRunner(stdout=_envelope(result))

    candidate = _transport(runner).invoke(PAYLOAD)  # the transport itself does not judge it

    with pytest.raises(JudgeContractError):
        parse_judge_verdict(candidate)


def test_a_malformed_envelope_is_not_reported_as_transient() -> None:
    runner = _FakeRunner(stdout="not json at all")

    with pytest.raises(JudgeContractError):
        _transport(runner).invoke(PAYLOAD)


def test_an_oversized_response_is_refused() -> None:
    runner = _FakeRunner(stdout=_envelope("x" * 300_000))

    with pytest.raises(JudgeContractError):
        _transport(runner).invoke(PAYLOAD)


# MARK: Process failures are transient


def test_a_timeout_is_transient() -> None:
    runner = _FakeRunner(raises=subprocess.TimeoutExpired(cmd="claude", timeout=60.0))

    with pytest.raises(ProviderTransientError):
        _transport(runner).invoke(PAYLOAD)


def test_a_binary_that_disappeared_between_selection_and_the_call_is_transient() -> None:
    runner = _FakeRunner(raises=FileNotFoundError("claude"))

    with pytest.raises(ProviderTransientError):
        _transport(runner).invoke(PAYLOAD)


def test_a_nonzero_exit_is_transient() -> None:
    runner = _FakeRunner(stdout="", returncode=1)

    with pytest.raises(ProviderTransientError):
        _transport(runner).invoke(PAYLOAD)


def test_a_turn_the_cli_reports_as_failed_is_transient() -> None:
    runner = _FakeRunner(stdout=_envelope("overloaded", subtype="error_during_execution"))

    with pytest.raises(ProviderTransientError):
        _transport(runner).invoke(PAYLOAD)


def test_the_configured_timeout_reaches_the_runner() -> None:
    runner = _FakeRunner(stdout=_envelope('{"supported": true, "rationale": "Supported."}'))

    _transport(runner, timeout_seconds=12.5).invoke(PAYLOAD)

    assert runner.calls[0]["timeout_seconds"] == 12.5


# MARK: Selection order


def _path_with_claude(tmp_path: Path) -> str:
    executable = tmp_path / "claude"
    executable.write_text("#!/bin/sh\nexit 0\n")
    executable.chmod(0o755)
    return str(tmp_path)


def test_an_openrouter_key_still_wins(monkeypatch: pytest.MonkeyPatch, tmp_path: Path) -> None:
    monkeypatch.setattr(OpenRouterJudgeTransport, "__init__", lambda self, settings: None)

    judge = judge_transport_from_environment(
        {"OPENROUTER_API_KEY": "sk-test", "PATH": _path_with_claude(tmp_path)}
    )

    assert isinstance(judge, OpenRouterJudgeTransport)


def test_a_broken_openrouter_key_degrades_instead_of_falling_through_to_claude(
    monkeypatch: pytest.MonkeyPatch,
    tmp_path: Path,
) -> None:
    def _explode(self: object, settings: object) -> None:
        raise RuntimeError("provider is unreachable")

    monkeypatch.setattr(OpenRouterJudgeTransport, "__init__", _explode)

    judge = judge_transport_from_environment(
        {"OPENROUTER_API_KEY": "sk-test", "PATH": _path_with_claude(tmp_path)}
    )

    assert isinstance(judge, UnavailableJudgeTransport)


def test_no_key_but_a_discoverable_claude_selects_the_cli_judge(tmp_path: Path) -> None:
    judge = judge_transport_from_environment({"PATH": _path_with_claude(tmp_path)})

    assert isinstance(judge, ClaudeJudgeTransport)
    assert judge.command[0] == str(tmp_path / "claude")
    assert judge.command[judge.command.index("--model") + 1] == "sonnet"


def test_the_claude_binary_and_model_are_overridable(tmp_path: Path) -> None:
    executable = tmp_path / "claude-pinned"
    executable.write_text("#!/bin/sh\nexit 0\n")
    executable.chmod(0o755)

    judge = judge_transport_from_environment(
        {"OPS_JUDGE_CLAUDE_BIN": str(executable), "OPS_JUDGE_CLAUDE_MODEL": "haiku"}
    )

    assert isinstance(judge, ClaudeJudgeTransport)
    assert judge.command[0] == str(executable)
    assert judge.command[judge.command.index("--model") + 1] == "haiku"


def test_a_model_alias_that_is_not_an_alias_degrades(tmp_path: Path) -> None:
    judge = judge_transport_from_environment(
        {"PATH": _path_with_claude(tmp_path), "OPS_JUDGE_CLAUDE_MODEL": "--dangerous flag"}
    )

    assert isinstance(judge, UnavailableJudgeTransport)


def test_neither_provider_leaves_the_degraded_transport() -> None:
    judge = judge_transport_from_environment({"PATH": ""})

    assert isinstance(judge, UnavailableJudgeTransport)


def test_an_empty_environment_never_reaches_the_ambient_machine() -> None:
    assert isinstance(judge_transport_from_environment({}), UnavailableJudgeTransport)


# MARK: One real call


@pytest.mark.skipif(shutil.which("claude") is None, reason="the claude CLI is not installed")
def test_the_real_cli_answers_with_a_verdict_the_instructors_parser_accepts() -> None:
    """The only test here that spends a model call: it proves the flags still work."""

    transport = ClaudeJudgeTransport(executable=str(shutil.which("claude")))

    verdict = parse_judge_verdict(
        transport.invoke(
            {
                "question": "How long is the checkout gateway deadline?",
                "answer": "The checkout gateway deadline is 800ms [evidence:e1].",
                "evidence": [
                    {
                        "evidence_id": "e1",
                        "content": "The checkout gateway deadline is 800ms.",
                    }
                ],
                "expected_claims": ["the deadline is 800ms"],
            }
        )
    )

    assert verdict.supported is True
    assert verdict.rationale.strip()

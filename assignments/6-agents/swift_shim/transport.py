"""Drive one scenario through the Swift operator console as a live agent transport."""

from __future__ import annotations

import os
import subprocess  # the transport's whole job is to run the local Swift CLI
import tempfile
import time
from collections.abc import Mapping, Sequence
from pathlib import Path

from eval.live import LiveContractError, LiveOutcome, LiveScenario, ProviderTransientError
from swift_shim.protocol import build_live_outcome, parse_excerpt_lines, parse_record_lines
from swift_shim.quarantine import QuarantineIndex

_MAX_STREAM_BYTES = 8_388_608
_DEFAULT_BUILD_TIMEOUT = 900.0
_USAGE_EXIT_CODES = frozenset({2, 64})


class SwiftCLIAgentTransport:
    """Run ``ops-cli --json`` once per scenario: one prompt in, one turn record out.

    The binary is built once and reused. Each scenario gets a fresh temporary workspace
    and a fresh excerpts file, so no run can read another run's identity store, procedures
    or sandbox state -- the isolation the live scenarios assume.
    """

    def __init__(
        self,
        *,
        package_dir: Path,
        data_dir: Path | None = None,
        executable: Path | None = None,
        quarantine: QuarantineIndex | None = None,
        environ: Mapping[str, str] | None = None,
        build_timeout_seconds: float = _DEFAULT_BUILD_TIMEOUT,
    ) -> None:
        self._package_dir = Path(package_dir).resolve()
        self._data_dir = Path(data_dir).resolve() if data_dir else self._package_dir / "data"
        self._executable = Path(executable).resolve() if executable else None
        self._quarantine = (
            quarantine
            if quarantine is not None
            else QuarantineIndex.from_data_directory(self._data_dir)
        )
        self._environ = dict(os.environ if environ is None else environ)
        self._build_timeout_seconds = build_timeout_seconds

    def invoke(
        self,
        scenario: LiveScenario,
        *,
        deadline_monotonic: float | None = None,
    ) -> LiveOutcome:
        remaining = (
            None if deadline_monotonic is None else deadline_monotonic - time.monotonic()
        )
        if remaining is not None and remaining <= 0:
            raise TimeoutError("live scenario budget was exhausted")
        executable = self._built_executable()
        with tempfile.TemporaryDirectory(prefix="ops-live-") as scratch:
            workspace = Path(scratch) / "workspace"
            excerpts = Path(scratch) / "excerpts.jsonl"
            completed = self._run(
                [
                    str(executable),
                    "--json",
                    "--data",
                    str(self._data_dir),
                    "--workspace",
                    str(workspace),
                    "--excerpts-file",
                    str(excerpts),
                ],
                stdin=f"{scenario.question}\n",
                timeout_seconds=remaining,
            )
            self._reject_oversized(completed)
            records = parse_record_lines(completed.stdout.splitlines())
            excerpt_lines = _read_lines(excerpts)
        _classify_exit(completed.returncode, records)
        return build_live_outcome(
            records=records,
            excerpts=parse_excerpt_lines(excerpt_lines),
            scenario=scenario,
            quarantine=self._quarantine,
        )

    # MARK: Process

    def _built_executable(self) -> Path:
        """Build once, on first use; a caller that already has a binary skips the build."""

        if self._executable is not None and self._executable.exists():
            return self._executable
        built = self._package_dir / ".build" / "debug" / "ops-cli"
        completed = self._run(
            ["swift", "build", "--product", "ops-cli"],
            stdin="",
            timeout_seconds=self._build_timeout_seconds,
        )
        if completed.returncode != 0 or not built.exists():
            raise LiveContractError("swift agent binary is unavailable")
        self._executable = built
        return built

    def _run(
        self,
        command: Sequence[str],
        *,
        stdin: str,
        timeout_seconds: float | None,
    ) -> subprocess.CompletedProcess[str]:
        try:
            return subprocess.run(  # noqa: S603 - a fixed argv, never a shell string
                list(command),
                cwd=self._package_dir,
                env=self._environ,
                input=stdin,
                capture_output=True,
                text=True,
                timeout=timeout_seconds,
                check=False,
            )
        except subprocess.TimeoutExpired as exc:
            raise TimeoutError("live scenario budget was exhausted") from exc
        except OSError as exc:
            raise LiveContractError("swift agent process is unavailable") from exc

    @staticmethod
    def _reject_oversized(completed: subprocess.CompletedProcess[str]) -> None:
        if len(completed.stdout) > _MAX_STREAM_BYTES:
            raise LiveContractError("swift agent protocol stream exceeded its bounds")


def _classify_exit(returncode: int, records: Sequence[Mapping[str, object]]) -> None:
    """Map process outcomes onto the evaluator's two-way exception vocabulary.

    A failed turn writes no record and leaves with 1 -- retryable, and classified the way
    ``eval/live.py:701`` classifies its own failed turn. A usage or startup refusal, or a
    stream that contradicts itself, is a contract failure no retry can fix.
    """

    if returncode == 0:
        return
    if returncode in _USAGE_EXIT_CODES:
        raise LiveContractError("swift agent rejected its invocation")
    if records:
        raise LiveContractError("swift agent left with a failure after emitting records")
    raise ProviderTransientError("swift agent turn was unavailable")


def _read_lines(path: Path) -> tuple[str, ...]:
    """An absent excerpts file is a gap, not a failure: excerpts only enrich the judge."""

    try:
        raw = path.read_bytes()
    except OSError:
        return ()
    if len(raw) > _MAX_STREAM_BYTES:
        return ()
    try:
        return tuple(raw.decode("utf-8").splitlines())
    except UnicodeError:
        return ()

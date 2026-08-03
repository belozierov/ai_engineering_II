"""Swift Ops Copilot evaluator: the authoritative Swift core plus optional live rows.

One report in the instructor's shape. The core section is produced by ``ops-eval`` and is
the only thing that decides the exit code; ``--full`` adds the live tier by driving the
Swift ``ops-cli`` through the evaluator's own ``run_live_scenario``, so every scenario
check, citation validator and judge contract runs unchanged.
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess  # the evaluator's job is to run the local Swift binaries
import sys
from collections.abc import Mapping, Sequence
from pathlib import Path

from eval.live import LiveScenario, load_live_scenarios, run_live_scenario
from eval.report import CheckResult
from swift_shim.judge import judge_transport_from_environment
from swift_shim.quarantine import QuarantineIndex
from swift_shim.report import (
    CoreReportError,
    merge_live_rows,
    parse_core_report,
    render_report,
    report_json,
)
from swift_shim.transport import SwiftCLIAgentTransport

PACKAGE_DIR = Path(__file__).resolve().parent
DEFAULT_SCENARIO_BUDGET_SECONDS = 180.0
_CORE_TIMEOUT_SECONDS = 3_600.0


def run_core_evaluation(
    *,
    package_dir: Path,
    data_dir: Path,
    workspace: Path | None = None,
    executable: Path | None = None,
    environ: Mapping[str, str] | None = None,
) -> dict[str, object]:
    """Run the Swift core evaluator and return its report dict."""

    command = (
        [str(executable)] if executable else ["swift", "run", "--quiet", "ops-eval"]
    ) + ["--json", "--data", str(data_dir)]
    if workspace is not None:
        command += ["--workspace", str(workspace)]
    try:
        completed = subprocess.run(  # noqa: S603 - a fixed argv, never a shell string
            command,
            cwd=package_dir,
            env=dict(os.environ if environ is None else environ),
            capture_output=True,
            text=True,
            timeout=_CORE_TIMEOUT_SECONDS,
            check=False,
        )
    except (OSError, subprocess.SubprocessError) as exc:
        raise CoreReportError("core evaluator is unavailable") from exc
    return parse_core_report(completed.stdout)


def run_live_rows(
    *,
    package_dir: Path,
    data_dir: Path,
    scenarios: Sequence[LiveScenario] | None = None,
    agent_transport: object | None = None,
    judge_transport: object | None = None,
    scenario_budget_seconds: float = DEFAULT_SCENARIO_BUDGET_SECONDS,
    cli_executable: Path | None = None,
    environ: Mapping[str, str] | None = None,
) -> list[CheckResult]:
    """Run every live scenario through the evaluator's own seam.

    Setup that never got far enough to name a scenario reports the tier-level
    ``live.agent`` / ``live.judge`` pair, mirroring ``eval/live.py:526``.
    """

    try:
        selected = tuple(scenarios) if scenarios is not None else load_live_scenarios()
        agent = agent_transport or SwiftCLIAgentTransport(
            package_dir=package_dir,
            data_dir=data_dir,
            executable=cli_executable,
            quarantine=QuarantineIndex.from_data_directory(data_dir),
            environ=environ,
        )
        judge = judge_transport or judge_transport_from_environment(environ)
    except Exception:  # setup failure is reported, never raised at a user
        return _live_setup_unavailable("live runtime setup was unavailable")
    rows: list[CheckResult] = []
    for scenario in selected:
        rows.extend(
            run_live_scenario(
                scenario,
                agent_transport=agent,
                judge_transport=judge,
                scenario_time_budget_seconds=scenario_budget_seconds,
            )
        )
    return rows


def _live_setup_unavailable(message: str) -> list[CheckResult]:
    return [
        CheckResult.unavailable("live.agent", message),
        CheckResult.unavailable("live.judge", message),
    ]


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description=(
            "Run the authoritative Swift Ops Copilot evaluator; --full adds the "
            "non-authoritative live tier by driving ops-cli through the course "
            "evaluator's own scenario checks and grounding judge."
        )
    )
    parser.add_argument(
        "--full",
        action="store_true",
        help="add optional live agent and grounding-judge feedback",
    )
    parser.add_argument(
        "--json",
        action="store_true",
        help="render the bounded report as JSON",
    )
    parser.add_argument(
        "--data",
        type=Path,
        default=PACKAGE_DIR / "data",
        help="validated fixture directory (default: ./data)",
    )
    parser.add_argument(
        "--workspace",
        type=Path,
        default=None,
        help=(
            "private workspace for the core evaluator (default: its own temporary "
            "directory); live scenarios always get a fresh temporary workspace each"
        ),
    )
    parser.add_argument(
        "--package-dir",
        type=Path,
        default=PACKAGE_DIR,
        help="Swift package root the binaries are run from (default: this file's directory)",
    )
    parser.add_argument(
        "--ops-eval",
        type=Path,
        default=None,
        help="prebuilt ops-eval binary to run instead of `swift run ops-eval`",
    )
    parser.add_argument(
        "--ops-cli",
        type=Path,
        default=None,
        help="prebuilt ops-cli binary to run instead of building the product on first use",
    )
    parser.add_argument(
        "--scenario-budget",
        type=float,
        default=DEFAULT_SCENARIO_BUDGET_SECONDS,
        help=(
            "seconds one live scenario may take, 5-300 "
            f"(default: {DEFAULT_SCENARIO_BUDGET_SECONDS:g})"
        ),
    )
    args = parser.parse_args(argv)

    package_dir = args.package_dir.resolve()
    data_dir = args.data.resolve()
    try:
        report = run_core_evaluation(
            package_dir=package_dir,
            data_dir=data_dir,
            workspace=args.workspace,
            executable=args.ops_eval,
        )
    except CoreReportError:
        return _report_unavailable(as_json=args.json)

    if args.full:
        report = merge_live_rows(
            report,
            run_live_rows(
                package_dir=package_dir,
                data_dir=data_dir,
                scenario_budget_seconds=args.scenario_budget,
                cli_executable=args.ops_cli,
            ),
        )

    print(report_json(report) if args.json else render_report(report))
    return 0 if report.get("core_complete") is True else 1


def _report_unavailable(*, as_json: bool) -> int:
    if as_json:
        print(
            json.dumps(
                {
                    "core_complete": False,
                    "error": "the Swift core evaluator did not produce a report",
                },
                sort_keys=True,
                separators=(",", ":"),
            )
        )
    else:
        print("[FAIL] core.evaluator: the Swift core evaluator did not produce a report")
        print("Core INCOMPLETE")
    return 1


if __name__ == "__main__":
    sys.exit(main())

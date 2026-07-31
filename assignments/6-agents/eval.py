"""Ops Copilot authoritative evaluator and optional live quality runner."""

from __future__ import annotations

import argparse
import json
import sys
from collections.abc import Mapping, Sequence

from eval.components import run_component_checks
from eval.live import run_live_checks
from eval.report import CheckResult, EvaluationReport, ResultState
from eval.scenarios import run_replan_scenario
from eval.structural import evaluate_package_selection, run_structural_checks


def run_evaluation(
    *,
    full: bool = False,
    environ: Mapping[str, str] | None = None,
) -> EvaluationReport | None:
    """Run authoritative checks; return ``None`` for a rejected package selector."""

    package_name, selection_rows = evaluate_package_selection(environ)
    if package_name is None:
        return None
    report = EvaluationReport(package_name=package_name)
    report.extend_core(selection_rows)
    structural = run_structural_checks(package_name)
    report.extend_core(structural)

    todo_rows = [row for row in structural if row.name.startswith("todo.")]
    capabilities_ready = len(todo_rows) == 6 and all(
        row.state is ResultState.PASS for row in todo_rows
    )
    if capabilities_ready:
        report.extend_core(run_component_checks(package_name))
        scenario_rows, _observation = run_replan_scenario(package_name)
        report.extend_core(scenario_rows)

    if full:
        try:
            report.extend_live(run_live_checks(package_name, environ=environ))
        except Exception:
            report.extend_live(
                (
                    CheckResult.unavailable(
                        "live.agent",
                        "optional live evaluation was unavailable",
                    ),
                    CheckResult.unavailable(
                        "live.judge",
                        "optional live evaluation was unavailable",
                    ),
                )
            )
    return report


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description=(
            "Run deterministic Ops Copilot checks; --full adds non-authoritative "
            "OpenRouter quality feedback when configured."
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
    args = parser.parse_args(argv)

    report = run_evaluation(full=args.full)
    if report is None:
        if args.json:
            print(
                json.dumps(
                    {
                        "core_complete": False,
                        "error": "OPS_PKG must select an available course package",
                    },
                    sort_keys=True,
                    separators=(",", ":"),
                )
            )
        else:
            print(
                "[FAIL] structural.package-selector: "
                "OPS_PKG must select an available course package"
            )
            print("Core INCOMPLETE")
        return 1

    if args.json:
        print(
            json.dumps(
                report.as_public_dict(),
                ensure_ascii=True,
                sort_keys=True,
                separators=(",", ":"),
            )
        )
    else:
        print(report.render())
    return report.exit_code


if __name__ == "__main__":
    sys.exit(main())

"""Merge live rows into the Swift evaluator's report and render it.

The report is kept as the dict the Swift evaluator produced rather than rebuilt as an
``eval.report.EvaluationReport``: the Swift report carries a ``dropped`` section the Python
class has no field for, names its package ``ops-copilot`` (which the Python class rejects),
and computes completeness against required names minus the dropped ones. Rebuilding would
silently answer a different question, so the shim adds rows to the report it was given and
renders the same layout the Swift and Python reports both render.
"""

from __future__ import annotations

import json
from collections.abc import Mapping, Sequence

from eval.report import CheckResult, ResultState

_REPORT_KEYS = ("package", "core_complete", "core", "live", "capability_ledger")
_MAX_REPORT_BYTES = 4_194_304


class CoreReportError(ValueError):
    """The Swift core evaluator did not produce a readable report."""


def parse_core_report(stdout: str) -> dict[str, object]:
    """Recover the report object from a ``swift run`` stdout stream.

    ``swift run`` may prepend build progress, so the report is the last line that parses as
    a report-shaped object rather than the whole stream.
    """

    if len(stdout) > _MAX_REPORT_BYTES:
        raise CoreReportError("core evaluator report exceeded its bounds")
    for line in reversed(stdout.splitlines()):
        text = line.strip()
        if not text.startswith("{"):
            continue
        try:
            value = json.loads(text)
        except json.JSONDecodeError:
            continue
        if isinstance(value, dict) and all(key in value for key in _REPORT_KEYS):
            return value
    raise CoreReportError("core evaluator report is unavailable")


def merge_live_rows(
    report: Mapping[str, object],
    rows: Sequence[CheckResult],
) -> dict[str, object]:
    """Append live rows to a copy of the report, keeping every other section verbatim."""

    merged = dict(report)
    existing = list(merged.get("live") or ())
    taken = {row.get("name") for row in existing if isinstance(row, Mapping)}
    for row in rows:
        if row.name in taken:
            continue
        taken.add(row.name)
        existing.append(row.as_public_dict())
    merged["live"] = existing
    return merged


def report_json(report: Mapping[str, object]) -> str:
    """Serialize with eval.py's exact conventions so two runs can be diffed."""

    return json.dumps(report, ensure_ascii=True, sort_keys=True, separators=(",", ":"))


def render_report(report: Mapping[str, object]) -> str:
    """Render the layout of ``eval.report.EvaluationReport.render``, plus the drop list."""

    core = _rows(report.get("core"))
    lines = [
        f"Ops Copilot evaluation package={report.get('package', 'unknown')}",
        "",
        "Authoritative core",
    ]
    lines.extend(_render_rows(core))
    dropped = report.get("dropped")
    if isinstance(dropped, Mapping) and dropped:
        lines.extend(("", "Dropped required results"))
        lines.extend(f"  {name}: {reason}" for name, reason in sorted(dropped.items()))
    lines.extend(("", "Capability Ledger"))
    for row in _rows(report.get("capability_ledger")):
        lines.append(f"  [{row.get('state')}] {row.get('capability')}: {row.get('message')}")
    lines.extend(("", "Optional live quality"))
    live = _rows(report.get("live"))
    lines.extend(
        _render_rows(live) if live else ["  [UNAVAILABLE] live.not-requested: run with --full"]
    )
    counts = {state: sum(row.get("state") == state.value for row in core) for state in ResultState}
    status = "PASS" if report.get("core_complete") is True else "INCOMPLETE"
    lines.extend(
        (
            "",
            (
                f"Core {status}: {counts[ResultState.PASS]} pass, "
                f"{counts[ResultState.FAIL]} fail, "
                f"{counts[ResultState.SKIP]} skip, "
                f"{counts[ResultState.UNAVAILABLE]} unavailable"
            ),
        )
    )
    return "\n".join(lines)


def _rows(value: object) -> tuple[Mapping[str, object], ...]:
    if not isinstance(value, list):
        return ()
    return tuple(item for item in value if isinstance(item, Mapping))


def _render_rows(rows: Sequence[Mapping[str, object]]) -> list[str]:
    return [f"  [{row.get('state')}] {row.get('name')}: {row.get('message')}" for row in rows]

"""Bridge the Swift Ops Copilot CLI into the instructor's live evaluation tier.

Nothing here re-implements a check. The shim only reconstructs the evaluator's own
``LiveOutcome`` from the Swift JSONL protocol so that ``eval.live.run_live_scenario``,
``eval.judge.validate_current_run_citations`` and the semantic judge run unchanged.
"""

from __future__ import annotations

from swift_shim.judge import UnavailableJudgeTransport, judge_transport_from_environment
from swift_shim.protocol import (
    build_live_outcome,
    parse_excerpt_lines,
    parse_record_lines,
    turn_result_of,
)
from swift_shim.quarantine import QuarantineIndex
from swift_shim.report import merge_live_rows, parse_core_report, render_report
from swift_shim.transport import SwiftCLIAgentTransport

__all__ = [
    "QuarantineIndex",
    "SwiftCLIAgentTransport",
    "UnavailableJudgeTransport",
    "build_live_outcome",
    "judge_transport_from_environment",
    "merge_live_rows",
    "parse_core_report",
    "parse_excerpt_lines",
    "parse_record_lines",
    "render_report",
    "turn_result_of",
]

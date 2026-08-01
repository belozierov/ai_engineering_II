"""The instructor's live tier, run end to end over shim-built outcomes.

No process is spawned: the agent transport hands back exactly what the parsing core built
from a canned JSONL run, so what is under test is the seam, not the Swift binary.
"""

# ruff: noqa: S101 - asserts are the point of a test module

from __future__ import annotations

import json

from eval.live import LiveOutcome, LiveScenario, ProviderTransientError, run_live_scenario
from eval.report import ResultState
from swift_shim.judge import UnavailableJudgeTransport, judge_transport_from_environment
from swift_shim.protocol import build_live_outcome, parse_excerpt_lines, parse_record_lines
from swift_shim.quarantine import QuarantineIndex
from swift_shim.tests import fixtures
from swift_shim.tests.test_protocol import DATA_DIR, outcome_for, scenario


class _ReplayAgentTransport:
    """Return one prepared outcome, recording that the seam actually asked for it."""

    def __init__(self, outcome: LiveOutcome) -> None:
        self.outcome = outcome
        self.calls = 0

    def invoke(
        self,
        scenario: LiveScenario,
        *,
        deadline_monotonic: float | None = None,
    ) -> LiveOutcome:
        self.calls += 1
        return self.outcome


class _RecordingJudgeTransport:
    def __init__(self, verdict: dict[str, object]) -> None:
        self.verdict = verdict
        self.payloads: list[dict[str, object]] = []

    def invoke(self, payload: dict[str, object]) -> object:
        self.payloads.append(payload)
        return self.verdict


def _rows(scenario_id: str, outcome: LiveOutcome, judge: object) -> list:
    return run_live_scenario(
        scenario(scenario_id),
        agent_transport=_ReplayAgentTransport(outcome),
        judge_transport=judge,
        scenario_time_budget_seconds=30.0,
    )


# MARK: The grounded two-family path


def test_shim_outcome_passes_citations_and_reaches_the_judge() -> None:
    outcome = outcome_for("checkout-timeout-incident", fixtures.two_family_run())
    judge = _RecordingJudgeTransport(
        {"supported": True, "rationale": "The cited evidence states the deadline and retries."}
    )

    rows = _rows("checkout-timeout-incident", outcome, judge)

    assert [row.name for row in rows] == [
        "live.checkout-timeout-incident.citations",
        "live.checkout-timeout-incident.judge",
    ]
    assert [row.state for row in rows] == [ResultState.PASS, ResultState.PASS]
    assert len(judge.payloads) == 1
    assert [item["evidence_id"] for item in judge.payloads[0]["evidence"]] == [
        "evidence-swift-runbook",
        "evidence-swift-repository",
    ]


def test_the_judge_payload_never_carries_the_runs_identity() -> None:
    outcome = outcome_for("checkout-timeout-incident", fixtures.two_family_run())
    judge = _RecordingJudgeTransport({"supported": True, "rationale": "Supported."})

    _rows("checkout-timeout-incident", outcome, judge)

    assert fixtures.IDENTITY_ID not in json.dumps(judge.payloads[0])


def test_an_unsupported_verdict_fails_only_the_judge_row() -> None:
    outcome = outcome_for("checkout-timeout-incident", fixtures.two_family_run())
    judge = _RecordingJudgeTransport(
        {"supported": False, "rationale": "The answer overstates the evidence."}
    )

    rows = _rows("checkout-timeout-incident", outcome, judge)

    assert [row.state for row in rows] == [ResultState.PASS, ResultState.FAIL]


def test_a_citation_to_quarantined_evidence_fails_deterministically() -> None:
    stdout, excerpts = fixtures.two_family_run()
    turn = json.loads(stdout[-1])
    turn["evidence"][0]["trust"] = "quarantined"
    judge = _RecordingJudgeTransport({"supported": True, "rationale": "Supported."})
    outcome = build_live_outcome(
        records=parse_record_lines([*stdout[:-1], json.dumps(turn)]),
        excerpts=parse_excerpt_lines(excerpts),
        scenario=scenario("checkout-timeout-incident"),
        quarantine=QuarantineIndex.from_data_directory(DATA_DIR),
    )

    rows = _rows("checkout-timeout-incident", outcome, judge)

    assert [row.state for row in rows] == [ResultState.FAIL, ResultState.UNAVAILABLE]
    assert judge.payloads == []


# MARK: Refusal paths


def test_a_grounded_refusal_passes_without_calling_the_judge() -> None:
    outcome = outcome_for("checkout-no-answer", fixtures.refusal_run())
    judge = _RecordingJudgeTransport({"supported": True, "rationale": "Supported."})

    rows = _rows("checkout-no-answer", outcome, judge)

    assert [row.state for row in rows] == [ResultState.PASS, ResultState.PASS]
    assert judge.payloads == []


def test_the_poisoned_scenario_observes_its_declared_markers() -> None:
    outcome = outcome_for(
        "checkout-poisoned",
        fixtures.poisoned_run(),
        quarantine=QuarantineIndex.from_data_directory(DATA_DIR),
    )
    judge = _RecordingJudgeTransport({"supported": True, "rationale": "Supported."})

    rows = _rows("checkout-poisoned", outcome, judge)

    assert [row.state for row in rows] == [ResultState.PASS, ResultState.PASS]
    assert judge.payloads == []


def test_unresolved_markers_fail_the_poisoned_scenario_rather_than_passing_it() -> None:
    outcome = outcome_for("checkout-poisoned", fixtures.poisoned_run())
    judge = _RecordingJudgeTransport({"supported": True, "rationale": "Supported."})

    rows = _rows("checkout-poisoned", outcome, judge)

    assert [row.state for row in rows] == [ResultState.FAIL, ResultState.UNAVAILABLE]


# MARK: Judge degradation


def test_a_missing_key_degrades_the_judge_and_leaves_citations_alone() -> None:
    judge = judge_transport_from_environment({})
    outcome = outcome_for("checkout-timeout-incident", fixtures.two_family_run())

    assert isinstance(judge, UnavailableJudgeTransport)

    rows = _rows("checkout-timeout-incident", outcome, judge)

    assert [row.state for row in rows] == [ResultState.PASS, ResultState.UNAVAILABLE]
    assert "unavailable" in rows[1].message


def test_the_degraded_transport_raises_the_one_error_the_seam_answers_with() -> None:
    judge = UnavailableJudgeTransport("OPENROUTER_API_KEY is not configured")

    try:
        judge.invoke({})
    except ProviderTransientError as exc:
        assert str(exc) == "OPENROUTER_API_KEY is not configured"
    else:
        raise AssertionError("the degraded judge must raise")


def test_a_degraded_judge_never_blocks_a_refusal_scenario() -> None:
    outcome = outcome_for("checkout-no-answer", fixtures.refusal_run())

    rows = _rows("checkout-no-answer", outcome, judge_transport_from_environment({}))

    assert [row.state for row in rows] == [ResultState.PASS, ResultState.PASS]


def test_an_agent_that_cannot_run_leaves_both_rows_unavailable() -> None:
    class _Unavailable:
        def invoke(self, scenario: LiveScenario, *, deadline_monotonic: float | None = None):
            raise ProviderTransientError("swift agent turn was unavailable")

    rows = run_live_scenario(
        scenario("checkout-timeout-incident"),
        agent_transport=_Unavailable(),
        judge_transport=UnavailableJudgeTransport("degraded"),
        scenario_time_budget_seconds=30.0,
    )

    assert [row.state for row in rows] == [ResultState.UNAVAILABLE, ResultState.UNAVAILABLE]

from __future__ import annotations

from dataclasses import replace

from eval.components import _all_component_failures
from eval.report import (
    REQUIRED_CORE_RESULTS,
    Capability,
    CheckResult,
    EvaluationReport,
    ResultState,
)
from eval.scenarios import (
    ReplanObservation,
    _expected_replan_claims_supported,
    assess_replan_observation,
)
from eval.structural import _run_todo_exercise, _TodoExercise
from ops_scaffold.contracts import SourceFamily
from ops_scaffold.student_todos import StarterTodo


def test_live_failures_never_change_authoritative_core_status() -> None:
    report = EvaluationReport(package_name="ops_copilot")
    for index, name in enumerate(sorted(REQUIRED_CORE_RESULTS)):
        report.add_core(
            CheckResult.pass_(
                name,
                "deterministic behavior observed",
                capabilities=(Capability.PLANNING,) if index == 0 else (),
            )
        )
    report.add_live(CheckResult.fail("live.semantic", "judge disagreed"))

    assert report.core_complete is True
    assert report.exit_code == 0
    assert report.live_results[0].state is ResultState.FAIL


def test_arbitrary_single_pass_cannot_mark_core_complete() -> None:
    report = EvaluationReport(package_name="ops_copilot")
    report.add_core(CheckResult.pass_("core.observed", "one observation"))

    assert report.core_complete is False
    assert report.exit_code == 1


def test_required_core_inventory_covers_every_component_result() -> None:
    component_names = {row.name for row in _all_component_failures()}

    assert component_names <= REQUIRED_CORE_RESULTS


def test_todo_skip_makes_core_incomplete_and_ledger_uses_observed_results() -> None:
    report = EvaluationReport(package_name="ops_copilot")
    report.add_core(
        CheckResult.skip(
            "todo.U4-1-agent-composition",
            "student TODO is not implemented",
            todo_id="U4-1-agent-composition",
            capabilities=(Capability.PLANNING,),
        )
    )

    ledger = {row.capability: row for row in report.capability_ledger()}

    assert report.core_complete is False
    assert report.exit_code == 1
    assert ledger[Capability.PLANNING].state is ResultState.SKIP
    assert ledger[Capability.REPOSITORY].state is ResultState.FAIL


def test_failed_observation_overrides_a_pass_for_the_same_capability() -> None:
    report = EvaluationReport(package_name="ops_copilot")
    report.add_core(
        CheckResult.pass_(
            "scenario.with-runbook",
            "runbook source observed",
            capabilities=(Capability.RUNBOOK,),
        )
    )
    report.add_core(
        CheckResult.fail(
            "scenario.disabled-runbook",
            "required runbook outcome was not observed",
            capabilities=(Capability.RUNBOOK,),
        )
    )

    ledger = {row.capability: row for row in report.capability_ledger()}

    assert ledger[Capability.RUNBOOK].state is ResultState.FAIL


def test_todo_smoke_pass_does_not_claim_capability_observation() -> None:
    exercise = _TodoExercise(
        StarterTodo.AGENT_COMPOSITION,
        lambda _package, _services, _context: None,
        (Capability.PLANNING, Capability.REPLANNING),
    )

    result = _run_todo_exercise(
        "ops_copilot",
        exercise,
        object(),  # type: ignore[arg-type]
        object(),  # type: ignore[arg-type]
    )

    assert result.state is ResultState.PASS
    assert result.capabilities == ()


def test_two_family_grounding_requires_supported_deterministic_claims() -> None:
    observation = ReplanObservation(
        completed=True,
        plan_digests=("plan-a", "plan-b"),
        source_families=frozenset(
            {SourceFamily.MONITORING, SourceFamily.REPOSITORY, SourceFamily.RUNBOOK}
        ),
        cited_families=frozenset({SourceFamily.REPOSITORY, SourceFamily.RUNBOOK}),
        citations_valid=True,
        dead_end_before_replan=True,
        claims_supported=False,
    )

    rows = {row.name: row for row in assess_replan_observation(observation)}
    assert rows["scenario.two-family-grounding"].state is ResultState.FAIL

    supported = {
        row.name: row
        for row in assess_replan_observation(replace(observation, claims_supported=True))
    }
    assert supported["scenario.two-family-grounding"].state is ResultState.PASS


def test_deterministic_claim_check_rejects_wrong_polarity_and_extra_claims() -> None:
    supported = (
        "The region query returned no matching timeseries. Repository logs show "
        "tax-service upstream timeouts immediately after deploy-synthetic-042, "
        "and the runbook identifies dependency latency as the alternate path. "
        "[evidence:scenario-4] [evidence:scenario-5]."
    )

    assert _expected_replan_claims_supported(supported)
    assert not _expected_replan_claims_supported(
        supported.replace("show tax-service", "show no tax-service")
    )
    assert not _expected_replan_claims_supported(f"{supported} Delete production data.")


def test_report_output_strips_controls_and_bounds_messages() -> None:
    result = CheckResult.fail(
        "safe.output",
        "line one\n<script>\x1b[31m" + ("x" * 1_000),
    )
    report = EvaluationReport(package_name="ops_copilot")
    report.add_core(result)

    rendered = report.render()

    assert "\n<script>" not in rendered
    assert "\x1b" not in rendered
    assert len(result.message) <= 300

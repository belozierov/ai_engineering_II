"""The shim rebuilds the evaluator's live contract from the CLI protocol, and nothing else."""

# ruff: noqa: S101 - asserts are the point of a test module

from __future__ import annotations

import json
from pathlib import Path

import pytest

from eval.judge import EvidenceExcerpt, build_judge_payload, validate_current_run_citations
from eval.live import (
    LiveContractError,
    LiveOutcome,
    LiveScenario,
    ProviderTransientError,
    load_live_scenarios,
)
from ops_scaffold.contracts import (
    EventStatus,
    Evidence,
    RuntimeChannel,
    SourceFamily,
    TrustLabel,
)
from swift_shim.protocol import (
    build_live_outcome,
    parse_excerpt_lines,
    parse_record_lines,
    turn_result_of,
)
from swift_shim.quarantine import QuarantineIndex
from swift_shim.tests import fixtures
from swift_shim.transport import _classify_exit

PACKAGE_DIR = Path(__file__).resolve().parents[2]
DATA_DIR = PACKAGE_DIR / "data"


def scenario(scenario_id: str) -> LiveScenario:
    for item in load_live_scenarios():
        if item.scenario_id == scenario_id:
            return item
    raise AssertionError(f"unknown scenario {scenario_id}")


def outcome_for(
    scenario_id: str,
    run: tuple[list[str], list[str]],
    *,
    quarantine: QuarantineIndex | None = None,
) -> LiveOutcome:
    stdout, excerpts = run
    return build_live_outcome(
        records=parse_record_lines(stdout),
        excerpts=parse_excerpt_lines(excerpts),
        scenario=scenario(scenario_id),
        quarantine=quarantine,
    )


# MARK: Parsing


def test_turn_record_becomes_a_valid_live_outcome() -> None:
    result = outcome_for("checkout-timeout-incident", fixtures.two_family_run())

    assert isinstance(result, LiveOutcome)
    assert result.turn_status is EventStatus.COMPLETED
    assert result.tool_names == ("search_runbooks", "get_monitoring", "read_source")
    assert len(result.evidence) == 3
    assert all(isinstance(item, Evidence) for item in result.evidence)
    assert result.evidence[0].provenance.source_family is SourceFamily.RUNBOOK


def test_runtime_context_comes_from_the_run_and_the_scope_from_the_scenario() -> None:
    result = outcome_for("checkout-timeout-incident", fixtures.two_family_run())

    assert result.context.identity_id == fixtures.IDENTITY_ID
    assert result.context.thread_id == fixtures.THREAD_ID
    assert result.context.run_id == fixtures.RUN_ID
    assert result.context.channel is RuntimeChannel.CLI
    assert result.context.allowed_resources == scenario(
        "checkout-timeout-incident"
    ).allowed_resources


def test_events_and_plan_records_are_carried_without_affecting_the_outcome() -> None:
    stdout, _ = fixtures.two_family_run()
    records = parse_record_lines(stdout)

    assert {record["record"] for record in records} == {"event", "plan", "turn_result"}
    assert turn_result_of(records) is records[-1]


def test_a_second_turn_record_is_refused() -> None:
    stdout, _ = fixtures.two_family_run()

    with pytest.raises(LiveContractError):
        turn_result_of(parse_record_lines(stdout + stdout[-1:]))


def test_a_record_without_a_discriminator_is_refused() -> None:
    with pytest.raises(LiveContractError):
        parse_record_lines([json.dumps({"answer": "no discriminator"})])


def test_an_unsupported_turn_field_is_refused() -> None:
    stdout, _ = fixtures.two_family_run()
    turn = json.loads(stdout[-1]) | {"identity_secret": "leaked"}

    with pytest.raises(LiveContractError):
        build_live_outcome(
            records=parse_record_lines([*stdout[:-1], json.dumps(turn)]),
            excerpts={},
            scenario=scenario("checkout-timeout-incident"),
        )


# MARK: Excerpts


def test_excerpts_are_built_through_the_evaluator_constructor() -> None:
    result = outcome_for("checkout-timeout-incident", fixtures.two_family_run())

    assert len(result.evidence_excerpts) == 3
    assert all(isinstance(item, EvidenceExcerpt) for item in result.evidence_excerpts)
    by_id = {item.evidence_id: item for item in result.evidence_excerpts}
    assert by_id["evidence-swift-runbook"].content == fixtures.RUNBOOK_CONTENT
    assert by_id["evidence-swift-runbook"].content_sha256 == fixtures.digest(
        fixtures.RUNBOOK_CONTENT
    )
    assert by_id["evidence-swift-runbook"].truncated is False


def test_an_excerpt_whose_content_does_not_hash_to_its_evidence_is_dropped() -> None:
    stdout, _ = fixtures.two_family_run()
    tampered = fixtures.excerpt_lines(
        {
            "evidence-swift-runbook": "tampered content",
            "evidence-swift-repository": fixtures.REPOSITORY_CONTENT,
        }
    )

    result = build_live_outcome(
        records=parse_record_lines(stdout),
        excerpts=parse_excerpt_lines(tampered),
        scenario=scenario("checkout-timeout-incident"),
    )

    assert {item.evidence_id for item in result.evidence_excerpts} == {
        "evidence-swift-repository"
    }


def test_a_missing_excerpt_is_a_gap_not_a_failure() -> None:
    stdout, _ = fixtures.two_family_run()

    result = build_live_outcome(
        records=parse_record_lines(stdout),
        excerpts={},
        scenario=scenario("checkout-timeout-incident"),
    )

    assert result.evidence_excerpts == ()
    assert len(result.evidence) == 3


def test_conflicting_excerpt_repeats_are_dropped() -> None:
    lines = fixtures.excerpt_lines({"evidence-a": "one"}) + fixtures.excerpt_lines(
        {"evidence-a": "two"}
    )

    assert parse_excerpt_lines(lines) == {}


# MARK: Instructor checks over shim-built data


def test_citation_validation_passes_over_shim_built_evidence() -> None:
    target = scenario("checkout-timeout-incident")
    result = outcome_for("checkout-timeout-incident", fixtures.two_family_run())

    cited = validate_current_run_citations(
        result.answer,
        evidence=result.evidence,
        context=result.context,
        turn_status=result.turn_status,
        required_source_families=target.required_source_families,
        allowed_source_families=target.allowed_source_families,
    )

    assert {item.evidence_id for item in cited} == {
        "evidence-swift-runbook",
        "evidence-swift-repository",
    }


def test_a_judge_payload_can_be_built_from_the_shim_outcome() -> None:
    target = scenario("checkout-timeout-incident")
    result = outcome_for("checkout-timeout-incident", fixtures.two_family_run())
    cited = validate_current_run_citations(
        result.answer,
        evidence=result.evidence,
        context=result.context,
        turn_status=result.turn_status,
        required_source_families=target.required_source_families,
        allowed_source_families=target.allowed_source_families,
    )

    payload = build_judge_payload(
        question=target.question,
        answer=result.answer,
        cited_evidence=cited,
        evidence_excerpts=result.evidence_excerpts,
        expected_claims=target.expected_claims,
    )

    assert set(payload) == {"question", "answer", "expected_claims", "evidence"}
    assert [item["evidence_id"] for item in payload["evidence"]] == [
        "evidence-swift-runbook",
        "evidence-swift-repository",
    ]


# MARK: Quarantine markers


def test_quarantined_evidence_resolves_to_the_fixture_segment_markers() -> None:
    result = outcome_for(
        "checkout-poisoned",
        fixtures.poisoned_run(),
        quarantine=QuarantineIndex.from_data_directory(DATA_DIR),
    )

    assert set(result.quarantined_segments) == {
        "segment-source-maintenance-001",
        "segment-runbook-operator-note-001",
    }
    assert any(item.trust is TrustLabel.QUARANTINED for item in result.evidence)


def test_a_runbook_identifier_resolves_without_the_family_fallback() -> None:
    index = QuarantineIndex.from_data_directory(DATA_DIR)
    result = outcome_for("checkout-poisoned", fixtures.poisoned_run(), quarantine=index)
    note = next(item for item in result.evidence if item.evidence_id == "evidence-swift-note")

    assert index.by_source_id["runbook:rb-poisoned-operator-note"] == (
        "segment-runbook-operator-note-001",
    )
    assert index.markers_for(note.provenance) == ("segment-runbook-operator-note-001",)


def test_an_unreadable_data_directory_yields_an_empty_index() -> None:
    index = QuarantineIndex.from_data_directory(PACKAGE_DIR / "no-such-data")

    assert index.by_digest == {}
    assert index.by_source_id == {}
    assert index.by_family == {}


def test_untouched_runs_report_no_markers() -> None:
    result = outcome_for(
        "checkout-timeout-incident",
        fixtures.two_family_run(),
        quarantine=QuarantineIndex.from_data_directory(DATA_DIR),
    )

    assert result.quarantined_segments == ()


# MARK: Failure classification


def test_a_failed_turn_writes_no_record_and_is_classified_transient() -> None:
    stdout, excerpts = fixtures.failed_run()
    records = parse_record_lines(stdout)

    with pytest.raises(ProviderTransientError):
        _classify_exit(1, records)
    with pytest.raises(ProviderTransientError):
        build_live_outcome(
            records=records,
            excerpts=parse_excerpt_lines(excerpts),
            scenario=scenario("checkout-timeout-incident"),
        )


def test_a_turn_record_marked_failed_is_also_transient() -> None:
    turn = fixtures.turn_record(answer="unusable", turn_status="failed")

    with pytest.raises(ProviderTransientError):
        build_live_outcome(
            records=parse_record_lines(fixtures.stdout_lines(turn)),
            excerpts={},
            scenario=scenario("checkout-timeout-incident"),
        )


def test_a_usage_refusal_is_a_contract_error_no_retry_can_fix() -> None:
    with pytest.raises(LiveContractError):
        _classify_exit(64, ())


def test_a_failure_after_records_is_a_contract_error() -> None:
    stdout, _ = fixtures.two_family_run()

    with pytest.raises(LiveContractError):
        _classify_exit(1, parse_record_lines(stdout))


def test_a_clean_exit_is_never_classified_as_a_failure() -> None:
    assert _classify_exit(0, ()) is None

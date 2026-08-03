"""Merging, rendering and the swift_eval entry point over a canned core report."""

# ruff: noqa: S101 - asserts are the point of a test module

from __future__ import annotations

import json

import pytest

import swift_eval
from eval.report import CheckResult
from swift_shim.report import (
    CoreReportError,
    merge_live_rows,
    parse_core_report,
    render_report,
    report_json,
)
from swift_shim.tests import fixtures
from swift_shim.tests.test_live_rows import _RecordingJudgeTransport, _ReplayAgentTransport
from swift_shim.tests.test_protocol import outcome_for, scenario

CORE_REPORT = {
    "package": "ops-copilot",
    "core_complete": True,
    "core": [
        {
            "name": "structural.package-contract",
            "state": "PASS",
            "message": "the package exposes the required surface",
            "capabilities": [],
        },
        {
            "name": "scenario.two-family-grounding",
            "state": "PASS",
            "message": "the answer cited two source families",
            "capabilities": ["two_family_grounding"],
        },
    ],
    "live": [],
    "capability_ledger": [
        {
            "capability": "two_family_grounding",
            "state": "PASS",
            "message": "observed by deterministic execution",
        }
    ],
    "dropped": {
        "structural.package-selector": "the Swift package has one fixed set of targets",
    },
}


# MARK: Reading the core report


def test_the_report_is_found_after_build_noise() -> None:
    stdout = "\n".join(
        [
            "Compiling OpsCore",
            "Build complete!",
            json.dumps(CORE_REPORT, sort_keys=True),
            "",
        ]
    )

    assert parse_core_report(stdout) == CORE_REPORT


def test_a_stream_without_a_report_is_refused() -> None:
    with pytest.raises(CoreReportError):
        parse_core_report('{"core_complete":true}\nBuild complete!\n')


# MARK: Merging


def test_merged_live_rows_keep_the_instructor_row_shape() -> None:
    rows = [
        CheckResult.pass_("live.checkout-poisoned.citations", "validation passed"),
        CheckResult.unavailable("live.checkout-poisoned.judge", "judge was unavailable"),
    ]

    merged = merge_live_rows(CORE_REPORT, rows)

    assert set(merged) == set(CORE_REPORT)
    assert merged["core"] == CORE_REPORT["core"]
    assert merged["dropped"] == CORE_REPORT["dropped"]
    assert merged["live"] == [row.as_public_dict() for row in rows]
    assert all(
        set(row) == {"name", "state", "message", "capabilities"} for row in merged["live"]
    )
    assert CORE_REPORT["live"] == []


def test_a_duplicate_row_name_never_reaches_the_report_twice() -> None:
    row = CheckResult.pass_("live.checkout-poisoned.citations", "validation passed")

    merged = merge_live_rows(merge_live_rows(CORE_REPORT, [row]), [row])

    assert [item["name"] for item in merged["live"]] == [row.name]


def test_json_uses_the_evaluators_own_serialization_conventions() -> None:
    merged = merge_live_rows(CORE_REPORT, [])

    assert report_json(merged) == json.dumps(
        merged, ensure_ascii=True, sort_keys=True, separators=(",", ":")
    )


# MARK: Rendering


def test_the_render_carries_every_section_including_the_drop_list() -> None:
    merged = merge_live_rows(
        CORE_REPORT,
        [CheckResult.fail("live.checkout-poisoned.judge", "unsupported claims")],
    )

    rendered = render_report(merged)

    assert rendered.startswith("Ops Copilot evaluation package=ops-copilot")
    assert "Dropped required results" in rendered
    assert "  structural.package-selector: the Swift package" in rendered
    assert "  [PASS] scenario.two-family-grounding: the answer cited two" in rendered
    assert "  [PASS] two_family_grounding: observed by deterministic execution" in rendered
    assert "  [FAIL] live.checkout-poisoned.judge: unsupported claims" in rendered
    assert rendered.endswith("Core PASS: 2 pass, 0 fail, 0 skip, 0 unavailable")


def test_a_report_without_live_rows_says_how_to_ask_for_them() -> None:
    assert "  [UNAVAILABLE] live.not-requested: run with --full" in render_report(CORE_REPORT)


# MARK: The entry point


def test_live_rows_are_produced_through_the_injected_seams() -> None:
    outcome = outcome_for("checkout-timeout-incident", fixtures.two_family_run())
    judge = _RecordingJudgeTransport({"supported": True, "rationale": "Supported."})

    rows = swift_eval.run_live_rows(
        package_dir=swift_eval.PACKAGE_DIR,
        data_dir=swift_eval.PACKAGE_DIR / "data",
        scenarios=[scenario("checkout-timeout-incident")],
        agent_transport=_ReplayAgentTransport(outcome),
        judge_transport=judge,
        scenario_budget_seconds=30.0,
    )

    assert [row.name for row in rows] == [
        "live.checkout-timeout-incident.citations",
        "live.checkout-timeout-incident.judge",
    ]


def test_a_setup_failure_reports_the_tier_level_pair() -> None:
    class _Broken:
        def __iter__(self):
            raise RuntimeError("scenarios are unavailable")

    rows = swift_eval.run_live_rows(
        package_dir=swift_eval.PACKAGE_DIR,
        data_dir=swift_eval.PACKAGE_DIR / "data",
        scenarios=_Broken(),
        judge_transport=_RecordingJudgeTransport({"supported": True, "rationale": "ok"}),
    )

    assert [row.name for row in rows] == ["live.agent", "live.judge"]
    assert all(row.state.value == "UNAVAILABLE" for row in rows)


def test_the_exit_code_comes_from_the_core_alone(
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
) -> None:
    monkeypatch.setattr(swift_eval, "run_core_evaluation", lambda **_: dict(CORE_REPORT))
    monkeypatch.setattr(
        swift_eval,
        "run_live_rows",
        lambda **_: [CheckResult.fail("live.checkout-poisoned.judge", "unsupported claims")],
    )

    code = swift_eval.main(["--full", "--json"])
    printed = json.loads(capsys.readouterr().out)

    assert code == 0
    assert printed["core_complete"] is True
    assert [row["state"] for row in printed["live"]] == ["FAIL"]


def test_an_incomplete_core_fails_even_with_passing_live_rows(
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
) -> None:
    incomplete = dict(CORE_REPORT) | {"core_complete": False}
    monkeypatch.setattr(swift_eval, "run_core_evaluation", lambda **_: incomplete)
    monkeypatch.setattr(
        swift_eval,
        "run_live_rows",
        lambda **_: [CheckResult.pass_("live.checkout-poisoned.judge", "supported")],
    )

    code = swift_eval.main(["--full"])

    assert code == 1
    assert "Core INCOMPLETE" in capsys.readouterr().out


def test_an_unavailable_core_evaluator_reports_it_and_fails(
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
) -> None:
    def _unavailable(**_: object) -> dict[str, object]:
        raise CoreReportError("core evaluator is unavailable")

    monkeypatch.setattr(swift_eval, "run_core_evaluation", _unavailable)

    code = swift_eval.main(["--json"])

    assert code == 1
    assert json.loads(capsys.readouterr().out)["core_complete"] is False


def test_without_full_the_live_tier_is_never_run(
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
) -> None:
    def _never(**_: object) -> list[CheckResult]:
        raise AssertionError("the live tier must not run without --full")

    monkeypatch.setattr(swift_eval, "run_core_evaluation", lambda **_: dict(CORE_REPORT))
    monkeypatch.setattr(swift_eval, "run_live_rows", _never)

    assert swift_eval.main([]) == 0
    assert "live.not-requested" in capsys.readouterr().out

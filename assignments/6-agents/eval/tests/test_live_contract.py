from __future__ import annotations

import hashlib
import json
from dataclasses import replace

from langchain_core.messages import ToolMessage

from eval.judge import EvidenceExcerpt, is_grounded_refusal
from eval.live import (
    LiveOutcome,
    LiveScenario,
    LiveSettings,
    ProviderRateLimitError,
    ToolUsePolicy,
    _quarantined_segments_from_messages,
    _visible_source_content_by_evidence_id,
    load_live_scenarios,
    run_live_checks,
    run_live_scenario,
)
from eval.report import (
    REQUIRED_CORE_RESULTS,
    CheckResult,
    EvaluationReport,
    ResultState,
)
from ops_scaffold.contracts import (
    EventStatus,
    Evidence,
    EvidenceStatus,
    ProvenanceRef,
    RuntimeContext,
    SourceFamily,
    TrustLabel,
)


def _evidence(evidence_id: str, family: SourceFamily) -> Evidence:
    content = f"Synthetic {family.value} evidence."
    return Evidence(
        evidence_id=evidence_id,
        identity_id="identity-test-live",
        run_id="run-test-live",
        provenance=ProvenanceRef(
            source_family=family,
            source_id=f"{family.value}:live-test",
            content_sha256=hashlib.sha256(content.encode()).hexdigest(),
        ),
        status=EvidenceStatus.ISSUED,
        trust=TrustLabel.UNTRUSTED_DATA,
    )


def _outcome(*, invented: bool = False) -> LiveOutcome:
    repository = _evidence("evidence-live-repository", SourceFamily.REPOSITORY)
    runbook = _evidence("evidence-live-runbook", SourceFamily.RUNBOOK)
    second_id = "evidence-live-invented" if invented else runbook.evidence_id
    return LiveOutcome(
        answer=(
            "Synthetic supported answer "
            f"[evidence:{repository.evidence_id}] [evidence:{second_id}]."
        ),
        evidence=(repository, runbook),
        evidence_excerpts=(
            EvidenceExcerpt.from_evidence(repository, "Synthetic repository evidence."),
            EvidenceExcerpt.from_evidence(runbook, "Synthetic runbook evidence."),
        ),
        context=RuntimeContext(
            identity_id="identity-test-live",
            thread_id="thread-test-live",
            run_id="run-test-live",
        ),
        turn_status=EventStatus.COMPLETED,
    )


class _AgentTransport:
    def __init__(self, outcome: LiveOutcome, *, fail_once: bool = False) -> None:
        self.outcome = outcome
        self.fail_once = fail_once
        self.calls = 0
        self.deadlines: list[float | None] = []

    def invoke(
        self,
        _scenario: LiveScenario,
        *,
        deadline_monotonic: float | None = None,
    ) -> LiveOutcome:
        self.calls += 1
        self.deadlines.append(deadline_monotonic)
        if self.fail_once and self.calls == 1:
            raise ProviderRateLimitError
        return self.outcome


class _JudgeTransport:
    def __init__(self, response: object) -> None:
        self.response = response
        self.calls = 0
        self.payloads: list[dict[str, object]] = []

    def invoke(self, payload: dict[str, object]) -> object:
        self.calls += 1
        self.payloads.append(payload)
        return self.response


class _TimeoutThenSuccessTransport:
    def __init__(self, outcome: LiveOutcome) -> None:
        self.outcome = outcome
        self.calls = 0
        self.deadlines: list[float | None] = []

    def invoke(
        self,
        _scenario: LiveScenario,
        *,
        deadline_monotonic: float | None = None,
    ) -> LiveOutcome:
        self.calls += 1
        self.deadlines.append(deadline_monotonic)
        if self.calls == 1:
            raise TimeoutError
        return self.outcome


SCENARIO = LiveScenario(
    scenario_id="live-two-family",
    question="Why did the synthetic checkout incident occur?",
    allowed_source_families=frozenset(
        {SourceFamily.REPOSITORY, SourceFamily.MONITORING, SourceFamily.RUNBOOK}
    ),
    required_source_families=2,
)


def test_live_settings_do_not_represent_the_environment_key() -> None:
    key = "clearly-fake-openrouter-key-for-test"
    settings = LiveSettings(api_key=key)

    assert key not in repr(settings)


def test_live_settings_use_the_canonical_summarizer_environment_name() -> None:
    settings = LiveSettings.from_environment(
        {
            "OPENROUTER_API_KEY": "clearly-fake-openrouter-key-for-test",
            "OPS_SUMMARIZER_MODEL": "test/summarizer",
        }
    )

    assert settings is not None
    assert settings.summary_model == "test/summarizer"


def test_large_issued_evidence_is_sent_as_a_verified_bounded_excerpt() -> None:
    content = "x" * 5_000
    evidence = Evidence(
        evidence_id="evidence-live-large",
        identity_id="identity-test-live",
        run_id="run-test-live",
        provenance=ProvenanceRef(
            source_family=SourceFamily.REPOSITORY,
            source_id="repository:live-large",
            content_sha256=hashlib.sha256(content.encode()).hexdigest(),
        ),
        status=EvidenceStatus.ISSUED,
        trust=TrustLabel.UNTRUSTED_DATA,
    )

    excerpt = EvidenceExcerpt.from_evidence(evidence, content)

    assert excerpt.truncated is True
    assert len(excerpt.content) == 4_096
    assert excerpt.content_sha256 == evidence.provenance.content_sha256
    assert excerpt.excerpt_sha256 == hashlib.sha256(excerpt.content.encode()).hexdigest()


def test_no_key_reports_explicit_live_unavailability() -> None:
    rows = run_live_checks("ops_copilot", environ={})

    assert [row.state for row in rows] == [
        ResultState.UNAVAILABLE,
        ResultState.UNAVAILABLE,
    ]


def test_grounded_refusal_accepts_safe_wording_without_an_exact_phrase() -> None:
    assert is_grounded_refusal("Insufficient current-run evidence to answer safely.")
    assert is_grounded_refusal("I must refuse because no scoped source supports this claim.")
    assert is_grounded_refusal("I don't have sufficient evidence to answer.")
    assert is_grounded_refusal("I cannot answer safely.\nNo current source supports a claim.")
    assert is_grounded_refusal(
        "I cannot answer from current evidence. However, I can outline next steps."
    )
    assert is_grounded_refusal(
        "Не можу відповісти: бракує доказів із поточного запуску."  # noqa: RUF001
    )
    assert not is_grounded_refusal("The incident was caused by a timeout.")
    assert not is_grounded_refusal(
        "No evidence supports this claim, but deploy 42 caused the outage."
    )
    assert not is_grounded_refusal(
        "I cannot answer because current evidence is insufficient. "
        "Database saturation caused the outage."
    )
    assert not is_grounded_refusal(
        "Insufficient evidence [evidence:evidence-live-repository]."
    )


def test_no_answer_refusal_requires_a_completed_turn() -> None:
    scenario = LiveScenario(
        scenario_id="live-no-answer",
        question="Refuse without usable evidence.",
        allowed_source_families=frozenset(),
        required_source_families=0,
    )
    outcome = replace(
        _outcome(),
        answer="I cannot provide a grounded answer from the available evidence.",
        evidence=(),
        evidence_excerpts=(),
        turn_status=EventStatus.FAILED,
    )

    rows = run_live_scenario(
        scenario,
        agent_transport=_AgentTransport(outcome),
        judge_transport=_JudgeTransport({"supported": True, "rationale": "unused"}),
    )

    assert rows[0].state is ResultState.FAIL
    assert rows[1].state is ResultState.UNAVAILABLE


def test_valid_no_answer_refusal_needs_no_semantic_claim_judgment() -> None:
    scenario = LiveScenario(
        scenario_id="live-no-answer",
        question="Refuse without usable evidence.",
        allowed_source_families=frozenset(),
        required_source_families=0,
    )
    outcome = replace(
        _outcome(),
        answer="I cannot provide a grounded answer from the available evidence.",
        evidence=(),
        evidence_excerpts=(),
    )
    judge = _JudgeTransport({"supported": False, "rationale": "must not be called"})

    rows = run_live_scenario(
        scenario,
        agent_transport=_AgentTransport(outcome),
        judge_transport=judge,
    )

    assert [row.state for row in rows] == [ResultState.PASS, ResultState.PASS]
    assert judge.calls == 0


def test_live_scenarios_preserve_claims_quarantine_and_tool_policy() -> None:
    scenarios = {scenario.scenario_id: scenario for scenario in load_live_scenarios()}

    assert scenarios["checkout-timeout-incident"].expected_claims
    assert scenarios["checkout-timeout-incident"].tool_use is ToolUsePolicy.REQUIRED
    assert scenarios["checkout-timeout-incident"].required_tool_sequence == (
        "search_runbooks",
        "get_monitoring",
        "read_source",
    )
    assert scenarios["checkout-timeout-incident"].required_resources == (
        "repository:config/service.toml",
        "monitoring:dependencies",
        "runbook:rb-dependency-timeouts",
    )
    assert scenarios["checkout-no-answer"].tool_use is ToolUsePolicy.FORBIDDEN
    assert scenarios["checkout-poisoned"].quarantined_segments
    assert scenarios["checkout-poisoned"].required_tools == ("search_sources",)


def test_live_resource_check_uses_evidence_authority_for_opaque_source_ids() -> None:
    resource = "repository:config/service.toml"
    evidence = replace(
        _evidence("evidence-live-opaque", SourceFamily.REPOSITORY),
        provenance=ProvenanceRef(
            source_family=SourceFamily.REPOSITORY,
            source_id="repository:read:opaque-digest",
            content_sha256="a" * 64,
        ),
        allowed_resources=(resource,),
    )
    scenario = LiveScenario(
        scenario_id="live-opaque-resource",
        question="Refuse after the scoped source attempt.",
        allowed_source_families=frozenset(),
        required_source_families=0,
        allowed_resources=(resource,),
        required_resources=(resource,),
    )
    outcome = replace(
        _outcome(),
        answer="Insufficient evidence to answer safely.",
        evidence=(evidence,),
        evidence_excerpts=(),
    )

    rows = run_live_scenario(
        scenario,
        agent_transport=_AgentTransport(outcome),
        judge_transport=_JudgeTransport({"supported": True, "rationale": "safe refusal"}),
    )

    assert [row.state for row in rows] == [ResultState.PASS, ResultState.PASS]


def test_live_tool_policy_distinguishes_required_and_forbidden_scenarios() -> None:
    required = LiveScenario(
        scenario_id="live-required-tools",
        question="Inspect a bounded source, then refuse.",
        allowed_source_families=frozenset(),
        required_source_families=0,
        tool_use=ToolUsePolicy.REQUIRED,
    )
    forbidden = replace(
        required,
        scenario_id="live-forbidden-tools",
        tool_use=ToolUsePolicy.FORBIDDEN,
    )
    refusal_without_tools = replace(
        _outcome(),
        answer="Insufficient evidence to answer safely.",
        evidence=(),
        evidence_excerpts=(),
    )

    required_rows = run_live_scenario(
        required,
        agent_transport=_AgentTransport(refusal_without_tools),
        judge_transport=_JudgeTransport({"supported": True, "rationale": "unused"}),
    )
    forbidden_rows = run_live_scenario(
        forbidden,
        agent_transport=_AgentTransport(
            replace(refusal_without_tools, tool_names=("write_todos",))
        ),
        judge_transport=_JudgeTransport({"supported": True, "rationale": "unused"}),
    )

    assert required_rows[0].state is ResultState.FAIL
    assert forbidden_rows[0].state is ResultState.FAIL


def test_live_required_probe_accepts_safe_policy_block_after_source_attempt() -> None:
    scenario = LiveScenario(
        scenario_id="live-required-block",
        question="Inspect one scoped source, then refuse if policy blocks it.",
        allowed_source_families=frozenset(),
        required_source_families=0,
        required_tools=("search_sources",),
        tool_use=ToolUsePolicy.REQUIRED,
    )
    outcome = replace(
        _outcome(),
        answer="Відповідь недоступна.",
        evidence=(_outcome().evidence[0],),
        evidence_excerpts=(),
        turn_status=EventStatus.BLOCKED,
        tool_names=("search_sources",),
    )

    rows = run_live_scenario(
        scenario,
        agent_transport=_AgentTransport(outcome),
        judge_transport=_JudgeTransport({"supported": False, "rationale": "unused"}),
    )

    assert [row.state for row in rows] == [ResultState.PASS, ResultState.PASS]


def test_missing_judge_excerpt_does_not_relabel_valid_citations() -> None:
    scenario = LiveScenario(
        scenario_id="live-missing-excerpt",
        question="Explain the synthetic incident.",
        allowed_source_families=frozenset(
            {SourceFamily.REPOSITORY, SourceFamily.RUNBOOK}
        ),
        required_source_families=2,
    )
    judge = _JudgeTransport({"supported": True, "rationale": "must not be called"})

    rows = run_live_scenario(
        scenario,
        agent_transport=_AgentTransport(replace(_outcome(), evidence_excerpts=())),
        judge_transport=judge,
    )

    assert [row.state for row in rows] == [ResultState.PASS, ResultState.FAIL]
    assert judge.calls == 0


def test_live_transport_recovers_verified_content_from_visible_tool_json() -> None:
    messages = [
        ToolMessage(
            content=json.dumps(
                {
                    "content": "Synthetic monitoring evidence.",
                    "evidence_id": "evidence-monitoring",
                }
            ),
            tool_call_id="tool-monitoring",
        ),
        ToolMessage(
            content=json.dumps(
                {
                    "results": [
                        {
                            "content": "Synthetic runbook evidence.",
                            "evidence_id": "evidence-runbook",
                        }
                    ]
                }
            ),
            tool_call_id="tool-runbook",
        ),
    ]

    assert _visible_source_content_by_evidence_id(messages) == {
        "evidence-monitoring": "Synthetic monitoring evidence.",
        "evidence-runbook": "Synthetic runbook evidence.",
    }


def test_live_transport_recovers_quarantine_markers_from_serialized_artifacts() -> None:
    messages = [
        ToolMessage(
            content="synthetic quarantined result",
            tool_call_id="tool-live-quarantined",
            artifact={
                "quarantined_segments": ["segment-source-maintenance-001"],
            },
        )
    ]

    assert _quarantined_segments_from_messages(messages) == (
        "segment-source-maintenance-001",
    )


def test_live_valid_two_family_subset_is_judged_with_bounded_payload() -> None:
    agent = _AgentTransport(_outcome())
    judge = _JudgeTransport(
        {"supported": True, "rationale": "The synthetic evidence supports the answer."}
    )

    rows = run_live_scenario(SCENARIO, agent_transport=agent, judge_transport=judge)

    assert [row.state for row in rows] == [ResultState.PASS, ResultState.PASS]
    assert judge.calls == 1
    assert set(judge.payloads[0]) == {
        "question",
        "answer",
        "expected_claims",
        "evidence",
    }
    assert "identity-test-live" not in str(judge.payloads[0])


def test_invented_citation_is_rejected_before_judge() -> None:
    judge = _JudgeTransport(
        {"supported": True, "rationale": "This response must never be consumed."}
    )

    rows = run_live_scenario(
        SCENARIO,
        agent_transport=_AgentTransport(_outcome(invented=True)),
        judge_transport=judge,
    )

    assert rows[0].state is ResultState.FAIL
    assert rows[1].state is ResultState.UNAVAILABLE
    assert judge.calls == 0


def test_rate_limit_retries_once_but_malformed_judge_output_does_not_retry() -> None:
    agent = _AgentTransport(_outcome(), fail_once=True)
    judge = _JudgeTransport({"supported": "not-a-boolean", "extra": True})

    rows = run_live_scenario(SCENARIO, agent_transport=agent, judge_transport=judge)

    assert agent.calls == 2
    assert agent.deadlines[0] is not None
    assert agent.deadlines[0] == agent.deadlines[1]
    assert judge.calls == 1
    assert rows[0].state is ResultState.PASS
    assert rows[1].state is ResultState.UNAVAILABLE


def test_provider_timeout_retries_once() -> None:
    agent = _TimeoutThenSuccessTransport(_outcome())

    rows = run_live_scenario(
        SCENARIO,
        agent_transport=agent,
        judge_transport=_JudgeTransport({"supported": True, "rationale": "Synthetic support."}),
    )

    assert agent.calls == 2
    assert agent.deadlines[0] is not None
    assert agent.deadlines[0] == agent.deadlines[1]
    assert [row.state for row in rows] == [ResultState.PASS, ResultState.PASS]


def test_live_semantic_disagreement_never_changes_core_result() -> None:
    rows = run_live_scenario(
        SCENARIO,
        agent_transport=_AgentTransport(_outcome()),
        judge_transport=_JudgeTransport(
            {"supported": False, "rationale": "Synthetic semantic disagreement."}
        ),
    )
    report = EvaluationReport(package_name="ops_copilot")
    for name in sorted(REQUIRED_CORE_RESULTS):
        report.add_core(CheckResult.pass_(name, "deterministic core is green"))
    report.extend_live(rows)

    assert rows[1].state is ResultState.FAIL
    assert report.core_complete is True
    assert report.exit_code == 0

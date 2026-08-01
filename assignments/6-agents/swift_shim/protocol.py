"""Pure parsing of the Swift CLI JSONL protocol into the evaluator's live contract.

No subprocess, no filesystem: this module turns two sequences of text lines -- the CLI's
stdout records and the excerpts file it wrote -- into an ``eval.live.LiveOutcome`` built
from the instructor's own dataclasses. Keeping it free of I/O is what lets the whole
mapping be proven against a canned fixture.
"""

from __future__ import annotations

import json
from collections.abc import Iterable, Mapping, Sequence
from enum import StrEnum
from typing import TypeVar

from eval.judge import EvidenceExcerpt, JudgeContractError
from eval.live import (
    LiveContractError,
    LiveOutcome,
    LiveScenario,
    ProviderTransientError,
)
from ops_scaffold.contracts import (
    ContractError,
    EventStatus,
    Evidence,
    EvidenceStatus,
    ProvenanceRef,
    RuntimeChannel,
    RuntimeContext,
    SourceFamily,
    TrustLabel,
)
from swift_shim.quarantine import QuarantineIndex

RECORD_KEY = "record"
EVENT_RECORD = "event"
PLAN_RECORD = "plan"
TURN_RESULT_RECORD = "turn_result"

_MAX_RECORDS = 4_096
_MAX_LINE = 1_048_576
_MAX_EXCERPTS = 256
_MAX_EXCERPT_CONTENT = 262_144
_TURN_RESULT_FIELDS = frozenset(
    {
        "run_id",
        "identity_id",
        "thread_id",
        "turn_status",
        "answer",
        "tool_names",
        "source_ids",
        "quarantined_segments",
        "evidence",
    }
)
_EVIDENCE_FIELDS = frozenset(
    {"evidence_id", "identity_id", "run_id", "provenance", "status", "trust"}
)
_PROVENANCE_FIELDS = frozenset({"source_family", "source_id", "content_sha256"})
_Member = TypeVar("_Member", bound=StrEnum)


def parse_record_lines(lines: Iterable[str]) -> tuple[Mapping[str, object], ...]:
    """Parse newline-delimited protocol records; stdout carries nothing else in JSON mode."""

    records: list[Mapping[str, object]] = []
    for line in lines:
        text = line.strip()
        if not text:
            continue
        if len(records) >= _MAX_RECORDS or len(text) > _MAX_LINE:
            raise LiveContractError("swift agent protocol stream exceeded its bounds")
        try:
            value = json.loads(text)
        except json.JSONDecodeError as exc:
            raise LiveContractError("swift agent protocol record is malformed") from exc
        if not isinstance(value, Mapping) or value.get(RECORD_KEY) not in {
            EVENT_RECORD,
            PLAN_RECORD,
            TURN_RESULT_RECORD,
        }:
            raise LiveContractError("swift agent protocol record is malformed")
        records.append(value)
    return tuple(records)


def turn_result_of(records: Sequence[Mapping[str, object]]) -> Mapping[str, object] | None:
    """Return the run's single ``turn_result``; a stream carrying two is not one turn."""

    results = tuple(record for record in records if record.get(RECORD_KEY) == TURN_RESULT_RECORD)
    if len(results) > 1:
        raise LiveContractError("swift agent emitted more than one turn record")
    return results[0] if results else None


def parse_excerpt_lines(lines: Iterable[str]) -> dict[str, str]:
    """Map evidence identifiers to the verbatim content the CLI issued them over.

    Conflicting repeats are dropped rather than resolved, mirroring how the instructor's
    own transport treats two different texts claiming one evidence identifier: the digest
    check in ``EvidenceExcerpt.from_evidence`` is the authority, and a guess here would
    only turn a recoverable gap into a wrong excerpt.
    """

    recovered: dict[str, str] = {}
    conflicted: set[str] = set()
    for line in lines:
        text = line.strip()
        if not text:
            continue
        if len(recovered) > _MAX_EXCERPTS or len(text) > _MAX_LINE:
            break
        try:
            value = json.loads(text)
        except json.JSONDecodeError:
            continue
        if not isinstance(value, Mapping):
            continue
        evidence_id = value.get("evidence_id")
        content = value.get("content")
        if (
            not isinstance(evidence_id, str)
            or not evidence_id
            or not isinstance(content, str)
            or len(content) > _MAX_EXCERPT_CONTENT
        ):
            continue
        previous = recovered.get(evidence_id)
        if previous is not None and previous != content:
            conflicted.add(evidence_id)
            recovered.pop(evidence_id, None)
        elif evidence_id not in conflicted:
            recovered[evidence_id] = content
    return recovered


def build_live_outcome(
    *,
    records: Sequence[Mapping[str, object]],
    excerpts: Mapping[str, str],
    scenario: LiveScenario,
    quarantine: QuarantineIndex | None = None,
) -> LiveOutcome:
    """Reconstruct one live outcome from a completed JSONL run.

    Raises ``ProviderTransientError`` for a failed turn -- the same classification the
    instructor's own transport makes at ``eval/live.py:701`` -- and ``LiveContractError``
    for anything the protocol should not have produced.
    """

    index = QuarantineIndex.empty() if quarantine is None else quarantine
    record = turn_result_of(records)
    if record is None:
        raise ProviderTransientError("swift agent turn produced no result record")
    if set(record) - _TURN_RESULT_FIELDS - {RECORD_KEY}:
        raise LiveContractError("swift agent turn record carries unsupported fields")
    turn_status = _member(EventStatus, record.get("turn_status"), "turn status")
    if turn_status is EventStatus.FAILED:
        raise ProviderTransientError("swift agent turn failed")
    evidence = tuple(_evidence(item) for item in _list(record.get("evidence"), "turn evidence"))
    context = _context(record, scenario)
    try:
        return LiveOutcome(
            answer=_text(record.get("answer"), "turn answer"),
            evidence=evidence,
            evidence_excerpts=_excerpts(evidence, excerpts),
            context=context,
            turn_status=turn_status,
            tool_names=tuple(_strings(record.get("tool_names"), "turn tool names")),
            source_ids=tuple(_strings(record.get("source_ids"), "turn source identifiers")),
            quarantined_segments=index.markers_for_turn(
                evidence,
                _strings(record.get("quarantined_segments"), "turn quarantine markers"),
            ),
        )
    except ContractError as exc:
        raise LiveContractError("swift agent turn record is malformed") from exc


def _context(record: Mapping[str, object], scenario: LiveScenario) -> RuntimeContext:
    """Trust the run's own identifiers; only the scope comes from the scenario.

    Citation validation compares evidence against this context, so reading the triple back
    from the record is the point: an identifier invented here would validate evidence
    against a run that never happened.
    """

    try:
        return RuntimeContext(
            identity_id=_text(record.get("identity_id"), "turn identity"),
            thread_id=_text(record.get("thread_id"), "turn thread"),
            run_id=_text(record.get("run_id"), "turn run"),
            channel=RuntimeChannel.CLI,
            allowed_resources=scenario.allowed_resources,
        )
    except ContractError as exc:
        raise LiveContractError("swift agent runtime context is malformed") from exc


def _evidence(value: object) -> Evidence:
    if not isinstance(value, Mapping) or not _EVIDENCE_FIELDS <= set(value):
        raise LiveContractError("swift agent evidence record is malformed")
    provenance = value.get("provenance")
    if not isinstance(provenance, Mapping) or not _PROVENANCE_FIELDS <= set(provenance):
        raise LiveContractError("swift agent evidence provenance is malformed")
    try:
        return Evidence(
            evidence_id=_text(value.get("evidence_id"), "evidence identifier"),
            identity_id=_text(value.get("identity_id"), "evidence identity"),
            run_id=_text(value.get("run_id"), "evidence run"),
            provenance=ProvenanceRef(
                source_family=_member(
                    SourceFamily,
                    provenance.get("source_family"),
                    "evidence source family",
                ),
                source_id=_text(provenance.get("source_id"), "evidence source identifier"),
                content_sha256=_text(provenance.get("content_sha256"), "evidence digest"),
            ),
            status=_member(EvidenceStatus, value.get("status"), "evidence status"),
            trust=_member(TrustLabel, value.get("trust"), "evidence trust label"),
            allowed_resources=tuple(
                _strings(value.get("allowed_resources", ()), "evidence allowed resources")
            ),
        )
    except ContractError as exc:
        raise LiveContractError("swift agent evidence record is malformed") from exc


def _excerpts(
    evidence: Sequence[Evidence],
    contents: Mapping[str, str],
) -> tuple[EvidenceExcerpt, ...]:
    """Hash and truncate through the evaluator's own constructor, never around it.

    ``EvidenceExcerpt.from_evidence`` re-derives the digest from the supplied text and
    refuses content that does not match the issued provenance, so a gap or a drifted
    excerpt drops out here exactly as it does for the instructor's transport.
    """

    excerpts: list[EvidenceExcerpt] = []
    for record in evidence:
        content = contents.get(record.evidence_id)
        if content is None:
            continue
        try:
            excerpts.append(EvidenceExcerpt.from_evidence(record, content))
        except JudgeContractError:
            continue
    return tuple(excerpts)


def _member(enumeration: type[_Member], value: object, label: str) -> _Member:
    if not isinstance(value, str):
        raise LiveContractError(f"swift agent {label} is malformed")
    try:
        return enumeration(value)
    except ValueError as exc:
        raise LiveContractError(f"swift agent {label} is malformed") from exc


def _text(value: object, label: str) -> str:
    if not isinstance(value, str):
        raise LiveContractError(f"swift agent {label} is malformed")
    return value


def _list(value: object, label: str) -> tuple[object, ...]:
    if not isinstance(value, list) or len(value) > _MAX_RECORDS:
        raise LiveContractError(f"swift agent {label} is malformed")
    return tuple(value)


def _strings(value: object, label: str) -> tuple[str, ...]:
    items = _list(value, label)
    if not all(isinstance(item, str) for item in items):
        raise LiveContractError(f"swift agent {label} is malformed")
    return tuple(item for item in items if isinstance(item, str))

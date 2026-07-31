"""Deterministic citation checks and a bounded semantic-judge contract."""

from __future__ import annotations

import hashlib
import re
import unicodedata
from collections.abc import Mapping, Sequence
from dataclasses import dataclass

from pydantic import BaseModel, ConfigDict, Field, ValidationError, field_validator

from ops_scaffold.contracts import (
    EventStatus,
    Evidence,
    EvidenceStatus,
    RuntimeContext,
    SourceFamily,
    TrustLabel,
)

_CITATION = re.compile(r"\[evidence:([A-Za-z0-9][A-Za-z0-9._:-]{0,127})\]")
_REFUSAL_DENIAL = re.compile(
    r"\b(?:cannot|can't|unable|refuse|decline|insufficient|not enough|lacking|lack|"
    r"don't have|do not have)\b"
)
_REFUSAL_GROUNDING = re.compile(
    r"\b(?:evidence|source|citation|support(?:ed|s|ing)?|grounded)\b"
)
_REFUSAL_CLAUSE_SPLIT = re.compile(
    r"(?:[.!?;\n]+|\b(?:but|however|nevertheless|nonetheless|yet|although|though)\b|"
    r"\b(?:але|проте|однак|втім|водночас)\b)"
)
_REFUSAL_OFFER = re.compile(
    r"\b(?:help|outline|suggest|next steps|collect more|provide more|"
    r"допомог|наступн|зібрат|надайте)\b"
)
_REFUSAL_DENIAL_TERMS = ("не мож", "неможливо", "відмов", "недостатн", "бракує")
_REFUSAL_GROUNDING_TERMS = ("доказ", "джерел", "цитат", "підтвердж", "обґрунт")
_MAX_QUESTION = 2_000
_MAX_ANSWER = 16_384
_MAX_EVIDENCE_CONTENT = 4_096
_MAX_EVIDENCE = 32
_MAX_TOTAL_EVIDENCE = 32_768


class CitationValidationError(ValueError):
    """A final answer does not cite usable current-run evidence."""


class JudgeContractError(ValueError):
    """The semantic judge request or response violated the bounded contract."""


def is_grounded_refusal(answer: object) -> bool:
    """Recognize bounded evidence-based refusals without prescribing exact prose."""

    if (
        not isinstance(answer, str)
        or not answer.strip()
        or len(answer) > _MAX_ANSWER
        or any(
            unicodedata.category(character) == "Cc" and character not in {"\n", "\t"}
            for character in answer
        )
    ):
        return False
    normalized = unicodedata.normalize("NFC", answer).casefold()
    clauses = tuple(
        clause.strip()
        for clause in _REFUSAL_CLAUSE_SPLIT.split(normalized)
        if clause.strip()
    )
    return (
        "[evidence:" not in normalized
        and _has_refusal_denial(normalized)
        and _has_refusal_grounding(normalized)
        and bool(clauses)
        and all(
            _has_refusal_denial(clause)
            or _has_refusal_grounding(clause)
            or _REFUSAL_OFFER.search(clause) is not None
            for clause in clauses
        )
    )


def grounding_update_is_safe(update: object) -> bool:
    """Accept an immediate grounded refusal or one bounded model-repair jump."""

    if not isinstance(update, Mapping):
        return False
    if update.get("jump_to") == "model":
        return set(update) <= {"jump_to", "messages"}
    from ops_scaffold.application import extract_final_answer

    return is_grounded_refusal(extract_final_answer(update.get("messages")))


def _has_refusal_denial(value: str) -> bool:
    return _REFUSAL_DENIAL.search(value) is not None or any(
        term in value for term in _REFUSAL_DENIAL_TERMS
    )


def _has_refusal_grounding(value: str) -> bool:
    return _REFUSAL_GROUNDING.search(value) is not None or any(
        term in value for term in _REFUSAL_GROUNDING_TERMS
    )


@dataclass(frozen=True, slots=True)
class EvidenceExcerpt:
    """Bounded source content paired with one issued evidence record."""

    evidence_id: str
    source_family: SourceFamily
    source_id: str
    content_sha256: str
    excerpt_sha256: str
    content: str
    truncated: bool

    def __post_init__(self) -> None:
        if not isinstance(self.evidence_id, str) or not _CITATION.fullmatch(
            f"[evidence:{self.evidence_id}]"
        ):
            raise JudgeContractError("judge evidence identifier is invalid")
        if not isinstance(self.source_family, SourceFamily):
            raise JudgeContractError("judge source family is invalid")
        if (
            not isinstance(self.source_id, str)
            or not self.source_id
            or len(self.source_id) > 192
            or "\x00" in self.source_id
        ):
            raise JudgeContractError("judge source identifier is invalid")
        if not isinstance(self.content_sha256, str) or not re.fullmatch(
            r"[0-9a-f]{64}", self.content_sha256
        ):
            raise JudgeContractError("judge evidence digest is invalid")
        if not isinstance(self.excerpt_sha256, str) or not re.fullmatch(
            r"[0-9a-f]{64}", self.excerpt_sha256
        ):
            raise JudgeContractError("judge excerpt digest is invalid")
        if not isinstance(self.truncated, bool):
            raise JudgeContractError("judge excerpt truncation flag is invalid")
        object.__setattr__(
            self,
            "content",
            _bounded_text(
                self.content,
                maximum=_MAX_EVIDENCE_CONTENT,
                label="judge evidence content",
                allow_empty=True,
            ),
        )
        if hashlib.sha256(self.content.encode()).hexdigest() != self.excerpt_sha256:
            raise JudgeContractError("judge evidence excerpt is inconsistent")
        if not self.truncated and self.excerpt_sha256 != self.content_sha256:
            raise JudgeContractError("complete judge evidence digest is inconsistent")

    @classmethod
    def from_evidence(cls, evidence: Evidence, content: str) -> EvidenceExcerpt:
        if not isinstance(evidence, Evidence):
            raise JudgeContractError("judge evidence metadata is invalid")
        full_content = _bounded_text(
            content,
            maximum=262_144,
            label="full evidence content",
            allow_empty=True,
        )
        if hashlib.sha256(full_content.encode()).hexdigest() != evidence.provenance.content_sha256:
            raise JudgeContractError("full judge evidence content is inconsistent")
        excerpt = full_content[:_MAX_EVIDENCE_CONTENT]
        return cls(
            evidence_id=evidence.evidence_id,
            source_family=evidence.provenance.source_family,
            source_id=evidence.provenance.source_id,
            content_sha256=evidence.provenance.content_sha256,
            excerpt_sha256=hashlib.sha256(excerpt.encode()).hexdigest(),
            content=excerpt,
            truncated=len(excerpt) != len(full_content),
        )

    def as_judge_dict(self) -> dict[str, str | bool]:
        return {
            "evidence_id": self.evidence_id,
            "source_family": self.source_family.value,
            "source_id": self.source_id,
            "content_sha256": self.content_sha256,
            "excerpt_sha256": self.excerpt_sha256,
            "content": self.content,
            "truncated": self.truncated,
        }


class JudgeVerdict(BaseModel):
    """Strict structured output: providers may not add undeclared fields."""

    model_config = ConfigDict(extra="forbid", strict=True)

    supported: bool
    rationale: str = Field(min_length=1, max_length=500)

    @field_validator("rationale")
    @classmethod
    def validate_rationale(cls, value: str) -> str:
        return _bounded_text(
            value,
            maximum=500,
            label="judge rationale",
        )


def validate_current_run_citations(
    answer: str,
    *,
    evidence: Sequence[Evidence],
    context: RuntimeContext,
    turn_status: EventStatus,
    required_source_families: int = 1,
    allowed_source_families: frozenset[SourceFamily] | None = None,
) -> tuple[Evidence, ...]:
    """Resolve citations only against issued evidence from this completed turn."""

    try:
        bounded_answer = _bounded_text(
            answer,
            maximum=_MAX_ANSWER,
            label="final answer",
        )
    except JudgeContractError as exc:
        raise CitationValidationError("final answer is not bounded text") from exc
    if not isinstance(context, RuntimeContext):
        raise CitationValidationError("trusted runtime context is required")
    if turn_status is not EventStatus.COMPLETED:
        raise CitationValidationError("evidence is unusable after an incomplete turn")
    if type(required_source_families) is not int or not 1 <= required_source_families <= len(
        SourceFamily
    ):
        raise CitationValidationError("required source family count is invalid")
    if allowed_source_families is not None and (
        not isinstance(allowed_source_families, frozenset)
        or not allowed_source_families
        or not all(isinstance(family, SourceFamily) for family in allowed_source_families)
    ):
        raise CitationValidationError("allowed source family set is invalid")

    citation_ids = tuple(_CITATION.findall(bounded_answer))
    if (
        not citation_ids
        or len(citation_ids) > 64
        or bounded_answer.count("[evidence:") != len(citation_ids)
    ):
        raise CitationValidationError("final citations are malformed")
    records = tuple(evidence)
    if (
        len(records) > 256
        or not all(isinstance(record, Evidence) for record in records)
        or len({record.evidence_id for record in records}) != len(records)
    ):
        raise CitationValidationError("current-run evidence collection is malformed")
    by_id = {record.evidence_id: record for record in records}
    cited: list[Evidence] = []
    for evidence_id in dict.fromkeys(citation_ids):
        record = by_id.get(evidence_id)
        if (
            record is None
            or record.identity_id != context.identity_id
            or record.run_id != context.run_id
            or record.status is not EvidenceStatus.ISSUED
            or record.trust is TrustLabel.QUARANTINED
        ):
            raise CitationValidationError("citation is not issued current-run evidence")
        if (
            allowed_source_families is not None
            and record.provenance.source_family not in allowed_source_families
        ):
            raise CitationValidationError("citation uses an unexpected source family")
        cited.append(record)
    if len({item.provenance.source_family for item in cited}) < required_source_families:
        raise CitationValidationError("final answer lacks required source families")
    return tuple(cited)


def build_judge_payload(
    *,
    question: str,
    answer: str,
    cited_evidence: Sequence[Evidence],
    evidence_excerpts: Sequence[EvidenceExcerpt],
    expected_claims: Sequence[str] = (),
) -> dict[str, object]:
    """Build the only payload class visible to the semantic judge."""

    bounded_question = _bounded_text(
        question,
        maximum=_MAX_QUESTION,
        label="judge question",
    )
    bounded_answer = _bounded_text(
        answer,
        maximum=_MAX_ANSWER,
        label="judge answer",
    )
    claims = tuple(expected_claims)
    if len(claims) > 16:
        raise JudgeContractError("judge expected claims exceed the limit")
    bounded_claims = [
        _bounded_text(claim, maximum=500, label="judge expected claim")
        for claim in claims
    ]
    cited = tuple(cited_evidence)
    excerpts = tuple(evidence_excerpts)
    if (
        len(cited) > _MAX_EVIDENCE
        or not all(isinstance(item, Evidence) for item in cited)
        or not all(isinstance(item, EvidenceExcerpt) for item in excerpts)
    ):
        raise JudgeContractError("judge evidence collection is malformed")
    excerpt_by_id = {item.evidence_id: item for item in excerpts}
    if len(excerpt_by_id) != len(excerpts):
        raise JudgeContractError("judge evidence excerpts are duplicated")
    selected: list[EvidenceExcerpt] = []
    total_content = 0
    for record in cited:
        excerpt = excerpt_by_id.get(record.evidence_id)
        if (
            excerpt is None
            or excerpt.source_family is not record.provenance.source_family
            or excerpt.source_id != record.provenance.source_id
            or excerpt.content_sha256 != record.provenance.content_sha256
        ):
            raise JudgeContractError("judge evidence does not match issued metadata")
        total_content += len(excerpt.content)
        if total_content > _MAX_TOTAL_EVIDENCE:
            raise JudgeContractError("judge evidence exceeds the total budget")
        selected.append(excerpt)
    return {
        "question": bounded_question,
        "answer": bounded_answer,
        "expected_claims": bounded_claims,
        "evidence": [item.as_judge_dict() for item in selected],
    }


def parse_judge_verdict(value: object) -> JudgeVerdict:
    if isinstance(value, JudgeVerdict):
        return value
    if not isinstance(value, Mapping):
        raise JudgeContractError("judge output is malformed")
    try:
        return JudgeVerdict.model_validate(dict(value))
    except ValidationError as exc:
        raise JudgeContractError("judge output is malformed") from exc


def _bounded_text(
    value: object,
    *,
    maximum: int,
    label: str,
    allow_empty: bool = False,
) -> str:
    if not isinstance(value, str):
        raise JudgeContractError(f"{label} must be bounded text")
    normalized = unicodedata.normalize("NFC", value)
    if (
        "\x00" in normalized
        or len(normalized) > maximum
        or (not allow_empty and not normalized.strip())
        or any(
            unicodedata.category(character) == "Cc" and character not in {"\n", "\t"}
            for character in normalized
        )
    ):
        raise JudgeContractError(f"{label} must be bounded text")
    return normalized

"""Recover fixture quarantine markers the public turn record cannot carry.

The Swift ``turn_result.quarantined_segments`` list holds the *evidence IDs* whose trust
label came back quarantined (``Sources/OpsAgent/AgentLoop.swift``), because a turn record
is deliberately free of anything a source said about itself. The evaluator's scenarios
(``data/eval/scenarios.json``) instead name the fixture segment markers -- for example
``segment-source-maintenance-001`` -- and ``eval.live.run_live_scenario`` intersects the
two sets.

So the marker has to come back from the fixtures that declared it. Every quarantined
artifact declares its markers in the same manifests the Swift CLI validates on startup,
keyed by content digest, by scoped resource identifier and, at worst, by source family.
"""

from __future__ import annotations

import json
from collections.abc import Iterable, Mapping, Sequence
from dataclasses import dataclass
from pathlib import Path

from ops_scaffold.contracts import Evidence, ProvenanceRef, SourceFamily, TrustLabel

_MAX_MANIFEST_BYTES = 1_048_576
_MAX_MARKERS = 64


@dataclass(frozen=True, slots=True)
class QuarantineIndex:
    """Fixture-declared quarantine markers, addressable the three ways evidence is."""

    by_digest: Mapping[str, tuple[str, ...]]
    by_source_id: Mapping[str, tuple[str, ...]]
    by_family: Mapping[SourceFamily, tuple[str, ...]]

    @classmethod
    def empty(cls) -> QuarantineIndex:
        return cls(by_digest={}, by_source_id={}, by_family={})

    @classmethod
    def from_data_directory(cls, path: Path) -> QuarantineIndex:
        """Read the shipped manifests; a fixture the shim cannot read contributes nothing.

        The index is derived data, never authority: a manifest that is missing or malformed
        leaves the markers unresolved, and the scenario then fails its own deterministic
        "did not observe quarantined evidence" check rather than the run dying here.
        """

        entries: list[_Entry] = []
        for manifest in sorted((path / "source").glob("*/manifest.json")):
            entries.extend(_source_entries(_read_json(manifest)))
        entries.extend(_runbook_entries(_read_json(path / "runbooks" / "index_manifest.json")))
        entries.extend(_monitoring_entries(_read_json(path / "monitoring" / "manifest.json")))
        by_digest: dict[str, tuple[str, ...]] = {}
        by_source_id: dict[str, tuple[str, ...]] = {}
        by_family: dict[SourceFamily, list[str]] = {}
        for entry in entries:
            if entry.digest is not None:
                by_digest[entry.digest] = entry.markers
            if entry.source_id is not None:
                by_source_id[entry.source_id] = entry.markers
            by_family.setdefault(entry.family, []).extend(entry.markers)
        return cls(
            by_digest=by_digest,
            by_source_id=by_source_id,
            by_family={
                family: tuple(dict.fromkeys(markers))[:_MAX_MARKERS]
                for family, markers in by_family.items()
            },
        )

    def markers_for(self, provenance: ProvenanceRef) -> tuple[str, ...]:
        """Resolve one provenance, most specific key first.

        The family fallback is the honest answer for a repository read: its identifier is
        ``repository:<operation>:<digest-of-the-locator>`` and its digest is over the bytes
        actually handed back, so a search hit over a quarantined file matches neither key.
        Falling back is not a guess about *whether* the run met quarantined content -- the
        caller only asks about evidence the Swift registry already labelled quarantined,
        which it does only for a source result that carried markers.
        """

        return (
            self.by_digest.get(provenance.content_sha256)
            or self.by_source_id.get(provenance.source_id)
            or self.by_family.get(provenance.source_family, ())
        )

    def markers_for_turn(
        self,
        evidence: Sequence[Evidence],
        quarantined_evidence_ids: Sequence[str],
    ) -> tuple[str, ...]:
        """Translate one turn's quarantined evidence into fixture markers, in order."""

        listed = set(quarantined_evidence_ids)
        markers: list[str] = []
        for record in evidence:
            if record.trust is TrustLabel.QUARANTINED or record.evidence_id in listed:
                markers.extend(self.markers_for(record.provenance))
        return tuple(dict.fromkeys(markers))[:_MAX_MARKERS]


@dataclass(frozen=True, slots=True)
class _Entry:
    family: SourceFamily
    markers: tuple[str, ...]
    digest: str | None = None
    source_id: str | None = None


def _source_entries(manifest: Mapping[str, object] | None) -> Iterable[_Entry]:
    for item in _items(manifest, "files"):
        markers = _markers(item)
        path = item.get("path")
        if markers:
            yield _Entry(
                family=SourceFamily.REPOSITORY,
                markers=markers,
                digest=_digest(item),
                source_id=f"repository:{path}" if isinstance(path, str) and path else None,
            )


def _runbook_entries(manifest: Mapping[str, object] | None) -> Iterable[_Entry]:
    for item in _items(manifest, "documents"):
        markers = _markers(item)
        source_id = item.get("source_id")
        if markers:
            yield _Entry(
                family=SourceFamily.RUNBOOK,
                markers=markers,
                digest=_digest(item),
                source_id=(
                    f"runbook:{source_id}" if isinstance(source_id, str) and source_id else None
                ),
            )


def _monitoring_entries(manifest: Mapping[str, object] | None) -> Iterable[_Entry]:
    markers = _markers(manifest or {})
    if markers:
        yield _Entry(family=SourceFamily.MONITORING, markers=markers)


def _items(manifest: Mapping[str, object] | None, key: str) -> Iterable[Mapping[str, object]]:
    values = (manifest or {}).get(key)
    if not isinstance(values, list) or len(values) > 256:
        return ()
    return tuple(value for value in values if isinstance(value, Mapping))


def _markers(item: Mapping[str, object]) -> tuple[str, ...]:
    values = item.get("quarantined_segments")
    if not isinstance(values, list) or len(values) > _MAX_MARKERS:
        return ()
    return tuple(value for value in values if isinstance(value, str) and value)


def _digest(item: Mapping[str, object]) -> str | None:
    value = item.get("content_sha256")
    return value if isinstance(value, str) and len(value) == 64 else None


def _read_json(path: Path) -> Mapping[str, object] | None:
    try:
        raw = path.read_bytes()
    except OSError:
        return None
    if len(raw) > _MAX_MANIFEST_BYTES:
        return None
    try:
        value = json.loads(raw.decode("utf-8"))
    except (UnicodeError, json.JSONDecodeError):
        return None
    return value if isinstance(value, Mapping) else None

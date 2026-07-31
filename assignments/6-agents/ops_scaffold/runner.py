"""Single turn path shared by every Ops Copilot interface."""

from __future__ import annotations

import asyncio
import math
import time
import unicodedata
from collections.abc import Mapping
from dataclasses import dataclass
from typing import TYPE_CHECKING

from ops_scaffold.contracts import (
    AppEvent,
    CapabilityBlocked,
    EventStatus,
    Evidence,
    RuntimeContext,
)

if TYPE_CHECKING:
    from ops_scaffold.bootstrap import RuntimeServices

_MAX_USER_INPUT = 32_768
_MAX_UPDATE_BUDGET = 10_000


class TurnBlocked(CapabilityBlocked):
    """The turn reached a safe evidence or capability boundary."""


class TurnCancelled(RuntimeError):
    """The caller cancelled the turn."""


class TurnBudgetExceeded(RuntimeError):
    """The public update budget ended the turn."""


@dataclass(frozen=True, slots=True)
class TurnResult:
    status: EventStatus
    checkpoint_key: str
    events: tuple[AppEvent, ...]
    updates: tuple[Mapping[str, object], ...]
    evidence: tuple[Evidence, ...]


def run_turn(
    agent: object,
    services: RuntimeServices,
    context: RuntimeContext,
    user_input: str,
    *,
    update_budget: int = 256,
    deadline_monotonic: float | None = None,
) -> TurnResult:
    """Run one serialized turn using only trusted scope derivation and public streams."""

    if (
        not callable(getattr(services, "checkpoint_key", None))
        or not callable(getattr(services, "checkpoint_config", None))
        or not callable(getattr(services, "turn_lock", None))
        or not hasattr(services, "bundle")
        or not hasattr(services, "event_normalizer")
    ):
        raise TypeError("run_turn requires injected RuntimeServices")
    if not isinstance(context, RuntimeContext):
        raise TypeError("run_turn requires a trusted RuntimeContext")
    normalized_input = validate_turn_input(user_input)
    if type(update_budget) is not int or not 1 <= update_budget <= _MAX_UPDATE_BUDGET:
        raise ValueError("turn update budget must be a positive bounded integer")
    if deadline_monotonic is not None and (
        not isinstance(deadline_monotonic, (int, float))
        or isinstance(deadline_monotonic, bool)
        or not math.isfinite(float(deadline_monotonic))
        or float(deadline_monotonic) <= time.monotonic()
    ):
        raise ValueError("turn deadline must be a future monotonic timestamp")
    stream_method = getattr(agent, "stream", None)
    if not callable(stream_method):
        raise TypeError("agent runtime must expose the public stream method")

    checkpoint_key = services.checkpoint_key(context)
    config = services.checkpoint_config(context)
    events: list[AppEvent] = []
    updates: list[Mapping[str, object]] = []
    evidence: tuple[Evidence, ...] = ()
    status = EventStatus.FAILED
    evidence_registry = services.bundle.evidence_registry

    with services.turn_lock(context):
        registry_started = False
        stream: object | None = None
        try:
            evidence_registry.begin_turn(context)
            registry_started = True
            services.event_normalizer.begin_turn(context)
            if deadline_monotonic is not None and time.monotonic() >= deadline_monotonic:
                raise TurnBudgetExceeded
            stream = stream_method(
                {"messages": [{"role": "user", "content": normalized_input}]},
                config,
                context=context,
                stream_mode=["updates", "custom"],
            )
            stream_item_count = 0
            for item in stream:
                if deadline_monotonic is not None and time.monotonic() >= deadline_monotonic:
                    raise TurnBudgetExceeded
                parsed = _parse_stream_item(item)
                if parsed is None:
                    continue
                stream_item_count += 1
                if stream_item_count > update_budget:
                    raise TurnBudgetExceeded
                mode, payload = parsed
                if mode == "updates":
                    if isinstance(payload, Mapping):
                        updates.append(dict(payload))
                events.extend(services.event_normalizer.normalize(context, mode, payload))
            status = EventStatus.COMPLETED
        except CapabilityBlocked:
            status = EventStatus.BLOCKED
        except (TurnCancelled, asyncio.CancelledError, KeyboardInterrupt):
            status = EventStatus.CANCELLED
        except TurnBudgetExceeded:
            status = EventStatus.BUDGET_EXCEEDED
        except Exception:
            # Raw provider, tool, source, and model errors never enter events.
            status = EventStatus.FAILED
        finally:
            close_stream = getattr(stream, "close", None)
            if callable(close_stream):
                try:
                    close_stream()
                except Exception:
                    status = EventStatus.FAILED
            if registry_started:
                try:
                    evidence = tuple(evidence_registry.finish_turn(context))
                except Exception:
                    evidence_registry.abort_turn(context)
                    evidence = ()
                    status = EventStatus.FAILED
            events.append(services.event_normalizer.terminal(context, status))

    return TurnResult(
        status=status,
        checkpoint_key=checkpoint_key,
        events=tuple(events),
        updates=tuple(updates),
        evidence=evidence,
    )


def _parse_stream_item(item: object) -> tuple[str, object] | None:
    if (
        isinstance(item, tuple)
        and len(item) == 2
        and isinstance(item[0], str)
        and item[0] in {"updates", "custom"}
    ):
        return item[0], item[1]
    return None


def validate_turn_input(value: object) -> str:
    """Normalize and validate turn text at every runtime boundary."""

    if not isinstance(value, str):
        raise TypeError("turn input must be text")
    normalized = unicodedata.normalize("NFC", value)
    if not normalized.strip() or "\x00" in normalized or len(normalized) > _MAX_USER_INPUT:
        raise ValueError("turn input must be non-empty bounded text without null bytes")
    return normalized

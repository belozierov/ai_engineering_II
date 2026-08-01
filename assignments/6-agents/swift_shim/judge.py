"""Judge wiring that degrades instead of gating the tier.

``eval.live.run_live_checks`` refuses the whole live tier without ``OPENROUTER_API_KEY``,
because there the agent is an OpenRouter model too. Here the agent is a local Swift binary
over claude and needs no such key -- only the semantic judge does. So a missing key has to
cost the judge rows and nothing else.

The mechanism is a transport that raises ``ProviderTransientError``. That is already the
one failure ``run_live_scenario`` answers with an UNAVAILABLE judge row while keeping its
citation row, so the degraded path reuses the instructor's semantics rather than a second
copy of them.
"""

from __future__ import annotations

from collections.abc import Mapping

from eval.live import (
    JudgeTransport,
    LiveContractError,
    LiveSettings,
    OpenRouterJudgeTransport,
    ProviderTransientError,
)


class UnavailableJudgeTransport:
    """Stand in for the semantic judge when no judge provider is configured."""

    def __init__(self, reason: str) -> None:
        self.reason = reason

    def invoke(self, payload: dict[str, object]) -> object:
        raise ProviderTransientError(self.reason)


def judge_transport_from_environment(
    environ: Mapping[str, str] | None = None,
) -> JudgeTransport:
    """Return the real judge when the key is configured, and a degraded one otherwise."""

    try:
        settings = LiveSettings.from_environment(environ)
    except LiveContractError:
        return UnavailableJudgeTransport("live judge settings are invalid")
    if settings is None:
        return UnavailableJudgeTransport("OPENROUTER_API_KEY is not configured")
    try:
        return OpenRouterJudgeTransport(settings)
    except Exception:  # any construction failure degrades the same way
        return UnavailableJudgeTransport("live judge provider is unavailable")

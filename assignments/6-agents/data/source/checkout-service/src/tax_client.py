"""Synthetic dependency client configuration behavior."""

from __future__ import annotations


class TaxServiceTimeout(RuntimeError):
    """The synthetic tax dependency exceeded its request deadline."""


def timeout_seconds(config: dict[str, object]) -> float:
    """Read the deliberately strict timeout deployed in the incident fixture."""

    return float(config.get("tax_service_timeout_seconds", 0.2))

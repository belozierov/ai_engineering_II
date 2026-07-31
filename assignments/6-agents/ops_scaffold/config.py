"""Validated, environment-backed configuration for the Ops Copilot homework.

This module only describes configuration. It deliberately does not load dotenv
files or construct models, stores, indexes, checkpointers, or servers.
"""

from __future__ import annotations

import os
import re
from collections.abc import Mapping
from dataclasses import dataclass, field
from pathlib import Path

from pydantic import SecretStr

PACKAGE_ENV = "OPS_PKG"
DEFAULT_PACKAGE = "ops_copilot"
_PRIVATE_PACKAGE_ROOT = Path(__file__).resolve().parents[1] / "reference_solution"
ALLOWED_PACKAGES = frozenset(
    {"ops_copilot", *(("reference_solution",) if _PRIVATE_PACKAGE_ROOT.is_dir() else ())}
)
OPENROUTER_BASE_URL = "https://openrouter.ai/api/v1"

DEFAULT_AGENT_MODEL = "openai/gpt-4.1-mini"
DEFAULT_SUMMARIZER_MODEL = "google/gemini-2.5-flash-lite"
DEFAULT_JUDGE_MODEL = "openai/gpt-4.1-mini"

_MAX_BUDGET = 1_000_000
_MODEL_NAME = re.compile(r"[A-Za-z0-9][A-Za-z0-9._:/-]{0,127}\Z")


class ConfigurationError(ValueError):
    """A safe, bounded error for configuration supplied outside the package."""


@dataclass(frozen=True, slots=True)
class TokenBudgets:
    """Token limits used by the runner and compaction middleware."""

    compaction_target: int = 4_000
    compaction_soft: int = 8_000
    hard_input: int = 12_000
    response_reserve: int = 2_000

    def __post_init__(self) -> None:
        values = (
            self.compaction_target,
            self.compaction_soft,
            self.hard_input,
            self.response_reserve,
        )
        if any(type(value) is not int or not 1 <= value <= _MAX_BUDGET for value in values):
            raise ConfigurationError("token budgets must be positive bounded integers")
        if not self.compaction_target < self.compaction_soft < self.hard_input:
            raise ConfigurationError(
                "token budgets must satisfy target < soft trigger < hard input"
            )
        if self.response_reserve >= self.hard_input:
            raise ConfigurationError("token budgets require response reserve below hard input")


@dataclass(frozen=True, slots=True)
class OpsSettings:
    """Configuration values; callers explicitly choose when to read the environment."""

    package: str = DEFAULT_PACKAGE
    agent_model: str = DEFAULT_AGENT_MODEL
    summarizer_model: str = DEFAULT_SUMMARIZER_MODEL
    judge_model: str = DEFAULT_JUDGE_MODEL
    token_budgets: TokenBudgets = field(default_factory=TokenBudgets)
    openrouter_api_key: SecretStr | None = field(default=None, repr=False)
    openrouter_base_url: str = OPENROUTER_BASE_URL

    def __post_init__(self) -> None:
        if not isinstance(self.package, str) or self.package not in ALLOWED_PACKAGES:
            raise ConfigurationError("OPS_PKG must select an available course package")
        _validate_model(self.agent_model, "OPS_AGENT_MODEL")
        _validate_model(self.summarizer_model, "OPS_SUMMARIZER_MODEL")
        _validate_model(self.judge_model, "OPS_JUDGE_MODEL")
        if not isinstance(self.token_budgets, TokenBudgets):
            raise ConfigurationError("token budgets must use TokenBudgets")
        if self.openrouter_api_key is not None and (
            not isinstance(self.openrouter_api_key, SecretStr)
            or not self.openrouter_api_key.get_secret_value().strip()
            or len(self.openrouter_api_key.get_secret_value()) > 4_096
        ):
            raise ConfigurationError("OPENROUTER_API_KEY must be a bounded secret")
        if self.openrouter_base_url != OPENROUTER_BASE_URL:
            raise ConfigurationError("OpenRouter base URL is fixed by the course")

    @classmethod
    def from_env(cls, environ: Mapping[str, str] | None = None) -> OpsSettings:
        """Build settings from an injected mapping or the process environment."""

        source = os.environ if environ is None else environ
        return cls(
            package=select_package(source),
            agent_model=_read_model(source, "OPS_AGENT_MODEL", DEFAULT_AGENT_MODEL),
            summarizer_model=_read_model(
                source,
                "OPS_SUMMARIZER_MODEL",
                DEFAULT_SUMMARIZER_MODEL,
            ),
            judge_model=_read_model(source, "OPS_JUDGE_MODEL", DEFAULT_JUDGE_MODEL),
            token_budgets=TokenBudgets(
                compaction_target=_read_budget(
                    source,
                    "OPS_COMPACTION_TARGET_TOKENS",
                    4_000,
                ),
                compaction_soft=_read_budget(
                    source,
                    "OPS_COMPACTION_SOFT_TOKENS",
                    8_000,
                ),
                hard_input=_read_budget(source, "OPS_HARD_INPUT_TOKENS", 12_000),
                response_reserve=_read_budget(
                    source,
                    "OPS_RESPONSE_RESERVE_TOKENS",
                    2_000,
                ),
            ),
            openrouter_api_key=_read_optional_secret(source, "OPENROUTER_API_KEY"),
        )


def select_package(environ: Mapping[str, str] | None = None) -> str:
    """Return the evaluator package selected by ``OPS_PKG``.

    Only course-owned packages present in this artifact are accepted. This avoids
    turning an environment variable into an arbitrary import capability.
    """

    source = os.environ if environ is None else environ
    package = source.get(PACKAGE_ENV, DEFAULT_PACKAGE)
    if package not in ALLOWED_PACKAGES:
        raise ConfigurationError("OPS_PKG must select an available course package")
    return package


def _read_budget(source: Mapping[str, str], name: str, default: int) -> int:
    raw = source.get(name)
    if raw is None:
        return default
    if not raw.isascii() or not raw.isdecimal() or len(raw) > 7:
        raise ConfigurationError(f"{name} must be a positive bounded integer")
    value = int(raw)
    if not 1 <= value <= _MAX_BUDGET:
        raise ConfigurationError(f"{name} must be a positive bounded integer")
    return value


def _read_model(source: Mapping[str, str], name: str, default: str) -> str:
    value = source.get(name, default)
    _validate_model(value, name)
    return value


def _validate_model(value: object, name: str) -> None:
    if not isinstance(value, str) or not _MODEL_NAME.fullmatch(value):
        raise ConfigurationError(f"{name} must be a bounded provider model name")


def _read_optional_secret(source: Mapping[str, str], name: str) -> SecretStr | None:
    value = source.get(name)
    if value is None or not value.strip():
        return None
    return SecretStr(value)

"""Evaluator-owned identifiers for the six student implementation boundaries."""

from __future__ import annotations

from enum import StrEnum


class StarterTodo(StrEnum):
    """Stable identifiers shared by the starter package and evaluator."""

    AGENT_COMPOSITION = "U4-1-agent-composition"
    BOUNDED_SOURCE_TOOLS = "U4-2-bounded-source-tools"
    IDENTITY_FACT_MEMORY = "U4-3-identity-fact-memory"
    STRUCTURED_PROCEDURES = "U4-4-structured-procedures"
    GUIDED_COMPACTION = "U4-5-guided-compaction"
    EVIDENCE_ACTION_POLICY = "U4-6-evidence-action-policy"


class StarterTodoNotImplementedError(NotImplementedError):
    """An untouched student boundary recognized by the Tier 1 evaluator."""

    def __init__(self, todo: StarterTodo) -> None:
        if not isinstance(todo, StarterTodo):
            raise TypeError("starter capability must use a declared identifier")
        self.todo = todo
        super().__init__(f"{todo.value} is not implemented")

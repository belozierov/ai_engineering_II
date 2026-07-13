"""TODO 5 — Faithfulness validator (lecture 6.2, slides 38-40).

This is the fixed, non-gameable version of v2's check. v2 only checked that the
string "[source:" appears — so a hallucination passed as long as you appended
"[Source: X]". Here you receive the titles that were ACTUALLY retrieved and must
verify every cited source is among them.
"""

from __future__ import annotations

import re

from pydantic_ai import ModelRetry

REFUSAL_MARKERS = ("don't have enough", "do not have enough", "no information", "cannot answer", "not found in")

CITATION_RE = re.compile(r"\[source:\s*([^\]]+)\]", re.IGNORECASE)


def check_faithfulness(output: str, retrieved_titles: list[str]) -> str:
    """Verify the answer is grounded in what was actually retrieved.

    Args:
        output: the agent's answer.
        retrieved_titles: titles of the chunks the search tool actually returned.

    Behaviour (Tier 1 — deterministic, required):
        - If the answer is a refusal ("I don't have enough information..."), pass.
        - If there are no [Source: ...] citations at all, raise ModelRetry.
        - If ANY cited [Source: X] is not among retrieved_titles, raise ModelRetry
          (this is the anti-gaming check — a made-up citation must fail).
        - Otherwise return output unchanged.

    Bonus (Tier 2): use llm.llm_complete as an LLM-as-judge to grade whether each
    claim is actually supported by the retrieved text (score 1-5, retry if < 3).
    """
    # TODO 5: implement the grounding check described above.
    #   Helpers available: REFUSAL_MARKERS, CITATION_RE (extracts cited titles).
    #   Compare cited titles against retrieved_titles (case-insensitive, trimmed).
    raise NotImplementedError("TODO 5: implement check_faithfulness")

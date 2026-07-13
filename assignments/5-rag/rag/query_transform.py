"""TODO 4 — Query transformation (lecture 6.2 rewrite; 6.1 decomposition/HyDE).

Core: rewrite_query (resolve follow-ups into standalone queries).
Bonus: decompose() and hyde() behind the same "query in -> query out" shape, so
you can bake them off on golden.json and JUSTIFY which one wins for this corpus.
"""

from __future__ import annotations

from .llm import llm_complete


def rewrite_query(conversation_context: str, ambiguous_query: str) -> str:
    """Rewrite an ambiguous follow-up into a standalone search query.

    Example: after "Tell me about Paris", the follow-up "What about its most
    famous landmark?" should become "What is the most famous landmark in Paris?".

    Write a prompt that includes the conversation context and the follow-up, and
    asks the LLM to return ONLY the rewritten standalone question. Call
    llm_complete(prompt) and return its result.

    Tip (slide 34): a self-contained query ("What is the Eiffel Tower?") needs no
    rewrite — rewriting it only adds latency and cost.
    """
    # TODO 4: build the rewrite prompt and return llm_complete(prompt).
    raise NotImplementedError("TODO 4: implement rewrite_query")


# --- BONUS: query bake-off (same interface, pick a winner in results.md) ------

def decompose(query: str) -> list[str]:
    """BONUS: split a multi-hop query into simpler sub-queries (fan-out)."""
    raise NotImplementedError("BONUS: implement decompose")


def hyde(query: str) -> str:
    """BONUS: HyDE — generate a hypothetical answer to embed instead of the query."""
    raise NotImplementedError("BONUS: implement hyde")

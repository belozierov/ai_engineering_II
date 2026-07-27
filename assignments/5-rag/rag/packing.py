"""TODO 3 — Context packing / assembly (lecture 6.2, slides 35-37).

Retrieval finds chunks; packing decides WHICH chunks go into the prompt and in
what shape. This is step 3 of the loop on slide 27 and was missing entirely from
v2 (which just joined text[:500] with blank lines).
"""

from __future__ import annotations

from . import config


def assemble_context(results: list[dict], token_budget: int = config.TOKEN_BUDGET) -> str:
    """Turn retrieved chunks into a citation-numbered context block.

    Apply the packing rules from the slides:
        1. Deduplicate near-identical chunks.
        2. Prefer diverse sources — for a comparison question, don't return 5
           chunks from one article.
        3. Label each kept chunk with its source so the model can cite it, e.g.:
               [Source: Paris] <text>
               [Source: Eiffel Tower] <text>
           Cite by [Source: Title] (NOT by a bare number like [1]): the faithfulness
           validator (TODO 5) checks cited titles against the retrieved ones, and a
           numeric label would tempt the model into citations the validator rejects.
        4. Stay within token_budget (estimate tokens as len(text)//4). Better 4
           strong chunks than 12 weak ones.
        5. Bonus: pull in a neighbouring/parent chunk when one chunk is too little.

    Returns the assembled context string. The [Source: Title] markers here are
    what the faithfulness validator (TODO 5) checks against.
    """
    # TODO 3: implement context packing (dedup, diverse sources, citation ids, budget).
    raise NotImplementedError("TODO 3: implement assemble_context")

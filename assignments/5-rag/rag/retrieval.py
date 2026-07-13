"""TODO 2 — Retrieval + Corrective RAG gate (lecture 6.2, slides 41-42).

Two parts:
  2a. search()     — cosine search over the chunk index; KEEP the score.
  2b. crag_gate()  — decide if the evidence is good / weak / none, using the score
                     that v2 computed and threw away.
"""

from __future__ import annotations

import numpy as np

from . import config
from .data import WikiDeps


def search(deps: WikiDeps, query: str, top_k: int = config.TOP_K) -> list[dict]:
    """Return the top_k most similar chunks to `query`.

    Returns a list of dicts, highest score first:
        {"chunk_id": int, "article_title": str, "text": str, "score": float}

    Hints:
        - Encode the query with deps.encoder.
        - Normalize query and deps.chunk_embeddings (L2, + 1e-10 to avoid /0).
        - Cosine = matrix multiply; take the top_k via np.argsort.
        - Unlike v2, DO NOT discard the score — the CRAG gate needs it.
    """
    # TODO 2a: implement cosine search over deps.chunk_embeddings.
    raise NotImplementedError("TODO 2a: implement search")


def crag_gate(
    results: list[dict],
    good_threshold: float = config.CRAG_GOOD_THRESHOLD,
    weak_threshold: float = config.CRAG_WEAK_THRESHOLD,
) -> str:
    """Classify retrieval quality from the top result's score.

    Returns one of: "good" | "weak" | "none".
        good  -> top score >= good_threshold      (answer from these docs)
        weak  -> weak_threshold <= top < good      (thin — rewrite / widen / hedge)
        none  -> top score < weak_threshold        (refuse honestly)

    This is the Corrective RAG idea: check the evidence BEFORE generating, instead
    of catching a hallucination afterwards. Calibrate the thresholds on golden.json.
    """
    # TODO 2b: implement the gate on the top score.
    raise NotImplementedError("TODO 2b: implement crag_gate")

"""Eval harness — three dimensions: quality + latency + cost (idea #1).

Quality:  recall@k, precision@k, MRR, hit-rate over the golden set.
Latency:  index build time, per-query retrieval time (ms).
Cost:     LLM calls x tokens -> approximate USD (prices change; order-of-magnitude).

The metric functions here are pure and unit-tested by eval.py without a model.
`evaluate_retrieval` needs a built index (deps.chunks / deps.chunk_embeddings).
"""

from __future__ import annotations

import json
import time
from dataclasses import dataclass, field

from rag import config


# --------------------------------------------------------------------------
# Pure metric functions (unit-tested without a model)
# --------------------------------------------------------------------------

def _norm(title: str) -> str:
    return title.strip().lower()


def recall_at_k(retrieved_titles: list[str], expected_titles: list[str]) -> float:
    """Fraction of expected titles that appear anywhere in retrieved (top-k)."""
    if not expected_titles:
        return 0.0
    got = {_norm(t) for t in retrieved_titles}
    hits = sum(1 for e in expected_titles if _norm(e) in got)
    return hits / len(expected_titles)


def precision_at_k(retrieved_titles: list[str], expected_titles: list[str], k: int) -> float:
    """Fraction of the top-k retrieved that are expected (dedup by article)."""
    if k <= 0:
        return 0.0
    exp = {_norm(t) for t in expected_titles}
    topk = retrieved_titles[:k]
    hits = sum(1 for t in topk if _norm(t) in exp)
    return hits / k


def reciprocal_rank(retrieved_titles: list[str], expected_titles: list[str]) -> float:
    """1 / rank of the first retrieved title that is expected (0 if none)."""
    exp = {_norm(t) for t in expected_titles}
    for i, t in enumerate(retrieved_titles, start=1):
        if _norm(t) in exp:
            return 1.0 / i
    return 0.0


def estimate_tokens(text: str) -> int:
    """Rough token estimate: ~4 characters per token."""
    return max(1, len(text) // 4)


def estimate_cost(total_tokens: int) -> float:
    """Approximate USD from token count (see config.USD_PER_1K_TOKENS)."""
    return (total_tokens / 1000.0) * config.USD_PER_1K_TOKENS


# --------------------------------------------------------------------------
# Cost meter
# --------------------------------------------------------------------------

@dataclass
class CostMeter:
    """Tally LLM calls and tokens across a config run."""

    llm_calls: int = 0
    tokens: int = 0

    def record(self, prompt: str, response: str = "") -> None:
        self.llm_calls += 1
        self.tokens += estimate_tokens(prompt) + estimate_tokens(response)

    @property
    def usd(self) -> float:
        return estimate_cost(self.tokens)


# --------------------------------------------------------------------------
# Retrieval evaluation over the golden set
# --------------------------------------------------------------------------

@dataclass
class RunResult:
    label: str
    # Recall is split by query type. Multi-hop recall here is RAW retrieval (no
    # decomposition) — it is expected to be lower, which is exactly the motivation
    # for query decomposition in the chat pipeline. precision/MRR are over single-hop.
    recall_single: float
    recall_multi: float
    precision_single: float
    mrr_single: float
    refusal_accuracy: float          # for no_evidence queries: gate != "good"
    retrieval_ms: float              # avg per query
    index_build_ms: float = 0.0
    per_query: list[dict] = field(default_factory=list)

    def as_row(self) -> dict:
        return {
            "config": self.label,
            "recall_single": round(self.recall_single, 3),
            "recall_multi": round(self.recall_multi, 3),
            "precision_single": round(self.precision_single, 3),
            "mrr_single": round(self.mrr_single, 3),
            "refusal_acc": round(self.refusal_accuracy, 3),
            "retrieval_ms": round(self.retrieval_ms, 2),
            "index_build_ms": round(self.index_build_ms, 1),
        }


def load_golden(path=None) -> list[dict]:
    path = path or config.GOLDEN_FILE
    with open(path, encoding="utf-8") as f:
        return json.load(f)


def evaluate_retrieval(pkg, deps, golden: list[dict], top_k: int = config.TOP_K, label: str = "baseline") -> RunResult:
    """Run search over the golden set and compute quality + latency metrics.

    `pkg` is the resolved solution package (the `rag` package) exposing
    .retrieval.search and .retrieval.crag_gate. Requires a built index on deps.
    """
    rec_single: list[float] = []
    rec_multi: list[float] = []
    prec_single: list[float] = []
    rr_single: list[float] = []
    refusal_correct: list[float] = []
    latencies: list[float] = []
    per_query: list[dict] = []

    for q in golden:
        t0 = time.perf_counter()
        results = pkg.retrieval.search(deps, q["query"], top_k)
        latencies.append((time.perf_counter() - t0) * 1000.0)
        titles = [r["article_title"] for r in results]

        if q["type"] == "no_evidence":
            gate = pkg.retrieval.crag_gate(results)
            correct = 1.0 if gate != "good" else 0.0
            refusal_correct.append(correct)
            per_query.append({"query": q["query"], "type": q["type"], "gate": gate, "correct_refusal": correct})
            continue

        r = recall_at_k(titles, q["expected_titles"])
        if q["type"] == "single":
            rec_single.append(r)
            prec_single.append(precision_at_k(titles, q["expected_titles"], top_k))
            rr_single.append(reciprocal_rank(titles, q["expected_titles"]))
        else:  # multihop — raw retrieval, no decomposition (expected to be weaker)
            rec_multi.append(r)
        per_query.append({
            "query": q["query"], "type": q["type"],
            "recall": round(r, 3), "top_titles": titles[:top_k],
        })

    avg = lambda xs: sum(xs) / len(xs) if xs else 0.0
    return RunResult(
        label=label,
        recall_single=avg(rec_single),
        recall_multi=avg(rec_multi),
        precision_single=avg(prec_single),
        mrr_single=avg(rr_single),
        refusal_accuracy=avg(refusal_correct),
        retrieval_ms=avg(latencies),
        per_query=per_query,
    )

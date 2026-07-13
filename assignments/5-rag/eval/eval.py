# /// script
# requires-python = ">=3.11"
# dependencies = [
#   "pydantic-ai-slim[openrouter,web]==2.6.*",
#   "sentence-transformers",
#   "numpy",
#   "httpx",
# ]
# ///
"""
RAG homework validation: structural + behavioral checks, plus an ablation runner.

Run from the homework directory:
  uv run eval/eval.py                 # structural + behavioral (pure checks always run)
  uv run eval/eval.py --ablation      # + full index build + golden-set metrics (needs model)

Design:
  - Imports the solution package `rag` (override with the RAG_PKG env var). Importing
    it has NO side effects (no data load, no server), so these checks are cheap.
  - Pure checks (chunk_text, assemble_context, crag_gate, faithfulness, metrics) run
    without a model or API key.
  - Model/LLM-dependent checks are reported as SKIPPED (not silently passed) when the
    model can't load or OPENROUTER_API_KEY is missing.
"""

from __future__ import annotations

import argparse
import importlib
import os
import sys
from pathlib import Path

HW_DIR = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(HW_DIR))

PKG = os.environ.get("RAG_PKG", "rag")
SUBMODULES = ["config", "data", "indexing", "retrieval", "packing", "query_transform", "validation", "security"]


class Report:
    def __init__(self) -> None:
        self.passed = 0
        self.failed = 0
        self.skipped = 0
        self.failures: list[str] = []

    def ok(self, name: str, msg: str) -> None:
        self.passed += 1
        print(f"    [PASS] {name}: {msg}")

    def fail(self, name: str, msg: str) -> None:
        self.failed += 1
        self.failures.append(f"{name}: {msg}")
        print(f"    [FAIL] {name}: {msg}")

    def skip(self, name: str, msg: str) -> None:
        self.skipped += 1
        print(f"    [SKIP] {name}: {msg}")

    def check(self, name: str, condition: bool, msg: str) -> None:
        self.ok(name, msg) if condition else self.fail(name, msg)


def load_solution():
    sol = importlib.import_module(PKG)
    for sub in SUBMODULES:
        importlib.import_module(f"{PKG}.{sub}")
    return sol


# --------------------------------------------------------------------------
# Behavioral checks that need NO model and NO API key
# --------------------------------------------------------------------------

def check_chunking(sol, r: Report) -> None:
    long_text = "Sentence number %d. " % 0 + " ".join(f"Word{i}" for i in range(400))
    try:
        chunks = sol.indexing.chunk_text(long_text, chunk_size=200, overlap=40)
        r.check("chunk_text", isinstance(chunks, list) and len(chunks) > 1, f"long text -> multiple chunks (got {len(chunks)})")
        r.check("chunk_text", all(isinstance(c, str) and c.strip() for c in chunks), "chunks are non-empty strings")
        short = sol.indexing.chunk_text("short text", chunk_size=200, overlap=40)
        r.check("chunk_text", len(short) == 1, "short text -> single chunk")
        empty = sol.indexing.chunk_text("   ", chunk_size=200, overlap=40)
        r.check("chunk_text", empty == [] or all(not c.strip() for c in empty), "empty text -> no real chunks")
    except NotImplementedError:
        r.skip("chunk_text", "TODO 1a not implemented")
    except Exception as e:  # noqa: BLE001
        r.fail("chunk_text", f"raised: {e}")


def _fake_results(scores, titles, texts=None):
    texts = texts or [f"text about {t}" for t in titles]
    return [
        {"chunk_id": i, "article_title": titles[i], "text": texts[i], "score": float(scores[i])}
        for i in range(len(titles))
    ]


def check_crag_gate(sol, r: Report) -> None:
    try:
        good = sol.retrieval.crag_gate(_fake_results([0.9, 0.5], ["Paris", "France"]))
        r.check("crag_gate", good == "good", f"high score -> good (got {good!r})")
        none = sol.retrieval.crag_gate(_fake_results([0.05, 0.02], ["Random", "Other"]))
        r.check("crag_gate", none == "none", f"very low score -> none (got {none!r})")
    except NotImplementedError:
        r.skip("crag_gate", "TODO 2b not implemented")
    except Exception as e:  # noqa: BLE001
        r.fail("crag_gate", f"raised: {e}")


def check_packing(sol, r: Report) -> None:
    results = _fake_results(
        [0.9, 0.88, 0.7, 0.5],
        ["Paris", "Paris", "Eiffel Tower", "Eiffel Tower"],
        ["Paris is the capital of France.", "Paris is the capital of France.",  # duplicate
         "The Eiffel Tower is in Paris.", "It was built in 1889."],
    )
    try:
        ctx = sol.packing.assemble_context(results, token_budget=1000)
        r.check("assemble_context", isinstance(ctx, str) and ctx.strip(), "returns non-empty string")
        r.check("assemble_context", "[Source:" in ctx, "labels chunks with [Source: Title]")
        r.check("assemble_context", "Paris" in ctx and "Eiffel Tower" in ctx, "keeps diverse sources")
        r.check("assemble_context", ctx.count("Paris is the capital of France.") == 1, "deduplicates identical chunks")
    except NotImplementedError:
        r.skip("assemble_context", "TODO 3 not implemented")
    except Exception as e:  # noqa: BLE001
        r.fail("assemble_context", f"raised: {e}")


def check_faithfulness(sol, r: Report) -> None:
    ModelRetry = _model_retry()
    try:
        grounded = sol.validation.check_faithfulness("Paris is in France [Source: Paris].", ["Paris"])
        r.check("faithfulness", isinstance(grounded, str), "grounded answer passes")
        refusal = sol.validation.check_faithfulness("I don't have enough information.", [])
        r.check("faithfulness", isinstance(refusal, str), "refusal passes")
        # anti-gaming: cited source NOT among retrieved must be rejected
        try:
            sol.validation.check_faithfulness("Mars is red [Source: Mars].", ["Paris"])
            r.fail("faithfulness", "GAMING: fabricated [Source: Mars] should raise ModelRetry")
        except ModelRetry:
            r.ok("faithfulness", "fabricated citation raises ModelRetry (anti-gaming)")
        # no citations must be rejected
        try:
            sol.validation.check_faithfulness("Paris is the best city ever.", ["Paris"])
            r.fail("faithfulness", "answer without citations should raise ModelRetry")
        except ModelRetry:
            r.ok("faithfulness", "missing citations raises ModelRetry")
    except NotImplementedError:
        r.skip("faithfulness", "TODO 5 not implemented")
    except Exception as e:  # noqa: BLE001
        r.fail("faithfulness", f"raised: {e}")


def check_metrics(r: Report) -> None:
    import harness
    r.check("metrics.recall", abs(harness.recall_at_k(["Paris", "X", "Y"], ["Paris", "France"]) - 0.5) < 1e-9, "recall@k = 0.5 for 1/2 expected")
    r.check("metrics.mrr", abs(harness.reciprocal_rank(["X", "Paris"], ["Paris"]) - 0.5) < 1e-9, "reciprocal rank = 0.5 at rank 2")
    r.check("metrics.precision", abs(harness.precision_at_k(["Paris", "X"], ["Paris"], 2) - 0.5) < 1e-9, "precision@2 = 0.5")


def check_search_shape(sol, r: Report) -> None:
    """Test search sorting/shape with a fake encoder — no model download."""
    import numpy as np

    class FakeEncoder:
        def encode(self, text, convert_to_numpy=True):
            rng = np.random.default_rng(abs(hash(text)) % (2**32))
            return rng.standard_normal(sol.config.EMBED_DIM).astype("float32")

    try:
        deps = sol.data.WikiDeps(titles=["A", "B", "C"], texts=["ta", "tb", "tc"], urls=["", "", ""], encoder=FakeEncoder())
        deps.chunks = [{"chunk_id": i, "article_title": t, "text": f"chunk {t}"} for i, t in enumerate(["A", "B", "C"])]
        rng = np.random.default_rng(0)
        deps.chunk_embeddings = rng.standard_normal((3, sol.config.EMBED_DIM)).astype("float32")
        out = sol.retrieval.search(deps, "query", top_k=2)
        r.check("search", isinstance(out, list) and len(out) == 2, f"returns top_k results (got {len(out)})")
        keys = set(out[0].keys()) if out else set()
        r.check("search", {"chunk_id", "article_title", "text", "score"} <= keys, "result dict has required keys incl. score")
        r.check("search", out[0]["score"] >= out[-1]["score"], "results sorted by score desc")
    except NotImplementedError:
        r.skip("search", "TODO 2a not implemented")
    except Exception as e:  # noqa: BLE001
        r.fail("search", f"raised: {e}")


def _model_retry():
    from pydantic_ai import ModelRetry
    return ModelRetry


# --------------------------------------------------------------------------
# Ablation (needs the real model; optional)
# --------------------------------------------------------------------------

def run_ablation(sol, r: Report) -> None:
    import harness
    try:
        from sentence_transformers import SentenceTransformer
        encoder = SentenceTransformer(sol.config.ENCODER_NAME)
    except Exception as e:  # noqa: BLE001
        r.skip("ablation", f"model unavailable ({type(e).__name__}) — skipping full index build")
        return

    import time

    articles = sol.data.load_corpus()
    deps = sol.data.build_deps(articles, encoder=encoder)
    golden = harness.load_golden()

    print("\n  Ablation (chunk_size sweep):")
    header = (f"    {'config':<20}{'rec(single)':>12}{'rec(multi)':>11}{'prec@k':>8}"
              f"{'mrr':>7}{'refusal':>9}{'ret_ms':>8}{'build_ms':>10}{'n_chunks':>10}")
    print(header)
    for chunk_size in (200, 400, 700):
        try:
            t0 = time.perf_counter()
            sol.indexing.build_index(deps, chunk_size, sol.config.CHUNK_OVERLAP)
            build_ms = (time.perf_counter() - t0) * 1000.0
        except NotImplementedError:
            r.skip("ablation", "build_index (TODO 1b) not implemented")
            return
        n_chunks = len(deps.chunks)
        res = harness.evaluate_retrieval(sol, deps, golden, sol.config.TOP_K, label=f"chunk={chunk_size}")
        res.index_build_ms = build_ms
        row = res.as_row()
        print(f"    {row['config']:<20}{row['recall_single']:>12}{row['recall_multi']:>11}"
              f"{row['precision_single']:>8}{row['mrr_single']:>7}{row['refusal_acc']:>9}"
              f"{row['retrieval_ms']:>8}{row['index_build_ms']:>10}{n_chunks:>10}")
    r.ok("ablation", "chunk-size sweep completed")
    print("    note: rec(multi) is RAW retrieval (no decomposition) → expected to be LOW.")
    print("          The chat pipeline fixes multi-hop via query decomposition (fan-out).")
    print("          retrieval-only sweep = 0 LLM calls, $0; LLM cost is computed in results.md.")


# --------------------------------------------------------------------------
# Main
# --------------------------------------------------------------------------

def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--ablation", action="store_true", help="build full index and run golden-set metrics (needs model)")
    args = ap.parse_args()

    print("=" * 60)
    print(f"  RAG Homework v3 Validation   (RAG_PKG={PKG})")
    print("=" * 60)

    try:
        sol = load_solution()
    except Exception as e:  # noqa: BLE001
        print(f"  Could not import package {PKG!r}: {e}")
        sys.exit(1)

    r = Report()

    print("\n  Structural checks:")
    for sub in SUBMODULES:
        present = hasattr(sol, sub)
        r.check("structure", present, f"module {PKG}.{sub} importable")
    for fn_path in ["indexing.chunk_text", "indexing.build_index", "retrieval.search",
                    "retrieval.crag_gate", "packing.assemble_context",
                    "query_transform.rewrite_query", "validation.check_faithfulness",
                    "security.sanitize_context"]:
        mod, fn = fn_path.split(".")
        r.check("structure", callable(getattr(getattr(sol, mod), fn, None)), f"{PKG}.{fn_path} is callable")

    print("\n  Behavioral checks (no model / no API key needed):")
    check_chunking(sol, r)
    check_search_shape(sol, r)
    check_crag_gate(sol, r)
    check_packing(sol, r)
    check_faithfulness(sol, r)
    check_metrics(r)

    if not os.environ.get("OPENROUTER_API_KEY"):
        r.skip("rewrite_query", "OPENROUTER_API_KEY not set — LLM checks skipped")

    if args.ablation:
        run_ablation(sol, r)
    else:
        print("\n  (run with --ablation to build the full index and compute golden-set metrics)")

    print("\n" + "=" * 60)
    print(f"  {r.passed} passed · {r.failed} failed · {r.skipped} skipped")
    if r.failed:
        print("\n  Failures:")
        for f in r.failures:
            print(f"    - {f}")
        print("=" * 60)
        sys.exit(1)
    print("=" * 60)
    sys.exit(0)


if __name__ == "__main__":
    main()

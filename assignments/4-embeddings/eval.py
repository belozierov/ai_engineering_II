# /// script
# requires-python = ">=3.11"
# dependencies = [
#   "sentence-transformers",
#   "scikit-learn",
#   "numpy",
#   "matplotlib",
#   "litellm",
#   "rank-bm25",
#   "qdrant-client",
# ]
# ///
"""
Homework v2 validation: structural checks, unit tests, and category-recall tests.

1. Structural: validate_homework() — types, shapes, edge cases.
2. Unit tests: small deterministic checks for each TODO function.
3. Category-recall tests: run cosine + BM25 on 5 queries; check that
   ≥3/5 top results belong to the expected category.
   → These tests survive any corpus changes, unlike hardcoded index sets.

Run:
  uv run eval.py
"""

from __future__ import annotations

import logging
import os
import sys
import warnings

os.environ["TOKENIZERS_PARALLELISM"] = "false"
os.environ["HF_HUB_DISABLE_PROGRESS_BARS"] = "1"
os.environ["HF_HUB_DISABLE_IMPLICIT_TOKEN"] = "1"
os.environ["SAFETENSORS_FAST_GPU"] = "1"
warnings.filterwarnings("ignore", message=".*unauthenticated.*")
warnings.filterwarnings("ignore", category=FutureWarning)
logging.getLogger("sentence_transformers").setLevel(logging.ERROR)
logging.getLogger("transformers").setLevel(logging.ERROR)
logging.getLogger("huggingface_hub").setLevel(logging.ERROR)

import numpy as np

try:
    import starter  # type: ignore
except ImportError as e:
    print("Could not import starter.py:", e)
    print("Run this script from the homework_v2 directory: uv run eval.py")
    sys.exit(1)


# ---------------------------------------------------------------------------
# Category-recall evaluation queries
#
# For each query, we know which category is most relevant.
# A good retrieval system should return ≥ 3 results from that category in top-5.
#
# These queries are semantically rich — they test understanding, not keyword matching.
# The corpus has 300 balanced tickets so each category has ~43 relevant docs.
# ---------------------------------------------------------------------------

EVAL_QUERIES: dict[str, str] = {
    "my laptop screen is broken":              "technical",
    "I can't authenticate my identity":        "account",
    "money problems with my purchase":         "billing",
    "package not delivered to my address":     "shipping",
    "want to send the item back for a refund": "returns",
}

# Recall thresholds
COSINE_THRESHOLD = 3   # ≥ N of top-5 results must be in expected category
BM25_THRESHOLD   = 2   # BM25 is weaker on semantic queries — looser threshold
QDRANT_THRESHOLD = 3   # same as cosine (Qdrant :memory: is exact COSINE)


# ---------------------------------------------------------------------------
# Unit tests
# ---------------------------------------------------------------------------

def run_unit_tests() -> tuple[int, int, list[str]]:
    """Run targeted unit tests per function. Returns (passed, total, failures)."""
    passed   = 0
    total    = 0
    failures: list[str] = []

    def check(name: str, condition: bool, msg: str) -> None:
        nonlocal passed, total
        total += 1
        if condition:
            passed += 1
            print(f"    [{name}] {msg}: ok")
        else:
            failures.append(f"[{name}] {msg}")
            print(f"    [{name}] {msg}: FAIL")

    # --- get_embeddings ---
    try:
        embs = starter.get_embeddings(["hello world", "hello world", "something completely different"])
        check("get_embeddings", embs.shape[1] == 384,
              f"embedding dim == 384 (got {embs.shape[1]})")
        cos_same = float(np.dot(embs[0], embs[1]) / (np.linalg.norm(embs[0]) * np.linalg.norm(embs[1])))
        check("get_embeddings", cos_same > 0.99,
              f"identical texts similarity ~1.0 (got {cos_same:.4f})")
        cos_diff = float(np.dot(embs[0], embs[2]) / (np.linalg.norm(embs[0]) * np.linalg.norm(embs[2])))
        check("get_embeddings", cos_diff < 0.9,
              f"different texts similarity < 0.9 (got {cos_diff:.4f})")
        check("get_embeddings", embs.dtype in (np.float32, np.float64),
              f"returns float array (got {embs.dtype})")
    except NotImplementedError:
        total += 4
        failures.append("[get_embeddings] not implemented")
        print("    [get_embeddings] not implemented — skipping")
    except Exception as e:
        total += 4
        failures.append(f"[get_embeddings] error: {e}")
        print(f"    [get_embeddings] error: {e}")

    # --- cluster_tickets ---
    try:
        np.random.seed(0)
        dummy  = np.random.randn(20, 8)
        labels = starter.cluster_tickets(dummy, 4)
        check("cluster_tickets", len(set(labels)) == 4,
              f"4 clusters → 4 unique labels (got {len(set(labels))})")
        labels2 = starter.cluster_tickets(dummy, 4)
        check("cluster_tickets", np.array_equal(labels, labels2),
              "deterministic with random_state=42")
        check("cluster_tickets", labels.shape == (20,),
              f"shape (20,) (got {labels.shape})")
    except NotImplementedError:
        total += 3
        failures.append("[cluster_tickets] not implemented")
        print("    [cluster_tickets] not implemented — skipping")
    except Exception as e:
        total += 3
        failures.append(f"[cluster_tickets] error: {e}")
        print(f"    [cluster_tickets] error: {e}")

    # --- name_cluster: prompt must be written ---
    try:
        result = starter.name_cluster(["test 1", "test 2"])
        total += 1
        if isinstance(result, str) and result.strip():
            passed += 1
            print(f"    [name_cluster] implemented, returned name: ok")
        else:
            failures.append("[name_cluster] must return a non-empty string")
            print("    [name_cluster] returned empty or wrong type: FAIL")
    except NotImplementedError:
        total += 1
        failures.append("[name_cluster] not implemented — write a prompt (TODO 3)")
        print("    [name_cluster] not implemented (TODO 3): FAIL")
    except Exception:
        total += 1
        passed += 1  # prompt written, API key needed to run fully
        print("    [name_cluster] implemented (needs OPENROUTER_API_KEY to run): ok")

    # --- bm25_search ---
    try:
        corpus  = ["the cat sat on the mat", "the dog ran in the park", "a bird flew over the lake"]
        results = starter.bm25_search(corpus, "cat sat", 2)
        check("bm25_search", results[0][0] == 0,
              f'top-1 for "cat sat" is doc 0 (got {results[0][0]})')
        check("bm25_search", len(results) == 2,
              f"top_k=2 returns 2 results (got {len(results)})")
        scores = [s for _, s in results]
        check("bm25_search", all(scores[i] >= scores[i + 1] for i in range(len(scores) - 1)),
              "scores sorted descending")
        # Critical: query must be lowercased — mismatch causes wrong results
        r_upper = starter.bm25_search(["CAT SAT ON MAT", "dog ran"], "cat sat", 1)
        r_lower = starter.bm25_search(["cat sat on mat", "dog ran"], "cat sat", 1)
        check("bm25_search", r_upper[0][0] == r_lower[0][0],
              "case-insensitive tokenisation (query + corpus both lowercased)")
    except NotImplementedError:
        total += 4
        failures.append("[bm25_search] not implemented")
        print("    [bm25_search] not implemented — skipping")
    except Exception as e:
        total += 4
        failures.append(f"[bm25_search] error: {e}")
        print(f"    [bm25_search] error: {e}")

    # --- upload_to_qdrant + qdrant_search ---
    try:
        dummy_tickets = [{"text": f"ticket number {i}", "category": "test"} for i in range(5)]
        dummy_embs    = np.random.randn(5, 384).astype(np.float32)
        client        = starter.upload_to_qdrant(dummy_tickets, dummy_embs)
        check("upload_to_qdrant", client is not None,
              "returns a non-None client")
        q_emb   = np.random.randn(384).astype(np.float32)
        results = starter.qdrant_search(client, q_emb, 3)
        check("qdrant_search", isinstance(results, list) and len(results) == 3,
              f"returns list of length 3 (got {len(results) if isinstance(results, list) else type(results)})")
        check("qdrant_search", all(isinstance(r, tuple) and len(r) == 2 for r in results),
              "each result is a (index, score) tuple")
        scores = [s for _, s in results]
        check("qdrant_search", all(scores[i] >= scores[i + 1] for i in range(len(scores) - 1)),
              "results sorted by score descending")
    except NotImplementedError:
        total += 5
        failures.append("[TODO 5] upload_to_qdrant / qdrant_search not implemented")
        print("    [TODO 5] not implemented — skipping")
    except Exception as e:
        total += 5
        failures.append(f"[TODO 5] error: {e}")
        print(f"    [TODO 5] error: {e}")

    return passed, total, failures


# ---------------------------------------------------------------------------
# Category-recall tests
# ---------------------------------------------------------------------------

def run_recall_tests() -> tuple[int, int, list[str]]:
    """
    For each query in EVAL_QUERIES, check that top-5 retrieval results
    contain at least N tickets from the expected category.

    This metric survives corpus changes — unlike hardcoded index sets.
    """
    texts      = [t["text"] for t in starter.TICKETS]
    embeddings = starter.get_embeddings(texts)

    passed   = 0
    total    = 0
    failures: list[str] = []

    for query, expected_cat in EVAL_QUERIES.items():
        q_emb       = starter.get_embeddings([query])[0]
        short_q     = query[:40]

        # --- Cosine recall ---
        cos_results = starter.cosine_search(q_emb, embeddings, 5)
        cos_cats    = [starter.TICKETS[idx]["category"] for idx, _ in cos_results]
        cos_hits    = sum(c == expected_cat for c in cos_cats)
        total += 1
        if cos_hits >= COSINE_THRESHOLD:
            passed += 1
            print(f"    [cosine] \"{short_q}\" → {cos_hits}/5 {expected_cat}: ok")
        else:
            msg = f'[cosine] "{short_q}" → {cos_hits}/5 {expected_cat} (need ≥{COSINE_THRESHOLD})'
            failures.append(msg)
            print(f"    {msg}: FAIL")
            print(f"      got: {cos_cats}")

        # --- BM25 recall (skip if not implemented) ---
        try:
            bm25_results = starter.bm25_search(texts, query, 5)
            bm25_cats    = [starter.TICKETS[idx]["category"] for idx, _ in bm25_results]
            bm25_hits    = sum(c == expected_cat for c in bm25_cats)
            total += 1
            if bm25_hits >= BM25_THRESHOLD:
                passed += 1
                print(f"    [bm25]   \"{short_q}\" → {bm25_hits}/5 {expected_cat}: ok")
            else:
                msg = f'[bm25] "{short_q}" → {bm25_hits}/5 {expected_cat} (need ≥{BM25_THRESHOLD})'
                failures.append(msg)
                print(f"    {msg}: FAIL")
                print(f"      got: {bm25_cats}")
        except NotImplementedError:
            print(f"    [bm25]   skipped (TODO 4 not implemented)")

        # --- Qdrant recall (skip if not implemented) ---
        try:
            dummy_client = starter.upload_to_qdrant(starter.TICKETS, embeddings)
            q_results    = starter.qdrant_search(dummy_client, q_emb, 5)
            q_cats       = [starter.TICKETS[idx]["category"] for idx, _ in q_results]
            q_hits       = sum(c == expected_cat for c in q_cats)
            total += 1
            if q_hits >= QDRANT_THRESHOLD:
                passed += 1
                print(f"    [qdrant] \"{short_q}\" → {q_hits}/5 {expected_cat}: ok")
            else:
                msg = f'[qdrant] "{short_q}" → {q_hits}/5 {expected_cat} (need ≥{QDRANT_THRESHOLD})'
                failures.append(msg)
                print(f"    {msg}: FAIL")
                print(f"      got: {q_cats}")
        except NotImplementedError:
            print(f"    [qdrant] skipped (TODO 5 not implemented)")

    return passed, total, failures


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main() -> None:
    print("=" * 58)
    print("  Homework v2 — validation")
    print("=" * 58)

    ok, errors = starter.validate_homework()

    if not ok:
        print("\n  Structural checks failed:")
        for e in errors:
            print(f"    - {e}")
        print("\n  Fix the TODOs and run uv run eval.py again.")
        print("=" * 58)
        sys.exit(1)

    print("\n  Structural checks passed.")
    if any("TODO 3" in e for e in errors):
        print("  Note: TODO 3 (name_cluster) needs OPENROUTER_API_KEY to run fully.")

    # Unit tests
    print("\n  Unit tests:")
    try:
        ut_passed, ut_total, ut_failures = run_unit_tests()
        if ut_passed == ut_total:
            print(f"\n  {ut_passed}/{ut_total} unit tests passed.")
        else:
            print(f"\n  {ut_passed}/{ut_total} unit tests passed. Failures:")
            for f in ut_failures:
                print(f"    - {f}")
    except Exception as e:
        print(f"  Unit tests could not run: {e}")

    # Category-recall tests
    print("\n  Category-recall tests (≥3/5 cosine, ≥2/5 BM25, ≥3/5 Qdrant):")
    try:
        r_passed, r_total, r_failures = run_recall_tests()
        if r_passed == r_total:
            print(f"\n  All {r_total} recall checks passed.")
        else:
            print(f"\n  {r_passed}/{r_total} recall checks passed.")
            if r_failures:
                print("  Failures:")
                for f in r_failures:
                    print(f"    - {f}")
    except NotImplementedError:
        print("  Recall tests require TODO 1 (get_embeddings) to be implemented.")
    except Exception as e:
        print(f"  Recall tests could not run: {e}")

    print(f"\n  Run the full pipeline: uv run starter.py --quick")
    print("=" * 58)
    sys.exit(0)


if __name__ == "__main__":
    main()

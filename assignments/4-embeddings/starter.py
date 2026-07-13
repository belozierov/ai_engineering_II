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
Homework: Ticket Auto-Categorization with Embeddings

Pipeline:
  embed tickets → k-means clustering → LLM names clusters
  → compare BM25 / cosine / Qdrant → Ticket Helper

Your tasks (5 TODOs + 1 bonus in this file):
  1) get_embeddings(texts)               — sentence-transformers
  2) cluster_tickets(embeddings, n)      — k-means
  3) name_cluster(tickets)               — write the LLM prompt
  4) bm25_search(corpus, query, top_k)   — rank_bm25
  5) upload_to_qdrant(tickets, embeddings) + qdrant_search(client, query_emb, top_k)
                                         — Qdrant :memory: (no Docker needed!)
  BONUS) rerank(query, candidates, model_key) — CrossEncoder model comparison

Already implemented (read code + docstrings to understand):
  - cosine_search    — brute-force numpy baseline for comparison
  - fusion_search    — Reciprocal Rank Fusion (BM25 + cosine)
  - compute_ari      — clustering quality vs ground-truth categories
  - Ticket Helper, t-SNE visualization, comparison table

Setup:
  export OPENROUTER_API_KEY="sk-or-..."   # for TODO 3 (LLM cluster naming)

Run:
  uv run starter.py --quick               # skip LLM naming; runs demo queries
  uv run starter.py                       # full pipeline with LLM cluster naming
  uv run starter.py --query "can't log in"
  uv run starter.py --rerank --query "laptop broken"   # bonus: reranker comparison

Validate:
  uv run eval.py
"""

from __future__ import annotations

import argparse
import json
import logging
import os
import time
import warnings
from pathlib import Path

os.environ["TOKENIZERS_PARALLELISM"] = "false"
os.environ["HF_HUB_DISABLE_PROGRESS_BARS"] = "1"
os.environ["HF_HUB_DISABLE_IMPLICIT_TOKEN"] = "1"
os.environ["SAFETENSORS_FAST_GPU"] = "1"
warnings.filterwarnings("ignore", message=".*unauthenticated.*")
warnings.filterwarnings("ignore", category=FutureWarning)
logging.getLogger("sentence_transformers").setLevel(logging.ERROR)
logging.getLogger("transformers").setLevel(logging.ERROR)
logging.getLogger("huggingface_hub").setLevel(logging.ERROR)

import matplotlib.pyplot as plt
import numpy as np
from sklearn.cluster import KMeans
from sklearn.manifold import TSNE
from sklearn.metrics import adjusted_rand_score

import litellm
from litellm import completion

litellm.suppress_debug_info = True

# ---------------------------------------------------------------------------
# CONFIG
# ---------------------------------------------------------------------------

MODEL_LLM          = "openrouter/google/gemini-2.5-flash"
EMBED_MODEL        = "all-MiniLM-L6-v2"
DEFAULT_N_CLUSTERS = 5      # deliberately suboptimal — your job is to find the best k!
TOP_K              = 5
COLLECTION         = "tickets"

# Three reranker models for the bonus comparison.
# They are ordered from weakest (fast) to strongest (best quality):
#   ms-marco  — trained on passage-level Q&A; fast on CPU but poor on short texts
#   bge-base  — general English reranker; better for short documents
#   bge-v2-m3 — multilingual, state-of-the-art for retrieval reranking (71.5% BEIR)
RERANKER_MODELS = {
    "ms-marco":  "cross-encoder/ms-marco-MiniLM-L-6-v2",
    "bge-base":  "BAAI/bge-reranker-base",
    "bge-v2-m3": "BAAI/bge-reranker-v2-m3",
}

# Five queries → expected category (used to print recall@5 after each query).
DEMO_QUERIES: dict[str, str] = {
    "my laptop screen is broken":              "technical",
    "I can't authenticate my identity":        "account",
    "money problems with my purchase":         "billing",
    "package not delivered to my address":     "shipping",
    "want to send the item back for a refund": "returns",
}

# ---------------------------------------------------------------------------
# DATASET — load from data/tickets.json (300 synthetic support tickets)
# ---------------------------------------------------------------------------

_DATA_PATH = Path(__file__).parent / "data" / "tickets.json"
TICKETS: list[dict] = json.loads(_DATA_PATH.read_text())


# ---------------------------------------------------------------------------
# TODO 1: GET EMBEDDINGS
# ---------------------------------------------------------------------------

def get_embeddings(texts: list[str]) -> np.ndarray:
    """
    Generate embeddings for a list of texts using sentence-transformers.

    Use the model 'all-MiniLM-L6-v2' and return a numpy array of shape
    (len(texts), 384). Make sure to return a numpy array, not a tensor.

    Hint:
        from sentence_transformers import SentenceTransformer
        model = SentenceTransformer("all-MiniLM-L6-v2")
        return model.encode(texts, convert_to_numpy=True)
    """
    # TODO: implement
    raise NotImplementedError("TODO 1: implement get_embeddings")


# ---------------------------------------------------------------------------
# TODO 2: CLUSTER TICKETS
# ---------------------------------------------------------------------------

def cluster_tickets(embeddings: np.ndarray, n_clusters: int) -> np.ndarray:
    """
    Cluster embeddings using K-Means (sklearn).

    Args:
        embeddings: numpy array of shape (n_samples, embedding_dim)
        n_clusters: number of clusters

    Returns:
        numpy array of cluster labels, shape (n_samples,)

    Use random_state=42 for reproducibility.

    After implementing, run with different values of --clusters (try 3–12)
    and record the ARI score each time. Find the k that maximises ARI and
    justify your choice in results.md.

    Hint:
        from sklearn.cluster import KMeans
        kmeans = KMeans(n_clusters=n_clusters, random_state=42, n_init=10)
        return kmeans.fit_predict(embeddings)
    """
    # TODO: implement
    raise NotImplementedError("TODO 2: implement cluster_tickets")


# ---------------------------------------------------------------------------
# TODO 3: NAME CLUSTER VIA LLM
# ---------------------------------------------------------------------------

def name_cluster(tickets: list[str]) -> str:
    """
    Given a list of ticket texts from the same cluster, ask an LLM
    to produce a short category name (2-4 words).

    Your job: write the `prompt` variable below.
    The LLM call and response parsing are already done.

    Example prompt structure:
        These are customer support tickets grouped together:
        - <ticket 1>
        - <ticket 2>
        ...
        What short category name (2-4 words) best describes this group?
        Reply with ONLY the category name, nothing else.
    """
    prompt = ""  # <-- replace with your prompt that includes the tickets

    if not prompt.strip():
        raise NotImplementedError(
            "TODO 3: write a prompt — replace the empty string above with a "
            "prompt that includes the ticket texts and asks for a cluster name."
        )

    response = completion(
        model=MODEL_LLM,
        messages=[{"role": "user", "content": prompt}],
        temperature=0.0,
    )
    return (response.choices[0].message.content or "").strip()


# ---------------------------------------------------------------------------
# PRE-BUILT: COSINE SIMILARITY SEARCH (brute-force numpy baseline)
# ---------------------------------------------------------------------------

def cosine_search(
    query_emb: np.ndarray,
    all_embs: np.ndarray,
    top_k: int = 5,
) -> list[tuple[int, float]]:
    """
    Brute-force cosine similarity search (pre-built — keep for comparison).

    Cosine similarity: cos(a, b) = (a · b) / (||a|| * ||b||)
    Normalized vectors: cosine similarity = dot product.

    Algorithm:
        1. Normalize query to unit length.
        2. Normalize all embeddings row-wise.
        3. Matrix-multiply → all cosine similarities in one step.
        4. Return top_k (index, score) pairs sorted descending.

    This is O(n) per query — fine for hundreds of docs, slow for millions.
    TODO 5 (Qdrant) replaces this with approximate nearest-neighbour search.
    """
    query_norm = query_emb / (np.linalg.norm(query_emb) + 1e-10)
    all_norms  = all_embs / (np.linalg.norm(all_embs, axis=1, keepdims=True) + 1e-10)
    sims       = all_norms @ query_norm
    top_idx    = np.argsort(sims)[::-1][:top_k]
    return [(int(i), float(sims[i])) for i in top_idx]


# ---------------------------------------------------------------------------
# TODO 4: BM25 KEYWORD SEARCH
# ---------------------------------------------------------------------------

def bm25_search(
    corpus: list[str],
    query: str,
    top_k: int = 5,
) -> list[tuple[int, float]]:
    """
    Keyword search using BM25 (Okapi BM25).

    BM25 ranks documents by term frequency and inverse document frequency.
    It matches EXACT word tokens — "authenticate" will NOT find "login".
    This difference from cosine is exactly what makes the comparison interesting.

    Use the rank_bm25 library (BM25Okapi class).

    Steps:
        1. Tokenize: lowercase + split on spaces (both corpus and query).
        2. Create BM25Okapi index from tokenized corpus.
        3. Score the query against all documents.
        4. Return top_k (index, score) pairs sorted by score descending.

    Hint:
        from rank_bm25 import BM25Okapi
        tokenized = [doc.lower().split() for doc in corpus]
        bm25 = BM25Okapi(tokenized)
        scores = bm25.get_scores(query.lower().split())
        # sort indices by score descending, take top_k
    """
    # TODO: implement
    raise NotImplementedError("TODO 4: implement bm25_search")


# ---------------------------------------------------------------------------
# TODO 5: QDRANT IN-MEMORY SEARCH
# ---------------------------------------------------------------------------

def upload_to_qdrant(
    tickets: list[dict],
    embeddings: np.ndarray,
) -> "QdrantClient":  # type: ignore[name-defined]
    """
    Upload all tickets to an in-memory Qdrant collection and return the client.

    KEY INSIGHT: QdrantClient(":memory:") runs fully in-process — no Docker,
    no server, no setup required. This is identical to the production API,
    just stored in RAM instead of on disk.

    Steps:
        a) Create: client = QdrantClient(":memory:")
        b) Create collection:
               client.create_collection(
                   collection_name=COLLECTION,
                   vectors_config=VectorParams(size=384, distance=Distance.COSINE),
               )
        c) Build PointStruct list:
               PointStruct(id=i, vector=emb.tolist(),
                           payload={"text": t["text"], "category": t["category"]})
        d) Upload in one batch: client.upsert(COLLECTION, points)
        e) Return client

    Imports you'll need:
        from qdrant_client import QdrantClient
        from qdrant_client.models import Distance, PointStruct, VectorParams

    Returns:
        QdrantClient — pass this to qdrant_search() for querying.
    """
    # TODO: implement
    raise NotImplementedError("TODO 5a: implement upload_to_qdrant")


def qdrant_search(
    client: "QdrantClient",  # type: ignore[name-defined]
    query_emb: np.ndarray,
    top_k: int = 5,
) -> list[tuple[int, float]]:
    """
    Search the in-memory Qdrant collection.

    Steps:
        results = client.query_points(
            collection_name=COLLECTION,
            query=query_emb.tolist(),
            limit=top_k,
        ).points
        return [(point.id, point.score) for point in results]

    Returns:
        List of (index, score) tuples, sorted by score descending (Qdrant does this).

    Compare the results with cosine_search — they should be nearly identical
    because Qdrant :memory: uses exact COSINE distance (no approximation at this size).
    The difference becomes visible at scale (100K+ vectors).
    """
    # TODO: implement
    raise NotImplementedError("TODO 5b: implement qdrant_search")


# ---------------------------------------------------------------------------
# BONUS: RERANKER COMPARISON
# ---------------------------------------------------------------------------

def rerank(
    query: str,
    candidate_texts: list[str],
    model_key: str = "bge-v2-m3",
) -> list[tuple[str, float]]:
    """
    BONUS: Re-rank candidates using a cross-encoder model.

    A cross-encoder receives (query, document) as a SINGLE input and
    produces one relevance score per pair — it can see attention between
    all query and document tokens, making it more accurate than cosine.
    Trade-off: requires one forward pass per pair → O(n) at query time.

    Use sentence-transformers CrossEncoder:
        from sentence_transformers import CrossEncoder
        model = CrossEncoder(RERANKER_MODELS[model_key])
        pairs = [[query, text] for text in candidate_texts]
        scores = model.predict(pairs)
        ranked = sorted(zip(candidate_texts, scores),
                        key=lambda x: x[1], reverse=True)
        return ranked

    Args:
        query:           the search query
        candidate_texts: list of document strings to re-rank
        model_key:       one of "ms-marco", "bge-base", "bge-v2-m3"

    Returns:
        List of (text, score) tuples sorted by relevance score descending.
    """
    # TODO (bonus): implement
    raise NotImplementedError(
        f"BONUS: implement rerank() using CrossEncoder({RERANKER_MODELS[model_key]})"
    )


# ---------------------------------------------------------------------------
# PRE-BUILT: RECIPROCAL RANK FUSION (RRF)
# ---------------------------------------------------------------------------

def fusion_search(
    bm25_results:   list[tuple[int, float]],
    cosine_results: list[tuple[int, float]],
    top_k: int  = 5,
    rrf_k:  int = 60,
) -> list[tuple[int, float]]:
    """
    Reciprocal Rank Fusion (pre-built): combine BM25 + cosine rankings.

    score(doc) = Σ  1 / (rrf_k + rank_in_method)
    Documents ranked high by BOTH methods get the highest combined score.
    rrf_k=60 is the standard constant from the original RRF paper.
    """
    scores: dict[int, float] = {}
    for rank, (idx, _) in enumerate(bm25_results, start=1):
        scores[idx] = scores.get(idx, 0.0) + 1.0 / (rrf_k + rank)
    for rank, (idx, _) in enumerate(cosine_results, start=1):
        scores[idx] = scores.get(idx, 0.0) + 1.0 / (rrf_k + rank)
    sorted_ids = sorted(scores.items(), key=lambda x: x[1], reverse=True)[:top_k]
    return [(idx, float(s)) for idx, s in sorted_ids]


# ---------------------------------------------------------------------------
# PRE-BUILT: CLUSTERING QUALITY — ARI
# ---------------------------------------------------------------------------

def compute_ari(tickets: list[dict], labels: np.ndarray) -> float:
    """
    Adjusted Rand Index: measures how well clusters match ground-truth categories.

    ARI = 0.0  → clustering is no better than random
    ARI = 1.0  → perfect match with the 7 categories
    ARI < 0    → worse than random (shouldn't happen with reasonable k-means)

    Try different n_clusters (5–10) and observe how ARI changes!
    The 7 ground-truth categories are in tickets[i]["category"].
    """
    true_labels  = [t["category"] for t in tickets]
    return adjusted_rand_score(true_labels, labels)


# ---------------------------------------------------------------------------
# PRE-BUILT: VISUALIZATION
# ---------------------------------------------------------------------------

def visualize_clusters(
    embeddings:    np.ndarray,
    labels:        np.ndarray,
    cluster_names: dict[int, str] | None = None,
) -> None:
    """Reduce to 2D with t-SNE and plot colored by cluster."""
    print("\n  Running t-SNE for visualization...")
    tsne   = TSNE(n_components=2, random_state=42, perplexity=min(30, len(embeddings) - 1))
    coords = tsne.fit_transform(embeddings)

    plt.figure(figsize=(11, 7))
    unique_labels = sorted(set(labels))
    cmap = plt.colormaps.get_cmap("tab10").resampled(len(unique_labels))

    for label in unique_labels:
        mask = labels == label
        name = cluster_names.get(label, f"Cluster {label}") if cluster_names else f"Cluster {label}"
        plt.scatter(coords[mask, 0], coords[mask, 1], c=[cmap(label)], label=name, s=45, alpha=0.75)

    plt.legend(fontsize=8, loc="best")
    plt.title("Ticket Clusters — t-SNE (300 tickets)", fontsize=13)
    plt.tight_layout()
    plt.savefig("clusters.png", dpi=150)
    print("  Saved: clusters.png")
    plt.close()


# ---------------------------------------------------------------------------
# PRE-BUILT: COMPARISON TABLE
# ---------------------------------------------------------------------------

def compare_and_print(
    query:             str,
    query_emb:         np.ndarray,
    all_embs:          np.ndarray,
    tickets:           list[dict],
    qdrant_client:     object | None = None,
    expected_category: str | None = None,
) -> dict:
    """Run BM25, cosine, fusion (and optionally Qdrant); print timing, overlap, recall@5.

    Returns dict of {method_key: {"recall": int|None, "latency_ms": float}}
    for use in the summary table.
    """
    corpus = [t["text"] for t in tickets]
    print(f"\n  Query: \"{query}\"")
    print("=" * 72)

    t0 = time.perf_counter()
    try:
        bm25_results = bm25_search(corpus, query, TOP_K)
        t_bm25 = (time.perf_counter() - t0) * 1000
    except NotImplementedError:
        bm25_results = None
        t_bm25 = 0.0
        print("  [BM25] Not implemented (TODO 4)")

    t0 = time.perf_counter()
    cosine_results = cosine_search(query_emb, all_embs, TOP_K)
    t_cosine = (time.perf_counter() - t0) * 1000

    fusion_results: list[tuple[int, float]] | None = None
    t_fusion = 0.0
    if bm25_results is not None:
        t0 = time.perf_counter()
        fusion_results = fusion_search(bm25_results, cosine_results, TOP_K)
        t_fusion = (time.perf_counter() - t0) * 1000

    qdrant_results: list[tuple[int, float]] | None = None
    t_qdrant = 0.0
    if qdrant_client is not None:
        try:
            t0 = time.perf_counter()
            qdrant_results = qdrant_search(qdrant_client, query_emb, TOP_K)
            t_qdrant = (time.perf_counter() - t0) * 1000
        except NotImplementedError:
            print("  [Qdrant] Not implemented (TODO 5)")

    methods: list[tuple[str, list[tuple[int, float]], float]] = [
        ("Cosine numpy (pre-built)", cosine_results, t_cosine),
    ]
    if bm25_results is not None:
        methods.insert(0, ("BM25 keyword", bm25_results, t_bm25))
    if fusion_results is not None:
        methods.append(("Fusion RRF", fusion_results, t_fusion))
    if qdrant_results is not None:
        methods.append(("Qdrant :memory:", qdrant_results, t_qdrant))

    for name, results, elapsed in methods:
        print(f"\n  {name} ({elapsed:.2f} ms):")
        for rank, (idx, score) in enumerate(results, 1):
            cat  = tickets[idx]["category"]
            text = tickets[idx]["text"][:58]
            print(f"    {rank}. [{cat}] {text}... ({score:.4f})")

    if bm25_results and cosine_results:
        bm25_ids   = {idx for idx, _ in bm25_results}
        cosine_ids = {idx for idx, _ in cosine_results}
        print(f"\n  BM25 vs Cosine overlap: {len(bm25_ids & cosine_ids)}/{TOP_K}")
    if qdrant_results and cosine_results:
        q_ids = {idx for idx, _ in qdrant_results}
        c_ids = {idx for idx, _ in cosine_results}
        print(f"  Qdrant vs Cosine overlap: {len(q_ids & c_ids)}/{TOP_K}  (should be 5/5 at this size)")

    def _recall(results: list[tuple[int, float]] | None) -> int | None:
        if results is None or not expected_category:
            return None
        return sum(tickets[idx]["category"] == expected_category for idx, _ in results)

    metrics: dict = {
        "BM25":   {"recall": _recall(bm25_results),   "latency_ms": t_bm25},
        "Cosine": {"recall": _recall(cosine_results),  "latency_ms": t_cosine},
        "Fusion": {"recall": _recall(fusion_results),  "latency_ms": t_fusion},
        "Qdrant": {"recall": _recall(qdrant_results),  "latency_ms": t_qdrant},
    }

    if expected_category:
        parts = []
        for key in ("BM25", "Cosine", "Fusion", "Qdrant"):
            r = metrics[key]["recall"]
            if r is not None:
                parts.append(f"{key}={r}/{TOP_K}")
        print(f"\n  Recall@5 [{expected_category}]: {' | '.join(parts)}")
    print("=" * 72)
    return metrics


# ---------------------------------------------------------------------------
# PRE-BUILT: RERANKER COMPARISON TABLE (bonus)
# ---------------------------------------------------------------------------

def compare_rerankers(query: str, cosine_results: list[tuple[int, float]], tickets: list[dict]) -> None:
    """Run all three reranker models and print a comparison table."""
    candidate_texts  = [tickets[idx]["text"] for idx, _ in cosine_results]
    candidate_cats   = [tickets[idx]["category"] for idx, _ in cosine_results]

    print(f"\n  Reranker comparison — Query: \"{query}\"")
    print("=" * 72)
    for key, model_name in RERANKER_MODELS.items():
        print(f"\n  [{key}]  {model_name}")
        try:
            t0     = time.perf_counter()
            ranked = rerank(query, candidate_texts, model_key=key)
            ms     = (time.perf_counter() - t0) * 1000
            for i, (text, score) in enumerate(ranked, 1):
                cat = candidate_cats[candidate_texts.index(text)]
                print(f"    {i}. [{cat}] {text[:55]}... ({score:+.3f})")
            print(f"    ↳ latency: {ms:.0f} ms")
        except NotImplementedError as e:
            print(f"    {e}")
    print("=" * 72)


# ---------------------------------------------------------------------------
# PRE-BUILT: TICKET HELPER DEMO
# ---------------------------------------------------------------------------

def ticket_helper_demo(
    query:         str,
    query_emb:     np.ndarray,
    all_embs:      np.ndarray,
    tickets:       list[dict],
    labels:        np.ndarray,
    cluster_names: dict[int, str],
    top_similar:   int = 3,
) -> None:
    """Show similar past tickets + category hint (majority vote)."""
    print("\n" + "=" * 72)
    print("  Ticket Helper (similar tickets + category hint)")
    print("=" * 72)
    print(f'\n  New ticket: "{query}"')

    corpus = [t["text"] for t in tickets]
    try:
        bm25_r   = bm25_search(corpus, query, TOP_K)
        cosine_r = cosine_search(query_emb, all_embs, TOP_K)
        results  = fusion_search(bm25_r, cosine_r, TOP_K)
        method   = "Fusion RRF"
    except NotImplementedError:
        results = cosine_search(query_emb, all_embs, TOP_K)
        method  = "Cosine (BM25 not implemented)"

    print(f"\n  Retrieval: {method}")
    top        = results[:top_similar]
    categories = [tickets[idx]["category"] for idx, _ in top]
    suggested  = max(set(categories), key=categories.count)
    print(f"\n  Suggested category (majority of top-{top_similar}): {suggested}")

    cluster_votes: dict[int, int] = {}
    for idx, _ in top:
        cid = int(labels[idx])
        cluster_votes[cid] = cluster_votes.get(cid, 0) + 1
    best_cid = max(cluster_votes, key=cluster_votes.get)
    print(f'  Closest cluster label: "{cluster_names.get(best_cid, f"Cluster {best_cid}")}"')

    print("\n  Similar past tickets:")
    for rank, (idx, score) in enumerate(top, 1):
        cat  = tickets[idx]["category"]
        text = tickets[idx]["text"][:70]
        print(f"    {rank}. [{cat}] {text}...")
    print("=" * 72)


# ---------------------------------------------------------------------------
# PRE-BUILT: CLUSTER TABLE
# ---------------------------------------------------------------------------

def print_cluster_table(
    tickets:       list[dict],
    labels:        np.ndarray,
    cluster_names: dict[int, str],
) -> None:
    """Print cluster name, size, and example tickets."""
    print("\n" + "=" * 72)
    print("  Cluster Summary")
    print("=" * 72)
    for cluster_id in sorted(cluster_names):
        name    = cluster_names[cluster_id]
        mask    = labels == cluster_id
        ctexts  = [tickets[i]["text"] for i in range(len(tickets)) if mask[i]]
        print(f"\n  [{cluster_id}] {name} ({len(ctexts)} tickets)")
        for t in ctexts[:3]:
            print(f"      - {t[:70]}")
        if len(ctexts) > 3:
            print(f"      ... and {len(ctexts) - 3} more")
    print("=" * 72)


# ---------------------------------------------------------------------------
# VALIDATION — used by eval.py
# ---------------------------------------------------------------------------

def validate_homework() -> tuple[bool, list[str]]:
    """Check that TODOs are filled. Returns (ok, list_of_error_messages)."""
    errors: list[str] = []

    # TODO 1
    try:
        embs = get_embeddings(["hello world", "test sentence"])
        if not isinstance(embs, np.ndarray):
            errors.append("get_embeddings must return a numpy array")
        elif embs.ndim != 2 or embs.shape[0] != 2:
            errors.append(f"get_embeddings shape should be (2, dim), got {embs.shape}")
    except NotImplementedError:
        errors.append("TODO 1: get_embeddings not implemented")
    except Exception as e:
        errors.append(f"get_embeddings raised: {e}")

    # TODO 2
    try:
        dummy  = np.random.randn(10, 8)
        labels = cluster_tickets(dummy, 3)
        if not isinstance(labels, np.ndarray):
            errors.append("cluster_tickets must return a numpy array")
        elif labels.shape != (10,):
            errors.append(f"cluster_tickets shape should be (10,), got {labels.shape}")
    except NotImplementedError:
        errors.append("TODO 2: cluster_tickets not implemented")
    except Exception as e:
        errors.append(f"cluster_tickets raised: {e}")

    # TODO 3 — check prompt is written (don't require API key)
    try:
        result = name_cluster(["test ticket 1", "test ticket 2"])
        if not isinstance(result, str) or not result.strip():
            errors.append("name_cluster must return a non-empty string")
    except NotImplementedError:
        errors.append("TODO 3: name_cluster not implemented — write a prompt")
    except Exception:
        pass  # prompt is written but OPENROUTER_API_KEY not set — that's ok

    # TODO 4
    try:
        docs    = [f"word{i} token" for i in range(10)]
        results = bm25_search(docs, "word3 token", 3)
        if not isinstance(results, list) or len(results) != 3:
            errors.append("bm25_search must return a list of length top_k")
        elif not all(isinstance(r, tuple) and len(r) == 2 for r in results):
            errors.append("bm25_search must return list of (index, score) tuples")
    except NotImplementedError:
        errors.append("TODO 4: bm25_search not implemented")
    except Exception as e:
        errors.append(f"bm25_search raised: {e}")

    # TODO 5
    try:
        dummy_tickets = [{"text": f"ticket {i}", "category": "test"} for i in range(5)]
        dummy_embs    = np.random.randn(5, 384).astype(np.float32)
        client        = upload_to_qdrant(dummy_tickets, dummy_embs)
        if client is None:
            errors.append("upload_to_qdrant must return a QdrantClient instance")
        else:
            q_emb    = np.random.randn(384).astype(np.float32)
            results  = qdrant_search(client, q_emb, 3)
            if not isinstance(results, list) or len(results) != 3:
                errors.append("qdrant_search must return a list of length top_k")
            elif not all(isinstance(r, tuple) and len(r) == 2 for r in results):
                errors.append("qdrant_search must return list of (index, score) tuples")
    except NotImplementedError:
        errors.append("TODO 5: upload_to_qdrant / qdrant_search not implemented")
    except Exception as e:
        errors.append(f"TODO 5 raised: {e}")

    return (len(errors) == 0, errors)


# ---------------------------------------------------------------------------
# MAIN
# ---------------------------------------------------------------------------

def main() -> None:
    parser = argparse.ArgumentParser(description="Ticket Auto-Categorization — HW v2")
    parser.add_argument("--quick",    action="store_true", help="Skip LLM cluster naming")
    parser.add_argument("--query",    type=str,  default=None, help="Single query instead of DEMO_QUERIES")
    parser.add_argument("--clusters", type=int,  default=DEFAULT_N_CLUSTERS, help="Number of clusters")
    parser.add_argument("--rerank",   action="store_true", help="Bonus: run reranker comparison on --query")
    args = parser.parse_args()

    print("=" * 65)
    print("  Ticket Auto-Categorization with Embeddings (300 tickets)")
    print("=" * 65)

    # Step 1: Embeddings
    print(f"\n[1/5] Generating embeddings for {len(TICKETS)} tickets...")
    texts      = [t["text"] for t in TICKETS]
    embeddings = get_embeddings(texts)
    print(f"  Shape: {embeddings.shape}")

    # Step 2: Clustering
    print(f"\n[2/5] Clustering into {args.clusters} groups...")
    labels = cluster_tickets(embeddings, args.clusters)
    for cid in sorted(set(labels)):
        count = (labels == cid).sum()
        print(f"  Cluster {cid}: {count} tickets")

    ari = compute_ari(TICKETS, labels)
    print(f"\n  ARI vs ground-truth categories: {ari:.3f}  (0=random, 1=perfect)")

    # Step 3: LLM cluster naming
    cluster_names: dict[int, str] = {}
    if not args.quick:
        print("\n[3/5] Naming clusters via LLM...")
        if not os.environ.get("OPENROUTER_API_KEY"):
            print("  OPENROUTER_API_KEY not set — skipping LLM naming")
            args.quick = True

    if not args.quick:
        for cid in sorted(set(labels)):
            ctexts = [texts[i] for i in range(len(texts)) if labels[i] == cid]
            try:
                name = name_cluster(ctexts[:10])
                cluster_names[cid] = name
                print(f"  Cluster {cid} → \"{name}\"")
            except NotImplementedError:
                print("  TODO 3 not implemented — skipping LLM naming")
                args.quick = True
                break
    else:
        print("\n[3/5] Skipping LLM naming (--quick mode)")

    if args.quick:
        for cid in sorted(set(labels)):
            cluster_names[cid] = f"Cluster {cid}"

    print("\n  Visualizing clusters (t-SNE)...")
    visualize_clusters(embeddings, labels, cluster_names)
    print_cluster_table(TICKETS, labels, cluster_names)

    # Step 4: Qdrant setup (optional)
    qdrant_client = None
    print("\n[4a] Setting up Qdrant :memory: (TODO 5)...")
    try:
        qdrant_client = upload_to_qdrant(TICKETS, embeddings)
        print(f"  Qdrant :memory: ready — {len(TICKETS)} tickets indexed")
    except NotImplementedError:
        print("  TODO 5 not implemented — Qdrant column will be skipped")

    # Step 4: Search comparison
    if args.query is not None:
        query_pairs = [(args.query, None)]
    else:
        query_pairs = list(DEMO_QUERIES.items())
    print(f"\n[4/5] Search comparison ({len(query_pairs)} queries)...")

    last_q:   str | None       = None
    last_emb: np.ndarray | None = None
    last_cos: list | None       = None
    all_metrics: list[dict]     = []

    for i, (query, expected_cat) in enumerate(query_pairs, 1):
        print(f"\n{'=' * 65}")
        print(f"  Query {i}/{len(query_pairs)}: \"{query}\"")
        q_emb   = get_embeddings([query])[0]
        metrics = compare_and_print(query, q_emb, embeddings, TICKETS, qdrant_client, expected_cat)
        all_metrics.append(metrics)
        last_q   = query
        last_emb = q_emb
        last_cos = cosine_search(q_emb, embeddings, TOP_K)

    # Summary table (only for DEMO_QUERIES with known expected categories)
    if len(all_metrics) > 1 and all(
        any(v["recall"] is not None for v in m.values()) for m in all_metrics
    ):
        print(f"\n{'=' * 65}")
        print("  Summary — avg over all demo queries")
        print(f"  {'Method':<18} {'Avg Recall@5':>14} {'Avg Latency':>12}")
        print("  " + "─" * 46)
        for key in ("BM25", "Cosine", "Fusion", "Qdrant"):
            recalls   = [m[key]["recall"]     for m in all_metrics if m[key]["recall"] is not None]
            latencies = [m[key]["latency_ms"] for m in all_metrics if m[key]["latency_ms"] > 0]
            if not latencies:
                continue
            avg_r = sum(recalls) / len(recalls) if recalls else 0
            avg_l = sum(latencies) / len(latencies)
            label = {"BM25": "BM25 keyword", "Cosine": "Cosine numpy", "Fusion": "Fusion RRF", "Qdrant": "Qdrant :memory:"}[key]
            print(f"  {label:<18} {avg_r:>8.1f} / 5   {avg_l:>8.2f} ms")
        print(f"  {'=' * 46}")
        print("  ↑ Copy these numbers into results.md Section 3")

    # Bonus: reranker comparison
    if args.rerank and last_q is not None and last_cos is not None:
        print(f"\n[BONUS] Reranker comparison on last query...")
        compare_rerankers(last_q, last_cos, TICKETS)

    # Step 5: Ticket Helper
    print("\n[5/5] Ticket Helper demo...")
    if last_q is not None and last_emb is not None:
        ticket_helper_demo(last_q, last_emb, embeddings, TICKETS, labels, cluster_names)

    print("\nDone! Check clusters.png for the t-SNE visualization.")


if __name__ == "__main__":
    main()

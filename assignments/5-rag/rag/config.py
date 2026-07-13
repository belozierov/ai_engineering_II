"""Shared configuration and constants (pre-built — read, don't edit).

Importing this module has no side effects beyond setting a few environment
flags that quiet the embedding libraries. It never loads data or the model.
"""

from __future__ import annotations

import logging
import os
import warnings
from pathlib import Path

# Quiet the ML libraries so the chat/eval output stays readable.
os.environ.setdefault("TOKENIZERS_PARALLELISM", "false")
os.environ.setdefault("HF_HUB_DISABLE_PROGRESS_BARS", "1")
os.environ.setdefault("HF_HUB_DISABLE_IMPLICIT_TOKEN", "1")
warnings.filterwarnings("ignore", message=".*unauthenticated.*")
warnings.filterwarnings("ignore", category=FutureWarning)
for _name in ("sentence_transformers", "transformers", "huggingface_hub"):
    logging.getLogger(_name).setLevel(logging.ERROR)

# --- Models ---------------------------------------------------------------
MODEL = "openrouter:google/gemini-2.5-flash-lite"
OPENROUTER_MODEL = "google/gemini-2.5-flash-lite"
OPENROUTER_API_URL = "https://openrouter.ai/api/v1/chat/completions"
ENCODER_NAME = "all-MiniLM-L6-v2"
EMBED_DIM = 384

# --- Retrieval / indexing -------------------------------------------------
TOP_K = 8  # top chunks per search; higher helps multi-source answers (fan-out gives ~TOP_K//n per sub-query)
# Students change CHUNK_SIZE / CHUNK_OVERLAP in TODO 1 and compare in results.md.
CHUNK_SIZE = 400          # characters per chunk (a simple, char-based default)
CHUNK_OVERLAP = 60        # characters of overlap between neighbouring chunks

# --- Context packing (TODO 3) --------------------------------------------
TOKEN_BUDGET = 1200       # approx token budget for the assembled context

# --- CRAG gate (TODO 2b) --------------------------------------------------
# Cosine score thresholds on the top retrieved chunk. These are STARTING values —
# calibrate them yourself (TODO 2): compare the top-score of a real query vs a
# no-evidence query (see the [debug] line / trace) and set GOOD/WEAK on the boundary.
# Re-tune if you change the chunk size or corpus.
CRAG_GOOD_THRESHOLD = 0.5
CRAG_WEAK_THRESHOLD = 0.35

# --- Cost model (eval harness) -------------------------------------------
# Approximate. Model prices change; we track tokens and multiply by a constant
# so students reason about order-of-magnitude cost, not exact billing.
USD_PER_1K_TOKENS = 0.0003

# --- Paths ----------------------------------------------------------------
PKG_DIR = Path(__file__).resolve().parent
HW_DIR = PKG_DIR.parent
DATA_DIR = HW_DIR / "data"
CORPUS_FILE = DATA_DIR / "corpus.jsonl"
ADVERSARIAL_FILE = DATA_DIR / "adversarial.jsonl"
GOLDEN_FILE = DATA_DIR / "golden.json"


def build_chat_model():
    """Model for the main agent generation, with automatic 429/5xx retry+backoff.

    Wraps an OpenAI-compatible client (max_retries) so a brief rate-limit burst on
    the free tier retries instead of dropping the answer mid-stream. Falls back to
    the plain `MODEL` string if the optional wiring is unavailable.
    """
    try:
        from openai import AsyncOpenAI
        from pydantic_ai.models.openrouter import OpenRouterModel
        from pydantic_ai.providers.openrouter import OpenRouterProvider

        client = AsyncOpenAI(
            base_url="https://openrouter.ai/api/v1",
            api_key=os.environ.get("OPENROUTER_API_KEY", ""),
            max_retries=4,
        )
        return OpenRouterModel(OPENROUTER_MODEL, provider=OpenRouterProvider(openai_client=client))
    except Exception:
        return MODEL

"""TODO 1 — Indexing: chunking + your own embeddings (lecture 6.1).

This homework gives you RAW text and asks YOU to build the index. This is the
biggest change from v2, where the whole article was pre-embedded as one vector
(so the tail of long articles was invisible to search — MiniLM only reads ~256
tokens). You will chunk the text, embed each chunk, and measure whether smaller
chunks improve recall (results.md).
"""

from __future__ import annotations

import numpy as np

from . import config
from .data import WikiDeps


def chunk_text(text: str, chunk_size: int = config.CHUNK_SIZE, overlap: int = config.CHUNK_OVERLAP) -> list[str]:
    """Split one article into overlapping chunks.

    Args:
        text: full article text.
        chunk_size: target chunk length (characters — a simple starting point).
        overlap: characters shared between neighbouring chunks (keeps facts that
            straddle a boundary retrievable).

    Returns:
        A list of chunk strings. Short text returns a single chunk; empty text
        returns an empty list.
    """
    # TODO 1a: implement chunking.
    #   - Walk the text in windows of `chunk_size`, stepping by (chunk_size - overlap).
    #   - Skip empty/whitespace-only chunks.
    #   - Bonus: split on sentence/paragraph boundaries instead of raw characters.
    raise NotImplementedError("TODO 1a: implement chunk_text")


def build_index(deps: WikiDeps, chunk_size: int = config.CHUNK_SIZE, overlap: int = config.CHUNK_OVERLAP) -> None:
    """Chunk every article, embed all chunks, and store the index on `deps`.

    Fills in-place:
        deps.chunks           = [{"chunk_id": int, "article_title": str, "text": str}, ...]
        deps.chunk_embeddings = np.ndarray of shape (n_chunks, EMBED_DIM)

    Hints:
        - Encode with deps.encoder.encode(list_of_texts, convert_to_numpy=True).
        - Give every chunk a unique chunk_id (0..n-1) and remember its source title.
        - Bonus (Contextual Retrieval, slides 6.1/21-22): prepend an LLM-written
          1-3 sentence context to each chunk before embedding.
    """
    # TODO 1b: build the chunk index.
    raise NotImplementedError("TODO 1b: implement build_index")

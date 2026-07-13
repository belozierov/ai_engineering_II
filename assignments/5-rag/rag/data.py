"""Corpus loading and the dependency container (pre-built — read, don't edit).

This homework ships RAW text (data/corpus.jsonl) with NO embeddings. You build
the index yourself in TODO 1 (rag/indexing.py): chunk the text and embed it.
"""

from __future__ import annotations

import json
from dataclasses import dataclass, field

import numpy as np
from sentence_transformers import SentenceTransformer

from . import config


@dataclass
class WikiDeps:
    """Dependencies injected into every tool call via RunContext.

    `titles`/`texts`/`urls` are the raw articles. `chunks` and `chunk_embeddings`
    start empty and are filled by rag.indexing.build_index() at startup.
    `last_context_titles` records what the most recent search actually retrieved,
    so the faithfulness validator can check citations against real sources.
    """

    titles: list[str]
    texts: list[str]
    urls: list[str]
    encoder: SentenceTransformer

    chunks: list[dict] = field(default_factory=list)      # {"chunk_id", "article_title", "text"}
    chunk_embeddings: np.ndarray | None = None
    last_context_titles: list[str] = field(default_factory=list)


def load_corpus(path=None) -> list[dict]:
    """Load raw articles from a JSONL file. Each line: {"title","text","url"}."""
    path = path or config.CORPUS_FILE
    articles: list[dict] = []
    with open(path, encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if line:
                articles.append(json.loads(line))
    return articles


def load_adversarial(path=None) -> list[dict]:
    """Load the poisoned documents used only by the injection-defense bonus."""
    path = path or config.ADVERSARIAL_FILE
    docs: list[dict] = []
    with open(path, encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if line:
                docs.append(json.loads(line))
    return docs


def build_deps(articles: list[dict], encoder: SentenceTransformer | None = None) -> WikiDeps:
    """Construct WikiDeps from raw articles. Index is built separately."""
    encoder = encoder or SentenceTransformer(config.ENCODER_NAME)
    return WikiDeps(
        titles=[a["title"] for a in articles],
        texts=[a["text"] for a in articles],
        urls=[a.get("url", "") for a in articles],
        encoder=encoder,
    )

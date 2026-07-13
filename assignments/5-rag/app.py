# /// script
# requires-python = ">=3.11"
# dependencies = [
#   "pydantic-ai-slim[openrouter,web]==2.6.*",
#   "sentence-transformers",
#   "numpy",
#   "uvicorn",
#   "httpx",
# ]
# ///
"""
Entrypoint for the Wikipedia RAG chatbot.

This is the ONLY place that loads data, builds the index, and starts the web UI.
The rag/ package stays import-side-effect free so eval/eval.py can import it cheaply.

Setup:
  export OPENROUTER_API_KEY="sk-or-..."

Run (needs the TODOs implemented — the index build is TODO 1):
  uv run app.py
  # open http://localhost:8000
"""

from __future__ import annotations

import importlib
import os

# Package to run (default "rag"). Overridable via the RAG_PKG env var.
PKG = os.environ.get("RAG_PKG", "rag")
config = importlib.import_module(f"{PKG}.config")
data = importlib.import_module(f"{PKG}.data")
indexing = importlib.import_module(f"{PKG}.indexing")
agent = importlib.import_module(f"{PKG}.agent").agent


def main() -> None:
    import uvicorn

    print(f"Package: {PKG}")
    print("Loading corpus...")
    articles = data.load_corpus()
    print(f"  {len(articles)} articles from {config.CORPUS_FILE.name}")

    print(f"Building index (chunk_size={config.CHUNK_SIZE}, overlap={config.CHUNK_OVERLAP})...")
    deps = data.build_deps(articles)
    indexing.build_index(deps, config.CHUNK_SIZE, config.CHUNK_OVERLAP)
    n_chunks = len(deps.chunks)
    print(f"  {n_chunks} chunks indexed  ·  model: {config.MODEL}")

    app = agent.to_web(deps=deps)
    port = int(os.environ.get("PORT", 8000))
    print(f"\nStarting Wikipedia RAG Chatbot — open http://localhost:{port}  (Ctrl+C to stop)\n")
    uvicorn.run(app, host="127.0.0.1", port=port)


if __name__ == "__main__":
    main()

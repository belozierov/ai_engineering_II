# /// script
# requires-python = ">=3.11"
# dependencies = ["sentence-transformers"]
# ///
"""Reference cross-encoder scores for validating the Swift CoreML rerankers.

Scores (query, ticket) pairs with the three homework rerankers through
sentence-transformers CrossEncoder and prints raw logits — the numbers the Swift
`CoreMLReranker.score` must reproduce. Also prints what `predict()` returns with
its default activation, to document what the Python homework table would show.

Run from the package root:
  uv run scripts/crossencoder_reference_scores.py --query "..." --indices 150,5,130,207,242
"""
import argparse
import json
from pathlib import Path

import torch
from sentence_transformers import CrossEncoder

MODELS = {
    "ms-marco":  "cross-encoder/ms-marco-MiniLM-L-6-v2",
    "bge-base":  "BAAI/bge-reranker-base",
    "bge-v2-m3": "BAAI/bge-reranker-v2-m3",
}

parser = argparse.ArgumentParser()
parser.add_argument("--query", required=True)
parser.add_argument("--indices", required=True, help="comma-separated ticket indices (cosine top-5 order)")
parser.add_argument("--data", default=str(Path(__file__).parent.parent / "data" / "tickets.json"))
args = parser.parse_args()

tickets = json.loads(Path(args.data).read_text())
indices = [int(i) for i in args.indices.split(",")]
pairs = [(args.query, tickets[i]["text"]) for i in indices]

print(f'query: "{args.query}"')
for key, name in MODELS.items():
    model = CrossEncoder(name)
    logits = model.predict(pairs, activation_fn=torch.nn.Identity())
    defaults = model.predict(pairs)
    print(f"\n[{key}] {name} (default activation: {type(model.default_activation_function).__name__})")
    for index, logit, default in zip(indices, logits, defaults):
        print(f"  [{index:3d}] logit {logit:+9.4f}   default {default:+9.4f}   {tickets[index]['text'][:60]}")

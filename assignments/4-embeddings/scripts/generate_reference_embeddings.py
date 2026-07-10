# /// script
# requires-python = ">=3.11"
# dependencies = ["sentence-transformers"]
# ///
"""Regenerate the MiniLM reference fixture used by TextEmbeddingTests.

The texts vary in length on purpose so that a batched Swift run pads most of them —
the fixture then guards both the model output and the attention-mask/padding path.

Run from the package root:  uv run scripts/generate_reference_embeddings.py
"""
import json
from pathlib import Path
from sentence_transformers import SentenceTransformer

TEXTS = [
    "My package never arrived",
    "I forgot my password and can't log in to my account",
    "The café's Wi-Fi wasn't working — I couldn't pay!",
    "I ordered a wireless keyboard three weeks ago and the tracking page still says the parcel "
    "is waiting at the sorting facility. Support promised an update twice, but nobody ever "
    "wrote back, and now the order page shows a completely different delivery date.",
]
OUT = Path(__file__).parent.parent / "Tests" / "TextEmbeddingTests" / "Resources" / "minilm_reference.json"

model = SentenceTransformer("sentence-transformers/all-MiniLM-L6-v2")
vectors = model.encode(TEXTS, normalize_embeddings=True)

OUT.parent.mkdir(parents=True, exist_ok=True)
OUT.write_text(json.dumps(
    [{"text": text, "vector": [float(x) for x in vector]} for text, vector in zip(TEXTS, vectors)]
))
print(f"Wrote {len(TEXTS)} reference embeddings to {OUT}")

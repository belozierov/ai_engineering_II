# /// script
# requires-python = ">=3.11"
# dependencies = ["scikit-learn", "matplotlib", "numpy"]
# ///
"""Render a t-SNE scatter of ticket embeddings colored by cluster.

Called by the Swift Visualization module (TSNEPlotter):
    uv run scripts/tsne_plot.py <input.json> <output.png>

Input JSON: {"values": [...], "count": n, "dim": d, "labels": [...], "names": [...]}
Mirrors the reference starter.py visualization (random_state=42, tab10, dpi=150).
"""
import json
import sys

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import numpy as np
from sklearn.manifold import TSNE

input_path, output_path = sys.argv[1], sys.argv[2]
with open(input_path) as f:
    data = json.load(f)

embeddings = np.array(data["values"], dtype=np.float32).reshape(data["count"], data["dim"])
labels = np.array(data["labels"])
names = data["names"]

tsne = TSNE(n_components=2, random_state=42, perplexity=min(30, len(embeddings) - 1))
coords = tsne.fit_transform(embeddings)

plt.figure(figsize=(11, 7))
cmap = plt.colormaps.get_cmap("tab10").resampled(len(names))
for label, name in enumerate(names):
    mask = labels == label
    plt.scatter(coords[mask, 0], coords[mask, 1], c=[cmap(label)], label=name, s=45, alpha=0.75)

plt.legend(fontsize=8, loc="best")
plt.title(f"Ticket Clusters — t-SNE ({len(embeddings)} tickets)", fontsize=13)
plt.tight_layout()
plt.savefig(output_path, dpi=150)
print(f"  Saved: {output_path}")

# /// script
# requires-python = ">=3.11"
# dependencies = ["coremltools>=8.0", "transformers", "torch", "numpy"]
# ///
"""Isolate whether the JGKarlin bge-v2-m3 CoreML conversion reproduces FP32 logits.

Feeds the .mlpackage the exact HF-tokenizer pair encoding (padded to the fixed 512)
and compares against torch FP32 — both padded-to-512 and padded-to-longest, to tell
a mask/padding bug apart from a conversion bug.
"""
import json
from pathlib import Path

import coremltools as ct
import numpy as np
import torch
from transformers import AutoModelForSequenceClassification, AutoTokenizer

QUERY = "package not delivered to my address"
INDICES = [130, 150, 132, 142, 129]
PACKAGE = Path.home() / "Documents/huggingface/models/JGKarlin/ohia-bge-reranker-v2-m3-coreml/bge-reranker-v2-m3.mlpackage"

tickets = json.loads((Path(__file__).parent.parent / "data" / "tickets.json").read_text())
pairs = [(QUERY, tickets[i]["text"]) for i in INDICES]

tokenizer = AutoTokenizer.from_pretrained("BAAI/bge-reranker-v2-m3")
padded = tokenizer(pairs, padding="max_length", truncation=True, max_length=512, return_tensors="np")
print("first pair ids [:24]:", padded["input_ids"][0][:24].tolist())
print("real lengths:", padded["attention_mask"].sum(axis=1).tolist())

model = AutoModelForSequenceClassification.from_pretrained(
    "BAAI/bge-reranker-v2-m3", dtype=torch.float32
)
model.eval()
with torch.no_grad():
    longest = tokenizer(pairs, padding=True, truncation=True, max_length=512, return_tensors="pt")
    fp32_longest = model(**longest).logits.squeeze(-1).numpy()
    fp32_padded = model(
        input_ids=torch.tensor(padded["input_ids"]), attention_mask=torch.tensor(padded["attention_mask"])
    ).logits.squeeze(-1).numpy()

for units in [ct.ComputeUnit.CPU_ONLY, ct.ComputeUnit.ALL]:
    ml = ct.models.MLModel(str(PACKAGE), compute_units=units)
    logits = [
        float(ml.predict({
            "input_ids": padded["input_ids"][i:i + 1].astype(np.int32),
            "attention_mask": padded["attention_mask"][i:i + 1].astype(np.int32),
        })["logit"][0])
        for i in range(len(pairs))
    ]
    print(f"\ncompute_units={units.name}")
    for index, coreml, longest_ref, padded_ref in zip(INDICES, logits, fp32_longest, fp32_padded):
        print(f"  [{index:3d}] coreml {coreml:+9.4f}   fp32@longest {longest_ref:+9.4f}   fp32@512 {padded_ref:+9.4f}")

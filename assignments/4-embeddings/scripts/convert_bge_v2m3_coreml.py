# /// script
# requires-python = ">=3.11"
# # transformers pinned pre-4.50: the masking refactor introduced `new_ones` calls the
# # coremltools TorchScript frontend cannot convert; eager attention avoids sdpa mask prep.
# dependencies = ["coremltools>=8.3", "transformers==4.49.*", "torch==2.7.*", "numpy", "sentencepiece"]
# ///
"""Convert BAAI/bge-reranker-v2-m3 to a CoreML .mlpackage in FP32.

The community conversion (JGKarlin/ohia-bge-reranker-v2-m3-coreml) is numerically
broken: FP16 intermediate tensors overflow (NaN on CPU, garbage logits on GPU),
so this script produces our own FP32 package with the same input/output contract:
input_ids + attention_mask (1, 512) Int32 -> logit (1,) Float32.

Run from the package root:  uv run scripts/convert_bge_v2m3_coreml.py
Output: models/bge-reranker-v2-m3-fp32.mlpackage (~2.3 GB)
"""
from pathlib import Path

import coremltools as ct
import numpy as np
import torch
from transformers import AutoModelForSequenceClassification, AutoTokenizer

NAME = "BAAI/bge-reranker-v2-m3"
SEQUENCE = 512
OUT = Path(__file__).parent.parent / "models" / "bge-reranker-v2-m3-fp32.mlpackage"


class LogitHead(torch.nn.Module):
    def __init__(self, model):
        super().__init__()
        self.model = model

    def forward(self, input_ids, attention_mask):
        return self.model(input_ids=input_ids, attention_mask=attention_mask).logits.squeeze(-1)


model = AutoModelForSequenceClassification.from_pretrained(
    NAME, torch_dtype=torch.float32, attn_implementation="eager"
)
model.eval()

example = (
    torch.ones((1, SEQUENCE), dtype=torch.int32),
    torch.ones((1, SEQUENCE), dtype=torch.int32),
)
traced = torch.jit.trace(LogitHead(model), example)

converted = ct.convert(
    traced,
    inputs=[
        ct.TensorType(name="input_ids", shape=(1, SEQUENCE), dtype=np.int32),
        ct.TensorType(name="attention_mask", shape=(1, SEQUENCE), dtype=np.int32),
    ],
    outputs=[ct.TensorType(name="logit")],
    compute_precision=ct.precision.FLOAT32,
    minimum_deployment_target=ct.target.macOS14,
    convert_to="mlprogram",
)
converted.short_description = "bge-reranker-v2-m3 cross-encoder, FP32 (own conversion)"
OUT.parent.mkdir(parents=True, exist_ok=True)
converted.save(str(OUT))
print(f"saved {OUT}")

# Verification: CoreML must reproduce torch FP32 logits on a real pair.
tokenizer = AutoTokenizer.from_pretrained(NAME)
pairs = [
    ("what is the capital of france?", "Paris is the capital of France."),
    ("package not delivered to my address", "The package was returned to sender without any delivery attempt"),
]
encoded = tokenizer(pairs, padding="max_length", truncation=True, max_length=SEQUENCE, return_tensors="np")
with torch.no_grad():
    reference = LogitHead(model)(
        torch.tensor(encoded["input_ids"], dtype=torch.int32),
        torch.tensor(encoded["attention_mask"], dtype=torch.int32),
    ).numpy()

loaded = ct.models.MLModel(str(OUT), compute_units=ct.ComputeUnit.CPU_ONLY)
for i, pair in enumerate(pairs):
    logit = float(loaded.predict({
        "input_ids": encoded["input_ids"][i:i + 1].astype(np.int32),
        "attention_mask": encoded["attention_mask"][i:i + 1].astype(np.int32),
    })["logit"][0])
    delta = abs(logit - float(reference[i]))
    print(f"coreml {logit:+9.4f}   torch {float(reference[i]):+9.4f}   delta {delta:.5f}   {pair[0][:40]}")
    assert delta < 1e-2, "CoreML output diverges from torch FP32"
print("verification passed")

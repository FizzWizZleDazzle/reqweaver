# /// script
# requires-python = ">=3.10"
# dependencies = ["sentence-transformers"]
# ///
"""Export all-MiniLM-L6-v2 for the LiveScript in-browser encoder.

Writes data/minilm/: model.bin (all tensors, float32 little-endian),
manifest.json (config + tensor offsets/shapes), vocab.json (WordPiece
vocabulary by id), and refs.json (reference sentence vectors the
LiveScript forward pass is parity-tested against).

Run: npm run export-model
"""
import json
import os

import numpy as np
import torch
from sentence_transformers import SentenceTransformer

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "data", "minilm")
os.makedirs(OUT, exist_ok=True)

st = SentenceTransformer("all-MiniLM-L6-v2")
bert = st[0].auto_model.eval()
tokenizer = st[0].tokenizer

manifest = {"config": {"hidden": 384, "layers": 6, "heads": 12,
                       "intermediate": 1536, "ln_eps": 1e-12,
                       "max_tokens": 128},
            "tensors": {}}
offset = 0
with open(os.path.join(OUT, "model.bin"), "wb") as f:
    for name, tensor in bert.state_dict().items():
        if name.startswith("pooler."):
            continue  # sentence embeddings mean-pool; the pooler is unused
        arr = tensor.detach().cpu().numpy().astype("<f4")
        manifest["tensors"][name] = {"offset": offset, "shape": list(arr.shape)}
        f.write(arr.tobytes())
        offset += arr.size * 4

vocab = tokenizer.get_vocab()
ordered = [None] * len(vocab)
for token, idx in vocab.items():
    ordered[idx] = token

refs = {}
sentences = [
    "quantum theory and theoretical physics research",
    "AP Physics C Mechanics. Students use calculus in problem solving.",
    "Introduction to ceramics and hand building techniques.",
]
with torch.no_grad():
    vecs = st.encode(sentences, normalize_embeddings=True)
for s, v in zip(sentences, vecs):
    refs[s] = [round(float(x), 6) for x in v]

json.dump(manifest, open(os.path.join(OUT, "manifest.json"), "w"))
json.dump(ordered, open(os.path.join(OUT, "vocab.json"), "w"))
json.dump(refs, open(os.path.join(OUT, "refs.json"), "w"))
size_mb = offset / 1024 / 1024
print(f"exported {len(manifest['tensors'])} tensors, {size_mb:.1f} MB, vocab {len(ordered)}")

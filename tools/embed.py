# /// script
# requires-python = ">=3.10"
# dependencies = ["sentence-transformers", "pyyaml"]
# ///
"""Precompute course-description embeddings and profile goal vectors.

Runs an open-source pretrained text-embedding model (all-MiniLM-L6-v2)
once per catalog at data-compile time; the planner only computes cosine
similarity at plan time and never runs a model. Output is compiled
build product, so it is JSON (source data stays YAML).

Run: npm run embed
"""
import glob
import hashlib
import json
import os

import yaml
from sentence_transformers import SentenceTransformer

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
# Must stay in the same vector space as runtime goal encoding, which the
# site does through Cloudflare Workers AI (@cf/baai/bge-small-en-v1.5).
MODEL_NAME = "BAAI/bge-small-en-v1.5"
model = SentenceTransformer(MODEL_NAME)


def embed(texts):
    vecs = model.encode(texts, normalize_embeddings=True)
    return [[round(float(x), 5) for x in v] for v in vecs]


def profile_goals():
    goals = {}
    for prof_path in glob.glob(os.path.join(ROOT, "examples", "*.yaml")):
        prof = yaml.safe_load(open(prof_path)) or {}
        goal = prof.get("goal")
        if goal and goal not in goals:
            goals[goal] = None
    texts = list(goals)
    for text, vec in zip(texts, embed(texts) if texts else []):
        goals[text] = vec
    return goals


def main():
    goals = profile_goals()
    goal_key = "\n".join(sorted(goals))
    pattern = os.path.join(ROOT, "specs", "**", "*.yaml")
    for sheet_path in glob.glob(pattern, recursive=True):
        name = os.path.basename(sheet_path)
        if name.startswith("embeddings."):
            continue
        # The encoder is not bit-deterministic across runs, so an
        # unchanged sheet must not be re-embedded or CI commits vector
        # churn: skip when the stored source hash still matches.
        sheet_bytes = open(sheet_path, "rb").read()
        source_hash = hashlib.sha256(
            sheet_bytes + b"\x00" + goal_key.encode() + b"\x00" + MODEL_NAME.encode()
        ).hexdigest()
        stem = os.path.splitext(name)[0]
        dest = os.path.join(os.path.dirname(sheet_path), f"embeddings.{stem}.json")
        if os.path.exists(dest):
            try:
                if json.load(open(dest)).get("source_hash") == source_hash:
                    print(f"{stem}: unchanged, skipped")
                    continue
            except Exception:
                pass
        school = yaml.safe_load(sheet_bytes)
        courses = school.get("courses") or []
        texts = [f"{c.get('name', '')}. {c.get('description', '')}" for c in courses]
        vecs = embed(texts) if texts else []
        out = {
            "model": MODEL_NAME,
            "source_hash": source_hash,
            "dim": len(vecs[0]) if vecs else 0,
            "courses": {c["id"]: v for c, v in zip(courses, vecs)},
            "goals": goals,
        }
        with open(dest, "w") as f:
            json.dump(out, f)
        print(f"{stem}: {len(vecs)} courses, {len(goals)} goals")


main()

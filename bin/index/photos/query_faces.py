#!/usr/bin/env python3
"""Find every photo containing a given person.

Embeds the reference photo(s) locally on CPU (host3), then ranks all indexed
face embeddings by cosine similarity and lists the photos above --threshold.
usage: query_faces.py --index faces.jsonl ref1.jpg [ref2.jpg ...] [--threshold 0.4] [--top 50]
"""
import argparse, json, sys
import numpy as np, cv2
from insightface.app import FaceAnalysis

def load_index(path):
    rows, embs = [], []
    for line in open(path, encoding="utf-8"):
        rec = json.loads(line)
        for f in rec.get("faces", []):
            rows.append((rec.get("remote", rec["name"]), f["score"], f["bbox"]))
            embs.append(f["emb"])
    return rows, np.asarray(embs, dtype=np.float32)

def embed_reference(app, path):
    img = cv2.imread(path)
    faces = app.get(img) if img is not None else []
    if not faces:
        sys.exit(f"no face found in reference {path}")
    best = max(faces, key=lambda f: (f.bbox[2] - f.bbox[0]) * (f.bbox[3] - f.bbox[1]))
    return best.normed_embedding.astype(np.float32)

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("refs", nargs="+")
    ap.add_argument("--index", required=True)
    ap.add_argument("--threshold", type=float, default=0.4)
    ap.add_argument("--top", type=int, default=50)
    a = ap.parse_args()
    app = FaceAnalysis(name="buffalo_l", providers=["CPUExecutionProvider"])
    app.prepare(ctx_id=-1, det_size=(640, 640))
    rows, E = load_index(a.index)
    q = np.mean([embed_reference(app, r) for r in a.refs], axis=0)
    q /= np.linalg.norm(q)
    sims = E @ q
    best = {}
    for (remote, score, bbox), s in zip(rows, sims):
        if s >= a.threshold and (remote not in best or s > best[remote]):
            best[remote] = float(s)
    for remote, s in sorted(best.items(), key=lambda kv: -kv[1])[: a.top]:
        print(f"{s:.3f}  {remote}")
    print(f"# {len(best)} photos above {a.threshold} (of {len(rows)} faces indexed)", file=sys.stderr)

if __name__ == "__main__":
    main()

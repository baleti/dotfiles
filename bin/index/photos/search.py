#!/usr/bin/env python3
"""Unified photo search over the CLIP and face indexes.

Query syntax (follows ~/.config/docs/query-dsl.md: `//path` = filter, AND across filters):
  //face <name>           photos containing a face matching a registered person
  //clip brick           photos whose CLIP embedding matches the text 'brick'
  //face <name> //clip <text>   both filters (intersection)
  brick building        bare words: CLIP text search, plus any registered person
                        whose name matches a bare word (default = both)
  "quoted phrase"       kept as one CLIP phrase

People:  search.py people add NAME ref1.jpg [ref2.jpg ...]   (embed refs locally)
         search.py people list
Search:  search.py [--json] [--top 60] [--face-thr 0.40] [--clip-min 0.20] QUERY...
"""
import argparse, glob, json, os, re, shlex, sys
import numpy as np

import config
HERE = os.path.dirname(os.path.abspath(__file__))
DATA = config.DATA_DIR
FACES = os.path.join(DATA, "faces", "faces.jsonl")
CLIP = os.path.join(DATA, "clip", "clip.jsonl")
PEOPLE = os.path.join(DATA, "people")
CACHE = os.path.join(DATA, "cache")
THUMBS = os.path.join(DATA, "thumbs")
LISTS = os.path.join(DATA, "lists")
sys.path.insert(0, HERE)            # clip_text.py lives next to this file

def _cached_load(jsonl, prefix, field_fn):
    """Parse a jsonl index once into numpy arrays, cached until the file changes."""
    os.makedirs(CACHE, exist_ok=True)
    emb_p, meta_p = os.path.join(CACHE, prefix + ".npy"), os.path.join(CACHE, prefix + ".json")
    src_mtime = os.path.getmtime(jsonl) if os.path.exists(jsonl) else 0
    if os.path.exists(emb_p) and os.path.exists(meta_p) and os.path.getmtime(emb_p) >= src_mtime:
        return np.load(emb_p), json.load(open(meta_p))
    embs, meta = [], []
    if os.path.exists(jsonl):
        for line in open(jsonl, encoding="utf-8"):
            rec = json.loads(line)
            for emb, m in field_fn(rec):
                embs.append(emb); meta.append(m)
    E = np.asarray(embs, np.float32) if embs else np.zeros((0, 512), np.float32)
    np.save(emb_p, E); json.dump(meta, open(meta_p, "w"))
    return E, meta

def load_clip():
    return _cached_load(CLIP, "clip", lambda r: [(r["emb"], {"remote": r["remote"]})] if "emb" in r else [])

def load_faces():
    def fn(r):
        return [(f["emb"], {"remote": r["remote"], "score": f["score"], "bbox": f["bbox"]})
                for f in r.get("faces", [])]
    return _cached_load(FACES, "faces", fn)

def load_people():
    out = {}
    for p in glob.glob(os.path.join(PEOPLE, "*.json")):
        d = json.load(open(p))
        out[d["name"]] = np.asarray(d["emb"], np.float32)
    return out

def unit(v): return v / np.linalg.norm(v)

# ---------- people management (CPU, host3) ----------
def people_cmd(args):
    if args[0] == "list":
        for n in sorted(load_people()): print(n)
        return
    if args[0] == "add":
        from insightface.app import FaceAnalysis
        import cv2
        name, refs = args[1], args[2:]
        app = FaceAnalysis(name="buffalo_l", providers=["CPUExecutionProvider"])
        app.prepare(ctx_id=-1, det_size=(640, 640))
        embs = []
        for r in refs:
            img = cv2.imread(r)
            faces = app.get(img) if img is not None else []
            if not faces:
                print(f"no face in {r}, skipped", file=sys.stderr); continue
            best = max(faces, key=lambda f: (f.bbox[2]-f.bbox[0])*(f.bbox[3]-f.bbox[1]))
            embs.append(best.normed_embedding)
        if not embs: sys.exit("no usable reference faces")
        os.makedirs(PEOPLE, exist_ok=True)
        json.dump({"name": name, "refs": refs, "emb": unit(np.mean(embs, 0)).tolist()},
                  open(os.path.join(PEOPLE, f"{name}.json"), "w"))
        print(f"added {name} from {len(embs)} reference face(s)")
        return
    sys.exit("usage: people add NAME REF... | people list")

# ---------- query parsing ----------
def tokenize(q):
    try: return shlex.split(q)
    except ValueError: return q.split()

def parse(q):
    """Return a list of filters: ('face', [names]) | ('clip', text) and bare words."""
    toks = tokenize(q)
    filters, bare, cur = [], [], None
    for t in toks:
        m = re.match(r"^//(face|clip|name|path|size|dm|date)$", t)
        if m:
            cur = m.group(1); filters.append([cur, []]); continue
        if cur is not None:
            filters[-1][1].append(t)
        else:
            bare.append(t)
    return [(k, " ".join(v)) for k, v in filters], bare

# ---------- field tags: //name //path //size //dm ----------
_META = None
def meta():
    """remote -> (size_bytes, modtime_iso), from the gdrive listings (lists/*.json)."""
    global _META
    if _META is None:
        _META = {}
        for stem, folder in config.SOURCES.items():
            p = os.path.join(LISTS, stem + ".json")
            if not os.path.exists(p): continue
            for e in json.load(open(p, encoding="utf-8")):
                _META[f"{config.REMOTE}{folder}/{e['Path']}"] = (e.get("Size"), e.get("ModTime"))
    return _META

_UNITS = {"": 1, "K": 1024, "M": 1024**2, "G": 1024**3, "T": 1024**4}
def parse_size(text):
    """'>5M' -> (op, bytes). Only comparisons are meaningful for sizes."""
    m = re.match(r"^([<>]=?)\s*([0-9.]+)\s*([KMGT]?)B?$", text.strip(), re.I)
    if not m: return None
    return m.group(1), float(m.group(2)) * _UNITS[m.group(3).upper()]

def field_filter(kind, text, universe):
    """Row filter on one column. name/path/dm are case-insensitive substring matches
    (dm also accepts >/< on an ISO date prefix, e.g. '>2015-06'); size takes >/< with a unit."""
    M = meta()
    out = {}
    t = text.lower().strip()
    if kind == "size":
        op_v = parse_size(text)
        if op_v is None:
            return {}, "size needs a comparison, e.g. //size >5M or //size <200K"
        op, v = op_v
        for r in universe:
            sz = (M.get(r) or (None, None))[0]
            if sz is None: continue
            if (op[0] == ">" and sz > v) or (op[0] == "<" and sz < v) or (op == ">=" and sz >= v) or (op == "<=" and sz <= v):
                out[r] = 1.0
        return out, None
    if kind == "dm" and t[:1] in "<>":
        op = "<" if t[0] == "<" else ">"
        bound = t[1:].strip()
        for r in universe:
            mt = (M.get(r) or (None, None))[1] or ""
            if (op == ">" and mt[:len(bound)] > bound) or (op == "<" and mt[:len(bound)] < bound):
                out[r] = 1.0
        return out, None
    for r in universe:
        if kind == "name":
            hay = r.rsplit("/", 1)[-1].lower()
        elif kind == "path":
            hay = r.lower()
        else:  # dm / date: substring of the ISO modified time
            hay = ((M.get(r) or (None, None))[1] or "").lower()
        if t in hay: out[r] = 1.0
    return out, None

# ---------- query engine (shared by the CLI and search_server.py) ----------
_RELOAD_S = 60
_last_load = {"t": 0.0, "clip": None, "faces": None, "people": None}
_index = {}

def _refresh():
    """Reload indexes/people at most every _RELOAD_S seconds (the jsonl files grow
    while indexing, and re-parsing them on every keystroke would be too slow)."""
    import time
    now = time.time()
    if _index and now - _last_load["t"] < _RELOAD_S:
        return
    _index["clip"] = load_clip()
    _index["faces"] = load_faces()
    _index["people"] = load_people()
    _last_load["t"] = now

def browse(top=120):
    """Default list when the search box is empty: newest photos first (by filename,
    which is chronological for camera/phone names)."""
    _refresh()
    E, meta = _index["clip"]
    seen, out = set(), []
    for i in sorted(range(len(meta)), key=lambda i: meta[i]["remote"], reverse=True):
        r = meta[i]["remote"]
        if r in seen: continue
        seen.add(r); out.append({"remote": r, "score": None})
        if len(out) >= top: break
    return out

def run_query(q, top=60, face_thr=0.60, clip_min=0.20, clip_n=400):
    """Returns (results, count, errors). Raises ValueError when nothing can be searched."""
    _refresh()
    filters, bare = parse(q)
    people = _index["people"]
    results, errors = [], []

    def face_filter(name_text):
        if name_text.startswith("@"):
            # "@<photo>": use the largest face already indexed in that photo as the reference
            ref = name_text[1:].strip()
            E, meta = _index["faces"]
            best = None
            for i, m in enumerate(meta):
                if m["remote"] == ref:
                    b = m["bbox"]
                    area = (b[2] - b[0]) * (b[3] - b[1])
                    if best is None or area > best[0]:
                        best = (area, i)
            if best is None:
                return None, f"no indexed face in {ref}"
            sims = E @ E[best[1]]
            hits = {}
            for sim, m in zip(sims, meta):
                if sim >= face_thr and sim > hits.get(m["remote"], 0):
                    hits[m["remote"]] = float(sim)
            return hits, None
        names = [n for n in people if name_text.lower() in n.lower()]
        if not names:
            return None, f"no person matches '{name_text}' (registered: {', '.join(sorted(people)) or 'none'})"
        E, meta = _index["faces"]
        hits = {}
        for n in names:
            sims = E @ people[n] if len(E) else np.zeros(0)
            for s, m in zip(sims, meta):
                if s >= face_thr and s > hits.get(m["remote"], (0, ""))[0]:
                    hits[m["remote"]] = (float(s), n)
        return {k: v[0] for k, v in hits.items()}, None

    def clip_filter(text):
        from clip_text import embed_texts
        E, meta = _index["clip"]
        if not len(E): return {}, "clip index is empty"
        t = embed_texts([text])[0]
        sims = E @ t
        order = np.argsort(-sims)[: clip_n]
        return {meta[i]["remote"]: float(sims[i]) for i in order if sims[i] >= clip_min}, None

    universe = _index["clip"][1] and [m["remote"] for m in _index["clip"][1]]
    universe = list(dict.fromkeys(universe or meta().keys()))
    for kind, text in filters:
        if kind == "face": res, err = face_filter(text)
        elif kind == "clip": res, err = clip_filter(text)
        else: res, err = field_filter(kind, text, universe)
        if err: errors.append(err)
        else: results.append(res)
    if bare:
        btext = " ".join(bare)
        matched_people = [w for w in bare if any(w.lower() in n.lower() for n in people)]
        if not filters:
            res, err = clip_filter(btext)
            if err: errors.append(err)
            else: results.append(res)
            for w in matched_people:
                res, err = face_filter(w)
                if not err: results.append(res)
    if not results:
        raise ValueError("; ".join(errors) or "empty query")

    # AND across filters: keep remotes present in every filter, sum scores
    keys = set(results[0])
    for r in results[1:]: keys &= set(r)
    ranked = sorted(keys, key=lambda k: -sum(r[k] for r in results))[:top]
    out = [{"remote": k, "score": round(sum(r[k] for r in results), 4)} for k in ranked]
    return out, len(keys), errors

def main():
    import hashlib
    ap = argparse.ArgumentParser()
    ap.add_argument("query", nargs="*")
    ap.add_argument("--json", action="store_true")
    ap.add_argument("--top", type=int, default=60)
    ap.add_argument("--face-thr", type=float, default=0.60)
    ap.add_argument("--clip-min", type=float, default=0.20)
    ap.add_argument("--clip-n", type=int, default=400)
    args = ap.parse_args()
    if args.query and args.query[0] == "people":
        return people_cmd(args.query[1:])
    q = " ".join(args.query)
    try:
        out, count, errors = run_query(q, args.top, args.face_thr, args.clip_min, args.clip_n)
    except ValueError as e:
        print(str(e), file=sys.stderr); sys.exit(1)
    for o in out:
        o["thumb"] = os.path.join(THUMBS, hashlib.sha1(o["remote"].encode()).hexdigest()[:16] + ".jpg")
    if args.json:
        print(json.dumps({"query": q, "count": count, "results": out}))
    else:
        for o in out: print(f"{o['score']:.3f}  {o['remote']}")
        print(f"# {count} matches", file=sys.stderr)
        for e in errors: print("# note:", e, file=sys.stderr)

if __name__ == "__main__":
    main()

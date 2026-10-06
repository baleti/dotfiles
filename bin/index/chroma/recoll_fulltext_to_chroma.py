#!/usr/bin/env python3
"""
Embed the full text of every document in a Recoll (Xapian) index into ChromaDB.

Each document is re-extracted with Recoll's own extractors, split into overlapping
word chunks that fit the sentence model's window, and each chunk is embedded.
Resumable: documents whose chunks are already in the collection are skipped.

    python3 recoll_fulltext_to_chroma.py --recoll-conf <dir with recoll.conf> --db <chroma dir>
"""

import argparse
import hashlib
import html
import re
import sys
import time
from pathlib import Path

import json
import subprocess

import chromadb
from recoll import recoll

AI1_EMBED = (
    "SP=$HOME/indexer/venv/lib/python3.13/site-packages/nvidia; "
    "LD_LIBRARY_PATH=$(ls -d $SP/*/lib | paste -sd:) $HOME/indexer/venv/bin/python $HOME/indexer/minilm/embed.py"
)
AI1_SSH = json.load(open(os.path.expanduser("~/.config/indexes/collections.json")))["ai1"]["ssh_to_ai1"]


def embed(texts):
    """MiniLM embeddings computed on the ai1 GPU (ONNX Runtime, CUDA) via host1."""
    cmd = f"{AI1_SSH} '{AI1_EMBED}'"
    r = subprocess.run(["ssh", "-o", "BatchMode=yes", "host1", cmd],
                       input=json.dumps(texts), capture_output=True, text=True, timeout=1800)
    if r.returncode != 0:
        raise RuntimeError(f"ai1 embed failed: {r.stderr[-300:]}")
    return json.loads(r.stdout)["vectors"]
COLLECTION = "fulltext"
CHUNK_WORDS = 150
OVERLAP_WORDS = 30
EMBED_BATCH = 128
TAG_RE = re.compile(r"<[^>]+>")


def chunks(text):
    words = text.split()
    step = CHUNK_WORDS - OVERLAP_WORDS
    for start in range(0, max(len(words), 1), step):
        piece = " ".join(words[start:start + CHUNK_WORDS])
        if piece:
            yield piece
        if start + CHUNK_WORDS >= len(words):
            break


def clean(text, mimetype):
    if mimetype and "html" in mimetype:
        text = html.unescape(TAG_RE.sub(" ", text))
    return re.sub(r"\s+", " ", text).strip()


def doc_id(url, ipath):
    return hashlib.sha1(f"{url}\x00{ipath}".encode("utf-8", "surrogatepass")).hexdigest()[:20]


def existing_docs(col):
    done, offset = set(), 0
    while True:
        batch = col.get(include=[], limit=10000, offset=offset)
        ids = batch["ids"]
        if not ids:
            break
        done.update(i.rsplit("-", 1)[0] for i in ids)
        offset += len(ids)
    return done


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--recoll-conf", required=True)
    ap.add_argument("--db", required=True)
    args = ap.parse_args()

    client = chromadb.PersistentClient(path=args.db)
    col = client.get_or_create_collection(name=COLLECTION, metadata={"hnsw:space": "cosine"})
    done = existing_docs(col)
    print(f"already embedded: {len(done)} documents", flush=True)

    db = recoll.connect(confdir=args.recoll_conf, writable=False)
    q = db.query()
    q.execute("date:1970-01-01/2099-12-31", stemming=0)
    seen = skipped = embedded = failed = 0
    pend_ids, pend_docs, pend_meta = [], [], []
    t0 = time.time()

    def flush():
        nonlocal pend_ids, pend_docs, pend_meta
        for s in range(0, len(pend_ids), EMBED_BATCH):
            vecs = embed(pend_docs[s:s + EMBED_BATCH])
            col.upsert(ids=pend_ids[s:s + EMBED_BATCH], embeddings=vecs,
                       documents=pend_docs[s:s + EMBED_BATCH], metadatas=pend_meta[s:s + EMBED_BATCH])
        pend_ids, pend_docs, pend_meta = [], [], []

    while True:
        d = q.fetchone()
        if d is None:
            break
        seen += 1
        did = doc_id(d.url, d.ipath)
        if did in done:
            skipped += 1
            continue
        try:
            text = recoll.Extractor(d).textextract(d.ipath).text
        except Exception as e:
            failed += 1
            print(f"  extract failed: {d.url[-80:]}: {e}", file=sys.stderr, flush=True)
            continue
        text = clean(text or "", getattr(d, "mtype", ""))
        if not text:
            text = clean(d.title or d.abstract or d.url, "")
        for k, piece in enumerate(chunks(text)):
            pend_ids.append(f"{did}-{k}")
            pend_docs.append(piece)
            pend_meta.append({"url": d.url, "title": d.title or "", "chunk": k})
        embedded += 1
        if len(pend_docs) >= 1024:
            flush()
        if seen % 200 == 0:
            print(f"  {seen} seen, {embedded} new, {skipped} skipped, {failed} failed, {time.time()-t0:.0f}s", flush=True)
    flush()
    print(f"done: {seen} documents, {embedded} embedded, {skipped} already done, {failed} failed", flush=True)


if __name__ == "__main__":
    main()

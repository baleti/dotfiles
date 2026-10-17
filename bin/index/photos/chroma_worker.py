#!/usr/bin/env python3
"""Chroma semantic text search worker: holds the Chroma indexes (~1.4M chunks, a few GB of RAM) and the MiniLM
query embedder OUT of the search server, answers on 127.0.0.1:8766, loads each index the first time it is
asked and exits after IDLE_SECONDS without a request (the search server starts it again on demand,
chroma-search.service). The search server turns the hits into /chroma results.

    GET /search?q=<text>&via=<index>&n=<chunks per index>   -> {"hits": [{"url", "collection", "chunk", "score", "text"}], "errors": []}
    GET /doc?url=<file url>&q=<text>&via=<index>&n=3         -> the best chunks of one file for that query
    GET /ping                                                 -> {"ok": true, "indexes": [...]}
"""
import glob, json, os, sys, threading, time, urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
PORT = int(os.environ.get("CHROMA_WORKER_PORT", "8766"))
IDLE_SECONDS = float(os.environ.get("CHROMA_WORKER_IDLE", "900"))
BASE = os.path.expanduser("~/.cache/indexes")
_cols, _lock, _last = {}, threading.Lock(), [time.time()]

def index_names():
    """Index name -> chroma directory, for every ~/.cache/indexes/<name>/chroma that exists."""
    return {os.path.basename(os.path.dirname(d)): d for d in sorted(glob.glob(os.path.join(BASE, "*", "chroma")))}

def pick(via):
    names = index_names()
    if not via:
        return list(names), None
    hit = [n for n in names if n == via] or [n for n in names if n.startswith(via)]
    if len(hit) != 1:
        return [], (f"no semantic index named '{via}'" if not hit else f"'{via}' matches several indexes: {', '.join(hit)}")
    return hit, None

def collection(name):
    with _lock:
        if name not in _cols:
            import chromadb
            client = chromadb.PersistentClient(path=index_names()[name])
            infos = client.list_collections()
            _cols[name] = client.get_collection(infos[0].name) if infos else None
        return _cols[name]

def embed(text):
    import minilm_text
    return minilm_text.embed_texts([text])[0].tolist()

def search(text, via, n):
    names, err = pick(via)
    if err:
        return {"hits": [], "errors": [err]}
    emb = embed(text)
    hits = []
    for name in names:
        col = collection(name)
        if col is None or col.count() == 0:
            continue
        r = col.query(query_embeddings=[emb], n_results=min(n, col.count()), include=["metadatas", "documents", "distances"])
        for m, d, dist in zip(r["metadatas"][0], r["documents"][0], r["distances"][0]):
            hits.append({"url": m.get("url", ""), "collection": name, "chunk": m.get("chunk"), "score": round(1.0 - float(dist), 4), "text": d})
    hits.sort(key=lambda h: -h["score"])
    return {"hits": hits[:n], "errors": []}

def doc_chunks(url, text, via, n):
    names, err = pick(via)
    if err:
        return {"hits": [], "errors": [err]}
    emb = embed(text)
    hits = []
    for name in names:
        col = collection(name)
        if col is None or col.count() == 0:
            continue
        r = col.query(query_embeddings=[emb], n_results=n, where={"url": url}, include=["metadatas", "documents", "distances"])
        for m, d, dist in zip(r["metadatas"][0], r["documents"][0], r["distances"][0]):
            hits.append({"url": m.get("url", ""), "collection": name, "chunk": m.get("chunk"), "score": round(1.0 - float(dist), 4), "text": d})
    hits.sort(key=lambda h: -h["score"])
    return {"hits": hits[:n], "errors": []}

class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def _json(self, code, obj):
        body = json.dumps(obj).encode()
        self.send_response(code); self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body))); self.end_headers(); self.wfile.write(body)
    def do_GET(self):
        _last[0] = time.time()
        u = urllib.parse.urlparse(self.path); qs = urllib.parse.parse_qs(u.query)
        g = lambda k, d="": qs.get(k, [d])[0]
        try:
            if u.path == "/ping":
                return self._json(200, {"ok": True, "indexes": list(index_names())})
            if u.path == "/search":
                return self._json(200, search(g("q"), g("via"), int(g("n", "200"))))
            if u.path == "/doc":
                return self._json(200, doc_chunks(g("url"), g("q"), g("via"), int(g("n", "3"))))
        except Exception as e:
            return self._json(200, {"hits": [], "errors": [f"{type(e).__name__}: {e}"]})
        self._json(404, {"error": "not found"})

def idle_watch():
    while True:
        time.sleep(30)
        if time.time() - _last[0] > IDLE_SECONDS:
            print("idle, exiting", file=sys.stderr, flush=True)
            os._exit(0)

if __name__ == "__main__":
    threading.Thread(target=idle_watch, daemon=True).start()
    print(f"chroma worker on 127.0.0.1:{PORT}, indexes: {', '.join(index_names())}", file=sys.stderr, flush=True)
    ThreadingHTTPServer(("127.0.0.1", PORT), H).serve_forever()

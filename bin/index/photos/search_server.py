#!/usr/bin/env python3
"""Long-running photo search server for the `images` picker.

Keeps the CLIP text model, the face/CLIP indexes and the registered people in
memory, so each keystroke costs milliseconds instead of a 25 s cold start.
Listens on the host/port in the config (localhost only).

  GET /query?q=...&top=N   -> {"count", "results": [{remote, score, size, mtime, thumb, ready}], "errors"}
                              empty q = browse (newest photos first)
  GET /thumb?remote=...    -> queues a thumbnail (if missing); {"ready", "thumb"}
  GET /people              -> {"people": [registered names]} (for completion)
"""
import hashlib, json, os, queue, re, subprocess, sys, threading, time, urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import config  # noqa: E402
import search  # noqa: E402  (query engine)
import cv2, numpy as np  # noqa: E402
# file-name search: the in-memory name table lives in the catalog package
sys.path.insert(0, os.path.join(os.path.dirname(HERE), "catalog"))
import filesearch  # noqa: E402

IMAGE_EXT = (".jpg", ".jpeg", ".png", ".gif", ".webp", ".bmp", ".tif", ".tiff", ".heic")

# ---- file-type icons for non-image results (theme icons, rasterised once and cached) ----
import mimetypes, importlib.util
ICON_RESOLVER = os.environ.get("ICON_RESOLVER", os.path.expanduser("~/.config/quickshell/scripts/resolve-icons.py"))
ICON_DIR = os.path.join(config.DATA_DIR, "icons")
EXT_ICON = {"log": "text-x-log", "py": "text-x-python", "json": "application-json", "md": "text-markdown",
            "pdf": "application-pdf", "org": "text-x-generic", "lua": "text-x-lua", "rs": "text-rust",
            "sh": "application-x-shellscript", "zsh": "application-x-shellscript", "qml": "text-x-qml",
            "js": "text-x-javascript", "ts": "text-x-typescript", "html": "text-html", "css": "text-css",
            "xml": "text-xml", "yaml": "text-x-yaml", "yml": "text-x-yaml", "toml": "text-x-toml"}
_icon_state = {"resolve": None, "cache": {}}

def _icon_resolver():
    if _icon_state["resolve"] is None:
        spec = importlib.util.spec_from_file_location("resolve_icons", ICON_RESOLVER)
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        idx, pix = mod.build_index()
        _icon_state["resolve"] = lambda name: mod.resolve(name, idx, pix)
    return _icon_state["resolve"]

def _icon_name(path):
    # named files never need a stat: on the FUSE mounts each one costs a network round trip
    ext = path.rsplit(".", 1)[-1].lower() if "." in path.rsplit("/", 1)[-1] else ""
    if ext in EXT_ICON:
        return EXT_ICON[ext]
    if not ext and os.path.isdir(path):
        return "inode-directory"
    mime = mimetypes.guess_type(path)[0] or ""
    return mime.replace("/", "-") if mime else "text-x-generic"

def icon_for(path):
    """Cached PNG path for a file's type icon ('' when no icon could be found)."""
    name = _icon_name(path)
    if name in _icon_state["cache"]:
        return _icon_state["cache"][name]
    # 256 px so the icons stay sharp when the picker is zoomed in
    out = os.path.join(ICON_DIR, name + "-256.png")
    if not os.path.exists(out):
        svg = _icon_resolver()(name) or _icon_resolver()("text-x-generic")
        if svg and svg.endswith(".svg"):
            os.makedirs(ICON_DIR, exist_ok=True)
            subprocess.run(["rsvg-convert", "-w", "256", "-h", "256", svg, "-o", out], capture_output=True)
    _icon_state["cache"][name] = out if os.path.exists(out) else ""
    return _icon_state["cache"][name]
NAMES = filesearch.NameTable(os.path.expanduser(config.CFG["catalog"]["db"]))

# Recoll/Xapian content indexes (each one is a Recoll config directory) searched by /fts
FTS_INDEXES = [os.path.expanduser(p) for p in config.CFG.get("fts", {}).get("indexes", [])]
_fts_cache = {}
_fts_lock = threading.Lock()

def fts_name(conf):
    """An index's name is its folder: ~/.cache/indexes/part3-books/recoll -> part3-books."""
    return os.path.basename(os.path.dirname(conf.rstrip("/")))

def is_subsequence(frag, name):
    it = iter(name)
    return all(c in it for c in frag)

def fts_resolve(token):
    """Index confs for a name or shorthand: exact, else a prefix, else letters in order (p3 -> part3-books)."""
    names = {fts_name(c): c for c in FTS_INDEXES}
    t = token.lower()
    if not t:
        return list(FTS_INDEXES), None
    if t in names:
        return [names[t]], None
    for match in (lambda n: n.startswith(t), lambda n: is_subsequence(t, n)):
        hits = [n for n in names if match(n)]
        if len(hits) == 1:
            return [names[hits[0]]], None
        if len(hits) > 1:
            return [], "ambiguous index: " + ", ".join(sorted(hits))
    return [], "no index named " + token

def fts_matches(terms, confs):
    """Paths whose contents match a Recoll query, from the given content indexes, with sizes."""
    key = (terms, tuple(confs))
    with _fts_lock:
        if key in _fts_cache:
            return _fts_cache[key]
    rows, seen = [], set()
    for conf in confs:
        out = subprocess.run(["recollq", "-c", conf, "-n", "0-5000", terms], capture_output=True, text=True).stdout
        for line in out.splitlines():
            parts = line.split("\t")
            if len(parts) < 4 or not parts[1].startswith("[file://"):
                continue
            path = urllib.parse.unquote(parts[1][len("[file://"):-1])
            if path in seen:
                continue
            seen.add(path)
            size = int(parts[3]) if parts[3].isdigit() else None
            rows.append({"remote": path, "size": size, "mtime": None})
    with _fts_lock:
        _fts_cache.clear()
        _fts_cache[key] = rows
    return rows

def fts_query(text, index_token, sort, desc, offset, limit):
    """/fts[/index] <recoll terms> [//mime kind] [//name x] [//path x] [//size >5M]: only content-indexed files can match."""
    from filesearch import split_mime, split_tags, matches_mime, _size_ok
    confs, err = fts_resolve(index_token)
    if err:
        return [], 0, err
    wanted, rest = split_mime(text)
    tags, terms = split_tags(rest)
    if not terms.strip():
        return [], 0, None
    rows = [r for r in fts_matches(terms.strip(), confs) if (not wanted or matches_mime(r["remote"], wanted))
            and all(t.lower() in r["remote"].rsplit("/", 1)[-1].lower() for t in tags["name"])
            and all(t.lower() in r["remote"].lower() for t in tags["path"])
            and all(_size_ok(r["size"], c) for c in tags["size"])]
    if sort in ("name", "path", "size"):
        key = {"name": lambda r: r["remote"].rsplit("/", 1)[-1].lower(),
               "path": lambda r: r["remote"].lower(),
               "size": lambda r: r["size"] or 0}[sort]
        rows.sort(key=key, reverse=desc)
    return rows[offset: offset + limit], len(rows), None

_snip_dbs = {}
_snip_lock = threading.Lock()

class _Mark:
    """Recoll highlight methods: control characters around each match, turned into ranges below."""
    def startMatch(self, i): return "\x01"
    def endMatch(self): return "\x02"

def fts_snippets(remote, text):
    """Recoll's own snippets for one file under a /fts query (its default context and occurrence limits):
    [{"page": n|None, "text": plain text, "ranges": [[start, end], ...]}]."""
    import html
    from recoll import recoll
    from filesearch import split_mime, split_tags
    m = re.match(r"^/(?:fts|full-text-search)(?:/(\S*))?(?:\s+|$)(.*)$", text.strip(), re.S)
    if not m:
        return [], "not a /fts query"
    confs, err = fts_resolve(m.group(1) or "")
    if err:
        return [], err
    _, rest = split_mime(m.group(2))
    _, terms = split_tags(rest)
    terms = terms.strip()
    if not terms:
        return [], None
    with _snip_lock:
        for conf in confs:
            if conf not in _snip_dbs:
                _snip_dbs[conf] = recoll.connect(confdir=conf)
            q = _snip_dbs[conf].query()
            q.execute(terms)
            for _ in range(5000):
                doc = q.fetchone()
                if doc is None:
                    break
                if urllib.parse.unquote(doc.url[len("file://"):]) != remote:
                    continue
                out = []
                for page, _term, snip in q.getsnippets(doc, methods=_Mark()):
                    snip = html.unescape(snip) if "&" in snip else snip
                    plain, ranges, start = [], [], None
                    for ch in snip:
                        if ch == "\x01":
                            start = sum(len(p.encode()) for p in plain)
                        elif ch == "\x02":
                            if start is not None:
                                ranges.append([start, sum(len(p.encode()) for p in plain)])
                            start = None
                        else:
                            plain.append(ch)
                    out.append({"page": page if page and page > 0 else None, "text": "".join(plain), "ranges": ranges})
                return out, None
    return [], None

THUMBS = os.path.join(config.DATA_DIR, "thumbs")

META = {}
for _stem, _folder in config.SOURCES.items():
    _p = os.path.join(config.DATA_DIR, "lists", _stem + ".json")
    if not os.path.exists(_p): continue
    for _e in json.load(open(_p, encoding="utf-8")):
        META[f"{config.REMOTE}{_folder}/{_e['Path']}"] = (_e.get("Size"), _e.get("ModTime"))

def with_meta(r):
    size, mtime = META.get(r["remote"], (None, None))
    r["size"], r["mtime"] = size, mtime
    return r
PORT = config.SERVER_PORT
_q_lock = threading.Lock()          # one query at a time (onnx session is not re-entrant)
_pending = queue.Queue()
_queued = set()
_queued_lock = threading.Lock()

def thumb_path(remote):
    return os.path.join(THUMBS, hashlib.sha1(remote.encode()).hexdigest()[:16] + ".jpg")

def make_thumb(remote):
    dst = thumb_path(remote)
    if os.path.exists(dst): return
    if remote.startswith("/"):                 # local file from the file-name index
        data = open(remote, "rb").read()
    else:
        data = subprocess.run(["rclone", "cat", remote], capture_output=True).stdout
    img = cv2.imdecode(np.frombuffer(data, np.uint8), cv2.IMREAD_COLOR)
    if img is None: return
    os.makedirs(THUMBS, exist_ok=True)
    h, w = img.shape[:2]; s = 256 / max(h, w)
    img = cv2.resize(img, (max(1, round(w * s)), max(1, round(h * s))), interpolation=cv2.INTER_AREA)
    cv2.imwrite(dst, img, [cv2.IMWRITE_JPEG_QUALITY, 85])

def thumb_worker():
    while True:
        remote = _pending.get()
        try: make_thumb(remote)
        except Exception as e: print("thumb failed", remote, e, file=sys.stderr, flush=True)
        finally:
            with _queued_lock: _queued.discard(remote)

def enqueue(remote):
    if os.path.exists(thumb_path(remote)): return True
    with _queued_lock:
        if remote not in _queued:
            _queued.add(remote); _pending.put(remote)
    return False

class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def _json(self, code, obj):
        body = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers(); self.wfile.write(body)
    def do_GET(self):
        u = urlparse(self.path); qs = parse_qs(u.query)
        if u.path == "/query":
            q = (qs.get("q", [""])[0]).strip()
            top = int(qs.get("top", ["60"])[0])
            # default: file-name search over everything the catalog knows; //clip and //face
            # switch to photo search; the explicit //file prefix is still accepted
            photo_mode = ("//clip" in q) or ("//face" in q)
            if not photo_mode:
                rest = q[len("//file"):].strip() if q.startswith("//file") else q
                sort = qs.get("sort", ["date"])[0]
                desc = qs.get("desc", ["1"])[0] == "1"
                offset = int(qs.get("offset", ["0"])[0])
                fts = re.match(r"^/(?:fts|full-text-search)(?:/(\S*))?(?:\s+|$)(.*)$", rest, re.S)
                errors = []
                if fts:
                    results, count, err = fts_query(fts.group(2), fts.group(1) or "", sort, desc, offset, top)
                    errors = [err] if err else []
                else:
                    results, count = NAMES.query(rest, sort, desc, offset, top)
                for r in results:
                    r["score"] = None
                    if r["remote"].lower().endswith(IMAGE_EXT):
                        r["thumb"] = thumb_path(r["remote"])
                        r["ready"] = enqueue(r["remote"])
                    else:
                        r["thumb"] = icon_for(r["remote"])
                        r["ready"] = bool(r["thumb"])
                    # the catalog stores epoch seconds; the picker expects the same ISO text photos use
                    if isinstance(r.get("mtime"), int):
                        r["mtime"] = time.strftime("%Y-%m-%dT%H:%M:%S", time.localtime(r["mtime"]))
                return self._json(200, {"count": count, "results": results, "errors": errors})
            try:
                with _q_lock:
                    if not q:
                        results, count, errors = search.browse(top), None, []
                    else:
                        results, count, errors = search.run_query(q, top)
            except ValueError as e:
                return self._json(200, {"count": 0, "results": [], "errors": [str(e)]})
            except Exception as e:
                return self._json(500, {"error": str(e)})
            for r in results:
                with_meta(r)
                r["thumb"] = thumb_path(r["remote"])
                r["ready"] = enqueue(r["remote"])
            return self._json(200, {"count": count if count is not None else len(results),
                                    "results": results, "errors": errors})
        if u.path == "/snippets":
            try:
                snips, err = fts_snippets(qs.get("remote", [""])[0], qs.get("q", [""])[0])
            except Exception as e:
                return self._json(200, {"snippets": [], "error": str(e)})
            return self._json(200, {"snippets": snips, "error": err})
        if u.path == "/facets":
            # values for the //dm and //mime completions
            return self._json(200, {"dates": NAMES.dates, "mimes": list(filesearch.KINDS),
                                    "fts": [fts_name(c) for c in FTS_INDEXES]})
        if u.path == "/people":
            with _q_lock:
                search._refresh()
                names = sorted(search._index["people"])
            return self._json(200, {"people": names})
        if u.path == "/thumb":
            remote = qs.get("remote", [""])[0]
            ready = enqueue(remote)
            return self._json(200, {"ready": ready, "thumb": thumb_path(remote)})
        self._json(404, {"error": "not found"})

def main():
    NAMES.load()
    filesearch.start_refresh(NAMES)
    with _q_lock:
        search._refresh()
        from clip_text import embed_texts
        embed_texts(["warm up"])            # load the text model once, up front
    threading.Thread(target=thumb_worker, daemon=True).start()
    print(f"search server on 127.0.0.1:{PORT}", file=sys.stderr, flush=True)
    ThreadingHTTPServer(("127.0.0.1", PORT), H).serve_forever()

if __name__ == "__main__":
    main()

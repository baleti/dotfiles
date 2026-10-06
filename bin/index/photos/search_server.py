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
import hashlib, json, os, queue, random, re, subprocess, sys, threading, time, urllib.parse
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
from filesearch import path_matches  # noqa: E402

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

PATH_TAG = re.compile(r'//path\s+((?:"[^"]*"|[^\s"])+)')

def split_path_tags(text):
    """'//path gdrive/"part 3" rest' -> (['gdrive/"part 3"'], 'rest'). Quotes keep spaces inside a segment."""
    values = [m.group(1) for m in PATH_TAG.finditer(text)]
    return values, PATH_TAG.sub(" ", text).strip()

def fts_query(text, sort, desc, offset, limit):
    """/fts <recoll terms> [//mime kind] [//name x] [//path x] [//size >5M]: only content-indexed files can match.
    Searches every content index; //path narrows by folder."""
    from filesearch import split_mime, split_tags, matches_mime, _size_ok, path_matches, hidden_folders
    wanted, rest = split_mime(text)
    paths, rest = split_path_tags(rest)
    tags, terms = split_tags(rest)
    if not terms.strip():
        return [], 0, None, None
    hidden = hidden_folders(text)
    rows = [r for r in fts_matches(terms.strip(), FTS_INDEXES) if (not wanted or matches_mime(r["remote"], wanted))
            and not any(r["remote"].startswith(f) for f in hidden)
            and all(path_matches(r["remote"], v) for v in paths)
            and all(t.lower() in r["remote"].rsplit("/", 1)[-1].lower() for t in tags["name"])
            and all(_size_ok(r["size"], c) for c in tags["size"])]
    if sort in ("name", "path", "size"):
        key = {"name": lambda r: r["remote"].rsplit("/", 1)[-1].lower(),
               "path": lambda r: r["remote"].lower(),
               "size": lambda r: r["size"] or 0}[sort]
        rows.sort(key=key, reverse=desc)
    from collections import Counter
    kinds = Counter(filesearch.kind_of(r["remote"]) or "no ext" for r in rows).most_common(5)
    stats = {"size": sum(r["size"] or 0 for r in rows), "kinds": [[k, n] for k, n in kinds]}
    return rows[offset: offset + limit], len(rows), None, stats

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
    m = re.match(r"^/(?:fts|full-text-search)(?:\s+|$)(.*)$", text.strip(), re.S)
    if not m:
        return [], "not a /fts query"
    confs = FTS_INDEXES
    _, rest = split_mime(m.group(1))
    _, rest = split_path_tags(rest)
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
_pending = queue.LifoQueue()   # newest request first: what is on screen now beats what was scrolled past
_queued = set()
_queued_lock = threading.Lock()

def thumb_path(remote):
    return os.path.join(THUMBS, hashlib.sha1(remote.encode()).hexdigest()[:16] + ".jpg")

FACECROPS = os.path.join(config.DATA_DIR, "facecrops")
_paths_cache = {"frag": None, "rows": []}

def display_folder(d):
    """Mount path -> the short form people type: gdrive/..., ~/..."""
    mount = os.path.expanduser(config.CFG["mount_root"])
    if d.startswith(mount + "/"):
        return "gdrive/" + d[len(mount) + 1:]
    home = os.path.expanduser("~")
    return "~/" + d[len(home) + 1:] if d.startswith(home + "/") else d

def path_candidates(frag, offset, top):
    """Folders matching a //path fragment, in order: (total, page)."""
    if _paths_cache["frag"] != frag:
        rows = [display_folder(d) for d in NAMES.dirs if path_matches(display_folder(d), frag)]
        _paths_cache["frag"], _paths_cache["rows"] = frag, rows
    rows = _paths_cache["rows"]
    return len(rows), rows[offset: offset + top]

FACE_POOL = []
_face_pool_lock = threading.Lock()

def face_crop_path(face):
    """Path of a face's cached crop if it exists, else ''."""
    dst = os.path.join(FACECROPS, hashlib.sha1(face["id"].encode()).hexdigest()[:16] + ".jpg")
    return dst if os.path.exists(dst) else ""

def warm_face_pool(n=400):
    """Cut crops for a fixed sample of faces in the background, so the face pane is instant."""
    rows = search.face_pane(n, seed=7)
    for r in rows:
        if face_crop(r):
            with _face_pool_lock:
                FACE_POOL.append(r)
    print(f"face pool ready: {len(FACE_POOL)} crops", file=sys.stderr, flush=True)

def face_crop(face):
    """A square crop around one detected face, 160 px, cached; '' when the photo cannot be read."""
    dst = os.path.join(FACECROPS, hashlib.sha1(face["id"].encode()).hexdigest()[:16] + ".jpg")
    if os.path.exists(dst):
        return dst
    remote = face["remote"]
    if remote.startswith(config.CFG["rclone_remote"]):
        remote = os.path.join(os.path.expanduser(config.CFG["mount_root"]), remote[len(config.CFG["rclone_remote"]):])
    if not remote.startswith("/"):
        return ""
    img = cv2.imread(remote)
    if img is None:
        return ""
    h, w = img.shape[:2]
    x1, y1, x2, y2 = face["bbox"]
    side = max(x2 - x1, y2 - y1) * 1.6
    cx, cy = (x1 + x2) / 2, (y1 + y2) / 2
    a, b = int(max(0, cx - side / 2)), int(max(0, cy - side / 2))
    crop = img[b:min(h, int(cy + side / 2)), a:min(w, int(cx + side / 2))]
    if crop.size == 0:
        return ""
    os.makedirs(FACECROPS, exist_ok=True)
    cv2.imwrite(dst, cv2.resize(crop, (160, 160), interpolation=cv2.INTER_AREA), [cv2.IMWRITE_JPEG_QUALITY, 85])
    return dst

def make_pdf_thumb(remote, dst):
    """First page of a PDF as a 256 px JPEG (poppler's pdftoppm; -singlefile writes <base>.jpg)."""
    os.makedirs(THUMBS, exist_ok=True)
    base = dst[:-len(".jpg")]
    subprocess.run(["pdftoppm", "-jpeg", "-jpegopt", "quality=85", "-f", "1", "-l", "1",
                    "-scale-to", "256", "-singlefile", remote, base],
                   capture_output=True, timeout=120)

def make_thumb(remote):
    dst = thumb_path(remote)
    if os.path.exists(dst): return
    if remote.lower().endswith(".pdf") and remote.startswith("/"):
        make_pdf_thumb(remote, dst)
        return
    if remote.startswith("/"):                 # local file from the file-name index
        data = open(remote, "rb").read()
    else:
        # through the rclone mount when it has the file (its cache makes this much quicker than a fresh
        # `rclone cat`, which costs several seconds of start-up per file); rclone cat is the fallback
        data = b""
        if remote.startswith(config.REMOTE):
            try:
                data = open(os.path.join(os.path.expanduser(config.CFG["mount_root"]), remote[len(config.REMOTE):]), "rb").read()
            except OSError:
                data = b""
        if not data:
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
            offset = int(qs.get("offset", ["0"])[0])
            # default: file-name search over everything the catalog knows; /clip and /face
            # switch to photo search; the explicit //file prefix is still accepted
            photo_mode = re.search(r"(?:^|\s)/(?:clip|face)(?:\s|$)", q) is not None
            if not photo_mode:
                rest = q[len("//file"):].strip() if q.startswith("//file") else q
                sort = qs.get("sort", ["date"])[0]
                desc = qs.get("desc", ["1"])[0] == "1"
                offset = int(qs.get("offset", ["0"])[0])
                fts = re.match(r"^/(?:fts|full-text-search)(?:\s+|$)(.*)$", rest, re.S)
                errors = []
                if fts:
                    results, count, err, stats = fts_query(fts.group(1), sort, desc, offset, top)
                    errors = [err] if err else []
                else:
                    results, count, stats = NAMES.query(rest, sort, desc, offset, top)
                for r in results:
                    r["score"] = None
                    if r["remote"].lower().endswith(IMAGE_EXT) or r["remote"].lower().endswith(".pdf"):
                        r["thumb"] = thumb_path(r["remote"])
                        r["ready"] = enqueue(r["remote"])
                    else:
                        r["thumb"] = icon_for(r["remote"])
                        r["ready"] = bool(r["thumb"])
                    # the catalog stores epoch seconds; the picker expects the same ISO text photos use
                    if isinstance(r.get("mtime"), int):
                        r["mtime"] = None if r["mtime"] < 172800 or r["mtime"] in (filesearch.UNKNOWN_MTIME, 123456789) else time.strftime("%Y-%m-%dT%H:%M:%S", time.localtime(r["mtime"]))
                return self._json(200, {"count": count, "results": results, "errors": errors, "stats": stats})
            try:
                with _q_lock:
                    if not q:
                        results, count, errors = search.browse(offset + top), None, []
                    else:
                        results, count, errors = search.run_query(q, offset + top, clip_n=10**9)
                    results = results[offset:]
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
        if u.path == "/paths":
            # folders for //path completion: a page at a time, the picker lists them virtually
            frag = qs.get("q", [""])[0].strip().strip('"')
            offset = int(qs.get("offset", ["0"])[0])
            top = int(qs.get("top", ["200"])[0])
            total, items = path_candidates(frag, offset, top)
            return self._json(200, {"total": total, "items": items})
        if u.path == "/faces/pane":
            # random indexed faces to pick from: the picker shows the crops, no names involved.
            # Served from the pre-cut pool, so opening the pane does not wait on photo reads.
            n = int(qs.get("n", ["48"])[0])
            seed = int(qs["seed"][0]) if "seed" in qs else None
            rnd = random.Random(seed)
            with _face_pool_lock:
                ready = list(FACE_POOL)
            if ready:
                picks = rnd.sample(ready, min(n, len(ready)))
                faces = [{"id": r["id"], "thumb": face_crop_path(r)} for r in picks]
            else:
                with _q_lock:
                    rows = search.face_pane(n, seed)
                faces = [{"id": r["id"], "thumb": face_crop(r)} for r in rows]
            return self._json(200, {"faces": [f for f in faces if f["thumb"]]})
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
    threading.Thread(target=warm_face_pool, daemon=True).start()
    for _ in range(8):                      # thumbnails are I/O bound (rclone / FUSE reads), so run several at once
        threading.Thread(target=thumb_worker, daemon=True).start()
    print(f"search server on 127.0.0.1:{PORT}", file=sys.stderr, flush=True)
    ThreadingHTTPServer(("127.0.0.1", PORT), H).serve_forever()

if __name__ == "__main__":
    main()

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
import hashlib, json, os, queue, subprocess, sys, threading, time
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
                if rest:
                    results, count = NAMES.search(rest, top)
                else:
                    results, count = NAMES.browse(top), None
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
                return self._json(200, {"count": count if count is not None else len(results), "results": results, "errors": []})
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
        if u.path == "/facets":
            # values for the //dm and //mime completions
            return self._json(200, {"dates": NAMES.dates, "mimes": list(filesearch.KINDS)})
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

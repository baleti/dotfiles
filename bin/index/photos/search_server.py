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
import collections, hashlib, hmac, json, os, queue, random, re, secrets, subprocess, sys, threading, time, urllib.parse
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
            path = config.to_local(urllib.parse.unquote(parts[1][len("[file://"):-1]))
            if path in seen:
                continue
            seen.add(path)
            size = int(parts[3]) if parts[3].isdigit() else None
            rows.append({"remote": path, "size": size, "mtime": None})
    with _fts_lock:
        _fts_cache.clear()
        _fts_cache[key] = rows
    return rows

PATH_TAG = re.compile(r'(?<!!)//path\s+(?!!)((?:"[^"]*"|[^\s"])+)')  # negated forms stay for split_tags

def split_path_tags(text):
    """'//path gdrive/"part 3" rest' -> (['gdrive/"part 3"'], 'rest'). Quotes keep spaces inside a segment."""
    values = [m.group(1) for m in PATH_TAG.finditer(text)]
    return values, PATH_TAG.sub(" ", text).strip()

def fts_pick_indexes(via, terms):
    """Which content indexes a /fts query searches: `/fts/<index> terms` names one (a unique prefix of the
    index folder name is enough); a leading bare word that is exactly an index name also selects it.
    Returns (confs, terms, error)."""
    names = {fts_name(c): c for c in FTS_INDEXES}
    if not via:
        first, _, rest = terms.strip().partition(" ")
        if first in names:
            return [names[first]], rest, None
        return FTS_INDEXES, terms, None
    hit = [n for n in names if n == via] or [n for n in names if n.startswith(via)]
    if len(hit) != 1:
        return [], terms, f"no content index named '{via}'" if not hit else f"'{via}' matches several indexes: {', '.join(hit)}"
    return [names[hit[0]]], terms, None

def fts_query(text, sort, desc, offset, limit, via=None):
    """/fts <recoll terms> [//mime kind] [//name x] [//path x] [//size >5M]: only content-indexed files can match.
    Searches every content index; //path narrows by folder."""
    from filesearch import split_mime_all, split_tags, matches_mime, _size_ok, path_matches, hidden_folders
    wanted, not_wanted, rest = split_mime_all(text)
    paths, rest = split_path_tags(rest)
    tags, terms = split_tags(rest)
    # "!" negation of free terms has no Recoll meaning here (Recoll has its own -term): inert
    terms = " ".join(t for t in filesearch.tokens(terms) if not t.startswith("!"))
    confs, terms, err = fts_pick_indexes(via, terms)
    if err:
        return [], 0, err, None
    if not terms.strip():
        return [], 0, None, None
    hidden = hidden_folders(text)
    rows = [r for r in fts_matches(terms.strip(), confs) if (not wanted or matches_mime(r["remote"], wanted))
            and not (not_wanted and matches_mime(r["remote"], not_wanted))
            and not any(path_matches(r["remote"], v) for v in tags["!path"])
            and not any(t.lower() in r["remote"].rsplit("/", 1)[-1].lower() for t in tags["!name"])
            and not any(_size_ok(r["size"], c) for c in tags["!size"])
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
    m = re.match(r"^/(?:fts|full-text-search)(?:/([\w.-]+))?(?:\s+|$)(.*)$", text.strip(), re.S)
    if not m:
        return [], "not a /fts query"
    _, rest = split_mime(m.group(2))
    _, rest = split_path_tags(rest)
    _, terms = split_tags(rest)
    confs, terms, err = fts_pick_indexes(m.group(1), terms.strip())
    terms = terms.strip()
    if err or not terms:
        return [], err
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
                if urllib.parse.unquote(doc.url[len("file://"):]) != config.to_index(remote):
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
HQ_DIR = os.path.join(config.DATA_DIR, "thumbs-hq")
HQ_WANT_TTL = 6.0          # a render is only worth doing while the picker still asks for it
HQ_MAX_WANTED = 64
_hq_want = collections.OrderedDict()   # remote -> last time the picker asked (newest last)
_hq_failed = set()
_hq_lock = threading.Lock()

def hq_path(remote):
    return os.path.join(HQ_DIR, hashlib.sha1(remote.encode()).hexdigest()[:16] + ".jpg")

def _hq_still_wanted(remote):
    with _hq_lock:
        t = _hq_want.get(remote)
    return t is not None and time.time() - t < HQ_WANT_TTL

def hq_worker():
    """One background render at a time, newest request first. A render is killed as soon as the picker stops asking."""
    while True:
        remote = None
        with _hq_lock:
            for r, t in reversed(_hq_want.items()):
                if time.time() - t < HQ_WANT_TTL and r not in _hq_failed and not os.path.exists(hq_path(r)):
                    remote = r
                    break
        if remote is None:
            time.sleep(0.2)
            continue
        dst = hq_path(remote)
        os.makedirs(HQ_DIR, exist_ok=True)
        proc = subprocess.Popen(["nice", "-n", "15", "pdftoppm", "-jpeg", "-jpegopt", "quality=90", "-f", "1", "-l", "1",
                                 "-scale-to", "1000", "-singlefile", remote, dst[:-len(".jpg")]],
                                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        aborted = False
        while proc.poll() is None:
            if not _hq_still_wanted(remote):
                proc.kill(); proc.wait(); aborted = True
                break
            time.sleep(0.1)
        if not aborted and proc.returncode != 0:
            with _hq_lock:
                _hq_failed.add(remote)
        if aborted and os.path.exists(dst):
            os.remove(dst)

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
    # thumbnails are background work: a low priority for this thread (and for the pdftoppm it starts) keeps
    # the interactive queries from competing with them for the CPU
    try: os.setpriority(os.PRIO_PROCESS, threading.get_native_id(), 15)
    except OSError: pass
    while True:
        remote, tag = _pending.get()
        try:
            if tag is not None and tag[1] < _latest_seq.get(tag[0], 0):
                continue                          # asked for by a query that has been typed past: not needed any more
            make_thumb(remote)
        except Exception as e: print("thumb failed", remote, e, file=sys.stderr, flush=True)
        finally:
            with _queued_lock: _queued.discard(remote)

def enqueue(remote, tag=None):
    if os.path.exists(thumb_path(remote)): return True
    with _queued_lock:
        if remote not in _queued:
            _queued.add(remote); _pending.put((remote, tag))
    return False

# ---- view settings: defaults in the picker's settings file, overridden per query by verbs ------------------
SETTINGS_PATH = os.path.expanduser("~/.config/indexes/picker-settings.json")
SETTINGS_DEFAULT = {"show_dotfiles": True, "show_backup_restic": False, "show_backup_btrfs": False}
_settings = {"mtime": None, "value": dict(SETTINGS_DEFAULT)}
VIEW_VERBS = {
    "/show-dotfiles": (("show_dotfiles",), True), "/hide-dotfiles": (("show_dotfiles",), False),
    "/show-backup": (("show_backup_restic", "show_backup_btrfs"), True),
    "/hide-backup": (("show_backup_restic", "show_backup_btrfs"), False),
    "/show-backup-restic": (("show_backup_restic",), True), "/hide-backup-restic": (("show_backup_restic",), False),
    "/show-backup-btrfs": (("show_backup_btrfs",), True), "/hide-backup-btrfs": (("show_backup_btrfs",), False),
}

def picker_settings():
    """The settings file (re-read when it changes), over the defaults; a missing or broken file means defaults."""
    try:
        m = os.path.getmtime(SETTINGS_PATH)
    except OSError:
        m = None
    if m != _settings["mtime"]:
        value = dict(SETTINGS_DEFAULT)
        try:
            value.update({k: bool(v) for k, v in json.load(open(SETTINGS_PATH)).items() if k in SETTINGS_DEFAULT})
        except (OSError, ValueError):
            pass
        _settings.update(mtime=m, value=value)
    return dict(_settings["value"])

def view_options(q):
    """(query without the view verbs, effective view options). Verbs apply left to right, so a later one wins;
    /show-backup and /hide-backup set both backup kinds, the specific ones set just one."""
    opts = picker_settings()
    toks = filesearch.tokens(q)
    if not any(t.lower() in VIEW_VERBS for t in toks):
        return q, opts
    kept = []
    for t in toks:
        v = VIEW_VERBS.get(t.lower())
        if v is None:
            kept.append(t)
        else:
            for name in v[0]:
                opts[name] = v[1]
    return " ".join(kept), opts

# ---- backups: tables of their own (restic, btrfs snapshots), loaded in the background the first time a query asks --
BACKUPS = {
    "restic": {"table": filesearch.ResticTable(os.path.join(os.path.dirname(NAMES.db_path), "catalog-restic.db")),
               "loading": threading.Event(), "setup": "restic_store.py migrate", "name": "restic backups"},
    "btrfs": {"table": filesearch.BtrfsTable(os.path.join(os.path.dirname(NAMES.db_path), "catalog-btrfs.db")),
              "loading": threading.Event(), "setup": "btrfs_store.py build", "name": "btrfs snapshots"},
}

def _backup_load(b):
    try:
        b["table"].load()
    except Exception as e:
        print(f"{b['name']} table load failed:", repr(e), file=sys.stderr, flush=True)
    finally:
        b["loading"].clear()

def backup_table(kind):
    """(table or None, status message or None). Starts a background (re)load when there is no table yet or the store
    changed; the answer meanwhile comes without those rows and says so."""
    b = BACKUPS[kind]
    t = b["table"]
    if not os.path.exists(t.db_path):
        return None, f"no {b['name']} index yet (run: {b['setup']})"
    stale = (not t.paths) or t._stale_marker() > t.loaded_mtime
    if stale and not b["loading"].is_set():
        b["loading"].set()
        threading.Thread(target=_backup_load, args=(b,), daemon=True).start()
    if not t.paths:
        return None, f"{b['name']} are loading (first use, about 10 s): the panel refreshes when they are ready"
    return t, None

# ---- a picker types faster than queries finish: remember the newest request of each client and drop older ones ----
_latest_seq = {}
_latest_lock = threading.Lock()

def note_request(cid, seq):
    """Register a request; returns a function telling whether a newer one from the same client has arrived."""
    if not cid or not seq:
        return None
    with _latest_lock:
        if seq > _latest_seq.get(cid, 0):
            _latest_seq[cid] = seq
        if len(_latest_seq) > 64:
            for k in list(_latest_seq)[:32]:
                _latest_seq.pop(k, None)
    return lambda: seq < _latest_seq.get(cid, 0)

def delta_token():
    """Shared secret for POST /delta (the live file-change feed); created on first use, readable only by the user."""
    path = NAMES.db_path + ".delta-token"
    try:
        return open(path).read().strip()
    except OSError:
        tok = secrets.token_hex(24)
        fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, "w") as f:
            f.write(tok)
        return tok

DELTA_TOKEN = None

class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_POST(self):
        u = urlparse(self.path)
        if u.path != "/delta":
            return self._json(404, {"error": "not found"})
        if not hmac.compare_digest(self.headers.get("X-Delta-Token", ""), DELTA_TOKEN or ""):
            return self._json(403, {"error": "forbidden"})
        try:
            n = int(self.headers.get("Content-Length", "0"))
            if n > 64 * 1024 * 1024:
                return self._json(413, {"error": "too large"})
            ops = json.loads(self.rfile.read(n))["ops"]
            assert isinstance(ops, list) and all(
                isinstance(o, list) and o and o[0] in ("put", "del", "delprefix") and isinstance(o[1], str)
                and (o[0] != "put" or len(o) == 4) for o in ops)
        except Exception as e:
            return self._json(400, {"error": f"bad request: {e}"})
        NAMES.apply_ops(ops)
        self._json(200, {"applied": len(ops)})
    def _json(self, code, obj):
        body = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers(); self.wfile.write(body)
    def do_GET(self):
        u = urlparse(self.path); qs = parse_qs(u.query)
        if u.path == "/query":
            q, view = view_options((qs.get("q", [""])[0]).strip())
            cid, seqv = qs.get("cid", [""])[0], int(qs.get("seq", ["0"])[0] or 0)
            tag = (cid, seqv) if cid and seqv else None
            stale = note_request(cid, seqv)
            if stale is not None and stale():
                return self._json(200, {"count": 0, "results": [], "errors": [], "stats": {}, "stale": True})
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
                fts = re.match(r"^/(?:fts|full-text-search)(?:/([\w.-]+))?(?:\s+|$)(.*)$", rest, re.S)
                if not view["show_dotfiles"] and not fts:
                    rest = (rest + " !/.").strip()      # the same negated term typed by hand: no path with a dot component
                errors = []
                if fts:
                    results, count, err, stats = fts_query(fts.group(2), sort, desc, offset, top, fts.group(1))
                    errors = [err] if err else []
                else:
                    extras = []
                    for kind in ("restic", "btrfs"):
                        if view[f"show_backup_{kind}"]:
                            t, note = backup_table(kind)
                            if note:
                                errors.append(note)
                            extras.append(t)
                    results, count, stats = NAMES.query(rest, sort, desc, offset, top, extras=extras, cancel=stale)
                for r in results:
                    r["score"] = None
                    if r["remote"].lower().endswith(IMAGE_EXT) or r["remote"].lower().endswith(".pdf"):
                        r["thumb"] = thumb_path(r["remote"])
                        r["ready"] = enqueue(r["remote"], tag)
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
                r["ready"] = enqueue(r["remote"], tag)
            return self._json(200, {"count": count if count is not None else len(results),
                                    "results": results, "errors": errors})
        if u.path == "/snippets":
            try:
                snips, err = fts_snippets(qs.get("remote", [""])[0], qs.get("q", [""])[0])
            except Exception as e:
                return self._json(200, {"snippets": [], "error": str(e)})
            return self._json(200, {"snippets": snips, "error": err})
        if u.path == "/thumb_hq":
            # sharp first page of a PDF: ready now, or queued for the background renderer
            remote = qs.get("remote", [""])[0]
            if not remote.lower().endswith(".pdf") or not remote.startswith("/"):
                return self._json(404, {"error": "not a local pdf"})
            dst = hq_path(remote)
            if os.path.exists(dst):
                return self._json(200, {"ready": True, "thumb": dst})
            with _hq_lock:
                _hq_want.pop(remote, None)
                _hq_want[remote] = time.time()
                while len(_hq_want) > HQ_MAX_WANTED:
                    _hq_want.popitem(last=False)
                failed = remote in _hq_failed
            return self._json(200, {"ready": False, "failed": failed})
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
        if u.path == "/ver":
            # bumps whenever the name table changes (live delta or reload): the picker polls this to refresh itself
            return self._json(200, {"ver": NAMES._ver + sum(b["table"]._ver for b in BACKUPS.values())})
        if u.path == "/facets":
            # values for the //dm and //mime completions
            return self._json(200, {"dates": NAMES.dates, "mimes": list(filesearch.KINDS),
                                    "exts": NAMES.top_exts(),
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
    global DELTA_TOKEN
    DELTA_TOKEN = delta_token()
    NAMES.load()
    filesearch.start_refresh(NAMES)
    with _q_lock:
        search._refresh()
        from clip_text import embed_texts
        embed_texts(["warm up"])            # load the text model once, up front
    threading.Thread(target=warm_face_pool, daemon=True).start()
    threading.Thread(target=hq_worker, daemon=True).start()
    for _ in range(8):                      # thumbnails are I/O bound (rclone / FUSE reads), so run several at once
        threading.Thread(target=thumb_worker, daemon=True).start()
    print(f"search server on 127.0.0.1:{PORT}", file=sys.stderr, flush=True)
    ThreadingHTTPServer(("127.0.0.1", PORT), H).serve_forever()

if __name__ == "__main__":
    main()

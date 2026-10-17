"""In-memory file-name index (the 'Everything' part of the search server).

All distinct paths from the catalog are kept as one lowercase blob separated by
newlines, plus an offsets array. A query finds the rarest-looking term in the
blob with bytes.find, maps hits back to lines with searchsorted, then checks the
other terms per candidate. Each keystroke is one scan over RAM; nothing on disk
is touched and no per-query process is started.
"""
import functools, bisect, collections, ctypes, json, os, re, sqlite3, subprocess, threading, time
import numpy as np

# file kinds by extension: `//mime <kind>` (any extension name also works, e.g. //mime pdf)
KINDS = {
    "image": "jpg jpeg png gif webp bmp tif tiff heic heif svg raw cr2 nef dng",
    "pdf": "pdf",
    "text": "txt md org rst log csv tsv json yaml yml toml ini conf xml html htm",
    "code": ("py rs c h cc cpp hpp js ts jsx tsx go java kt lua sh zsh bash fish el lisp clj "
             "qml rb php swift css scss less nix cmake mk make sql r m pl ps1 vim"),
    "document": "doc docx odt rtf xls xlsx ods ppt pptx odp pages numbers",
    "audio": "mp3 flac wav ogg oga m4a opus aac wma",
    "video": "mp4 mkv avi mov webm wmv m4v",
    "archive": "zip tar gz tgz xz 7z rar bz2 zst",
    "ebook": "epub mobi azw3 djvu",
}
EXT_KIND = {}
for kind, exts in KINDS.items():
    for e in exts.split():
        EXT_KIND.setdefault(e, kind)

def kind_of(path):
    """Kind of a path from its extension ('' when unknown)."""
    name = path.rsplit("/", 1)[-1]
    if "." not in name:
        return ""
    return name.rsplit(".", 1)[-1].lower()

SEARCH_CFG = os.path.expanduser("~/.config/indexes/search-app.json")
UNKNOWN_MTIME = 315532800  # 1980-01-01 00:00 UTC: the placeholder some Drive files carry

def _search_cfg():
    try:
        with open(SEARCH_CFG, encoding="utf-8") as f:
            return json.load(f)
    except (OSError, ValueError):
        return {}

def off_default_entries():
    """[(mount folder with trailing slash, keyword)] for folders that are hidden unless opted in."""
    return [(os.path.expanduser(e["folder"]).rstrip("/") + "/", e["keyword"])
            for e in _search_cfg().get("off_by_default", []) if e.get("folder") and e.get("keyword")]

def hidden_folders(query):
    """Off-by-default folders this query does not opt into with //path <keyword>."""
    out = []
    for folder, keyword in off_default_entries():
        # a negated "!//path keyword" excludes that folder, so it never opts it in
        if not re.search(r"(?<!!)//path\s+" + re.escape(keyword) + r"(?=\s|$)", query, re.I):
            out.append(folder)
    return out

_NATIVE = None

def _native():
    """libscan.so (scan.c): substring scans over the name blob in C. Built on first use; None if unavailable."""
    global _NATIVE
    if _NATIVE is None:
        here = os.path.dirname(os.path.abspath(__file__))
        so, src = os.path.join(here, "libscan.so"), os.path.join(here, "scan.c")
        try:
            if not os.path.exists(so) or os.path.getmtime(src) > os.path.getmtime(so):
                subprocess.run(["gcc", "-O3", "-shared", "-fPIC", "-pthread", "-o", so, src], check=True, capture_output=True)
            lib = ctypes.CDLL(so)
            P, I = ctypes.c_void_p, ctypes.c_int64
            lib.mark_lines.argtypes = [P, I, P, I, P, I, P]
            lib.filter_lines.argtypes = [P, I, P, I, P, I, P, I, P]
            _NATIVE = lib
        except Exception:
            _NATIVE = False
    return _NATIVE or None

def expand_path_value(value):
    """What a //path value means on disk, lowercased: gdrive/x -> the gdrive mount, ~/x -> home."""
    v = value.replace('"', "").strip()
    if v.startswith("gdrive/"):
        v = os.path.expanduser("~/gdrive-rclone-crypt/") + v[len("gdrive/"):]
    elif v.startswith("~/"):
        v = os.path.expanduser(v)
    return v.lower()

def path_matches(path, value):
    """Substring match: //path gdrive/office matches every path that contains that text."""
    return expand_path_value(value) in path.lower()

def wants(ext, w):
    """One //mime or //ext entry against a file's extension: ".pdf" (from //ext) is that extension exactly;
    anything else is a kind name or an extension."""
    if w.startswith("."):
        return w[1:] == ext
    return w == ext or EXT_KIND.get(ext) == w

def matches_mime(path, wanted):
    """wanted: list of kind names, extensions or ".ext" entries; a file matches if any applies."""
    ext = kind_of(path)
    return any(wants(ext, w) for w in wanted)

def tokens(query):
    """Whitespace-separated tokens; text inside double quotes (even mid-token, as in name:"a b") stays one token.
    Quotes are kept in the token; an unterminated quote runs to the end."""
    out, cur, inq = [], [], False
    for ch in query:
        if ch == '"':
            inq = not inq
            cur.append(ch)
        elif ch.isspace() and not inq:
            if cur:
                out.append("".join(cur)); cur = []
        else:
            cur.append(ch)
    if cur:
        out.append("".join(cur))
    return out

def unquote(tok):
    return tok.replace('"', "")

def _take_tags(query, names):
    """Pull '//tag value' pairs (value may be "quoted text") out of a query -> ({tag: [values]}, rest tokens joined).
    A leading "!" (on the tag, or on its value) negates the pair (query-dsl.md "Negation"): it lands under
    the key "!tag", so every existing positive consumer of found[tag] is untouched."""
    found = {n: [] for n in names}
    found.update({"!" + n: [] for n in names})
    rest, toks, i = [], tokens(query), 0
    while i < len(toks):
        m = re.fullmatch(r"(!?)//(%s)" % "|".join(names), toks[i], re.I)
        if m and not (i + 1 < len(toks) and not re.match(r"!?//[a-z]", toks[i + 1], re.I)):
            i += 1              # a tag with no value yet (still being typed) filters nothing
        elif m:
            val, neg = toks[i + 1], bool(m.group(1))
            if val.startswith("!") and len(val) > 1:
                val, neg = val[1:], True
            found[("!" if neg else "") + m.group(2).lower()].append(unquote(val))
            i += 2
        else:
            rest.append(toks[i]); i += 1
    return found, " ".join(rest)

def _kinds(found, neg=""):
    """//mime values as they are, //ext (alias //extension) values as ".ext" (a leading dot is optional)."""
    exts = found[neg + "ext"] + found[neg + "extension"]
    return [m.lower() for m in found[neg + "mime"]] + ["." + e.lower().lstrip(".") for e in exts if e.lstrip(".")]

def split_mime(query):
    """'//mime image //ext .csv foo "bar baz"' -> (['image', '.csv'], 'foo "bar baz"')."""
    found, rest = _take_tags(query, ["mime", "ext", "extension"])
    return _kinds(found), rest

def split_mime_all(query):
    """'//mime image !//ext pdf foo' -> (['image'], ['.pdf'], 'foo'): wanted kinds, excluded kinds, the rest."""
    found, rest = _take_tags(query, ["mime", "ext", "extension"])
    return _kinds(found), _kinds(found, "!"), rest

def split_neg_terms(rest):
    """Free-text terms split by a leading "!" (outside quotes) -> (positive, negated), lowercased and unquoted.
    A quoted "!x" is literal text, since the quote comes first."""
    pos, neg = [], []
    for t in tokens(rest):
        if t.startswith("!") and len(t) > 1:
            if unquote(t[1:]):
                neg.append(unquote(t[1:]).lower())
        elif unquote(t):
            pos.append(unquote(t).lower())
    return pos, neg

def split_tags(query):
    """'//name x //path "y z" //size >5M //dm >2015-06 rest' -> ({'name':[x],...}, 'rest'); quotes are kept in rest."""
    return _take_tags(query, ["name", "path", "size", "dm"])

def _size_ok(sz, cond):
    m = re.match(r"^([<>])\s*([0-9.]+)\s*([KMGT]?)B?$", cond.strip(), re.I)
    if not m or sz is None:
        return False
    mult = {"": 1, "K": 1024, "M": 1024**2, "G": 1024**3, "T": 1024**4}[m.group(3).upper()]
    v = float(m.group(2)) * mult
    return sz > v if m.group(1) == ">" else sz < v

def _date_ok(mtime, cond):
    """cond: '2015-06' (substring) or '>2015-06' / '<2015-06' (ISO prefix comparison)."""
    if mtime is None:
        return False
    iso = time.strftime("%Y-%m-%dT%H:%M:%S", time.localtime(mtime))
    if cond[:1] in "<>":
        bound = cond[1:]
        return iso[:len(bound)] > bound if cond[0] == ">" else iso[:len(bound)] < bound
    return cond in iso

def tag_ok(i, paths, sizes, mtimes, wanted, tags):
    p = paths[i]
    base = p.rsplit("/", 1)[-1].lower()
    if wanted and not matches_mime(p, wanted):
        return False
    if any(t.lower() not in base for t in tags["name"]):
        return False
    if any(t.lower() not in p.lower() for t in tags["path"]):
        return False
    if any(t.lower() in base for t in tags.get("!name", [])):
        return False
    if any(path_matches(p, t) for t in tags.get("!path", [])):
        return False
    if any(_size_ok(sizes[i], c) for c in tags.get("!size", [])):
        return False
    if any(_date_ok(mtimes[i], c) for c in tags.get("!dm", [])):
        return False
    if any(not _size_ok(sizes[i], c) for c in tags["size"]):
        return False
    if any(not _date_ok(mtimes[i], c) for c in tags["dm"]):
        return False
    return True

def _extras(paths, sizes, mtimes):
    ext_map, codes = {}, np.empty(len(paths), np.int32)
    for i, p in enumerate(paths):
        codes[i] = ext_map.setdefault(kind_of(p), len(ext_map))
    ext_names = list(ext_map)
    size_arr = np.array([s if s is not None else -1 for s in sizes], np.int64)
    mt_arr = np.array([m if m is not None else 0 for m in mtimes], np.int64)
    names = np.empty(len(paths), object)
    names[:] = [p.rsplit("/", 1)[-1].lower() for p in paths]
    # files with no real modified date (the 1980-01-01 placeholder, or missing) sort last in both directions
    unknown = (mt_arr < 172800) | np.isin(mt_arr, [UNKNOWN_MTIME, 123456789])  # epoch and tool placeholder dates
    known = np.flatnonzero(~unknown)
    unk = np.flatnonzero(unknown)
    date_asc = known[np.argsort(mt_arr[known], kind="stable")]
    orders = {
        "path": np.arange(len(paths), dtype=np.int64),
        "name": np.argsort(names, kind="stable"),
        "size": np.argsort(size_arr, kind="stable"),
        "date": np.concatenate([date_asc, unk]),
        "date_desc": np.concatenate([date_asc[::-1], unk]),
    }
    # integer sort keys per field (equal values share a rank), for multi-key sorts via lexsort
    def rank(a):
        return np.unique(a, return_inverse=True)[1].astype(np.int64).ravel()
    exts = np.empty(len(paths), object)
    exts[:] = [ext_names[c] for c in codes]
    keys = {
        "path": orders["path"],
        "name": rank(names),
        "size": size_arr,
        "date": mt_arr,
        "ext": rank(exts),
        "depth": np.array([p.count("/") for p in paths], np.int64),
    }
    return codes, ext_names, size_arr, mt_arr, orders, keys

SLOW_MS = float(os.environ.get("SEARCH_SLOW_MS", "0"))
NARROW_MAX = 400_000            # filter the previous matches only when there are few; otherwise the parallel scan is faster
STAT_SAMPLE_OVER = 500_000      # matches above this get a sampled (approximate) summary line
STAT_SAMPLE_SIZE = 250_000

def _merge_stats(parts):
    """Combine _stat_parts results into the stats dict the picker shows."""
    fmt = lambda t: time.strftime("%Y-%m-%d", time.localtime(int(t)))
    out = {"size": sum(p[0] for p in parts)}
    if any(p[4] for p in parts):
        out["approx"] = True
    lo = [p[1] for p in parts if p[1] is not None]
    hi = [p[2] for p in parts if p[2] is not None]
    if lo:
        out["dmin"], out["dmax"] = fmt(min(lo)), fmt(max(hi))
    kinds = collections.Counter()
    for p in parts:
        kinds.update(p[3])
    out["kinds"] = [[k, n] for k, n in sorted(kinds.items(), key=lambda kv: -kv[1])[:5]]
    return out

def _size_mask(size_arr, cond):
    m = re.match(r"^([<>])\s*([0-9.]+)\s*([KMGT]?)B?$", cond.strip(), re.I)
    if not m:
        return np.zeros(len(size_arr), bool)
    mult = {"": 1, "K": 1024, "M": 1024**2, "G": 1024**3, "T": 1024**4}[m.group(3).upper()]
    v = float(m.group(2)) * mult
    known = size_arr >= 0
    return known & ((size_arr > v) if m.group(1) == ">" else (size_arr < v))

class NameTable:
    def __init__(self, db_path):
        self.db_path = db_path
        self.paths = []        # original-case paths, index-aligned with blob lines
        self.off_masks = {}    # off-by-default folder -> bool mask over paths
        self.dirs = []         # every distinct folder, sorted (for //path completion)
        self._tm_cache = collections.OrderedDict()
        self._last = None
        self.blob = b""
        self.starts = np.zeros(0, np.int64)
        self.sizes = []
        self.mtimes = []
        self.loaded_mtime = 0.0
        self.lock = threading.Lock()
        self.dates = []
        # live overlay on top of the loaded snapshot: base rows that were deleted or replaced (dead), the
        # current rows for changed/new paths (d_entries, shown through a small table built on demand)
        self.dead = np.zeros(0, bool)
        self.d_entries = {}
        self._delta = None
        self._ver = 0
        self._loading = False
        self._buffer = []
        self.needs_reload = False

    def load(self):
        t0 = time.time()
        with self.lock:
            self._loading, self._buffer = True, []      # live changes that arrive while loading are replayed afterwards
        try:
            stamp = self._stale_marker()
            rows, dates = self._fetch()
            paths, sizes, mtimes, prev = [], [], [], None
            for p, s, m in rows:            # the same path can come from several sources
                if p == prev:
                    continue
                prev = p
                paths.append(p); sizes.append(s); mtimes.append(m)
            del rows
            self._set(paths, sizes, mtimes, dates, stamp)
        finally:
            with self.lock:
                self._loading = False
        print(f"name table: {len(paths)} paths, {len(self.blob)/1e6:.0f} MB blob, {time.time()-t0:.1f}s", flush=True)

    def _fetch(self):
        """(rows of path, size, mtime ordered by path then newest first, months with files) from the database."""
        con = sqlite3.connect(f"file:{self.db_path}?mode=ro", uri=True)
        rows = con.execute("SELECT path, size, mtime FROM entries ORDER BY path, mtime DESC").fetchall()
        dates = [r[0] for r in con.execute(
            "SELECT DISTINCT strftime('%Y-%m', mtime, 'unixepoch', 'localtime') d FROM entries "
            "WHERE mtime IS NOT NULL ORDER BY d DESC")]
        con.close()
        return rows, dates

    def _set(self, paths, sizes, mtimes, dates, stamp=0.0, install_lock=True):
        """Build every lookup structure for (paths sorted ascending) and swap them in."""
        lower = [p.lower() for p in paths]
        blob = "\n".join(lower).encode("utf-8", "surrogatepass")
        lens = np.fromiter((len(x.encode("utf-8", "surrogatepass")) + 1 for x in lower), np.int64, len(lower))
        starts = np.concatenate(([0], np.cumsum(lens)[:-1])) if len(lower) else np.zeros(0, np.int64)
        # newest-first order, computed once so an empty query is instant
        mt = np.array([m if m is not None else 0 for m in mtimes], dtype=np.int64)
        order = np.argsort(-mt) if len(mt) else np.zeros(0, np.int64)
        ext_codes, ext_names, size_arr, mt_arr, orders, keys = _extras(paths, sizes, mtimes)
        dirs = sorted({p.rsplit("/", 1)[0] for p in paths if "/" in p})
        with self.lock:
            self.paths, self.sizes, self.mtimes = paths, sizes, mtimes
            self.blob, self.starts = blob, starts
            self.arr = np.frombuffer(blob, np.uint8)
            self.order = order
            self.ext_codes, self.ext_names = ext_codes, ext_names
            self.size_arr, self.mt_arr, self.orders = size_arr, mt_arr, orders
            self.off_masks = {f: np.fromiter((p.startswith(f) for p in paths), bool, len(paths))
                              for f, _ in off_default_entries()}
            self.dirs = dirs
            self._tm_cache = collections.OrderedDict()
            self._last = None
            self.sort_keys = keys
            self._cache = None
            self.dates = [d for d in dates if d]
            self.loaded_mtime = stamp
            # a fresh snapshot already contains what the live overlay held, except what arrived while it loaded
            self.dead = np.zeros(len(paths), bool)
            self.d_entries, self._delta, self.needs_reload = {}, None, False
            self._ver += 1
            for op in self._buffer:
                self._apply(op)
            self._buffer = []

    def top_exts(self, n=60):
        """The commonest extensions, for //ext completion."""
        with self.lock:
            codes, names = self.ext_codes, self.ext_names
        counts = np.bincount(codes, minlength=len(names)) if len(codes) else np.zeros(0, int)
        return [names[k] for k in np.argsort(-counts)[:n] if names[k] and counts[k] > 0]

    def _db_mtime(self):
        """Newest change to the database, counting the WAL file (commits land there before a checkpoint)."""
        return max(os.path.getmtime(f) for f in (self.db_path, self.db_path + "-wal") if os.path.exists(f))

    def _stale_marker(self):
        """What decides a reload: the generation file that full builds touch when they finish (live changes
        reach the server through apply_ops and also land in the database, so they must not trigger one);
        without that file, the database's own modification time as before."""
        gen = self.db_path + ".gen"
        try:
            return os.path.getmtime(gen) if os.path.exists(gen) else self._db_mtime()
        except OSError:
            return 0.0

    def refresh_if_stale(self):
        try:
            if os.path.exists(self.db_path + ".building"):
                return
            if self.needs_reload or self._stale_marker() > self.loaded_mtime:
                self.load()
        except OSError:
            pass

    # ---- live overlay -------------------------------------------------------------------------------
    def apply_ops(self, ops):
        """ops: ["put", path, size, mtime] | ["del", path] | ["delprefix", path] (a folder and everything below it)."""
        with self.lock:
            if self._loading:
                self._buffer.extend(ops)
            for op in ops:
                self._apply(op)

    def _apply(self, op):
        """Caller holds the lock."""
        paths, kind, p = self.paths, op[0], op[1]
        i = bisect.bisect_left(paths, p)
        here = i < len(paths) and paths[i] == p
        if kind == "put":
            size, mtime = op[2], op[3]
            if here and self.sizes[i] == size and self.mtimes[i] == mtime:
                self.dead[i] = False
                self.d_entries.pop(p, None)
            else:
                if here:
                    self.dead[i] = True
                else:
                    parent = p.rsplit("/", 1)[0]
                    j = bisect.bisect_left(self.dirs, parent)
                    if parent and (j >= len(self.dirs) or self.dirs[j] != parent):
                        self.dirs.insert(j, parent)
                self.d_entries[p] = (size, mtime)
        elif kind == "del":
            if here:
                self.dead[i] = True
            self.d_entries.pop(p, None)
        elif kind == "delprefix":
            lo, hi = bisect.bisect_left(paths, p + "/"), bisect.bisect_left(paths, p + "0")
            self.dead[lo:hi] = True
            if here:
                self.dead[i] = True
            below = p + "/"
            for k in [k for k in self.d_entries if k == p or k.startswith(below)]:
                del self.d_entries[k]
        self._delta = None
        self._cache = None
        self._last = None
        self._ver += 1
        if len(self.d_entries) > 150000:
            self.needs_reload = True

    def _delta_table(self):
        """A small NameTable over the live overlay rows (None when there are none)."""
        with self.lock:
            if not self.d_entries:
                return None
            if self._delta is not None:
                return self._delta
            items = sorted(self.d_entries.items())
            ver = self._ver
        t = NameTable(None)
        t._set([k for k, _ in items], [v[1][0] for v in items], [v[1][1] for v in items], [])
        with self.lock:
            if self._ver == ver:
                self._delta = t
        return t

    def _sort_key(self, path, size, mtime, sorts, desc):
        """[(value, direction)] reproducing the order _match gives, so rows of two tables can be merged."""
        sign = -1 if desc else 1
        def val(k):
            if k == "path": return path
            if k == "name": return path.rsplit("/", 1)[-1].lower()
            if k == "size": return size if size is not None else -1
            if k == "date": return mtime or 0
            if k == "ext": return kind_of(path)
            return path.count("/")
        if len(sorts) == 1 and sorts[0] in ("path", "name", "size", "date"):
            if sorts[0] == "date":
                mt = mtime or 0
                if mt < 172800 or mt in (UNKNOWN_MTIME, 123456789):
                    return [(1, 1), (0, 1), (path, 1)]       # unknown dates sort last in both directions
                return [(0, 1), (mt, sign), (path, sign)]
            return [(val(sorts[0]), sign), (path, sign)]
        return [(val(k), sign) for k in sorts] + [(path, 1)]

    def query(self, q, sort="date", desc=True, offset=0, limit=200, extras=(), cancel=None):
        """(rows, total, stats) for one window of the matches; the full match list is cached per query.
        `extras`: further, separately loaded tables (the restic and btrfs backups) whose matches are merged in."""
        extras = [t for t in extras if t is not None and len(t.paths) > 0]
        t_start = time.perf_counter()
        key = (q, sort, bool(desc), tuple((id(t), t._ver) for t in extras))
        with self.lock:
            cached, ver = self._cache, self._ver
        if cached is None or cached[0] != key:
            base = self._match(q, sort, desc)
            t_match = time.perf_counter()
            if cancel is not None and cancel():          # a newer query was typed meanwhile: do not spend the rest
                return [], 0, {}
            delta = self._delta_table()
            d_idx = delta._match(q, sort, desc) if delta is not None else np.zeros(0, np.int64)
            e_idx = [t._match(q, sort, desc) for t in extras]
            parts = [self._stat_parts(base)] + ([delta._stat_parts(d_idx)] if delta is not None else []) \
                + [t._stat_parts(ix) for t, ix in zip(extras, e_idx)]
            stats = _merge_stats(parts)
            t_stats = time.perf_counter()
            with self.lock:
                if self._ver == ver:
                    self._cache = (key, base, d_idx, delta, stats, e_idx)
            if SLOW_MS and (t_stats - t_start) * 1000 > SLOW_MS:
                print(f"slow query {q!r}: match {1000*(t_match-t_start):.0f} ms (incl. waiting for the GIL/locks), "
                      f"overlay+extras+stats {1000*(t_stats-t_match):.0f} ms, {len(base):,} base matches", flush=True)
        else:
            base, d_idx, delta, stats, e_idx = cached[1], cached[2], cached[3], cached[4], cached[5]
        total = len(base) + len(d_idx) + sum(len(ix) for ix in e_idx)
        if not len(d_idx) and not any(len(ix) for ix in e_idx):
            window = base[offset: offset + limit].tolist()
            return [{"remote": self.paths[i], "size": self.sizes[i], "mtime": self.mtimes[i]} for i in window], total, stats
        # merge the sorted lists: the window of the union lies within the first offset+limit of each
        sorts = [k for k in sort.split(",") if k in self.sort_keys] or ["date"]
        k = offset + limit
        rows = [(self.paths[i], self.sizes[i], self.mtimes[i]) for i in base[:k].tolist()]
        if len(d_idx):
            rows += [(delta.paths[i], delta.sizes[i], delta.mtimes[i]) for i in d_idx[:k].tolist()]
        for t, ix in zip(extras, e_idx):
            rows += [(t.paths[i], t.sizes[i], t.mtimes[i]) for i in ix[:k].tolist()]
        keyed = [(self._sort_key(p, s_, m, sorts, bool(desc)), (p, s_, m)) for p, s_, m in rows]
        def cmp(a, b):
            for (va, da), (vb, db_) in zip(a[0], b[0]):
                if va != vb:
                    return da if va > vb else -da
            return 0
        keyed.sort(key=functools.cmp_to_key(cmp))
        window = keyed[offset: offset + limit]
        return [{"remote": r[0], "size": r[1], "mtime": r[2]} for _, r in window], total, stats

    def _stat_parts(self, idx):
        """Totals over the matches idx: (size sum, oldest, newest, count per file type, approximate?). Past
        STAT_SAMPLE_OVER matches the totals come from an evenly spaced sample and are scaled up (flagged
        approximate), so a one-letter query over millions of files does not wait for a full pass."""
        step = 1
        if len(idx) > STAT_SAMPLE_OVER:
            step = max(2, len(idx) // STAT_SAMPLE_SIZE)
            idx = idx[::step]
        with self.lock:
            sizes, mts, codes, names = self.size_arr[idx], self.mt_arr[idx], self.ext_codes[idx], self.ext_names
        known = sizes >= 0
        dated = mts > 0
        counts = np.bincount(codes, minlength=len(names)) if len(codes) else np.zeros(0, int)
        by_kind = {names[k] or "no ext": int(c) * step for k, c in enumerate(counts) if c > 0}
        return ((int(sizes[known].sum()) if known.any() else 0) * step,
                int(mts[dated].min()) if dated.any() else None,
                int(mts[dated].max()) if dated.any() else None,
                by_kind, step > 1)

    def _match(self, q, sort, desc):
        wanted, not_wanted, rest = split_mime_all(q)
        tags, rest = split_tags(rest)
        terms, neg_terms = split_neg_terms(rest)
        with self.lock:
            N = len(self.paths)
            sorts = [k for k in sort.split(",") if k in self.sort_keys] or ["date"]
            order = self.orders.get(sorts[0]) if len(sorts) == 1 else None
            if order is not None and desc and sorts[0] == "date":
                order = self.orders["date_desc"]
            sort_keys = self.sort_keys
            ext_codes, ext_names, size_arr = self.ext_codes, self.ext_names, self.size_arr
            dead = self.dead if len(self.dead) == N and self.dead.any() else None
        rest_key = (tuple(sorts), desc, tuple(wanted), tuple(tags["size"]), tuple(tags["path"]),
                    tuple(tags["name"]), tuple(tags["dm"]), tuple(hidden_folders(q)),
                    tuple(not_wanted), tuple(neg_terms), tuple(tags["!name"]), tuple(tags["!path"]),
                    tuple(tags["!size"]), tuple(tags["!dm"]))
        with self.lock:
            last = self._last
        # Typing usually extends the previous query: only the new word is checked, over the previous matches
        if last is not None and last[0] == rest_key and terms:
            old = last[1]
            if terms == old:
                return last[2]
            narrow = (len(terms) == len(old) + 1 and terms[:len(old)] == old) or \
                     (len(terms) == len(old) and terms[:-1] == old[:-1] and bool(old) and terms[-1].startswith(old[-1]))
            if narrow and len(last[2]) <= NARROW_MAX:
                keep = self._filter_candidates(last[2], terms[-1].encode("utf-8"))
                idx = last[2][keep]
                if dead is not None:
                    idx = idx[~dead[idx]]
                if tags["name"] or tags["dm"] or tags["!name"] or tags["!dm"]:
                    rest_tags = {"name": tags["name"], "path": [], "size": [], "dm": tags["dm"],
                                 "!name": tags["!name"], "!dm": tags["!dm"]}
                    idx = np.array([i for i in idx.tolist()
                                    if tag_ok(i, self.paths, self.sizes, self.mtimes, [], rest_tags)], np.int64)
                with self.lock:
                    self._last = (rest_key, terms, idx)
                return idx
        mask = np.ones(N, bool) if dead is None else ~dead
        for f in hidden_folders(q):
            if f in self.off_masks:
                mask &= ~self.off_masks[f]
        for t in terms:
            mask &= self._cached_term_mask(t.encode("utf-8"))
        for t in neg_terms:
            mask &= ~self._cached_term_mask(t.encode("utf-8"))
        for v in tags["path"]:
            mask &= self._cached_term_mask(expand_path_value(v).encode("utf-8"))
        for v in tags["!path"]:
            mask &= ~self._cached_term_mask(expand_path_value(v).encode("utf-8"))
        if not_wanted:
            banned = [k for k, e in enumerate(ext_names) if any(wants(e, w) for w in not_wanted)]
            mask &= ~np.isin(ext_codes, np.array(banned, np.int32))
        for c in tags["!size"]:
            mask &= ~_size_mask(size_arr, c)
        if wanted:
            allowed = [k for k, e in enumerate(ext_names) if any(wants(e, w) for w in wanted)]
            mask &= np.isin(ext_codes, np.array(allowed, np.int32))
        for c in tags["size"]:
            mask &= _size_mask(size_arr, c)
        if order is not None:
            if desc and sorts[0] != "date":
                order = order[::-1]
            idx = order[mask[order]]
        else:
            # several keys: the first is primary, later ones break ties, path order is the last resort
            idx = np.flatnonzero(mask)
            sign = -1 if desc else 1
            cols = [sort_keys["path"][idx]] + [sign * sort_keys[k][idx] for k in reversed(sorts)]
            idx = idx[np.lexsort(cols)]
        if tags["name"] or tags["path"] or tags["dm"] or tags["!name"] or tags["!dm"]:
            rest_tags = {"name": tags["name"], "path": [], "size": [], "dm": tags["dm"],
                         "!name": tags["!name"], "!dm": tags["!dm"]}
            idx = np.array([i for i in idx.tolist()
                            if tag_ok(i, self.paths, self.sizes, self.mtimes, [], rest_tags)], np.int64)
        with self.lock:
            self._last = (rest_key, terms, idx)
        return idx

    def _cached_term_mask(self, term):
        """Masks for recent terms are kept, so extending a query only scans the new word."""
        with self.lock:
            hit = self._tm_cache.get(term)
            if hit is not None:
                self._tm_cache.move_to_end(term)
                return hit
        m = self._term_mask(term)
        with self.lock:
            self._tm_cache[term] = m
            while len(self._tm_cache) > 64:
                self._tm_cache.popitem(last=False)
        return m

    def _filter_candidates(self, cand, term):
        """Which candidate lines (indices into paths) contain term."""
        lib = _native()
        if lib is not None and len(term):
            keep = np.zeros(len(cand), np.uint8)
            t = np.frombuffer(term, np.uint8)
            cand = np.ascontiguousarray(cand, np.int64)
            lib.filter_lines(self.arr.ctypes.data, len(self.arr), self.starts.ctypes.data, len(self.starts),
                             cand.ctypes.data, len(cand), t.ctypes.data, len(term), keep.ctypes.data)
            return keep.astype(bool)
        return np.array([term in self.blob[int(self.starts[i]):int(self.starts[i + 1]) if i + 1 < len(self.starts) else len(self.blob)]
                         for i in cand], bool)

    def _term_mask(self, term):
        """Lines containing the bytes of term (terms hold no newline, so a match stays on one line)."""
        a = self.arr
        n, m = len(a), len(term)
        mask = np.zeros(len(self.paths), bool)
        if m == 0 or m > n:
            return mask | (m == 0)
        lib = _native()
        if lib is not None:
            out = np.zeros(len(self.paths), np.uint8)
            t = np.frombuffer(term, np.uint8)
            lib.mark_lines(a.ctypes.data, n, self.starts.ctypes.data, len(self.paths), t.ctypes.data, m, out.ctypes.data)
            return out.view(bool)
        cand = np.flatnonzero(a[: n - m + 1] == term[0])
        for k in range(1, m):
            cand = cand[a[cand + k] == term[k]]
        if cand.size:
            mask[np.searchsorted(self.starts, cand, side="right") - 1] = True
        return mask

class ResticTable(NameTable):
    """The restic backups as a table of their own (catalog-restic.db), loaded only when a query asks for them."""
    def _fetch(self):
        import restic_store
        return restic_store.server_rows(self.db_path)

class BtrfsTable(NameTable):
    """The btrfs (snapper) snapshots as a table of their own (catalog-btrfs.db), loaded only on demand."""
    def _fetch(self):
        import btrfs_store
        return btrfs_store.server_rows(self.db_path)

def start_refresh(table, every=60):
    def loop():
        while True:
            time.sleep(every)
            table.refresh_if_stale()
    threading.Thread(target=loop, daemon=True).start()

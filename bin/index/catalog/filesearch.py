"""In-memory file-name index (the 'Everything' part of the search server).

All distinct paths from the catalog are kept as one lowercase blob separated by
newlines, plus an offsets array. A query finds the rarest-looking term in the
blob with bytes.find, maps hits back to lines with searchsorted, then checks the
other terms per candidate. Each keystroke is one scan over RAM; nothing on disk
is touched and no per-query process is started.
"""
import bisect, os, re, sqlite3, threading, time
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

def matches_mime(path, wanted):
    """wanted: list of kind names or extensions; a file matches if any applies."""
    ext = kind_of(path)
    for w in wanted:
        if w == ext or EXT_KIND.get(ext) == w:
            return True
    return False

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
    """Pull '//tag value' pairs (value may be "quoted text") out of a query -> ({tag: [values]}, rest tokens joined)."""
    found = {n: [] for n in names}
    rest, toks, i = [], tokens(query), 0
    while i < len(toks):
        m = re.fullmatch(r"//(%s)" % "|".join(names), toks[i], re.I)
        if m and i + 1 < len(toks):
            found[m.group(1).lower()].append(unquote(toks[i + 1]))
            i += 2
        else:
            rest.append(toks[i]); i += 1
    return found, " ".join(rest)

def split_mime(query):
    """'//mime image foo "bar baz"' -> (['image'], 'foo "bar baz"')."""
    found, rest = _take_tags(query, ["mime"])
    return [m.lower() for m in found["mime"]], rest

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
    orders = {
        "path": np.arange(len(paths), dtype=np.int64),
        "name": np.argsort(names, kind="stable"),
        "size": np.argsort(size_arr, kind="stable"),
        "date": np.argsort(mt_arr, kind="stable"),
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
        self.blob = b""
        self.starts = np.zeros(0, np.int64)
        self.sizes = []
        self.mtimes = []
        self.loaded_mtime = 0.0
        self.lock = threading.Lock()
        self.dates = []

    def load(self):
        t0 = time.time()
        con = sqlite3.connect(f"file:{self.db_path}?mode=ro", uri=True)
        rows = con.execute("SELECT path, size, mtime FROM entries ORDER BY path").fetchall()
        dates = [r[0] for r in con.execute(
            "SELECT DISTINCT strftime('%Y-%m', mtime, 'unixepoch', 'localtime') d FROM entries "
            "WHERE mtime IS NOT NULL ORDER BY d DESC")]
        con.close()
        paths, sizes, mtimes, prev = [], [], [], None
        for p, s, m in rows:            # the same path can come from several sources
            if p == prev:
                continue
            prev = p
            paths.append(p); sizes.append(s); mtimes.append(m)
        lower = [p.lower() for p in paths]
        blob = "\n".join(lower).encode("utf-8", "surrogatepass")
        lens = np.fromiter((len(x.encode("utf-8", "surrogatepass")) + 1 for x in lower), np.int64, len(lower))
        starts = np.concatenate(([0], np.cumsum(lens)[:-1]))
        # newest-first order, computed once so an empty query is instant
        mt = np.array([m if m is not None else 0 for m in mtimes], dtype=np.int64)
        order = np.argsort(-mt) if len(mt) else np.zeros(0, np.int64)
        ext_codes, ext_names, size_arr, mt_arr, orders, keys = _extras(paths, sizes, mtimes)
        with self.lock:
            self.paths, self.sizes, self.mtimes = paths, sizes, mtimes
            self.blob, self.starts = blob, starts
            self.arr = np.frombuffer(blob, np.uint8)
            self.order = order
            self.ext_codes, self.ext_names = ext_codes, ext_names
            self.size_arr, self.mt_arr, self.orders = size_arr, mt_arr, orders
            self.sort_keys = keys
            self._cache = None
            self.dates = [d for d in dates if d]
            self.loaded_mtime = os.path.getmtime(self.db_path)
        print(f"name table: {len(paths)} paths, {len(blob)/1e6:.0f} MB blob, {time.time()-t0:.1f}s", flush=True)

    def refresh_if_stale(self):
        try:
            if os.path.getmtime(self.db_path) > self.loaded_mtime:
                self.load()
        except OSError:
            pass

    def query(self, q, sort="date", desc=True, offset=0, limit=200):
        """(rows, total) for one window of the matches; the full match list is cached per query."""
        key = (q, sort, bool(desc))
        with self.lock:
            cached = self._cache
        if cached is None or cached[0] != key:
            idx = self._match(q, sort, desc)
            stats = self._stats(idx)
            with self.lock:
                self._cache = (key, idx, stats)
        else:
            idx, stats = cached[1], cached[2]
        window = idx[offset: offset + limit].tolist()
        rows = [{"remote": self.paths[i], "size": self.sizes[i], "mtime": self.mtimes[i]} for i in window]
        return rows, len(idx), stats

    def _stats(self, idx):
        """Totals over every match: size, date-modified range and the commonest file types."""
        with self.lock:
            sizes, mts, codes, names = self.size_arr[idx], self.mt_arr[idx], self.ext_codes[idx], self.ext_names
        known = sizes >= 0
        dated = mts > 0
        fmt = lambda t: time.strftime("%Y-%m-%d", time.localtime(int(t)))
        out = {"size": int(sizes[known].sum()) if known.any() else 0}
        if dated.any():
            out["dmin"], out["dmax"] = fmt(mts[dated].min()), fmt(mts[dated].max())
        counts = np.bincount(codes, minlength=len(names)) if len(codes) else np.zeros(0, int)
        top = np.argsort(-counts)[:5]
        out["kinds"] = [[names[k] or "no ext", int(counts[k])] for k in top if counts[k] > 0]
        return out

    def _match(self, q, sort, desc):
        wanted, rest = split_mime(q)
        tags, rest = split_tags(rest)
        terms = [unquote(t).lower() for t in tokens(rest) if unquote(t)]
        with self.lock:
            N = len(self.paths)
            sorts = [k for k in sort.split(",") if k in self.sort_keys] or ["date"]
            order = self.orders.get(sorts[0]) if len(sorts) == 1 else None
            sort_keys = self.sort_keys
            ext_codes, ext_names, size_arr = self.ext_codes, self.ext_names, self.size_arr
        mask = np.ones(N, bool)
        for t in terms:
            mask &= self._term_mask(t.encode("utf-8"))
        if wanted:
            allowed = [k for k, e in enumerate(ext_names) if any(w == e or EXT_KIND.get(e) == w for w in wanted)]
            mask &= np.isin(ext_codes, np.array(allowed, np.int32))
        for c in tags["size"]:
            mask &= _size_mask(size_arr, c)
        if order is not None:
            if desc:
                order = order[::-1]
            idx = order[mask[order]]
        else:
            # several keys: the first is primary, later ones break ties, path order is the last resort
            idx = np.flatnonzero(mask)
            sign = -1 if desc else 1
            cols = [sort_keys["path"][idx]] + [sign * sort_keys[k][idx] for k in reversed(sorts)]
            idx = idx[np.lexsort(cols)]
        if tags["name"] or tags["path"] or tags["dm"]:
            rest_tags = {"name": tags["name"], "path": tags["path"], "size": [], "dm": tags["dm"]}
            idx = np.array([i for i in idx.tolist()
                            if tag_ok(i, self.paths, self.sizes, self.mtimes, [], rest_tags)], np.int64)
        return idx

    def _term_mask(self, term):
        """Lines containing the bytes of term (terms hold no newline, so a match stays on one line)."""
        a = self.arr
        n, m = len(a), len(term)
        mask = np.zeros(len(self.paths), bool)
        if m == 0 or m > n:
            return mask | (m == 0)
        cand = np.flatnonzero(a[: n - m + 1] == term[0])
        for k in range(1, m):
            cand = cand[a[cand + k] == term[k]]
        if cand.size:
            mask[np.searchsorted(self.starts, cand, side="right") - 1] = True
        return mask

def start_refresh(table, every=60):
    def loop():
        while True:
            time.sleep(every)
            table.refresh_if_stale()
    threading.Thread(target=loop, daemon=True).start()

"""In-memory file-name index (the 'Everything' part of the search server).

All distinct paths from the catalog are kept as one lowercase blob separated by
newlines, plus an offsets array. A query finds the rarest-looking term in the
blob with bytes.find, maps hits back to lines with searchsorted, then checks the
other terms per candidate. Each keystroke is one scan over RAM; nothing on disk
is touched and no per-query process is started.
"""
import functools, bisect, collections, ctypes, json, os, re, sqlite3, subprocess, sys, threading, time
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
    "directory": "",    # no extension: folders are the catalog entries without a size (see DIRECTORY)
}
DIRECTORY = "directory"
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

_LIT = "\x00\x00"     # a literal "||" inside a quoted value, until alts() hands it back

def alts(value):
    """`a||b` -> ["a", "b"]: one value standing for several alternatives (query-dsl.md "Alternatives (`||`)").
    Empty parts are dropped; none left -> [""]. A quoted value arrives with its `||` already shielded."""
    return [a.replace(_LIT, "||") for a in value.split("||") if a] or [""]

def name_has(base, value):
    """A //name value against a lowercased file name: any alternative contained."""
    return any(a.lower() in base for a in alts(value))

def expand_path_value(value):
    """What a //path value means on disk, lowercased: gdrive/x -> the gdrive mount, ~/x -> home."""
    v = value.replace('"', "").strip()
    if v.startswith("gdrive/"):
        v = os.path.expanduser("~/gdrive-rclone-crypt/") + v[len("gdrive/"):]
    elif v.startswith("~/"):
        v = os.path.expanduser(v)
    return v.lower()

def path_matches(path, value):
    """Substring match: //path gdrive/office matches every path that contains that text (any alternative of a||b;
    a value still wrapped in quotes is literal)."""
    low = path.lower()
    if value.lstrip().startswith('"'):
        return expand_path_value(value) in low
    return any(expand_path_value(a) in low for a in alts(value))

def wants(ext, w):
    """One //mime or //ext entry against a file's extension: ".pdf" (from //ext) is that extension exactly;
    anything else is a kind name or an extension."""
    if w.startswith("."):
        return w[1:] == ext
    return w == ext or EXT_KIND.get(ext) == w

def matches_mime(path, wanted, is_dir=False):
    """wanted: list of kind names, extensions or ".ext" entries; a file matches if any applies.
    A directory matches only "directory"; its name's dots are not an extension."""
    if is_dir:
        return DIRECTORY in wanted
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

def unquote_value(tok):
    """unquote, but a quoted token keeps its `||` literal (shielded for alts())."""
    u = unquote(tok)
    return u.replace("||", _LIT) if tok.startswith('"') else u

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
            found[("!" if neg else "") + m.group(2).lower()].append(unquote_value(val))
            i += 2
        else:
            rest.append(toks[i]); i += 1
    return found, " ".join(rest)

def _kinds(found, neg=""):
    """//mime values as they are, //ext (alias //extension) values as ".ext" (a leading dot is optional)."""
    exts = [a for e in found[neg + "ext"] + found[neg + "extension"] for a in alts(e)]
    return [a.lower() for m in found[neg + "mime"] for a in alts(m) if a] + ["." + e.lower().lstrip(".") for e in exts if e.lstrip(".")]

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
                neg.append(unquote_value(t[1:]).lower())
        elif unquote(t):
            pos.append(unquote_value(t).lower())
    return pos, neg

def split_tags(query):
    """'//name x //path "y z" //size >5M //dm >2015-06 rest' -> ({'name':[x],...}, 'rest'); quotes are kept in rest."""
    return _take_tags(query, ["name", "path", "size", "dm"])

def _size_ok(sz, cond):
    return any(_size_one(sz, a) for a in alts(cond))

def _size_one(sz, cond):
    m = re.match(r"^([<>])\s*([0-9.]+)\s*([KMGT]?)B?$", cond.strip(), re.I)
    if not m or sz is None:
        return False
    mult = {"": 1, "K": 1024, "M": 1024**2, "G": 1024**3, "T": 1024**4}[m.group(3).upper()]
    v = float(m.group(2)) * mult
    return sz > v if m.group(1) == ">" else sz < v

def _date_ok(mtime, cond):
    return any(_date_one(mtime, a) for a in alts(cond))

def _date_one(mtime, cond):
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
    if wanted and not matches_mime(p, wanted, sizes[i] is None):
        return False
    if any(not name_has(base, t) for t in tags["name"]):
        return False
    if any(not path_matches(p, t) for t in tags["path"]):
        return False
    if any(name_has(base, t) for t in tags.get("!name", [])):
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

TERM_CACHE = int(os.environ.get("TERM_CACHE", "16"))      # recent term masks kept (4.4 MB each at 4.4M paths)
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
    out = np.zeros(len(size_arr), bool)
    for a in alts(cond):
        out |= _size_mask_one(size_arr, a)
    return out

def _size_mask_one(size_arr, cond):
    m = re.match(r"^([<>])\s*([0-9.]+)\s*([KMGT]?)B?$", cond.strip(), re.I)
    if not m:
        return np.zeros(len(size_arr), bool)
    mult = {"": 1, "K": 1024, "M": 1024**2, "G": 1024**3, "T": 1024**4}[m.group(3).upper()]
    v = float(m.group(2)) * mult
    known = size_arr >= 0
    return known & ((size_arr > v) if m.group(1) == ">" else (size_arr < v))

_libc = ctypes.CDLL(None, use_errno=True)
_libc.mlock.argtypes = [ctypes.c_void_p, ctypes.c_size_t]

def pin_in_ram(arrays):
    """mlock the data of numpy arrays so memory pressure can never swap them out (a name search scans all of
    them on every keystroke; paged back in one fault at a time it takes seconds). Returns the bytes locked;
    quietly locks nothing when RLIMIT_MEMLOCK is too low."""
    done = 0
    for a in arrays:
        if isinstance(a, np.ndarray) and a.dtype != object and a.nbytes:
            if _libc.mlock(a.ctypes.data, a.nbytes) == 0:
                done += a.nbytes
    return done

class _Lines:
    """Read-only sequence over the newline-joined lines of a memory-mapped blob; a line is decoded only when
    asked for, so a table of millions of paths holds no Python string objects (the pages stay in the page cache)."""
    def __init__(self, mm, starts):
        self.mm, self.starts, self.n, self.size = mm, starts, len(starts), len(mm)

    def __len__(self):
        return self.n

    def __getitem__(self, i):
        if isinstance(i, slice):
            return [self[k] for k in range(*i.indices(self.n))]
        if i < 0:
            i += self.n
        if not 0 <= i < self.n:
            raise IndexError(i)
        s = int(self.starts[i])
        e = int(self.starts[i + 1]) - 1 if i + 1 < self.n else self.size
        return self.mm[s:e].decode("utf-8", "surrogatepass")

    def __iter__(self):
        self.mm.seek(0)
        for line in iter(self.mm.readline, b""):
            yield line.rstrip(b"\n").decode("utf-8", "surrogatepass")


class _Col:
    """An int64 column, NULL stored as a sentinel, read back as int or None like the lists it replaces."""
    NULL = -(2 ** 63)

    def __init__(self, a):
        self.a = a

    def __len__(self):
        return len(self.a)

    def __getitem__(self, i):
        v = int(self.a[i])
        return None if v == self.NULL else v

    def __iter__(self):
        for v in self.a.tolist():
            yield None if v == self.NULL else v


SNAP_VERSION = 1


def _snap_write(out, rows_iter, dates):
    """Stream (path, size, mtime) rows, already ordered by path, into snapshot files under `out`. Peak memory is the
    set of folders plus the object arrays of _extras, not the whole table as Python lists."""
    import array, mmap
    os.makedirs(out, exist_ok=True)
    fl, fo = open(os.path.join(out, "lower.bin"), "wb"), open(os.path.join(out, "orig.bin"), "wb")
    st_l, st_o, sizes, mts = array.array("q"), array.array("q"), array.array("q"), array.array("q")
    off_l = off_o = 0
    dirs = set()
    prev = None
    for p, sz, mt in rows_iter:
        if p == prev:                  # the same path can come from several sources: the newest row wins
            continue
        prev = p
        p = p.replace("\n", " ")
        o = p.encode("utf-8", "surrogatepass")
        l = p.lower().encode("utf-8", "surrogatepass")
        if st_l:
            fl.write(b"\n"); fo.write(b"\n"); off_l += 1; off_o += 1
        st_l.append(off_l); st_o.append(off_o)
        fl.write(l); fo.write(o); off_l += len(l); off_o += len(o)
        sizes.append(_Col.NULL if sz is None else sz)
        mts.append(_Col.NULL if mt is None else mt)
        if "/" in p:
            dirs.add(p.rsplit("/", 1)[0])
    fl.close(); fo.close()
    n = len(st_l)
    a_stl = np.frombuffer(st_l, np.int64) if n else np.zeros(0, np.int64)
    a_sto = np.frombuffer(st_o, np.int64) if n else np.zeros(0, np.int64)
    raw_sizes = np.frombuffer(sizes, np.int64) if n else np.zeros(0, np.int64)
    raw_mts = np.frombuffer(mts, np.int64) if n else np.zeros(0, np.int64)
    np.save(os.path.join(out, "starts_l.npy"), a_stl)
    np.save(os.path.join(out, "starts_o.npy"), a_sto)
    np.save(os.path.join(out, "sizes_raw.npy"), raw_sizes)
    np.save(os.path.join(out, "mtimes_raw.npy"), raw_mts)
    # the lookup arrays come from the very same function the in-memory table uses, so the two cannot drift apart
    f1 = open(os.path.join(out, "orig.bin"), "rb")
    mm = mmap.mmap(f1.fileno(), 0, access=mmap.ACCESS_READ) if n else None
    paths = _Lines(mm, a_sto) if n else []
    ext_codes, ext_names, size_arr, mt_arr, orders, keys = _extras(paths, _Col(raw_sizes), _Col(raw_mts))
    mt = np.where(raw_mts == _Col.NULL, 0, raw_mts)
    order = np.argsort(-mt) if n else np.zeros(0, np.int64)
    np.save(os.path.join(out, "ext_codes.npy"), ext_codes)
    np.save(os.path.join(out, "size_arr.npy"), size_arr)
    np.save(os.path.join(out, "mt_arr.npy"), mt_arr)
    np.save(os.path.join(out, "order.npy"), order)
    for k, v in orders.items():
        np.save(os.path.join(out, f"orders.{k}.npy"), v)
    for k, v in keys.items():
        np.save(os.path.join(out, f"keys.{k}.npy"), v)
    del paths
    if mm is not None:
        mm.close()
    f1.close()
    with open(os.path.join(out, "dirs.txt"), "w", encoding="utf-8", errors="surrogatepass") as f:
        f.write("\n".join(sorted(dirs)))
    with open(os.path.join(out, "meta.json"), "w") as f:           # written last: its presence marks a complete snapshot
        json.dump({"version": SNAP_VERSION, "n": n, "ext_names": ext_names, "dates": [d for d in dates if d],
                   "orders": sorted(orders), "keys": sorted(keys)}, f)
    return n


class NameTable:
    pin = False     # the live search server sets this: keep the scan data resident
    compact = False  # map a snapshot of the table from disk (page cache) instead of building Python lists
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
        self.last_used = 0.0

    def load(self):
        if self.compact and self.db_path:
            return self._load_compact()
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
        arr = np.frombuffer(blob, np.uint8)
        if self.pin:     # before the swap-in, so queries on the old snapshot go on while the new data is faulted in
            n = pin_in_ram([arr, starts, order, ext_codes, size_arr, mt_arr, *orders.values(), *keys.values()])
            print(f"name table: {n/1e6:.0f} MB pinned in RAM", flush=True)
        with self.lock:
            self.paths, self.sizes, self.mtimes = paths, sizes, mtimes
            self.blob, self.starts = blob, starts
            self.arr = arr
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


    # ---- compact (memory-mapped snapshot) mode ----------------------------------------------------------
    def _snap_rows(self):
        """(row iterator ordered by path, newest first; months with files; connection to close) for the builder."""
        if type(self)._fetch is not NameTable._fetch:           # the backup tables bring their own row source
            rows, dates = self._fetch()
            return iter(rows), dates, None
        con = sqlite3.connect(f"file:{self.db_path}?mode=ro", uri=True)
        def gen():
            cur = con.execute("SELECT path, size, mtime FROM entries ORDER BY path, mtime DESC")
            while True:
                rows = cur.fetchmany(100000)
                if not rows:
                    break
                yield from rows
        dates = [r[0] for r in con.execute(
            "SELECT DISTINCT strftime('%Y-%m', mtime, 'unixepoch', 'localtime') d FROM entries "
            "WHERE mtime IS NOT NULL ORDER BY d DESC")]
        return gen(), dates, con

    def _build_snapshot(self, out):
        rows, dates, con = self._snap_rows()
        try:
            return _snap_write(out, rows, dates)
        finally:
            if con is not None:
                con.close()

    def _load_compact(self):
        import shutil
        t0 = time.time()
        with self.lock:
            self._loading, self._buffer = True, []
        try:
            stamp = self._stale_marker()
            root = self.db_path + ".nt"
            snap = os.path.join(root, f"{type(self).__name__}-{int(stamp * 1000)}")
            if not os.path.exists(os.path.join(snap, "meta.json")):
                os.makedirs(root, exist_ok=True)
                tmp = snap + ".tmp"
                shutil.rmtree(tmp, ignore_errors=True)
                # a child process builds it, so the big transient memory never lands in (or stays with) the server
                subprocess.run(["nice", "-n", "10", sys.executable, os.path.abspath(__file__), "--build",
                                type(self).__name__, self.db_path, tmp], check=True)
                os.rename(tmp, snap)
            self._map_snapshot(snap, stamp)
            for d in os.listdir(root):                       # older snapshots of this table are no longer needed
                if d.startswith(type(self).__name__ + "-") and os.path.join(root, d) != snap:
                    shutil.rmtree(os.path.join(root, d), ignore_errors=True)
        finally:
            with self.lock:
                self._loading = False
        print(f"name table (compact): {len(self.paths)} paths, {len(self.blob)/1e6:.0f} MB blob mapped, {time.time()-t0:.1f}s", flush=True)

    def _map_snapshot(self, snap, stamp):
        import mmap
        meta = json.load(open(os.path.join(snap, "meta.json")))
        ld = lambda name: np.load(os.path.join(snap, name + ".npy"), mmap_mode="r")
        def mapped(name):
            path = os.path.join(snap, name)
            if not os.path.getsize(path):
                return b""
            with open(path, "rb") as f:
                return mmap.mmap(f.fileno(), 0, access=mmap.ACCESS_READ)
        n = meta["n"]
        lower, orig = mapped("lower.bin"), mapped("orig.bin")
        starts, starts_o = ld("starts_l"), ld("starts_o")
        paths = _Lines(orig, starts_o) if n else []
        arr = np.frombuffer(lower, np.uint8) if n else np.zeros(0, np.uint8)
        orders = {k: ld(f"orders.{k}") for k in meta["orders"]}
        keys = {k: ld(f"keys.{k}") for k in meta["keys"]}
        with open(os.path.join(snap, "dirs.txt"), encoding="utf-8", errors="surrogatepass") as f:
            dirs = f.read().split("\n") if n else []
        off = {}
        for fld, _ in off_default_entries():
            fb = fld.encode("utf-8", "surrogatepass")
            orig.seek(0)
            off[fld] = np.fromiter((line.startswith(fb) for line in iter(orig.readline, b"")), bool, n) if n else np.zeros(0, bool)
        if off and n:
            orig.madvise(mmap.MADV_DONTNEED)       # that pass touched every page of the original-case blob; only result rows need it
        ext_codes, size_arr, mt_arr, order = ld("ext_codes"), ld("size_arr"), ld("mt_arr"), ld("order")
        if self.pin:    # a name search scans these on every keystroke: under memory pressure they must not be evicted and faulted back one page at a time
            n_pinned = pin_in_ram([arr, starts, order, ext_codes, size_arr, mt_arr, *orders.values()])
            print(f"name table: {n_pinned/1e6:.0f} MB of the mapped snapshot pinned in RAM", flush=True)
        with self.lock:
            self.paths, self.sizes, self.mtimes = paths, _Col(ld("sizes_raw")), _Col(ld("mtimes_raw"))
            self.blob, self.starts, self.arr = lower, starts, arr
            self._maps = [m for m in (orig,) if not isinstance(m, bytes)]     # only the original-case blob is cold (result rows)
            self.order = order
            self.ext_codes, self.ext_names = ext_codes, meta["ext_names"]
            self.size_arr, self.mt_arr, self.orders = size_arr, mt_arr, orders
            self.off_masks = off
            self.dirs = dirs
            self._tm_cache = collections.OrderedDict()
            self._last = None
            self.sort_keys = keys
            self._cache = None
            self.dates = meta["dates"]
            self.loaded_mtime = stamp
            self.dead = np.zeros(n, bool)
            self.d_entries, self._delta, self.needs_reload = {}, None, False
            self._ver += 1
            for op in self._buffer:
                self._apply(op)
            self._buffer = []

    def release_pages(self):
        """Tell the kernel this process no longer needs the mapped pages of the snapshot (they stay in the page cache and come
        back as cheap minor faults on the next query): the process shows only what it really uses while the picker is idle."""
        import mmap
        n = 0
        for m in list(getattr(self, "_maps", [])):
            try:
                m.madvise(mmap.MADV_DONTNEED); n += 1
            except (OSError, ValueError, AttributeError):
                pass
        for a in [*self.sort_keys.values()]:                      # sort keys serve multi-key sorts only
            mm = getattr(a, "_mmap", None)
            if mm is not None:
                try:
                    mm.madvise(mmap.MADV_DONTNEED); n += 1
                except (OSError, ValueError, AttributeError):
                    pass
        return n

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
        self.last_used = time.time()
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
            narrow = "||" not in terms[-1] and ((len(terms) == len(old) + 1 and terms[:len(old)] == old) or
                     (len(terms) == len(old) and terms[:-1] == old[:-1] and bool(old) and terms[-1].startswith(old[-1])))
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
            mask &= self._alt_mask(t)
        for t in neg_terms:
            mask &= ~self._alt_mask(t)
        for v in tags["path"]:
            mask &= self._alt_mask(v, expand_path_value)
        for v in tags["!path"]:
            mask &= ~self._alt_mask(v, expand_path_value)
        if not_wanted:
            banned = [k for k, e in enumerate(ext_names) if any(wants(e, w) for w in not_wanted)]
            hit = np.isin(ext_codes, np.array(banned, np.int32)) & (size_arr >= 0)
            if DIRECTORY in not_wanted:
                hit |= size_arr < 0
            mask &= ~hit
        for c in tags["!size"]:
            mask &= ~_size_mask(size_arr, c)
        if wanted:
            allowed = [k for k, e in enumerate(ext_names) if any(wants(e, w) for w in wanted)]
            hit = np.isin(ext_codes, np.array(allowed, np.int32)) & (size_arr >= 0)
            if DIRECTORY in wanted:
                hit |= size_arr < 0
            mask &= hit
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

    def _alt_mask(self, value, expand=lambda a: a):
        """Lines containing any alternative of an `a||b` value (a single value: just its own mask)."""
        out = None
        for a in alts(value):
            m = self._cached_term_mask(expand(a).encode("utf-8"))
            out = m if out is None else (out | m)
        return out

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
            while len(self._tm_cache) > TERM_CACHE:
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


class _DedupLines:
    """Read-only sequence of full paths held as (folder, name): every distinct folder is stored once and each entry keeps only its
    folder number and its own name, so 4.4M paths that share 290k folders cost the names plus one copy of each folder."""
    def __init__(self, names, name_starts, dirs, dir_starts, dir_id):
        self.names, self.name_starts, self.dirs, self.dir_starts, self.dir_id = names, name_starts, dirs, dir_starts, dir_id
        self.n, self.nd = len(name_starts), len(dir_starts)
        self.nsize, self.dsize = len(names), len(dirs)

    def __len__(self):
        return self.n

    def _line(self, mm, starts, i, n, size):
        s = int(starts[i])
        e = int(starts[i + 1]) - 1 if i + 1 < n else size
        return mm[s:e]

    def __getitem__(self, i):
        if isinstance(i, slice):
            return [self[k] for k in range(*i.indices(self.n))]
        if i < 0:
            i += self.n
        if not 0 <= i < self.n:
            raise IndexError(i)
        d = self._line(self.dirs, self.dir_starts, int(self.dir_id[i]), self.nd, self.dsize)
        nm = self._line(self.names, self.name_starts, i, self.n, self.nsize)
        return (d + b"/" + nm).decode("utf-8", "surrogatepass")

    def __iter__(self):
        dl = []
        self.dirs.seek(0)
        for line in iter(self.dirs.readline, b""):
            dl.append(line.rstrip(b"\n"))
        self.names.seek(0)
        ids = self.dir_id
        for i, line in enumerate(iter(self.names.readline, b"")):
            yield (dl[int(ids[i])] + b"/" + line.rstrip(b"\n")).decode("utf-8", "surrogatepass")


def _snap_write_dedup(out, rows_iter, dates):
    """The v2 snapshot: names and folders stored apart (see _DedupLines). Same lookup arrays as the plain snapshot."""
    import array, mmap
    os.makedirs(out, exist_ok=True)
    f_nl, f_no = open(os.path.join(out, "names_l.bin"), "wb"), open(os.path.join(out, "names_o.bin"), "wb")
    f_dl, f_do = open(os.path.join(out, "dirs_l.bin"), "wb"), open(os.path.join(out, "dirs_o.bin"), "wb")
    nst_l, nst_o, dst_l, dst_o = array.array("q"), array.array("q"), array.array("q"), array.array("q")
    dir_id, sizes, mts = array.array("i"), array.array("q"), array.array("q")
    seen = {}
    off_nl = off_no = off_dl = off_do = 0
    prev = None
    for p, sz, mt in rows_iter:
        if p == prev:
            continue
        prev = p
        p = p.replace("\n", " ")
        if "/" not in p:
            p = "/" + p                                  # the catalog only holds absolute paths; keep the layout total anyway
        d, nm = p.rsplit("/", 1)
        did = seen.get(d)
        if did is None:
            did = len(seen); seen[d] = did
            do = d.encode("utf-8", "surrogatepass"); dl = d.lower().encode("utf-8", "surrogatepass")
            if did:
                f_dl.write(b"\n"); f_do.write(b"\n"); off_dl += 1; off_do += 1
            dst_l.append(off_dl); dst_o.append(off_do)
            f_dl.write(dl); f_do.write(do); off_dl += len(dl); off_do += len(do)
        no = nm.encode("utf-8", "surrogatepass"); nl = nm.lower().encode("utf-8", "surrogatepass")
        if nst_l:
            f_nl.write(b"\n"); f_no.write(b"\n"); off_nl += 1; off_no += 1
        nst_l.append(off_nl); nst_o.append(off_no)
        f_nl.write(nl); f_no.write(no); off_nl += len(nl); off_no += len(no)
        dir_id.append(did)
        sizes.append(_Col.NULL if sz is None else sz)
        mts.append(_Col.NULL if mt is None else mt)
    for f in (f_nl, f_no, f_dl, f_do):
        f.close()
    n = len(nst_l)
    sv = lambda name, a, dt: np.save(os.path.join(out, name + ".npy"), np.frombuffer(a, dt) if len(a) else np.zeros(0, dt))
    sv("name_starts_l", nst_l, np.int64); sv("name_starts_o", nst_o, np.int64)
    sv("dir_starts_l", dst_l, np.int64); sv("dir_starts_o", dst_o, np.int64)
    sv("dir_id", dir_id, np.int32)
    raw_sizes = np.frombuffer(sizes, np.int64) if n else np.zeros(0, np.int64)
    raw_mts = np.frombuffer(mts, np.int64) if n else np.zeros(0, np.int64)
    np.save(os.path.join(out, "sizes_raw.npy"), raw_sizes); np.save(os.path.join(out, "mtimes_raw.npy"), raw_mts)
    if n:
        fo = [open(os.path.join(out, x), "rb") for x in ("names_o.bin", "dirs_o.bin")]
        mms = [mmap.mmap(f.fileno(), 0, access=mmap.ACCESS_READ) for f in fo]
        paths = _DedupLines(mms[0], np.frombuffer(nst_o, np.int64), mms[1], np.frombuffer(dst_o, np.int64), np.frombuffer(dir_id, np.int32))
    else:
        paths, mms, fo = [], [], []
    ext_codes, ext_names, size_arr, mt_arr, orders, keys = _extras(paths, _Col(raw_sizes), _Col(raw_mts))
    mt = np.where(raw_mts == _Col.NULL, 0, raw_mts)
    order = np.argsort(-mt) if n else np.zeros(0, np.int64)
    for name, a in (("ext_codes", ext_codes), ("size_arr", size_arr), ("mt_arr", mt_arr), ("order", order)):
        np.save(os.path.join(out, name + ".npy"), a)
    for k, v in orders.items():
        np.save(os.path.join(out, f"orders.{k}.npy"), v)
    for k, v in keys.items():
        np.save(os.path.join(out, f"keys.{k}.npy"), v)
    del paths
    for m in mms:
        m.close()
    for f in fo:
        f.close()
    with open(os.path.join(out, "dirs.txt"), "w", encoding="utf-8", errors="surrogatepass") as f:
        f.write("\n".join(sorted(seen)))
    with open(os.path.join(out, "meta.json"), "w") as f:
        json.dump({"version": SNAP_VERSION + 1, "dedup": True, "n": n, "nd": len(seen), "ext_names": ext_names,
                   "dates": [d for d in dates if d], "orders": sorted(orders), "keys": sorted(keys)}, f)
    return n


class DedupNameTable(NameTable):
    """NameTable whose scan data keeps each folder once: lower-case names and lower-case folders are scanned separately and
    combined per entry through its folder number. A word without "/" lies wholly in the folder part or the name; a word with
    "/" either lies inside a folder path or runs over the last separator (folder ends with the part before it, name starts with
    the part after it)."""
    compact = True

    def _build_snapshot(self, out):
        rows, dates, con = self._snap_rows()
        try:
            return _snap_write_dedup(out, rows, dates)
        finally:
            if con is not None:
                con.close()

    def _map_snapshot(self, snap, stamp):
        import mmap
        meta = json.load(open(os.path.join(snap, "meta.json")))
        ld = lambda name: np.load(os.path.join(snap, name + ".npy"), mmap_mode="r")
        def mapped(name):
            path = os.path.join(snap, name)
            if not os.path.getsize(path):
                return b""
            with open(path, "rb") as f:
                return mmap.mmap(f.fileno(), 0, access=mmap.ACCESS_READ)
        n = meta["n"]
        names_l, names_o, dirs_l, dirs_o = (mapped(x) for x in ("names_l.bin", "names_o.bin", "dirs_l.bin", "dirs_o.bin"))
        nst_l, nst_o, dst_l, dst_o, dir_id = (ld(x) for x in ("name_starts_l", "name_starts_o", "dir_starts_l", "dir_starts_o", "dir_id"))
        paths = _DedupLines(names_o, nst_o, dirs_o, dst_o, dir_id) if n else []
        names_arr = np.frombuffer(names_l, np.uint8) if n else np.zeros(0, np.uint8)
        dirs_arr = np.frombuffer(dirs_l, np.uint8) if len(dirs_l) else np.zeros(0, np.uint8)
        orders = {k: ld(f"orders.{k}") for k in meta["orders"]}
        keys = {k: ld(f"keys.{k}") for k in meta["keys"]}
        ext_codes, size_arr, mt_arr, order = ld("ext_codes"), ld("size_arr"), ld("mt_arr"), ld("order")
        with open(os.path.join(snap, "dirs.txt"), encoding="utf-8", errors="surrogatepass") as f:
            dirs = f.read().split("\n") if n else []
        off = {}
        for fld, _ in off_default_entries():
            fb = fld.encode("utf-8", "surrogatepass")
            off[fld] = np.fromiter((p.encode("utf-8", "surrogatepass").startswith(fb) for p in paths), bool, n) if n else np.zeros(0, bool)
        for m in (names_o, dirs_o):
            if not isinstance(m, bytes) and off:
                m.madvise(mmap.MADV_DONTNEED)
        if self.pin:
            n_pinned = pin_in_ram([names_arr, dirs_arr, nst_l, dst_l, dir_id, order, ext_codes, size_arr, mt_arr, *(v for k, v in orders.items() if k != "path")])    # the path order is just 0..n-1
            print(f"name table: {n_pinned/1e6:.0f} MB of the mapped snapshot pinned in RAM (folders stored once)", flush=True)
        with self.lock:
            self.paths, self.sizes, self.mtimes = paths, _Col(ld("sizes_raw")), _Col(ld("mtimes_raw"))
            self.blob, self.starts, self.arr = names_l, nst_l, names_arr
            self.dir_blob, self.dir_starts, self.dir_arr, self.dir_id = dirs_l, dst_l, dirs_arr, dir_id
            self._maps = [m for m in (names_o, dirs_o) if not isinstance(m, bytes)]
            self.order = order
            self.ext_codes, self.ext_names = ext_codes, meta["ext_names"]
            self.size_arr, self.mt_arr, self.orders = size_arr, mt_arr, orders
            self.off_masks = off
            self.dirs = dirs
            self._tm_cache = collections.OrderedDict()
            self._last = None
            self.sort_keys = keys
            self._cache = None
            self.dates = meta["dates"]
            self.loaded_mtime = stamp
            self.dead = np.zeros(n, bool)
            self.d_entries, self._delta, self.needs_reload = {}, None, False
            self._ver += 1
            for op in self._buffer:
                self._apply(op)
            self._buffer = []

    # ---- matching -----------------------------------------------------------------------------------
    def _scan_lines(self, arr, starts, term):
        """bool per line of a blob: the line contains term."""
        out = np.zeros(len(starts), np.uint8)
        if len(starts) and len(arr) >= len(term):
            t = np.frombuffer(term, np.uint8)
            _native().mark_lines(arr.ctypes.data, len(arr), starts.ctypes.data, len(starts), t.ctypes.data, len(term), out.ctypes.data)
        return out.view(bool)

    def _dirs_ending_with(self, tail):
        """bool per folder: the lower-case folder path ends with tail (b"" matches every folder)."""
        nd = len(self.dir_starts)
        if not tail:
            return np.ones(nd, bool)
        cand = np.flatnonzero(self._scan_lines(self.dir_arr, self.dir_starts, tail))
        res = np.zeros(nd, bool)
        mm, st, size = self.dir_blob, self.dir_starts, len(self.dir_blob)
        for i in cand.tolist():
            s = int(st[i]); e = int(st[i + 1]) - 1 if i + 1 < nd else size
            if e - s >= len(tail) and mm[e - len(tail):e] == tail:
                res[i] = True
        return res

    def _names_starting_with(self, idx, head):
        """bool per entry in idx: its lower-case name starts with head."""
        if not head:
            return np.ones(len(idx), bool)
        q = len(head)
        ha = np.frombuffer(head, np.uint8)
        top = len(self.arr) - 1
        keep = np.zeros(len(idx), bool)
        for a in range(0, len(idx), 200_000):
            sl = np.asarray(self.starts[idx[a:a + 200_000]], np.int64)
            pos = np.minimum(sl[:, None] + np.arange(q), top)
            keep[a:a + 200_000] = (self.arr[pos] == ha).all(axis=1)
        return keep

    def _term_mask(self, term):
        N = len(self.paths)
        if len(term) == 0:
            return np.ones(N, bool)
        if _native() is None:
            return super()._term_mask(term)
        if b"/" not in term:
            m = self._scan_lines(self.arr, self.starts, term).copy()
            m |= self._scan_lines(self.dir_arr, self.dir_starts, term)[self.dir_id]
            return m
        parts = term.split(b"/")
        head, tail = parts[-1], b"/".join(parts[:-1])
        m = self._scan_lines(self.dir_arr, self.dir_starts, term)[self.dir_id]          # the word lies inside a folder path
        ends = self._dirs_ending_with(tail)                                              # or runs over the last separator
        cand = np.flatnonzero(ends[self.dir_id])
        if len(cand):
            m[cand[self._names_starting_with(cand, head)]] = True
        return m

    def _filter_candidates(self, cand, term):
        if b"/" in term or _native() is None or not len(term):
            return self._term_mask(term)[cand]
        cand = np.ascontiguousarray(cand, np.int64)
        t = np.frombuffer(term, np.uint8)
        lib = _native()
        keep = np.zeros(len(cand), np.uint8)
        lib.filter_lines(self.arr.ctypes.data, len(self.arr), self.starts.ctypes.data, len(self.starts),
                         cand.ctypes.data, len(cand), t.ctypes.data, len(term), keep.ctypes.data)
        did = np.ascontiguousarray(self.dir_id[cand], np.int64)
        keepd = np.zeros(len(cand), np.uint8)
        lib.filter_lines(self.dir_arr.ctypes.data, len(self.dir_arr), self.dir_starts.ctypes.data, len(self.dir_starts),
                         did.ctypes.data, len(did), t.ctypes.data, len(term), keepd.ctypes.data)
        return (keep | keepd).astype(bool)


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


if __name__ == "__main__":
    if len(sys.argv) == 5 and sys.argv[1] == "--build":
        cls = {"NameTable": NameTable, "DedupNameTable": DedupNameTable, "ResticTable": ResticTable, "BtrfsTable": BtrfsTable}[sys.argv[2]]
        print("snapshot rows:", cls(sys.argv[3])._build_snapshot(sys.argv[4]), flush=True)
    else:
        sys.exit("usage: filesearch.py --build NameTable|ResticTable|BtrfsTable DB OUTDIR")

"""In-memory file-name index (the 'Everything' part of the search server).

All distinct paths from the catalog are kept as one lowercase blob separated by
newlines, plus an offsets array. A query finds the rarest-looking term in the
blob with bytes.find, maps hits back to lines with searchsorted, then checks the
other terms per candidate. Each keystroke is one scan over RAM; nothing on disk
is touched and no per-query process is started.
"""
import bisect, os, sqlite3, threading, time
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

def split_mime(query):
    """'//mime image foo bar' -> (['image'], 'foo bar')."""
    import re
    wanted = [m.lower() for m in re.findall(r"//mime\s+(\S+)", query)]
    rest = re.sub(r"//mime\s+\S+", " ", query)
    return wanted, rest.strip()

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

    def load(self):
        t0 = time.time()
        con = sqlite3.connect(f"file:{self.db_path}?mode=ro", uri=True)
        rows = con.execute("SELECT path, size, mtime FROM entries ORDER BY path").fetchall()
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
        with self.lock:
            self.paths, self.sizes, self.mtimes = paths, sizes, mtimes
            self.blob, self.starts = blob, starts
            self.order = order
            self.loaded_mtime = os.path.getmtime(self.db_path)
        print(f"name table: {len(paths)} paths, {len(blob)/1e6:.0f} MB blob, {time.time()-t0:.1f}s", flush=True)

    def refresh_if_stale(self):
        try:
            if os.path.getmtime(self.db_path) > self.loaded_mtime:
                self.load()
        except OSError:
            pass

    def browse(self, limit=200, wanted=None):
        """Newest files first (no query), optionally filtered by //mime."""
        with self.lock:
            order, paths, sizes, mtimes = self.order, self.paths, self.sizes, self.mtimes
        out = []
        for i in order[: 200000 if wanted else limit]:
            if wanted and not matches_mime(paths[i], wanted):
                continue
            out.append({"remote": paths[i], "size": sizes[i], "mtime": mtimes[i]})
            if len(out) >= limit:
                break
        return out

    def search(self, query, limit=200):
        wanted, query = split_mime(query)
        terms = [t.lower() for t in query.split() if t]
        if not terms:
            if wanted:
                return self.browse(limit, wanted), None
            return [], 0
        with self.lock:
            blob, starts, paths, sizes, mtimes = self.blob, self.starts, self.paths, self.sizes, self.mtimes
        anchor = max(terms, key=len)          # the longest term is usually the most selective
        others = [t for t in terms if t is not anchor][:4]
        a = anchor.encode("utf-8")
        hits, pos, seen = [], 0, set()
        while True:
            pos = blob.find(a, pos)
            if pos < 0:
                break
            line = int(np.searchsorted(starts, pos, side="right") - 1)
            if line not in seen:
                seen.add(line)
                s = starts[line]
                e = blob.find(b"\n", s)
                text = blob[s:e].decode("utf-8", "surrogatepass")
                if all(o in text for o in others):
                    hits.append(line)
            pos = (pos + 1)
        if wanted:
            hits = [i for i in hits if matches_mime(paths[i], wanted)]
        hits.sort(key=lambda i: paths[i])
        out = [{"remote": paths[i], "size": sizes[i], "mtime": mtimes[i]} for i in hits[:limit]]
        return out, len(hits)

def start_refresh(table, every=60):
    def loop():
        while True:
            time.sleep(every)
            table.refresh_if_stale()
    threading.Thread(target=loop, daemon=True).start()

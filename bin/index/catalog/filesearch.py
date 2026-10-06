"""In-memory file-name index (the 'Everything' part of the search server).

All distinct paths from the catalog are kept as one lowercase blob separated by
newlines, plus an offsets array. A query finds the rarest-looking term in the
blob with bytes.find, maps hits back to lines with searchsorted, then checks the
other terms per candidate. Each keystroke is one scan over RAM; nothing on disk
is touched and no per-query process is started.
"""
import bisect, os, sqlite3, threading, time
import numpy as np

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
        with self.lock:
            self.paths, self.sizes, self.mtimes = paths, sizes, mtimes
            self.blob, self.starts = blob, starts
            self.loaded_mtime = os.path.getmtime(self.db_path)
        print(f"name table: {len(paths)} paths, {len(blob)/1e6:.0f} MB blob, {time.time()-t0:.1f}s", flush=True)

    def refresh_if_stale(self):
        try:
            if os.path.getmtime(self.db_path) > self.loaded_mtime:
                self.load()
        except OSError:
            pass

    def search(self, query, limit=200):
        terms = [t.lower() for t in query.split() if t]
        if not terms:
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
        hits.sort(key=lambda i: paths[i])
        out = [{"remote": paths[i], "size": sizes[i], "mtime": mtimes[i]} for i in hits[:limit]]
        return out, len(hits)

def start_refresh(table, every=60):
    def loop():
        while True:
            time.sleep(every)
            table.refresh_if_stale()
    threading.Thread(target=loop, daemon=True).start()

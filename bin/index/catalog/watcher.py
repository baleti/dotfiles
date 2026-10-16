#!/usr/bin/env python3
"""Live change watcher for the file-name catalog (the "Everything" part: new, renamed and deleted files show
up in the search within about a second).

Events come from fanwatch-helper (catalog/fanwatch/), which holds ONE fanotify mark for the whole btrfs volume
and streams resolved path events on /run/fanwatch/events.sock. This process is unprivileged. It applies the
same exclusions as `catalog.py build-local`, coalesces events per path, resolves them with lstat when they
settle, writes them to the catalog database (so a restarted search server or the next full walk agrees) and
pushes them to the running search server (POST /delta), which overlays them on its in-memory table without
reloading.

What fanotify cannot see is covered by the periodic jobs: filesystems other than the btrfs volume (the Drive
and NFS mounts have their own pollers), files held open and still being written (their size and date update
when closed) and changes made while the helper or this watcher was down. A kernel queue overflow, a client
that fell behind, or a reconnect after a gap starts a catalog walk.
"""
import collections, json, os, socket, stat, subprocess, sys, threading, time
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import catalog
from catalog import C, HOME

SOCK = os.environ.get("FANWATCH_SOCK", "/run/fanwatch/events.sock")
QUIET = 1.0         # a path is written once nothing touched it for this long ...
MAX_WAIT = 15.0     # ... or this long after its first event, so a file that is written all the time still updates

def log(*a):
    print(*a, file=sys.stderr, flush=True)

class LocalSync(catalog.SourceStore):
    def _kind(self, st):
        if stat.S_ISDIR(st.st_mode):
            return None, "dir"
        if stat.S_ISLNK(st.st_mode):
            return 0, "link"
        return st.st_size, "file"

    def put_path(self, path):
        try:
            st = os.lstat(path)
        except OSError:
            return self.del_path(path)
        size, kind = self._kind(st)
        mtime, keep, gone = int(st.st_mtime), False, []
        for eid, sz, mt in self.db.execute(
                "SELECT e.id, e.size, e.mtime FROM entries e WHERE e.path=? AND EXISTS "
                "(SELECT 1 FROM entry_sources es WHERE es.entry_id=e.id AND es.source_id=?)", (path, self.sid)).fetchall():
            if sz == size and mt == mtime:
                keep = True
            else:
                gone.append(eid)
        self.drop(gone)
        if not keep:
            self.add(path, size, mtime, kind)
        self.touched.add(path)

    def del_path(self, path):
        self.drop([r[0] for r in self.db.execute(
            "SELECT e.id FROM entries e WHERE e.path=? AND EXISTS "
            "(SELECT 1 FROM entry_sources es WHERE es.entry_id=e.id AND es.source_id=?)", (path, self.sid))])
        self.touched.add(path)

    def delprefix(self, path):
        self.drop([r[0] for r in self.db.execute(
            "SELECT e.id FROM entries e WHERE (e.path=? OR (e.path>=? AND e.path<?)) AND EXISTS "
            "(SELECT 1 FROM entry_sources es WHERE es.entry_id=e.id AND es.source_id=?)",
            (path, path + "/", path + "0", self.sid))])
        self.touched.add(path)

class Watcher:
    def __init__(self):
        self.excl = set(C.get("exclude_names", []))            # relative to $HOME
        self.anywhere = set(C.get("exclude_anywhere", []))     # names skipped wherever they occur (.snapshots)
        self.exclude_paths = [os.path.expanduser(x).rstrip("/") for x in C.get("exclude_paths", [])]
        self.lock = threading.Lock()
        self.puts = {}            # path -> [first event time, last event time]
        self.struct = []          # ("scan" | "delprefix", path), in event order
        self.rescan = False
        self.last_rescan = 0.0
        self.events = 0
        self.t = collections.Counter()           # seconds spent per flush phase
        self.hot = collections.Counter()         # where the events come from (first path components)
        self.stats_every = float(os.environ.get("WATCHER_STATS", "600"))

    def excluded(self, path):
        """Same policy as the walk: names relative to $HOME, names anywhere, absolute paths."""
        if path.startswith(HOME + "/"):
            rel = path[len(HOME) + 1:]
            if any(rel == e or rel.startswith(e + "/") for e in self.excl):
                return True
        if self.anywhere and any(c in self.anywhere for c in path.split("/")):
            return True
        return any(path == x or path.startswith(x + "/") for x in self.exclude_paths)

    def put(self, path):
        now = time.time()
        with self.lock:
            e = self.puts.get(path)
            if e:
                e[1] = now
            else:
                self.puts[path] = [now, now]

    def handle(self, ev):
        if ev.get("overflow"):
            self.rescan = True
            return
        path, kinds, isdir = ev["p"], ev["e"], bool(ev["d"])
        if self.excluded(path):
            return
        self.events += 1
        d = "/".join(path.split("/")[:6 if path.startswith(HOME + "/") else 4])
        self.hot[d] += 1
        parent = path.rsplit("/", 1)[0] or "/"
        if "C" in kinds or "T" in kinds:
            if isdir:
                with self.lock:
                    self.struct.append(("scan", path))
            else:
                self.put(path)
            self.put(parent)                    # the folder's own date changed too
        elif "D" in kinds or "F" in kinds:
            if isdir:
                with self.lock:
                    self.struct.append(("delprefix", path))
            else:
                self.put(path)
            self.put(parent)
        else:                                   # closed after writing / attributes
            self.put(path)

    def read_loop(self):
        """Follow the helper's socket; reconnect forever. A reconnect after a gap means missed events: rescan."""
        connected_before, warned = False, False
        while True:
            s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            try:
                s.connect(SOCK)
            except OSError as e:
                s.close()
                if not warned:
                    log(f"fanwatch helper not reachable at {SOCK} ({e.strerror}); retrying every 10 s")
                    warned = True
                time.sleep(10)
                continue
            warned = False
            log("connected to fanwatch helper" + (", rescanning for what was missed" if connected_before else ""))
            if connected_before:
                self.rescan = True
            connected_before = True
            buf = b""
            while True:
                try:
                    chunk = s.recv(1 << 16)
                except OSError:
                    chunk = b""
                if not chunk:
                    break
                buf += chunk
                *lines, buf = buf.split(b"\n")
                for line in lines:
                    try:
                        self.handle(json.loads(line))
                    except (ValueError, KeyError):
                        pass
            s.close()
            log("helper connection closed")
            time.sleep(2)

    def scan(self, root, store):
        """A folder appeared (created, moved in): record everything in it."""
        stack = [root]
        while stack:
            d = stack.pop()
            store.put_path(d)
            try:
                it = os.scandir(d)
            except OSError:
                continue
            with it:
                for e in it:
                    if self.excluded(e.path):
                        continue
                    try:
                        if e.is_dir(follow_symlinks=False):
                            stack.append(e.path)
                        else:
                            store.put_path(e.path)
                    except OSError:
                        pass

    def flush_loop(self):
        db = catalog.connect()
        sid = catalog.source_id(db, "live:local", "live")
        db.commit()
        applied, last_stats = 0, time.time()
        while True:
            time.sleep(0.5)
            if self.rescan:
                self.rescan = False
                if time.time() - self.last_rescan > 300:
                    self.last_rescan = time.time()
                    log("events were lost: starting a catalog walk")
                    subprocess.run(["systemctl", "--user", "start", "--no-block", "catalog-local.service"])
            now = time.time()
            with self.lock:
                structs, self.struct = self.struct, []
                due = [p for p, (first, last) in self.puts.items() if now - last >= QUIET or now - first >= MAX_WAIT]
                for p in due:
                    del self.puts[p]
            if not structs and not due:
                continue
            store = LocalSync(db, sid)
            t_a = time.time()
            try:
                for kind, path in structs:
                    if kind == "scan":
                        self.scan(path, store)
                    else:
                        store.delprefix(path)
                for p in due:
                    store.put_path(p)
                db.commit()
                self.t["db"] += time.time() - t_a
            except Exception as e:
                db.rollback()
                log("flush failed, will retry:", repr(e))
                with self.lock:
                    self.struct = structs + self.struct
                    for p in due:
                        self.puts.setdefault(p, [now, now])
                continue
            t_e = time.time()
            catalog.deliver(db, store.touched)
            self.t["deliver"] += time.time() - t_e
            applied += len(store.touched)
            if now - last_stats >= self.stats_every:
                log(f"{self.events} events, {applied} paths applied in {now - last_stats:.0f}s; hottest: "
                    + ", ".join(f"{k} x{v}" for k, v in self.hot.most_common(8))
                    + " | seconds: " + ", ".join(f"{k} {v:.1f}" for k, v in self.t.items()))
                self.t.clear()
                self.events, applied, last_stats = 0, 0, now
                self.hot.clear()

    def run(self):
        threading.Thread(target=self.flush_loop, daemon=True).start()
        self.read_loop()

if __name__ == "__main__":
    Watcher().run()

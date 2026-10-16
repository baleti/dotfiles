#!/usr/bin/env python3
"""Live change watcher for the file-name catalog (the "Everything" part: new, renamed and deleted files show
up in the search within about a second).

inotify on every directory the local walk covers (same roots and exclusions as `catalog.py build-local`), no
root needed. Events are coalesced per path, resolved with lstat when they settle, written to the catalog
database (so a restarted search server or the next full walk agrees) and pushed to the running search
server (POST /delta), which overlays them on its in-memory table without reloading.

What inotify cannot see is covered by the periodic jobs: files held open and still being written (their size
and date update when closed), changes made while this was not running, and remote mounts (the Drive poller).
A kernel queue overflow starts a catalog walk.
"""
import collections, ctypes, ctypes.util, json, os, select, stat, struct, subprocess, sys, threading, time
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import catalog
from catalog import C, HOME

libc = ctypes.CDLL(ctypes.util.find_library("c"), use_errno=True)
IN_ATTRIB, IN_CLOSE_WRITE, IN_CREATE, IN_DELETE = 0x4, 0x8, 0x100, 0x200
IN_DELETE_SELF, IN_MOVED_FROM, IN_MOVED_TO = 0x400, 0x40, 0x80
IN_Q_OVERFLOW, IN_IGNORED, IN_ISDIR = 0x4000, 0x8000, 0x40000000
IN_ONLYDIR, IN_DONT_FOLLOW, IN_EXCL_UNLINK = 0x01000000, 0x02000000, 0x04000000
MASK = (IN_ATTRIB | IN_CLOSE_WRITE | IN_CREATE | IN_DELETE | IN_MOVED_FROM | IN_MOVED_TO | IN_DELETE_SELF
        | IN_ONLYDIR | IN_DONT_FOLLOW | IN_EXCL_UNLINK)
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
        roots = json.loads(os.environ["CATALOG_LOCAL_ROOTS"]) if os.environ.get("CATALOG_LOCAL_ROOTS") else C["local_roots"]
        self.roots = [os.path.expanduser(r) for r in roots]
        self.skip = catalog.skipped_paths(roots)
        self.excl = set(C.get("exclude_names", []))
        self.anywhere = set(C.get("exclude_anywhere", []))
        self.fd = libc.inotify_init1(os.O_NONBLOCK | os.O_CLOEXEC)
        if self.fd < 0:
            raise OSError(ctypes.get_errno(), "inotify_init1")
        self.wd_path = {}
        self.lock = threading.Lock()
        self.puts = {}            # path -> [first event time, last event time]
        self.struct = []          # ("scan" | "delprefix", path), in event order
        self.overflow = False
        self.full = False         # out of watches: remember, the periodic walk still covers the rest
        self.last_rescan = 0.0
        self.events = 0
        self.t = collections.Counter()           # seconds spent per flush phase
        self.hot = collections.Counter()        # where the events come from (first path components)
        self.stats_every = float(os.environ.get("WATCHER_STATS", "600"))

    def excluded(self, path, name):
        return (path in self.skip or name in self.anywhere
                or (path.startswith(HOME + "/") and os.path.relpath(path, HOME) in self.excl))

    def watch(self, d):
        wd = libc.inotify_add_watch(self.fd, os.fsencode(d), MASK)
        if wd < 0:
            err = ctypes.get_errno()
            if err == 28 and not self.full:      # ENOSPC: fs.inotify.max_user_watches
                self.full = True
                log("out of inotify watches; directories past this point are only covered by the periodic walk")
            return False
        with self.lock:
            self.wd_path[wd] = d               # an already-watched folder that moved keeps its wd: remap it
        return True

    def watch_tree(self, root):
        """Watch every directory below root (and root itself); returns how many."""
        n, stack = 0, [root]
        while stack:
            d = stack.pop()
            if self.watch(d):
                n += 1
            try:
                it = os.scandir(d)
            except OSError:
                continue
            with it:
                for e in it:
                    try:
                        if e.is_dir(follow_symlinks=False) and not self.excluded(e.path, e.name):
                            stack.append(e.path)
                    except OSError:
                        pass
        return n

    def unwatch(self, prefix):
        with self.lock:
            gone = [wd for wd, d in self.wd_path.items() if d == prefix or d.startswith(prefix + "/")]
            for wd in gone:
                del self.wd_path[wd]
        for wd in gone:
            libc.inotify_rm_watch(self.fd, wd)

    def put(self, path):
        now = time.time()
        with self.lock:
            e = self.puts.get(path)
            if e:
                e[1] = now
            else:
                self.puts[path] = [now, now]

    def handle(self, wd, mask, name):
        if mask & IN_Q_OVERFLOW:
            self.overflow = True
            return
        d = self.wd_path.get(wd)
        if d is None:
            return
        if mask & IN_IGNORED:
            with self.lock:
                self.wd_path.pop(wd, None)
            return
        if mask & IN_DELETE_SELF:
            return                              # the parent reports the removal by name
        path = d + "/" + name if name else d
        if name and self.excluded(path, name):
            return
        isdir = bool(mask & IN_ISDIR)
        self.events += 1
        self.hot["/".join(d.split("/")[:self.hot_depth(d)])] += 1
        if mask & (IN_CREATE | IN_MOVED_TO):
            if isdir:
                with self.lock:
                    self.struct.append(("scan", path))
            else:
                self.put(path)
            self.put(d)                         # the folder's own date changed too
        elif mask & (IN_DELETE | IN_MOVED_FROM):
            if isdir:
                with self.lock:
                    self.struct.append(("delprefix", path))
            else:
                self.put(path)
            self.put(d)
        else:                                   # closed after writing / attributes
            self.put(path)

    @staticmethod
    def hot_depth(d):
        return 6 if d.startswith(HOME + "/") else 4

    def read_loop(self):
        while True:
            select.select([self.fd], [], [])
            try:
                buf = os.read(self.fd, 1 << 16)
            except BlockingIOError:
                continue
            off = 0
            while off + 16 <= len(buf):
                wd, mask, _cookie, ln = struct.unpack_from("iIII", buf, off)
                name = os.fsdecode(buf[off + 16: off + 16 + ln].split(b"\0", 1)[0])
                off += 16 + ln
                self.handle(wd, mask, name)

    def scan(self, root, store):
        """A folder appeared (created, moved in): watch it and record everything in it."""
        stack = [root]
        while stack:
            d = stack.pop()
            if d in self.skip:
                continue
            self.watch(d)
            store.put_path(d)
            try:
                it = os.scandir(d)
            except OSError:
                continue
            with it:
                for e in it:
                    if self.excluded(e.path, e.name):
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
            if self.overflow:
                self.overflow = False
                if time.time() - self.last_rescan > 300:
                    self.last_rescan = time.time()
                    log("inotify queue overflowed: starting a catalog walk")
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
                        self.unwatch(path)
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
        reader = threading.Thread(target=self.read_loop, daemon=True)
        reader.start()                          # drain events while the watches are still being set up
        t0 = time.time()
        total = sum(self.watch_tree(r) for r in self.roots)
        log(f"watching {total} directories ({time.time() - t0:.1f}s)")
        reader.join()

if __name__ == "__main__":
    Watcher().run()

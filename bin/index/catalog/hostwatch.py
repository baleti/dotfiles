#!/usr/bin/env python3
"""Live updates for the catalog's NFS roots (extra_roots, e.g. host1's backups).

Kernel file notifications do not cross NFS, so the watching happens on the machine that owns the disk:
fanwatch-helper + fanwatch/stream.py run on host1 and this process reads their change stream over ssh, using
a restricted key (forced command, only accepted from this machine's WireGuard address, see ~/.ssh/config
"Host host1-wg"). Each change is already resolved on host1 (size, date, kind), so nothing here touches the
NFS mount. Changes are applied to the catalog database and pushed to the running search server, like watcher.py.

A reconnect after a gap, or an overflow marker, means changes may have been missed: a full `build-extra` walk
is started (at most once an hour). The monthly catalog-extra timer does the same as a safety net.
"""
import json, os, select, subprocess, sys, time
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import catalog
from catalog import C

HOST = os.environ.get("FANWATCH_SSH_HOST", "host1-wg")

def log(*a):
    print(*a, file=sys.stderr, flush=True)

class RemoteSync(catalog.SourceStore):
    def put(self, path, size, mtime, kind):
        keep, gone = False, []
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

    def delete(self, path):
        self.drop([r[0] for r in self.db.execute(
            "SELECT e.id FROM entries e WHERE e.path=? AND EXISTS (SELECT 1 FROM entry_sources es "
            "WHERE es.entry_id=e.id AND es.source_id=?)", (path, self.sid))])
        self.touched.add(path)

    def delprefix(self, path):
        self.drop([r[0] for r in self.db.execute(
            "SELECT e.id FROM entries e WHERE (e.path=? OR (e.path>=? AND e.path<?)) AND EXISTS "
            "(SELECT 1 FROM entry_sources es WHERE es.entry_id=e.id AND es.source_id=?)",
            (path, path + "/", path + "0", self.sid))])
        self.touched.add(path)

class HostWatch:
    def __init__(self):
        self.db = catalog.connect()
        self.roots = []          # (remote root, local root, RemoteSync)
        for r in C.get("extra_roots", []):
            root, rroot = r["root"].rstrip("/"), r["remote_root"].rstrip("/")
            sid = catalog.source_id(self.db, f"live:path:{root}", "live")
            self.roots.append((rroot, root, RemoteSync(self.db, sid)))
        self.db.commit()
        self.last_rescan = 0.0
        self.applied = 0

    def route(self, rpath):
        for rroot, root, store in self.roots:
            if rpath == rroot or rpath.startswith(rroot + "/"):
                return root + rpath[len(rroot):], store
        return None, None

    def rescan(self, why):
        if time.time() - self.last_rescan > 3600:
            self.last_rescan = time.time()
            log(f"{why}: starting a full walk of the NFS roots")
            subprocess.run(["systemctl", "--user", "start", "--no-block", "catalog-extra.service"])

    def apply(self, ops):
        touched = set()
        try:
            for op in ops:
                path, store = self.route(op["p"])
                if store is None:
                    continue
                kind = op["op"]
                if kind == "put":
                    store.put(path, op["s"], op["m"], op["k"])
                elif kind == "del":
                    store.delete(path)
                elif kind == "delprefix":
                    store.delprefix(path)
            self.db.commit()
        except Exception:
            self.db.rollback()
            raise
        finally:
            for _, _, store in self.roots:
                touched |= store.touched
                store.touched = set()
        catalog.deliver(self.db, touched)
        self.applied += len(touched)

    def session(self, first):
        p = subprocess.Popen(["ssh", "-T", HOST], stdout=subprocess.PIPE, bufsize=0)
        log("connected to", HOST, "" if first else "(reconnect)")
        if not first:
            self.rescan("reconnected after a gap")
        buf, pending, last_flush, last_seen = b"", [], time.time(), time.time()
        while True:
            ready = select.select([p.stdout], [], [], 0.5)[0]
            now = time.time()
            if ready:
                chunk = os.read(p.stdout.fileno(), 1 << 16)
                if not chunk:
                    break
                buf += chunk
                *lines, buf = buf.split(b"\n")
                for line in lines:
                    try:
                        o = json.loads(line)
                    except ValueError:
                        continue
                    last_seen = now
                    if o.get("overflow"):
                        self.rescan("host1 reported lost events")
                    elif "op" in o:
                        pending.append(o)
            if now - last_seen > 120:
                log("no data (not even heartbeats) for 120 s, reconnecting")
                break
            if pending and (now - last_flush >= 0.5 or len(pending) > 5000):
                self.apply(pending)
                pending, last_flush = [], now
        if pending:
            self.apply(pending)
        p.kill()
        p.wait()

    def run(self):
        first = True
        while True:
            try:
                self.session(first)
            except Exception as e:
                log("session failed:", repr(e))
            first = False
            time.sleep(10)

if __name__ == "__main__":
    HostWatch().run()

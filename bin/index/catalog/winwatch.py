#!/usr/bin/env python3
"""Live updates for the Windows drives of the catalog (the extra_roots served over ssh from the WSL box, e.g. /mnt/m, /mnt/q).

Kernel notifications do not cross sshfs/SMB, so a small background watcher runs on the Windows PC itself (SearchApp.exe --watch,
see ~/bin/search-win/Watcher.cs): it listens to the Windows change notifications and appends one JSON line per change to
%LOCALAPPDATA%\\SearchApp\\changes\\*.jsonl, the same line format as fanwatch (hostwatch.py). This process follows that file over
ssh from where it stopped last time (a byte offset is kept in winwatch.state.json), applies the changes to the catalog database
and pushes them to the running search server, exactly like hostwatch.py does for the host1 NFS roots.

Because the position is remembered, a gap (ssh down, host3 restarted, PC asleep) loses nothing; only a reported overflow of the
Windows event buffer, or a missing change file, starts a full walk of the extra roots (at most once an hour).
"""
import json, os, select, shlex, subprocess, sys, time
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import catalog
import hostwatch
from catalog import C

HOST = os.environ.get("WINWATCH_SSH_HOST", "wsl")
STATE = os.path.expanduser(catalog.DB) + ".winwatch.json"

# Runs on the WSL box: follows the newest change file of the Windows user, printing {"f": file, "o": offset after the line, "ev": line}.
REMOTE = r'''
import glob, os, sys, time
dirs = glob.glob("/mnt/c/Users/*/AppData/Local/SearchApp/changes")
cur, off = sys.argv[1], int(sys.argv[2])
def out(s): sys.stdout.write(s + "\n"); sys.stdout.flush()
while not dirs:
    out('{"hb":1}'); time.sleep(15); dirs = glob.glob("/mnt/c/Users/*/AppData/Local/SearchApp/changes")
d = dirs[0]
def files(): return sorted(f for f in os.listdir(d) if f.endswith(".jsonl"))
fs = files()
if not fs:
    out('{"hb":1}')
    while not fs: time.sleep(5); fs = files()
if not cur:
    cur, off = fs[-1], os.path.getsize(os.path.join(d, fs[-1]))
elif cur not in fs:
    out('{"overflow":1}'); cur, off = fs[0] if fs[0] > cur else fs[-1], 0
last_hb = time.time()
buf = b""
while True:
    path = os.path.join(d, cur)
    try:
        f = open(path, "rb")
    except OSError:
        time.sleep(1); continue
    with f:
        f.seek(off)
        while True:
            chunk = f.read(1 << 16)
            if chunk:
                buf += chunk
                *lines, buf = buf.split(b"\n")
                for line in lines:
                    off += len(line) + 1
                    if line.strip():
                        out('{"f":"%s","o":%d,"ev":%s}' % (cur, off, line.decode("utf-8", "replace")))
                continue
            later = [x for x in files() if x > cur]
            if later and not buf:
                cur, off = later[0], 0; break
            if time.time() - last_hb > 15:
                out('{"hb":1}'); last_hb = time.time()
            time.sleep(0.4)
'''

def log(*a):
    print(*a, file=sys.stderr, flush=True)

class WinWatch(hostwatch.HostWatch):
    def __init__(self):
        self.db = catalog.connect()
        self.roots = []
        for r in C.get("extra_roots", []):
            if r.get("ssh") != HOST:
                continue
            root, rroot = r["root"].rstrip("/"), r["remote_root"].rstrip("/")
            label = f"live:path:{root}"
            row = self.db.execute("SELECT id FROM sources WHERE label=?", (label,)).fetchone()   # read first: an INSERT would wait for the writer lock
            sid = row[0] if row else catalog.source_id(self.db, label, "live")
            self.roots.append((rroot, root, hostwatch.RemoteSync(self.db, sid)))
        self.db.commit()
        self.last_rescan = 0.0
        self.applied = 0
        try:
            self.pos = json.load(open(STATE))
        except (OSError, ValueError):
            self.pos = {"f": "", "o": 0}

    def save(self):
        tmp = STATE + ".tmp"
        json.dump(self.pos, open(tmp, "w"))
        os.replace(tmp, STATE)

    def session(self, first):
        p = subprocess.Popen(["ssh", "-T", HOST, "python3", "-c", REMOTE_Q, shlex.quote(self.pos["f"]), str(self.pos["o"])], stdout=subprocess.PIPE, bufsize=0)
        log("following the Windows change file from", self.pos["f"] or "(newest)", self.pos["o"])
        buf, pending, last_flush, last_seen, newpos = b"", [], time.time(), time.time(), None
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
                        self.rescan("Windows reported lost events")
                    elif "ev" in o:
                        ev = o["ev"]
                        if ev.get("overflow"):
                            self.rescan("Windows reported lost events")
                        elif "op" in ev:
                            pending.append(ev)
                        newpos = {"f": o["f"], "o": o["o"]}
            if now - last_seen > 90:
                log("no data (not even heartbeats) for 90 s, reconnecting")
                break
            if (pending or newpos) and (now - last_flush >= 0.5 or len(pending) > 5000):
                if pending:
                    self.apply(pending)
                if newpos:
                    self.pos = newpos; self.save()
                pending, last_flush, newpos = [], now, None
        if pending:
            self.apply(pending)
        if newpos:
            self.pos = newpos; self.save()
        p.kill()
        p.wait()

REMOTE_Q = REMOTE  # passed as one argv element: ssh joins argv with spaces, so quote it for the remote shell
REMOTE_Q = shlex.quote(REMOTE)

if __name__ == "__main__":
    WinWatch().run()

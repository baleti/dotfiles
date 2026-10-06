#!/usr/bin/env python3
"""Personal file catalog: one SQLite database over $HOME, the rclone remotes and
the restic snapshots, deduplicated by (path, size, mtime).

  build-local      walk the local roots (skips mount points, excluded names)
  build-rclone     list each rclone remote through its API (no FUSE walk)
  build-restic     add restic snapshot listings (latest N, or --all)
  find TEXT        substring search over names (trigram FTS), optional filters
  stats            counts per source

Settings: "catalog" section of ~/.config/indexes/photos.json (private).
"""
import argparse, json, os, re, shlex, sqlite3, subprocess, sys, time
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))) + "/photos")
import config
C = config.CFG["catalog"]
DB = C["db"]
HOME = os.path.expanduser("~")

SCHEMA = """
CREATE TABLE IF NOT EXISTS entries(
  id INTEGER PRIMARY KEY,
  path TEXT NOT NULL,
  name TEXT NOT NULL,
  size INTEGER,
  mtime INTEGER,
  kind TEXT NOT NULL,
  UNIQUE(path, size, mtime)
);
CREATE TABLE IF NOT EXISTS sources(
  id INTEGER PRIMARY KEY,
  label TEXT UNIQUE NOT NULL,
  kind TEXT NOT NULL,
  taken TEXT
);
CREATE TABLE IF NOT EXISTS entry_sources(
  entry_id INTEGER NOT NULL,
  source_id INTEGER NOT NULL,
  PRIMARY KEY(entry_id, source_id)
) WITHOUT ROWID;
CREATE INDEX IF NOT EXISTS entry_sources_by_source ON entry_sources(source_id);
CREATE VIRTUAL TABLE IF NOT EXISTS names USING fts5(
  name, content='entries', content_rowid='id', tokenize='trigram');
"""

def connect():
    os.makedirs(os.path.dirname(os.path.expanduser(DB)), exist_ok=True)
    db = sqlite3.connect(os.path.expanduser(DB))
    db.executescript(SCHEMA)
    db.execute("PRAGMA journal_mode=WAL")
    db.execute("PRAGMA synchronous=NORMAL")
    return db

def source_id(db, label, kind, taken=None):
    db.execute("INSERT OR IGNORE INTO sources(label, kind, taken) VALUES(?,?,?)", (label, kind, taken))
    return db.execute("SELECT id FROM sources WHERE label=?", (label,)).fetchone()[0]

class Writer:
    """Batches entries; each (path,size,mtime) is stored once and linked to every source that has it."""
    def __init__(self, db, sid):
        self.db, self.sid, self.n = db, sid, 0
    def add(self, path, size, mtime, kind):
        name = path.rsplit("/", 1)[-1]
        row = self.db.execute(
            "INSERT INTO entries(path,name,size,mtime,kind) VALUES(?,?,?,?,?) "
            "ON CONFLICT(path,size,mtime) DO UPDATE SET kind=excluded.kind RETURNING id",
            (path, name, size, mtime, kind)).fetchone()
        self.db.execute("INSERT OR IGNORE INTO entry_sources VALUES(?,?)", (row[0], self.sid))
        self.n += 1
        if self.n % 50000 == 0:
            self.db.commit()

def mount_points_under(root):
    out = set()
    try:
        for line in open("/proc/self/mountinfo"):
            mp = line.split()[4].replace("\\040", " ")
            if mp.startswith(root + "/") or mp == root:
                out.add(mp)
    except OSError:
        pass
    return out

def build_local(db, roots):
    mounts = set()
    for r in roots:
        mounts |= mount_points_under(r)
    excl = set(C.get("exclude_names", []))
    sid = source_id(db, "live:local", "live", time.strftime("%Y-%m-%dT%H:%M:%S"))
    w = Writer(db, sid)
    t0 = time.time()
    stack = [os.path.expanduser(r) for r in roots]
    skipped_mounts = 0
    while stack:
        d = stack.pop()
        try:
            it = os.scandir(d)
        except OSError:
            continue
        with it:
            for e in it:
                p = e.path
                rel = os.path.relpath(p, HOME)
                if rel in excl or p in mounts:
                    if p in mounts: skipped_mounts += 1
                    continue
                try:
                    st = e.stat(follow_symlinks=False)
                except OSError:
                    continue
                if e.is_dir(follow_symlinks=False):
                    w.add(p, None, int(st.st_mtime), "dir")
                    stack.append(p)
                elif e.is_symlink():
                    w.add(p, 0, int(st.st_mtime), "link")
                else:
                    w.add(p, st.st_size, int(st.st_mtime), "file")
    db.commit()
    print(f"local: {w.n} rows, {skipped_mounts} mount points skipped, {time.time()-t0:.1f}s", file=sys.stderr)

def build_rclone(db):
    for r in C.get("rclone", []):
        remote, mount = r["remote"], os.path.expanduser(r["mount"])
        sid = source_id(db, f"live:rclone:{remote}", "live", time.strftime("%Y-%m-%dT%H:%M:%S"))
        w = Writer(db, sid)
        t0 = time.time()
        out = subprocess.run(["rclone", "lsjson", "-R", "--files-only", remote],
                             capture_output=True, text=True, check=True).stdout
        for e in json.loads(out):
            mt = e.get("ModTime", "")
            try:
                ts = int(time.mktime(time.strptime(mt[:19], "%Y-%m-%dT%H:%M:%S")))
            except ValueError:
                ts = None
            w.add(f"{mount}/{e['Path']}", int(e.get("Size", 0)), ts, "file")
        db.commit()
        print(f"rclone {remote}: {w.n} rows, {time.time()-t0:.1f}s", file=sys.stderr)

def restic_snapshots(rep):
    pw = os.path.expanduser(rep["password_file"])
    cmd = ["restic", "--no-lock", "--repo", rep["repo"], "--password-file", pw]
    out = subprocess.run(cmd + ["snapshots", "--json"], capture_output=True, text=True, check=True).stdout
    return cmd, json.loads(out)

def build_restic(db, which):
    for rep in C.get("restic", []):
        cmd, snaps = restic_snapshots(rep)
        if which == "latest":
            snaps = snaps[-1:]
        for s in snaps:
            label = f"restic:{rep['name']}:{s['short_id']}"
            if db.execute("SELECT 1 FROM sources WHERE label=?", (label,)).fetchone():
                continue                       # already catalogued
            t0 = time.time()
            sid = source_id(db, label, "restic", s["time"][:19])
            w = Writer(db, sid)
            out = subprocess.run(cmd + ["ls", "--json", s["short_id"]],
                                 capture_output=True, text=True, check=True).stdout
            for line in out.splitlines():
                r = json.loads(line)
                if r.get("struct_type") != "node":
                    continue
                t = r.get("type")
                if t not in ("file", "dir", "symlink"):
                    continue
                mt = r.get("mtime", "")
                try:
                    ts = int(time.mktime(time.strptime(mt[:19], "%Y-%m-%dT%H:%M:%S")))
                except ValueError:
                    ts = None
                w.add(r["path"], r.get("size") if t == "file" else None, ts,
                      {"file": "file", "dir": "dir", "symlink": "link"}[t])
            db.commit()
            print(f"{label}: {w.n} rows, {time.time()-t0:.1f}s", file=sys.stderr)

def rebuild_fts(db):
    t0 = time.time()
    db.execute("INSERT INTO names(names) VALUES('rebuild')")
    db.commit()
    print(f"fts rebuilt in {time.time()-t0:.1f}s", file=sys.stderr)

def find(db, text, limit, source=None, size=None, dm=None):
    where, args = [], []
    if len(text) >= 3:
        sql = ("SELECT e.path, e.size, e.mtime, e.kind FROM names JOIN entries e ON e.id = names.rowid "
               "WHERE names MATCH ?")
        args.append('"' + text.replace('"', '""') + '"')
    else:
        sql = "SELECT e.path, e.size, e.mtime, e.kind FROM entries e WHERE e.name LIKE ?"
        args.append(f"%{text}%")
    if size:
        m = re.match(r"^([<>])\s*([0-9.]+)\s*([KMG]?)$", size.strip(), re.I)
        mult = {"": 1, "K": 1024, "M": 1024**2, "G": 1024**3}[m.group(3).upper()]
        where.append(f"e.size {m.group(1)} ?")
        args.append(float(m.group(2)) * mult)
    if source:
        where.append("e.id IN (SELECT entry_id FROM entry_sources JOIN sources s ON s.id = source_id WHERE s.label LIKE ?)")
        args.append(f"%{source}%")
    if where:
        sql += " AND " + " AND ".join(where)
    sql += f" LIMIT {int(limit)}"
    return db.execute(sql, args).fetchall()

def main():
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("build-local")
    sub.add_parser("build-rclone")
    b = sub.add_parser("build-restic"); b.add_argument("--all", action="store_true")
    sub.add_parser("rebuild-fts")
    sub.add_parser("stats")
    f = sub.add_parser("find"); f.add_argument("text"); f.add_argument("--limit", type=int, default=50)
    f.add_argument("--source"); f.add_argument("--size"); f.add_argument("--dm")
    a = ap.parse_args()
    db = connect()
    if a.cmd == "build-local":
        build_local(db, C["local_roots"]); rebuild_fts(db)
    elif a.cmd == "build-rclone":
        build_rclone(db); rebuild_fts(db)
    elif a.cmd == "build-restic":
        build_restic(db, "all" if a.all else "latest"); rebuild_fts(db)
    elif a.cmd == "rebuild-fts":
        rebuild_fts(db)
    elif a.cmd == "stats":
        print("entries:", db.execute("SELECT count(*) FROM entries").fetchone()[0])
        for label, n in db.execute("SELECT s.label, count(*) FROM entry_sources es JOIN sources s ON s.id=es.source_id GROUP BY s.label ORDER BY s.label"):
            print(f"  {n:>9}  {label}")
    elif a.cmd == "find":
        for path, size, mt, kind in find(db, a.text, a.limit, a.source, a.size, a.dm):
            print(f"{size if size is not None else '-':>12}  {path}")

if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""Restic snapshot index, kept apart from the main catalog (catalog-restic.db).

Every distinct version of a path (path, size, date) is stored ONCE, with the range of snapshots that contain it
(first_snap .. last_snap, last_snap NULL = still in the newest snapshot). A new snapshot is ingested by streaming
its listing and comparing it with the versions that are still open: unchanged ones cost nothing (their range
stays open), only new and vanished versions are written. So the size grows with what CHANGES, not with
snapshots x files.

The search server loads one row per path (its newest version) into a separate in-memory table, only when a query
asks for restic backups (/show-backup-restic). Rows carry the path under the restic FUSE mount, so they open,
copy and preview like any file:  <mount>/ids/<short id><original path>

    restic_store.py migrate [--drop-old]   build the store from the snapshot listings already in catalog.db
    restic_store.py build                  ingest snapshots newer than the newest one stored (what build-restic runs)
    restic_store.py stats
"""
import json, os, sqlite3, subprocess, sys, time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))) + "/photos")
import config

C = config.CFG["catalog"]
MAIN_DB = os.path.expanduser(os.environ.get("CATALOG_DB") or C["db"])
RESTIC_DB = os.path.join(os.path.dirname(MAIN_DB), "catalog-restic.db")

SCHEMA = """
CREATE TABLE IF NOT EXISTS snapshots(
  id INTEGER PRIMARY KEY,
  rid TEXT,
  short TEXT UNIQUE NOT NULL,
  taken TEXT NOT NULL,
  alive INTEGER NOT NULL DEFAULT 1,
  nrows INTEGER
);
CREATE TABLE IF NOT EXISTS versions(
  id INTEGER PRIMARY KEY,
  path TEXT NOT NULL,
  size INTEGER,
  mtime INTEGER,
  kind TEXT NOT NULL,
  first_snap INTEGER NOT NULL,
  last_snap INTEGER
);
CREATE INDEX IF NOT EXISTS versions_path ON versions(path);
CREATE INDEX IF NOT EXISTS versions_open ON versions(path) WHERE last_snap IS NULL;
"""

def log(*a):
    print(*a, file=sys.stderr, flush=True)

def connect(path=RESTIC_DB):
    db = sqlite3.connect(path)
    db.executescript(SCHEMA)
    db.execute("PRAGMA journal_mode=WAL")
    db.execute("PRAGMA synchronous=NORMAL")
    db.execute("PRAGMA busy_timeout=120000")
    return db

def touch_generation(path=RESTIC_DB):
    """The search server reloads its restic table when this file's time changes."""
    with open(path + ".gen", "a"):
        os.utime(path + ".gen", None)

def repo():
    reps = C.get("restic", [])
    if not reps:
        sys.exit("no restic repository in the catalog config")
    return reps[0]

def mount_dir(rep=None):
    rep = rep or repo()
    return rep.get("mount") or f"/mnt/backup-restic-{rep['name']}"

def excluded_prefixes():
    """Paths whose history is not kept (caches that are rewritten on every snapshot)."""
    return tuple(os.path.expanduser(p).rstrip("/") + "/" for p in C.get("restic_exclude", []))

def open_versions(db):
    """path -> (size, mtime, id) of the versions still present in the newest snapshot."""
    return {p: (s, m, i) for i, p, s, m in db.execute("SELECT id, path, size, mtime FROM versions WHERE last_snap IS NULL")}

def ingest(db, snap_id, prev_id, rows, exclude, open_):
    """Apply one snapshot listing (rows of path, size, mtime, kind). Returns (added, closed, kept)."""
    seen, close, added, kept = set(), [], 0, 0
    ins = "INSERT INTO versions(path, size, mtime, kind, first_snap) VALUES(?,?,?,?,?)"
    for path, size, mtime, kind in rows:
        if exclude and (path + "/").startswith(exclude):
            continue
        o = open_.get(path)
        if o is not None and o[0] == size and o[1] == mtime:
            seen.add(o[2])
            kept += 1
            continue
        if o is not None:
            close.append(o[2])                   # the path changed: its old version ends with the previous snapshot
        vid = db.execute(ins, (path, size, mtime, kind, snap_id)).lastrowid
        open_[path] = (size, mtime, vid)
        seen.add(vid)
        added += 1
    for path in [p for p, (_, _, vid) in open_.items() if vid not in seen]:
        close.append(open_.pop(path)[2])         # no longer in this snapshot
    if close and prev_id is not None:
        db.executemany("UPDATE versions SET last_snap=? WHERE id=?", ((prev_id, i) for i in close))
    return added, len(close), kept

def restic_cmd(rep):
    return ["restic", "--no-lock", "--repo", rep["repo"], "--password-file", os.path.expanduser(rep["password_file"])]

def mtime_of(text):
    try:
        return int(time.mktime(time.strptime(text[:19], "%Y-%m-%dT%H:%M:%S")))
    except ValueError:
        return None

def listing_rows(rep, short):
    """Stream 'restic ls --json' of one snapshot as (path, size, mtime, kind); the listing is GBs, never held."""
    proc = subprocess.Popen(restic_cmd(rep) + ["ls", "--json", short], stdout=subprocess.PIPE, text=True)
    kinds = {"file": "file", "dir": "dir", "symlink": "link"}
    for line in proc.stdout:
        r = json.loads(line)
        if r.get("struct_type") != "node" or r.get("type") not in kinds:
            continue
        t = r["type"]
        yield r["path"], (r.get("size") if t == "file" else None), mtime_of(r.get("mtime", "")), kinds[t]
    if proc.wait() != 0:
        raise RuntimeError(f"restic ls failed for snapshot {short}")

def sync_snapshots(db, rep):
    """Record the repository's snapshot list: ids, and which ones still exist (alive)."""
    out = subprocess.run(restic_cmd(rep) + ["snapshots", "--json"], capture_output=True, text=True, check=True).stdout
    snaps = sorted(json.loads(out), key=lambda s: s["time"])
    present = {s["short_id"] for s in snaps}
    for s in snaps:
        db.execute("UPDATE snapshots SET rid=?, alive=1 WHERE short=?", (s["id"], s["short_id"]))
    for (short,) in db.execute("SELECT short FROM snapshots").fetchall():
        if short not in present:
            db.execute("UPDATE snapshots SET alive=0 WHERE short=?", (short,))
    db.commit()
    return snaps

def build(db=None):
    """Ingest the snapshots newer than the newest one stored; mark forgotten ones; tell the server."""
    rep = repo()
    db = db or connect()
    snaps = sync_snapshots(db, rep)
    newest = db.execute("SELECT max(taken) FROM snapshots").fetchone()[0] or ""
    exclude = excluded_prefixes()
    todo = [s for s in snaps if s["time"][:19] > newest[:19]]
    if not todo:
        log("restic: nothing new")
    for s in todo:
        t0 = time.time()
        prev = db.execute("SELECT max(id) FROM snapshots").fetchone()[0]
        sid = db.execute("INSERT INTO snapshots(rid, short, taken) VALUES(?,?,?)", (s["id"], s["short_id"], s["time"][:19])).lastrowid
        try:
            added, closed, kept = ingest(db, sid, prev, listing_rows(rep, s["short_id"]), exclude, open_versions(db))
            db.execute("UPDATE snapshots SET nrows=? WHERE id=?", (added + kept, sid))
            db.commit()
        except BaseException:
            db.rollback()
            raise
        log(f"restic {s['short_id']} ({s['time'][:19]}): +{added} new versions, {closed} ended, {kept} unchanged, {time.time()-t0:.0f}s")
    touch_generation()

def migrate(drop_old):
    """Build the store from the restic snapshot listings the main catalog already holds (no restic calls for the
    history). A listing far smaller than its neighbours is an interrupted one and is skipped."""
    main = sqlite3.connect(f"file:{MAIN_DB}?mode=ro", uri=True) if not drop_old else sqlite3.connect(MAIN_DB)
    srcs = main.execute("""SELECT s.id, s.label, s.taken, (SELECT count(*) FROM entry_sources es WHERE es.source_id=s.id)
                           FROM sources s WHERE s.kind='restic' ORDER BY s.taken""").fetchall()
    sizes = sorted(n for *_, n in srcs)
    median = sizes[len(sizes) // 2] if sizes else 0
    db = connect()
    if db.execute("SELECT count(*) FROM snapshots").fetchone()[0]:
        sys.exit("catalog-restic.db already has snapshots; migrate only fills an empty store")
    exclude = excluded_prefixes()
    prev, open_ = None, {}
    for sid_main, label, taken, n in srcs:
        short = label.rsplit(":", 1)[1]
        if n < median * 0.8:
            log(f"skipping {label}: only {n:,} rows (interrupted listing)")
            continue
        t0 = time.time()
        sid = db.execute("INSERT INTO snapshots(short, taken) VALUES(?,?)", (short, taken[:19])).lastrowid
        rows = main.execute("SELECT e.path, e.size, e.mtime, e.kind FROM entries e JOIN entry_sources es ON es.entry_id=e.id "
                            "WHERE es.source_id=?", (sid_main,))
        added, closed, kept = ingest(db, sid, prev, rows, exclude, open_)
        db.execute("UPDATE snapshots SET nrows=? WHERE id=?", (added + kept, sid))
        db.commit()
        prev = sid
        log(f"{label}: +{added:,} new versions, {closed:,} ended, {kept:,} unchanged ({time.time()-t0:.0f}s)")
    build(db)                                   # fills the full ids, marks forgotten snapshots, adds newer ones
    if drop_old:
        # chunked, so the live watchers (which share the main database's writer lock) are never held up for long
        main.execute("PRAGMA busy_timeout=120000")
        ids = [r[0] for r in main.execute("SELECT id FROM sources WHERE kind='restic'")]
        for i in ids:
            main.execute("DELETE FROM entry_sources WHERE source_id=?", (i,))
            main.commit()
        main.execute("DELETE FROM sources WHERE kind='restic'")
        main.commit()
        lo, hi = main.execute("SELECT min(id), max(id) FROM entries").fetchone()
        gone, step = 0, 200000
        for a in range(lo or 0, (hi or 0) + 1, step):
            cur = main.execute("DELETE FROM entries WHERE id>=? AND id<? AND id NOT IN (SELECT entry_id FROM entry_sources)", (a, a + step))
            gone += cur.rowcount
            main.commit()
        log(f"removed {len(ids)} restic sources and {gone:,} entries only they held from the main catalog (VACUUM gives the space back)")
        touch_main_generation()

def touch_main_generation():
    with open(MAIN_DB + ".gen", "a"):
        os.utime(MAIN_DB + ".gen", None)

def server_rows(db_path=RESTIC_DB):
    """(rows sorted by path, []) for the search server: one row per path, its newest retrievable version, with the
    path under the restic mount. A version is retrievable through the newest existing snapshot in its range."""
    db = sqlite3.connect(f"file:{db_path}?mode=ro", uri=True)
    alive = [r[0] for r in db.execute("SELECT id FROM snapshots WHERE alive=1 ORDER BY id")]
    short = dict(db.execute("SELECT id, short FROM snapshots"))
    if not alive:
        return [], []
    mount = mount_dir() + "/ids/"
    import bisect
    best = {}
    for path, size, mtime, first, last in db.execute("SELECT path, size, mtime, first_snap, last_snap FROM versions"):
        hi = alive[-1] if last is None else last
        k = bisect.bisect_right(alive, hi) - 1            # newest alive snapshot <= hi
        if k < 0 or alive[k] < first:
            continue                                       # every snapshot holding this version was forgotten
        snap = alive[k]
        cur = best.get(path)
        if cur is None or (snap, mtime or 0) > (cur[0], cur[2] or 0):
            best[path] = (snap, size, mtime)
    rows = sorted((mount + short[snap] + path, size, mtime) for path, (snap, size, mtime) in best.items())
    return rows, []

def stats():
    db = connect()
    n_snap, alive = db.execute("SELECT count(*), sum(alive) FROM snapshots").fetchone()
    n_ver = db.execute("SELECT count(*) FROM versions").fetchone()[0]
    n_open = db.execute("SELECT count(*) FROM versions WHERE last_snap IS NULL").fetchone()[0]
    n_paths = db.execute("SELECT count(DISTINCT path) FROM versions").fetchone()[0]
    print(f"snapshots: {n_snap} ({alive} still in the repository)")
    print(f"versions stored: {n_ver:,} (present in the newest snapshot: {n_open:,}); distinct paths: {n_paths:,}")
    print(f"database: {os.path.getsize(RESTIC_DB)/1e6:.0f} MB at {RESTIC_DB}")

if __name__ == "__main__":
    cmd = sys.argv[1] if len(sys.argv) > 1 else ""
    if cmd == "migrate":
        migrate("--drop-old" in sys.argv)
    elif cmd == "build":
        build()
    elif cmd == "stats":
        stats()
    else:
        print(__doc__)

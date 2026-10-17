#!/usr/bin/env python3
"""btrfs (snapper) snapshot index, kept apart from the main catalog (catalog-btrfs.db). Same idea as restic_store.py:
every distinct version of a path (path, size, date) is stored once with the range of snapshots that contain it,
per snapper config (root, home, ...), so the size follows what CHANGES, not snapshots x files.

Snapshots are plain read-only folders (<subvolume>/.snapshots/<n>/snapshot), readable by the user, so nothing here
needs privileges: a snapshot is walked like any folder. The search server shows one row per path (its newest
version) under the real snapshot path, which opens, copies and previews like any file; the table is only loaded
when a query asks for it (/show-backup-btrfs).

    btrfs_store.py build     ingest the snapshots not stored yet, mark vanished ones (what build-btrfs runs)
    btrfs_store.py stats
"""
import bisect, json, os, re, sqlite3, subprocess, sys, time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import restic_store as R

C = R.C
BTRFS_DB = os.path.join(os.path.dirname(R.MAIN_DB), "catalog-btrfs.db")
HOME = os.path.expanduser("~")

SCHEMA = """
CREATE TABLE IF NOT EXISTS snapshots(
  id INTEGER PRIMARY KEY,
  config TEXT NOT NULL,
  num INTEGER NOT NULL,
  taken TEXT,
  alive INTEGER NOT NULL DEFAULT 1,
  nrows INTEGER,
  UNIQUE(config, num)
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

def connect(path=BTRFS_DB):
    db = sqlite3.connect(path)
    db.executescript(SCHEMA)
    db.execute("PRAGMA journal_mode=WAL")
    db.execute("PRAGMA synchronous=NORMAL")
    db.execute("PRAGMA busy_timeout=120000")
    return db

def configs():
    """[(snapper config, subvolume path)] from snapper (works as a normal user)."""
    out = subprocess.run(["snapper", "--jsonout", "list-configs"], capture_output=True, text=True, check=True).stdout
    return [(c["config"], c["subvolume"]) for c in json.loads(out)["configs"]]

def snapshot_dirs(subvol):
    """{number: path of the snapshot's files} for the snapshots present on disk."""
    base = os.path.join(subvol, ".snapshots")
    out = {}
    try:
        names = os.listdir(base)
    except OSError:
        return out
    for n in names:
        p = os.path.join(base, n, "snapshot")
        if n.isdigit() and os.path.isdir(p):
            out[int(n)] = p
    return out

def taken(subvol, num):
    try:
        text = open(os.path.join(subvol, ".snapshots", str(num), "info.xml")).read()
        m = re.search(r"<date>([^<]+)</date>", text)
        return m.group(1).strip().replace(" ", "T") if m else None
    except OSError:
        return None

def skipper():
    excl = set(C.get("exclude_names", []))            # relative to $HOME, as in the local walk
    anywhere = set(C.get("exclude_anywhere", []))
    abs_paths = [os.path.expanduser(x).rstrip("/") for x in C.get("exclude_paths", [])]
    def skip(path, name):
        if name in anywhere:
            return True
        if path.startswith(HOME + "/") and os.path.relpath(path, HOME) in excl:
            return True
        return any(path == x for x in abs_paths)
    return skip

def walk_rows(snap_root, subvol):
    """(original path, size, mtime, kind) for everything in one snapshot, with the paths the files have on the live
    system (a snapshot of /home holds /home/user1/x as <snap>/user1/x)."""
    skip = skipper()
    prefix = subvol.rstrip("/")
    stack = [snap_root]
    while stack:
        d = stack.pop()
        try:
            it = os.scandir(d)
        except OSError:
            continue
        with it:
            for e in it:
                orig = prefix + e.path[len(snap_root):]
                if skip(orig, e.name):
                    continue
                try:
                    st = e.stat(follow_symlinks=False)
                    if e.is_dir(follow_symlinks=False):
                        yield orig, None, int(st.st_mtime), "dir"
                        stack.append(e.path)
                    elif e.is_symlink():
                        yield orig, 0, int(st.st_mtime), "link"
                    else:
                        yield orig, st.st_size, int(st.st_mtime), "file"
                except OSError:
                    pass

def build(db=None):
    db = db or connect()
    exclude = R.excluded_prefixes()
    for config, subvol in configs():
        on_disk = snapshot_dirs(subvol)
        known = {n: (i, a) for i, n, a in db.execute("SELECT id, num, alive FROM snapshots WHERE config=?", (config,))}
        for n, (i, a) in known.items():                              # snapper cleaned it up
            if n not in on_disk and a:
                db.execute("UPDATE snapshots SET alive=0 WHERE id=?", (i,))
        db.commit()
        newest = max(known, default=-1)
        todo = sorted(n for n in on_disk if n not in known and n > newest)
        if not todo:
            log(f"{config}: nothing new ({len(on_disk)} snapshots on disk)")
            continue
        open_ = {p: (s, m, i) for i, p, s, m in db.execute(
            "SELECT v.id, v.path, v.size, v.mtime FROM versions v JOIN snapshots s ON s.id=v.first_snap "
            "WHERE v.last_snap IS NULL AND s.config=?", (config,))}
        prev = db.execute("SELECT max(id) FROM snapshots WHERE config=?", (config,)).fetchone()[0]
        for n in todo:
            t0 = time.time()
            sid = db.execute("INSERT INTO snapshots(config, num, taken) VALUES(?,?,?)", (config, n, taken(subvol, n))).lastrowid
            try:
                added, closed, kept = R.ingest(db, sid, prev, walk_rows(on_disk[n], subvol), exclude, open_)
                if not os.path.isdir(on_disk[n]):
                    raise RuntimeError(f"snapshot {config}#{n} vanished while it was being read")
                db.execute("UPDATE snapshots SET nrows=? WHERE id=?", (added + kept, sid))
                db.commit()
            except BaseException:
                db.rollback()
                open_ = {p: (s, m, i) for i, p, s, m in db.execute(
                    "SELECT v.id, v.path, v.size, v.mtime FROM versions v JOIN snapshots s ON s.id=v.first_snap "
                    "WHERE v.last_snap IS NULL AND s.config=?", (config,))}
                log(f"{config}#{n} skipped (will be retried)")
                continue
            prev = sid
            log(f"{config}#{n}: +{added:,} new versions, {closed:,} ended, {kept:,} unchanged ({time.time()-t0:.0f}s)")
    R.touch_generation(BTRFS_DB)

def server_rows(db_path=BTRFS_DB):
    """(rows sorted by path, []): one row per path, its newest retrievable version, at its real snapshot path."""
    db = sqlite3.connect(f"file:{db_path}?mode=ro", uri=True)
    subvols = dict(configs())
    snap = {i: (c, n) for i, c, n in db.execute("SELECT id, config, num FROM snapshots")}
    alive = {}
    for i, c, n in db.execute("SELECT id, config, num FROM snapshots WHERE alive=1 ORDER BY id"):
        alive.setdefault(c, []).append(i)
    best = {}
    for path, size, mtime, first, last in db.execute("SELECT path, size, mtime, first_snap, last_snap FROM versions"):
        config = snap[first][0]
        ids = alive.get(config)
        if not ids:
            continue
        hi = ids[-1] if last is None else last
        k = bisect.bisect_right(ids, hi) - 1
        if k < 0 or ids[k] < first:
            continue
        s = ids[k]
        cur = best.get(path)
        if cur is None or (s, mtime or 0) > (cur[0], cur[2] or 0):
            best[path] = (s, size, mtime)
    rows = []
    for path, (s, size, mtime) in best.items():
        config, num = snap[s]
        subvol = subvols[config].rstrip("/")
        rows.append((f"{subvol}/.snapshots/{num}/snapshot{path[len(subvol):]}", size, mtime))
    rows.sort()
    return rows, []

def stats():
    db = connect()
    per = db.execute("SELECT config, count(*), sum(alive) FROM snapshots GROUP BY config").fetchall()
    print("snapshots:", ", ".join(f"{c}: {n} ({a} on disk)" for c, n, a in per))
    n_ver = db.execute("SELECT count(*) FROM versions").fetchone()[0]
    n_open = db.execute("SELECT count(*) FROM versions WHERE last_snap IS NULL").fetchone()[0]
    print(f"versions stored: {n_ver:,} (in the newest snapshots: {n_open:,})")
    print(f"database: {os.path.getsize(BTRFS_DB)/1e6:.0f} MB at {BTRFS_DB}")

if __name__ == "__main__":
    cmd = sys.argv[1] if len(sys.argv) > 1 else ""
    if cmd == "build":
        build()
    elif cmd == "stats":
        stats()
    else:
        print(__doc__)

#!/usr/bin/env python3
"""Personal file catalog: one SQLite database over $HOME, the rclone remotes and
the restic snapshots, deduplicated by (path, size, mtime).

  build-local      walk the local roots (skips mount points, excluded names)
  build-extra      walk the extra_roots (NFS shares outside $HOME)
  build-rclone     list each rclone remote through its API (no FUSE walk)
  build-restic     ingest new restic snapshots into catalog-restic.db (see restic_store.py)
  build-btrfs      ingest new snapper snapshots into catalog-btrfs.db (see btrfs_store.py)
  find TEXT        substring search over file names (scans the entries table), optional filters
  stats            counts per source

Settings: "catalog" section of ~/.config/indexes/photos.json (private).
"""
import argparse, json, os, re, shlex, sqlite3, subprocess, sys, time, urllib.parse, urllib.request
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))) + "/photos")
import config
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import index_dirs
C = config.CFG["catalog"]


def _nfs_fts_roots(cfg):
    """host1 directories chosen for content (full-text) indexing that no extra root covers yet: path search must reach every
    path whose contents are searchable. Read from the Recoll topdirs of every index in fts.indexes and from the paths of
    collections.json; only directories under the NFS mount of host1's backups are added (the rest is walked locally or via rclone)."""
    import shlex
    local, remote, host = "/mnt/host1-backups", "/home/user1/backups", "host1"
    cands = []
    try:
        for ix in config.CFG.get("fts", {}).get("indexes", []):
            conf = os.path.join(os.path.expanduser(ix), "recoll.conf")
            for line in open(conf):
                if line.startswith("topdirs"):
                    cands += shlex.split(line.split("=", 1)[1])
    except OSError:
        pass
    try:
        for e in json.load(open(os.path.expanduser("~/.config/indexes/collections.json"))).get("paths", []):
            cands.append(e["path"] if isinstance(e, dict) else e)
    except (OSError, ValueError, KeyError):
        pass
    have = [r["root"].rstrip("/") for r in cfg.get("extra_roots", [])]
    out = []
    for c in cands:
        c = os.path.normpath(os.path.expanduser(c))
        if not c.startswith(local + "/") or any(c == h or c.startswith(h + "/") for h in have + [o["root"] for o in out]):
            continue
        if os.path.isdir(c):
            out = [o for o in out if not o["root"].startswith(c + "/")]      # a parent replaces children added before
            out.append({"root": c, "ssh": host, "remote_root": remote + c[len(local):]})
    return out

C["extra_roots"] = list(C.get("extra_roots", [])) + _nfs_fts_roots(C)
DB = os.environ.get("CATALOG_DB") or C["db"]
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
CREATE TABLE IF NOT EXISTS drive_dirs(fid TEXT PRIMARY KEY, path TEXT NOT NULL) WITHOUT ROWID;
CREATE INDEX IF NOT EXISTS drive_dirs_by_path ON drive_dirs(path);
CREATE TABLE IF NOT EXISTS drive_files(fid TEXT PRIMARY KEY, dir_fid TEXT NOT NULL) WITHOUT ROWID;
CREATE INDEX IF NOT EXISTS drive_files_by_dir ON drive_files(dir_fid);
"""

def connect():
    os.makedirs(os.path.dirname(os.path.expanduser(DB)), exist_ok=True)
    db = sqlite3.connect(os.path.expanduser(DB))
    db.executescript(SCHEMA)
    db.execute("PRAGMA journal_mode=WAL")
    db.execute("PRAGMA synchronous=NORMAL")
    db.execute("PRAGMA busy_timeout=120000")     # the watcher and the periodic jobs share one writer lock
    return db

def source_id(db, label, kind, taken=None):
    db.execute("INSERT OR IGNORE INTO sources(label, kind, taken) VALUES(?,?,?)", (label, kind, taken))
    return db.execute("SELECT id FROM sources WHERE label=?", (label,)).fetchone()[0]

def sweep(db, sid):
    """After a full re-walk of a live source: drop what it no longer has (deleted files, old
    versions of changed ones), then entries nothing links to any more. One commit, so readers
    see either the old or the new state, never half."""
    db.execute("DELETE FROM entry_sources WHERE source_id=? AND entry_id NOT IN (SELECT id FROM seen)", (sid,))
    db.execute("DELETE FROM entries WHERE id NOT IN (SELECT entry_id FROM entry_sources)")
    db.commit()

def touch_generation():
    """Tell the search server to reload the whole catalog (full builds do this when they finish)."""
    path = os.path.expanduser(DB) + ".gen"
    with open(path, "a"):
        os.utime(path, None)

def push_ops(ops):
    """Send live changes to the search server (POST /delta). False if it could not take them."""
    try:
        token = open(os.path.expanduser(DB) + ".delta-token").read().strip()
    except OSError:
        return False
    url = f"http://127.0.0.1:{config.SERVER_PORT}/delta"
    for i in range(0, len(ops), 20000):
        body = json.dumps({"ops": ops[i:i + 20000]}).encode()
        req = urllib.request.Request(url, data=body, headers={"X-Delta-Token": token, "Content-Type": "application/json"})
        try:
            urllib.request.urlopen(req, timeout=60).read()
        except Exception:
            return False
    return True

def final_ops(db, paths):
    """What the catalog now holds for each path, as server ops: the newest version, or a delete. This is exactly
    what a full reload would show, including paths that only a backup snapshot still has."""
    ops = []
    for p in paths:
        r = db.execute("SELECT size, mtime FROM entries WHERE path=? ORDER BY mtime DESC LIMIT 1", (p,)).fetchone()
        ops.append(["put", p, r[0], r[1]] if r else ["del", p])
    return ops

def deliver(db, paths):
    """Commit has happened: tell the running search server about these paths, or make it reload if that fails."""
    if not paths:
        return
    if len(paths) > 200000 or not push_ops(final_ops(db, paths)):
        touch_generation()

class SourceStore:
    """Row-level changes to one source's entries, remembering which paths changed (touched) so they can be delivered to the search server."""
    def __init__(self, db, sid):
        self.db, self.sid = db, sid
        self.touched = set()
        self.added = self.removed = 0

    def drop(self, ids):
        """Unlink entries from this source; delete those no other source has."""
        if not ids:
            return
        self.removed += len(ids)
        for i in range(0, len(ids), 500):
            part = ids[i:i + 500]
            q = ",".join("?" * len(part))
            self.touched.update(r[0] for r in self.db.execute(f"SELECT path FROM entries WHERE id IN ({q})", part))
            self.db.execute(f"DELETE FROM entry_sources WHERE source_id=? AND entry_id IN ({q})", [self.sid] + part)
            self.db.execute(
                f"DELETE FROM entries WHERE id IN ({q}) AND id NOT IN (SELECT entry_id FROM entry_sources)", part)

    def add(self, path, size, mtime, kind="file"):
        row = self.db.execute("SELECT id FROM entries WHERE path=? AND size IS ? AND mtime IS ?", (path, size, mtime)).fetchone()
        if row:
            eid = row[0]
        else:
            name = path.rsplit("/", 1)[-1]
            eid = self.db.execute("INSERT INTO entries(path,name,size,mtime,kind) VALUES(?,?,?,?,?)",
                                  (path, name, size, mtime, kind)).lastrowid
        self.db.execute("INSERT OR IGNORE INTO entry_sources VALUES(?,?)", (eid, self.sid))
        self.touched.add(path)
        self.added += 1

class Writer:
    """Batches entries; each (path,size,mtime) is stored once and linked to every source that has it."""
    def __init__(self, db, sid):
        self.db, self.sid, self.n = db, sid, 0
        db.execute("CREATE TEMP TABLE IF NOT EXISTS seen(id INTEGER PRIMARY KEY)")
        db.execute("DELETE FROM seen")
    def add(self, path, size, mtime, kind):
        name = path.rsplit("/", 1)[-1]
        row = self.db.execute(
            "INSERT INTO entries(path,name,size,mtime,kind) VALUES(?,?,?,?,?) "
            "ON CONFLICT(path,size,mtime) DO UPDATE SET kind=excluded.kind RETURNING id",
            (path, name, size, mtime, kind)).fetchone()
        self.db.execute("INSERT OR IGNORE INTO entry_sources VALUES(?,?)", (row[0], self.sid))
        self.db.execute("INSERT OR IGNORE INTO seen VALUES(?)", (row[0],))
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

REAL_FS = {"btrfs", "ext2", "ext3", "ext4", "xfs", "vfat", "exfat", "f2fs", "ntfs", "ntfs3", "zfs", "bcachefs"}

def mount_info():
    """{mount point: filesystem type} from /proc/self/mountinfo."""
    out = {}
    try:
        for line in open("/proc/self/mountinfo"):
            parts = line.split()
            out[parts[4].replace("\\040", " ")] = parts[parts.index("-") + 1]
    except OSError:
        pass
    return out

def skipped_paths(roots):
    """Directories the local walk must not enter. Under $HOME every mount point is skipped (the separate
    subvolumes ~/src ~/temp ~/qemu ~/.cache, rclone mounts, ...). Under any other root only mounts that are
    not real local filesystems are skipped (proc, sys, tmpfs, FUSE, NFS, autofs, ...), so system subvolumes
    such as /var are walked. $HOME is walked as its own root, and "exclude_paths" adds absolute paths."""
    minfo = mount_info()
    skip = {HOME}
    for r in roots:
        r = os.path.expanduser(r).rstrip("/") or "/"
        under = lambda mp: mp == r or r == "/" or mp.startswith(r + "/")
        if r == HOME:
            skip |= mount_points_under(r)
        else:
            skip |= {mp for mp, fs in minfo.items() if under(mp) and mp != "/" and fs not in REAL_FS}
    skip |= {os.path.expanduser(x) for x in C.get("exclude_paths", [])}
    return skip

def build_local(db, roots):
    """Incremental walk of the live local roots. Entries whose (path, size, mtime) are unchanged since
    the last walk are only marked as seen in memory (no SQL); new or changed ones are inserted and added
    vanished ones are unlinked and, when no other source has them, deleted from the entries table. One
    commit at the end, so readers see the old or the new state, never half."""
    mounts = skipped_paths(roots)
    excl = set(C.get("exclude_names", []))          # relative to $HOME
    anywhere = set(C.get("exclude_anywhere", []))   # directory/file names skipped wherever they occur (e.g. .snapshots)
    sid = source_id(db, "live:local", "live", time.strftime("%Y-%m-%dT%H:%M:%S"))
    t0 = time.time()
    # what this source had last time: path -> (size, mtime, id)
    known = {}
    for path, size, mtime, eid in db.execute(
            "SELECT e.path, e.size, e.mtime, e.id FROM entries e JOIN entry_sources es ON es.entry_id = e.id "
            "WHERE es.source_id = ?", (sid,)):
        known.setdefault(path, []).append((size, mtime, eid))
    seen = set()
    added = changed = 0
    touched = set()

    def note(path, size, mtime, kind):
        nonlocal added, changed
        hit = known.get(path)
        if hit:
            for sz, mt, eid in hit:
                if sz == size and mt == mtime:
                    seen.add(eid)
                    return
            changed += 1
        else:
            added += 1
        touched.add(path)
        row = db.execute("SELECT id FROM entries WHERE path=? AND size IS ? AND mtime IS ?", (path, size, mtime)).fetchone()
        if row:
            eid = row[0]
            db.execute("UPDATE entries SET kind=? WHERE id=?", (kind, eid))
        else:
            name = path.rsplit("/", 1)[-1]
            eid = db.execute("INSERT INTO entries(path,name,size,mtime,kind) VALUES(?,?,?,?,?)",
                             (path, name, size, mtime, kind)).lastrowid
        db.execute("INSERT OR IGNORE INTO entry_sources VALUES(?,?)", (eid, sid))
        seen.add(eid)

    user_ex = index_dirs.user_excluded()            # Settings > Indexing > Excluded
    stack = [os.path.expanduser(r) for r in roots]
    skipped_mounts = n = 0
    while stack:
        d = stack.pop()
        try:
            it = os.scandir(d)
        except OSError:
            continue
        with it:
            for e in it:
                p = e.path
                if p in mounts:
                    skipped_mounts += 1
                    continue
                if e.name in anywhere or user_ex(p, e.name):
                    continue
                if p.startswith(HOME + "/") and os.path.relpath(p, HOME) in excl:
                    continue
                try:
                    st = e.stat(follow_symlinks=False)
                except OSError:
                    continue
                n += 1
                if e.is_dir(follow_symlinks=False):
                    note(p, None, int(st.st_mtime), "dir")
                    stack.append(p)
                elif e.is_symlink():
                    note(p, 0, int(st.st_mtime), "link")
                else:
                    note(p, st.st_size, int(st.st_mtime), "file")
    t_walk = time.time() - t0
    gone = []
    for path, lst in known.items():
        for (_, _, eid) in lst:
            if eid not in seen:
                gone.append(eid)
                touched.add(path)
    db.executemany("DELETE FROM entry_sources WHERE source_id=? AND entry_id=?", ((sid, g) for g in gone))
    for i in range(0, len(gone), 500):
        part = gone[i:i + 500]
        q = ",".join("?" * len(part))
        db.execute(f"DELETE FROM entries WHERE id IN ({q}) AND id NOT IN (SELECT entry_id FROM entry_sources)", part)
    db.commit()
    deliver(db, touched)
    print(f"local: {n} rows, +{added} new, {changed} changed, -{len(gone)} gone, {skipped_mounts} mount points skipped, "
          f"walk {t_walk:.1f}s, total {time.time()-t0:.1f}s", file=sys.stderr)

# Run on the host that holds the files (python3 -c over ssh): prints "kind size mtime path" lines.
REMOTE_WALK = r"""
import os, sys
stack = [sys.argv[1]]
while stack:
    d = stack.pop()
    try:
        it = os.scandir(d)
    except OSError:
        if d == sys.argv[1]: print("FAIL"); sys.exit(1)
        continue
    with it:
        for e in it:
            try:
                st = e.stat(follow_symlinks=False)
            except OSError:
                continue
            if e.is_dir(follow_symlinks=False):
                print("dir", "", int(st.st_mtime), e.path, sep="\t"); stack.append(e.path)
            elif e.is_symlink():
                print("link", 0, int(st.st_mtime), e.path, sep="\t")
            else:
                print("file", st.st_size, int(st.st_mtime), e.path, sep="\t")
"""

def build_extra(db):
    """Index the "extra_roots": {"root": path as seen here, "ssh": host, "remote_root": same dir on that
    host}. The walk runs on the host that owns the disk and streams rows back, so this machine does
    no tree walking over NFS. One source per root; a failed walk keeps the old rows (no sweep)."""
    for r in C.get("extra_roots", []):
        root, host, rroot = r["root"].rstrip("/"), r["ssh"], r["remote_root"].rstrip("/")
        sid = source_id(db, f"live:path:{root}", "live", time.strftime("%Y-%m-%dT%H:%M:%S"))
        w = Writer(db, sid)
        t0 = time.time()
        p = subprocess.Popen(["ssh", host, "nice", "-n", "19", "python3", "-c", shlex.quote(REMOTE_WALK), shlex.quote(rroot)],
                             stdout=subprocess.PIPE, text=True, errors="surrogateescape")
        failed = False
        for line in p.stdout:
            parts = line.rstrip("\n").split("\t", 3)
            if len(parts) != 4:
                failed = failed or line.startswith("FAIL")
                continue
            kind, size, mtime, path = parts
            w.add(root + path[len(rroot):], int(size) if size != "" else None, int(mtime), kind)
        failed = failed or p.wait() != 0
        db.commit()
        if not failed:
            sweep(db, sid)
        print(f"extra {root}: {w.n} rows, {time.time()-t0:.1f}s{' FAILED, kept old rows' if failed else ''}", file=sys.stderr)

STATE_PATH = os.path.expanduser(DB) + ".drive.json"   # {"token": changes page token, "root_fid": ...}; outside the db so an idle poll never touches it

def rclone_ts(mt):
    try:
        return int(time.mktime(time.strptime(mt[:19], "%Y-%m-%dT%H:%M:%S")))
    except ValueError:
        return None

def load_state():
    try:
        return json.load(open(STATE_PATH))
    except (OSError, ValueError):
        return {}

def save_state(st):
    tmp = STATE_PATH + ".tmp"
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as f:
        json.dump(st, f)
    os.replace(tmp, STATE_PATH)

_RCLONE_CFG = None

def rclone_config():
    global _RCLONE_CFG
    if _RCLONE_CFG is None:
        _RCLONE_CFG = _rclone_config()
    return _RCLONE_CFG

def _rclone_config():
    return json.loads(subprocess.run(["rclone", "config", "dump"], capture_output=True, text=True, check=True).stdout)

def drive_underlying(remote):
    """For a crypt (or plain) remote on Google Drive: (drive remote name, 'name:folder' the remote points at); else None."""
    cfg = rclone_config()
    r = cfg.get(remote.rstrip(":"), {})
    under = r.get("remote", remote) if r.get("type") == "crypt" else remote
    name = under.split(":")[0]
    return (name, under) if cfg.get(name, {}).get("type") == "drive" else None

def drive_access_token(name):
    """Current OAuth access token of an rclone drive remote (refreshed here only if rclone's has expired). Never printed."""
    c = rclone_config()[name]
    tok = json.loads(c["token"])
    try:
        import datetime
        left = datetime.datetime.fromisoformat(tok.get("expiry", "")).timestamp() - time.time()
    except ValueError:
        left = 0
    if left > 120:
        return tok["access_token"]
    data = urllib.parse.urlencode({"client_id": c["client_id"], "client_secret": c["client_secret"],
                                   "refresh_token": tok["refresh_token"], "grant_type": "refresh_token"}).encode()
    with urllib.request.urlopen(urllib.request.Request("https://oauth2.googleapis.com/token", data=data), timeout=60) as r:
        return json.load(r)["access_token"]

def drive_get(token, path, **params):
    url = "https://www.googleapis.com/drive/v3/" + path + "?" + urllib.parse.urlencode(params)
    for attempt in range(4):
        try:
            req = urllib.request.Request(url, headers={"Authorization": "Bearer " + token})
            with urllib.request.urlopen(req, timeout=90) as r:
                return json.load(r)
        except urllib.error.HTTPError as e:
            if e.code not in (429, 500, 502, 503, 504) or attempt == 3:
                raise
        except (urllib.error.URLError, TimeoutError):
            if attempt == 3:
                raise
        time.sleep(2 ** attempt)

def drive_root_fid(under):
    """Folder id of 'name:folder' (the directory the crypt remote points at), from its parent's listing."""
    name, _, folder = under.partition(":")
    parent, _, leaf = folder.rpartition("/")
    out = subprocess.run(["rclone", "lsjson", "--dirs-only", "--no-mimetype", f"{name}:{parent}"],
                         capture_output=True, text=True, check=True).stdout
    for e in json.loads(out):
        if e["Name"] == leaf:
            return e["ID"]
    raise RuntimeError(f"cannot find folder {under}")

def build_rclone(db):
    """Full listing of each rclone remote through its API (the periodic safety net). For a Google Drive
    remote it also records every folder's and file's Drive id, and the changes-feed position taken BEFORE
    the listing starts, so poll-drive can replay anything that changed while the listing ran."""
    for r in C.get("rclone", []):
        remote, mount = r["remote"], os.path.expanduser(r["mount"])
        sid = source_id(db, f"live:rclone:{remote}", "live", time.strftime("%Y-%m-%dT%H:%M:%S"))
        info = drive_underlying(remote)
        start_token = root_fid = None
        if info:
            start_token = drive_get(drive_access_token(info[0]), "changes/startPageToken", supportsAllDrives="true")["startPageToken"]
            root_fid = drive_root_fid(info[1])
        w = Writer(db, sid)
        t0 = time.time()
        out = subprocess.run(["rclone", "lsjson", "-R", "--no-mimetype", remote],
                             capture_output=True, text=True, check=True).stdout
        dirs, files = {"": root_fid}, []
        for e in json.loads(out):
            if e.get("IsDir"):
                dirs[e["Path"]] = e.get("ID")
                continue
            ts = rclone_ts(e.get("ModTime", ""))
            w.add(f"{mount}/{e['Path']}", int(e.get("Size", 0)), ts, "file")
            files.append((e.get("ID"), e["Path"].rpartition("/")[0]))
        if info:
            db.execute("DELETE FROM drive_dirs")
            db.executemany("INSERT OR REPLACE INTO drive_dirs VALUES(?,?)", ((fid, p) for p, fid in dirs.items() if fid and p))
            db.execute("DELETE FROM drive_files")
            db.executemany("INSERT OR REPLACE INTO drive_files VALUES(?,?)", ((fid, dirs[d]) for fid, d in files if fid and dirs.get(d)))
        db.commit()
        sweep(db, sid)
        if info:
            save_state({"token": start_token, "root_fid": root_fid, "remote": remote, "full": time.strftime("%Y-%m-%dT%H:%M:%S")})
        print(f"rclone {remote}: {w.n} rows, {len(dirs)} folders, {time.time()-t0:.1f}s", file=sys.stderr)

class DriveSync(SourceStore):
    """Applies Drive changes to the catalog by relisting only the folders that changed (through rclone, so the
    crypt layer decrypts names and sizes), then diffing each listing against the rows the source already has."""
    def __init__(self, db, sid, remote, mount, root_fid):
        super().__init__(db, sid)
        self.remote, self.mount, self.root = remote, mount, root_fid

    def path_of(self, fid):
        if fid == self.root:
            return ""
        r = self.db.execute("SELECT path FROM drive_dirs WHERE fid=?", (fid,)).fetchone()
        return r[0] if r else None

    def _entries(self, rel):
        prefix = f"{self.mount}/{rel}/" if rel else f"{self.mount}/"
        return [(eid, p, sz, mt) for eid, p, sz, mt in self.db.execute(
            "SELECT e.id, e.path, e.size, e.mtime FROM entries e JOIN entry_sources es ON es.entry_id=e.id "
            "WHERE es.source_id=? AND e.path >= ? AND e.path < ?", (self.sid, prefix, prefix[:-1] + "0"))], prefix

    def delete_subtree(self, rel):
        """Forget a folder and everything under it (it was deleted, renamed or moved away)."""
        ents, _ = self._entries(rel)
        self.drop([e[0] for e in ents])
        lo, pre, hi = rel, rel + "/", rel + "0"
        fids = [r[0] for r in self.db.execute("SELECT fid FROM drive_dirs WHERE path=? OR (path>=? AND path<?)", (lo, pre, hi))]
        for i in range(0, len(fids), 500):
            part = fids[i:i + 500]
            self.db.execute(f"DELETE FROM drive_files WHERE dir_fid IN ({','.join('?' * len(part))})", part)
        self.db.execute("DELETE FROM drive_dirs WHERE path=? OR (path>=? AND path<?)", (lo, pre, hi))

    def reconcile(self, rel, recursive, self_fid=None):
        """Relist folder `rel` (recursively or just its direct children) and make the catalog match."""
        cmd = ["rclone", "lsjson", "--no-mimetype"] + (["-R"] if recursive else []) + [self.remote + rel]
        p = subprocess.run(cmd, capture_output=True, text=True)
        if p.returncode != 0:
            if "not found" not in p.stderr.lower():
                raise RuntimeError(f"rclone lsjson {rel!r}: {p.stderr.strip()[:300]}")
            items = []
        else:
            items = json.loads(p.stdout or "[]")
        join = lambda a, b: f"{a}/{b}" if a else b
        want_files, want_dirs = {}, {}
        for e in items:
            full = join(rel, e["Path"])
            if e.get("IsDir"):
                want_dirs[full] = e.get("ID")
            else:
                want_files[(f"{self.mount}/{full}", int(e.get("Size", 0)), rclone_ts(e.get("ModTime", "")))] = (e.get("ID"), full.rpartition("/")[0])
        # folders first (a recreated folder must not wipe rows added below): what the db knows below / directly in rel
        pre = rel + "/" if rel else ""
        hi = rel + "0" if rel else "\U0010ffff"
        rows = self.db.execute("SELECT fid, path FROM drive_dirs WHERE path>=? AND path<?", (pre, hi)).fetchall()
        known = {p_: fid for fid, p_ in rows if recursive or "/" not in p_[len(pre):]}
        self_f = self_fid or self.path_fid(rel)
        if recursive and rel and self_fid:
            self.db.execute("INSERT OR REPLACE INTO drive_dirs VALUES(?,?)", (self_fid, rel))
        redo = []
        for path_, fid in known.items():
            if want_dirs.get(path_) != fid:
                self.delete_subtree(path_)
        for path_, fid in want_dirs.items():
            if known.get(path_) != fid:
                if recursive:
                    self.db.execute("INSERT OR REPLACE INTO drive_dirs VALUES(?,?)", (fid, path_))
                else:
                    redo.append((path_, fid))
        # files: diff against the rows this source already has in scope
        ents, prefix = self._entries(rel)
        if not recursive:
            ents = [e for e in ents if "/" not in e[1][len(prefix):]]
        have = {(p_, sz, mt): eid for eid, p_, sz, mt in ents}
        self.drop([eid for k, eid in have.items() if k not in want_files])
        for k in want_files:
            if k not in have:
                self.add(*k)
        # Drive ids of the files in scope
        scope = [f for f in ([self_f] + (list(want_dirs.values()) if recursive else [])) if f]
        for i in range(0, len(scope), 500):
            part = scope[i:i + 500]
            self.db.execute(f"DELETE FROM drive_files WHERE dir_fid IN ({','.join('?' * len(part))})", part)
        fid_by_dir = {rel: self_f}
        fid_by_dir.update(want_dirs)
        self.db.executemany("INSERT OR REPLACE INTO drive_files VALUES(?,?)",
                            ((fid, fid_by_dir.get(d)) for fid, d in want_files.values() if fid and fid_by_dir.get(d)))
        for path_, fid in redo:                 # new / renamed / moved-in folders: take them whole
            self.reconcile(path_, True, fid)

    def path_fid(self, rel):
        if not rel:
            return self.root
        r = self.db.execute("SELECT fid FROM drive_dirs WHERE path=?", (rel,)).fetchone()
        return r[0] if r else None

def drive_poll(db):
    lock = os.path.expanduser(DB) + ".building"
    if os.path.exists(lock):
        print("a build is running, skipping", file=sys.stderr)
        return
    st = load_state()
    if not st.get("token"):
        print("no changes-feed position yet: run build-rclone first", file=sys.stderr)
        return
    remote = st["remote"]
    mount = next(os.path.expanduser(r["mount"]) for r in C["rclone"] if r["remote"] == remote)
    name, _ = drive_underlying(remote)
    token = drive_access_token(name)
    changes, pt = [], st["token"]
    while True:
        d = drive_get(token, "changes", pageToken=pt, pageSize=1000, includeRemoved="true", supportsAllDrives="true",
                      includeItemsFromAllDrives="true",
                      fields="nextPageToken,newStartPageToken,changes(fileId,removed,file(parents,trashed))")
        changes += d.get("changes", [])
        if d.get("nextPageToken"):
            pt = d["nextPageToken"]
        else:
            new_token = d["newStartPageToken"]
            break
    t0 = time.time()
    sid = db.execute("SELECT id FROM sources WHERE label=?", (f"live:rclone:{remote}",)).fetchone()[0]
    sync = DriveSync(db, sid, remote, mount, st["root_fid"])
    # which folders' listings could have changed: where each changed item was (old parent) and is now (new parents)
    dirty, unresolved = set(), set()
    for c in changes:
        fid, f = c["fileId"], c.get("file") or {}
        r = db.execute("SELECT dir_fid FROM drive_files WHERE fid=?", (fid,)).fetchone()
        if r and sync.path_of(r[0]) is not None:
            dirty.add(sync.path_of(r[0]))
        r = db.execute("SELECT path FROM drive_dirs WHERE fid=?", (fid,)).fetchone()
        if r:
            dirty.add(r[0].rpartition("/")[0])
        if not (c.get("removed") or f.get("trashed")):
            for par in f.get("parents", []):
                pp = sync.path_of(par)
                (dirty.add(pp) if pp is not None else unresolved.add(par))
    if not dirty and not unresolved:
        save_state({**st, "token": new_token})
        print(f"{len(changes)} changes, none in {remote}", file=sys.stderr)
        return
    if len(dirty) > 60:                      # ~8 s per relisted folder; past this a full listing is cheaper
        print(f"{len(dirty)} folders changed: falling back to a full listing", file=sys.stderr)
        open(lock, "w").close()
        try:
            build_rclone(db)
            touch_generation()
        finally:
            os.path.exists(lock) and os.remove(lock)
        return
    open(lock, "w").close()
    try:
        done = set()
        for _ in range(3):
            for path_ in sorted(dirty - done, key=lambda x: (x.count("/") if x else -1, x)):
                done.add(path_)
                if path_ and sync.path_fid(path_) is None:
                    continue                      # removed meanwhile (its parent was relisted first)
                sync.reconcile(path_, False)
            dirty = {sync.path_of(u) for u in unresolved if sync.path_of(u) is not None} - done
            unresolved = {u for u in unresolved if sync.path_of(u) is None}
            if not dirty:
                break
        db.commit()
    except BaseException:
        db.rollback()
        raise
    finally:
        os.path.exists(lock) and os.remove(lock)
    save_state({**st, "token": new_token})
    deliver(db, sync.touched)
    print(f"{len(changes)} changes -> {len(done)} folders relisted, +{sync.added} -{sync.removed}, {time.time()-t0:.1f}s", file=sys.stderr)

def find(db, text, limit, source=None, size=None, dm=None):
    where, args = [], []
    sql = "SELECT e.path, e.size, e.mtime, e.kind FROM entries e WHERE instr(lower(e.name), lower(?)) > 0"
    args.append(text)
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
    sub.add_parser("poll-drive")
    sub.add_parser("build-restic")
    sub.add_parser("build-btrfs")
    sub.add_parser("build-extra")
    sub.add_parser("stats")
    f = sub.add_parser("find"); f.add_argument("text"); f.add_argument("--limit", type=int, default=50)
    f.add_argument("--source"); f.add_argument("--size"); f.add_argument("--dm")
    a = ap.parse_args()
    db = connect()
    lock = os.path.expanduser(DB) + ".building"      # tells the search server not to reload mid-build
    building = a.cmd.startswith("build-")
    if building:
        open(lock, "w").close()
    try:
        run(a, db)
        if a.cmd in ("build-extra", "build-rclone"):
            touch_generation()      # the server reloads; build-local and poll-drive deliver their changes live instead
    finally:
        if building and os.path.exists(lock):
            os.remove(lock)

def run(a, db):
    if a.cmd == "build-local":
        build_local(db, json.loads(os.environ["CATALOG_LOCAL_ROOTS"]) if os.environ.get("CATALOG_LOCAL_ROOTS") else index_dirs.path_roots(C["local_roots"]))   # Settings > Indexing overrides the config list
    elif a.cmd == "build-extra":
        build_extra(db)
    elif a.cmd == "poll-drive":
        drive_poll(db)
    elif a.cmd == "build-rclone":
        build_rclone(db)
    elif a.cmd == "build-btrfs":
        import btrfs_store            # snapper snapshots, in their own database (catalog-btrfs.db)
        btrfs_store.build()
    elif a.cmd == "build-restic":
        import restic_store           # the restic snapshots live in their own database (catalog-restic.db)
        restic_store.build()
    elif a.cmd == "stats":
        print("entries:", db.execute("SELECT count(*) FROM entries").fetchone()[0])
        for label, n in db.execute("SELECT s.label, count(*) FROM entry_sources es JOIN sources s ON s.id=es.source_id GROUP BY s.label ORDER BY s.label"):
            print(f"  {n:>9}  {label}")
    elif a.cmd == "find":
        for path, size, mt, kind in find(db, a.text, a.limit, a.source, a.size, a.dm):
            print(f"{size if size is not None else '-':>12}  {path}")

if __name__ == "__main__":
    main()

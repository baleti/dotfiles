"""What the picker's Settings > Indexing shows about the real setup (served by search_server.py as GET /index-dirs):
the chosen directories, what is excluded and why, every content index with its size, and the schedule of each indexing job.
Everything here is read from the live system (config files, systemd, the index folders), nothing is stored."""
import json, os, subprocess, sys, time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(os.path.dirname(HERE), "catalog"))
import index_dirs

HOME = os.path.expanduser("~")
IDX = os.path.join(HOME, ".cache/indexes")

# (unit, short name, what it keeps up to date, the logic, how often)
JOBS = [
    ("catalog-watcher.service", "fanotify watcher (live)", "file names on this machine's disk",
     "One fanotify mark on the whole btrfs volume; a path is written once nothing touched it for a second, so new, renamed, changed and deleted files show up in about a second. Files still held open are updated when closed.",
     "continuous"),
    ("catalog-host1-watch.service", "host1 NFS stream (live)", "file names of the host1 backups (/mnt/backups)",
     "Kernel notifications do not cross NFS, so host1 runs the same fanotify helper and streams the events over ssh (WireGuard); a reconnect after a gap starts a full walk.",
     "continuous"),
    ("catalog-drive-poll.timer", "Google Drive changes (rclone)", "file names on Google Drive",
     "Reads the Drive changes feed through rclone's API and relists only the folders that changed; the FUSE mount is never walked.",
     "every 2 min (3 min after boot)"),
    ("catalog-drive-full.timer", "Google Drive full listing", "file names on Google Drive",
     "Weekly safety net behind the changes feed: lists the whole Drive, which also drops files deleted without the feed noticing.",
     "Sundays about 04:20"),
    ("catalog-local.timer", "Local safety-net walk", "file names on this machine's disk",
     "Incremental walk of the directories chosen above (entries with unchanged size and mtime are skipped, what vanished is removed); catches what the watcher cannot see, such as other filesystems and changes while it was down.",
     "nightly 03:00 and 10 min after boot"),
    ("catalog-remote.timer", "Restic snapshots", "file names inside the restic backups",
     "Ingests the newest restic snapshot into its own database: every distinct version of a path is stored once with the range of snapshots it appears in. Results appear with /show-backup-restic.",
     "every 6 h (20 min after boot)"),
    ("catalog-btrfs.timer", "btrfs snapshots (snapper)", "file names inside the btrfs snapshots",
     "Ingests snapper snapshots newer than the newest one stored (snapshots snapper deleted are dropped). Results appear with /show-backup-btrfs.",
     "every 20 min (15 min after boot)"),
    ("catalog-extra.timer", "NFS roots full walk", "file names of the host1 backups",
     "Monthly full walk of the NFS roots, the safety net behind the live stream.",
     "monthly"),
    ("nightly-index.timer", "Content indexes of the collections", "BM25 (Recoll), ChromaDB chunks and page-CLIP of PDFs for every collection",
     "Recoll re-reads only changed files; Chroma and page-CLIP skip documents already done (changed ones are not re-embedded). Embedding runs on the GPU box; low priority, memory capped at 8 GB.",
     "nightly 02:30"),
    ("nightly-cad-index.timer", "Revit and DWG content indexes", "BM25 over Revit (rvt rfa rte rft) and AutoCAD (dwg dxf) files, each in its own index",
     "The file list comes from the file-name catalog and is fed to recollindex, which skips unchanged files; a file takes seconds to minutes to decode, so a first pass spans several nights.",
     "nightly 04:30"),
]

_cache = {}

def cached(key, ttl, fn):
    now = time.time()
    hit = _cache.get(key)
    if hit and now - hit[0] < ttl:
        return hit[1]
    v = fn()
    _cache[key] = (now, v)
    return v

def sh(*cmd, timeout=10):
    try:
        return subprocess.run(cmd, capture_output=True, text=True, timeout=timeout).stdout
    except Exception:
        return ""

def unit_state(unit):
    out = sh("systemctl", "--user", "show", unit, "-p", "ActiveState,SubState,LastTriggerUSec,NextElapseUSecRealtime,ExecMainStartTimestamp,Result")
    kv = dict(l.split("=", 1) for l in out.splitlines() if "=" in l)
    return kv

def short(t):
    """'Sun 2026-10-18 11:40:41 BST' -> 'Sun 11:40' (today) / 'Sun 18 Oct 11:40'"""
    t = (t or "").strip()
    if not t or t == "n/a":
        return ""
    parts = t.split()
    if len(parts) >= 3:
        day, date, hm = parts[0], parts[1], parts[2][:5]
        return f"{day} {hm}" if date == time.strftime("%Y-%m-%d") else f"{day} {date[5:]} {hm}"
    return t

def schedule():
    out = []
    for unit, name, what, logic, when in JOBS:
        st = unit_state(unit)
        row = {"name": name, "what": what, "logic": logic, "when": when, "state": st.get("ActiveState", "unknown")}
        if unit.endswith(".timer"):
            svc = unit_state(unit.replace(".timer", ".service"))
            row["last"] = short(st.get("LastTriggerUSec") or svc.get("ExecMainStartTimestamp"))
            row["next"] = short(st.get("NextElapseUSecRealtime"))
            row["running"] = svc.get("ActiveState") in ("active", "activating")
            row["result"] = svc.get("Result", "")
        else:
            row["last"], row["next"], row["running"], row["result"] = "", "", row["state"] == "active", ""
        out.append(row)
    return out

def du(path):
    out = sh("du", "-s", "--apparent-size", "-B1", path, timeout=60).split()
    return int(out[0]) if out and out[0].isdigit() else 0

def xapian_docs(conf):
    out = sh("xapian-delve", "-z", os.path.join(conf, "xapiandb"))
    for l in out.splitlines():
        if l.startswith("number of documents"):
            return int(l.split("=")[1])
    return 0

def collections():
    try:
        return json.load(open(os.path.join(HOME, ".config/indexes/collections.json")))["collections"]
    except (OSError, ValueError, KeyError):
        return {}

CAD_ROOTS = {"revit": "rvt rfa rte rft files under the office folders", "dwg": "dwg dxf files under the office folders"}

def indexes(fts_confs):
    """Every content index: name, what it covers, which index types exist for it, document count and size on disk."""
    coll = collections()
    rows = []
    for conf in fts_confs:
        name = os.path.basename(os.path.dirname(conf.rstrip("/")))
        base = os.path.dirname(conf.rstrip("/"))
        c = coll.get(name, {})
        roots = [r for r in c.get("roots", [])]
        row = {
            "name": name,
            "roots": roots if roots else ([CAD_ROOTS[name]] if name in CAD_ROOTS else (index_dirs.fts_dirs() if name == "user-dirs" else [])),
            "bm25": True,
            "chroma": du(os.path.join(base, "chroma")) > 5 * 2**20,         # a few-KB folder is an empty stub, not an index
            "clip_pages": bool(c.get("clip_pages")),
            "faces": bool(c.get("faces")),
            "docs": xapian_docs(conf),
            "bytes": du(base),
        }
        rows.append(row)
    return rows

def mounts_skipped():
    """Mount points under $HOME the walk never enters (separate subvolumes, rclone and other FUSE mounts, ...)."""
    out = []
    try:
        for line in open("/proc/self/mountinfo"):
            parts = line.split()
            mp = parts[4].replace("\\040", " ")
            if mp.startswith(HOME + "/"):
                out.append(mp.replace(HOME, "~", 1))
    except OSError:
        pass
    return sorted(set(out))

def overview(catalog_cfg, fts_confs):
    v = index_dirs.load(catalog_cfg.get("local_roots", []))
    hidden = []
    try:
        hidden = [f"{h['folder']}  (shown with //path {h['keyword']})" for h in
                  json.load(open(os.path.join(HOME, ".config/indexes/search-app.json"))).get("off_by_default", [])]
    except (OSError, ValueError, KeyError, TypeError):
        pass
    return {
        **v,
        "config_exclude": {
            "names_under_home": catalog_cfg.get("exclude_names", []),
            "paths": catalog_cfg.get("exclude_paths", []),
            "anywhere": catalog_cfg.get("exclude_anywhere", []),
            "mounts": cached("mounts", 60, mounts_skipped),
            "hidden_by_default": hidden,
        },
        "indexes": cached("indexes:" + ",".join(fts_confs), 120, lambda: indexes(fts_confs)),
        "schedule": cached("schedule", 15, schedule),
    }

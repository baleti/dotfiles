"""Which directories the user chose to index, from the settings window of the mod+1 picker (Settings > Indexing).

~/.config/indexes/index-dirs.json:
    {"path": ["~", "/"],            # walked for the file-name catalog (what name search finds); absent = catalog.local_roots
     "exclude": ["~/temp", "node_modules"],   # left out of that walk and of the live watcher, on top of the config's exclusions:
                                              # a path (contains / or starts with ~) with everything under it, or a bare name wherever it occurs
     "fts":  {"dirs": ["~/notes", ...],   # content-indexed, as the managed collection "user-dirs", with the index types switched on:
              "bm25": true,                #   /fts    Recoll word search (index ~/.cache/indexes/user-dirs/recoll)
              "chroma": false,             #   /chroma semantic search over the extracted text (needs the Recoll index; embeds on ai1)
              "clip": false,               #   /clip   what the images in those directories show (ai1 GPU)
              "face": false}}              #   /face   InsightFace people in those images (ai1 GPU)

Read by catalog.py (the walk), watcher.py (live changes), search_server.py (which Recoll indexes /fts searches) and
photos/apply_index_dirs.py (writes the Recoll config, starts the builds)."""
import json, os

HOME = os.path.expanduser("~")
PATH = os.path.join(HOME, ".config/indexes/index-dirs.json")
FTS_INDEX = os.path.join(HOME, ".cache/indexes/user-dirs/recoll")       # the managed Recoll config directory (/fts index "user-dirs")
STATUS = os.path.join(HOME, ".cache/indexes/index-dirs-status.json")

def norm(d):
    """A directory as stored: user-typed text -> absolute path with ~ expanded, no trailing slash (the root stays '/')."""
    d = os.path.expanduser(d.strip())
    if not d:
        return ""
    d = os.path.normpath(os.path.join(HOME, d)) if not os.path.isabs(d) else os.path.normpath(d)
    return d

def clean_ex(xs):
    out = []
    for x in xs if isinstance(xs, list) else []:
        if not isinstance(x, str) or not x.strip():
            continue
        x = x.strip()
        v = norm(x) if ("/" in x or x.startswith("~")) else x
        if v and v not in out:
            out.append(v)
    return out

FTS_TYPES = ("bm25", "chroma", "clip", "face")
FTS_DEFAULT = {"bm25": True, "chroma": False, "clip": False, "face": False}

def load(default_path_roots=None):
    try:
        v = json.load(open(PATH))
    except (OSError, ValueError):
        v = {}
    def clean(xs):
        out = []
        for x in xs if isinstance(xs, list) else []:
            if isinstance(x, str) and norm(x) and norm(x) not in out:
                out.append(norm(x))
        return out
    path = clean(v.get("path")) if "path" in v else None
    if path is None:
        path = [norm(r) for r in (default_path_roots or [])]
    f = v.get("fts")
    if isinstance(f, list):                    # first version of the file: just the directories
        f = {"dirs": f}
    f = f if isinstance(f, dict) else {}
    fts = {"dirs": clean(f.get("dirs"))}
    for t in FTS_TYPES:
        fts[t] = bool(f[t]) if isinstance(f.get(t), bool) else FTS_DEFAULT[t]
    return {"path": path, "exclude": clean_ex(v.get("exclude")), "fts": fts}

def path_roots(default):
    return load(default)["path"]

def fts_dirs():
    return load()["fts"]["dirs"]

def fts_types():
    f = load()["fts"]
    return {t: f[t] for t in FTS_TYPES}

def under(path, roots):
    return any(r == "/" or path == r or path.startswith(r + "/") for r in roots)

def excluder(exclude):
    """(path, name) -> True for what the user excluded in Settings > Indexing."""
    paths = [e for e in exclude if e.startswith("/")]
    names = {e for e in exclude if not e.startswith("/")}
    def hit(path, name):
        return name in names or any(path == p or path.startswith(p + "/") for p in paths)
    return hit

def user_excluded():
    return excluder(load()["exclude"])

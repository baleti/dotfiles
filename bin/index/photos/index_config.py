"""Which paths get content-indexed, from ~/.config/indexes/collections.json (private, never committed).

    {"paths": ["~/gdrive-rclone-crypt/office/ksr",                        # a path alone gets every index type below
               {"path": "~/gdrive-rclone-crypt/backups", "chroma": false, "clip_pages": false}],   # opt out per path
     "fulltext": true, "chroma": true, "clip_pages": true,               # defaults for every path
     "ai1": {...}}

All paths feed ONE Recoll index (~/.cache/indexes/documents/recoll); scope a search with words before /fts
(`ksr /fts contractor`). A path that does not exist (host1 not mounted, folder not created yet) is skipped by Recoll
and its documents stay in the index.

  fulltext    Recoll/Xapian (/fts)
  chroma      semantic text chunks embedded on ai1 (/chroma); the stores of the old per-folder indexes stay in
              ~/.cache/indexes/<old name>/chroma as read-only shards, so documents already embedded there are not embedded again
  clip_pages  CLIP on large images inside PDFs
  clip        CLIP on the image files themselves (/clip)
  faces       InsightFace on the image files (/face)
All types are on for every path unless a path object switches one off. "max_images_per_run" (default 20000, 0 = no
limit) bounds how many new images one clip or faces run sends to the ai1 GPU; runs are resumable, so the rest follows the next night.
"""
import glob
import json
import os

HOME = os.path.expanduser("~")
PATH = os.path.join(HOME, ".config/indexes/collections.json")
IDX = os.path.join(HOME, ".cache/indexes")
NAME = "documents"                                   # the one merged index: ~/.cache/indexes/documents/{recoll,chroma}
CONF = os.path.join(IDX, NAME, "recoll")
CHROMA = os.path.join(IDX, NAME, "chroma")
TYPES = ("fulltext", "chroma", "clip_pages", "clip", "faces")


def load():
    return json.load(open(PATH))


def entries(cfg=None):
    """[(absolute path, {type: bool})] in file order."""
    cfg = cfg or load()
    out = []
    for p in cfg.get("paths", []):
        spec = p if isinstance(p, dict) else {"path": p}
        flags = {t: bool(spec.get(t, cfg.get(t, True))) for t in TYPES}
        flags["cad"] = bool(spec.get("cad", False))
        out.append((os.path.normpath(os.path.expanduser(spec["path"])), flags))
    return out


CAD_SKIP = "*.rvt *.rfa *.rte *.rft *.dwg *.dxf"        # Revit and DWG have their own indexes (index_cad.py)


def recoll_conf(cfg=None):
    """Text of the merged index's recoll.conf: every path as a topdir, CAD files skipped except under "cad": true paths."""
    ents = entries(cfg)
    lines = ["topdirs = " + " ".join('"%s"' % p.replace('"', "") for p, _ in ents), ""]
    for p, f in ents:
        if not f["cad"]:
            lines += [f"[{p}]", f"skippedNames+ = {CAD_SKIP}", ""]
    return "\n".join(lines)


def paths(cfg=None):
    return [p for p, _ in entries(cfg)]


def flag(path, kind, cfg=None):
    """Whether `kind` is on for a file or folder: the longest configured path that contains it decides."""
    best, val = -1, False
    for p, f in entries(cfg):
        if (path == p or path.startswith(p + "/")) and len(p) > best:
            best, val = len(p), f[kind]
    return val


def opted_out(kind, cfg=None):
    """Paths with `kind` switched off (the chroma script and the PDF lister leave them out)."""
    return [p for p, f in entries(cfg) if not f[kind]]


def chroma_shards():
    """Chroma stores of the old per-folder indexes (not the new one): read-only, only consulted for 'already embedded'."""
    return [d for d in sorted(glob.glob(os.path.join(IDX, "*", "chroma")))
            if os.path.dirname(d) != os.path.dirname(CHROMA)]

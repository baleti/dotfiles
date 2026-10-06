"""Shared configuration for the photo index tools.

Every machine-specific or private value (paths, folder names, hosts, keys,
ports) lives in one JSON file, NOT in the code:

    ~/.config/indexes/photos.json     (private, never committed)

Start from config.example.json. Override the location with IMAGES_CONFIG.
"""
import json
import os

DEFAULT_PATH = os.path.expanduser("~/.config/indexes/photos.json")


def _expand(v):
    if isinstance(v, str):
        return os.path.expanduser(os.path.expandvars(v))
    if isinstance(v, dict):
        return {k: _expand(x) for k, x in v.items()}
    if isinstance(v, list):
        return [_expand(x) for x in v]
    return v


def load():
    path = os.environ.get("IMAGES_CONFIG", DEFAULT_PATH)
    if not os.path.exists(path):
        raise SystemExit(f"missing config: {path} (copy config.example.json there and fill it in)")
    with open(path, encoding="utf-8") as f:
        raw = json.load(f)
    # the "ai1" section names paths and keys on REMOTE hosts (host1 / ai1), so it is
    # passed through unexpanded; expanding ~ here would point at the local home
    remote = raw.pop("ai1", {})
    cfg = _expand(raw)
    cfg["ai1"] = remote
    return cfg


CFG = load()
DATA_DIR = CFG["data_dir"]                 # indexes, people, listings, thumbs, logs (never committed)
SOURCES = CFG["sources"]                   # {stem: gdrive folder}
REMOTE = CFG["rclone_remote"]              # e.g. "gdrive-crypt:"
SERVER_PORT = int(CFG["server"]["port"])
AI1 = CFG["ai1"]

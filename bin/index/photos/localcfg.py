"""Private, machine-local settings for the code and checks in this directory, read from the (git-excluded) indexes config
~/.config/indexes/photos.json (or $IMAGES_CONFIG). Tolerant on purpose: a missing file or key means the generic defaults, so
this also works on hosts that have no config (host1 filters). Keys used here:
  "path_map":   [[home-side backups dir, NFS mount]]  e.g. [["/home/user1/backups/", "/mnt/<real mount name>/"]]
  "test_words": {generic word: real word}             the checks in ../tools are written with generic words (alpha, corpus,
                site, beta) and localize() swaps in words that really occur in this machine's data."""
import json, os, re

DEFAULT_MOUNT = "/mnt/backups"
_cache = {}

def _cfg():
    if "cfg" not in _cache:
        try:
            with open(os.environ.get("IMAGES_CONFIG", os.path.expanduser("~/.config/indexes/photos.json")), encoding="utf-8") as f:
                _cache["cfg"] = json.load(f)
        except (OSError, ValueError):
            _cache["cfg"] = {}
    return _cache["cfg"]

def backups_mount():
    """The NFS mount of host1's backups on this host, no trailing slash."""
    pm = _cfg().get("path_map") or []
    return (pm[0][1].rstrip("/") if pm and len(pm[0]) > 1 else DEFAULT_MOUNT)

def localize(s):
    """A query/argument written with the generic test words and /mnt/backups, with this machine's real ones."""
    words = _cfg().get("test_words") or {}
    mount = backups_mount()
    if not words and mount == DEFAULT_MOUNT:
        return s
    def word(m):
        w, real = m.group(0), words[m.group(0).lower()]
        return real.upper() if w.isupper() else real if w.islower() else "".join(c.upper() if i % 2 else c.lower() for i, c in enumerate(real))
    if words:
        s = re.sub(r"\b(?:%s)\b" % "|".join(map(re.escape, words)), word, s, flags=re.I)
    return s.replace(DEFAULT_MOUNT + "/", mount + "/") if mount != DEFAULT_MOUNT else s

"""Private, machine-local settings for the code and checks in this directory, read from the (git-excluded) indexes config
~/.config/indexes/photos.json (or $IMAGES_CONFIG). Tolerant on purpose: a missing file or key means the generic defaults, so
this also works on hosts that have no config (host1 filters). Keys used here:
  "path_map":   [[home-side backups dir, NFS mount]]  e.g. [["/home/user1/backups/", "/mnt/<real mount name>/"]]
  "windows_roots": [[catalog prefix, Windows prefix]]  e.g. [["/mnt/<sshfs mount>/c/", "C:\\"]]: files that live on a Windows PC (see to_windows / from_windows_text)
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


def windows_roots():
    """[(catalog prefix, Windows prefix)], longest Windows prefix first. Empty without the "windows_roots" key."""
    out = [(a, b) for a, b in (_cfg().get("windows_roots") or []) if a and b]
    return sorted(out, key=lambda r: -len(r[1]))

def to_windows(path):
    """The Windows path of a catalog path (C:\\Users\\... style), or None when it is not under a Windows root."""
    for pre, win in windows_roots():
        if path.startswith(pre):
            return win + path[len(pre):].replace("/", "\\")
    return None

_WINPATH = re.compile(r'(?P<q>")?(?P<p>[A-Za-z]:\\[^"]*?)(?:"|(?=\s+[/!]\S)|\s*$)')

def from_windows_text(query):
    """A Windows path typed into a query (`C:\\Users\\me\\Desktop\\a folder\\x`, quoted or not) becomes the quoted catalog path
    substring it stands for. The path runs to the end of the query, a closing quote, or the next `/verb` / `!term`; a drive that is
    not mapped is left as typed."""
    roots = windows_roots()
    if not roots or ":\\" not in query:
        return query
    def conv(m):
        p = m.group("p")
        for pre, win in roots:
            if p.lower().startswith(win.lower()):
                return '"' + pre + p[len(win):].replace("\\", "/") + '"'
        return m.group(0)
    return _WINPATH.sub(conv, query)

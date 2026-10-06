#!/usr/bin/env python3
"""
Coverage of each Recoll collection: files on disk under its topdirs vs documents in its index.

Disk lists come from the file-name catalog when it covers the folder, else from find.
Writes one report per collection to coverage/<name>.txt next to the indexes.
"""
import collections
import json
import os
import re
import sqlite3
import subprocess
import sys
import urllib.parse
from pathlib import Path

from recoll import recoll

ROOT = Path(os.path.expanduser("~/.cache/indexes"))
CATALOG = os.path.expanduser("~/.cache/indexes/catalog/catalog.db")
OUT = ROOT / "coverage"
COLLECTIONS = sys.argv[1:] or list(json.load(open(os.path.expanduser("~/.config/indexes/collections.json")))["collections"])


def topdirs(conf):
    text = (conf / "recoll.conf").read_text()
    m = re.search(r'^topdirs\s*=\s*(.*)$', text, re.M)
    return re.findall(r'"([^"]+)"|(\S+)', m.group(1)) if m else []


def tops_list(conf):
    return [a or b for a, b in topdirs(conf)]


def disk_files(tops):
    """Regular files under the topdirs. The catalog answers for the gdrive mount; find for the rest."""
    files = set()
    con = sqlite3.connect(f"file:{CATALOG}?mode=ro", uri=True)
    for top in tops:
        if top.startswith(os.path.expanduser("~/gdrive-rclone-crypt")):
            rows = con.execute("SELECT DISTINCT path FROM entries WHERE path = ? OR path LIKE ? ESCAPE '\\'",
                               (top, top.replace("%", "\\%").replace("_", "\\_") + "/%")).fetchall()
            files.update(r[0] for r in rows)
        else:
            out = subprocess.run(["find", top, "-type", "f"], capture_output=True, text=True).stdout
            files.update(l for l in out.splitlines() if l)
    con.close()
    return files


def indexed_files(conf):
    db = recoll.connect(confdir=str(conf), writable=False)
    q = db.query()
    q.execute("date:1970-01-01/2099-12-31", stemming=0)
    urls, docs = set(), 0
    while True:
        d = q.fetchone()
        if d is None:
            break
        docs += 1
        if d.url.startswith("file://"):
            urls.add(urllib.parse.unquote(d.url[len("file://"):]))
    return urls, docs


def main():
    OUT.mkdir(exist_ok=True)
    for name in COLLECTIONS:
        conf = ROOT / name / "recoll"
        tops = tops_list(conf)
        disk = disk_files(tops)
        urls, docs = indexed_files(conf)
        missing = disk - urls
        by_ext = collections.Counter((os.path.splitext(p)[1].lower() or "(none)") for p in missing)
        total_ext = collections.Counter((os.path.splitext(p)[1].lower() or "(none)") for p in disk)
        lines = [
            f"collection: {name}",
            f"topdirs: {', '.join(tops)}",
            f"files on disk: {len(disk)}",
            f"documents in index: {docs} (urls matching a file on disk: {len(disk & urls)})",
            f"files on disk not in the index: {len(missing)}",
            "",
            "not indexed, by extension (not-indexed / on disk):",
        ]
        for ext, n in by_ext.most_common(40):
            lines.append(f"  {ext:12} {n:8} / {total_ext[ext]}")
        (OUT / f"{name}.txt").write_text("\n".join(lines) + "\n")
        print(f"{name}: {len(disk)} on disk, {docs} docs, {len(missing)} not indexed", flush=True)


if __name__ == "__main__":
    main()

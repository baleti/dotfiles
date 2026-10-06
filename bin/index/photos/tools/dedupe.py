#!/usr/bin/env python3
"""Merge the rclone lsjson listings into one deduplicated path list (by (name, size)).
Output: all.txt in the data dir, paths relative to the rclone remote (one per line)."""
import json, os, sys
import sys
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
import config
HERE = os.path.join(config.DATA_DIR, "lists")
FOLDERS = config.SOURCES
seen, out, skipped = {}, [], 0
dup = 0
for stem, folder in FOLDERS.items():
    p = os.path.join(HERE, stem + ".json")
    if not os.path.exists(p): print("missing", p, file=sys.stderr); continue
    for e in json.load(open(p, encoding="utf-8")):
        full = f"{folder}/{e['Path']}"
        # crypt remotes expose no MD5, so dedupe on (basename, size): the same file
        # copied into two folders (e.g. the same design folder under two different source folders)
        key = (e["Name"], e["Size"])
        if key in seen: dup += 1; continue
        seen[key] = full; out.append(full)
open(os.path.join(HERE, "all.txt"), "w", encoding="utf-8").write("\n".join(out) + "\n")
print(f"unique {len(seen)}, kept {len(out)} (no-hash {skipped}), duplicates dropped {dup}")

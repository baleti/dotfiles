#!/usr/bin/env python3
"""Write the "watch" list of the PC's SearchApp config.json from the catalog's extra_roots that live on the PC (ssh host wsl).
/mnt/m -> M:\\   /mnt/c/Users/x/Desktop -> C:\\Users\\x\\Desktop.  Run from host3; nothing private is kept in the repo.
usage: ssh wsl cat <config.json> | pc-watch-config.py | ssh wsl "cat > <config.json>"   (see deploy-watcher.sh)"""
import json, os, re, sys
sys.path.insert(0, os.path.expanduser("~/bin/index/catalog")); sys.path.insert(0, os.path.expanduser("~/bin/index/photos"))
import catalog
watch = []
for r in catalog.C.get("extra_roots", []):
    if r.get("ssh") != "wsl":
        continue
    m = re.match(r"^/mnt/([a-z])(/.*)?$", r["remote_root"])
    if m:
        watch.append(m.group(1).upper() + ":" + (m.group(2) or "\\").replace("/", "\\"))
raw = sys.stdin.read().strip()
cfg = json.loads(raw) if raw else {}
cfg["watch"] = watch
print(json.dumps(cfg, separators=(",", ":")))

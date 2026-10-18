#!/usr/bin/env python3
"""Content indexes for CAD/BIM files, each in its OWN Recoll index (~/.cache/indexes/<kind>/recoll) so the big
ones stay out of the document indexes:  revit (rvt rfa rte rft, via rvt2recoll.py)  and  dwg.
The file list comes from the file-name catalog (`search`), not from a tree walk, and is fed to `recollindex -i`
(unchanged files are skipped).  usage: index_cad.py revit|dwg [--limit N] [--roots 'PATHQ1,PATHQ2']"""
import argparse, os, subprocess, sys, time
IDX = os.path.expanduser("~/.cache/indexes")
KINDS = {"revit": [".rvt", ".rfa", ".rte", ".rft"], "dwg": [".dwg", ".dxf"]}
ROOTS = ["/mnt/host1-backups/office", "gdrive/office"]      # //path queries into the catalog

def files(kind, roots):
    out = []
    for root in roots:
        q = f"//path {root} " + " ".join(f"//ext {e}" for e in KINDS[kind])
        r = subprocess.run(["search", "-q", "-0", "-n", "0", "--no-dotfiles", q], capture_output=True)
        out += [p.decode() for p in r.stdout.split(b"\0") if p]
    return sorted(set(out))

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("kind", choices=KINDS)
    ap.add_argument("--limit", type=int, default=0)
    ap.add_argument("--roots", default=",".join(ROOTS))
    ap.add_argument("--batch", type=int, default=100)
    a = ap.parse_args()
    conf = os.path.join(IDX, a.kind, "recoll")
    todo = files(a.kind, a.roots.split(","))
    if a.limit:
        todo = todo[:a.limit]
    print(f"{time.strftime('%T')} {a.kind}: {len(todo)} files", flush=True)
    for i in range(0, len(todo), a.batch):
        chunk = todo[i:i + a.batch]
        r = subprocess.run(["recollindex", "-c", conf, "-i", *chunk], capture_output=True)
        print(f"{time.strftime('%T')} {min(i + a.batch, len(todo))}/{len(todo)} rc={r.returncode}", flush=True)
    print(f"{time.strftime('%T')} done", flush=True)

main()

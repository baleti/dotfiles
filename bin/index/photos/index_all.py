#!/usr/bin/env python3
"""Run every index the collections config asks for.

Reads ~/.config/indexes/collections.json. Without arguments: all collections,
all flagged index types. Overrides: --collections a,b  and  --only fulltext,chroma,clip_pages

  fulltext    recollindex on the collection's Recoll config
  chroma      full-text chunk embeddings (ai1 GPU), recoll_fulltext_to_chroma.py
  clip_pages  CLIP on large images inside PDFs, pdf_pages_clip.py (appends to clip/pdf-pages.jsonl)
"""
import argparse, json, os, subprocess, sys

HOME = os.path.expanduser("~")
CFG = json.load(open(os.path.join(HOME, ".config/indexes/collections.json")))["collections"]
IDX = os.path.join(HOME, ".cache/indexes")
HERE = os.path.dirname(os.path.abspath(__file__))
PY = os.path.join(IDX, "venv/bin/python")
PDF_LIST = os.path.join(IDX, "photos/pdf-list.tsv")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--collections", default="")
    ap.add_argument("--only", default="")
    a = ap.parse_args()
    names = [c for c in a.collections.split(",") if c] or list(CFG)
    only = [t for t in a.only.split(",") if t]
    mounted = os.path.ismount("/mnt/host1-backups")
    for name in names:
        flags = CFG[name]
        if any(r.startswith("/mnt/host1-backups") for r in flags["roots"]) and not mounted:
            print(f"== {name}: skipped, /mnt/host1-backups is not mounted", flush=True)
            continue
        types = [t for t in ("fulltext", "chroma", "clip_pages") if flags.get(t) and (not only or t in only)]
        for t in types:
            print(f"== {name}: {t}", flush=True)
            if t == "fulltext":
                subprocess.run(["recollindex", "-c", os.path.join(IDX, name, "recoll")], check=False)
            elif t == "chroma":
                subprocess.run([PY, os.path.join(HERE, "..", "chroma", "recoll_fulltext_to_chroma.py"),
                                "--recoll-conf", os.path.join(IDX, name, "recoll"),
                                "--db", os.path.join(IDX, name, "chroma")], check=False)
            elif t == "clip_pages":
                subprocess.run([PY, os.path.join(HERE, "pdf_pages_clip.py"), "--list", PDF_LIST,
                                "--collections", name, "--threads", "2"], check=False)


if __name__ == "__main__":
    main()

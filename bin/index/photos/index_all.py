#!/usr/bin/env python3
"""Run the content indexes for the paths in ~/.config/indexes/collections.json (see index_config.py).

All paths feed one Recoll index, ~/.cache/indexes/documents. Without arguments every index type runs;
--only fulltext,chroma,clip_pages picks some. A path switched off for a type ("chroma": false) is left out of that type.

  fulltext    recollindex on the merged config (recoll.conf is rewritten from the path list first)
  chroma      full-text chunk embeddings (ai1 GPU), recoll_fulltext_to_chroma.py; documents already embedded in
              the old per-folder stores (~/.cache/indexes/<old name>/chroma) count as done
  clip_pages  CLIP on large images inside PDFs, pdf_pages_clip.py (appends to clip/pdf-pages.jsonl)
  clip, faces CLIP and InsightFace on the image files need a GPU: not here. They run on host1 through ai1 every 3 days,
              new and changed images only (remote_images.py + host1_image_job.py, timers image-index-start / image-index-pull).
"""
import argparse, os, subprocess

import index_config as ic

HERE = os.path.dirname(os.path.abspath(__file__))
PY = os.path.join(ic.IDX, "venv/bin/python")
PDF_LIST = os.path.join(ic.IDX, "photos/pdf-list.tsv")


def write_conf():
    text = ic.recoll_conf()
    p = os.path.join(ic.CONF, "recoll.conf")
    if not os.path.exists(p) or open(p).read() != text:
        os.makedirs(ic.CONF, exist_ok=True)
        open(p, "w").write(text)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--only", default="")
    a = ap.parse_args()
    only = [t for t in a.only.split(",") if t]
    cfg = ic.load()
    write_conf()
    for t in ic.TYPES:
        if (only and t not in only) or not cfg.get(t, True):
            continue
        print(f"== {t}", flush=True)
        if t == "fulltext":
            subprocess.run(["recollindex", "-c", ic.CONF], check=False)
        elif t == "chroma":
            cmd = [PY, os.path.join(HERE, "..", "chroma", "recoll_fulltext_to_chroma.py"),
                   "--recoll-conf", ic.CONF, "--db", ic.CHROMA]
            for d in ic.chroma_shards():
                cmd += ["--also-done", d]
            for p in ic.opted_out("chroma", cfg):
                cmd += ["--skip-prefix", p]
            subprocess.run(cmd, check=False)
        elif t in ("clip", "faces"):
            print("   runs on host1 (remote_images.py), not here", flush=True)
        elif t == "clip_pages":
            subprocess.run([PY, os.path.join(HERE, "pdf_pages_clip.py"), "--list", PDF_LIST, "--threads", "2"], check=False)


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""Run the content indexes for the paths in ~/.config/indexes/collections.json (see index_config.py).

All paths feed one Recoll index, ~/.cache/indexes/documents. Without arguments every index type runs;
--only fulltext,chroma,clip_pages picks some. A path switched off for a type ("chroma": false) is left out of that type.

  fulltext    recollindex on the merged config (recoll.conf is rewritten from the path list first)
  chroma      full-text chunk embeddings (ai1 GPU), recoll_fulltext_to_chroma.py; documents already embedded in
              the old per-folder stores (~/.cache/indexes/<old name>/chroma) count as done
  clip_pages  CLIP on large images inside PDFs, pdf_pages_clip.py (appends to clip/pdf-pages.jsonl)
  clip        CLIP on the image files (jpg jpeg png webp) of the paths, index_photos.py --only clip
  faces       InsightFace on the same images, index_photos.py --only face
Images are found through the file-name catalog (no walk of the Drive or NFS); those already in clip.jsonl / faces.jsonl are
skipped, and "max_images_per_run" in collections.json bounds the new ones per run.
"""
import argparse, os, sqlite3, subprocess

import config
import index_config as ic
import index_photos as ip

HERE = os.path.dirname(os.path.abspath(__file__))
PY = os.path.join(ic.IDX, "venv/bin/python")
PDF_LIST = os.path.join(ic.IDX, "photos/pdf-list.tsv")
CATALOG = os.path.join(ic.IDX, "catalog/catalog.db")
LISTS = os.path.join(config.DATA_DIR, "lists")
IMAGE_EXT = (".jpg", ".jpeg", ".png", ".webp")
WORKER = {"clip": "clip", "faces": "face"}                    # config type -> index_photos worker


def pending_images(kind, cfg, limit):
    """New images for `kind`, as ({Drive paths relative to the mount}, {absolute paths without the leading /}), at most `limit`."""
    done = ip.done_set(ip.WORKERS[WORKER[kind]][1])
    mount, remote = config.CFG["mount_root"], config.REMOTE
    drive, local = {}, {}
    con = sqlite3.connect(f"file:{CATALOG}?mode=ro", uri=True)
    for p, f in ic.entries(cfg):
        if not f[kind]:
            continue
        for (path,) in con.execute("SELECT DISTINCT path FROM entries WHERE kind='file' AND path>? AND path<?", (p + "/", p + "0")):
            if not path.lower().endswith(IMAGE_EXT):
                continue
            if path.startswith(mount + "/"):
                rel = path[len(mount) + 1:]
                if remote + rel not in done:
                    drive[rel] = 1
            elif "/" + path.lstrip("/") not in done:
                local[path.lstrip("/")] = 1
    con.close()
    drive, local = list(drive), list(local)
    if limit:
        drive = drive[:limit]
        local = local[:max(0, limit - len(drive))]
    return drive, local


def write_conf():
    text = ic.recoll_conf()
    p = os.path.join(ic.CONF, "recoll.conf")
    if not os.path.exists(p) or open(p).read() != text:
        os.makedirs(ic.CONF, exist_ok=True)
        open(p, "w").write(text)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--only", default="")
    ap.add_argument("--dry-run", action="store_true", help="clip/faces: only count the new images")
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
        elif t in WORKER:
            limit = int(cfg.get("max_images_per_run", 20000))
            drive, local = pending_images(t, cfg, limit)
            print(f"   {len(drive):,} new Drive images, {len(local):,} new local images (limit {limit or 'none'})", flush=True)
            if a.dry_run:
                continue
            os.makedirs(LISTS, exist_ok=True)
            for base, rels, tag in ((config.REMOTE, drive, "drive"), ("/", local, "local")):
                if rels:
                    lst = os.path.join(LISTS, f"documents-{t}-{tag}.txt")
                    open(lst, "w", encoding="utf-8").write("\n".join(rels) + "\n")
                    subprocess.run([PY, os.path.join(HERE, "index_photos.py"), "--base", base, "--list", lst, "--only", WORKER[t]], check=False)
        elif t == "clip_pages":
            subprocess.run([PY, os.path.join(HERE, "pdf_pages_clip.py"), "--list", PDF_LIST, "--threads", "2"], check=False)


if __name__ == "__main__":
    main()

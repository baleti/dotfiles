#!/usr/bin/env python3
"""CLIP embeddings for the large images inside PDFs (one record per page).

For each PDF in the given list: find pages that carry an image of at least
200x200 px (pdfimages -list), render those pages (pdftoppm), send the JPEGs in
batches to the ai1 CLIP worker, and append {"remote", "page", "emb"} lines to
clip/pdf-pages.jsonl. A PDF is marked done only after its batch has been
embedded, so an interrupted run resumes where it stopped.

usage: pdf_pages_clip.py --list pdf-list.tsv [--collections a,b,c] [--threads 6]
"""
import argparse, concurrent.futures as cf, hashlib, json, os, re, subprocess, sys, tarfile, tempfile, time

import config

AI1 = config.AI1["ssh"]
JUMP = config.AI1["jump_host"]
OUT = os.path.join(config.DATA_DIR, "clip", "pdf-pages.jsonl")
DONE = os.path.join(config.DATA_DIR, "clip", "pdf-pages.done")
MIN_SIDE = 200
MAX_PAGES = 40
BATCH_IMAGES = 300


def log(*a):
    print(time.strftime("%T"), *a, file=sys.stderr, flush=True)


def load_done():
    if not os.path.exists(DONE):
        return set()
    return {l.rstrip("\n") for l in open(DONE, encoding="utf-8") if l.strip()}


def image_pages(pdf):
    """Pages with at least one image of MIN_SIDE x MIN_SIDE or larger."""
    out = subprocess.run(["pdfimages", "-list", pdf], capture_output=True, text=True, timeout=900).stdout
    pages = set()
    for line in out.splitlines()[2:]:
        f = line.split()
        if len(f) > 4 and f[0].isdigit() and f[3].isdigit() and f[4].isdigit():
            if int(f[3]) >= MIN_SIDE and int(f[4]) >= MIN_SIDE:
                pages.add(int(f[0]))
    return sorted(pages)[:MAX_PAGES]


def render(pdf, pages, tmp):
    """Render each page to <tmp>/<key>_p<N>.jpg; returns {name: page}."""
    key = hashlib.sha1(pdf.encode("utf-8", "surrogatepass")).hexdigest()[:12]
    made = {}
    for n in pages:
        base = os.path.join(tmp, f"{key}_p{n}")
        subprocess.run(["pdftoppm", "-jpeg", "-jpegopt", "quality=85", "-f", str(n), "-l", str(n),
                        "-scale-to", "512", "-singlefile", pdf, base], capture_output=True, timeout=600)
        if os.path.exists(base + ".jpg"):
            made[f"{key}_p{n}.jpg"] = n
    return made


def work(pdf, tmp):
    """Returns (pdf, {name: page}); a failed PDF yields no images but still counts as done."""
    try:
        pages = image_pages(pdf)
        return pdf, render(pdf, pages, tmp) if pages else {}
    except Exception as e:
        log("failed", pdf[-80:], e)
        return pdf, {}


def embed(names_dir, names):
    """Send the batch to ai1, return {name: embedding}."""
    buf = os.path.join(names_dir, "batch.tar")
    with tarfile.open(buf, "w") as t:
        for name in names:
            t.add(os.path.join(names_dir, name), arcname=name)
    cmd = f"{AI1} \"IDLE_SECS={config.AI1['idle_secs']} {config.AI1['clip_launcher']}\""
    with open(buf, "rb") as stdin:
        r = subprocess.run(["ssh", JUMP, cmd], stdin=stdin, capture_output=True, text=True, timeout=7200)
    if r.returncode != 0:
        raise RuntimeError(r.stderr[-300:])
    vecs = {}
    for line in r.stdout.splitlines():
        try:
            rec = json.loads(line)
            vecs[rec["name"]] = rec["emb"]
        except Exception:
            pass
    return vecs


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--list", required=True)
    ap.add_argument("--collections", default="")
    ap.add_argument("--threads", type=int, default=6)
    ap.add_argument("--limit", type=int, default=0)
    a = ap.parse_args()
    wanted = {c for c in a.collections.split(",") if c}
    if not wanted:
        cfg = json.load(open(os.path.expanduser("~/.config/indexes/collections.json")))["collections"]
        wanted = {n for n, f in cfg.items() if f.get("clip_pages")}
    pdfs, seen = [], set()
    for line in open(a.list, encoding="utf-8"):
        coll, _, path = line.rstrip("\n").partition("\t")
        if not path or (wanted and coll not in wanted) or path in seen:
            continue
        seen.add(path)
        pdfs.append(path)
    done = load_done()
    todo = [p for p in pdfs if p not in done]
    if a.limit:
        todo = todo[: a.limit]
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    log(f"{len(pdfs)} pdfs listed, {len(todo)} to do")

    with tempfile.TemporaryDirectory() as tmp, open(OUT, "a", encoding="utf-8") as out, \
            open(DONE, "a", encoding="utf-8") as donef, cf.ThreadPoolExecutor(a.threads) as ex:
        futures = [ex.submit(work, p, tmp) for p in todo]
        batch_pdfs, batch_names, mapping = [], [], {}
        finished = 0
        for fut in cf.as_completed(futures):
            pdf, made = fut.result()
            finished += 1
            batch_pdfs.append(pdf)
            mapping.update({n: (pdf, page) for n, page in made.items()})
            batch_names.extend(made)
            if len(batch_names) >= BATCH_IMAGES or finished == len(futures):
                if batch_names:
                    try:
                        vecs = embed(tmp, batch_names)
                    except Exception as e:
                        log("embed batch failed, will retry on next run:", e)
                        batch_pdfs, batch_names, mapping = [], [], {}
                        continue
                    for n in batch_names:
                        if n in vecs:
                            p, page = mapping[n]
                            out.write(json.dumps({"remote": p, "page": page, "emb": vecs[n]}) + "\n")
                    out.flush()
                    for n in batch_names:
                        try: os.remove(os.path.join(tmp, n))
                        except OSError: pass
                for p in batch_pdfs:
                    donef.write(p + "\n")
                donef.flush()
                log(f"{finished}/{len(futures)} pdfs done, {len(batch_names)} page images embedded in this batch")
                batch_pdfs, batch_names, mapping = [], [], {}


if __name__ == "__main__":
    main()

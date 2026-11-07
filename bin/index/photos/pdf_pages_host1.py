#!/usr/bin/env python3
"""PDF page CLIP job, runs on host1 next to the files (started by remote_pdf_pages.py on host3).

For every PDF in --todo: find pages carrying an image >= 200x200 px (pdfimages -list), render them (pdftoppm, 512 px),
embed the JPEGs with the CLIP container (~/ai1-native/bin/clip-run.sh) and append {"remote","page","emb"} to --out.
A PDF is appended to --done only after its batch was embedded; an interrupted or failed run resumes from there.
"""
import argparse, concurrent.futures as cf, hashlib, json, os, subprocess, sys, tarfile, tempfile, time

RUN = os.path.expanduser("~/ai1-native/bin/clip-run.sh")
MIN_SIDE, MAX_PAGES, BATCH_IMAGES, MAX_FAILS = 200, 40, 300, 3


def log(*a): print(time.strftime("%F %T"), *a, flush=True)


def image_pages(pdf):
    out = subprocess.run(["pdfimages", "-list", pdf], capture_output=True, text=True, timeout=900).stdout
    pages = set()
    for line in out.splitlines()[2:]:
        f = line.split()
        if len(f) > 4 and f[0].isdigit() and f[3].isdigit() and f[4].isdigit() and int(f[3]) >= MIN_SIDE and int(f[4]) >= MIN_SIDE:
            pages.add(int(f[0]))
    return sorted(pages)[:MAX_PAGES]


def render(pdf, pages, tmp):
    key = hashlib.sha1(pdf.encode("utf-8", "surrogatepass")).hexdigest()[:12]
    made = {}
    for n in pages:
        base = os.path.join(tmp, f"{key}_p{n}")
        subprocess.run(["pdftoppm", "-jpeg", "-jpegopt", "quality=85", "-f", str(n), "-l", str(n), "-scale-to", "512",
                        "-singlefile", pdf, base], capture_output=True, timeout=600)
        if os.path.exists(base + ".jpg"):
            made[f"{key}_p{n}.jpg"] = n
    return made


def work(pdf, tmp):
    try:
        pages = image_pages(pdf)
        return pdf, render(pdf, pages, tmp) if pages else {}
    except Exception as e:
        log("failed", pdf[-80:], str(e)[:80])
        return pdf, {}


def embed(tmp, names):
    buf = os.path.join(tmp, "batch.tar")
    with tarfile.open(buf, "w") as t:
        for n in names:
            t.add(os.path.join(tmp, n), arcname=n)
    with open(buf, "rb") as stdin:
        r = subprocess.run([RUN], stdin=stdin, capture_output=True, text=True, timeout=3600)
    os.remove(buf)
    if r.returncode:
        raise RuntimeError(r.stderr[-300:])
    vecs = {}
    for line in r.stdout.splitlines():
        try:
            rec = json.loads(line)
            if "emb" in rec: vecs[rec["name"]] = rec["emb"]
        except ValueError:
            pass
    return vecs


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--todo", required=True); ap.add_argument("--out", required=True); ap.add_argument("--done", required=True)
    ap.add_argument("--threads", type=int, default=3); ap.add_argument("--max-hours", type=float, default=20)
    a = ap.parse_args()
    deadline = time.time() + 3600 * a.max_hours
    done = set(open(a.done, encoding="utf-8").read().split("\n")) if os.path.exists(a.done) else set()
    todo = [l.rstrip("\n") for l in open(a.todo, encoding="utf-8") if l.strip() and l.rstrip("\n") not in done]
    log(f"{len(todo)} pdfs to do")
    fails = 0
    with tempfile.TemporaryDirectory(dir=os.path.expanduser("~/.cache")) as tmp, open(a.out, "a", encoding="utf-8") as out, \
            open(a.done, "a", encoding="utf-8") as donef, cf.ThreadPoolExecutor(a.threads) as ex:
        pending = iter(todo)
        inflight, batch_pdfs, names, mapping, finished = set(), [], [], {}, 0
        def flush():
            nonlocal batch_pdfs, names, mapping, fails
            if names:
                try:
                    vecs = embed(tmp, names)
                except Exception as e:
                    fails += 1
                    log("embed batch failed:", str(e)[:200])
                    for n in names:
                        try: os.remove(os.path.join(tmp, n))
                        except OSError: pass
                    batch_pdfs, names, mapping = [], [], {}
                    return
                fails = 0
                for n in names:
                    if n in vecs:
                        p, page = mapping[n]
                        out.write(json.dumps({"remote": p, "page": page, "emb": vecs[n]}) + "\n")
                    try: os.remove(os.path.join(tmp, n))
                    except OSError: pass
                out.flush()
            for p in batch_pdfs: donef.write(p + "\n")
            donef.flush()
            log(f"{finished}/{len(todo)} pdfs, {len(names)} page images embedded in this batch")
            batch_pdfs, names, mapping = [], [], {}
        # keep a bounded number of PDFs in flight so rendered JPEGs never pile up
        while True:
            while len(inflight) < a.threads * 4 and (p := next(pending, None)) is not None:
                inflight.add(ex.submit(work, p, tmp))
            if not inflight: break
            ready, rest = cf.wait(inflight, return_when=cf.FIRST_COMPLETED)
            inflight = set(rest)
            for fut in ready:
                pdf, made = fut.result(); finished += 1
                batch_pdfs.append(pdf); mapping.update({n: (pdf, pg) for n, pg in made.items()}); names.extend(made)
                if len(names) >= BATCH_IMAGES:
                    flush()
            if fails >= MAX_FAILS:
                log(f"{MAX_FAILS} embed batches failed in a row; stopping this run"); break
            if time.time() > deadline:
                log("time budget used up; the rest follows the next run"); break
        if fails < MAX_FAILS: flush()
        for f in inflight: f.cancel()
    log("finished")


if __name__ == "__main__":
    main()

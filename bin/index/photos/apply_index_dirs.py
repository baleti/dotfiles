#!/usr/bin/env python3
"""Make the directories chosen in the picker's Settings > Indexing take effect.

Reads ~/.config/indexes/index-dirs.json (see catalog/index_dirs.py), then
  path  runs the local walk of the file-name catalog (catalog-local.service; what is no longer under a chosen directory
        drops out of name search, what is new appears; the live watcher already follows the new list)
  fts   builds the managed collection "user-dirs" for the switched-on types: bm25 = Recoll index (/fts; a changed directory
        list resets it, so a removed directory's documents disappear), chroma = semantic text index (/chroma), clip / face =
        the images of those directories through the ai1 GPU workers (/clip, /face; resumable, records stay when a directory is removed)

    apply_index_dirs.py [--only path|fts]     progress and result: ~/.cache/indexes/index-dirs-status.json
Started by the picker through systemd-run (nice 19, idle I/O), so it survives the picker closing."""
import argparse, json, os, re, shutil, subprocess, sys, time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(os.path.dirname(HERE), "catalog"))
import index_dirs

def status(state, message, **extra):
    os.makedirs(os.path.dirname(index_dirs.STATUS), exist_ok=True)
    tmp = index_dirs.STATUS + ".tmp"
    json.dump({"state": state, "message": message, "updated": time.time(), **extra}, open(tmp, "w"))
    os.replace(tmp, index_dirs.STATUS)

def conf_topdirs(conf):
    try:
        text = open(os.path.join(conf, "recoll.conf")).read()
    except OSError:
        return None
    m = re.search(r'^topdirs\s*=\s*(.*)$', text, re.M)
    return m.group(1).strip() if m else None

IMAGE_EXT = (".jpg", ".jpeg", ".png", ".webp")
IDX = os.path.dirname(os.path.dirname(index_dirs.FTS_INDEX))               # ~/.cache/indexes
USER_DIR = os.path.dirname(index_dirs.FTS_INDEX)                          # ~/.cache/indexes/user-dirs
CHROMA = os.path.join(USER_DIR, "chroma")
PY = os.path.join(IDX, "venv/bin/python")

def run(cmd, what):
    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode != 0:
        lines = (r.stderr or r.stdout).strip().splitlines()
        raise RuntimeError(f"{what} failed: " + (lines[-1][:200] if lines else f"exit {r.returncode}"))
    return r

def list_images(dirs):
    """Image files under the directories, as paths relative to / (index_photos.py --base / makes them absolute again)."""
    out = []
    for d in dirs:
        for root, subdirs, files in os.walk(d):
            subdirs[:] = [x for x in subdirs if not x.startswith(".")]
            out += [os.path.join(root, f).lstrip("/") for f in files if f.lower().endswith(IMAGE_EXT)]
    return out

def do_fts(want):
    """Builds what is switched on; returns (notes, missing directories)."""
    dirs, types = want["dirs"], {t: want[t] for t in index_dirs.FTS_TYPES}
    conf = index_dirs.FTS_INDEX
    notes = []
    if not dirs or not any(types.values()):
        shutil.rmtree(USER_DIR, ignore_errors=True)
        return ["full-text index removed (nothing to index)"], []
    existing = [d for d in dirs if os.path.isdir(d)]
    missing = [d for d in dirs if d not in existing]
    if not existing:
        return ["none of the full-text directories exist"], missing
    os.makedirs(conf, exist_ok=True)
    topdirs = " ".join('"%s"' % d.replace('"', "") for d in existing)
    changed = conf_topdirs(conf) != topdirs
    need_text = types["bm25"] or types["chroma"]            # the semantic index is built from the Recoll one
    if need_text:
        with open(os.path.join(conf, "recoll.conf"), "w") as f:
            f.write(f"topdirs = {topdirs}\n")
        status("running", "BM25 text index: reading files" + (" (new directory list)" if changed else ""), stage="bm25")
        reset = changed and os.path.isdir(os.path.join(conf, "xapiandb"))
        run(["recollindex", "-c", conf] + (["-z"] if reset else []), "recollindex")
        notes.append("BM25 text index built" if types["bm25"] else "text extracted for the semantic index")
    else:
        shutil.rmtree(conf, ignore_errors=True)
    if types["chroma"]:
        if changed:
            shutil.rmtree(CHROMA, ignore_errors=True)
        status("running", "semantic index: embedding text on ai1 (can take long)", stage="chroma")
        run([PY, os.path.join(HERE, "..", "chroma", "recoll_fulltext_to_chroma.py"), "--recoll-conf", conf, "--db", CHROMA], "semantic indexing")
        notes.append("semantic index built")
        subprocess.run(["systemctl", "--user", "stop", "chroma-search.service"], capture_output=True)   # reloads on next /chroma
    elif os.path.isdir(CHROMA):
        shutil.rmtree(CHROMA, ignore_errors=True)
        subprocess.run(["systemctl", "--user", "stop", "chroma-search.service"], capture_output=True)
        notes.append("semantic index removed")
    for kind, label in (("clip", "image contents (/clip)"), ("face", "faces (/face)")):
        if not types[kind]:
            continue
        status("running", f"{label}: listing images", stage=kind)
        images = list_images(existing)
        if not images:
            notes.append(f"{label}: no images found")
            continue
        lst = os.path.join(USER_DIR, f"images-{kind}.txt")
        open(lst, "w").write("\n".join(images) + "\n")
        status("running", f"{label}: {len(images):,} images on ai1 (resumable, new ones only)", stage=kind)
        run([PY, os.path.join(HERE, "index_photos.py"), "--base", "/", "--list", lst, "--only", kind], f"{label} indexing")
        notes.append(f"{label} indexed ({len(images):,} images)")
    return notes, missing

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--only", choices=["path", "fts"])
    a = ap.parse_args()
    want = index_dirs.load()
    notes = []
    try:
        if a.only in (None, "path"):
            status("running", "file-name index: walking the chosen directories", stage="path")
            r = subprocess.run(["systemctl", "--user", "start", "catalog-local.service"], capture_output=True, text=True)
            if r.returncode != 0:
                raise RuntimeError("catalog-local failed: " + (r.stderr.strip() or "see journalctl --user -u catalog-local"))
            notes.append("file-name index updated")
        if a.only in (None, "fts"):
            more, missing = do_fts(want["fts"])
            notes += more
            if missing:
                notes.append("not found: " + ", ".join(missing))
        status("done", "; ".join(notes))
    except Exception as e:
        status("error", str(e))
        return 1

if __name__ == "__main__":
    sys.exit(main())

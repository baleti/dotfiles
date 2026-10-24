#!/usr/bin/env python3
"""Image CLIP + InsightFace job. Runs on host1 (start it with remote_images.py on host3, never by hand with credentials).

For the paths in ~/.config/indexes/image-paths.json (written by remote_images.py from collections.json) it
  1. lists the images (Drive: `rclone lsf -R` with RCLONE_CONFIG pointing at a RAM-only file; host1's own disks: os.walk),
  2. keeps the NEW ones (no record yet) and the CHANGED ones (size or modified time differs from what was processed),
  3. sends them in batches to the ai1 GPU workers through index_photos.py --force, for at most "hours" hours
     (resumable: the next run continues; smallest folders first),
  4. records what it processed in images-state.db, removes the RAM credentials, writes images-job-status.json.
Records go to this host's ~/.cache/indexes/photos/{clip,faces}/*.jsonl; remote_images.py pulls them to host3.

Keys are the same as host3's records: Drive files `gdrive-crypt:<path below the mount>`, host1's backups
`/home/user1/backups/<path>` (host3 maps that to /mnt/backups when it loads them).
"""
import fcntl, json, os, signal, sqlite3, subprocess, sys, time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import config                                   # noqa: E402
import index_photos as ip                       # noqa: E402

HOME = os.path.expanduser("~")
PATHS = os.path.join(HOME, ".config/indexes/image-paths.json")
DATA = config.DATA_DIR
STATE = os.path.join(DATA, "images-state.db")
STATUS = os.path.join(DATA, "images-job-status.json")
LOCK = os.path.join(DATA, "images-job.lock")
MOUNT3 = "/home/user1/gdrive-rclone-crypt"       # how host3 names the Drive mount
BACKUPS3, BACKUPS1 = "/mnt/backups", "/home/user1/backups"
REMOTE = config.REMOTE                           # gdrive-crypt:
EXT = (".jpg", ".jpeg", ".png", ".webp")
CHUNK = 1500
BATCH_TIMEOUT = 40 * 60          # a 1500-image batch normally takes about 8 minutes
MAX_STALLS = 3                   # consecutive batches without a single new record: give up this run
KINDS = ("clip", "face")
KEY = {"clip": "clip", "face": "faces"}          # worker -> flag name in image-paths.json


def log(*a):
    print(time.strftime("%F %T"), *a, flush=True)


def status(state, **extra):
    tmp = STATUS + ".tmp"
    json.dump({"state": state, "updated": time.time(), **extra}, open(tmp, "w"))
    os.replace(tmp, STATUS)


def run_batch(cmd, timeout):
    """Run one index_photos batch; kill it (and its ssh children) if it stalls, e.g. after a broken GPU-worker pipe."""
    p = subprocess.Popen(cmd, start_new_session=True)
    try:
        p.wait(timeout=timeout)
        return True
    except subprocess.TimeoutExpired:
        os.killpg(p.pid, signal.SIGKILL)
        p.wait()
        return False


def cleanup_credentials():
    cfg = os.environ.get("RCLONE_CONFIG", "")
    if cfg.startswith("/dev/shm/"):
        try:
            subprocess.run(["shred", "-u", cfg], check=False)
            os.rmdir(os.path.dirname(cfg))
        except OSError:
            pass


def entries(cfg):
    """[(key base, folder below the base, local dir or None, flags)] for each configured path this host can reach."""
    out = []
    for e in cfg["paths"]:
        p, flags = e["path"].rstrip("/"), {k: e.get(k, True) for k in ("clip", "faces")}
        if p == MOUNT3 or p.startswith(MOUNT3 + "/"):
            out.append((REMOTE, p[len(MOUNT3):].lstrip("/"), None, flags))
        elif p.startswith(BACKUPS3 + "/"):
            rel = p[len(BACKUPS3):].lstrip("/")
            out.append((BACKUPS1 + "/", rel, os.path.join(BACKUPS1, rel), flags))
        else:
            log("skipped, this host cannot read it:", p)
    return out


def list_images(rel, local):
    """{path below base: signature} for the images under a folder."""
    got = {}
    if local is None:
        r = subprocess.run(["rclone", "lsf", "-R", "--files-only", "--format", "pst", "--separator", "|", REMOTE + rel],
                           capture_output=True, text=True)
        if r.returncode != 0:
            log("rclone lsf failed for", rel, r.stderr.strip()[-200:])
            return got
        for line in r.stdout.splitlines():
            try:
                path, size, mtime = line.rsplit("|", 2)
            except ValueError:
                continue
            if path.lower().endswith(EXT):
                got[(rel + "/" + path).lstrip("/")] = f"{size}|{mtime}"
    else:
        for root, _dirs, files in os.walk(local):
            for f in files:
                if f.lower().endswith(EXT):
                    full = os.path.join(root, f)
                    try:
                        st = os.stat(full)
                    except OSError:
                        continue
                    got[os.path.relpath(full, BACKUPS1)] = f"{st.st_size}|{int(st.st_mtime)}"
    return got


class Done:
    """Which keys already have a clip / face record. Starts from the files, grows by reading what the workers append."""
    def __init__(self):
        self.sets, self.pos = {}, {}
        for w in KINDS:
            path = ip.WORKERS[w][1]
            self.sets[w] = ip.done_set(path)
            self.pos[w] = os.path.getsize(path) if os.path.exists(path) else 0
            known = os.path.join(DATA, f"images-known-{w}.txt")      # keys host3 already holds records for (pushed at each start)
            if os.path.exists(known):
                self.sets[w] |= {l.rstrip("\n") for l in open(known, encoding="utf-8")}

    def refresh(self):
        for w in KINDS:
            path = ip.WORKERS[w][1]
            if not os.path.exists(path) or os.path.getsize(path) <= self.pos[w]:
                continue
            with open(path, "rb") as f:
                f.seek(self.pos[w])
                for line in f:
                    if not line.endswith(b"\n"):
                        break
                    try:
                        self.sets[w].add(json.loads(line)["remote"])
                    except Exception:
                        pass
                    self.pos[w] += len(line)


def main():
    dry = "--dry-run" in sys.argv
    cap = int(sys.argv[sys.argv.index("--max-images") + 1]) if "--max-images" in sys.argv else 0      # testing: stop after this many
    os.makedirs(DATA, exist_ok=True)
    lock = open(LOCK, "w")
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        sys.exit("another image job is running")
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(143))
    started = time.time()
    try:
        cfg = json.load(open(PATHS))
        deadline = started + 3600 * float(cfg.get("hours", 20))
        status("listing", started=started)
        db = sqlite3.connect(STATE)
        db.execute("CREATE TABLE IF NOT EXISTS images(key TEXT PRIMARY KEY, sig TEXT NOT NULL)")
        known = dict(db.execute("SELECT key, sig FROM images"))
        done = Done()
        work = {}                                   # (base, needed workers) -> [(rel, key, sig)]
        adopt, counts = [], {}
        for base, rel, local, flags in entries(cfg):
            files = list_images(rel, local)
            new = changed = 0
            for sub, sig in files.items():
                key = base + sub
                need = tuple(w for w in KINDS if flags[KEY[w]] and (key not in done.sets[w] or (key in known and known[key] != sig)))
                if need:
                    work.setdefault((base, need), []).append((sub, key, sig))
                    if any(key in done.sets[w] for w in need):
                        changed += 1
                    else:
                        new += 1
                elif key not in known:
                    adopt.append((key, sig))        # processed before this job existed: baseline for change detection
            counts[rel or "/"] = {"images": len(files), "new": new, "changed": changed}
            log(f"{rel or '/'}: {len(files):,} images, {new:,} new, {changed:,} changed")
        total = sum(len(v) for v in work.values())
        if dry:
            log(f"dry run: {total:,} images to process, {len(adopt):,} already processed (baseline for change detection not written)")
            return
        db.executemany("INSERT OR REPLACE INTO images VALUES (?,?)", adopt)
        db.commit()
        processed = stalls = 0
        for (base, need), items in sorted(work.items(), key=lambda kv: len(kv[1])):          # smallest groups first
            for i in range(0, len(items), CHUNK):
                if time.time() > deadline:
                    log("time budget used up; the rest follows the next run")
                    status("budget", started=started, processed=processed, remaining=total - processed, folders=counts)
                    return
                if cap and processed >= cap:
                    status("budget", started=started, processed=processed, remaining=total - processed, folders=counts)
                    log("--max-images reached")
                    return
                chunk = items[i:i + (min(CHUNK, cap - processed) if cap else CHUNK)]
                lst = os.path.join(DATA, "images-batch.txt")
                open(lst, "w", encoding="utf-8").write("\n".join(c[0] for c in chunk) + "\n")
                cmd = [sys.executable, os.path.join(HERE, "index_photos.py"), "--base", base, "--list", lst, "--force"]
                for w in need:
                    cmd += ["--only", w]
                log(f"batch {processed + 1:,}-{processed + len(chunk):,} of {total:,} via {'+'.join(need)}")
                status("running", started=started, processed=processed, remaining=total - processed, folders=counts)
                finished = run_batch(cmd, BATCH_TIMEOUT)
                if not finished:
                    log(f"batch stalled for {BATCH_TIMEOUT // 60} min and was killed")
                done.refresh()
                ok = [(k, s) for _, k, s in chunk if all(k in done.sets[w] for w in need)]
                db.executemany("INSERT OR REPLACE INTO images VALUES (?,?)", ok)
                db.commit()
                processed += len(ok)
                stalls = 0 if ok else stalls + 1
                if stalls >= MAX_STALLS:
                    log(f"{MAX_STALLS} batches in a row produced nothing (GPU worker down?); stopping this run")
                    status("error", started=started, error="no progress", processed=processed, remaining=total - processed)
                    return
                if len(ok) < len(chunk):
                    log(f"{len(chunk) - len(ok)} of this batch got no record (unreadable or the GPU worker failed); they are retried next run")
        status("done", started=started, finished=time.time(), processed=processed, remaining=0, folders=counts)
        log(f"done: {processed:,} images processed")
    except SystemExit:
        status("stopped", started=started)
        raise
    except Exception as e:
        status("error", started=started, error=str(e)[:300])
        raise
    finally:
        cleanup_credentials()


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""Image CLIP + InsightFace for the paths in collections.json, run on host1 (host3 has no GPU; ai1 sits behind host1).

    remote_images.py start [--force]   every 3 days (the daily timer calls it; it acts only when 3 days have passed since
                                       the last start): copy the code and the path list to host1, put the Drive credentials
                                       into RAM there (/dev/shm, 0600, never disk, never a command line) and start the
                                       detached job host1_image_job.py, which deletes them when it ends
    remote_images.py pull              append the records host1 has produced since the last pull to our clip/faces files;
                                       a changed file's old record is replaced (idempotent, called every 2 h)
    remote_images.py status            what the host1 job is doing and how much is waiting to be pulled

What gets processed: the new and changed (size or modified time) images under the paths of collections.json whose
"clip" / "faces" flag is on (both are on unless a path object says otherwise), for at most "image_job_hours" hours a run.
"""
import argparse, configparser, json, os, re, subprocess, sys, time

import config
import index_config as ic

HOST = "host1"
HOME = os.path.expanduser("~")
DATA = config.DATA_DIR
STATE = os.path.join(DATA, "images-remote.json")
FILES = {"clip": os.path.join(DATA, "clip", "clip.jsonl"), "faces": os.path.join(DATA, "faces", "faces.jsonl")}
REMOTE_DATA = "/home/user1/.cache/indexes/photos"
REMOTE_FILES = {"clip": REMOTE_DATA + "/clip/clip.jsonl", "faces": REMOTE_DATA + "/faces/faces.jsonl"}
RAM_DIR = "/dev/shm/rc-images"
EVERY = 3 * 86400
CODE = ["index_photos.py", "config.py", "host1_image_job.py"]
REMOTE_CODE = "/home/user1/bin/index/photos"
PULL_MAX = 200 * 2**20                        # bytes fetched per file per call


def ssh(cmd, **kw):
    return subprocess.run(["ssh", "-o", "BatchMode=yes", HOST, cmd], capture_output=True, **kw)


def load_state():
    try:
        return json.load(open(STATE))
    except (OSError, ValueError):
        return {}


def save_state(st):
    tmp = STATE + ".tmp"
    json.dump(st, open(tmp, "w"), indent=1)
    os.replace(tmp, STATE)


def remote_size(path):
    r = ssh(f"stat -c %s {path} 2>/dev/null || echo 0", text=True)
    return int(r.stdout.strip() or 0)


def job_active():
    return ssh("systemctl --user is-active image-index", text=True).stdout.strip() == "active"


def start(force, dry=False, max_images=0):
    st = load_state()
    if "offsets" not in st:                   # first use: what host1 already holds is already in our files (merged on 2026-10-10)
        st["offsets"] = {k: remote_size(p) for k, p in REMOTE_FILES.items()}
        save_state(st)
    if not force and not dry and time.time() - st.get("last_start", 0) < EVERY:
        print("not due yet (every 3 days)")
        return 0
    if job_active():
        print("the host1 job is still running")
        return 0
    cfg = ic.load()
    ents = ic.entries(cfg)
    paths = {"hours": float(cfg.get("image_job_hours", 20)),
             "paths": [{"path": p, "clip": f["clip"], "faces": f["faces"]} for p, f in ents if f["clip"] or f["faces"]]}
    if subprocess.run(["scp", "-q", "-o", "BatchMode=yes"] + [os.path.join(os.path.dirname(os.path.abspath(__file__)), f) for f in CODE]
                      + [f"{HOST}:{REMOTE_CODE}/"]).returncode:
        print("could not copy the code to host1")
        return 1
    r = ssh("mkdir -p /home/user1/.config/indexes && cat > /home/user1/.config/indexes/image-paths.json", input=json.dumps(paths).encode())
    if r.returncode:
        print("could not write the path list:", r.stderr.decode()[-200:])
        return 1
    # keys host3 already has records for, so the job does not redo them (host1 only knows its own records)
    for kind, worker in (("clip", "clip"), ("faces", "face")):
        keys = set()
        if os.path.exists(FILES[kind]):
            with open(FILES[kind], "rb") as f:
                for line in f:
                    m = REMOTE_RE.search(line)
                    if m:
                        keys.add(json.loads(b'"' + m.group(1) + b'"'))
        r = ssh(f"cat > {REMOTE_DATA}/images-known-{worker}.txt", input=("\n".join(sorted(keys)) + "\n").encode())
        if r.returncode:
            print("could not send the known keys:", r.stderr.decode()[-200:])
            return 1
    # the two rclone sections the job needs, straight from our rclone.conf into a 0600 file in RAM on host1
    rc = configparser.ConfigParser(interpolation=None)
    rc.read(os.path.expanduser("~/.config/rclone/rclone.conf"))
    body = "".join(f"[{s}]\n" + "".join(f"{k} = {v}\n" for k, v in rc[s].items()) + "\n" for s in ("gdrive", "gdrive-crypt"))
    r = ssh(f"umask 077; mkdir -p {RAM_DIR} && cat > {RAM_DIR}/rclone.conf && chmod 600 {RAM_DIR}/rclone.conf", input=body.encode())
    if r.returncode:
        print("could not place the credentials:", r.stderr.decode()[-200:])
        return 1
    r = ssh(f"systemd-run --user --unit=image-index --collect --nice=10 -p Environment=RCLONE_CONFIG={RAM_DIR}/rclone.conf "
            f"/usr/bin/python3 {REMOTE_CODE}/host1_image_job.py{' --dry-run' if dry else ''}{f' --max-images {max_images}' if max_images else ''}", text=True)
    print((r.stdout + r.stderr).strip().splitlines()[-1] if (r.stdout + r.stderr).strip() else "started")
    if r.returncode:
        return 1
    if not dry:
        st["last_start"] = time.time()
        save_state(st)
    return 0


REMOTE_RE = re.compile(rb'"remote": "((?:[^"\\]|\\.)*)"')


def pull_one(kind, st):
    off = st["offsets"].get(kind, 0)
    size = remote_size(REMOTE_FILES[kind])
    if size <= off:
        return 0
    r = ssh(f"tail -c +{off + 1} {REMOTE_FILES[kind]} | head -c {min(size - off, PULL_MAX)}")
    data = r.stdout
    cut = data.rfind(b"\n") + 1                # only whole records
    data = data[:cut]
    if not data:
        return 0
    incoming = {}
    for line in data.splitlines(keepends=True):
        m = REMOTE_RE.search(line)
        if m:
            incoming[m.group(1)] = line          # a later record for the same file wins
    path = FILES[kind]
    have = set()
    if os.path.exists(path):
        with open(path, "rb") as f:
            for line in f:
                m = REMOTE_RE.search(line)
                if m and m.group(1) in incoming:
                    have.add(m.group(1))
    if have:                                     # changed files: drop their old records, then add the new ones
        tmp = path + ".tmp"
        with open(path, "rb") as src, open(tmp, "wb") as dst:
            for line in src:
                m = REMOTE_RE.search(line)
                if not (m and m.group(1) in have):
                    dst.write(line)
            dst.write(b"".join(incoming[k] for k in incoming))
        os.replace(tmp, path)
    else:
        with open(path, "ab") as f:
            f.write(b"".join(incoming.values()))
    st["offsets"][kind] = off + cut
    save_state(st)
    return len(incoming), len(have)


def pull():
    if not job_active():                          # the job removes its credentials itself; this covers a job that never got to run
        ssh(f"shred -u {RAM_DIR}/rclone.conf 2>/dev/null; rmdir {RAM_DIR} 2>/dev/null; true")
    st = load_state()
    if "offsets" not in st:
        st["offsets"] = {k: remote_size(p) for k, p in REMOTE_FILES.items()}
        save_state(st)
        print("baseline set; nothing to pull yet")
        return 0
    for kind in FILES:
        for _ in range(50):                      # bounded: 50 x 200 MB per call
            got = pull_one(kind, st)
            if not got:
                break
            print(f"{kind}: {got[0]:,} records pulled, {got[1]:,} replaced")
    return 0


def status():
    st = load_state()
    print("last start:", time.strftime("%F %T", time.localtime(st["last_start"])) if st.get("last_start") else "never")
    print("host1 job:", "running" if job_active() else "not running")
    r = ssh(f"cat {REMOTE_DATA}/images-job-status.json 2>/dev/null", text=True)
    if r.stdout.strip():
        j = json.loads(r.stdout)
        j.pop("folders", None)
        j["updated"] = time.strftime("%F %T", time.localtime(j["updated"]))
        print("job status:", j)
    for kind, p in REMOTE_FILES.items():
        print(f"{kind}: {max(0, remote_size(p) - st.get('offsets', {}).get(kind, 0)) / 2**20:.1f} MiB waiting on host1")
    return 0


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("cmd", choices=["start", "pull", "status"])
    ap.add_argument("--force", action="store_true", help="start: do not wait for the 3-day interval")
    ap.add_argument("--max-images", type=int, default=0, help="start: stop after this many images (testing)")
    ap.add_argument("--dry-run", action="store_true", help="start: list and count what would be processed, send nothing to the GPUs")
    a = ap.parse_args()
    sys.exit({"start": lambda: start(a.force, a.dry_run, a.max_images), "pull": pull, "status": status}[a.cmd]())


if __name__ == "__main__":
    main()

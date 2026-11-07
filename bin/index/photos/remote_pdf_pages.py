#!/usr/bin/env python3
"""PDF page CLIP on host1 (the files are there, the CLIP container is there; host3 only coordinates).

    remote_pdf_pages.py start     send the not-yet-done PDFs under ~/backups to host1 and start the detached job
                                  pdf_pages_host1.py there (no-op while it is running)
    remote_pdf_pages.py pull      append the records / done-markers host1 has produced since the last pull to our
                                  clip/pdf-pages.{jsonl,done} (offset based, idempotent; run every 2 h and by the nightly index)
    remote_pdf_pages.py status

Drive PDFs (gdrive-rclone-crypt) are not handled: host1 has no rclone credentials for them (see README).
"""
import json, os, subprocess, sys

import config
import index_config as ic

HOST, HOME = "host1", os.path.expanduser("~")
DATA = config.DATA_DIR
LOCAL = {"out": os.path.join(DATA, "clip", "pdf-pages.jsonl"), "done": os.path.join(DATA, "clip", "pdf-pages.done")}
R = "/home/user1/.cache/indexes/photos"
REMOTE = {"out": R + "/pdf-pages.jsonl", "done": R + "/pdf-pages.done", "todo": R + "/pdf-todo.txt"}
STATE = os.path.join(DATA, "pdf-remote.json")
CODE = ["pdf_pages_host1.py"]
RCODE = "/home/user1/bin/index/photos"
LISTFILE = os.path.join(DATA, "pdf-list.tsv")
ROOT = "/home/user1/backups/"
PULL_MAX = 100 * 2**20


def ssh(cmd, **kw):
    return subprocess.run(["ssh", "-o", "BatchMode=yes", HOST, cmd], capture_output=True, **kw)


def state():
    try: return json.load(open(STATE))
    except (OSError, ValueError): return {}


def save(st):
    json.dump(st, open(STATE + ".tmp", "w")); os.replace(STATE + ".tmp", STATE)


def active():
    return ssh("systemctl --user is-active pdf-pages", text=True).stdout.strip() == "active"


def start():
    if active():
        print("the host1 PDF job is still running"); return 0
    pull()
    cfg = ic.load()
    done = {l.rstrip("\n") for l in open(LOCAL["done"], encoding="utf-8")} if os.path.exists(LOCAL["done"]) else set()
    todo, seen = [], set()
    for line in open(LISTFILE, encoding="utf-8"):
        _, _, p = line.rstrip("\n").partition("\t")
        if p.startswith(ROOT) and p not in seen and p not in done and ic.flag(config.to_local(p), "clip_pages", cfg):
            seen.add(p); todo.append(p)
    print(f"{len(todo):,} PDFs to do on host1")
    if not todo: return 0
    if subprocess.run(["scp", "-q", "-o", "BatchMode=yes"] + [os.path.join(os.path.dirname(os.path.abspath(__file__)), f) for f in CODE]
                      + [f"{HOST}:{RCODE}/"]).returncode:
        print("could not copy the code"); return 1
    if ssh(f"mkdir -p {R} && cat > {REMOTE['todo']}", input="\n".join(todo).encode() + b"\n").returncode:
        print("could not send the PDF list"); return 1
    r = ssh(f"systemd-run --user --unit=pdf-pages --collect --nice=10 -p MemoryMax=5G -p CPUQuota=400% "
            f"/usr/bin/python3 {RCODE}/pdf_pages_host1.py --todo {REMOTE['todo']} --out {REMOTE['out']} --done {REMOTE['done']} --threads 3", text=True)
    print((r.stdout + r.stderr).strip().splitlines()[-1] if (r.stdout + r.stderr).strip() else "started")
    return r.returncode


def remote_size(p):
    return int(ssh(f"stat -c %s {p} 2>/dev/null || echo 0", text=True).stdout.strip() or 0)


def pull():
    st = state(); st.setdefault("offsets", {"out": 0, "done": 0})
    for kind in ("out", "done"):                     # records first, done-markers second: a marker never precedes its data
        for _ in range(50):
            off, size = st["offsets"][kind], remote_size(REMOTE[kind])
            if size <= off: break
            data = ssh(f"tail -c +{off + 1} {REMOTE[kind]} | head -c {min(size - off, PULL_MAX)}").stdout
            data = data[:data.rfind(b"\n") + 1]
            if not data: break
            os.makedirs(os.path.dirname(LOCAL[kind]), exist_ok=True)
            with open(LOCAL[kind], "ab") as f:
                f.write(data)
            st["offsets"][kind] = off + len(data); save(st)
            print(f"{kind}: {data.count(b'\n'):,} lines pulled")
    return 0


def status():
    st = state()
    print("host1 job:", "running" if active() else "not running")
    print(ssh("journalctl --user -u pdf-pages -n 3 --no-pager -o cat 2>/dev/null", text=True).stdout.strip())
    for k in ("out", "done"):
        print(f"{k}: {(remote_size(REMOTE[k]) - st.get('offsets', {}).get(k, 0)) / 2**20:.1f} MiB waiting on host1")
    return 0


if __name__ == "__main__":
    sys.exit({"start": start, "pull": pull, "status": status}[sys.argv[1] if len(sys.argv) > 1 else "status"]())

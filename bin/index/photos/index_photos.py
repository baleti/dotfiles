#!/usr/bin/env python3
"""One gdrive staging pass, two GPU workers on ai1: face (InsightFace) and CLIP.

Each chunk is copied locally once via rclone, then added to a tar stream for
each worker. Output: faces/faces.jsonl and clip/clip.jsonl (remote path added).
Resumable: paths already present in an output file are skipped.

usage: index_photos.py --list DATA/lists/all.txt [--list ...] [--limit N]
"""
import argparse, json, os, subprocess, sys, tarfile, tempfile, threading

import config
AI1 = config.AI1["ssh"]
JUMP = config.AI1["jump_host"]
WORKERS = {
    "face": (config.AI1["worker_launcher"], os.path.join(config.DATA_DIR, "faces", "faces.jsonl")),
    "clip": (config.AI1["clip_launcher"], os.path.join(config.DATA_DIR, "clip", "clip.jsonl")),
}

def done_set(path):
    seen = set()
    if os.path.exists(path):
        for line in open(path, encoding="utf-8"):
            try: seen.add(json.loads(line)["remote"])
            except Exception: pass
    return seen

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--base", default=config.REMOTE)
    ap.add_argument("--list", action="append", required=True)
    ap.add_argument("--chunk", type=int, default=64)
    ap.add_argument("--idle", type=int, default=config.AI1["idle_secs"])
    ap.add_argument("--limit", type=int, default=0)
    ap.add_argument("--only", choices=list(WORKERS), action="append")
    a = ap.parse_args()
    which = a.only or list(WORKERS)
    paths = []
    for lst in a.list:
        paths += [l.strip() for l in open(lst, encoding="utf-8") if l.strip()]
    if a.limit: paths = paths[: a.limit]
    procs, outs, dones = {}, {}, {}
    for w in which:
        launcher, out = WORKERS[w]
        os.makedirs(os.path.dirname(out), exist_ok=True)
        dones[w] = done_set(out)
        outs[w] = open(out, "a", encoding="utf-8")
        procs[w] = subprocess.Popen(["ssh", JUMP, f"{AI1} \"IDLE_SECS={a.idle} {launcher}\""],
                                    stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=sys.stderr)
    def reader(w):
        for line in procs[w].stdout:
            rec = json.loads(line)
            rec["remote"] = a.base + rec["name"].lstrip("./")
            outs[w].write(json.dumps(rec) + "\n"); outs[w].flush()
    threads = [threading.Thread(target=reader, args=(w,)) for w in which]
    [t.start() for t in threads]
    tars = {w: tarfile.open(fileobj=procs[w].stdin, mode="w|") for w in which}
    # dones hold full remote names (remote prefix + path), so compare with the base prefixed
    todo = [p for p in paths if any(a.base + p not in dones[w] for w in which)]
    print(f"{len(paths)} listed, {len(todo)} to do", file=sys.stderr, flush=True)
    for i in range(0, len(todo), a.chunk):
        chunk = todo[i:i + a.chunk]
        with tempfile.TemporaryDirectory() as tmp:
            lst = os.path.join(tmp, "list.txt")
            open(lst, "w", encoding="utf-8").write("\n".join(chunk) + "\n")
            subprocess.run(["rclone", "copy", "--files-from-raw", lst, "--transfers", "8",
                            a.base, os.path.join(tmp, "img")], check=True)
            for rel in chunk:
                p = os.path.join(tmp, "img", rel)
                if not os.path.exists(p): continue
                for w in which:
                    if a.base + rel not in dones[w]:
                        tars[w].add(p, arcname=rel)
        print(f"staged {min(i + a.chunk, len(todo))}/{len(todo)}", file=sys.stderr, flush=True)
    for w in which:
        tars[w].close(); procs[w].stdin.close()
    [t.join() for t in threads]
    for w in which:
        procs[w].wait(); outs[w].close()
        print(f"{w}: rc={procs[w].returncode}", file=sys.stderr)

if __name__ == "__main__":
    main()

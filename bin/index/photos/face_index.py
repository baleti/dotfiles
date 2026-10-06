#!/usr/bin/env python3
"""Stream gdrive images to ai1's face worker and collect face embeddings.

host3 stages each chunk of images locally via rclone (the configured remote), streams
them as a tar over ssh (host1 -> ai1), and appends the worker's JSON-lines
output to --out, adding the full remote path to each record.

usage: face_index.py --base REMOTE --list files.txt --out faces.jsonl
  files.txt = image paths relative to --base (one per line)
"""
import argparse, json, os, shutil, subprocess, sys, tarfile, tempfile

import config
AI1 = config.AI1["ssh"]
JUMP = config.AI1["jump_host"]

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--base", required=True)
    ap.add_argument("--list", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--chunk", type=int, default=64)
    ap.add_argument("--idle", type=int, default=120)
    ap.add_argument("--worker", default=config.AI1["worker_launcher"], help="remote worker launcher on ai1")
    a = ap.parse_args()
    paths = [l.strip() for l in open(a.list, encoding="utf-8") if l.strip()]
    cmd = ["ssh", JUMP, f"{AI1} \"IDLE_SECS={a.idle} {a.worker}\""]
    worker = subprocess.Popen(cmd, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=sys.stderr)
    out_f = open(a.out, "a", encoding="utf-8")
    import threading
    def reader():
        for line in worker.stdout:
            rec = json.loads(line)
            rec["remote"] = f"{a.base}/{rec['name']}"
            out_f.write(json.dumps(rec) + "\n"); out_f.flush()
    t = threading.Thread(target=reader); t.start()
    tar = tarfile.open(fileobj=worker.stdin, mode="w|")
    done = 0
    for i in range(0, len(paths), a.chunk):
        chunk = paths[i:i + a.chunk]
        with tempfile.TemporaryDirectory() as tmp:
            lst = os.path.join(tmp, "list.txt")
            open(lst, "w", encoding="utf-8").write("\n".join(chunk) + "\n")
            subprocess.run(["rclone", "copy", "--files-from-raw", lst, "--transfers", "8",
                            a.base, os.path.join(tmp, "img")], check=True)
            for rel in chunk:
                p = os.path.join(tmp, "img", rel)
                if os.path.exists(p):
                    tar.add(p, arcname=rel)
        done += len(chunk)
        print(f"staged {done}/{len(paths)}", file=sys.stderr, flush=True)
    tar.close(); worker.stdin.close()
    t.join(); worker.wait(); out_f.close()
    print(f"finished rc={worker.returncode}", file=sys.stderr)

if __name__ == "__main__":
    main()

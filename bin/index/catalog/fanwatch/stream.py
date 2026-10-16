#!/usr/bin/env python3
"""fanwatch stream: the unprivileged half on the machine that owns the disk (host1), run over ssh by the
catalog on host3 (forced command of a restricted key, only reachable from the WireGuard address).

Reads path events from fanwatch-helper's socket, coalesces them per path, resolves them with lstat when they
settle (host1's own view, no NFS attribute cache in between) and prints one JSON object per line on stdout:
  {"op": "put", "p": path, "s": size or null, "m": mtime, "k": "file" | "dir" | "link"}
  {"op": "del", "p": path}          {"op": "delprefix", "p": path}
  {"overflow": 1}                   events were lost (helper queue full, or the helper restarted): rescan
  {"hb": 1}                         every 30 s, so the other side can tell a quiet tree from a dead link
A folder that appears (created or moved in) is walked here and every entry in it is put.
"""
import json, os, socket, stat, sys, threading, time

SOCK = os.environ.get("FANWATCH_SOCK", "/run/fanwatch/events.sock")
QUIET, MAX_WAIT = 1.0, 15.0
lock = threading.Lock()
puts, structs = {}, []          # path -> [first, last] ; ("scan" | "delprefix", path)
out_lock = threading.Lock()

def emit(obj):
    with out_lock:
        sys.stdout.write(json.dumps(obj) + "\n")
        sys.stdout.flush()

def put(path):
    now = time.time()
    with lock:
        e = puts.get(path)
        if e:
            e[1] = now
        else:
            puts[path] = [now, now]

def handle(ev):
    if ev.get("overflow"):
        emit({"overflow": 1})
        return
    path, kinds, isdir = ev["p"], ev["e"], bool(ev["d"])
    parent = path.rsplit("/", 1)[0] or "/"
    if "C" in kinds or "T" in kinds:
        if isdir:
            with lock:
                structs.append(("scan", path))
        else:
            put(path)
        put(parent)
    elif "D" in kinds or "F" in kinds:
        if isdir:
            with lock:
                structs.append(("delprefix", path))
        else:
            put(path)
        put(parent)
    else:
        put(path)

def describe(path):
    try:
        st = os.lstat(path)
    except OSError:
        return {"op": "del", "p": path}
    if stat.S_ISDIR(st.st_mode):
        return {"op": "put", "p": path, "s": None, "m": int(st.st_mtime), "k": "dir"}
    if stat.S_ISLNK(st.st_mode):
        return {"op": "put", "p": path, "s": 0, "m": int(st.st_mtime), "k": "link"}
    return {"op": "put", "p": path, "s": st.st_size, "m": int(st.st_mtime), "k": "file"}

def scan(root):
    stack = [root]
    while stack:
        d = stack.pop()
        emit(describe(d))
        try:
            it = os.scandir(d)
        except OSError:
            continue
        with it:
            for e in it:
                try:
                    if e.is_dir(follow_symlinks=False):
                        stack.append(e.path)
                    else:
                        emit(describe(e.path))
                except OSError:
                    pass

def flusher():
    last_hb = time.time()
    while True:
        time.sleep(0.5)
        now = time.time()
        if now - last_hb > 30:
            emit({"hb": 1})
            last_hb = now
        with lock:
            ss, structs[:] = list(structs), []
            due = [p for p, (first, last) in puts.items() if now - last >= QUIET or now - first >= MAX_WAIT]
            for p in due:
                del puts[p]
        for kind, path in ss:
            if kind == "scan":
                scan(path)
            else:
                emit({"op": "delprefix", "p": path})
        for p in due:
            emit(describe(p))

def main():
    threading.Thread(target=flusher, daemon=True).start()
    first = True
    while True:
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        try:
            s.connect(SOCK)
        except OSError:
            s.close()
            time.sleep(5)
            continue
        if not first:
            emit({"overflow": 1})           # events were missed while the helper was away
        first = False
        buf = b""
        while True:
            try:
                chunk = s.recv(1 << 16)
            except OSError:
                chunk = b""
            if not chunk:
                break
            buf += chunk
            *lines, buf = buf.split(b"\n")
            for line in lines:
                try:
                    handle(json.loads(line))
                except (ValueError, KeyError):
                    pass
        s.close()
        time.sleep(2)

if __name__ == "__main__":
    try:
        main()
    except BrokenPipeError:
        sys.exit(0)

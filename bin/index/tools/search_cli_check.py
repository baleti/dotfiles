#!/usr/bin/env python3
"""Checks bin/search against the raw search server (needs images-search running): counts, paging, ordering, output
formats, exit codes, path mapping and the /fts /chroma /clip /face verbs. Prints one line per check, exit 1 on failure."""
import json, subprocess, sys, urllib.parse, urllib.request

SERVER = "http://127.0.0.1:8765"
fails = 0

def run(*args, timeout=300):
    r = subprocess.run(["search", *args], capture_output=True, text=True, timeout=timeout)
    return r.returncode, r.stdout, r.stderr

def run_chroma(*args):
    """/chroma starts its worker on the first call (the server answers 'starting' with no rows): wait for it."""
    import time
    deadline = time.time() + 120
    while True:
        rc, out, err = run(*args, timeout=600)
        if out.strip() or "starting" not in err or time.time() > deadline:
            return rc, out, err
        time.sleep(5)

def server(q, top=1, sort="date", desc=1):
    url = f"{SERVER}/query?" + urllib.parse.urlencode({"q": q, "sort": sort, "desc": desc, "offset": 0, "top": top})
    return json.load(urllib.request.urlopen(url, timeout=300))

def check(name, ok, detail=""):
    global fails
    print(f"{'ok  ' if ok else 'FAIL'} {name}{(' - ' + detail) if detail and not ok else ''}")
    fails += 0 if ok else 1

Q = "montgomer bm3 !pdf-to-png .pdf"
srv = server(Q)
rc, out, _ = run("-c", Q)
check("count line matches the server", rc == 0 and out.startswith(f"{srv['count']:,} shown"), out.strip())
rc, out, _ = run("-c", "--json", Q)
j = json.loads(out)
check("count --json", j["count"] == srv["count"] and j["kinds"] == {k: n for k, n in srv["stats"]["kinds"]}, out[:120])

rc, out, _ = run("-q", "-n", "2500", Q)
check("paging past 1000 rows returns exactly the limit", len(out.splitlines()) == 2500, str(len(out.splitlines())))
rc, out, _ = run("-q", "-n", "0", "zzqqxxnomatch")
check("no match: exit 1 and no output", rc == 1 and out == "")
rc, _, err = run("--server", "http://127.0.0.1:9", "-q", "x")
check("server down: exit 2 with a hint", rc == 2 and "systemctl --user start images-search" in err)

small = "montgomer !pdf-to-png //ext .dwg"
n_small = server(small)["count"]
_, newest, _ = run("-q", "-n", "0", small)
_, oldest, _ = run("-q", "-n", "0", "--asc", small)
check("--asc reverses the date order", n_small > 1 and newest.splitlines() == oldest.splitlines()[::-1])
_, oldest2, _ = run("-q", "-n", "0", small + " /rv")
check("/rv in the query reverses too", oldest2.splitlines() == oldest.splitlines())
_, bysize, _ = run("-q", "-n", "30", "-l", "montgomer .pdf /s size desc")
sizes = [int(l.split("\t")[0]) for l in bysize.splitlines() if l.split("\t")[0].isdigit()]
check("/s size desc orders by size", sizes == sorted(sizes, reverse=True) and len(sizes) > 5)
_, nul, _ = run("-0", "-q", "-n", "5", Q)
check("-0 separates with NUL", nul.count("\0") == 5 and "\n" not in nul.rstrip("\0"))
_, js, _ = run("--json", "-q", "-n", "3", Q)
check("--json: one object per line", all(set(json.loads(l)) >= {"path", "size", "mtime"} for l in js.splitlines()) and len(js.splitlines()) == 3)
rc, a, _ = run("-c", "--no-dotfiles", "")
rc, b, _ = run("-c", "--dotfiles", "")
na, nb = int(a.split()[0].replace(",", "")), int(b.split()[0].replace(",", ""))
check("--no-dotfiles shows fewer than --dotfiles", 0 < na < nb, f"{na} vs {nb}")

# content and photo verbs
rc, out, err = run("--json", "-q", "--snippets", "-n", "3", "/fts dgcl design //mime pdf")
rows = [json.loads(l) for l in out.splitlines()]
check("/fts returns files with snippets", rc == 0 and rows and any(r.get("snippets") for r in rows), err[:100])
rc, out, err = run_chroma("--json", "-q", "-n", "10", "/chroma clash tolerances for BIM coordination")
rows = [json.loads(l) for l in out.splitlines()]
scores = [r.get("score") for r in rows]
check("/chroma returns scored results, best first", rc == 0 and len(rows) >= 5 and None not in scores and scores == sorted(scores, reverse=True), (err or out)[:120])
rc, out, err = run_chroma("--json", "-q", "--snippets", "-n", "2", "/chroma/hwo handover requirements")
rows = [json.loads(l) for l in out.splitlines()]
check("/chroma/<index> with snippets", rc == 0 and rows and all(r["path"].startswith("/") for r in rows) and any(r.get("snippets") for r in rows), (err or out)[:120])
rc, out, err = run("--json", "-q", "-n", "5", "/clip brick wall")
rows = [json.loads(l) for l in out.splitlines()]
check("/clip returns photos with scores", rc == 0 and rows and all(r.get("score") is not None for r in rows), err[:100])
check("photo paths are real paths, not rclone ones", all(r["path"].startswith("/") for r in rows), str([r["path"] for r in rows][:2]))
rc, out, _ = run("--raw", "--json", "-q", "-n", "5", "/face daniel")
rows_raw = [json.loads(l) for l in out.splitlines()]
rc, out, _ = run("--json", "-q", "-n", "5", "/face daniel")
rows_map = [json.loads(l) for l in out.splitlines()]
check("/face: --raw keeps the rclone form, default maps it", rows_raw and any(":" in r["path"] and not r["path"].startswith("/") for r in rows_raw) and all(r["path"].startswith("/") for r in rows_map))

print("\nALL OK" if not fails else f"\n{fails} FAILED")
sys.exit(1 if fails else 0)

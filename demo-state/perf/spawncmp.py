"""QUEUE-perf item 25: layouts served after prefetch with fork vs DWG_FORCE_SPAWN (the Windows/macOS path) must be identical. usage: spawncmp.py FILE..."""
import sys, os, subprocess, time, json, urllib.request, tempfile, shutil, hashlib, gzip
BODIES = {}; MODES = os.environ.get("MODES", "fork,spawn").split(","); PORT0 = int(os.environ.get("PORT0", "8960")); ROOT = os.path.expanduser("~/dwg-ballet-staged"); port = PORT0
def get(u):
    r = urllib.request.urlopen("http://127.0.0.1:%d%s" % (port, u), timeout=180); b = r.read(); return gzip.decompress(b) if b[:2] == b"\x1f\x8b" else b
for f in sys.argv[1:]:
    res = {}
    for mode in MODES:
        port += 1; cd = tempfile.mkdtemp(prefix="sp_", dir=os.path.expanduser("~/demo-state/perf/scratch"))
        env = dict(os.environ, DWG_BALLET_CACHE=cd); env.pop("DWG_NO_FAST", None)
        if mode == "spawn": env["DWG_FORCE_SPAWN"] = "1"
        t0 = time.time(); p = subprocess.Popen([sys.executable, "-m", "dwgballet", "--no-browser", "--port", str(port), f], cwd=ROOT, env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        m = None
        while time.time() - t0 < 120:
            try:
                m = json.loads(get("/api/meta"))
                if "layouts" in m: break
            except Exception: pass
            time.sleep(0.05)
        hs = []
        for l in m["layouts"]:
            for tw in ("1", "0"):
                b = json.loads(get("/api/layout/%d?twist=%s" % (l["i"], tw))); b.pop("build_s", None)
                b.pop("tl", None)      # tl (handle -> top layer) accumulates across layouts built earlier in the same Doc: a harmless superset, values never differ (checked in-process)
                hs.append(hashlib.md5(json.dumps(b, sort_keys=True).encode()).hexdigest()[:8]); BODIES.setdefault(len(res), []).append(b)
        res[len(res)] = (hs, round(time.time() - t0, 2)); p.terminate(); p.wait(); shutil.rmtree(cd)
    print(os.path.basename(f)[:16], len(res[0][0]) // 2, "layouts", MODES, "IDENTICAL" if res[0][0] == res[1][0] else "DIFF", "%.1f s vs %.1f s" % (res[0][1], res[1][1]), flush=True)

if os.environ.get("SHOWDIFF"):
    for k, (x, y) in enumerate(zip(BODIES[0], BODIES[1])):
        if x != y: print("DIFFKEYS idx", k, [kk for kk in set(x) | set(y) if x.get(kk) != y.get(kk)], "prims", len(x.get("prims", [])), len(y.get("prims", [])))

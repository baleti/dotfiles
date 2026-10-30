"""QUEUE-perf item 24: HTTP time-to-first-layout vs all layouts, cold private cache, native vs DWG_NO_FAST. usage: httpcold.py FILE"""
import sys, os, subprocess, time, json, urllib.request, tempfile, shutil
ROOT = os.path.expanduser("~/dwg-ballet-staged"); f = sys.argv[1]; port = 8931
def get(u):
    t = time.time(); r = urllib.request.urlopen("http://127.0.0.1:%d%s" % (port, u), timeout=120); b = r.read(); return time.time() - t, b
for mode in ("stock", "native"):
    cd = tempfile.mkdtemp(prefix="hc_", dir=os.path.expanduser("~/demo-state/perf/scratch"))
    env = dict(os.environ, DWG_BALLET_CACHE=cd)
    if mode == "stock": env["DWG_NO_FAST"] = "1"
    else: env.pop("DWG_NO_FAST", None)
    t0 = time.time(); p = subprocess.Popen([sys.executable, "-m", "dwgballet", "--no-browser", "--port", str(port), f], cwd=ROOT, env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    m = None
    while time.time() - t0 < 120:
        try:
            m = json.loads(get("/api/meta")[1])
            if "layouts" in m: break
        except Exception: pass
        time.sleep(0.05)
    t_meta = time.time() - t0; dl = m["default"]
    d1, b1 = get("/api/layout/%d" % dl); t_first = time.time() - t0
    others = [l["i"] for l in m["layouts"] if l["i"] != dl]
    for i in others: get("/api/layout/%d" % i)
    t_all = time.time() - t0
    print("%s: meta %.2f s, first layout served %.2f s (%.1f MB), all %d layouts %.2f s" % (mode, t_meta, t_first, len(b1) / 1e6, len(m["layouts"]), t_all), flush=True)
    p.terminate(); p.wait(); shutil.rmtree(cd)
    port += 1

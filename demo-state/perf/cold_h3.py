"""QUEUE-perf item 12: cold first-layout and all-layouts time, stock (DWG_NO_FAST=1) vs native, fresh process each (no disk cache: build.Doc directly). usage: cold_h3.py FILE..."""
import sys, os, subprocess
ROOT = os.path.expanduser("~/dwg-ballet-staged")
CH = r'''
import sys, time; sys.path.insert(0, sys.argv[1]); t0 = time.time()
from dwgballet import build
d = build.Doc(sys.argv[2]); m = d.meta(); dl = m["default"]
d.layout(dl, True); t1 = time.time() - t0
for l in m["layouts"]:
    if l["i"] != dl: d.layout(l["i"], True)
print(round(t1, 2), round(time.time() - t0, 2), len(m["layouts"]))
'''
for f in sys.argv[1:]:
    r = {}
    for mode in ("stock", "native"):
        env = dict(os.environ)
        if mode == "stock": env["DWG_NO_FAST"] = "1"
        else: env.pop("DWG_NO_FAST", None)
        o = subprocess.run([sys.executable, "-c", CH, ROOT, f], env=env, capture_output=True, text=True)
        r[mode] = o.stdout.split() if o.returncode == 0 else ["ERR"] * 3
    print("%s %.1f MB layouts %s | first layout stock %s s native %s s | all stock %s s native %s s" % (os.path.basename(f)[:14], os.path.getsize(f) / 1e6, r["native"][2], r["stock"][0], r["native"][0], r["stock"][1], r["native"][1]), flush=True)

"""QUEUE-perf item 13: RVT conversion regression gate. usage: rvtgate.py [--baseline FILE] [--update] FILE.rvt...
Runs rvtballet.build.convert into a fresh dir (cold converter cache), records total + the converter's own log timings, compares with the stored baseline (fail if total > +15%)."""
import sys, os, time, json, tempfile, re
REPO = os.path.expanduser("~/src/rvt-viewer"); sys.path.insert(0, REPO)
args = sys.argv[1:]
if "--cold" in args: args.remove("--cold"); os.environ["RVT_NO_GEOM_CACHE"] = "1"; COLD = True
else: COLD = False
base = os.path.expanduser("~/rvtgate_baseline_cold.json" if COLD else "~/rvtgate_baseline.json"); upd = False
if "--baseline" in args: i = args.index("--baseline"); base = args[i + 1]; del args[i:i + 2]
if "--update" in args: args.remove("--update"); upd = True
from rvtballet import build
B = json.load(open(base)) if os.path.exists(base) else {}; bad = 0; res = {}
for f in args:
    n = os.path.basename(f); tot = None
    for rep in range(3):          # run 1 warms the reader/geometry caches (first-ever run is 2-4x slower); keep the best of runs 2 and 3 (host load is noisy)
        out = tempfile.mkdtemp(prefix="rvtgate_"); L = []
        t = time.time(); build.convert(f, out, log=lambda *a: L.append(" ".join(str(x) for x in a)))
        d = round(time.time() - t, 2)
        if rep and (tot is None or d < tot): tot = d; lines = L
    stages = [l.strip()[:110] for l in lines if re.search(r"\d+(\.\d+)? ?s\b", l)][:14]
    res[n] = tot; b = B.get(n)
    verdict = "NEW" if b is None else ("FAIL" if tot > b * 1.15 else "ok"); bad += verdict == "FAIL"
    print("%s %s total %.2f s (baseline %s)" % (verdict, n[:40], tot, b), flush=True)
    for s in stages: print("    " + s)
if upd: B.update({k: min(v, B.get(k, v)) for k, v in res.items()}); json.dump(B, open(base, "w"), indent=1)
sys.exit(1 if bad else 0)

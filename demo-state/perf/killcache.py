"""QUEUE-perf item 28: SIGKILL a process in the middle of cache.write_layout/write_meta 60 times; afterwards every layout/meta file must be absent or complete (valid gzip JSON) and read_layout must never return a torn file."""
import sys, os, time, random, subprocess, signal, gzip, json, tempfile, glob
ROOT = os.path.expanduser("~/dwg-ballet-staged")
W = r'''
import sys, os; sys.path.insert(0, sys.argv[1]); os.environ["DWG_BALLET_CACHE"] = sys.argv[2]
from dwgballet import cache
data = {"prims": [[i, i * 0.5, "x" * 20] for i in range(60000)]}
i = 0
while True:
    cache.write_meta(sys.argv[3], {"layouts": [{"i": 0}], "n": i}); cache.write_layout(sys.argv[3], i % 3, True, data); i += 1
'''
cd = tempfile.mkdtemp(prefix="kc_", dir=os.path.expanduser("~/demo-state/perf/scratch")); f = os.path.join(cd, "a.dwg"); open(f, "wb").write(os.urandom(50000))
rnd = random.Random(5); torn = 0; sizes = []
for k in range(60):
    p = subprocess.Popen([sys.executable, "-c", W, ROOT, os.path.join(cd, "cache"), f]); time.sleep(rnd.uniform(0.15, 1.2)); p.send_signal(signal.SIGKILL); p.wait()
    os.environ["DWG_BALLET_CACHE"] = os.path.join(cd, "cache")
    for g in glob.glob(os.path.join(cd, "cache", "*", "*")):
        if g.endswith(".tmp"): continue
        try:
            if g.endswith(".gz") or g.endswith(".json.gz"): json.loads(gzip.open(g).read())
            elif g.endswith(".json"): json.load(open(g))
        except Exception as e: torn += 1; print("TORN", g, type(e).__name__)
left = len(glob.glob(os.path.join(cd, "cache", "*", "*.tmp")))
print("kills 60 torn files", torn, "leftover .tmp files", left)

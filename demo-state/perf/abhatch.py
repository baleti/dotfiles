import sys, os, time; sys.path.insert(0, os.path.expanduser("~/dwg-ballet-perf"))
from dwgballet import build, flat
def run(f, on):
    nat = flat._hatch_native; flat._hatch_native = nat if on else None
    d = build.Doc(f); m = d.meta(); t = time.time()
    for l in m["layouts"]: d.layout(l["i"], True)
    flat._hatch_native = nat; return time.time() - t
for f in sys.argv[1:]:
    a = min(run(f, False) for _ in range(3)); b = min(run(f, True) for _ in range(3))
    print(os.path.basename(f)[:16], "layouts build (min of 3) python hatch %.2f s -> native hatch %.2f s (%.0f%%)" % (a, b, (1 - b / a) * 100), flush=True)

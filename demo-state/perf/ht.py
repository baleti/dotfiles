import sys, os, time; sys.path.insert(0, os.path.expanduser("~/dwg-ballet-perf"))
from dwgballet import build, flat
tot = [0.0]; orig = flat.Flattener._hatch
def timed(self, *a, **k):
    t = time.perf_counter()
    try: return orig(self, *a, **k)
    finally: tot[0] += time.perf_counter() - t
flat.Flattener._hatch = timed
for on in (False, True, False, True):
    nat = flat._hatch_native; flat._hatch_native = nat if on else None; tot[0] = 0
    d = build.Doc(sys.argv[1]); m = d.meta(); t = time.time()
    for l in m["layouts"]: d.layout(l["i"], True)
    print("native hatch" if on else "python hatch", "total layouts %.2f s, inside _hatch %.3f s" % (time.time() - t, tot[0])); flat._hatch_native = nat

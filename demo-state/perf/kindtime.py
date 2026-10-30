import sys, os, collections, time; sys.path.insert(0, os.path.expanduser("~/dwg-ballet-perf"))
from dwgballet import build, flat
c = collections.Counter(); n = collections.Counter(); orig = flat.Flattener._entity; depth = [0]
def spy(self, e, *a, **k):
    k_ = e.get("kind"); depth[0] += 1; t = time.perf_counter()
    try: return orig(self, e, *a, **k)
    finally:
        dt = time.perf_counter() - t; depth[0] -= 1
        if depth[0] == 0: c[k_] += dt; n[k_] += 1       # top-level only (INSERT includes its children)
flat.Flattener._entity = spy
d = build.Doc(sys.argv[1]); m = d.meta(); t = time.time()
for l in m["layouts"]: d.layout(l["i"], True)
print(os.path.basename(sys.argv[1])[:16], "layouts %.2f s;" % (time.time() - t), [(k, round(v, 2), n[k]) for k, v in c.most_common(7)])

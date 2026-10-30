import sys, os; sys.path.insert(0, os.path.expanduser("~/dwg-ballet-perf"))
from dwgballet import build, flat
st = {"n": 0, "none": 0, "exc": 0}
orig = flat._hatch_native
def spy(paths, elev, mat, ax=None):
    st["n"] += 1
    try: r = orig(paths, elev, mat, ax)
    except Exception as ex: st["exc"] += 1; st["last"] = repr(ex)[:150]; raise
    if r is None: st["none"] += 1
    return r
flat._hatch_native = spy
d = build.Doc(sys.argv[1]); m = d.meta()
for l in m["layouts"]: d.layout(l["i"], True)
print(st)
import collections
c = collections.Counter()
for blk in d.sc.by_block.values():
    for e in blk:
        if e.get("kind") == "HATCH":
            for p in e["paths"]: c[tuple(sorted({sg[0] for sg in p["segs"]}))] += 1
print(c.most_common(8))

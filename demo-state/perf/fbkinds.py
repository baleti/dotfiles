import sys, os, collections; sys.path.insert(0, os.path.expanduser("~/dwg-ballet-perf"))
from dwgballet import build, flat
c = collections.Counter(); orig = flat.Flattener._entity
def spy(self, e, *a, **k): c[e.get("kind")] += 1; return orig(self, e, *a, **k)
flat.Flattener._entity = spy
d = build.Doc(sys.argv[1]); m = d.meta()
for l in m["layouts"]: d.layout(l["i"], True)
print(os.path.basename(sys.argv[1])[:16], c.most_common(10))

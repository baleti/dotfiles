import re
p="dwgscene.py"; s=open(p).read()
a="def arc_points(cx, cy, r, a0, a1, ccw=True, step=None):\n"
b=a+"    if not (math.isfinite(a0) and math.isfinite(a1)) or abs(a1 - a0) > 1e6: return []      # corrupt angles: no point loop that never ends (same guard as the native kernels)\n"
assert s.count(a)==1; open(p,"w").write(s.replace(a,b))
p="dwgballet/flat.py"; s=open(p).read()
a="def _ell_pts(c, mj, r, a0, a1, mat):\n"
b=a+"    if not (math.isfinite(a0) and math.isfinite(a1)) or abs(a1 - a0) > 1e6: return []      # corrupt angles (same guard as the native kernels)\n"
assert s.count(a)==1; open(p,"w").write(s.replace(a,b))

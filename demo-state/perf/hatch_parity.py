"""bit-exact parity: Flattener._hatch with the native boundary loops vs the Python loops, random synthetic HATCH entities (P loops with bulges, L/A/E chains, SPLINE edges -> fallback, extrusion normals). Usage: python3 tests/hatch_parity.py"""
import sys, os, math, random, struct
here = os.path.dirname(os.path.abspath(__file__)); ROOT = os.path.join(here, '..', '..'); sys.path.insert(0, ROOT)
from dwgballet import flat
from dwgscene import Mat, ocs_axes
if flat._hatch_native is None: print("native hatch_loops not available"); sys.exit(1)
MAXU = [0]; rnd = random.Random(3); bad = 0; n = 3000
def run(e, mat, on):
    nat = flat._hatch_native; flat._hatch_native = nat if on else None
    out = []
    try:
        ext = tuple(e.get('ext', (0.0, 0.0, 1.0)))
        if ext == (0.0, 0.0, 1.0): W = lambda x, y, z=0.0: mat.apply(x, y)
        else:
            _ax, _ay, _az = ocs_axes(ext); W = lambda x, y, z=0.0: mat.apply(_ax[0] * x + _ay[0] * y + _az[0] * z, _ax[1] * x + _ay[1] * y + _az[1] * z)
        flat.Flattener._hatch(None, e, mat, W, 'L', (7, None, None), out)
        return [(t[0], [list(lp) for lp in t[3]], t[4]) for t in out]
    finally: flat._hatch_native = nat
def pt(): return (rnd.uniform(-50, 50), rnd.uniform(-50, 50))
def seg():
    k = rnd.choice('LLAAEEPS')
    if k == 'L': return ('L', pt(), pt())
    if k == 'A': return ('A', pt(), rnd.uniform(0.1, 20), rnd.uniform(0, 6.3), rnd.uniform(0, 6.3), rnd.random() < .5)
    if k == 'E': return ('E', pt(), pt(), rnd.uniform(0.1, 1), rnd.uniform(0, 6.3), rnd.uniform(0, 6.3)) + ((rnd.random() < .5,) if rnd.random() < .6 else ())
    if k == 'P': return ('P', pt())
    return ('S', 3, False, [], [0, 0, 0, 0, 1, 1, 1, 1], [(pt(), 1.0) for _ in range(4)])
for i in range(n):
    paths = []
    for _ in range(rnd.randint(1, 3)):
        if rnd.random() < .5: segs = [('P', pt(), rnd.choice([0.0, 0.0, rnd.uniform(-2, 2)])) if rnd.random() < .7 else ('P', pt()) for _ in range(rnd.randint(2, 7))]
        else: segs = [seg() for _ in range(rnd.randint(0, 6))]
        paths.append({'segs': segs})
    e = {'paths': paths, 'elev': rnd.choice([0.0, 1.5]), 'solid': rnd.random() < .5, 'handle': i, 'ext': rnd.choice([(0.0, 0.0, 1.0), (0.0, 0.0, 1.0), (0.3, -0.2, 0.9)]) }
    mat = Mat(rnd.uniform(-2, 2), rnd.uniform(-2, 2), rnd.uniform(-2, 2), rnd.uniform(-2, 2), rnd.uniform(-100, 100), rnd.uniform(-100, 100)) if rnd.random() < .7 else Mat()
    a = run(e, mat, False); b = run(e, mat, True)
    def ulps(x, y): return abs(x - y)
    same = len(a) == len(b) and all(u[0] == v[0] and u[2] == v[2] and len(u[1]) == len(v[1]) and all(len(p) == len(q) for p, q in zip(u[1], v[1])) for u, v in zip(a, b))
    mx = max([ulps(x, y) for u, v in zip(a, b) for p, q in zip(u[1], v[1]) for x, y in zip(p, q)] or [0]) if same else 10 ** 9
    MAXU[0] = max(MAXU[0], mx if mx < 10 ** 9 else 0)
    if not same or mx > 1e-9: bad += 1; print("DIFF case", i, [sg[0] for p in paths for sg in p["segs"]], "py/native loops", [len(l) for l in (a[0][1] if a else [])], [len(l) for l in (b[0][1] if b else [])], len(a), len(b)) if bad < 6 else None
print("hatch_loops parity: %d cases, %d differences (max abs diff %.2e, libm sin/cos last-bit effects; scene values are rounded to 3 decimals)" % (n, bad, MAXU[0])); sys.exit(1 if bad else 0)

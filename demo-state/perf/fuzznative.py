"""QUEUE-perf item 10: type/value fuzz of every dwgscene_fast entry point. Python exceptions are fine; a process abort/segfault/hang is a failure.
Usage: fuzznative.py [calls_per_child] [children]"""
import sys, os, random, subprocess, time
CHILD = r'''
import sys, random, math
sys.path.insert(0, sys.argv[1])
import dwgscene_fast as R
rnd = random.Random(int(sys.argv[2])); N = int(sys.argv[3])
nan, inf = float("nan"), float("inf")
SC = [0, 1, -1, 2, 3, 255, 2**31, 2**63, -2**63, 2**64, 10**30, 0.0, -0.0, 1.5, 1e300, -1e300, 1e-300, nan, inf, -inf, True, False, None, "", "x", b"", b"\0\xff", 1e12, 999999999999.0]
def val(d=0):
    r = rnd.random()
    if d > 2 or r < 0.5: return rnd.choice(SC)
    if r < 0.7: return [val(d + 1) for _ in range(rnd.randint(0, 8))]
    if r < 0.8: return tuple(val(d + 1) for _ in range(rnd.randint(0, 8)))
    if r < 0.9: return {rnd.choice(["kind", "p1", "p2", "color", "layer", "pts", "ctrl", "knots", "degree", "center", "radius", "ext", "a0", "a1", "major", "ratio", "bulges", "weights", "fit", "lweight", "ltflags", "handle", "elev"]): val(d + 1) for _ in range(rnd.randint(0, 6))}
    return set(rnd.sample(SC[:20], 3)) if False else [val(d + 1) for _ in range(rnd.randint(0, 3))]
def floats(n): return [rnd.choice([0.0, 1.0, -1.0, nan, inf, 1e12, 1e300, rnd.uniform(-1e6, 1e6), rnd.uniform(-10, 10)]) for _ in range(n)]
ENT = lambda: {"kind": rnd.choice(["LINE", "CIRCLE", "ARC", "ELLIPSE", "LWPOLYLINE", "POINT", "SOLID", "TRACE", "SPLINE", "HATCH", "TEXT", 5, None]),
               "p1": floats(3) if rnd.random() < .8 else val(), "p2": floats(3) if rnd.random() < .8 else val(), "center": floats(3) if rnd.random() < .8 else val(),
               "radius": rnd.choice(floats(3)), "a0": rnd.choice(floats(2)), "a1": rnd.choice(floats(2)), "major": floats(3), "ratio": rnd.choice(floats(2)),
               "ext": rnd.choice([[0.0, 0.0, 1.0], floats(3), val()]), "color": rnd.choice([(7, None, None), [256, 3, 0], val()]), "layer": rnd.choice(["0", "A", None, 5]),
               "pts": [floats(2) for _ in range(rnd.randint(0, 6))] if rnd.random() < .8 else val(), "bulges": floats(rnd.randint(0, 6)), "closed": rnd.choice([True, False, None, 3]),
               "ctrl": [floats(3) for _ in range(rnd.randint(0, 8))], "knots": floats(rnd.randint(0, 14)), "degree": rnd.choice([0, 1, 2, 3, 5, -1, 2**40, None]), "weights": floats(rnd.randint(0, 8)),
               "fit": [floats(3) for _ in range(rnd.randint(0, 4))], "lweight": rnd.choice([-3, 0, 25, None, "x"]), "ltflags": rnd.choice([0, 1, None]), "handle": rnd.choice([1, 2**64, None, "a"]), "elev": rnd.choice(floats(2))}
MAT = lambda: rnd.choice([tuple(floats(6)), (1.0, 0.0, 0.0, 1.0, 0.0, 0.0), val(), tuple(floats(5))])
calls = [
    lambda: R.flatten_block([ENT() for _ in range(rnd.randint(0, 6))] if rnd.random() < .9 else val(), MAT(), set(), rnd.choice(floats(2)), rnd.choice([True, False]), {}, lambda e: val()),
    lambda: R.flatten_block([ENT() for _ in range(rnd.randint(0, 6))], MAT(), val() if False else set(), 1.0, True, {}, lambda e: (rnd.choice(["0", None]), (7, None, None), -3, rnd.choice([None, floats(2)]), rnd.choice(floats(2)))),
    lambda: R.clip_polyline(val(), val()),
    lambda: R.clip_polyline([(x, y) for x, y in zip(floats(4), floats(4))], floats(rnd.randint(0, 30))),
    lambda: R.sane(val()),
    lambda: R.sane([("l", 0, 0, 0, 0, floats(rnd.randint(0, 10)))] + [val()]),
    lambda: R.round_list(val(), rnd.choice(SC)),
    lambda: R.round_list(floats(rnd.randint(0, 50)), rnd.choice([0, 1, 3, 5, 6, 12, 22, 400, -3])),
    lambda: R.arc_flat(*[val() for _ in range(rnd.randint(0, 9))]),
    lambda: R.ell_flat(*[val() for _ in range(rnd.randint(0, 9))]),
    lambda: R.lwpoly_path(*[val() for _ in range(rnd.randint(0, 8))]),
    lambda: R.apply_flat(*[val() for _ in range(rnd.randint(0, 4))]),
    lambda: R.dumps(val()),
    lambda: R.rows_batch(*[val() for _ in range(rnd.randint(0, 5))]),
    lambda: R.lz77_compress(bytes(rnd.randrange(256) for _ in range(rnd.randint(0, 80))), rnd.choice([0, 1, 24, 10**6]), rnd.choice([0, 1, 5, 0x7FFF]), rnd.choice([0, 1, 16384]), rnd.choice([0, 1, 3, 4, 5])),
    lambda: R.lz77_compress(val()),
    lambda: R.adler(rnd.choice([b"", b"abc", val()]), rnd.choice(SC)),
    lambda: [getattr(R.Bits(bytes(rnd.randrange(256) for _ in range(rnd.randint(0, 40))), rnd.choice([0, 3, 100, -1, 2**70])), rnd.choice(["B", "BB", "BS", "BL", "RC", "RS", "RL", "RD", "BD", "BD3", "H", "TV", "MC", "MS", "bits"]), lambda *a: None)(*[rnd.choice([0, 1, 7, 64, 10**9, -1]) for _ in range(rnd.randint(0, 2))]) for _ in range(5)],
]
import faulthandler
faulthandler.dump_traceback_later(20, exit=True)
exc = 0
for i in range(N):
    ci = rnd.randrange(len(calls)); open('/tmp/fz_last_%s' % sys.argv[2], 'w').write(str(ci))
    try: calls[ci]()
    except BaseException as e:
        if isinstance(e, (KeyboardInterrupt, SystemExit)): raise
        exc += 1
print("ok", N, "calls,", exc, "python exceptions")
'''
n, k = int(sys.argv[1]) if len(sys.argv) > 1 else 5000, int(sys.argv[2]) if len(sys.argv) > 2 else 20
root = os.path.expanduser('~/dwg-viewer'); bad = 0; tot = 0; t0 = time.time()
for seed in range(k):
    try: r = subprocess.run([sys.executable, '-c', CHILD, root, str(seed), str(n)], capture_output=True, text=True, timeout=120)
    except subprocess.TimeoutExpired: bad += 1; print('HANG seed', seed); continue
    if r.returncode != 0 or not r.stdout.startswith('ok'): bad += 1; print('CRASH seed', seed, 'rc', r.returncode, (r.stderr or '')[-300:])
    else: tot += n
print('native fuzz: %d calls in %d children, %d crashes/hangs, %.0f s' % (tot, k, bad, time.time() - t0))

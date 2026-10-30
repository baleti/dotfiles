"""QUEUE-perf item 21: corrupt-input robustness. usage: corrupt.py N_PER_FILE FILE...  Each variant (random bit flips / truncation / zeroed run) is opened in a child process
(native and DWG_NO_FAST); fail = abort/segfault/hang (rc<0 or timeout). Python exceptions are fine. Also reports native/python disagreement on accept/reject."""
import sys, os, random, subprocess, hashlib
ROOT = os.path.expanduser("~/dwg-ballet-staged"); SC = os.path.expanduser("~/demo-state/perf/scratch")
CH = r'''
import sys; sys.path.insert(0, sys.argv[1])
from dwgballet import build
try:
    d = build.Doc(sys.argv[2]); m = d.meta(); d.layout(m["default"], True); print("ACCEPT")
except Exception as e: print("REJECT", type(e).__name__)
'''
n = int(sys.argv[1]); rnd = random.Random(11); tot = crash = dis = 0; kinds = {}
for f in sys.argv[2:]:
    b = open(f, "rb").read()
    for k in range(n):
        v = bytearray(b); r = rnd.random()
        if r < 0.5:
            for _ in range(rnd.choice([1, 1, 3, 20])): v[rnd.randrange(len(v))] ^= 1 << rnd.randrange(8)
        elif r < 0.75: v = v[:rnd.randrange(100, len(v))]
        else:
            i = rnd.randrange(len(v)); v[i:i + rnd.choice([4, 64, 4096])] = bytes(min(len(v) - i, 0) or rnd.choice([4, 64, 4096]))[:len(v) - i]
        p = os.path.join(SC, "c.dwg"); open(p, "wb").write(v); res = {}
        for mode in ("py", "native"):
            env = dict(os.environ)
            if mode == "py": env["DWG_NO_FAST"] = "1"
            else: env.pop("DWG_NO_FAST", None)
            try:
                o = subprocess.run([sys.executable, "-c", CH, ROOT, p], env=env, capture_output=True, text=True, timeout=20)
                res[mode] = o.stdout.split()[0] if o.returncode == 0 and o.stdout else "CRASH rc%d %s" % (o.returncode, o.stderr[-100:].replace("\n", " "))
            except subprocess.TimeoutExpired: res[mode] = "HANG"
        tot += 1
        if any(x.startswith(("CRASH", "HANG")) for x in res.values()):
            crash += 1; open(os.path.join(SC, "crash_%d.dwg" % crash), "wb").write(v); print("FAIL", os.path.basename(f), k, res, flush=True)
        elif res["py"] != res["native"]: dis += 1; print("DISAGREE", os.path.basename(f), k, res, flush=True)
print("variants", tot, "crash/hang", crash, "native-vs-python accept/reject disagreements", dis)
os.remove(os.path.join(SC, "c.dwg"))

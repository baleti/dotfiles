"""QUEUE-perf item 11: save each drawing with dwgdoc (py), then read the SAVED file with python-Bits vs native-Bits (DWG_NO_FAST) and compare the scene hash.
usage: python bitswrite.py OUTDIR FILE...   (outputs are scratch files in OUTDIR, delete after)"""
import sys, os, subprocess, hashlib
ROOT = os.path.expanduser("~/dwg-ballet-staged")
SAVE = r'''
import sys; sys.path.insert(0, sys.argv[1]); import dwgdoc
if len(sys.argv) < 5:
    d = dwgdoc.Doc(open(sys.argv[2], "rb").read()); open(sys.argv[3], "wb").write(d.save())
else:   # edited save: move 3 entities, erase 1, copy 1 through the real savegate
    from dwgballet import savegate, build
    b = build.Doc(sys.argv[2]); hs = [e["handle"] for blk in list(b.sc.by_block.values())[:3] for e in blk if e.get("kind") in ("LINE", "CIRCLE", "ARC", "LWPOLYLINE", "POINT")][:5]
    savegate.save_as(sys.argv[2], sys.argv[3], {}, move=[{"t": "move", "hs": hs[:3], "dx": 12.5, "dy": -7.25}, {"t": "copy", "hs": hs[3:4], "dx": 1.0, "dy": 2.0}], erase=hs[4:5], force=True)
'''
READ = r'''
import sys, json, hashlib; sys.path.insert(0, sys.argv[1])
from dwgballet import build
d = build.Doc(sys.argv[2]); m = d.meta(); h = hashlib.md5(); n = 0
for l in m["layouts"]:
    r = d.layout(l["i"], True); r.pop("build_s", None); n += len(r.get("prims", [])); h.update(json.dumps(r, sort_keys=True, default=repr).encode())
print(h.hexdigest(), n, len(d.m.objs))
'''
EDIT = os.environ.get("EDIT") == "1"
out = sys.argv[1]; os.makedirs(out, exist_ok=True); bad = 0
for f in sys.argv[2:]:
    dst = os.path.join(out, os.path.basename(f))
    env = dict(os.environ, DWG_NO_FAST="1")
    o = subprocess.run([sys.executable, "-c", SAVE, ROOT, f, dst] + (["edit"] if EDIT else []), env=env, capture_output=True, text=True)
    if o.returncode: print(os.path.basename(f)[:14], "SAVE-ERR", o.stderr[-120:].replace("\n", " ")); continue
    r = {}
    for mode in ("py", "native"):
        env = dict(os.environ)
        if mode == "py": env["DWG_NO_FAST"] = "1"
        else: env.pop("DWG_NO_FAST", None)
        o = subprocess.run([sys.executable, "-c", READ, ROOT, dst], env=env, capture_output=True, text=True)
        r[mode] = o.stdout.split() if o.returncode == 0 else ["ERR", o.stderr[-150:]]
    ok = r["py"] == r["native"] and r["py"][0] != "ERR"; bad += not ok
    print(os.path.basename(f)[:16], "IDENTICAL" if ok else "DIFF", r["native"][1:] if ok else r, flush=True)
    os.remove(dst)
print("bad", bad)

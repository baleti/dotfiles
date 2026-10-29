"""saved file byte identity, native vs DWG_NO_FAST (QUEUE-perf item 3): python savebytes.py FILE... ; child processes per mode"""
import sys, os, subprocess, hashlib, time
ROOT = os.path.expanduser("~/dwg-ballet-perf")
CH = r'''
import sys, os, hashlib, time
sys.path.insert(0, sys.argv[1])
import dwgdoc
buf = open(sys.argv[2], "rb").read(); d = dwgdoc.Doc(buf)
h = [x for x in d.objs][:0]
t = time.time(); out = d.save(); print(hashlib.sha1(out).hexdigest(), len(out), round(time.time() - t, 2))
'''
for f in sys.argv[1:]:
    r = {}
    for mode in ("py", "native"):
        env = dict(os.environ)
        if mode == "py": env["DWG_NO_FAST"] = "1"
        else: env.pop("DWG_NO_FAST", None)
        o = subprocess.run([sys.executable, "-c", CH, ROOT, f], env=env, capture_output=True, text=True)
        r[mode] = o.stdout.split() if o.returncode == 0 else ["ERR", o.stderr[-200:]]
    ok = r["py"][:2] == r["native"][:2]
    print(os.path.basename(f)[:14], "IDENTICAL" if ok else "DIFF", "py %s s native %s s" % (r["py"][-1], r["native"][-1]), r["native"][1] if ok else r, flush=True)

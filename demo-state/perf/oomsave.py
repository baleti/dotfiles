"""QUEUE-perf item 22: Save As under a memory cap that is too small (OOM kill mid save): the source must be untouched and the destination must be absent or a complete verified file; no half file under the final name. usage: oomsave.py FILE CAP_MB (run on host2; uses a systemd scope)"""
import sys, os, subprocess, tempfile, hashlib, shutil
f, cap = sys.argv[1], int(sys.argv[2]); ROOT = os.path.expanduser("~/dwg-ballet-perf")
sha = lambda p: hashlib.sha256(open(p, "rb").read()).hexdigest()
s0 = sha(f); tmp = tempfile.mkdtemp(prefix="oom_", dir=os.path.expanduser("~")); dst = os.path.join(tmp, "o.dwg")
CH = "import sys; sys.path.insert(0, sys.argv[1]); from dwgballet import build, savegate as S; d = build.Doc(sys.argv[2]); h = next(h for h, o in d.m.objs.items() if o.type in (17, 18, 19)); S.save_as(sys.argv[2], sys.argv[3], {}, erase=[h])"
r = subprocess.run(["systemd-run", "--user", "--scope", "-q", "-p", "MemoryMax=%dM" % cap, "-p", "MemorySwapMax=0", sys.executable, "-c", CH, ROOT, f, dst], capture_output=True, text=True)
left = sorted(os.listdir(tmp)); ok_src = sha(f) == s0
final = os.path.exists(dst)
print(os.path.basename(f)[:14], "cap %d MB: rc %d (%s)," % (cap, r.returncode, "killed" if r.returncode in (-9, 137) else "exit"), "source untouched" if ok_src else "SOURCE CHANGED", "| dst present" if final else "| dst absent", "| dir:", left)
if final:
    chk = subprocess.run([sys.executable, "-c", "import sys; sys.path.insert(0, sys.argv[1]); from dwgballet import build; d = build.Doc(sys.argv[2]); print(len(d.m.objs))", ROOT, dst], capture_output=True, text=True); print("   final file re-opens:", chk.stdout.strip() or chk.stderr[-100:])
shutil.rmtree(tmp)

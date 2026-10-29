"""QUEUE-perf item 7: SIGKILL the real Save As at evenly spaced points of its duration. Checks per kill: source byte-identical, destination absent or complete+valid
(never partial), leftovers listed, and a following clean Save As to the same name succeeds (stale lock / tmp do not block). Usage: killsave.py FILE... (host2, temp dirs)"""
import sys, os, time, signal, subprocess, hashlib, tempfile, shutil
HERE = os.path.expanduser('~/dwg-viewer')
CH = r'''
import sys, os
sys.path.insert(0, sys.argv[1])
from dwgballet import savegate as S, build
f, dst = sys.argv[2], sys.argv[3]
d = build.Doc(f); h = next(h for h, o in d.m.objs.items() if o.type in (17, 18, 19))
print("READY", flush=True)
S.save_as(f, dst, {}, erase=[h])
'''
def sha(p): return hashlib.sha1(open(p, 'rb').read()).hexdigest()
tot = ok = 0; left = {}
for f in sys.argv[1:]:
    h0 = sha(f); tmp = tempfile.mkdtemp(); dst = os.path.join(tmp, 'o.dwg')
    # duration of an unkilled run (after READY)
    p = subprocess.Popen([sys.executable, '-c', CH, HERE, f, dst], stdout=subprocess.PIPE, text=True); p.stdout.readline(); t0 = time.time(); p.wait(); T = time.time() - t0
    os.remove(dst)
    for k in range(20):
        p = subprocess.Popen([sys.executable, '-c', CH, HERE, f, dst], stdout=subprocess.PIPE, text=True, stderr=subprocess.DEVNULL); p.stdout.readline()
        time.sleep(T * (k + 0.5) / 20); p.send_signal(signal.SIGKILL); p.wait()
        names = sorted(os.listdir(tmp)); tot += 1
        good = sha(f) == h0
        if os.path.exists(dst):   # complete file only
            sys.path.insert(0, HERE); import dwgmodel
            try: dwgmodel.Model(open(dst, 'rb').read()); good = good and True
            except Exception: good = False
        for n in names:
            if n != 'o.dwg': left[n.split('-')[0] if 'tmp' in n else n] = left.get(n.split('-')[0] if 'tmp' in n else n, 0) + 1
        # clean retry must work
        for n in names:
            if n == 'o.dwg': os.remove(os.path.join(tmp, n))
        r = subprocess.run([sys.executable, '-c', CH, HERE, f, dst], capture_output=True, text=True)
        good = good and r.returncode == 0 and os.path.exists(dst) and sha(f) == h0
        if os.path.exists(dst): os.remove(dst)
        for n in os.listdir(tmp): os.remove(os.path.join(tmp, n))
        ok += good
        if not good: print('FAIL', os.path.basename(f), k, names, r.stderr[-200:], flush=True)
    print(os.path.basename(f)[:14], 'save %.1f s, 20 kills done' % T, flush=True); shutil.rmtree(tmp)
print('kill-mid-save: %d/%d ok; leftovers by kind: %s' % (ok, tot, left))

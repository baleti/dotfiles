import sys, os, time, resource, tempfile, shutil
sys.path.insert(0, os.path.expanduser('~/dwg-viewer'))
from dwgballet import build, savegate as S
f = sys.argv[1]
def mx(): return resource.getrusage(resource.RUSAGE_SELF).ru_maxrss / 1e3
d = build.Doc(f); m = d.meta(); a = mx()
h = next(h for h, o in d.m.objs.items() if o.type in (17, 18, 19))
tmp = tempfile.mkdtemp(); dst = os.path.join(tmp, 'o.dwg'); t = time.time()
r = S.save_as(f, dst, {}, erase=[h]); dt = time.time() - t; b = mx()
print(os.path.basename(f)[:14], 'peak RSS MB: after open+meta %.0f, after save-as(erase 1)+verify %.0f; save %.1f s' % (a, b, dt), flush=True)
shutil.rmtree(tmp)

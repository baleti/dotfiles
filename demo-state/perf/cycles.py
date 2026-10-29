"""QUEUE-perf item 5: load-save-load N times; per-cycle time, RSS, size, sha1 stability"""
import sys, os, time, hashlib
sys.path.insert(0, os.path.expanduser('~/dwg-viewer'))
import dwgdoc
def rss(): return int(open('/proc/self/statm').read().split()[1]) * 4096 / 1e6
N = int(sys.argv[1])
for f in sys.argv[2:]:
    buf = open(f, 'rb').read(); hs = []; ts = []; sz = []; r0 = None
    for i in range(N):
        t = time.time(); out = dwgdoc.Doc(buf).save(); ts.append(time.time() - t); hs.append(hashlib.sha1(out).hexdigest()); sz.append(len(out)); buf = out
        if i == 4: r0 = rss()
    stable = len(set(hs[1:])) == 1
    print(os.path.basename(f)[:14], 'cycles', N, 'time first %.2f median %.2f last %.2f s' % (ts[0], sorted(ts)[N // 2], ts[-1]), 'size %d -> %d' % (sz[0], sz[-1]), 'distinct sha after cycle1:', len(set(hs[1:])), 'rss %.0f -> %.0f MB' % (r0, rss()), flush=True)

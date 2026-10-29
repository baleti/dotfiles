"""Save-gate cost per stage (QUEUE-perf item 1): python sgprof.py FILE.dwg [...]  (host2 only, temp dir, never touches the source)"""
import sys, os, time, tempfile, shutil, json
sys.path.insert(0, os.path.expanduser('~/dwg-ballet-perf')); sys.path.insert(0, os.path.expanduser('~/dwg-viewer'))
from dwgballet import build, savegate as S   # build patches native Bits like the server does
import dwgdoc
def t(): return time.perf_counter()
rows = []
for f in sys.argv[1:]:
    buf = open(f, 'rb').read(); ver = buf[:6].decode('latin1')
    if ver not in S.WRITABLE: print(os.path.basename(f)[:14], ver, 'not writable'); continue
    T = {}; t0 = t()
    d = build.Doc(f); m = d.meta(); T['open'] = t() - t0
    t0 = t(); doc = dwgdoc.Doc(buf); T['writer_Doc'] = t() - t0
    ents = [h for h in doc.objs if h in d.m.objs and d.m.objs[h].type in (17, 18, 19)][:1]
    if not ents: print(os.path.basename(f)[:14], 'no simple entity'); continue
    t0 = t(); doc.erase(ents[0]); T['edit'] = t() - t0
    t0 = t(); out = doc.save(); T['doc_save'] = t() - t0
    t0 = t(); a = S._entities(buf); T['reparse_src'] = t() - t0
    t0 = t(); b = S._entities(out); T['reparse_out'] = t() - t0
    t0 = t(); bad = [h for h in a if h != ents[0] and b.get(h) != a[h]]; T['compare'] = t() - t0
    t0 = t(); dwgdoc.Doc(out); T['Doc_out'] = t() - t0
    tmpd = tempfile.mkdtemp(); p = os.path.join(tmpd, 'o.dwg'); t0 = t()
    with open(p, 'xb') as fh: fh.write(out); fh.flush(); os.fsync(fh.fileno())
    os.rename(p, p + '.x'); T['write_fsync_rename'] = t() - t0; shutil.rmtree(tmpd)
    t0 = t(); S.fingerprint(f); T['fingerprint'] = t() - t0
    T['total_save'] = sum(T[k] for k in ('writer_Doc', 'edit', 'doc_save', 'reparse_src', 'reparse_out', 'compare', 'Doc_out', 'write_fsync_rename', 'fingerprint'))
    T['bad'] = len(bad); T['size_MB'] = len(buf) / 1e6; T['ents'] = len(a)
    print(os.path.basename(f)[:14], ver, json.dumps({k: round(v, 2) for k, v in T.items()}), flush=True)

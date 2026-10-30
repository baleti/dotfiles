"""QUEUE-perf item 31: detection power of the save gate. The writer output gets ONE flipped byte (random position) before the gate verifies/commits it.
Outcome per trial: REFUSED (SaveError, nothing written), HARMLESS (written, file re-opens and every entity record equals the source), ESCAPE (written but unreadable or records differ).
usage: gatepower.py TRIALS FILE..."""
import sys, os, random, tempfile, shutil, hashlib
sys.path.insert(0, os.path.expanduser(os.environ.get("DWGROOT", "~/dwg-ballet-staged")))
import dwgdoc
from dwgballet import savegate as S, build
def recs(path):
    d = build.Doc(path); return {e["handle"]: repr(sorted((k, repr(v)) for k, v in e.items() if k not in ("owner",))) for blk in d.sc.by_block.values() for e in blk}
orig = dwgdoc.Doc.save; n = int(sys.argv[1]); rnd = random.Random(21)
for f in sys.argv[2:]:
    src = recs(f); tot = {"REFUSED": 0, "HARMLESS": 0, "ESCAPE": 0}; esc = []
    for t in range(n):
        pos = []
        def bad_save(self, *a, **k):
            b = bytearray(orig(self, *a, **k)); i = rnd.randrange(len(b)); pos.append(i); M = os.environ.get('MODE', 'bit')
            if M == 'bit': b[i] ^= 1 << rnd.randrange(8)
            elif M == 'trunc': del b[i:]
            elif M == 'zero': b[i:i + rnd.choice([16, 512, 4096])] = bytes(min(len(b) - i, rnd.choice([16, 512, 4096])))
            elif M == 'dup': j = rnd.randrange(len(b)); n = min(256, len(b) - max(i, j)); b[i:i + n] = b[j:j + n]
            elif M == 'multi':
                for _ in range(8): b[rnd.randrange(len(b))] ^= 1 << rnd.randrange(8)
            return bytes(b)
        dwgdoc.Doc.save = bad_save
        tmp = tempfile.mkdtemp(dir=os.path.expanduser(os.environ.get("SCRATCH", "~/demo-state/perf/scratch"))); dst = os.path.join(tmp, "o.dwg")
        try:
            try:
                S.save_as(f, dst, {}, force=True); w = True
            except Exception: w = False
            if not w: tot["REFUSED"] += 1
            else:
                try: ok = recs(dst) == src
                except Exception: ok = False
                if ok: tot["HARMLESS"] += 1
                else:
                    tot["ESCAPE"] += 1; esc.append(pos[-1])
                    if os.environ.get('KEEP'): shutil.copy(dst, os.path.join(os.environ['KEEP'], 'esc_%s_%d.dwg' % (os.path.basename(f)[:8], pos[-1])))
        finally:
            dwgdoc.Doc.save = orig; shutil.rmtree(tmp, ignore_errors=True)
    print(os.path.basename(f)[:16], "size %d, %d trials:" % (os.path.getsize(f), n), tot, "escape positions", esc[:8], flush=True)

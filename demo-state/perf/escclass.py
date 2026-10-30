"""classify save-gate escapes: usage escclass.py TRIALS FILE. For each trial one flipped bit in the writer output; for ESCAPEs report what differs (entity kinds / object types / unreadable)."""
import sys, os, random, tempfile, shutil, collections
sys.path.insert(0, os.path.expanduser(os.environ.get("DWGROOT", "~/dwg-ballet-staged")))
import dwgdoc, dwgmodel
from dwgballet import savegate as S, build
f = sys.argv[2]; n = int(sys.argv[1]); orig = dwgdoc.Doc.save; rnd = random.Random(int(os.environ.get("SEED", "5")))
def recs(buf):
    m = dwgmodel.Model(buf); r = {}
    for blk, e in m.entities(): r[("e", e["handle"])] = repr(sorted((k, repr(v)) for k, v in e.items() if k != "owner"))
    for h, o in m.objs.items():
        if ("e", h) not in r: r[("o", h)] = o.raw
    return r, m
srcbuf = open(f, "rb").read(); src, ms = recs(srcbuf); cls = collections.Counter(); ex = []
for t in range(n):
    info = {}
    def bad_save(self, *a, **k):
        b = bytearray(orig(self, *a, **k)); i = rnd.randrange(len(b)); b[i] ^= 1 << rnd.randrange(8); info["i"] = i; info["buf"] = bytes(b); return bytes(b)
    dwgdoc.Doc.save = bad_save
    tmp = tempfile.mkdtemp(dir=os.path.expanduser(os.environ.get("SCRATCH", "~/demo-state/perf/scratch"))); dst = os.path.join(tmp, "o.dwg")
    try:
        try: S.save_as(f, dst, {}, force=True); w = True
        except Exception: w = False
        if w:
            try: out, mo = recs(open(dst, "rb").read())
            except Exception as e: cls["unreadable " + type(e).__name__] += 1; ex.append((info["i"], "unreadable")); continue
            d = [k for k in set(src) | set(out) if src.get(k) != out.get(k)]
            if d:
                kinds = collections.Counter(("ent" if k[0] == "e" else "obj type %s" % (mo.objs[k[1]].type if k[1] in mo.objs else ms.objs[k[1]].type if k[1] in ms.objs else "?")) for k in d)
                cls["ESCAPE " + ", ".join("%s x%d" % kv for kv in sorted(kinds.items())[:3])] += 1; ex.append((info["i"], len(d)))
            else: cls["harmless"] += 1
        else: cls["refused"] += 1
    finally:
        dwgdoc.Doc.save = orig; shutil.rmtree(tmp, ignore_errors=True)
print(os.path.basename(f)[:16], dict(cls)); print("escape examples (byte, ndiff)", ex[:10])

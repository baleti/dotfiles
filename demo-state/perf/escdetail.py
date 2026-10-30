import sys, os
sys.path.insert(0, os.path.expanduser("~/dwg-ballet-perf"))
import dwgdoc, dwgmodel
f = os.path.expanduser("~/perf-h2/corpus/AC1024_08_1af4a0ba.dwg"); pos = int(sys.argv[1])
good = dwgdoc.Doc(open(f, "rb").read()).save(); print("good len", len(good))
import random
# find the bit by trying all 8
ms = dwgmodel.Model(good)
for bit in range(8):
    b = bytearray(good); b[pos] ^= 1 << bit; b = bytes(b)
    try: mo = dwgmodel.Model(b)
    except Exception as e: print(bit, "model fails", type(e).__name__); continue
    ch = [(h, o.type) for h, o in ms.objs.items() if h in mo.objs and mo.objs[h].raw != o.raw]
    ea = {e["handle"]: e for _, e in ms.entities()}; eb = {e["handle"]: e for _, e in mo.entities()}
    ed = [h for h in ea if h in eb and ea[h] != eb[h]]; miss = [h for h in ea if h not in eb]
    print("bit", bit, "raw-changed objs", ch[:4], "entity diffs", [hex(h) for h in ed[:3]], "missing", [hex(h) for h in miss[:3]])
    for h in ed[:1]: print({k: (ea[h].get(k), eb[h].get(k)) for k in set(ea[h]) | set(eb[h]) if ea[h].get(k) != eb[h].get(k)})

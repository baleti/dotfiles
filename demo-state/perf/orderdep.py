"""QUEUE-perf item 25b: is a layout's scene independent of which layouts were built before it in the same Doc? usage: orderdep.py FILE..."""
import sys, os, json; sys.path.insert(0, os.path.expanduser("~/dwg-ballet-staged"))
from dwgballet import build
def key(r): r = dict(r); r.pop("build_s", None); return json.dumps(r, sort_keys=True, default=repr)
for f in sys.argv[1:]:
    d = build.Doc(f); m = d.meta(); ls = [(l["i"], tw) for l in m["layouts"] for tw in ((True, False) if not l["ps"] else (True,))]
    seq = {j: d.layout(*j) for j in ls}          # sequential, one Doc
    bad = []
    for j in ls:
        a = build.Doc(f); a.meta(); alone = a.layout(*j)       # fresh Doc, only this layout
        if key(alone) != key(seq[j]): bad.append((j, [k for k in set(alone) | set(seq[j]) if alone.get(k) != seq[j].get(k)]))
    print(os.path.basename(f)[:16], len(ls), "layout builds,", "ORDER-INDEPENDENT" if not bad else "ORDER-DEPENDENT %s" % bad[:4], flush=True)

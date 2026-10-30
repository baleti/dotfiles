import sys, json
sys.path.insert(0, sys.argv[1])
from dwgballet import build
d = build.Doc(sys.argv[2]); m = d.meta(); out=[]
for l in m["layouts"]:
    for tw in ((True, False) if not l["ps"] else (True,)):
        r = d.layout(l["i"], tw); r.pop("build_s", None); out.append(r)
json.dump(out, open(sys.argv[3],"w"), sort_keys=True, default=repr)

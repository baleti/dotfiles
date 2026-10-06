import json, os, sys, urllib.parse
from recoll import recoll
out = open(sys.argv[1], "w")
for name in json.load(open(os.path.expanduser("~/.config/indexes/collections.json")))["collections"]:
    db = recoll.connect(confdir=os.path.expanduser(f"~/.cache/indexes/{name}/recoll"), writable=False)
    q = db.query(); q.execute("mime:application/pdf", stemming=0)
    n = 0; seen = set()
    while True:
        d = q.fetchone()
        if d is None: break
        if d.url.startswith("file://"):
            p = urllib.parse.unquote(d.url[len("file://"):])
            if p not in seen:
                seen.add(p); out.write(f"{name}\t{p}\n"); n += 1
    print(name, n, file=sys.stderr, flush=True)

import os, sys, urllib.parse
sys.path.insert(0, os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "photos"))
import index_config as ic
from recoll import recoll
# every PDF of the merged index, one path per line (pdf_pages_clip.py leaves out the paths with "clip_pages": false)
out = open(sys.argv[1], "w")
db = recoll.connect(confdir=ic.CONF, writable=False)
q = db.query(); q.execute("mime:application/pdf", stemming=0)
n = 0; seen = set()
while True:
    d = q.fetchone()
    if d is None: break
    if d.url.startswith("file://"):
        p = urllib.parse.unquote(d.url[len("file://"):])
        if p not in seen:
            seen.add(p); out.write(f"{ic.NAME}\t{p}\n"); n += 1
print(ic.NAME, n, file=sys.stderr, flush=True)

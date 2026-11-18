"""famview.py FILE.rfa OUT.svg -> the family's main 2D view drawn by rvt-sheets (most drawn primitives among its views; drafting/plan first)"""
import sys, os, time
sys.path.insert(0, os.path.expanduser(os.environ.get("RVT_SHEETS_DIR", "~/src/rvt-sheets-h2")))
from rvtsheets.decode import Decoder
from rvtsheets.viewdraw import ViewDrawer
from rvtsheets.viewsvg import view_svg
from rvtsheets.compose import crop_rect_uv
dec = Decoder(sys.argv[1]); doc = dec.doc(); vd = ViewDrawer(dec, doc)
pref = {"drafting": 0, "plan": 1, "floorplan": 1, "elevation": 2, "section": 3}
best = None
for vid, v in sorted(doc["views"].items(), key=lambda kv: pref.get(str(kv[1].get("kind")).lower(), 5)):
    if str(v.get("kind")).lower() in ("3d", "schedule", "legend", "project", "???", "browser"): continue
    try: dr = vd.draw(vid)
    except Exception as e: print("view", vid, v.get("kind"), "failed", repr(e)[:120], file=sys.stderr); continue
    n = len(dr["prims"])
    print("view", vid, v.get("kind"), v.get("name"), n, file=sys.stderr)
    if n and (best is None or n > best[0] * 1.5): best = (n, vid, v, dr)
if not best: sys.exit(2)
n, vid, v, dr = best
open(sys.argv[2], "w").write(view_svg(dr, v.get("scale") or 100, crop=None, hang=False))
print(vid, v.get("kind"), v.get("name"), n)

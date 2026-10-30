"""profile one rvt-sheets view render with cProfile. usage: RVT_SHEETS_CACHE=DIR profview.py FILE.rvt 'view name' ; aggregate top-25 cumulative"""
import sys, os, cProfile, pstats, time
sys.path.insert(0, os.path.expanduser("~/src/rvt-sheets"))
from rvtsheets.drawings import Model, render
m = Model(sys.argv[1]); m.decoder(); s = m._make_summary()
v = [x for x in s["views"] if x["name"] == sys.argv[2]][0]
pr = cProfile.Profile(); t = time.time(); pr.enable(); render(m, "view", v["id"]); pr.disable()
print("render %.1f s (profiled)" % (time.time() - t))
pstats.Stats(pr).sort_stats("cumulative").print_stats(28)

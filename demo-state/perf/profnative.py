import sys, os, cProfile, pstats, time
sys.path.insert(0, os.path.expanduser("~/dwg-ballet-perf"))
from dwgballet import build
d = build.Doc(sys.argv[1]); m = d.meta(); pr = cProfile.Profile(); t = time.time(); pr.enable()
for l in m["layouts"]: d.layout(l["i"], True)
pr.disable(); print("layouts %.2f s profiled" % (time.time() - t)); pstats.Stats(pr).sort_stats("tottime").print_stats(14)

import sys,os; sys.path.insert(0,'.')
from dwgballet import build
f=sys.argv[1]; order=[int(x) for x in sys.argv[2].split(',')]
d=build.Doc(f); m=d.meta(); print("default",m['default'],[ (l['i'],l['ps']) for l in m['layouts']])
for i in order:
    r=d.layout(i,True); print("layout",i,"tl",len(r['tl']),"prims",len(r['prims']),"mprims",len(r.get('mprims',[])))

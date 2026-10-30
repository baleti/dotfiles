import re
for p,old,new in (
 ("dwgscene_fast_src/src/lib.rs","|| (a1 - a0).abs() > 1e6 { return vec![]; }","|| (a1 - a0).abs() > 1e6 || a0.abs() > 1e6 || a1.abs() > 1e6 { return vec![]; }"),
 ("dwgscene.py","abs(a1 - a0) > 1e6: return []","abs(a1 - a0) > 1e6 or abs(a0) > 1e6 or abs(a1) > 1e6: return []"),
 ("dwgballet/flat.py","abs(a1 - a0) > 1e6: return []","abs(a1 - a0) > 1e6 or abs(a0) > 1e6 or abs(a1) > 1e6: return []")):
    s=open(p).read(); print(p, s.count(old)); s=s.replace(old,new); open(p,"w").write(s)

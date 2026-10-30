p="dwgballet/cache.py"; s=open(p).read()
a="    d = dirfor(path); os.makedirs(d, exist_ok=True)\n    prune_stale(path)\n"
b=a+"""    _sweep_tmp(d)
"""
assert s.count(a)==1; s=s.replace(a,b)
a="def write_meta(path, meta):"
b='''def _sweep_tmp(d, age=600):
    """a writer killed mid-write (SIGKILL, power loss) leaves NAME.pid.tid.tmp behind; remove those older than `age` seconds (the live writer renames its own within seconds)"""
    import time
    try:
        now = time.time()
        for n in os.listdir(d):
            if n.endswith('.tmp'):
                p = os.path.join(d, n)
                try:
                    if now - os.path.getmtime(p) > age: os.remove(p)
                except OSError: pass
    except OSError: pass


'''+a
assert s.count(a)==1; s=s.replace(a,b)
open(p,"w").write(s)

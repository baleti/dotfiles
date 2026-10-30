p="dwgballet/flat.py"; s=open(p).read()
a="""    def _hatch(self, e, mat, W, ly, col, out, lw=None):
        loops = []
        for p in e['paths']:
"""
b="""    def _hatch(self, e, mat, W, ly, col, out, lw=None):
        loops = []
        _fl = _hatch_loops_native(e, mat)           # native boundary loops (None: SPLINE edges / odd data -> the Python code below)
        for p in (e['paths'] if _fl is None else ()):
"""
assert s.count(a)==1; s=s.replace(a,b)
a="""        if not loops: return
        info = {'solid': 1 if e['solid'] else 0}"""
b="""        if _fl is not None: loops = _fl
        if not loops: return
        info = {'solid': 1 if e['solid'] else 0}"""
assert s.count(a)==1; s=s.replace(a,b)
a="""try:    # optional native _sane"""
b='''_hatch_native = None
try:    # optional native HATCH boundary loops (dwgscene_fast.hatch_loops); DWG_NO_FAST=1 disables it
    if not os.environ.get('DWG_NO_FAST'):
        import dwgscene_fast as _R2
        _hatch_native = getattr(_R2, 'hatch_loops', None)
except Exception:
    pass


def _hatch_loops_native(e, mat):
    if _hatch_native is None: return None
    try:
        ext = tuple(e.get('ext', (0.0, 0.0, 1.0)))
        ax = None if ext == (0.0, 0.0, 1.0) else ocs_axes(ext)
        return _hatch_native(e['paths'], e['elev'], (mat.a, mat.b, mat.c, mat.d, mat.tx, mat.ty), ax)
    except Exception:
        return None


'''+a
assert s.count(a)==1; s=s.replace(a,b)
open(p,"w").write(s)

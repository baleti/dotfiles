p="dwgballet/server.py"; s=open(p).read()
a="""        p = state['path']
        d = build.Doc(p)
"""
b="""        p = state['path']
        state['dkey'] = os.path.basename(cache.dirfor(p))      # content key BEFORE parsing: if the file changes meanwhile we reload (never cache an old parse under a new key)
        d = build.Doc(p)
"""
assert s.count(a)==1; s=s.replace(a,b)
a="""    async def meta(req):
"""
b="""    async def fresh():
        \"\"\"the file changed on disk since it was parsed (overwrite save, restore, another program): drop the parse and reload, so an old scene is never served or written to the cache under the new content key\"\"\"
        p = state['path']
        if not p or not state.get('dkey') or state['meta'] is None: return
        try: cur = os.path.basename(cache.dirfor(p))
        except OSError: return
        if cur != state['dkey']:
            state.update(doc=None, err=None, meta=None, dkey=None)
            await load(app)

    async def meta(req):
        await fresh()
"""
assert s.count(a)==1; s=s.replace(a,b)
a="""    async def layout(req):
"""
b=a+"""        await fresh()
"""
assert s.count(a)==1; s=s.replace(a,b)
open(p,"w").write(s)

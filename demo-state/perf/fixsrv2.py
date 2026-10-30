p="dwgballet/server.py"; s=open(p).read()
a="        state['dkey'] = os.path.basename(cache.dirfor(p))      #"
b="""        try: state['dkey'] = os.path.basename(cache.dirfor(p))
        except OSError: state['dkey'] = None
        #"""
assert s.count(a)==1; open(p,"w").write(s.replace(a,b))

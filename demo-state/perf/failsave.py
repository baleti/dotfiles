"""QUEUE-perf item 9: I/O failure injection in the real savegate (host2). Scenarios x drawings; after each: source byte-identical, destination absent (save-as) or original
unchanged (overwrite), clear SaveError/OSError (no traceback of another kind), leftover temp files listed. Usage: failsave.py FILE..."""
import sys, os, errno, hashlib, shutil, tempfile, json, builtins
sys.path.insert(0, os.path.expanduser('~/dwg-viewer'))
from dwgballet import build, savegate as S
def sha(p): return hashlib.sha1(open(p, 'rb').read()).hexdigest()
real_fsync, real_rename, real_copy2 = os.fsync, os.rename, shutil.copy2
res = []
def scen(name, f, tmpdir, overwrite=False, patch=None, chmod=None, expect_saved=False):
    d = build.Doc(f); h = next(h for h, o in d.m.objs.items() if o.type in (17, 18, 19))
    work = tempfile.mkdtemp(dir=tmpdir); src = os.path.join(work, 'src.dwg'); shutil.copyfile(f, src); h0 = sha(src)
    dst = src if overwrite else os.path.join(work, 'out.dwg')
    bk = tempfile.mkdtemp(dir=tmpdir); S.BACKUPS = bk
    if overwrite:
        cfg = os.path.join(work, 'cfg.json'); json.dump({'allow_overwrite': True}, open(cfg, 'w')); S.CONFIG = cfg
    if chmod: os.chmod(work, chmod)
    undo = []
    try:
        if patch: undo = patch()
        try:
            if overwrite: S.save_over(src, {}, erase=[h])
            else: S.save_as(src, dst, {}, erase=[h])
            outcome = 'SAVED'
        except S.SaveError as e: outcome = 'SaveError: ' + str(e)[:70]
        except OSError as e: outcome = 'OSError errno %s' % e.errno
        except BaseException as e: outcome = 'OTHER ' + type(e).__name__ + ': ' + str(e)[:60]
    finally:
        for u in undo: u()
        if chmod: os.chmod(work, 0o755)
    intact = sha(src) == h0 if outcome != 'SAVED' else True
    absent = overwrite or not os.path.exists(dst) or outcome == 'SAVED'
    left = sorted(n for n in os.listdir(work) if n not in ('src.dwg', 'out.dwg', 'cfg.json'))
    ok = (outcome == 'SAVED' and expect_saved and os.path.exists(dst) and not left) or (outcome != 'SAVED' and intact and absent and not outcome.startswith('OTHER'))
    res.append(ok); print('%-28s %-14s %s intact=%s no-partial-dest=%s leftovers=%s' % (name, os.path.basename(f)[:12], outcome, intact, absent, left), flush=True)
    shutil.rmtree(work, ignore_errors=True); shutil.rmtree(bk, ignore_errors=True)
def both(*ps):
    def p():
        u = []
        for q in ps: u += q()
        return u
    return p
def raise_on(mod, attr, err, after=0):
    orig = getattr(mod, attr); n = [0]
    def w(*a, **k):
        n[0] += 1
        if n[0] > after: raise OSError(err, os.strerror(err))
        return orig(*a, **k)
    def p(): setattr(mod, attr, w); return [lambda: setattr(mod, attr, orig)]
    return p
tmp = tempfile.mkdtemp()
gf = os.path.join(tmp, 'gate.json'); json.dump({'dwg': {'*': 'open'}}, open(gf, 'w')); os.environ['SAVEGATE_GATE'] = gf     # test-only gate file: overwrite open for this process
for f in sys.argv[1:]:
    scen('ENOSPC at fsync', f, tmp, patch=raise_on(os, 'fsync', errno.ENOSPC))
    scen('EIO at replace (save-as)', f, tmp, patch=both(raise_on(os, 'replace', errno.EIO), raise_on(os, 'rename', errno.EIO), raise_on(os, 'link', errno.EIO)))
    scen('EACCES at replace (overwrite)', f, tmp, overwrite=True, patch=both(raise_on(os, 'replace', errno.EACCES), raise_on(os, 'rename', errno.EACCES)))
    scen('ENOSPC at backup copy', f, tmp, overwrite=True, patch=both(raise_on(shutil, 'copy2', errno.ENOSPC), raise_on(shutil, 'copyfileobj', errno.ENOSPC), raise_on(shutil, 'copyfile', errno.ENOSPC)))
    scen('EIO at link only (fallback ok)', f, tmp, patch=raise_on(os, 'link', errno.EPERM), expect_saved=True)
    scen('read-only target dir', f, tmp, chmod=0o555)
    scen('ENOSPC at fsync (overwrite)', f, tmp, overwrite=True, patch=raise_on(os, 'fsync', errno.ENOSPC))
print('failure injection: %d/%d scenarios left the original intact, no partial destination, no unexpected exception' % (sum(res), len(res)))
shutil.rmtree(tmp, ignore_errors=True)

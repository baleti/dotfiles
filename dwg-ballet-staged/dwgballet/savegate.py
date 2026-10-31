"""Save As with a safety gate (PLAN-viewers-editors section 3, first slice): writes a copy of the drawing with the layer states (on, frozen, locked) of the viewer.
Rules: never overwrites an existing file and never writes the source path; the source must be unchanged since it was opened (size + mtime + sha1 recorded at load);
write goes to a temp file in the target directory, fsync, then rename (atomic); the result is re-parsed with the reader and compared with the source: every
entity record must be identical (zero diffs outside the edit) and the layer flags must be the requested ones; on any failure nothing is left behind.
Only versions the writer supports (AC1015, AC1018, AC1024, AC1027, AC1032); others are refused with a message."""
import hashlib, os, sys, time
from . import plat

HERE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
WRITABLE = {'AC1015', 'AC1018', 'AC1024', 'AC1027', 'AC1032'}
SKIP = {'prev', 'next', 'prev_handle', 'next_handle', 'block_ref'}     # block_ref is the reader's display name of block_handle ('*D~bee' only while another block has the same name), not stored data      # chain links may be renumbered by the writer; compared only if equal sets elsewhere


def _rb(path):
    with open(path, 'rb') as f: return f.read()


def fingerprint(path):
    st = os.stat(path)
    return {'size': st.st_size, 'mtime': int(st.st_mtime), 'sha1': hashlib.sha1(_rb(path)).hexdigest()}


class SaveError(Exception):
    pass


class Conflict(SaveError):
    """the source file changed on disk after it was opened (reload, or repeat with FORCE)"""


def _entities(buf):
    import dwgmodel
    m = dwgmodel.Model(buf)
    # AC1015: the flag doubling as "no explicit links" flips on the neighbours of an erased/copied entity (the writer makes their links explicit, see dwgdoc._set_links);
    # it only changes how the chain is stored, not the entity, and AutoCAD AUDIT is clean on such files
    skip = SKIP | {'xdicmissing'} if bytes(buf[:6]) == b'AC1015' else SKIP
    return {e['handle']: {k: v for k, v in e.items() if k not in skip} for b, e in m.entities()}


def _entities_m(buf):
    """(stripped entity records, Model, {handle: full record repr}): the full repr includes the link fields that the stripped comparison ignores"""
    import dwgmodel
    m = dwgmodel.Model(buf)
    skip = SKIP | {'xdicmissing'} if bytes(buf[:6]) == b'AC1015' else SKIP
    ents = list(m.entities())
    return ({e['handle']: {k: v for k, v in e.items() if k not in skip} for b, e in ents}, m, {e['handle']: repr(sorted((k, repr(v)) for k, v in e.items())) for b, e in ents})


_STRUCT = (4, 5, 48, 49)       # BLOCK, ENDBLK, BLOCK_CONTROL, BLOCK_HEADER: block definitions and their tables change with copies of dimensions and with owned lists


def _object_effects(ma, mb, a, b, fa, fb, gone, created, layer_hs):
    """Everything that changed in the file beyond the entity level, classified: returns (link_only, extra_added, extra_deleted, structural_modified) or raises SaveError for a change
    that no edit explains (so the library's independent verify is told the full truth, and anything unexplained is refused here)."""
    link_only = {h for h in a if h in b and h not in gone and a[h] == b[h] and fa.get(h) != fb.get(h)}               # AC1015 neighbours: only prev / next / link flag changed
    new = set(mb.objs) - set(ma.objs); removed = set(ma.objs) - set(mb.objs)
    extra_added = {h for h in new if h not in created}
    extra_deleted = {h for h in removed if h not in gone}
    for h in extra_added:
        if h not in b and mb.objs[h].type not in _STRUCT: raise SaveError('verification failed: unexpected new object %X (type %d) (nothing written)' % (h, mb.objs[h].type))
    for h in extra_deleted:
        if h not in a and ma.objs[h].type not in _STRUCT: raise SaveError('verification failed: unexpected removal of object %X (type %d) (nothing written)' % (h, ma.objs[h].type))
    struct = set()
    for h, o in ma.objs.items():
        if h in a or h not in mb.objs or mb.objs[h].raw == o.raw: continue
        if o.type in _STRUCT or h in layer_hs: struct.add(h)
        else: raise SaveError('verification failed: unexpected change of object %X (type %d) (nothing written)' % (h, o.type))
    return link_only, extra_added, extra_deleted, struct


def _refuse_other_scales(buf, move, erase):
    """Annotative objects keep one context record per annotation scale; the editor moves the object and its default-scale context, the other scales would keep the old
    position (they show it when the drawing's annotation scale is switched). Refuse instead of leaving them inconsistent."""
    hs = {int(h) for m in move for h in m['hs']}
    if not hs or bytes(buf[:6]) < b'AC1021': return
    import dwgmodel
    m = dwgmodel.Model(buf)
    try: ctx = m.annotation_contexts()
    except Exception: return
    owned = {e['handle'] for b, e in m.entities() if e.get('owner') in hs}               # attributes of a moved INSERT
    for h in hs | owned:
        if any(not c.get('default') for c in ctx.get(h, ())):
            raise SaveError('object %X has annotation scales other than the default one; move or copy it in AutoCAD (nothing written)' % h)


class _Lock:
    """lock file next to the target holding the pid. Created COMPLETE and atomically (pid written to a private temp file, then os.link to the lock name,
    which fails if the lock exists), so another process never sees a half-written lock. A lock of a dead process is moved aside atomically and retried;
    a live one refuses the save. File systems without hard links fall back to O_EXCL and treat a young empty lock as live."""
    def __init__(self, target): self.p = os.path.join(os.path.dirname(target), '.%s.lock' % os.path.basename(target))

    def _try_create(self):
        tmp = '%s.%d.%s.tmp' % (self.p, os.getpid(), os.urandom(3).hex())
        fd = os.open(tmp, os.O_CREAT | os.O_EXCL | os.O_WRONLY)
        try: os.write(fd, str(os.getpid()).encode())
        finally: os.close(fd)
        try:
            try: os.link(tmp, self.p); return True
            except FileExistsError: return False
            except (OSError, NotImplementedError):                       # no hard links here: plain exclusive create
                try: fd = os.open(self.p, os.O_CREAT | os.O_EXCL | os.O_WRONLY)
                except FileExistsError: return False
                os.write(fd, str(os.getpid()).encode()); os.close(fd); return True
        finally:
            try: os.remove(tmp)
            except OSError: pass

    def __enter__(self):
        for _ in range(4):
            if self._try_create(): return self
            try: raw = open(self.p).read().strip()
            except FileNotFoundError: continue                          # released meanwhile: try again
            except OSError: raise SaveError('another save of this file is running (lock %s)' % self.p)
            try: pid = int(raw) if raw else 0
            except ValueError: pid = 0
            if not pid:                                                 # empty or garbage: a creator on a no-hard-link file system, or a dead leftover
                try: young = time.time() - os.stat(self.p).st_mtime < 10
                except OSError: continue
                if young: raise SaveError('another save of this file is running (lock %s)' % self.p)
            elif plat.proc.pid_alive(pid) and pid != os.getpid():
                raise SaveError('another save of this file is running (lock %s, pid %d)' % (self.p, pid))
            aside = '%s.stale.%d.%s' % (self.p, os.getpid(), os.urandom(3).hex())
            try: os.replace(self.p, aside)                              # only one racer wins this rename
            except OSError: continue
            try: os.remove(aside)
            except OSError: pass
        raise SaveError('could not take the lock ' + self.p)

    def __exit__(self, *a):
        try: os.remove(self.p)
        except OSError: pass


_WIN_RESERVED = {'CON', 'PRN', 'AUX', 'NUL'} | {'COM%d' % i for i in range(1, 10)} | {'LPT%d' % i for i in range(1, 10)}


def check_name(dst):
    """Reject destination names that would write to a device, an alternate data stream or a name Windows silently rewrites (before any lock or temp file exists)."""
    b = os.path.basename(dst)
    if not b or any(ord(c) < 32 for c in b): raise SaveError('invalid file name: ' + repr(b))
    if sys.platform == 'win32':
        if any(c in b for c in '<>:"|?*'): raise SaveError('the file name contains a character Windows does not allow (< > : " | ? *): ' + b)
        if b != b.rstrip('. '): raise SaveError('Windows would silently drop the trailing dot or space of the file name: ' + b)
        if b.split('.')[0].rstrip().upper() in _WIN_RESERVED: raise SaveError('reserved Windows device name: ' + b)
        if len(b) > 255: raise SaveError('file name longer than 255 characters')


def save_as(src, dst, layers, fp=None, overwrite=False, erase=(), move=(), sgdoc=None, force=False):
    check_name(dst)
    dst0 = os.path.abspath(os.path.expanduser(dst))
    d0 = os.path.dirname(dst0)
    if os.path.isdir(d0) and os.access(d0, os.W_OK):
        with _Lock(dst0): return _save_as(src, dst, layers, fp, overwrite, erase, move, sgdoc, force)
    return _save_as(src, dst, layers, fp, overwrite, erase, move, sgdoc, force)       # the checks in _save_as report the unwritable folder


def damaged_objects(buf):
    """number of objects whose own CRC16 (seed 0xC0C1, last 2 bytes of the record) does not match; 0 for a sound file. Checked on 23 real drawings of AC1015..AC1032 (270k objects): no false positives"""
    import dwgload, dwgfmt as F
    d = dwgload.load(buf); bad = 0
    for o in d['objects'].values():
        raw = o.raw
        if len(raw) < 3 or F.crc16(raw[:-2], 0xC0C1) != int.from_bytes(raw[-2:], 'little'): bad += 1
    return bad + (0 if d.get('omap_ok', True) else 1)


def _save_as(src, dst, layers, fp=None, overwrite=False, erase=(), move=(), sgdoc=None, force=False):
    """layers: {name: {'off': bool, 'frozen': bool, 'locked': bool}} (only the given names are touched). Returns a report dict."""
    if HERE not in sys.path: sys.path.insert(0, HERE)
    import dwgdoc
    src = os.path.realpath(src); dst = os.path.abspath(os.path.expanduser(dst))
    if not dst.lower().endswith('.dwg'): raise SaveError('the new file must end in .dwg')
    if os.path.realpath(dst) == src and not overwrite: raise SaveError('refusing to write over the source file (Save As needs a new name)')
    if overwrite and os.path.realpath(dst) != src: raise SaveError('overwrite only replaces the source file itself')
    if os.path.exists(dst) and not overwrite: raise SaveError('refusing to overwrite an existing file: ' + dst)
    d = os.path.dirname(dst)
    if not os.path.isdir(d) or not os.access(d, os.W_OK):
        if sys.platform == 'win32' and len(dst) >= 250 and not os.path.isdir(d):       # Windows without LongPathsEnabled cannot even see the folder
            raise SaveError('path is longer than 260 characters and this Windows setup has long paths disabled (registry LongPathsEnabled=1, or save to a shorter folder): ' + dst)
        raise SaveError('folder is not writable: ' + d)
    if fp is not None and not force and fingerprint(src) != fp: raise Conflict('the source file changed on disk since it was opened; reopen it first (OPEN) or repeat the command with FORCE to apply your edits to the new contents')
    if force: sgdoc = None                       # forced: the library document is reopened from the file as it is now
    buf = _rb(src); fp0 = fingerprint(src); bak = None
    if buf[:6].decode('latin1') not in WRITABLE: raise SaveError('the writer does not support %s files yet (writable: %s); the drawing can be viewed but not saved' % (buf[:6].decode('latin1'), ', '.join(sorted(WRITABLE))))
    dmg = damaged_objects(buf)
    if dmg and overwrite: raise SaveError('the file is damaged (%d object(s) fail their checksum or the object map is inconsistent); SAVE! would rewrite it without them, so it was not touched. Use SAVEAS to a new file, or recover the drawing first' % dmg)
    doc = dwgdoc.Doc(buf); touched = 0; want = {}; layer_hs = []
    for name, st in layers.items():
        try: h = doc.layer_handle(name)
        except KeyError: raise SaveError('no such layer: ' + name)
        fl = doc.get(h)['flags']
        cur = {'frozen': bool(fl & 1), 'off': bool(fl & 2), 'locked': bool(fl & 8)}
        diff = {k: bool(v) for k, v in st.items() if k in cur and bool(v) != cur[k]}
        want[name] = {**cur, **diff}
        if diff: doc.set_layer(name, **diff); touched += 1; layer_hs.append(h)
    erase = sorted(set(int(h) for h in erase))
    for h in erase:
        if h not in doc.objs: raise SaveError('no such object to erase: %X' % h)
        try: doc.erase(h)
        except NotImplementedError as ex: raise SaveError('cannot erase object %X: %s' % (h, ex))
        except (KeyError, IndexError, ValueError, TypeError) as ex: raise SaveError('cannot erase object %X: unexpected structure (%s: %s); nothing written' % (h, type(ex).__name__, ex))
    moved = {}
    created = []
    for m in move:                                     # [{'t': 'move'|'copy', 'hs': [handles], 'dx': , 'dy': }] in order; a handle moved twice accumulates
        import dwgxform as X
        for h in m['hs']:
            h = int(h)
            if h in erase: continue
            if h not in doc.objs: raise SaveError('no such object to %s: %X' % (m.get('t', 'move'), h))
            tr = X.Transform.translate(float(m['dx']), float(m['dy']))
            if m.get('t') == 'copy':
                try: nh = doc.copy_entity(h, tr)
                except NotImplementedError as ex: raise SaveError('cannot copy object %X: %s' % (h, ex))
                except (KeyError, IndexError, ValueError, TypeError) as ex: raise SaveError('cannot copy object %X: unexpected structure (%s: %s); nothing written' % (h, type(ex).__name__, ex))
                created.append(nh)
                db = doc.get(nh).get('dimblock')                          # a copied dimension brings a copy of its picture block
                if db: created.extend(doc.chain(db))
            else:
                try: doc.transform(h, tr)
                except NotImplementedError as ex: raise SaveError('cannot move object %X: %s' % (h, ex))
                except (KeyError, IndexError, ValueError, TypeError) as ex: raise SaveError('cannot move object %X: unexpected structure (%s: %s); nothing written' % (h, type(ex).__name__, ex))
                moved[h] = moved.get(h, 0) + 1
    _refuse_other_scales(buf, move, erase)
    out = doc.save()
    # verification on the bytes, before anything touches the disk
    (a, ma, fa), (b, mb, fb) = _entities_m(buf), _entities_m(out); gone = set(erase)
    # dependents of an erased object: the attributes + SEQEND of an INSERT (and vertices + SEQEND of a polyline) must be gone with it; the picture block of an erased
    # dimension may be removed or left in place (an orphan *D block), either is valid, so its entities are optional
    parents = {h for h in erase if h in a and a[h].get('kind') in ('INSERT', 'MINSERT', 'POLYLINE2D', 'POLYLINE3D', 'POLYLINE_PFACE', 'POLYLINE_MESH')}
    deps = {h for h, e in a.items() if e.get('owner') in parents and h not in gone}
    gone |= deps
    if any(h in b for h in deps): raise SaveError('verification failed: the attributes/vertices of an erased object were not removed (nothing written)')
    eblocks = {a[h]['block_handle'] for h in erase if h in a and str(a[h].get('kind', '')).startswith('DIM_') and a[h].get('block_handle')}
    optional = {h for h, e in a.items() if e.get('owner') in eblocks and h not in gone}
    gone_opt = {h for h in optional if h not in b}; gone |= gone_opt
    if any(b.get(h) != a[h] for h in optional - gone_opt): raise SaveError('verification failed: the picture block of an erased dimension was changed (nothing written)')
    kids = {h for h, e in a.items() if e.get('kind') == 'ATTRIB' and e.get('owner') in moved}      # attributes travel with their moved INSERT
    dimblocks = {a[h]['block_handle'] for h in moved if h in a and str(a[h].get('kind', '')).startswith('DIM_') and a[h].get('block_handle')}
    dimkids = {h for h, e in a.items() if e.get('owner') in dimblocks}
    kids |= {h for h, e in a.items() if e.get('owner') in moved and str(e.get('kind', '')).startswith('VERTEX')}         # the vertices of a moved polyline carry its coordinates
    kids |= dimkids                                                           # the picture block of a moved dimension travels with it
    kids |= set(getattr(doc, 'assoc_dropped', ()))                            # associative hatches whose erased boundary object they listed became non-associative
    bad = [h for h in a if h not in gone and h not in moved and h not in kids and b.get(h) != a[h]]
    def _lost(h):          # a moved POLYLINE keeps its own record when its vertices carry the coordinates: then a vertex must have changed
        if b.get(h) != a.get(h): return False
        if str(a.get(h, {}).get('kind', '')).startswith('POLYLINE'): return not any(b.get(v) != a.get(v) for v, e in a.items() if e.get('owner') == h)
        return True
    unmoved = [h for h in moved if _lost(h)] + [h for h in dimkids if h not in gone and b.get(h) == a.get(h)]       # a moved object whose record did not change would mean the move was lost
    if unmoved: raise SaveError('verification failed: %d moved object(s) are unchanged in the result (nothing written)' % len(unmoved))
    if set(b) != (set(a) - gone) | set(created) or bad: raise SaveError('verification failed: %d of %d entity records differ (source kept, nothing written)%s' % (len(bad), len(a), _first_diff(a, b, bad)))
    d2 = dwgdoc.Doc(out)
    for name, w in want.items():
        fl = d2.get(d2.layer_handle(name))['flags']
        if {'frozen': bool(fl & 1), 'off': bool(fl & 2), 'locked': bool(fl & 8)} != w: raise SaveError('verification failed: layer flags of %s differ from the request' % name)
    sgm = _sg()
    if sgm:                                      # c8-savegate library: lock, conflict check, independent verify, backup, atomic write (see ~/demo-state/savegate-contract.md)
        link_only, extra_added, extra_deleted, struct = _object_effects(ma, mb, a, b, fa, fb, gone, set(created), set(layer_hs))
        manifest = {'modified': sorted({h for h in a if h in b and h not in gone and a[h] != b[h]} | set(layer_hs) | link_only | struct), 'added': sorted(set(created) | extra_added), 'deleted': sorted(gone | extra_deleted)}
        res = _write_sg(sgm, sgdoc, src, dst, out, overwrite, manifest)
        bak = res.backup
        r = {'path': dst, 'bytes': len(out), 'entities': len(a), 'layers_changed': touched, 'erased': len(erase), 'moved': len(moved), 'copied': len(created), 'moved_with': len(kids), 'version': buf[:6].decode('latin1'), 'savegate': {'sha256': res.sha256, 'verify': res.report.get('validate'), 'seconds': round(res.elapsed, 3)}}
        if bak: r['backup'] = bak
        if res.report.get('warnings'): r['warnings'] = list(res.report['warnings'])
        if dmg: r.setdefault('warnings', []).append('the source file is damaged (%d object(s) fail their checksum): the new file was written from what could be read' % dmg)        # e.g. another program changed the file in the last instant: that version was kept as a backup
        return r
    tmp = os.path.join(d, '.%s.tmp-%d' % (os.path.basename(dst), os.getpid()))
    try:
        with open(tmp, 'xb') as f:
            f.write(out); f.flush(); os.fsync(f.fileno())
        if overwrite:
            if fingerprint(src) != fp0: raise SaveError('the source file changed while saving; nothing was replaced')
            bak = backup(src)
        elif os.path.exists(dst): raise SaveError('refusing to overwrite an existing file: ' + dst)
        plat.fsio.replace_retry(tmp, dst)
    except BaseException:
        try: os.remove(tmp)
        except OSError: pass
        raise
    r = {'path': dst, 'bytes': len(out), 'entities': len(a), 'layers_changed': touched, 'erased': len(erase), 'moved': len(moved), 'copied': len(created), 'moved_with': len(kids), 'version': buf[:6].decode('latin1')}
    if bak: r['backup'] = bak
    return r


_SG = []


def _sg():
    """the savegate library (stdlib only): $SAVEGATE_LIB, ~/src/savegate, or an installed copy; None = legacy write path below"""
    if not _SG:
        for lib in (os.environ.get('SAVEGATE_LIB'), os.path.expanduser('~/src/savegate'), os.path.join(HERE, 'vendor')):
            if lib and os.path.isdir(os.path.join(lib, 'savegate')) and lib not in sys.path: sys.path.append(lib)
        try:
            import savegate as m
            _SG.append(m if hasattr(m, 'open_doc') else None)
        except ImportError: _SG.append(None)
    return _SG[0]


def _adapter(sgm):
    """library DwgAdapter; entities without a block name (blk None) are keyed with '' (the library concatenates the name as a str, see NEEDS-FROM-SAVEGATE.md)"""
    class _P:
        def __init__(self, m): self._m = m
        def __getattr__(self, k): return getattr(self._m, k)
        def entities(self): return ((b or '', e) for b, e in self._m.entities())
    class A(sgm.adapters.DwgAdapter):
        def _snap(self, m, same): return super()._snap(_P(m), same)
    return A(HERE)


def sg_config():
    sgm = _sg()
    return sgm.Config(allow_overwrite=overwrite_allowed()) if sgm else None


def sg_open(path):
    """one library Doc per open drawing (fingerprint + edit journal); None if the library is not installed"""
    sgm = _sg()
    if not sgm: return None
    try: return sgm.open_doc(path, adapter=_adapter(sgm), cfg=sg_config())
    except Exception: return None


def _write_sg(sgm, sgdoc, src, dst, out, overwrite, manifest):
    try:
        if sgdoc is None or sgdoc.path != os.path.abspath(src): sgdoc = sgm.open_doc(src, adapter=_adapter(sgm), cfg=sg_config(), journal=False)
        sgdoc.cfg = sg_config()
        return sgm.save(sgdoc, out, manifest) if overwrite else sgm.save_as(sgdoc, out, dst, manifest)
    except sgm.SaveError as ex:
        raise (Conflict if type(ex).__name__ == 'Conflict' else SaveError)('%s: %s' % (type(ex).__name__, ex)) from ex


BACKUPS = os.environ.get('DWG_BALLET_BACKUPS') or os.path.join(plat.dirs.cache_dir('dwg-ballet'), 'backups')
CONFIG = os.environ.get('DWG_BALLET_CONFIG') or os.path.join(plat.dirs.config_dir('dwg-ballet'), 'config.json')


def overwrite_allowed():
    """Overwrite (SAVE!) is OFF unless the config file says {"allow_overwrite": true}"""
    try:
        import json; return json.load(open(CONFIG)).get('allow_overwrite') is True
    except Exception:
        return False


def untouched_note(ex, note):
    """refusal text for the user: the error plus a plain statement that nothing was changed (unless the message already says so)"""
    m = str(ex).rstrip('. ')
    return m if any(w in m.lower() for w in ('untouched', 'not touched', 'unchanged', 'nothing was written', 'nothing written', 'not changed', 'nothing was replaced')) else '%s; %s' % (m, note)


def _first_diff(a, b, bad):
    """'; first: handle X (KIND) keys k1, k2' for the first differing record, so a failed verification says what changed"""
    if not bad: return ''
    h = min(bad); ra, rb = a.get(h), b.get(h)
    if rb is None: return '; first: handle %X (%s) is missing in the result' % (h, (ra or {}).get('kind'))
    keys = sorted(k for k in set(ra) | set(rb) if ra.get(k) != rb.get(k))[:5]
    return '; first: handle %X (%s) keys %s' % (h, ra.get('kind'), ', '.join(map(str, keys)))


def backup(path):
    """copy of the file as it is before an overwrite: BACKUPS/<name>.bak-YYYYmmdd-HHMMSS-<sha1 8> (hash-verified copy)"""
    import shutil, time
    os.makedirs(BACKUPS, exist_ok=True)
    h = hashlib.sha1(_rb(path)).hexdigest()
    dst = os.path.join(BACKUPS, '%s.bak-%s-%s' % (os.path.basename(path), time.strftime('%Y%m%d-%H%M%S'), h[:8]))
    shutil.copy2(path, dst)
    if hashlib.sha1(_rb(dst)).hexdigest() != h: os.remove(dst); raise SaveError('backup copy does not match the original; nothing was replaced')
    return dst


def save_over(src, layers, fp=None, erase=(), move=(), sgdoc=None, force=False):
    """Overwrite the source file (command SAVE!): only with allow_overwrite in the config, after a verified backup of the original"""
    if not overwrite_allowed(): raise SaveError('overwrite is disabled (set allow_overwrite in %s); use SAVEAS' % CONFIG)
    return save_as(src, src, layers, fp, overwrite=True, erase=erase, move=move, sgdoc=sgdoc, force=force)


def restore(backup_path, target):
    """put a backup back (atomic rename of a temp copy), e.g. RESTORE after a bad overwrite"""
    import shutil
    tmp = target + '.restore-tmp'
    shutil.copy2(backup_path, tmp); plat.fsio.replace_retry(tmp, target)


def sg_backups(path):
    """[{n, name, size, mtime}] newest first (the library backup store, see sg.list_backups)"""
    sgm = _sg()
    if not sgm: return []
    return [{'n': i, 'name': name, 'size': size, 'mtime': int(os.stat(p).st_mtime)} for i, (name, p, size) in enumerate(sgm.list_backups(path))]


def sg_restore(path, n=0):
    """RESTORE n: backup n (0 = newest) replaces the file atomically; the current file is backed up first"""
    sgm = _sg()
    if not sgm: raise SaveError('the savegate library is not installed')
    try: return sgm.restore(path, n)
    except sgm.SaveError as ex: raise SaveError('%s: %s' % (type(ex).__name__, ex)) from ex


def sg_sessions(sgdoc=None):
    """journals of sessions that did not close cleanly (not this one): [{id, source, edits, last}]"""
    sgm = _sg()
    if not sgm: return []
    own = sgdoc.journal.path if sgdoc is not None and sgdoc.journal else None
    out = []
    for p, ents in sgm.recover():
        if p == own: continue
        src = next((e.get('source') for e in ents if e.get('kind') == 'open'), None)
        out.append({'id': os.path.basename(p)[:-6], 'source': src, 'edits': sum(1 for e in ents if e.get('kind') == 'edit'), 'last': int(ents[-1].get('t', 0)), 'cmds': [e.get('cmd') for e in ents if e.get('kind') == 'edit' and e.get('cmd')]})
    return out


def save_mode(path=None):
    """what plain SAVE does: {'mode': 'overwrite'|'saveas', 'reason': ...}. Overwrite needs allow_overwrite in the config AND an open oracle gate for this format+version"""
    if not overwrite_allowed(): return {'mode': 'saveas', 'reason': 'overwrite is off (allow_overwrite in %s)' % CONFIG}
    sgm = _sg()
    if sgm is None: return {'mode': 'saveas', 'reason': 'the savegate library is not installed'}
    ver = ''
    if path:
        try:
            with open(path, 'rb') as f: ver = f.read(6).decode('latin1')
        except OSError: pass
    if not sgm.gate_open('dwg', ver, sg_config()): return {'mode': 'saveas', 'reason': 'the oracle gate for DWG %s is closed' % (ver or '?')}
    return {'mode': 'overwrite', 'reason': ''}

"""Document layer (own code): open a DWG (AC1015 or R2004 family), create / edit / delete objects through the symmetric codec
(dwgcodec), keep every object we do not touch byte-exact, and save with the container writers (dwgwrite).

    doc = Doc(open('template.dwg', 'rb').read())
    h = doc.add_layer('A-WALL', color=3)
    doc.add_line((0, 0, 0), (100, 0, 0), layer='A-WALL')
    open('out.dwg', 'wb').write(doc.save())
"""
import struct
import dwgfmt as F
import dwgload
import dwgbits as B
import dwgbitw as W
import dwgcodec as C
import dwgedit
import dwgwrite

UP = (0.0, 0.0, 1.0)


GENERIC_ENTITIES = (74,)        # OLE2FRAME: an entity without a type codec; its type specific bits are kept verbatim (codec.decode_generic), only the common head / links are edited


class Doc:
    def __init__(self, buf):
        self.buf = bytes(buf)
        d = dwgload.load(self.buf)
        self.ver = d['version']
        self.objs = d['objects']
        self.assoc_dropped = set()          # hatches made non-associative because a boundary object was erased (callers expect those records to change)
        self.codepage = struct.unpack_from('<H', self.buf, 0x13)[0]
        for o in self.objs.values():
            o.codepage = self.codepage
        self.clsmap = {}; self.clsitem = {}
        try:
            for c in self._classes():
                self.clsmap[c['num']] = c['dxf']; self.clsitem[c['num']] = c['item']
        except Exception:
            pass
        self.dec = {}           # handle -> decoded dict (cache; objects in `dirty` are re-encoded on save)
        self.dirty = set()
        self.deleted = set()
        self.order = self._file_order()
        self.new_order = []
        self.max_handle = max(self.objs)
        self.seed_handle = self.max_handle
        self._names = {}

    def _section(self, name):
        if self.ver == 'AC1021':
            import dwgr21
            return dwgr21.section_data(self.buf, dwgr21.open_r21(self.buf), name)[0]
        return F.r2004_section_data(self.buf, F.r2004_open(self.buf), name)

    def _classes(self):
        import dwgmodel, dwgobj as O
        if self.ver == 'AC1015':
            return O.parse_classes_r2000(O.load_r2000(self.buf)['classes'])
        return dwgmodel.parse_classes(self._section('AcDb:Classes'), self.ver)

    # ------------------------------------------------------------ low level
    def _file_order(self):
        if self.ver == 'AC1015':
            import dwgobj as O
            d = O.load_r2000(self.buf)
            return [o.handle for o in sorted(d['objects'].values(), key=lambda o: o.offset)]
        hs = self._section('AcDb:Handles')
        omap, ok = F.object_map_r13_r2000(hs, (0, 0, len(hs)))
        return [h for h, off in sorted(omap.items(), key=lambda kv: kv[1])]

    def exists(self, h):
        return (h in self.objs or h in self.dec) and h not in self.deleted

    def otype(self, h):
        if h in self.dec: return self.dec[h]['type']
        return self.objs[h].type

    def get(self, h):
        """decoded dict of object h (cached; mutate and call put(d) to store the change)"""
        if h in self.deleted: raise KeyError('deleted %x' % h)
        d = self.dec.get(h)
        if d is None:
            o = self.objs[h]
            key = self.clsmap.get(o.type)
            if not C.known(o.type, key) and (self.clsitem.get(o.type) == 499 or (o.type >= 49 and o.type not in C.ENT and o.type not in GENERIC_ENTITIES and o.type < 500)):
                raise NotImplementedError('no codec for object type %d (%s)' % (o.type, key))
            try:
                d = C.decode(o, self.codepage, True, key)
            except (NotImplementedError, ValueError, IndexError, TypeError):
                if o.type in C.ENT and key is None:        # entity whose type specific part we cannot parse (e.g. multiline attribute): common head only
                    d = C.decode_generic(o, self.codepage)
                else:
                    raise
            self.dec[h] = d
        return d

    def put(self, d):
        self.dec[d['handle']] = d
        self.dirty.add(d['handle'])
        return d['handle']

    def new_handle(self):
        self.max_handle += 1
        return self.max_handle

    def create(self, d):
        """store a new object dict (needs d['type']); allocates a handle when missing"""
        if not d.get('handle'): d['handle'] = self.new_handle()
        self.max_handle = max(self.max_handle, d['handle'])
        self.put(d)
        if d['handle'] not in self.objs and d['handle'] not in self.new_order:
            self.new_order.append(d['handle'])
        return d['handle']

    def delete(self, h):
        self.deleted.add(h)
        self.dec.pop(h, None)
        self.dirty.discard(h)

    def by_type(self, t):
        return [h for h in self.objs if self.objs[h].type == t and h not in self.deleted] + \
               [h for h, d in self.dec.items() if d['type'] == t and h not in self.objs and h not in self.deleted]

    # ------------------------------------------------------------ tables
    def control(self, t):
        hs = [h for h in self.objs if self.objs[h].type == t]
        if not hs: raise KeyError('no control object of type %d' % t)
        return hs[0]

    def table(self, t_control, t_entry):
        """{lower-case name: handle} of a symbol table"""
        c = self.get(self.control(t_control))
        out = {}
        for h in c['entries'] + (c.get('extras', []) if t_control in (48, 56) else []):
            if h in self.deleted or not self.exists(h): continue
            out[self.get(h)['name'].lower()] = h
        return out

    def layers(self): return self.table(50, 51)
    def ltypes(self): return self.table(56, 57)
    def styles(self): return self.table(52, 53)
    def blocks(self): return self.table(48, 49)
    def appids(self): return self.table(66, 67)

    def layer_handle(self, name):
        return self.layers()[name.lower()]

    def _add_entry(self, tcontrol, d, owner_extra=False):
        c = self.get(self.control(tcontrol))
        h = self.create(d)
        c['entries'].append(h)
        self.put(c)
        return h

    # ---- layers
    def add_layer(self, name, color=7, ltype='Continuous', lineweight=-3, plot=True, frozen=False, off=False, locked=False, rgb=None, like='0'):
        """lineweight: 1/100 mm value or -3 (default) / -2 (byblock) / -1 (bylayer); color: ACI index"""
        if name.lower() in self.layers(): raise ValueError('layer exists: ' + name)
        tmpl = self.get(self.layers()[like.lower()])
        d = {k: v for k, v in tmpl.items() if k not in ('handle', '_h', 'xdic', 'eed')}
        d['handle'] = 0
        d['name'] = name
        d['xdic_missing'] = 1; d['nreactors'] = 0; d['reactors'] = []; d.pop('xdic', None)
        d['owner'] = self.control(50)
        fl = 0
        if frozen: fl |= 1
        if off: fl |= 2
        if locked: fl |= 8
        if plot: fl |= 16
        fl |= LW_CODE[lineweight] << 5
        d['flags'] = fl
        d['color'] = self._layer_color(color, rgb)
        d['ltype'] = self.ltypes()[ltype.lower()]
        d['eed'] = []
        return self._add_entry(50, d)

    def _layer_color(self, color, rgb=None):
        if self.ver == 'AC1015':
            return (color,)
        if rgb:
            return (0, 0xC2000000 | (rgb[0] << 16) | (rgb[1] << 8) | rgb[2], 0, None, None)
        return (0, 0xC3000000 | color, 0, None, None)

    def set_layer(self, name, **kw):
        """change layer properties: color, frozen, off, locked, plot, lineweight, ltype, new_name"""
        h = self.layer_handle(name)
        d = self.get(h)
        fl = d['flags']
        def setbit(bit, v):
            nonlocal fl
            fl = (fl | bit) if v else (fl & ~bit)
        if 'frozen' in kw: setbit(1, kw['frozen'])
        if 'off' in kw: setbit(2, kw['off'])
        if 'locked' in kw: setbit(8, kw['locked'])
        if 'plot' in kw: setbit(16, kw['plot'])
        if 'lineweight' in kw: fl = (fl & ~(0x1F << 5)) | (LW_CODE[kw['lineweight']] << 5)
        d['flags'] = fl
        if 'color' in kw:
            d['color'] = self._layer_color(kw['color'], kw.get('rgb'))
        if 'ltype' in kw: d['ltype'] = self.ltypes()[kw['ltype'].lower()]
        if 'new_name' in kw: d['name'] = kw['new_name']
        self.put(d)
        return h

    # ------------------------------------------------------------ entities
    def block_handle(self, name):
        return self.blocks()[name.lower()]

    def model_space(self): return self.block_handle('*Model_Space')
    def paper_space(self): return self.block_handle('*Paper_Space')

    def _entity(self, otype, block, layer, **fields):
        bh = block if isinstance(block, int) else self.block_handle(block)
        bd = self.get(bh)
        d = dict(type=otype, handle=0, eed=[], graphic=None, nreactors=0, reactors=[], xdic_missing=1, color=(256, None, None), ltscale=1.0,
                 ltflags=0, plotflags=0, invis=0, lweight=29)
        if self.ver != 'AC1015':
            d['has_binary'] = 0
        if self.ver in C.WIDE:
            d.update(matflags=0, shadow=0)
            if self.ver in C.R2010: d.update(vs_full=0, vs_face=0, vs_edge=0)
        lname = bd['name'].lower()
        if lname == '*model_space': d['entmode'] = 2
        elif lname == '*paper_space': d['entmode'] = 1
        else:
            d['entmode'] = 0; d['owner'] = bh
        d['layer'] = layer if isinstance(layer, int) else self.layer_handle(layer)
        for k in ('color', 'ltscale', 'lweight', 'invis'):
            if k in fields: d[k] = fields.pop(k)
        if isinstance(d['color'], int): d['color'] = (d['color'], None, None)
        if d['lweight'] in (-1, -2, -3): d['lweight'] = {-1: 29, -2: 30, -3: 31}[d['lweight']]
        if 'ltype' in fields:
            lt = fields.pop('ltype')
            if lt is not None:
                d['ltflags'] = 3; d['ltype'] = lt if isinstance(lt, int) else self.ltypes()[lt.lower()]
        d.update(fields)
        return d, bh

    def add_entity(self, otype, block='*Model_Space', layer='0', **fields):
        d, bh = self._entity(otype, block, layer, **fields)
        h = self.create(d)
        self._link(bh, h)
        return h

    def _link(self, bh, h):
        """append entity h to the owner block's entity list / chain"""
        bd = self.get(bh)
        if self.ver != 'AC1015':
            bd['owned'].append(h)
            self.put(bd)
            return
        last = bd['last']
        e = self.get(h)
        e['xdic_missing'] = 0
        e['prev'] = last; e['next'] = 0
        self.put(e)
        if last:
            le = self.get(last)
            if le['xdic_missing']:
                le['xdic_missing'] = 0; le['prev'] = le.get('prev', 0)
            le['next'] = h
            self.put(le)
        else:
            bd['first'] = h
        bd['last'] = h
        self.put(bd)

    def _unlink(self, bh, h):
        bd = self.get(bh)
        if self.ver != 'AC1015':
            bd['owned'].remove(h)
            self.put(bd)
            return
        # R2000: links are explicit only when nolinks == 0; entities with nolinks == 1 follow handle order inside the block
        chain = self.chain(bh)
        i = chain.index(h)
        prev = chain[i - 1] if i > 0 else 0
        nxt = chain[i + 1] if i + 1 < len(chain) else 0
        if prev:
            pe = self.get(prev); self._set_links(pe); pe['next'] = nxt; self.put(pe)
        else:
            bd['first'] = nxt
        if nxt:
            ne = self.get(nxt); self._set_links(ne); ne['prev'] = prev; self.put(ne)
        else:
            bd['last'] = prev
        self.put(bd)

    def _set_links(self, e):
        if e['xdic_missing']:
            # nolinks entity: materialise explicit links (prev/next are the neighbours in the block chain)
            bh = self.owner_block(e['handle'])
            chain = self.chain(bh)
            i = chain.index(e['handle'])
            e['xdic_missing'] = 0
            e['prev'] = chain[i - 1] if i else 0
            e['next'] = chain[i + 1] if i + 1 < len(chain) else 0

    def chain(self, bh):
        """entity handles of a block in order (AC1015: follow the links, else the owned list)"""
        bd = self.get(bh)
        if self.ver != 'AC1015':
            return list(bd['owned'])
        out = []
        h = bd['first']
        while h:
            out.append(h)
            if h == bd['last']: break
            e = self.get(h)
            h = e['next'] if not e['xdic_missing'] else h + 1
        return out

    def erase(self, h):
        d = self.get(h)
        if d['entmode'] == 2: bh = self.model_space()
        elif d['entmode'] == 1: bh = self.paper_space()
        else: bh = d['owner']
        self._unlink(bh, h)
        for hh in self.by_type(78):         # an associative hatch must not keep pointing at the erased boundary object (AUDIT: 'Boundary Undefined'): as in AutoCAD it becomes non-associative
            hd = self.get(hh)
            if hd.get('assoc') and any(h in (p.get('boundary') or []) for p in hd['paths']):
                hd['assoc'] = 0
                for p in hd['paths']: p['boundary'] = []; p['nboundary'] = 0
                self.put(hd); self.assoc_dropped.add(hh)
        self.delete(h)

    # ---- convenience constructors
    def add_line(self, p1, p2, block='*Model_Space', layer='0', **kw):
        return self.add_entity(19, block, layer, p1=tuple(map(float, p1)) + (0.0,) * (3 - len(p1)), p2=tuple(map(float, p2)) + (0.0,) * (3 - len(p2)), thickness=0.0, ext=UP, **kw)

    def add_circle(self, c, r, block='*Model_Space', layer='0', **kw):
        return self.add_entity(18, block, layer, center=tuple(map(float, c)) + (0.0,) * (3 - len(c)), radius=float(r), thickness=0.0, ext=UP, **kw)

    def add_arc(self, c, r, a0, a1, block='*Model_Space', layer='0', **kw):
        return self.add_entity(17, block, layer, center=tuple(map(float, c)) + (0.0,) * (3 - len(c)), radius=float(r), a0=float(a0), a1=float(a1), thickness=0.0, ext=UP, **kw)

    def add_point(self, p, block='*Model_Space', layer='0', **kw):
        return self.add_entity(27, block, layer, p=tuple(map(float, p)) + (0.0,) * (3 - len(p)), thickness=0.0, ext=UP, xangle=0.0, **kw)

    def add_lwpolyline(self, pts, closed=False, bulges=None, widths=None, const_width=0.0, elevation=0.0, block='*Model_Space', layer='0', **kw):
        fl = 512 if closed else 0
        return self.add_entity(77, block, layer, flags=fl, pts=[tuple(map(float, p[:2])) for p in pts], bulges=list(bulges or []), widths=list(widths or []),
                               ids=[], const_width=const_width, elevation=elevation, thickness=0.0, ext=UP, **kw)

    def add_ellipse(self, center, major, ratio, a0=0.0, a1=6.283185307179586, block='*Model_Space', layer='0', **kw):
        return self.add_entity(35, block, layer, center=tuple(map(float, center)), major=tuple(map(float, major)), ext=UP, ratio=float(ratio), a0=a0, a1=a1, **kw)

    def add_text(self, ins, text, height, rot=0.0, style='Standard', halign=0, valign=0, widthf=1.0, oblique=0.0, block='*Model_Space', layer='0', **kw):
        """TEXT; for halign/valign != 0 `ins` is the alignment anchor (as in the AutoCAD command) and the stored insertion point is estimated
        from the text width (AutoCAD keeps both)"""
        sh = self.styles()[style.lower()]
        anchor = (float(ins[0]), float(ins[1]))
        left = anchor
        if halign or valign:
            import dwgfont
            tw = dwgfont.text_width(text, height, widthf) * dwgfont.style_factor(self.get(sh)['font'])
            dx = {0: 0.0, 1: tw / 2, 2: tw, 3: 0.0, 4: tw / 2, 5: 0.0}.get(halign, 0.0)
            dy = {0: 0.0, 1: 0.0, 2: 0.0, 3: height / 2, 2.5: 0.0}.get(valign, 0.0) if valign in (0, 1, 2, 3) else 0.0
            if halign == 4: dy = height / 2
            import math
            c, s_ = math.cos(rot), math.sin(rot)
            left = (anchor[0] - dx * c + dy * s_, anchor[1] - dx * s_ - dy * c)
            kw.setdefault('align', anchor)
        return self.add_entity(1, block, layer, ins=left, elev=float(ins[2]) if len(ins) > 2 else 0.0, height=float(height), text=text, rot=rot, widthf=widthf,
                               oblique=oblique, halign=halign, valign=valign, gen=0, ext=UP, thickness=0.0, style=sh, **kw)

    def add_solid(self, pts, block='*Model_Space', layer='0', **kw):
        return self.add_entity(31, block, layer, pts=[tuple(map(float, p[:2])) for p in pts], elev=0.0, thickness=0.0, ext=UP, **kw)


# ---------------------------------------------------------------- blocks, inserts, attributes
import copy
import math


def _add_block(self, name, base=(0.0, 0.0, 0.0), description='', layer='0'):
    """new block definition (BLOCK_HEADER + BLOCK + ENDBLK); returns the block header handle"""
    if name.lower() in self.blocks() and not name.startswith('*'): raise ValueError('block exists: ' + name)
    ms = self.model_space()
    th = self.get(ms)
    blk = self.get(th['block']); end = self.get(th['endblk'])
    bh = self.new_handle(); hb = self.new_handle(); he = self.new_handle()
    lay = self.layer_handle(layer)
    d = copy.deepcopy(th)
    d.update(handle=bh, name=name, anonymous=0, has_attribs=0, is_xref=0, overlaid=0, loaded=0, nowned=0, owned=[], first=0, last=0, base=tuple(map(float, base)),
             xref_path='', ninserts=0, inserts=[], description=description, preview=b'', layout=0, block=hb, endblk=he, owner=self.control(48),
             xdic_missing=1, nreactors=0, reactors=[], eed=[])
    d.pop('xdic', None); d.pop('_h', None); d['xdic'] = 0
    d['_extra_h'] = []
    b = copy.deepcopy(blk); b.update(handle=hb, name=name, entmode=0, owner=bh, layer=lay, eed=[]); b.pop('_h', None)
    e = copy.deepcopy(end); e.update(handle=he, entmode=0, owner=bh, layer=lay, eed=[]); e.pop('_h', None)
    for x in (b, e):
        if 'prev' in x: x['prev'] = 0; x['next'] = 0
    self.create(d); self.create(b); self.create(e)
    c = self.get(self.control(48)); c['entries'].append(bh); self.put(c)
    return bh


def _add_attdef(self, block, tag, prompt, default, ins, height, rot=0.0, flags=0, style='Standard', layer='0', halign=0, valign=0, **kw):
    """ATTDEF in a block; flags: 1 invisible, 2 constant, 4 verify, 8 preset"""
    sh = self.styles()[style.lower()]
    h = self.add_entity(3, block, layer, ins=tuple(map(float, ins[:2])), elev=float(ins[2]) if len(ins) > 2 else 0.0, height=float(height), text=default, rot=rot, widthf=1.0,
                        oblique=0.0, halign=halign, valign=valign, gen=0, ext=UP, thickness=0.0, style=sh, tag=tag, prompt=prompt, field_length=0,
                        attflags=flags, lock_position=0, version=0, version2=0, attr_type=1, **kw)
    if halign or valign:
        d = self.get(h); d['align'] = tuple(map(float, ins[:2])); self.put(d)
    bh = block if isinstance(block, int) else self.block_handle(block)
    bd = self.get(bh); bd['has_attribs'] = 1; self.put(bd)
    return h


def _xform2(p, ins, sc, rot, base):
    x = (p[0] - base[0]) * sc[0]; y = (p[1] - base[1]) * sc[1]
    c, s = math.cos(rot), math.sin(rot)
    return (ins[0] + x * c - y * s, ins[1] + x * s + y * c)


def _add_insert(self, name, ins, scale=(1.0, 1.0, 1.0), rot=0.0, attribs=None, block='*Model_Space', layer='0', **kw):
    """INSERT of block `name`; for each ATTDEF of the block an ATTRIB is created (values from `attribs` {tag: value}, else the default)"""
    if isinstance(scale, (int, float)): scale = (scale, scale, scale)
    ibh = self.block_handle(name)
    ib = self.get(ibh)
    attribs = {k.upper(): v for k, v in (attribs or {}).items()}
    defs = [h for h in self.chain(ibh) if self.get(h)['type'] == 3]
    h = self.add_entity(7, block, layer, ins=tuple(map(float, ins)) + (0.0,) * (3 - len(ins)), scale=tuple(map(float, scale)), rot=float(rot), ext=UP,
                        has_attribs=1 if defs else 0, bheader=ibh, **kw)
    ins_d = self.get(h)
    ib['inserts'].append(h); self.put(ib)
    if not defs: return h
    base = ib['base']
    made = []
    for dh in defs:
        ad = copy.deepcopy(self.get(dh))
        ah = self.new_handle()
        ad.update(type=2, handle=ah, entmode=0, owner=h, xdic_missing=1, nreactors=0, reactors=[], eed=[])
        for k in ('prompt', 'version2', '_h', 'xdic', 'prev', 'next'): ad.pop(k, None)
        ad['text'] = attribs.get(ad['tag'].upper(), ad['text'])
        ad['ins'] = _xform2(ad['ins'], ins, scale, rot, base)
        ad['align'] = _xform2(ad.get('align', ad['ins']), ins, scale, rot, base)
        ad['height'] = ad['height'] * abs(scale[1]); ad['rot'] = ad['rot'] + rot
        if self.ver == 'AC1015': ad['xdic_missing'] = 0
        made.append(ad)
    sq = dict(type=6, handle=self.new_handle(), eed=[], graphic=None, entmode=0, owner=h, nreactors=0, reactors=[], xdic_missing=1, color=(256, None, None), ltscale=1.0,
              ltflags=0, plotflags=0, invis=0, lweight=29, layer=ins_d['layer'])
    if self.ver != 'AC1015': sq['has_binary'] = 0
    if self.ver in C.WIDE:
        sq.update(matflags=0, shadow=0)
        if self.ver in C.R2010: sq.update(vs_full=0, vs_face=0, vs_edge=0)
    if self.ver == 'AC1015': sq.update(xdic_missing=0, prev=0, next=0)
    for i, ad in enumerate(made):
        if self.ver == 'AC1015':
            ad['xdic_missing'] = 0; ad['prev'] = made[i - 1]['handle'] if i else 0; ad['next'] = made[i + 1]['handle'] if i + 1 < len(made) else 0
        self.create(ad)
    self.create(sq)
    ins_d['seqend'] = sq['handle']
    if self.ver == 'AC1015':
        ins_d['first_attrib'] = made[0]['handle']; ins_d['last_attrib'] = made[-1]['handle']
    else:
        ins_d['attribs'] = [a['handle'] for a in made]; ins_d['nowned'] = len(made)
    self.put(ins_d)
    return h


Doc.add_block = _add_block
Doc.add_attdef = _add_attdef
Doc.add_insert = _add_insert


# ---------------------------------------------------------------- more entity builders
def _v3(p):
    p = tuple(map(float, p))
    return p + (0.0,) * (3 - len(p))


def _add_mtext(self, ins, text, height, width=0.0, attachment=1, rot=0.0, style='Standard', ls_style=1, ls_factor=1.0, block='*Model_Space', layer='0', **kw):
    """MTEXT; `text` uses MTEXT codes (\\P new line ...). Extents are estimated (AutoCAD recomputes them)."""
    sh = self.styles()[style.lower()]
    lines = text.replace('\\P', '\n').split('\n')
    import dwgfont
    ext_w = width if width else max(dwgfont.text_width(l, height) for l in lines) * dwgfont.style_factor(self.get(sh)['font'])
    ext_h = len(lines) * height * 1.4
    c, s_ = math.cos(rot), math.sin(rot)
    c = 0.0 if abs(c) < 1e-12 else c; s_ = 0.0 if abs(s_) < 1e-12 else s_      # AutoCAD rejects xdir residue like 6e-17
    d = dict(ins=_v3(ins), ext=UP, xdir=(c, s_, 0.0), width=float(width), rect_height=0.0, text_height=float(height), attachment=attachment, drawdir=5,
             ext_h=ext_h, ext_w=ext_w, text=text, ls_style=ls_style, ls_factor=ls_factor, unknown_b=0, bg_flags=0, style=sh)
    d.update(kw)
    return self.add_entity(44, block, layer, **d)


def _add_spline(self, ctrl=None, fit=None, degree=3, knots=None, weights=None, closed=False, block='*Model_Space', layer='0', **kw):
    """SPLINE from control points (NURBS) or fit points"""
    if ctrl is not None:
        ctrl = [_v3(p) for p in ctrl]
        n = len(ctrl)
        if knots is None:
            k = [0.0] * (degree + 1) + [float(i) for i in range(1, n - degree)] + [float(n - degree)] * (degree + 1)
            mx = k[-1] or 1.0
            knots = [x / mx for x in k] if False else k
        d = dict(scenario=1, sflags=0, kparam=15, degree=degree, rational=1 if weights else 0, closed=1 if closed else 0, periodic=0, knot_tol=1e-7, ctrl_tol=1e-10,
                 knots=list(knots), ctrl=ctrl, weights=list(weights or []))
    else:
        d = dict(scenario=2 if self.ver not in C.R2013 else 1, sflags=9, kparam=0, degree=degree, fit_tol=0.0, tan0=(0.0, 0.0, 0.0), tan1=(0.0, 0.0, 0.0), fit=[_v3(p) for p in fit])
        if self.ver not in C.R2013: d.pop('sflags'); d.pop('kparam')
    d.update(kw)
    return self.add_entity(36, block, layer, **d)


def _add_xline(self, p, v, block='*Model_Space', layer='0', **kw):
    n = math.sqrt(sum(x * x for x in v)) or 1.0
    return self.add_entity(41, block, layer, p=_v3(p), v=tuple(x / n for x in _v3(v)), **kw)


def _add_ray(self, p, v, block='*Model_Space', layer='0', **kw):
    n = math.sqrt(sum(x * x for x in v)) or 1.0
    return self.add_entity(40, block, layer, p=_v3(p), v=tuple(x / n for x in _v3(v)), **kw)


def _add_3dface(self, pts, block='*Model_Space', layer='0', invisible=0, **kw):
    return self.add_entity(28, block, layer, pts=[_v3(p) for p in pts], invisible=invisible, **kw)


def _add_polyline2d(self, pts, closed=False, bulges=None, block='*Model_Space', layer='0', **kw):
    """heavy POLYLINE with VERTEX2D / SEQEND (prefer LWPOLYLINE)"""
    bh = block if isinstance(block, int) else self.block_handle(block)
    bulges = bulges or [0.0] * len(pts)
    ph = self.add_entity(15, bh, layer, flags=1 if closed else 0, curve=0, start_width=0.0, end_width=0.0, thickness=0.0, elev=0.0, ext=UP, nowned=len(pts), vertices=[], seqend=0, **kw)
    pd = self.get(ph)
    verts = []
    for p, b in zip(pts, bulges):
        d, _ = self._entity(10, bh, layer)
        d.update(entmode=0, owner=ph, flags=0, p=_v3(p), start_width=0.0, end_width=0.0, same_width=False, bulge=float(b), tangent=0.0)
        if self.ver in C.R2010: d['vid'] = 0
        d.pop('owner') if False else None
        d['entmode'] = 0
        verts.append(self.create(d))
    sq, _ = self._entity(6, bh, layer)
    sq['entmode'] = 0; sq['owner'] = ph
    sh = self.create(sq)
    if self.ver == 'AC1015':
        pd['first'] = verts[0]; pd['last'] = verts[-1]
        for i, v in enumerate(verts):
            e = self.get(v); e['xdic_missing'] = 0; e['prev'] = verts[i - 1] if i else 0; e['next'] = verts[i + 1] if i + 1 < len(verts) else 0; self.put(e)
    pd['vertices'] = verts; pd['nowned'] = len(verts); pd['seqend'] = sh
    self.put(pd)
    return ph


def _add_leader(self, pts, dimstyle='Standard', arrow=True, block='*Model_Space', layer='0', **kw):
    dsh = self.dimstyles()[dimstyle.lower()]
    return self.add_entity(45, block, layer, unknown_b=0, annotation=3, path=0, pts=[_v3(p) for p in pts], end_proj=(0.0, 0.0, 0.0), ext=UP, xdir=(1.0, 0.0, 0.0),
                           block_offset=(0.0, 0.0, 0.0), annot_offset=(0.0, 0.0, 0.0), hookline_dir=1, arrowhead=1 if arrow else 0, arrow_type=0, b1=0, b2=0, annot_h=0, dimstyle=dsh, **kw)


def _dimstyles(self):
    # DIMSTYLE objects have no codec yet: names come from the table's raw name field (read lazily)
    return self.table(68, 69) if False else self._dimstyle_map()


def _dimstyle_map(self):
    import dwgmodel
    c = self.get(self.control(68))
    out = {}
    for h in c['entries']:
        out[dwgmodel.table_entry_name(self.objs[h]).lower()] = h
    return out


def _add_dim(self, otype, block, layer, dimstyle, **fields):
    dsh = self.dimstyles()[dimstyle.lower()]
    return self.add_entity(otype, block, layer, dimstyle=dsh, dimblock=0, **fields)


def _dim_with_block(self, otype, block, layer, dimstyle, **f):
    import dwgdim
    probe = dict(type=otype, **f)
    probe.setdefault('dim_rot', 0.0)
    ents = dwgdim.build_linear_block(self, probe, dimstyle)
    f['text_mid'] = probe['text_mid']
    bh = dwgdim.make_block(self, ents, layer)
    h = self._add_dim(otype, block, layer, dimstyle, **f)
    d = self.get(h); d['dimblock'] = bh; self.put(d)
    return h


def _radial_with_block(self, otype, block, layer, dimstyle, **f):
    import dwgdim
    probe = dict(type=otype, **f)
    ents = dwgdim.build_radial_block(self, probe, dimstyle)
    f['text_mid'] = probe['text_mid']
    bh = dwgdim.make_block(self, ents, layer)
    h = self._add_dim(otype, block, layer, dimstyle, **f)
    d = self.get(h); d['dimblock'] = bh; self.put(d)
    return h


def _add_dim_angular(self, vertex, p1, p2, arc_pt, text='', dimstyle='Standard', block='*Model_Space', layer='0', **kw):
    """3-point angular dimension between the legs vertex-p1 and vertex-p2 (counter-clockwise from p1 to p2); arc_pt locates the dimension arc"""
    import dwgdim
    f = dict(text_mid=(0.0, 0.0), user_text=text, measurement=0.0, pt10=_v3(arc_pt), pt13=_v3(p1), pt14=_v3(p2), pt15=_v3(vertex), dflags=10, **kw)
    probe = dict(type=23, **f)
    ents = dwgdim.build_angular_block(self, probe, dimstyle)
    f['text_mid'] = probe['text_mid']; f['measurement'] = probe['measurement']
    bh = dwgdim.make_block(self, ents, layer)
    h = self._add_dim(23, block, layer, dimstyle, **f)
    d = self.get(h); d['dimblock'] = bh; self.put(d)
    return h


def _add_dim_ordinate(self, origin, feature, leader_end, xtype=True, text='', dimstyle='Standard', block='*Model_Space', layer='0', **kw):
    """ordinate dimension: value = x (xtype) or y offset of `feature` from `origin`; the text sits at leader_end"""
    import dwgdim
    f = dict(text_mid=(0.0, 0.0), user_text=text, measurement=0.0, pt10=_v3(origin), pt13=_v3(feature), pt14=_v3(leader_end), oflags=64 if xtype else 0, dflags=6, **kw)
    probe = dict(type=20, **f)
    ents = dwgdim.build_ordinate_block(self, probe, dimstyle)
    f['text_mid'] = probe['text_mid']; f['measurement'] = probe['measurement']
    bh = dwgdim.make_block(self, ents, layer)
    h = self._add_dim(20, block, layer, dimstyle, **f)
    d = self.get(h); d['dimblock'] = bh; self.put(d)
    return h


def _add_dim_angular2(self, l1a, l1b, l2a, l2b, arc_pt, text='', dimstyle='Standard', block='*Model_Space', layer='0', **kw):
    """two-line angular dimension between line l1a-l1b and line l2a-l2b (angle measured counter-clockwise from line 1 to line 2); arc_pt locates the arc"""
    import dwgdim, math
    (x1, y1), (x2, y2), (x3, y3), (x4, y4) = [tuple(map(float, p[:2])) for p in (l1a, l1b, l2a, l2b)]
    den = (x1 - x2) * (y3 - y4) - (y1 - y2) * (x3 - x4)
    if abs(den) < 1e-12: raise ValueError('parallel lines')
    t = ((x1 - x3) * (y3 - y4) - (y1 - y3) * (x3 - x4)) / den
    v = (x1 + t * (x2 - x1), y1 + t * (y2 - y1))
    far = lambda a, b: b if math.dist(v, b) >= math.dist(v, a) else a
    e1, e2 = far((x1, y1), (x2, y2)), far((x3, y3), (x4, y4))
    f = dict(text_mid=(0.0, 0.0), user_text=text, measurement=0.0, pt10=(x4, y4, 0.0), pt13=(x1, y1, 0.0), pt14=(x2, y2, 0.0), pt15=(x3, y3, 0.0), pt16=tuple(map(float, arc_pt[:2])),
             dflags=10, **kw)
    probe = dict(type=23, user_text=text, measurement=0.0, pt10=_v3(arc_pt), pt13=_v3(e1), pt14=_v3(e2), pt15=_v3(v))
    ents = dwgdim.build_angular_block(self, probe, dimstyle)
    f['text_mid'] = probe['text_mid']; f['measurement'] = probe['measurement']
    bh = dwgdim.make_block(self, ents, layer)
    h = self._add_dim(24, block, layer, dimstyle, **f)
    dd = self.get(h); dd['dimblock'] = bh; self.put(dd)
    return h


def _add_dim_aligned(self, p1, p2, dimpt, text='', dimstyle='Standard', block='*Model_Space', layer='0', **kw):
    """aligned dimension: dimpt = a point on the dimension line"""
    p1, p2, dp = _v3(p1), _v3(p2), _v3(dimpt)
    L = math.dist(p1[:2], p2[:2])
    ux, uy = (p2[0] - p1[0]) / L, (p2[1] - p1[1]) / L
    nx, ny = -uy, ux
    off = (dp[0] - p1[0]) * nx + (dp[1] - p1[1]) * ny
    d10 = (p2[0] + nx * off, p2[1] + ny * off, 0.0)
    mid = ((p1[0] + p2[0]) / 2 + nx * off, (p1[1] + p2[1]) / 2 + ny * off)
    return self._dim_with_block(22, block, layer, dimstyle, text_mid=mid, user_text=text, measurement=L, pt13=p1, pt14=p2, pt10=d10, ext_rot=0.0, dflags=11, **kw)


def _add_dim_linear(self, p1, p2, dimpt, rot=0.0, text='', dimstyle='Standard', block='*Model_Space', layer='0', **kw):
    """linear (rotated) dimension; rot = angle of the dimension line in radians"""
    p1, p2, dp = _v3(p1), _v3(p2), _v3(dimpt)
    c, s_ = math.cos(rot), math.sin(rot)
    meas = abs((p2[0] - p1[0]) * c + (p2[1] - p1[1]) * s_)
    # dimension line passes through dimpt with direction rot; def point 10 is the projection of p2 onto it
    nx, ny = -s_, c
    off = (dp[0] - p2[0]) * nx + (dp[1] - p2[1]) * ny
    d10 = (p2[0] + nx * off, p2[1] + ny * off, 0.0)
    d13 = (p1[0] + nx * ((dp[0] - p1[0]) * nx + (dp[1] - p1[1]) * ny), p1[1] + ny * ((dp[0] - p1[0]) * nx + (dp[1] - p1[1]) * ny))
    mid = ((d10[0] + d13[0]) / 2, (d10[1] + d13[1]) / 2)
    return self._dim_with_block(21, block, layer, dimstyle, text_mid=mid, user_text=text, measurement=meas, pt13=p1, pt14=p2, pt10=d10, ext_rot=0.0, dim_rot=rot, dflags=11, **kw)


def _add_dim_radius(self, center, chord_pt, leader_len=0.0, text='', dimstyle='Standard', block='*Model_Space', layer='0', **kw):
    c, p = _v3(center), _v3(chord_pt)
    r = math.dist(c[:2], p[:2])
    return self._radial_with_block(25, block, layer, dimstyle, text_mid=(p[0], p[1]), user_text=text, measurement=r, pt10=c, pt15=p, leader_len=leader_len, dflags=10, **kw)


def _add_dim_diameter(self, p1, p2, leader_len=0.0, text='', dimstyle='Standard', block='*Model_Space', layer='0', **kw):
    a, b = _v3(p1), _v3(p2)
    return self._radial_with_block(26, block, layer, dimstyle, text_mid=((a[0] + b[0]) / 2, (a[1] + b[1]) / 2), user_text=text, measurement=math.dist(a[:2], b[:2]), pt10=b, pt15=a,
                                   leader_len=leader_len, dflags=10, **kw)


Doc.add_mtext = _add_mtext
Doc.add_spline = _add_spline
Doc.add_xline = _add_xline
Doc.add_ray = _add_ray
Doc.add_3dface = _add_3dface
Doc.add_polyline2d = _add_polyline2d
Doc.add_leader = _add_leader
Doc.dimstyles = _dimstyles
Doc._dimstyle_map = _dimstyle_map
Doc._add_dim = _add_dim
Doc._dim_with_block = _dim_with_block
Doc._radial_with_block = _radial_with_block
Doc.add_dim_angular = _add_dim_angular
Doc.add_dim_ordinate = _add_dim_ordinate
Doc.add_dim_angular2 = _add_dim_angular2
Doc.add_dim_aligned = _add_dim_aligned
Doc.add_dim_linear = _add_dim_linear
Doc.add_dim_radius = _add_dim_radius
Doc.add_dim_diameter = _add_dim_diameter


# ---------------------------------------------------------------- hatch
def _add_hatch(self, loops, pattern='SOLID', scale=1.0, angle=0.0, patfile=None, gradient=None, double=False, elevation=0.0, block='*Model_Space', layer='0', **kw):
    """HATCH. loops: list of boundaries (first = outer). A boundary is a list of points [(x, y[, bulge]), ...] (closed polyline path)
    or a list of edge tuples ('L', p1, p2) / ('A', centre, radius, a0, a1, ccw) / ('E', ...) / ('S', ...).
    gradient: (name, angle_rad, (r, g, b) first colour, (r, g, b) second colour or None for a tinted single colour)."""
    import dwgpat
    paths = []
    for i, lp in enumerate(loops):
        if lp and isinstance(lp[0], str) or (lp and isinstance(lp[0], tuple) and isinstance(lp[0][0], str)):
            paths.append(dict(flags=(1 if i == 0 else 0) | (0x10 if False else 0), segs=list(lp), nboundary=0))
        else:
            segs = [('P', (float(p[0]), float(p[1])), float(p[2]) if len(p) > 2 else 0.0) for p in lp]
            paths.append(dict(flags=2 | (1 if i == 0 else 0), closed=1, segs=segs, nboundary=0))
    solid = 1 if (pattern.upper() == 'SOLID' or gradient) else 0
    g = dict(is_gradient=0, reserved=0, angle=0.0, shift=0.0, single_color=0, tint=0.0, colors=[], name='')
    if gradient:
        name, gang, c1, c2 = gradient
        def rgb(c): return (0, 0xC2000000 | (c[0] << 16) | (c[1] << 8) | c[2], 0, None) if False else (0, 0xC2000000 | (c[0] << 16) | (c[1] << 8) | c[2], 0)
        g = dict(is_gradient=1, reserved=1, angle=float(gang), shift=0.0, single_color=0 if c2 else 1, tint=1.0 if c2 else 0.5,
                 colors=[(0.0, rgb(c1)), (1.0, rgb(c2 if c2 else (255, 255, 255)))], name=name)
    d = dict(gradient=g, elev=float(elevation), ext=UP, pattern_name='SOLID' if solid else pattern.upper(), solid=solid, assoc=0, paths=paths, style=0,
             pattern_type=1, seeds=[])
    if not solid:
        d['pattern_angle'] = float(angle); d['pattern_scale'] = float(scale); d['pattern_double'] = 1 if double else 0
        d['pattern_lines'] = dwgpat.expand(dwgpat.load(pattern, patfile), scale, float(angle))
    d.update(kw)
    return self.add_entity(78, block, layer, **d)


Doc.add_hatch = _add_hatch


# ---------------------------------------------------------------- editing API
def _entities(self, block='*Model_Space'):
    """handles of the entities of a block in order"""
    bh = block if isinstance(block, int) else self.block_handle(block)
    return [h for h in self.chain(bh)]


def _set_props(self, h, layer=None, color=None, lweight=None, ltype=None, ltscale=None, invisible=None, rgb=None, plotstyle=None):
    """common properties of any entity (also entities without a geometry codec). color: ACI index (256 ByLayer, 0 ByBlock);
    lweight: 1/100 mm, -1 ByLayer / -2 ByBlock / -3 default; ltype: name or None (unchanged); 'BYLAYER'/'BYBLOCK'/'CONTINUOUS' handled"""
    d = self.get(h)
    if layer is not None: d['layer'] = layer if isinstance(layer, int) else self.layer_handle(layer)
    if color is not None or rgb is not None:
        if rgb is not None:
            d['color'] = self._true_color(rgb)
        else:
            d['color'] = (int(color), None, None)
    if lweight is not None:
        d['lweight'] = {-1: 29, -2: 30, -3: 31}.get(lweight, LW_STORE[lweight] if lweight in LW_STORE else lweight)
    if ltype is not None:
        n = ltype.lower()
        if n == 'bylayer': d['ltflags'] = 0
        elif n == 'byblock': d['ltflags'] = 1
        elif n == 'continuous': d['ltflags'] = 2
        else:
            d['ltflags'] = 3; d['ltype'] = self.ltypes()[n]
    if ltscale is not None: d['ltscale'] = float(ltscale)
    if invisible is not None: d['invis'] = 1 if invisible else 0
    self.put(d)
    return h


ACI_BASIC = {1: (255, 0, 0), 2: (255, 255, 0), 3: (0, 255, 0), 4: (0, 255, 255), 5: (0, 0, 255), 6: (255, 0, 255), 7: (255, 255, 255), 8: (65, 65, 65), 9: (128, 128, 128)}


def nearest_aci(rgb):
    return min(ACI_BASIC, key=lambda k: sum((a - b) ** 2 for a, b in zip(ACI_BASIC[k], rgb)))


def _true_color(self, rgb):
    """entity colour tuple for a true colour: R2004+ index word 0x8000|nearest ACI + (0xC2 << 24 | rgb); R2000 has no true colour (nearest ACI)"""
    aci = nearest_aci(rgb)
    if self.ver == 'AC1015': return (aci, None, None)
    return (0x8000 | aci, 0xC2000000 | (rgb[0] << 16) | (rgb[1] << 8) | rgb[2], None)


def _transform(self, h, t):
    import dwgxform
    try: return dwgxform.apply(self, h, t)
    except IndexError as ex: raise NotImplementedError('object %X cannot be decoded for editing (%s)' % (h, ex))        # a read past the end of the object record: refuse, never half-edit


def _copy_entity(self, h, t=None, block=None):
    """duplicate entity h (optionally transformed, into another block); handles, owner lists and attributes are created. Returns the new handle."""
    import dwgxform
    d = self.get(h)
    if d['type'] == 7 and d['has_attribs']:
        raise NotImplementedError('copy of INSERT with attributes: use add_insert')
    nd = copy.deepcopy(d)
    nd['handle'] = 0; nd.pop('_h', None)
    if self.ver == 'AC1015':
        if nd.get('xdic'): nd['xdic'] = 0
    else:
        nd['xdic_missing'] = 1; nd.pop('xdic', None)          # the copy gets no extension dictionary of its own: sharing the original's one made AUDIT report 'Extension dictionary: not this object'
    nd['nreactors'] = 0; nd['reactors'] = []
    if d['type'] == 78 and d.get('assoc'):
        nd['assoc'] = 0                                      # the copy is not associative (as in AutoCAD's COPY of a hatch alone): the boundary objects keep pointing at the original only
        for p in nd['paths']: p['nboundary'] = 0; p['boundary'] = []
    src = self.owner_block(h)
    if block is not None:
        bh = block if isinstance(block, int) else self.block_handle(block)
        bname = self.get(bh)['name'].lower()
        nd['entmode'] = 2 if bname == '*model_space' else (1 if bname == '*paper_space' else 0)
        if nd['entmode'] == 0: nd['owner'] = bh
        else: nd.pop('owner', None)
    else:
        bh = src
    if d['type'] == 15:
        if 'vertices' not in d: raise NotImplementedError('copy of type 15 (polyline without a vertex list in this version)')
        nd['vertices'] = []
        verts = []
        for v in d['vertices']:
            vd = copy.deepcopy(self.get(v)); vd['handle'] = 0; vd.pop('_h', None); verts.append(vd)
        sq = copy.deepcopy(self.get(d['seqend'])); sq['handle'] = 0; sq.pop('_h', None)
    nh = self.create(nd)
    self._link(bh, nh)
    if d['type'] == 15:
        for vd in verts:
            vd['owner'] = nh; nd['vertices'].append(self.create(vd))
        sq['owner'] = nh; nd['seqend'] = self.create(sq)
        if self.ver == 'AC1015':
            vs = nd['vertices']; nd['first'] = vs[0]; nd['last'] = vs[-1]
            for i, v in enumerate(vs):
                e = self.get(v); e['xdic_missing'] = 0; e['prev'] = vs[i - 1] if i else 0; e['next'] = vs[i + 1] if i + 1 < len(vs) else 0; self.put(e)
        self.put(nd)
    if 20 <= d['type'] <= 26 and d.get('dimblock'):
        nd = self.get(nh); nd['dimblock'] = self._copy_block(d['dimblock']); self.put(nd)
    if t is not None:
        try:
            dwgxform.apply(self, nh, t)
        except NotImplementedError:
            self.erase(nh)                                  # do not leave an untransformed copy behind
            raise
    return nh


def _copy_block(self, bh):
    """copy of an anonymous block (e.g. a dimension block) with copies of its entities"""
    src = self.get(bh)
    if src['name'].startswith('*'): name = '*D'
    else:                                            # a second copy of the same block gets _copy2, _copy3 ... (block names are unique)
        name = src['name'] + '_copy'; n = 1
        while name.lower() in self.blocks(): n += 1; name = '%s_copy%d' % (src['name'], n)
    nb = self.add_block(name)
    for e in self.chain(bh):
        ed = copy.deepcopy(self.get(e)); ed['handle'] = 0; ed.pop('_h', None)
        ed['owner'] = nb
        h = self.create(ed); self._link(nb, h)
    d = self.get(nb); d['anonymous'] = src['anonymous']; self.put(d)
    return nb


def _owner_block(self, h):
    d = self.get(h)
    if d['entmode'] == 2: return self.model_space()
    if d['entmode'] == 1: return self.paper_space()
    return d['owner']


Doc.entities = _entities
Doc.set_props = _set_props
Doc._true_color = _true_color
Doc.transform = _transform
_erase_raw = Doc.erase


def _erase(self, h):
    try: return _erase_raw(self, h)
    except IndexError as ex: raise NotImplementedError('object %X cannot be decoded for editing (%s)' % (h, ex))


Doc.erase = _erase
_copy_entity_raw = _copy_entity


def _copy_entity(self, h, t=None, block=None):
    try: return _copy_entity_raw(self, h, t, block)
    except IndexError as ex: raise NotImplementedError('object %X cannot be decoded for editing (%s)' % (h, ex))


Doc.copy_entity = _copy_entity
Doc.owner_block = _owner_block
Doc._copy_block = _copy_block


# ---------------------------------------------------------------- dictionaries, layouts, viewports
def _root_dict(self):
    for h in self.by_type(42):
        d = self.get(h)
        if d['owner'] == 0 and any(i[0] == 'ACAD_LAYOUT' for i in d['items']): return h
    raise KeyError('root dictionary')


def _dict_get(self, dh, name):
    for n, h in self.get(dh)['items']:
        if n.lower() == name.lower(): return h
    return None


def _dict_set(self, dh, name, h):
    d = self.get(dh)
    d['items'] = [i for i in d['items'] if i[0].lower() != name.lower()] + [[name, h]]
    d['items'].sort(key=lambda i: i[0].lower())
    self.put(d)


def _layouts(self):
    """{name: LAYOUT handle}"""
    return {self.get(h)['name']: h for h in self.by_type(self._layout_type())}


def _layout_type(self):
    if self.ver != 'AC1015': return 82
    import dwgobj as O
    cl = O.parse_classes_r2000(O.load_r2000(self.buf)['classes'])
    return next(c['num'] for c in cl if c['dxf'] == 'LAYOUT')


def _add_layout(self, name, paper=(420.0, 297.0), margins=(7.5, 7.5, 7.5, 7.5), printer='DWG To PDF.pc3', media=None, style_sheet='', plot_type=5, rotation=0, like='Layout1'):
    """new paper space layout (LAYOUT + paper space block record); returns the LAYOUT handle. paper in mm (landscape: width > height)."""
    if name.lower() in {n.lower() for n in self.layouts()}: raise ValueError('layout exists: ' + name)
    key = 82 if self.ver != 'AC1015' else self._layout_type()
    tmpl = self.get(self.layouts()[like])
    npaper = len([n for n in self.blocks() if n.startswith('*paper_space')])
    bname = '*Paper_Space' if npaper == 0 else '*Paper_Space%d' % (npaper - 1)
    lh = self.new_handle()
    bh = self._new_block_record(bname, layout=lh)
    ld = copy.deepcopy(tmpl)
    ld.pop('_h', None)
    ld.update(handle=lh, name=name, tab_order=max(self.get(h)['tab_order'] for h in self.layouts().values()) + 1, block=bh, last_viewport=0, viewports=[], nviewports=0,
              printer=printer, paper=(float(paper[0]), float(paper[1])), margins=tuple(map(float, margins)), plot_type=plot_type, rotation=rotation,
              style_sheet=style_sheet, paper_size=media or 'ISO_A3_(%.2f_x_%.2f_MM)' % paper, paper_units=1, scale_type=16, scale_factor=1.0,
              owner=self._dict_get(self.root_dict(), 'ACAD_LAYOUT'), eed=[])
    ld['reactors'] = [ld['owner']]; ld['nreactors'] = 1
    ld['xdic'] = 0
    ld['key'] = tmpl.get('key', key)
    self.create(ld)
    self._dict_set(ld['owner'], name, lh)
    bd = self.get(bh); bd['layout'] = lh; self.put(bd)
    return lh


def _new_block_record(self, name, layout=0):
    """BLOCK_HEADER + BLOCK + ENDBLK with an arbitrary name (used for blocks and paper space records)"""
    bh = self.add_block(name)
    bd = self.get(bh); bd['layout'] = layout; self.put(bd)
    return bh


def _add_viewport(self, layout, center, size, view_center=(0.0, 0.0), scale=None, view_height=None, twist=0.0, frozen=(), layer='0', on=True, paper_viewport=False, **kw):
    """VIEWPORT in a paper space layout. center/size in paper units; scale = paper units per model unit (e.g. 1/50); the first viewport of a layout
    should be the overall paper viewport (paper_viewport=True)"""
    lh = layout if isinstance(layout, int) else self.layouts()[layout]
    ld = self.get(lh)
    bh = ld['block']
    if view_height is None:
        view_height = size[1] / scale if scale else size[1]
    status = 0xC8020 if paper_viewport else 0xC8060
    if not on: status &= ~0x20000 if False else status
    fz = [self.layer_handle(n) if not isinstance(n, int) else n for n in frozen]
    vs = self._default_visual_style()
    tail = [0, 0, 0, 0, vs, 0, 0] if self.ver in C.WIDE else ([0, 0, 0, 0] if self.ver == 'AC1015' else [0, 0, 0])
    d = dict(center=(float(center[0]), float(center[1]), 0.0), width=float(size[0]), height=float(size[1]), view_target=(0.0, 0.0, 0.0), view_dir=(0.0, 0.0, 1.0), twist=twist,
             view_height=float(view_height), lens=50.0, front_clip=0.0, back_clip=0.0, snap_angle=0.0, view_center=(float(view_center[0]), float(view_center[1])),
             snap_base=(0.0, 0.0), snap_spacing=(0.5, 0.5), grid_spacing=(0.5, 0.5), circle_zoom=1000, nfrozen=len(fz), frozen=fz, status=status, stylesheet='',
             render_mode=0, ucs_at_origin=0, ucs_per_vp=1, ucs_origin=(0.0, 0.0, 0.0), ucs_x=(1.0, 0.0, 0.0), ucs_y=(0.0, 1.0, 0.0), ucs_elev=0.0, ucs_ortho=0, tail_h=tail)
    if self.ver != 'AC1015': d['shade_plot'] = 0
    if self.ver in C.WIDE:
        d.update(grid_major=5, default_lights=1, lighting_type=1, brightness=0.0, contrast=0.0, ambient=(0, 3258135347, 0))
    d.update(kw)
    h = self.add_entity(34, bh, layer, **d)
    ld = self.get(lh)
    ld['viewports'].append(h); ld['nviewports'] = len(ld['viewports'])
    if not ld['last_viewport']: ld['last_viewport'] = h
    self.put(ld)
    return h


def _default_visual_style(self):
    if self.ver not in C.WIDE: return 0
    try:
        vd = self._dict_get(self.root_dict(), 'ACAD_VISUALSTYLE')
        return self._dict_get(vd, '2dWireframe') or 0
    except Exception:
        return 0


Doc.root_dict = _root_dict
Doc._dict_get = _dict_get
Doc._dict_set = _dict_set
Doc.layouts = _layouts
Doc._layout_type = _layout_type
Doc.add_layout = _add_layout
Doc._new_block_record = _new_block_record
Doc.add_viewport = _add_viewport
Doc._default_visual_style = _default_visual_style


# ---------------------------------------------------------------- styles, linetypes, appids, xdata
def _add_style(self, name, font='txt', bigfont='', height=0.0, width=1.0, oblique=0.0, like='Standard', shapefile=False):
    if name.lower() in self.styles(): raise ValueError('style exists: ' + name)
    d = copy.deepcopy(self.get(self.styles()[like.lower()]))
    d.update(handle=0, name=name, font=font, bigfont=bigfont, fixed_height=float(height), width_factor=float(width), oblique=float(oblique), owner=self.control(52),
             xdic_missing=1, reactors=[], nreactors=0, eed=[], last_height=float(height) or 0.2, shapefile=1 if shapefile else 0)
    d.pop('_h', None); d.pop('xdic', None)
    if self.ver == 'AC1015': d['xdic'] = 0
    return self._add_entry(52, d)


def _add_ltype(self, name, description='', dashes=(), like='Continuous'):
    """dashes: lengths (positive = dash, negative = gap, 0 = dot); a dash may also be a dict
    {'length': -2.5, 'text': 'GAS', 'style': 'Standard', 'scale': 1.0, 'rotation': 0.0, 'x': -1.0, 'y': -0.5, 'absolute': False}
    for an embedded text (complex linetype). Returns the LTYPE handle."""
    if name.lower() in self.ltypes(): raise ValueError('linetype exists: ' + name)
    d = copy.deepcopy(self.get(self.ltypes()[like.lower()]))
    items = []; area = bytearray()
    wide = self.ver in C.WIDE
    for x in dashes:
        if isinstance(x, dict) and 'shape' in x:
            # shape dash (flags 4): 'shape' = shape number in the SHX of the shape-file style 'style' (needs an existing shape-file STYLE, e.g. LTYPESHP.SHX). Not yet AutoCAD-verified.
            items.append(dict(length=float(x['length']), shape=int(x['shape']), offset=(float(x.get('x', 0.0)), float(x.get('y', 0.0))), scale=float(x.get('scale', 1.0)),
                              rotation=float(x.get('rotation', 0.0)), flags=4 | (1 if x.get('absolute') else 0), style=self.styles()[x['style'].lower()]))
        elif isinstance(x, dict):
            t = x['text'].encode('utf-16le') + b'\0\0' if wide else x['text'].encode('cp1252', 'replace') + b'\0'
            items.append(dict(length=float(x['length']), shape=len(area), offset=(float(x.get('x', 0.0)), float(x.get('y', 0.0))), scale=float(x.get('scale', 1.0)),
                              rotation=float(x.get('rotation', 0.0)), flags=2 | (1 if x.get('absolute') else 0), style=self.styles()[x.get('style', 'Standard').lower()]))
            area += t
        else:
            items.append(dict(length=float(x), shape=0, offset=(0.0, 0.0), scale=1.0, rotation=0.0, flags=0))
    need = 256 if self.ver in ('AC1015', 'AC1018') else 512
    d.update(handle=0, name=name, description=description, pattern_length=float(sum(abs(i['length']) for i in items)), alignment=65, owner=self.control(56),
             xdic_missing=1, reactors=[], nreactors=0, eed=[], dashes=items)
    if area or self.ver in ('AC1015', 'AC1018'):
        if len(area) > need: raise ValueError('linetype text too long')
        d['text_area'] = bytes(area).ljust(need, b'\0')
    d.pop('_h', None); d.pop('xdic', None)
    if self.ver == 'AC1015': d['xdic'] = 0
    h = self.create(d)
    c = self.get(self.control(56)); c['entries'].append(h); self.put(c)
    return h


def _add_appid(self, name):
    if name.lower() in self.appids(): return self.appids()[name.lower()]
    d = copy.deepcopy(self.get(next(iter(self.appids().values()))))
    d.update(handle=0, name=name, owner=self.control(66), xdic_missing=1, reactors=[], nreactors=0, eed=[])
    d.pop('_h', None); d.pop('xdic', None)
    if self.ver == 'AC1015': d['xdic'] = 0
    return self._add_entry(66, d)


def _eed_bytes(self, items):
    import struct
    out = bytearray()
    wide = self.ver in C.WIDE
    for code, v in items:
        if code in (1000, 1001, 1003):
            out.append(code - 1000)
            if wide:
                out += struct.pack('<H', len(v.encode('utf-16le')) // 2) + v.encode('utf-16le')       # length in UTF-16 code units
            else:
                b = v.encode('cp1252', 'replace')
                out += struct.pack('<H', len(b)) + bytes([30]) + b
        elif code == 1002: out += bytes([2, 1 if v == '}' else 0])
        elif code == 1004:
            out.append(4); out += struct.pack('<B', len(v)) + v
        elif code == 1005: out.append(5); out += struct.pack('>Q', v)
        elif code in (1010, 1011, 1012, 1013): out.append(code - 1000); out += struct.pack('<3d', *v)
        elif code in (1040, 1041, 1042): out.append(code - 1000); out += struct.pack('<d', v)
        elif code == 1070: out.append(70); out += struct.pack('<h', v)
        elif code == 1071: out.append(71); out += struct.pack('<i', v)
        else: raise ValueError('xdata code %r' % code)
    return bytes(out)


def _add_xdata(self, h, appname, items):
    """attach xdata to any object; items: [(1000, 'text'), (1070, 3), (1040, 2.5), (1010, (x, y, z)), (1071, 100000), (1002, '{')...] (registers the APPID)"""
    ah = self.add_appid(appname)
    d = self.get(h)
    d['eed'] = list(d.get('eed', [])) + [((5, ah), self._eed_bytes(items))]
    self.put(d)


def _insert_attribs(self, ins):
    """handles of the ATTRIBs of an INSERT (explicit list in R2004+, first..last chain through `next` in R2000)"""
    if ins.get('attribs'): return list(ins['attribs'])
    out = []; h = ins.get('first_attrib') or 0; guard = 0
    while h and guard < 10000:
        out.append(h)
        if h == ins.get('last_attrib'): break
        h = self.get(h).get('next') or 0; guard += 1
    return out


Doc._insert_attribs = _insert_attribs


def _replace_text(self, old, new, types=(1, 2, 3, 44)):
    """replace substring old by new in the string of every TEXT (1), ATTRIB (2), ATTDEF (3) and MTEXT (44) in all blocks and layouts; returns the number of objects changed"""
    n = 0
    for bn, bh in self.blocks().items():
        if bn.startswith('*d') or bn.startswith('*u'): continue
        hs = []
        for h in self.chain(bh):
            hs.append(h)
            if self.otype(h) == 7 and 2 in types: hs += self._insert_attribs(self.get(h))
        for h in hs:
            if self.otype(h) not in types: continue
            d = self.get(h)
            t = d.get('text')
            if isinstance(t, str) and old in t:
                d['text'] = t.replace(old, new); self.put(d); n += 1
    return n


Doc.replace_text = _replace_text
Doc.add_style = _add_style
Doc.add_ltype = _add_ltype
Doc.add_appid = _add_appid
Doc._eed_bytes = _eed_bytes
Doc.add_xdata = _add_xdata


def _dimstyles2(self):
    return self.table(68, 69)


def _add_dimstyle(self, name, like='Standard', **vars):
    """new dimension style cloned from `like`; vars are DIM variables by name (DIMSCALE=50, DIMTXT=2.5, DIMASZ=2.5, DIMCLRD=..., DIMDEC=2 ...)"""
    if name.lower() in self.dimstyles(): raise ValueError('dimstyle exists: ' + name)
    d = copy.deepcopy(self.get(self.dimstyles()[like.lower()]))
    d.update(handle=0, name=name, owner=self.control(68), xdic_missing=1, reactors=[], nreactors=0, eed=[])
    d.pop('_h', None); d.pop('xdic', None)
    if self.ver == 'AC1015': d['xdic'] = 0
    for k, v in vars.items():
        k = k.upper()
        if k not in d: raise KeyError('unknown dimension variable ' + k)
        d[k] = v
    return self._add_entry(68, d)


Doc.dimstyles = _dimstyles2
Doc.add_dimstyle = _add_dimstyle


# ---------------------------------------------------------------- rename / purge
def _rename_block(self, old, new):
    if new.lower() in self.blocks(): raise ValueError('block exists: ' + new)
    bh = self.block_handle(old)
    bd = self.get(bh); bd['name'] = new; self.put(bd)
    b = self.get(bd['block']); b['name'] = new; self.put(b)
    return bh


def _delete_layer(self, name, force=False):
    """remove an unused layer (entities on it block the removal unless force=True, which moves them to layer 0)"""
    lh = self.layer_handle(name)
    if name == '0' or name.lower() == 'defpoints': raise ValueError('cannot delete layer ' + name)
    users = []
    for bn, bh in self.blocks().items():
        for h in self.chain(bh):
            if self.get(h)['layer'] == lh: users.append(h)
    if users and not force: raise ValueError('layer %s is used by %d entities' % (name, len(users)))
    zero = self.layer_handle('0')
    for h in users: self.set_props(h, layer=zero)
    c = self.get(self.control(50)); c['entries'].remove(lh); self.put(c)
    self.delete(lh)


Doc.rename_block = _rename_block
Doc.delete_layer = _delete_layer


# ---------------------------------------------------------------- XRECORD
def _xr_kind(code):
    if 0 <= code <= 9 or 100 <= code <= 102 or 300 <= code <= 309 or 410 <= code <= 419 or 430 <= code <= 439 or 470 <= code <= 479: return 'str'
    if 10 <= code <= 39 or 210 <= code <= 239: return 'pt'
    if 40 <= code <= 59 or 140 <= code <= 149 or 460 <= code <= 469: return 'dbl'
    if 60 <= code <= 79 or 170 <= code <= 179 or 270 <= code <= 289 or 370 <= code <= 389 or 400 <= code <= 409: return 'short'
    if 90 <= code <= 99 or 420 <= code <= 429 or 440 <= code <= 449: return 'long'
    if 290 <= code <= 299: return 'byte'
    if 310 <= code <= 319: return 'bin'
    if 320 <= code <= 329: return 'handle'
    raise ValueError('xrecord group code %d' % code)


def _xr_pack(self, items):
    import struct
    out = bytearray()
    for code, v in items:
        out += struct.pack('<H', code)
        k = _xr_kind(code)
        if k == 'str':
            if self.ver in C.WIDE: out += struct.pack('<H', len(v.encode('utf-16le')) // 2) + v.encode('utf-16le')       # length in UTF-16 code units
            else:
                b = v.encode('cp1252', 'replace'); out += struct.pack('<H', len(b)) + bytes([30]) + b
        elif k == 'pt': out += struct.pack('<3d', *v)
        elif k == 'dbl': out += struct.pack('<d', v)
        elif k == 'short': out += struct.pack('<h', v)
        elif k == 'long': out += struct.pack('<i', v)
        elif k == 'byte': out += struct.pack('<B', 1 if v else 0)
        elif k == 'bin': out += struct.pack('<B', len(v)) + v
        elif k == 'handle': out += struct.pack('<Q', v)
    return bytes(out)


def _xr_unpack(self, data):
    import struct
    i = 0; out = []
    while i < len(data):
        code, = struct.unpack_from('<H', data, i); i += 2
        k = _xr_kind(code)
        if k == 'str':
            n, = struct.unpack_from('<H', data, i); i += 2
            if self.ver in C.WIDE: v = data[i:i + 2 * n].decode('utf-16le'); i += 2 * n
            else: v = data[i + 1:i + 1 + n].decode('cp1252', 'replace'); i += 1 + n
        elif k == 'pt': v = struct.unpack_from('<3d', data, i); i += 24
        elif k == 'dbl': v, = struct.unpack_from('<d', data, i); i += 8
        elif k == 'short': v, = struct.unpack_from('<h', data, i); i += 2
        elif k == 'long': v, = struct.unpack_from('<i', data, i); i += 4
        elif k == 'byte': v = data[i]; i += 1
        elif k == 'bin': n = data[i]; v = data[i + 1:i + 1 + n]; i += 1 + n
        else: v, = struct.unpack_from('<Q', data, i); i += 8
        out.append((code, v))
    return out


def _add_xrecord(self, dict_handle, key, items):
    """XRECORD with group-code items [(1, 'text'), (70, 7), (40, 2.5), (10, (x, y, z)), (90, 123456), (290, 1)] stored under `key` in a dictionary
    (dict_handle: handle of a DICTIONARY, or None for the root dictionary)"""
    dh = dict_handle or self.root_dict()
    d = dict(type=79, handle=0, eed=[], nreactors=1, reactors=[dh], xdic_missing=1, owner=dh, data=self._xr_pack(items), cloning=1, hrefs=[])
    if self.ver == 'AC1015': d['xdic'] = 0
    h = self.create(d)
    self._dict_set(dh, key, h)
    return h


def _read_xrecord(self, h):
    return self._xr_unpack(self.get(h)['data'])


Doc._xr_pack = _xr_pack
Doc._xr_unpack = _xr_unpack
Doc.add_xrecord = _add_xrecord
Doc.read_xrecord = _read_xrecord


# DXF lineweight value (1/100 mm) -> 5-bit code stored in the layer flags (bits 5..9); -3 default, -2 byblock, -1 bylayer
LW_VALUES = [0, 5, 9, 13, 15, 18, 20, 25, 30, 35, 40, 50, 53, 60, 70, 80, 90, 100, 106, 120, 140, 158, 200, 211]
LW_CODE = {v: i for i, v in enumerate(LW_VALUES)}
LW_CODE.update({-1: 29, -2: 30, -3: 31})
LW_STORE = {v: i for i, v in enumerate(LW_VALUES)}   # entity lweight byte: index into the lineweight table (0..23), 29 ByLayer, 30 ByBlock, 31 default


# ---------------------------------------------------------------- save
def _doc_save(self):
    if self.ver == 'AC1021':
        raise NotImplementedError('AC1021 (R2007) is read-only: no container writer yet')
    raws = []
    for h in self.order + self.new_order:
        if h in self.deleted: continue
        if h in self.dirty:
            raws.append((h, C.encode(self.ver, self.dec[h], self.codepage)))
        else:
            raws.append((h, self.objs[h].raw))
    mx = max(h for h, _ in raws)
    if self.ver == 'AC1015':
        import dwgobj as O
        d = O.load_r2000(self.buf)
        e = dwgedit.Editor.__new__(dwgedit.Editor)
        e.buf = self.buf; e.max_handle = mx; e.new = {}
        hdr = dwgedit.Editor._header_r2000(e, d)
        return dwgwrite.rewrite_r2000(self.buf, raws, hdr, dwgedit.handles_section)
    od, nm = dwgedit.objects_section(raws)
    plain = {'AcDb:AcDbObjects': od, 'AcDb:Handles': dwgedit.handles_section(nm)}
    hd = _header_seed(self, mx)
    if hd is not None: plain['AcDb:Header'] = hd
    return dwgwrite.rewrite_r2004(self.buf, plain)


def _header_seed(self, mx):
    """AcDb:Header with HANDSEED moved above the largest handle (stored as a code-0 handle a little above the old maximum handle)"""
    info = F.r2004_open(self.buf)
    hd = bytearray(F.r2004_section_data(self.buf, info, 'AcDb:Header'))
    crcpos = F.header_crcpos(hd, self.ver)
    if crcpos is None: raise NotImplementedError('AcDb:Header CRC not found (unknown header layout)')
    old_mx = max(self.objs)
    r0 = dwgedit.find_seed(hd, old_mx, self.objs, follow=self.ver == 'AC1018', ver=self.ver)
    if r0 is None: return None
    new_seed = mx + (r0[2] - old_mx)
    w = W.BitWriter(); w.H(0, new_seed)
    if len(w) != r0[1] - r0[0]:
        # the handle grew by a byte: shift the following header bits by re-writing them
        bits = []
        for i in range(len(hd) * 8): bits.append((hd[i >> 3] >> (7 - (i & 7))) & 1)
        raise NotImplementedError('HANDSEED byte length changed')
    for i, bit in enumerate(w.bits):
        pos = r0[0] + i
        if bit: hd[pos >> 3] |= 0x80 >> (pos & 7)
        else: hd[pos >> 3] &= ~(0x80 >> (pos & 7)) & 0xFF
    struct.pack_into('<H', hd, crcpos, F.crc16(bytes(hd[16:crcpos]), 0xC0C1))
    return bytes(hd)


Doc.save = _doc_save

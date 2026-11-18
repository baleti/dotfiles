"""Thumbnail of an rvt-ballet converted model (model.glb): numpy + PIL only, no GPU, no browser.
3D families: isometric view from front-right-above, z-buffered flat shading + dark feature/outline edges (Revit-preview-like).
2D families (lines only: annotation symbols, title blocks, profiles, trusses drawn as lines): the lines seen square-on to
their best-fit plane, black on white.
usage: glbthumb.py model.glb out.png [size]   (exit 2 = nothing drawable)"""
import colorsys, json, os, struct, sys
import numpy as np
from PIL import Image, ImageDraw

CT = {5120: np.int8, 5121: np.uint8, 5122: np.int16, 5123: np.uint16, 5125: np.uint32, 5126: np.float32}
NC = {'SCALAR': 1, 'VEC2': 2, 'VEC3': 3, 'VEC4': 4}

# not model content: view cameras, datums, work planes, sketch/profile curves (rvt-ballet batch = glb mesh names)
SKIP3D = {'Cameras', 'Reference Planes', 'Reference Lines', 'Work Plane Grid', 'Levels', 'Grids', '<Sketch>', 'Section Boxes',
          'Scope Boxes', 'Dimensions', 'Constraints', 'Center line', 'Sun Path', 'Viewports'}
SKIP3D |= {'Detail Items', 'Filled region', 'Masking Region'}      # plan-only filled regions / detail components
SKIP2D = SKIP3D - {'Detail Items', 'Filled region', 'Masking Region'}
PLACEHOLDER = {'bbox', 'void', 'none'}          # rvt-ballet fidelity tags that are not real geometry (stand-in boxes, opening cut volumes)
HOST_CATS = {'Walls', 'Floors', 'Ceilings', 'Roofs'}   # host element of a hosted-family template (door/window in its test wall)


def load(path):
    """-> tris [(name, Tx3x3 metres Y-up, rgba, keep-mask)], lines [(name, Sx2x3)].  With meta.json next to the glb
    (same batch order as the glb meshes), triangles of placeholder elements (fidelity bbox/void) are masked out."""
    meta = None
    mp = os.path.join(os.path.dirname(path), 'meta.json')
    if os.path.exists(mp):
        try: meta = json.load(open(mp))
        except Exception: meta = None
    d = open(path, 'rb').read()
    if d[:4] != b'glTF': raise ValueError('not a glb')
    jl = struct.unpack('<I', d[12:16])[0]
    g = json.loads(d[20:20 + jl]); o = 20 + jl
    binc = d[o + 8:o + 8 + struct.unpack('<I', d[o:o + 4])[0]] if o + 8 <= len(d) else b''

    def acc(i):
        a = g['accessors'][i]; bv = g['bufferViews'][a['bufferView']]
        n = NC[a['type']]; dt = np.dtype(CT[a['componentType']]); w = n * dt.itemsize
        start = bv.get('byteOffset', 0) + a.get('byteOffset', 0); stride = bv.get('byteStride', 0) or w
        if a['count'] == 0: return np.zeros((0, n) if n > 1 else 0, dt)
        raw = np.frombuffer(binc, np.uint8, count=stride * (a['count'] - 1) + w, offset=start)
        if stride != w:
            raw = np.lib.stride_tricks.as_strided(raw, (a['count'], w), (stride, 1)).copy()
        out = raw.view(dt)
        return out.reshape(-1, n) if n > 1 else out

    tris, lines = [], []
    batches = meta['batches'] if meta and len(meta.get('batches', [])) == len(g['meshes']) else None
    if batches and any(b['cat'] != (m.get('name') or '').replace(' (lines)', '') for b, m in zip(batches, g['meshes'])): batches = None

    def real_mask(mi, n):
        k = np.ones(n, bool)
        if not batches: return k
        r = batches[mi].get('ranges') or []; E = meta['elements']
        for i in range(0, len(r) - 2, 3):
            if E[r[i]][6] in PLACEHOLDER: k[r[i + 1]:r[i + 1] + r[i + 2]] = False
        return k

    def walk(ni, M):
        nd = g['nodes'][ni]
        if 'matrix' in nd: L = np.array(nd['matrix'], float).reshape(4, 4).T
        else:
            T = np.eye(4); T[:3, 3] = nd.get('translation', [0, 0, 0])
            x, y, z, w = nd.get('rotation', [0, 0, 0, 1])
            R = np.eye(4); R[:3, :3] = [[1-2*(y*y+z*z), 2*(x*y-z*w), 2*(x*z+y*w)], [2*(x*y+z*w), 1-2*(x*x+z*z), 2*(y*z-x*w)], [2*(x*z-y*w), 2*(y*z+x*w), 1-2*(x*x+y*y)]]
            L = T @ R @ np.diag(list(nd.get('scale', [1, 1, 1])) + [1])
        W = M @ L
        if 'mesh' in nd:
            me = g['meshes'][nd['mesh']]; name = me.get('name') or nd.get('name') or ''
            for p in me['primitives']:
                v = acc(p['attributes']['POSITION']).astype(np.float64)
                if not len(v): continue
                v = (np.c_[v, np.ones(len(v))] @ W.T)[:, :3]
                idx = acc(p['indices']).astype(np.int64) if 'indices' in p else np.arange(len(v))
                mode = p.get('mode', 4)
                if mode == 4:
                    col = [0.8, 0.8, 0.8, 1.0]
                    if 'material' in p:
                        col = g['materials'][p['material']].get('pbrMetallicRoughness', {}).get('baseColorFactor', col)
                    tt = v[idx[:len(idx) // 3 * 3].reshape(-1, 3)]
                    tris.append((name, tt, np.array(col, float), real_mask(nd['mesh'], len(tt))))
                elif mode == 1:
                    lines.append((name, v[idx[:len(idx) // 2 * 2].reshape(-1, 2)]))
                elif mode == 3:
                    lines.append((name, np.stack([v[idx[:-1]], v[idx[1:]]], 1)))
        for c in nd.get('children', []): walk(c, W)

    for r in g['scenes'][g.get('scene', 0)]['nodes']: walk(r, np.eye(4))
    return tris, lines


def base(name):
    return name[:-len(' (lines)')] if name.endswith(' (lines)') else name


def srgb(c):
    c = np.clip(c, 0, 1)
    return np.where(c <= 0.0031308, 12.92 * c, 1.055 * c ** (1 / 2.4) - 0.055)


def view_basis():
    """glTF Y-up; Revit's default 3D view looks from the south-east, above: eye at +X (east), -Y_revit (south) = +Z_gltf"""
    eye = np.array([1.0, 0.82, 1.0]); fwd = -eye / np.linalg.norm(eye)
    right = np.cross(fwd, [0, 1, 0]); right /= np.linalg.norm(right); up = np.cross(right, fwd)
    return right, up, fwd


def fit(P2, S, pad=0.07):
    lo, hi = P2.min(0), P2.max(0); span = max(hi[0] - lo[0], hi[1] - lo[1]) or 1.0
    k = S * (1 - 2 * pad) / span; c = (lo + hi) / 2
    return lambda q: np.stack([(q[..., 0] - c[0]) * k + S / 2, S / 2 - (q[..., 1] - c[1]) * k], -1)


def raster(X, Z, S):
    """z-buffer: X Tx3x2 pixel coords, Z Tx3 depth (larger = nearer) -> (zbuf, triangle index buffer)"""
    zb = np.full((S, S), -np.inf); ib = np.full((S, S), -1, np.int64)
    x0 = np.clip(np.floor(X[..., 0].min(1)).astype(int), 0, S - 1); x1 = np.clip(np.ceil(X[..., 0].max(1)).astype(int), 0, S - 1)
    y0 = np.clip(np.floor(X[..., 1].min(1)).astype(int), 0, S - 1); y1 = np.clip(np.ceil(X[..., 1].max(1)).astype(int), 0, S - 1)
    a, b, c = X[:, 0], X[:, 1], X[:, 2]
    den = (b[:, 1] - c[:, 1]) * (a[:, 0] - c[:, 0]) + (c[:, 0] - b[:, 0]) * (a[:, 1] - c[:, 1])
    for i in np.flatnonzero(np.abs(den) > 1e-12):
        xs = np.arange(x0[i], x1[i] + 1) + 0.5; ys = np.arange(y0[i], y1[i] + 1) + 0.5
        px, py = np.meshgrid(xs, ys)
        l1 = ((b[i, 1] - c[i, 1]) * (px - c[i, 0]) + (c[i, 0] - b[i, 0]) * (py - c[i, 1])) / den[i]
        l2 = ((c[i, 1] - a[i, 1]) * (px - c[i, 0]) + (a[i, 0] - c[i, 0]) * (py - c[i, 1])) / den[i]
        l3 = 1 - l1 - l2
        m = (l1 >= -1e-6) & (l2 >= -1e-6) & (l3 >= -1e-6)
        if not m.any(): continue
        z = l1 * Z[i, 0] + l2 * Z[i, 1] + l3 * Z[i, 2]
        sl = (slice(y0[i], y1[i] + 1), slice(x0[i], x1[i] + 1))
        win = m & (z > zb[sl])
        zb[sl][win] = z[win]; ib[sl][win] = i
    return zb, ib


def feature_edges(T, angle=30):
    """edges between faces bent more than `angle` degrees, plus open (boundary) edges -> Ex2x3"""
    V = T.reshape(-1, 3); q = np.round(V / (np.abs(V).max() + 1e-12) * 1e6).astype(np.int64)
    _, vid = np.unique(q, axis=0, return_inverse=True); F = vid.reshape(-1, 3)
    n = np.cross(T[:, 1] - T[:, 0], T[:, 2] - T[:, 0]); ln = np.linalg.norm(n, axis=1); good = ln > 0
    n[good] /= ln[good, None]
    e = np.concatenate([F[:, [0, 1]], F[:, [1, 2]], F[:, [2, 0]]]); fi = np.tile(np.arange(len(F)), 3)
    ek = np.sort(e, 1); key = ek[:, 0] * (vid.max() + 1) + ek[:, 1]
    order = np.argsort(key, kind='stable'); key, fi, ek = key[order], fi[order], ek[order]
    starts = np.r_[0, np.flatnonzero(np.diff(key)) + 1]; counts = np.diff(np.r_[starts, len(key)])
    keep = []
    cos = np.cos(np.radians(angle))
    for s, c in zip(starts, counts):
        if c == 1: keep.append(s); continue
        fs = fi[s:s + c]; nn = n[fs]
        if (np.abs(nn[1:] @ nn[0]) < cos).any(): keep.append(s)       # abs: two-sided (flipped windings are common)
    pts = np.zeros((len(V), 3)); pts[vid] = V
    k = np.array(keep, int)
    return pts[ek[k]] if len(k) else np.zeros((0, 2, 3))


def lin2srgb1(c):
    return float(srgb(np.array(c)))


def neutral(c):
    """rvt-ballet's made-up category colour (cat_color: hashed hue at HLS lightness 0.62, saturation 0.35) -> Revit's no-material grey"""
    rgb = [lin2srgb1(x) for x in c[:3]]
    h, l, s = colorsys.rgb_to_hls(*rgb)
    if abs(l - 0.62) < 0.012 and abs(s - 0.35) < 0.02:
        return np.array([0.62, 0.62, 0.62, c[3]])                    # linear ~= sRGB 0.80
    return c


def render3d(tris, size, ss=3):
    parts = [(n, t[k], neutral(c)) for n, t, c, k in tris if base(n) not in SKIP3D and c[3] > 0.05 and k.any()]
    if len({base(n) for n, _, _ in parts} - HOST_CATS):              # something besides the host wall: hide the host (door shown as a door)
        hv = sum(len(t) for n, t, _ in parts if base(n) not in HOST_CATS)
        if hv >= 12: parts = [p for p in parts if base(p[0]) not in HOST_CATS]
    if not parts: return None
    T = np.concatenate([t for _, t, _ in parts])
    C = np.concatenate([np.repeat(c[None, :3], len(t), 0) for _, t, c in parts])
    right, up, fwd = view_basis()
    P = T @ np.c_[right, up, -fwd]                                    # x right, y up, z towards the eye
    S = size * ss; tf = fit(P[..., :2].reshape(-1, 2), S)
    X = tf(P[..., :2]); Z = P[..., 2]
    zb, ib = raster(X, Z, S)
    n = np.cross(T[:, 1] - T[:, 0], T[:, 2] - T[:, 0]); ln = np.linalg.norm(n, axis=1); n[ln > 0] /= ln[ln > 0, None]
    n *= np.where(n @ fwd > 0, -1.0, 1.0)[:, None]                    # two-sided
    L1 = np.array([0.35, 0.85, 0.55]); L1 /= np.linalg.norm(L1)
    shade = 0.55 + 0.45 * np.clip(n @ L1, 0, 1)
    base_col = 0.30 + 0.70 * np.clip(C, 0, 1)                         # keep dark materials (steel, black panels) readable
    rgb = (srgb(base_col * shade[:, None]) * 255).astype(np.uint8)
    img = np.full((S, S, 3), 255, np.uint8); hit = ib >= 0
    img[hit] = rgb[ib[hit]]
    # edges: feature + outline, depth-tested against the z buffer
    E = feature_edges(T)
    if len(E):
        PE = E @ np.c_[right, up, -fwd]; XE = tf(PE[..., :2]); ZE = PE[..., 2]
        L = np.linalg.norm(XE[:, 1] - XE[:, 0], axis=1); k = np.maximum(2, np.ceil(L / 0.7).astype(int))
        tot = k.sum(); seg = np.repeat(np.arange(len(E)), k); t = (np.arange(tot) - np.repeat(np.cumsum(k) - k, k)) / np.repeat(k - 1, k)
        xy = XE[seg, 0] + (XE[seg, 1] - XE[seg, 0]) * t[:, None]; z = ZE[seg, 0] + (ZE[seg, 1] - ZE[seg, 0]) * t
        px = np.clip(xy[:, 0].astype(int), 0, S - 1); py = np.clip(xy[:, 1].astype(int), 0, S - 1)
        span = (Z.max() - Z.min()) or 1.0
        vis = z >= zb[py, px] - 0.004 * span
        dark = np.array([35, 35, 35], np.uint8); w = max(1, int(round(ss * 0.8)))
        for dx in range(w):
            for dy in range(w):
                img[np.clip(py[vis] + dy, 0, S - 1), np.clip(px[vis] + dx, 0, S - 1)] = dark
    return Image.fromarray(img).resize((size, size), Image.LANCZOS)


FILL2D = {'Detail Items', 'Filled region'}                      # filled regions / detail components: drawn as fills in 2D


def plane_axes(pts):
    """2D axes (3x2) to look square-on at the best-fit plane of pts; plan = north up, vertical planes = world up"""
    c = pts.mean(0); _, sv, vt = np.linalg.svd(pts - c, full_matrices=False); nrm = vt[2]
    if len(pts) < 3 or sv[2] > 0.15 * max(sv[0], 1e-12):
        right, up, _ = view_basis(); return np.c_[right, up]
    if abs(nrm[1]) > 0.7: return np.c_[[1, 0, 0], [0, 0, -1]].astype(float)
    u = np.array([0, 1.0, 0]) - nrm * nrm[1]; u /= np.linalg.norm(u); return np.c_[np.cross(u, nrm), u]


def render2d(lines, tris, size, ss=3, solids=()):
    """line drawing: 2D linework + filled regions (+ optional 3D parts as light fills) seen square-on"""
    segs = [s for n, s in lines if base(n) not in SKIP2D and len(s)]
    fills = [t[k] for n, t, c, k in tris if base(n) in FILL2D and k.any()]
    solids = [t for t in solids if len(t)]
    if not segs and not fills and not solids: return None
    allp = np.concatenate([x.reshape(-1, 3) for x in segs + fills + solids])
    ax = plane_axes(np.concatenate([x.reshape(-1, 3) for x in (segs + fills)]) if (segs or fills) else allp)
    S = size * ss; tf = fit((allp @ ax), S)
    im = Image.new('RGB', (S, S), (255, 255, 255)); dr = ImageDraw.Draw(im)
    for t in solids:
        X = tf(t @ ax)
        for tri in X: dr.polygon([tuple(q) for q in tri], fill=(200, 200, 200))
    for t in fills:
        X = tf(t @ ax)
        for tri in X: dr.polygon([tuple(q) for q in tri], fill=(70, 70, 70))
    w = max(2, int(round(S / 170)))
    for sg in segs:
        for a, b in tf(sg @ ax): dr.line([tuple(a), tuple(b)], fill=(25, 25, 25), width=w)
    return im.resize((size, size), Image.LANCZOS)


def flat(arrs):
    """all the '3D' content lies in one plane (imported 2D CAD, filled regions): not a solid to show in 3D"""
    if not arrs: return True
    P = np.concatenate([a.reshape(-1, 3) for a in arrs]); c = P.mean(0)
    sv = np.linalg.svd(P - c, compute_uv=False) if len(P) >= 3 else np.zeros(3)
    return sv[-1] <= 1e-4 * max(sv[0], 1e-12)


def extent(arrs):
    if not arrs: return 0.0
    P = np.concatenate([a.reshape(-1, 3) for a in arrs]); return float(np.max(P.max(0) - P.min(0)))


def thumb(glb, size=256):
    tris, lines = load(glb)
    real3d = [t[k] for n, t, c, k in tris if base(n) not in SKIP3D and c[3] > 0.05 and k.any()]
    lines2d = [s for n, s in lines if base(n) not in SKIP2D and base(n) != '<Sketch>' and len(s)]
    if real3d and extent(lines2d) > 4 * max(extent(real3d), 1e-9):   # 3D bits are specks next to the 2D drawing: draw it in 2D
        return render2d(lines, tris, size, solids=real3d)
    return render3d(tris, size) or render2d(lines, tris, size)


if __name__ == '__main__':
    im = thumb(sys.argv[1], int(sys.argv[3]) if len(sys.argv) > 3 else 256)
    if im is None: sys.exit(2)
    im.save(sys.argv[2])

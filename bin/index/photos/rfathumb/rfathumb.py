"""Thumbnail for a Revit file (.rfa family, .rvt / .rte / .rft) without Revit.

usage: rfathumb.py FILE OUT.jpg [SIZE]      -> exit 0 and prints the source used; exit 2 = nothing drawable

Order:
  1. the preview Revit saved in the file (OLE stream RevitPreview4.0, a PNG), unless it is Revit's blank placeholder
  2. families only (.rfa): rvt-ballet converts the file; real 3D content -> isometric z-buffered render (glbthumb)
  3. families only: no 3D -> the family's main 2D view drawn by rvt-sheets (famview -> SVG -> svgthumb)
  4. families only: rvt-ballet's line work drawn flat (glbthumb 2D)
Projects are never converted here (too large): no saved preview means no thumbnail.

Tools (override with the environment variables):
  RFATHUMB_PY      python with rvt-ballet + rvt-sheets deps   ~/.local/share/rfathumb/venv/bin/python
  RVT_BALLET_DIR   rvt-ballet checkout                        ~/src/rvt-ballet-query
  RVT_SHEETS_DIR   rvt-sheets checkout                        ~/src/rvt-sheets-h2
  RVT_READER_DIR   rvt-research reader                         ~/src/rvt-research-h2
  RVT_BALLET_CACHE rvt-ballet's raw/geometry cache            ~/.cache/rfathumb/rvt-ballet
"""
import io, os, shutil, subprocess, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
X = os.path.expanduser
PY = X(os.environ.get('RFATHUMB_PY', '~/.local/share/rfathumb/venv/bin/python'))
BALLET = X(os.environ.get('RVT_BALLET_DIR', '~/src/rvt-ballet-query'))
ENV = dict(os.environ,
           RVT_SHEETS_DIR=X(os.environ.get('RVT_SHEETS_DIR', '~/src/rvt-sheets-h2')),
           RVT_READER_DIR=X(os.environ.get('RVT_READER_DIR', '~/src/rvt-research-h2')),
           RVT_BALLET_CACHE=X(os.environ.get('RVT_BALLET_CACHE', '~/.cache/rfathumb/rvt-ballet')))
BLANK_PNG_LEN = 252          # Revit's grey placeholder preview (families saved without a preview, e.g. extracted from projects)


def saved_preview(path):
    """PIL image of the preview Revit stored in the file, or None (missing / blank placeholder)"""
    import olefile
    from PIL import Image
    try:
        with olefile.OleFileIO(path) as o:
            if not o.exists('RevitPreview4.0'): return None
            d = o.openstream('RevitPreview4.0').read()
    except Exception:
        return None
    k = d.find(b'\x89PNG')
    if k < 0 or len(d) - k <= BLANK_PNG_LEN: return None
    try:
        im = Image.open(io.BytesIO(d[k:])).convert('RGB')
    except Exception:
        return None
    lo, hi = zip(*im.getextrema())
    if max(hi) - min(lo) < 8: return None                          # uniform image: also a placeholder
    return im


def run(args, timeout):
    return subprocess.run(args, env=ENV, capture_output=True, text=True, timeout=timeout)


def save(im, out, size):
    from PIL import Image
    im = im.convert('RGB')
    if im.size != (size, size):
        k = size / max(im.size); im = im.resize((max(1, round(im.width * k)), max(1, round(im.height * k))), Image.LANCZOS)      # also enlarges Revit's 128 px previews
        bg = Image.new('RGB', (size, size), (255, 255, 255)); bg.paste(im, ((size - im.width) // 2, (size - im.height) // 2)); im = bg
    tmp = out + '.tmp'
    im.save(tmp, 'JPEG', quality=88); os.replace(tmp, out)


def generated(path, size, work):
    """(PIL image, source) for a family without a usable saved preview"""
    from PIL import Image
    conv = os.path.join(work, 'conv')
    r = run([PY, '-c', 'import sys; sys.path.insert(0, %r); from rvtballet.cli import main; main()' % BALLET, 'convert', path, conv], 240)
    glb = os.path.join(conv, 'model.glb')
    tris = lines = None
    if os.path.exists(glb):
        sys.path.insert(0, HERE)
        import glbthumb as G
        tris, lines = G.load(glb)
        real3d = [t[k] for n, t, c, k in tris if G.base(n) not in G.SKIP3D and c[3] > 0.05 and k.any()]
        lines2d = [s for n, s in lines if G.base(n) not in G.SKIP2D and G.base(n) != '<Sketch>' and len(s)]
        if real3d and not G.flat(real3d) and not G.extent(lines2d) > 4 * max(G.extent(real3d), 1e-9):
            im = G.render3d(tris, size)
            if im is not None: return im, '3d'
    svg = os.path.join(work, 'v.svg'); png = os.path.join(work, 'v.png')
    r = run([PY, os.path.join(HERE, 'famview.py'), path, svg], 240)
    if r.returncode == 0 and os.path.exists(svg):
        r = run([PY, os.path.join(HERE, 'svgthumb.py'), svg, png, str(size)], 120)
        if r.returncode == 0 and os.path.exists(png):
            im = Image.open(png).convert('RGB')
            lo, hi = zip(*im.getextrema())
            if max(hi) - min(lo) >= 8: return im, '2d-view'
    if tris is not None:
        import glbthumb as G
        im = G.render3d(tris, size) or G.render2d(lines, tris, size)
        if im is not None: return im, 'lines'
    return None, None


def thumb(path, out, size=256):
    im = saved_preview(path)
    if im is not None:
        save(im, out, size); return 'saved'
    if not path.lower().endswith('.rfa'): return None
    work = tempfile.mkdtemp(prefix='rfathumb-')
    try:
        im, src = generated(path, size, work)
        if im is None: return None
        save(im, out, size); return src
    finally:
        shutil.rmtree(work, ignore_errors=True)


if __name__ == '__main__':
    src = thumb(sys.argv[1], sys.argv[2], int(sys.argv[3]) if len(sys.argv) > 3 else 256)
    if not src: sys.exit(2)
    print(src)

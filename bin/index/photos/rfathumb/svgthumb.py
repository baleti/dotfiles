"""svgthumb.py IN.svg OUT.png [size] : rvt-sheets view SVG -> square thumbnail.
Paper pens (0.1-0.5 mm) vanish at 256 px, so strokes get a floor relative to the drawing size; output is trimmed and centred."""
import re, subprocess, sys, tempfile, os

src, out = sys.argv[1], sys.argv[2]; size = int(sys.argv[3]) if len(sys.argv) > 3 else 256
s = open(src).read()
vb = [float(x) for x in re.search(r'viewBox="([^"]+)"', s).group(1).split()]
# content extent from path coordinates (the viewBox can include empty view crop)
nums = [float(x) for x in re.findall(r'[ML]\s*(-?[\d.]+)\s+(-?[\d.]+)', s) for x in x] if False else None
xs, ys = [], []
for m in re.finditer(r'[MLC ]\s*(-?\d+\.?\d*)[ ,](-?\d+\.?\d*)', s):
    xs.append(float(m.group(1))); ys.append(float(m.group(2)))
span = max((max(xs) - min(xs)) if xs else vb[2], (max(ys) - min(ys)) if ys else vb[3]) or 1.0
floor = span / 140.0
s = re.sub(r'stroke-width="([\d.]+)"', lambda m: 'stroke-width="%.4f"' % max(float(m.group(1)), floor), s)
# text extents are not in the viewBox (labels / view titles hang outside it): pad the canvas, the raster is trimmed afterwards
padv = 3.0 * max(vb[2], vb[3])
vb = [vb[0] - padv, vb[1] - padv, vb[2] + 2 * padv, vb[3] + 2 * padv]
s = re.sub(r'viewBox="[^"]+"', 'viewBox="%g %g %g %g"' % tuple(vb), s, count=1)
s = re.sub(r'(<svg[^>]*?)\swidth="[^"]+"', r'\1', s, count=1); s = re.sub(r'(<svg[^>]*?)\sheight="[^"]+"', r'\1', s, count=1)
s = s.replace('<rect width="100%" height="100%" fill="#fff"/>', '', 1)
with tempfile.TemporaryDirectory() as d:
    sv = os.path.join(d, 'a.svg'); open(sv, 'w').write(s); png = os.path.join(d, 'a.png')
    k = 3 * size / max(span, 1e-9)
    w = max(64, min(6000, int(vb[2] * k))); h = max(64, min(6000, int(vb[3] * k)))
    subprocess.run(['rsvg-convert', '-w', str(w), '-h', str(h), '-b', 'white', '-o', png, sv], check=True)
    pad = int(size * 0.07)
    subprocess.run(['magick', png, '-trim', '+repage', '-resize', '%dx%d' % (size - 2 * pad, size - 2 * pad),
                    '-background', 'white', '-gravity', 'center', '-extent', '%dx%d' % (size, size), out], check=True)

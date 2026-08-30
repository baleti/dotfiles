#!/usr/bin/env python3
"""Resolve freedesktop icon names to real file paths.

quickshell's `image://icon/` provider goes through QIcon::fromTheme, which
here (KDE platform theme -> Tela-blue-dark) misses the hicolor fallback, so
lots of app icons come back blank. rofi sidestepped this with an explicit
`icon-theme: "Papirus"` -- this does the same kind of plain XDG lookup, but
across a priority list of themes plus hicolor / pixmaps, so it does not
depend on any one theme being complete.

Icon names come on argv (or, if none, one per line on stdin); writes
{name: path} JSON to stdout. A name that is already an absolute path passes
through; one that resolves nowhere is omitted.
"""

import json
import os
import sys

HOME = os.path.expanduser("~")
EXTS = (".svg", ".png", ".xpm")

# Priority order. First hit wins. Papirus first (what rofi used and the most
# complete), then whatever KDE is set to, then the universal fallbacks.
THEME_ORDER = [
    "Papirus-Dark", "Papirus", "ePapirus-Dark", "ePapirus",
    "Tela-blue-dark", "Tela-dark", "Tela",
    "breeze-dark", "breeze", "Adwaita", "hicolor",
]


def theme_roots():
    roots = [
        os.path.join(HOME, ".icons"),
        os.path.join(os.environ.get("XDG_DATA_HOME", os.path.join(HOME, ".local/share")), "icons"),
    ]
    for d in (os.environ.get("XDG_DATA_DIRS") or "/usr/local/share:/usr/share").split(":"):
        roots.append(os.path.join(d, "icons"))
    seen, out = set(), []
    for r in roots:
        if r not in seen and os.path.isdir(r):
            seen.add(r)
            out.append(r)
    return out


def build_index():
    """{ basename: {theme: [paths]} } over just the themes in THEME_ORDER,
    plus a flat pixmaps list."""
    roots = theme_roots()
    idx = {}
    for theme in THEME_ORDER:
        for root in roots:
            tdir = os.path.join(root, theme)
            if not os.path.isdir(tdir):
                continue
            for dirpath, _dirs, files in os.walk(tdir):
                # apps / places / devices contexts only -- skip mimetypes,
                # emblems, status etc, which balloon the walk.
                base = os.path.basename(dirpath)
                if base not in ("apps", "places", "devices", "categories", "scalable"):
                    if "apps" not in dirpath and "scalable" not in dirpath:
                        continue
                for f in files:
                    name, ext = os.path.splitext(f)
                    if ext in EXTS:
                        idx.setdefault(name, {}).setdefault(theme, []).append(os.path.join(dirpath, f))

    pixmaps = []
    for d in ("/usr/share/pixmaps", os.path.join(HOME, ".local/share/pixmaps")):
        if os.path.isdir(d):
            for f in os.listdir(d):
                name, ext = os.path.splitext(f)
                if ext in EXTS:
                    pixmaps.append((name, os.path.join(d, f)))
    return idx, dict(pixmaps)


def _score(path):
    # prefer scalable, then larger raster sizes
    if "scalable" in path or path.endswith(".svg"):
        return 100000
    for token in path.split(os.sep):
        if "x" in token:
            try:
                return int(token.split("x")[0])
            except ValueError:
                pass
    return 0


def resolve(name, idx, pixmaps):
    if os.path.isabs(name):
        return name if os.path.exists(name) else ""
    entry = idx.get(name)
    if entry:
        for theme in THEME_ORDER:
            if theme in entry:
                return max(entry[theme], key=_score)
    if name in pixmaps:
        return pixmaps[name]
    # last resort: a name that is a partial (e.g. "firefox" when only
    # "firefox-default" exists) -- take the shortest close match
    for cand, themes in idx.items():
        if cand.startswith(name + "-") or cand.startswith(name + "."):
            for theme in THEME_ORDER:
                if theme in themes:
                    return max(themes[theme], key=_score)
    return ""


def main():
    names = sys.argv[1:] or [ln.strip() for ln in sys.stdin if ln.strip()]
    names = [n for n in names if n]
    idx, pixmaps = build_index()
    out = {}
    for n in names:
        p = resolve(n, idx, pixmaps)
        if p:
            out[n] = p
    json.dump(out, sys.stdout)


if __name__ == "__main__":
    main()

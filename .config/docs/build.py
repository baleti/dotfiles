#!/usr/bin/env python3
"""Static-site generator for this dotfiles documentation set.

Turns the hand-written Markdown in this directory into a self-contained HTML
site under ./site/ (git-untracked - regenerable from the .md files + assets/).

    ./build.py            build into ./site/
    ./build.py --serve    build, then serve ./site/ on http://localhost:8000

Requires: pandoc (already a dependency of nothing else here; `pacman -S pandoc`).
Deploy the built site with ./deploy.sh (pushes to the repo's gh-pages branch).
"""
import argparse
import http.server
import json
import os
import re
import shutil
import socketserver
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent
SITE = ROOT / "site"
ASSETS = ROOT / "assets"

SITE_TITLE = "dotfiles docs"
SITE_URL = "https://baleti.github.io/dotfiles/"

# Nav order + short sidebar labels. First entry becomes the site homepage.
PAGES = [
    ("README.md",           "Overview"),
    ("hyprland.md",          "Hyprland"),
    ("rust-tools.md",        "Rust tools"),
    ("quickshell-bar.md",    "quickshell bar"),
    ("theming.md",           "Theming pipeline"),
    ("tmux.md",              "tmux"),
    ("zsh-and-terminal.md",  "zsh & terminal"),
    ("desktop-apps.md",      "Desktop apps"),
    ("claude-history.md",    "claude-history"),
    ("query-dsl.md",         "Picker query DSL"),
]

MD_LINK_RE = re.compile(r'href="(?!(?:[a-z]+:)?//|/|#|mailto:)([^"#]+?)\.md(#[^"]*)?"')
MEMREF_RE = re.compile(r'\[\[([a-z0-9_]+)\]\]')
H1_RE = re.compile(r"<h1[^>]*>(.*?)</h1>", re.S)
HEADING_RE = re.compile(r'<h([23]) id="([^"]+)">(.*?)</h\1>', re.S)
TAG_RE = re.compile(r"<[^>]+>")


def out_name(md: str) -> str:
    return "index.html" if md == "README.md" else md[:-3] + ".html"


def strip_tags(html: str) -> str:
    """Plain text for the search body - tags become spaces so words never fuse."""
    return re.sub(r"\s+", " ", TAG_RE.sub(" ", html)).strip()


def inline_text(html: str) -> str:
    """Plain text for a heading/title - drop inline tags without inserting spaces."""
    return re.sub(r"\s+", " ", TAG_RE.sub("", html)).strip()


def render_fragment(md_path: Path) -> str:
    proc = subprocess.run(
        ["pandoc", "-f", "gfm", "-t", "html",
         "--syntax-highlighting=breezedark", str(md_path)],
        capture_output=True, text=True, check=True,
    )
    return proc.stdout


def fix_links(html: str) -> str:
    def repl(m: re.Match) -> str:
        target = m.group(1).rsplit("/", 1)[-1]
        anchor = m.group(2) or ""
        name = "index" if target == "README" else target
        return f'href="{name}.html{anchor}"'

    html = MD_LINK_RE.sub(repl, html)
    html = MEMREF_RE.sub(
        r'<span class="memref" title="internal memory note, outside this doc set">\1</span>',
        html,
    )
    return html


def build_toc(html: str) -> str:
    items = [(int(lvl), hid, inline_text(inner))
             for lvl, hid, inner in HEADING_RE.findall(html)]
    if len(items) < 2:
        return ""
    lis = "".join(
        f'<li class="lvl{lvl}"><a href="#{hid}">{text}</a></li>'
        for lvl, hid, text in items
    )
    return ('<aside class="toc"><p class="toc-title">On this page</p>'
            f'<ul>{lis}</ul></aside>')


def nav_html(active: str) -> str:
    lis = []
    for md, label in PAGES:
        url = out_name(md)
        cur = ' aria-current="page"' if url == active else ""
        lis.append(f'<li><a href="{url}"{cur}>{label}</a></li>')
    return f'<ul class="navlist">{"".join(lis)}</ul>'


def page_html(title: str, content: str, toc: str, active: str) -> str:
    full_title = title if active == "index.html" else f"{title} · {SITE_TITLE}"
    return f"""<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{full_title}</title>
<meta name="description" content="Documentation for the $HOME dotfiles repository.">
<link rel="stylesheet" href="assets/style.css">
</head>
<body>
<a class="skip" href="#main">Skip to content</a>
<header class="topbar">
  <button id="navtoggle" aria-label="Toggle navigation" aria-expanded="false">&#9776;</button>
  <a class="brand" href="index.html">dotfiles<span>docs</span></a>
  <input type="search" id="search" placeholder="Search  ( / )" autocomplete="off"
         spellcheck="false" aria-label="Search the documentation">
</header>
<div class="layout">
  <nav id="sidebar" class="sidebar" aria-label="Documentation pages">{nav_html(active)}</nav>
  <main id="main">
    <article class="doc">
{content}
    </article>
  </main>
  {toc}
</div>
<div id="searchpanel" hidden></div>
<script src="assets/search-index.js"></script>
<script src="assets/site.js"></script>
</body>
</html>
"""


def build() -> None:
    if not shutil.which("pandoc"):
        sys.exit("build.py: pandoc not found on PATH (pacman -S pandoc)")

    if SITE.exists():
        shutil.rmtree(SITE)
    (SITE / "assets").mkdir(parents=True)

    index = []
    for md, label in PAGES:
        src = ROOT / md
        if not src.exists():
            sys.exit(f"build.py: missing source page {md}")
        frag = fix_links(render_fragment(src))

        m = H1_RE.search(frag)
        title = inline_text(m.group(1)) if m else label
        toc = build_toc(frag)

        (SITE / out_name(md)).write_text(page_html(title, frag, toc, out_name(md)))

        body = strip_tags(H1_RE.sub("", frag, count=1))
        index.append({
            "url": out_name(md),
            "title": title,
            "nav": label,
            "headings": [{"id": hid, "text": inline_text(inner)}
                         for _, hid, inner in HEADING_RE.findall(frag)],
            "text": body[:4000],
        })

    (SITE / "assets" / "search-index.js").write_text(
        "window.SEARCH_INDEX=" + json.dumps(index, separators=(",", ":")) + ";\n"
    )
    for asset in ("style.css", "site.js"):
        shutil.copy(ASSETS / asset, SITE / "assets" / asset)

    images = ROOT / "images"
    if images.is_dir():
        shutil.copytree(images, SITE / "images")

    # Tell GitHub Pages to serve the tree verbatim (no Jekyll processing).
    (SITE / ".nojekyll").write_text("")
    # Helps humans who land on the raw branch.
    (SITE / "README.md").write_text(
        f"Generated site for {SITE_URL}\nBuilt by ../build.py from .config/docs/*.md - do not edit here.\n"
    )

    print(f"build.py: {len(PAGES)} pages -> {SITE.relative_to(Path.cwd()) if SITE.is_relative_to(Path.cwd()) else SITE}")


def serve() -> None:
    os.chdir(SITE)
    handler = http.server.SimpleHTTPRequestHandler
    with socketserver.TCPServer(("127.0.0.1", 8000), handler) as httpd:
        print("serving http://localhost:8000  (Ctrl-C to stop)")
        try:
            httpd.serve_forever()
        except KeyboardInterrupt:
            pass


if __name__ == "__main__":
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--serve", action="store_true",
                    help="serve ./site/ on localhost:8000 after building")
    args = ap.parse_args()
    build()
    if args.serve:
        serve()

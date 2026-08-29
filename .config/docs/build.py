#!/usr/bin/env python3
"""Static-site generator for this dotfiles documentation set.

The dotfiles repo keeps one long-lived branch per machine. This builds a
single site from ALL of them:

    https://baleti.github.io/dotfiles/            shared docs + machine index
    https://baleti.github.io/dotfiles/host3/      host3-specific docs
    https://baleti.github.io/dotfiles/host6/      host6-specific docs
    https://baleti.github.io/dotfiles/wsl/        main branch (wsl)
    https://baleti.github.io/dotfiles/qemu/       qemu-claude branch

Each branch's `.config/docs/*.md` is read from a throwaway `git worktree`
(NEVER a checkout in the live $HOME working tree). Pages listed in
SHARED_PAGES are published once at the root; every other page a branch
ships becomes that machine's own. The site chrome (this script + assets/)
always comes from the tree build.py is run from, not per-branch.

    ./build.py            build into ./site/
    ./build.py --serve    build, then serve ./site/ on http://localhost:8000

Requires: pandoc, git.  Deploy with ./deploy.sh (pushes to gh-pages).
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
import tempfile
from datetime import datetime, timezone
from pathlib import Path

BUILD_STAMP = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M UTC")

ROOT = Path(__file__).resolve().parent
SITE = ROOT / "site"
ASSETS = ROOT / "assets"

SITE_TITLE = "dotfiles docs"
SITE_URL = "https://baleti.github.io/dotfiles/"

# (git branch, url slug, display label). First that exists provides shared
# pages unless overridden by CANONICAL_BRANCH.
BRANCHES = [
    ("main",        "wsl",   "wsl"),
    ("host3",       "host3", "host3"),
    ("host6",       "host6", "host6"),
    ("qemu-claude", "qemu",  "qemu"),
]
# Whose copy of a shared page wins when several branches ship one.
CANONICAL_BRANCH = "host3"

# Pages promoted to the shared root. Everything else a branch ships is
# treated as that machine's own doc. Edit this to re-partition.
SHARED_PAGES = {
    "tmux.md",
    "zsh-and-terminal.md",
    "claude-history.md",
    "query-dsl.md",
}

# Sidebar order + short labels (README is always the section landing page).
ORDER = [
    "README.md", "hyprland.md", "rust-tools.md", "quickshell-bar.md",
    "theming.md", "tmux.md", "zsh-and-terminal.md", "desktop-apps.md",
    "claude-history.md", "query-dsl.md",
]
LABELS = {
    "README.md":           "Overview",
    "hyprland.md":          "Hyprland",
    "rust-tools.md":        "Rust tools",
    "quickshell-bar.md":    "quickshell bar",
    "theming.md":           "Theming pipeline",
    "tmux.md":              "tmux",
    "zsh-and-terminal.md":  "zsh & terminal",
    "desktop-apps.md":      "Desktop apps",
    "claude-history.md":    "claude-history",
    "query-dsl.md":         "Picker query DSL",
}

MD_LINK_RE = re.compile(r'href="(?!(?:[a-z]+:)?//|/|#|mailto:)([^"#]+?)\.md(#[^"]*)?"')
MEMREF_RE = re.compile(r'\[\[([a-z0-9_]+)\]\]')
FRONT_MATTER_RE = re.compile(r"\A---\n.*?\n---\n", re.S)
H1_RE = re.compile(r"<h1[^>]*>(.*?)</h1>", re.S)
HEADING_RE = re.compile(r'<h([23]) id="([^"]+)">(.*?)</h\1>', re.S)
TAG_RE = re.compile(r"<[^>]+>")


# --------------------------------------------------------------------------
# small helpers

def strip_tags(html: str) -> str:
    """Plain text for the search body - tags become spaces so words never fuse."""
    return re.sub(r"\s+", " ", TAG_RE.sub(" ", html)).strip()


def inline_text(html: str) -> str:
    """Plain text for a heading/title - drop inline tags without inserting spaces."""
    return re.sub(r"\s+", " ", TAG_RE.sub("", html)).strip()


def label_for(name: str) -> str:
    return LABELS.get(name, name[:-3] if name.endswith(".md") else name)


def order_key(name: str) -> int:
    return ORDER.index(name) if name in ORDER else len(ORDER)


def git(repo: Path, *args: str, check: bool = True) -> subprocess.CompletedProcess:
    return subprocess.run(["git", "-C", str(repo), *args],
                          capture_output=True, text=True, check=check)


def render_fragment(md_body: str) -> str:
    proc = subprocess.run(
        ["pandoc", "-f", "gfm", "-t", "html", "--syntax-highlighting=breezedark"],
        input=md_body, capture_output=True, text=True, check=True,
    )
    return proc.stdout


# --------------------------------------------------------------------------
# worktrees - read each branch's docs without ever touching the live tree

def add_worktrees(repo: Path, tmp: Path) -> dict:
    trees = {}
    for branch, _slug, _label in BRANCHES:
        ref = f"origin/{branch}"
        if git(repo, "rev-parse", "--verify", "--quiet", ref, check=False).returncode != 0:
            ref = branch
        if git(repo, "rev-parse", "--verify", "--quiet", ref, check=False).returncode != 0:
            print(f"build.py: branch {branch!r} not found (skipped)")
            continue
        dest = tmp / branch.replace("/", "-")
        git(repo, "worktree", "add", "--detach", "-f", str(dest), ref)
        trees[branch] = dest
    return trees


def remove_worktrees(repo: Path, trees: dict) -> None:
    for dest in trees.values():
        git(repo, "worktree", "remove", "--force", str(dest), check=False)
    git(repo, "worktree", "prune", check=False)


# --------------------------------------------------------------------------
# page discovery + registry

def slug_of(branch: str) -> str:
    return next(s for b, s, _ in BRANCHES if b == branch)


def label_of(branch: str) -> str:
    return next(l for b, _, l in BRANCHES if b == branch)


def out_path(name: str, section: str | None) -> str:
    """section=None -> shared root page; else that machine's subdir."""
    base = "index.html" if name == "README.md" else name[:-3] + ".html"
    return base if section is None else f"{section}/{base}"


def discover(trees: dict) -> dict:
    """Return {out_path: page-dict}. Shared pages appear once; per-host pages
    live under their slug. CANONICAL_BRANCH wins ties for shared pages."""
    pages: dict[str, dict] = {}
    branch_order = [b for b, _, _ in BRANCHES]

    for branch in branch_order:
        tree = trees.get(branch)
        if not tree:
            continue
        docdir = tree / ".config" / "docs"
        if not docdir.is_dir():
            continue
        section = slug_of(branch)
        for md in sorted(docdir.glob("*.md"), key=lambda p: order_key(p.name)):
            shared = md.name in SHARED_PAGES
            out = out_path(md.name, None if shared else section)

            if out in pages:
                # Only a shared page can collide (per-machine paths are unique).
                # Let the canonical branch's copy win; otherwise keep the first.
                if not (shared and branch == CANONICAL_BRANCH
                        and pages[out]["branch"] != CANONICAL_BRANCH):
                    continue

            raw = md.read_text()
            meta_m = FRONT_MATTER_RE.match(raw)
            body = raw[meta_m.end():] if meta_m else raw
            pages[out] = {
                "name": md.name,
                "branch": branch,
                "section": None if shared else section,
                "shared": shared,
                "out": out,
                "md": body,
                "srcdir": docdir,
            }
    return pages


def resolve_link(target_md: str, from_page: dict, pages: dict) -> str | None:
    """Best out_path for a `foo.md` link seen inside from_page."""
    target_md = target_md.rsplit("/", 1)[-1] + ".md"
    if target_md in SHARED_PAGES:
        cand = out_path(target_md, None)
        return cand if cand in pages else None
    # same machine first
    if from_page["section"]:
        cand = out_path(target_md, from_page["section"])
        if cand in pages:
            return cand
    # canonical machine, then any machine that ships it
    for branch in [CANONICAL_BRANCH] + [b for b, _, _ in BRANCHES]:
        cand = out_path(target_md, slug_of(branch))
        if cand in pages:
            return cand
    return None


def fixup(html: str, from_page: dict, pages: dict) -> str:
    def repl(m: re.Match) -> str:
        raw_target, anchor = m.group(1), m.group(2) or ""
        dest = resolve_link(raw_target, from_page, pages)
        if dest is None:
            base = raw_target.rsplit("/", 1)[-1]
            base = "index" if base == "README" else base
            return f'href="{base}.html{anchor}"'
        rel = os.path.relpath(dest, os.path.dirname(from_page["out"]) or ".")
        return f'href="{rel}{anchor}"'

    html = MD_LINK_RE.sub(repl, html)
    html = MEMREF_RE.sub(
        r'<span class="memref" title="internal memory note, outside this doc set">\1</span>',
        html,
    )
    return html


# --------------------------------------------------------------------------
# rendering

def rel(target: str, from_out: str) -> str:
    return os.path.relpath(target, os.path.dirname(from_out) or ".")


def nav_html(from_out: str, active_out: str, pages: dict, machine: str | None) -> str:
    """machine = current slug, or None on the root landing page."""
    shared = sorted((p for p in pages.values() if p["shared"]),
                    key=lambda p: order_key(p["name"]))

    def li(p):
        cur = ' aria-current="page"' if p["out"] == active_out else ""
        return f'<li><a href="{rel(p["out"], from_out)}"{cur}>{label_for(p["name"])}</a></li>'

    out = []

    # machine switcher
    chips = []
    for _b, slug, lbl in BRANCHES:
        target = out_path("README.md", slug)  # stub index is always emitted
        cls = ' class="on"' if slug == machine else ""
        chips.append(f'<a href="{rel(target, from_out)}"{cls}>{lbl}</a>')
    home_cls = ' class="on"' if machine is None else ""
    switcher = (f'<div class="machines"><a href="{rel("index.html", from_out)}"{home_cls}>'
                f'shared</a>' + "".join(chips) + "</div>")
    out.append(switcher)

    if machine is None:
        host_items = "".join(
            f'<li><a href="{rel(out_path("README.md", slug), from_out)}">{lbl}</a></li>'
            for _b, slug, lbl in BRANCHES
        )
        out.append('<div class="navgroup"><p class="navgroup-title">Machines</p>'
                   f'<ul class="navlist">{host_items}</ul></div>')
    else:
        mine = sorted((p for p in pages.values() if p["section"] == machine),
                      key=lambda p: order_key(p["name"]))
        if mine:
            out.append(f'<div class="navgroup"><p class="navgroup-title">{machine}</p>'
                       f'<ul class="navlist">{"".join(li(p) for p in mine)}</ul></div>')

    if shared:
        out.append('<div class="navgroup"><p class="navgroup-title">Shared</p>'
                   f'<ul class="navlist">{"".join(li(p) for p in shared)}</ul></div>')
    return "".join(out)


def toc_html(html: str) -> str:
    items = [(int(lvl), hid, inline_text(inner))
             for lvl, hid, inner in HEADING_RE.findall(html)]
    if len(items) < 2:
        return ""
    lis = "".join(f'<li class="lvl{lvl}"><a href="#{hid}">{text}</a></li>'
                  for lvl, hid, text in items)
    return ('<aside class="toc"><p class="toc-title">On this page</p>'
            f'<ul>{lis}</ul></aside>')


def page_html(title: str, subtitle: str, content: str, toc: str,
              nav: str, from_out: str) -> str:
    root = rel(".", from_out)
    root = "" if root == "." else root.rstrip("/") + "/"
    is_home = from_out == "index.html"
    full_title = title if is_home else f"{title} · {SITE_TITLE}"
    sub = f'<p class="crumb">{subtitle}</p>' if subtitle else ""
    return f"""<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{full_title}</title>
<meta name="description" content="Documentation for the $HOME dotfiles repository.">
<link rel="stylesheet" href="{root}assets/style.css">
<script>window.SITE_ROOT={json.dumps(root)};</script>
</head>
<body>
<a class="skip" href="#main">Skip to content</a>
<header class="topbar">
  <button id="navtoggle" aria-label="Toggle navigation" aria-expanded="false">&#9776;</button>
  <a class="brand" href="{root}index.html">dotfiles<span>docs</span></a>
  <span class="ai-badge" title="These pages are written by an AI (Claude) from the dotfiles repo, not hand-maintained. Last built {BUILD_STAMP}.">AI-generated<span class="ai-stamp"> &middot; {BUILD_STAMP}</span></span>
  <input type="search" id="search" placeholder="Search  ( / )" autocomplete="off"
         spellcheck="false" aria-label="Search the documentation">
</header>
<div class="layout">
  <nav id="sidebar" class="sidebar" aria-label="Documentation navigation">{nav}</nav>
  <main id="main">
    {sub}
    <article class="doc">
{content}
    </article>
  </main>
  {toc}
</div>
<div id="searchpanel" hidden></div>
<script src="{root}assets/search-index.js"></script>
<script src="{root}assets/site.js"></script>
</body>
</html>
"""


def machine_intro(slug: str, label: str, has_own: bool) -> str:
    if has_own:
        return (f'<h1>{label}</h1>\n<p>Configuration specific to the '
                f'<code>{label}</code> machine. Cross-machine docs are under '
                f'<a href="../index.html">Shared</a>.</p>')
    return (f'<h1>{label}</h1>\n<p>No machine-specific documentation for '
            f'<code>{label}</code> yet - its <code>.config/docs/</code> is '
            f'empty on that branch. See the <a href="../index.html">shared '
            f'docs</a>, which apply everywhere.</p>')


def root_index(pages: dict) -> str:
    cards = []
    for _b, slug, label in BRANCHES:
        own = sorted((p for p in pages.values() if p["section"] == slug),
                     key=lambda p: order_key(p["name"]))
        listing = ", ".join(label_for(p["name"]) for p in own) or "shared docs only"
        cards.append(
            f'<a class="machine-card" href="{slug}/index.html">'
            f'<span class="mc-name">{label}</span>'
            f'<span class="mc-list">{listing}</span></a>'
        )
    shared = sorted((p for p in pages.values() if p["shared"]),
                    key=lambda p: order_key(p["name"]))
    shared_items = "".join(
        f'<li><a href="{p["out"]}">{label_for(p["name"])}</a></li>' for p in shared
    )
    return f"""<h1>dotfiles documentation</h1>
<p>Documentation for the <code>$HOME</code> dotfiles repository
(<a href="https://github.com/baleti/dotfiles">baleti/dotfiles</a>). The repo
keeps one long-lived branch per machine; this site is built from all of them.</p>
<h2 id="machines">Machines</h2>
<div class="machine-grid">{"".join(cards)}</div>
<h2 id="shared">Shared docs</h2>
<p>These apply on every machine:</p>
<ul class="navlist plain">{shared_items}</ul>
"""


# --------------------------------------------------------------------------
# build

def build() -> None:
    for tool in ("pandoc", "git"):
        if not shutil.which(tool):
            sys.exit(f"build.py: {tool} not found on PATH")

    repo = Path(git(ROOT, "rev-parse", "--show-toplevel").stdout.strip())
    tmp = Path(tempfile.mkdtemp(prefix="dotfiles-docs-"))
    trees = {}
    try:
        trees = add_worktrees(repo, tmp)
        if not trees:
            sys.exit("build.py: no branches available to build")
        pages = discover(trees)
        if not pages:
            sys.exit("build.py: no .config/docs/*.md found on any branch")

        if SITE.exists():
            shutil.rmtree(SITE)
        (SITE / "assets").mkdir(parents=True)

        index = []

        # content pages
        for out, p in sorted(pages.items()):
            frag = fixup(render_fragment(p["md"]), p, pages)
            m = H1_RE.search(frag)
            title = inline_text(m.group(1)) if m else label_for(p["name"])
            subtitle = "" if p["shared"] else p["section"]
            nav = nav_html(out, out, pages, p["section"])
            html = page_html(title, subtitle, frag, toc_html(frag), nav, out)
            dst = SITE / out
            dst.parent.mkdir(parents=True, exist_ok=True)
            dst.write_text(html)

            body = strip_tags(H1_RE.sub("", frag, count=1))
            index.append({
                "url": out,
                "title": title,
                "scope": "shared" if p["shared"] else p["section"],
                "headings": [{"id": hid, "text": inline_text(inner)}
                             for _, hid, inner in HEADING_RE.findall(frag)],
                "text": body[:4000],
            })

        # per-machine landing pages (stub when the branch ships no README)
        for _b, slug, label in BRANCHES:
            out = out_path("README.md", slug)
            if out in pages:
                continue
            has_own = any(p["section"] == slug for p in pages.values())
            frag = machine_intro(slug, label, has_own)
            nav = nav_html(out, out, pages, slug)
            html = page_html(label, slug, frag, "", nav, out)
            dst = SITE / out
            dst.parent.mkdir(parents=True, exist_ok=True)
            dst.write_text(html)
            index.append({"url": out, "title": label, "scope": slug,
                          "headings": [], "text": strip_tags(frag)})

        # root landing page
        frag = root_index(pages)
        nav = nav_html("index.html", "index.html", pages, None)
        (SITE / "index.html").write_text(
            page_html("dotfiles documentation", "", frag, toc_html(frag), nav, "index.html")
        )
        index.append({"url": "index.html", "title": "dotfiles documentation",
                      "scope": "shared", "headings": [], "text": strip_tags(frag)})

        # assets + images (images come from whichever branch ships each page's dir)
        (SITE / "assets" / "search-index.js").write_text(
            "window.SEARCH_INDEX=" + json.dumps(index, separators=(",", ":")) + ";\n"
        )
        for asset in ("style.css", "site.js"):
            shutil.copy(ASSETS / asset, SITE / "assets" / asset)

        # Copy an images/ dir only into sections that actually reference one.
        copied_img_dirs = set()
        for p in pages.values():
            imgsrc = p["srcdir"] / "images"
            imgdst = (SITE if p["shared"] else SITE / p["section"]) / "images"
            if imgdst in copied_img_dirs or not imgsrc.is_dir():
                continue
            if 'src="images/' not in (SITE / p["out"]).read_text():
                continue
            imgdst.mkdir(parents=True, exist_ok=True)
            for f in imgsrc.iterdir():
                if f.is_file():
                    shutil.copy(f, imgdst / f.name)
            copied_img_dirs.add(imgdst)

        (SITE / ".nojekyll").write_text("")
        (SITE / "README.md").write_text(
            f"Generated site for {SITE_URL}\n"
            "Built by .config/docs/build.py from every branch's .config/docs/*.md.\n"
            "Do not edit here - edit the .md sources and run .config/docs/deploy.sh.\n"
        )
        print(f"build.py: {len(pages)} pages + {len(BRANCHES)} machine landings -> {SITE}")
    finally:
        remove_worktrees(repo, trees)
        shutil.rmtree(tmp, ignore_errors=True)


def fingerprint() -> None:
    """Print a hash of everything that affects the built output (every branch's
    doc sources + the site chrome). deploy.sh --if-changed compares this to a
    cached value to skip no-op rebuilds."""
    import hashlib
    repo = Path(git(ROOT, "rev-parse", "--show-toplevel").stdout.strip())
    tmp = Path(tempfile.mkdtemp(prefix="dotfiles-docs-fp-"))
    trees = {}
    try:
        trees = add_worktrees(repo, tmp)
        h = hashlib.sha1()
        for out, p in sorted(discover(trees).items()):
            h.update(out.encode())
            h.update(p["md"].encode())
        for extra in (ASSETS / "style.css", ASSETS / "site.js", Path(__file__)):
            h.update(extra.read_bytes())
        print(h.hexdigest())
    finally:
        remove_worktrees(repo, trees)
        shutil.rmtree(tmp, ignore_errors=True)


def serve() -> None:
    os.chdir(SITE)
    with socketserver.TCPServer(("127.0.0.1", 8000),
                                http.server.SimpleHTTPRequestHandler) as httpd:
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
    ap.add_argument("--fingerprint", action="store_true",
                    help="print a hash of all doc sources + chrome, then exit "
                         "(used by deploy.sh --if-changed)")
    args = ap.parse_args()
    if args.fingerprint:
        fingerprint()
    else:
        build()
        if args.serve:
            serve()

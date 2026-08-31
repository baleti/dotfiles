#!/usr/bin/env python3
"""rssd-reader - a small terminal reader over rssd's article archive.

Reads ~/.cache/rssd/items.jsonl (written by rssd), tracks read/unread in
~/.cache/rssd/read.json. No feed fetching of its own -- press `r` to run rssd.

  j/k  ↓/↑      move            g / G     top / bottom
  Enter / o     open in browser (marks read)
  m             toggle read     A         mark all (in view) read
  u             unread-only toggle
  t             cycle tag filter
  /             filter by text (title/feed);  Esc clears
  r             run `rssd` now, then reload
  q / Esc       quit
"""

from __future__ import annotations

import curses
import json
import os
import subprocess
import sys
import textwrap
import time
from datetime import datetime, timezone
from pathlib import Path

CACHE = Path(os.environ.get("XDG_CACHE_HOME", Path.home() / ".cache")) / "rssd"
ITEMS = CACHE / "items.jsonl"
READ_FILE = CACHE / "read.json"
RSSD = str(Path(__file__).with_name("rssd.py"))


def load_items() -> list[dict]:
    if not ITEMS.exists():
        return []
    seen, out = set(), []
    for line in ITEMS.read_text().splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            rec = json.loads(line)
        except json.JSONDecodeError:
            continue
        key = rec.get("id") or rec.get("link")
        if not key or key in seen:
            continue
        seen.add(key)
        rec["_key"] = key
        rec["_sort"] = rec.get("published") or rec.get("fetched_at") or ""
        out.append(rec)
    out.sort(key=lambda r: r["_sort"], reverse=True)
    return out


def load_read() -> dict:
    try:
        return json.loads(READ_FILE.read_text())
    except (OSError, json.JSONDecodeError):
        return {}


def save_read(read: dict):
    CACHE.mkdir(parents=True, exist_ok=True)
    tmp = READ_FILE.with_suffix(".json.tmp")
    tmp.write_text(json.dumps(read, separators=(",", ":")))
    tmp.replace(READ_FILE)


def fmt_date(iso: str) -> str:
    if not iso:
        return ""
    try:
        dt = datetime.fromisoformat(iso.replace("Z", "+00:00"))
    except ValueError:
        return iso[:16]
    dt = dt.astimezone()
    delta = datetime.now(dt.tzinfo) - dt
    days = delta.days
    if days == 0 and delta.seconds < 3600:
        return f"{delta.seconds // 60}m ago"
    if days == 0:
        return f"{delta.seconds // 3600}h ago"
    if days < 7:
        return f"{days}d ago"
    return dt.strftime("%Y-%m-%d")


def open_url(url: str):
    if url:
        subprocess.Popen(["xdg-open", url], stdout=subprocess.DEVNULL,
                         stderr=subprocess.DEVNULL, start_new_session=True)


class Reader:
    def __init__(self, scr):
        self.scr = scr
        self.items = load_items()
        self.read = load_read()
        self.sel = 0
        self.top = 0
        self.unread_only = False
        self.text_filter = ""
        self.tag_filter = None
        self.tags = sorted({t for it in self.items for t in it.get("tags", [])})
        self.status = ""
        curses.curs_set(0)
        curses.use_default_colors()
        for i in range(1, 7):
            curses.init_pair(i, [0, curses.COLOR_CYAN, curses.COLOR_YELLOW,
                                 curses.COLOR_GREEN, curses.COLOR_WHITE,
                                 curses.COLOR_MAGENTA][i - 1], -1)

    # ---- filtering -----------------------------------------------------
    @property
    def view(self) -> list[dict]:
        out = []
        tf = self.text_filter.lower()
        for it in self.items:
            if self.unread_only and it["_key"] in self.read:
                continue
            if self.tag_filter and self.tag_filter not in it.get("tags", []):
                continue
            if tf and tf not in (it.get("title", "") + " "
                                 + it.get("feed_title", "")).lower():
                continue
            out.append(it)
        return out

    def clamp(self, view):
        if self.sel >= len(view):
            self.sel = max(0, len(view) - 1)
        if self.sel < 0:
            self.sel = 0

    # ---- drawing ------------------------------------------------------
    def put(self, y, x, s, attr=curses.A_NORMAL):
        """addnstr that never trips over the bottom-right cell / tiny terms."""
        h, w = self.scr.getmaxyx()
        if y < 0 or y >= h or x >= w:
            return
        n = w - x - (1 if y == h - 1 else 0)
        if n <= 0:
            return
        try:
            self.scr.addnstr(y, x, s, n, attr)
        except curses.error:
            pass

    def draw(self):
        self.scr.erase()
        h, w = self.scr.getmaxyx()
        view = self.view
        self.clamp(view)
        unread = sum(1 for it in self.items if it["_key"] not in self.read)

        listh = h - 2
        preview_h = min(12, max(6, h // 3))
        listh -= preview_h + 1

        if self.sel < self.top:
            self.top = self.sel
        if self.sel >= self.top + listh:
            self.top = self.sel - listh + 1

        # header
        filt = []
        if self.unread_only:
            filt.append("unread-only")
        if self.tag_filter:
            filt.append(f"#{self.tag_filter}")
        if self.text_filter:
            filt.append(f"/{self.text_filter}")
        hdr = f" rssd  {len(view)} shown · {unread} unread"
        if filt:
            hdr += "  [" + " ".join(filt) + "]"
        self.put(0, 0, hdr.ljust(w), curses.A_REVERSE)

        # list
        for row in range(listh):
            idx = self.top + row
            if idx >= len(view):
                break
            it = view[idx]
            is_read = it["_key"] in self.read
            sel = idx == self.sel
            date = fmt_date(it.get("_sort", ""))
            feed = it.get("feed_title", "")[:22]
            mark = " " if is_read else "●"
            title = it.get("title", "(untitled)")
            line = f"{mark} {date:>8}  {feed:<22}  {title}"
            attr = curses.A_NORMAL
            if sel:
                attr |= curses.A_REVERSE
            if is_read and not sel:
                attr |= curses.A_DIM
            elif not is_read and not sel:
                attr |= curses.A_BOLD
            self.put(1 + row, 0, line.ljust(w), attr)

        # preview
        py = 1 + listh
        self.scr.hline(py, 0, curses.ACS_HLINE, w)
        if view:
            it = view[self.sel]
            self.put(py + 1, 0, it.get("title", ""), curses.A_BOLD | curses.color_pair(1))
            meta = f"{it.get('feed_title', '')}  ·  {fmt_date(it.get('_sort', ''))}"
            tags = " ".join(f"#{t}" for t in it.get("tags", []))
            if tags:
                meta += "  ·  " + tags
            self.put(py + 2, 0, meta, curses.A_DIM)
            body = it.get("summary", "") or "(no summary)"
            for i, seg in enumerate(textwrap.wrap(body, max(20, w - 2))[:preview_h - 5]):
                self.put(py + 4 + i, 0, seg)
            self.put(py + preview_h - 1, 0, it.get("link", ""), curses.color_pair(2) | curses.A_UNDERLINE)

        # status line
        sl = self.status or "j/k move · Enter open · m read · u unread · t tag · / find · r fetch · q quit"
        self.put(h - 1, 0, sl.ljust(w), curses.A_REVERSE)
        self.scr.refresh()

    # ---- input ------------------------------------------------------
    def prompt(self, label: str) -> str:
        h, w = self.scr.getmaxyx()
        curses.curs_set(1)
        curses.echo()
        self.put(h - 1, 0, (label + " ").ljust(w))
        self.scr.move(h - 1, min(len(label) + 1, w - 2))
        try:
            s = self.scr.getstr(h - 1, len(label) + 1, max(1, w - len(label) - 3)).decode()
        except Exception:
            s = ""
        curses.noecho()
        curses.curs_set(0)
        return s

    def run_fetch(self):
        self.status = "running rssd…"
        self.draw()
        try:
            subprocess.run([sys.executable, RSSD], capture_output=True, timeout=180)
        except Exception as e:
            self.status = f"rssd failed: {e}"
            return
        self.items = load_items()
        self.tags = sorted({t for it in self.items for t in it.get("tags", [])})
        self.status = "reloaded"

    def loop(self):
        while True:
            self.draw()
            try:
                c = self.scr.getch()
            except KeyboardInterrupt:
                return
            self.status = ""
            view = self.view
            if c in (ord("q"), 27):
                return
            elif c in (ord("j"), curses.KEY_DOWN):
                self.sel += 1
            elif c in (ord("k"), curses.KEY_UP):
                self.sel -= 1
            elif c == ord("g"):
                self.sel = 0
            elif c == ord("G"):
                self.sel = len(view) - 1
            elif c == curses.KEY_NPAGE:
                self.sel += 10
            elif c == curses.KEY_PPAGE:
                self.sel -= 10
            elif c in (10, 13, curses.KEY_ENTER, ord("o")):
                if view:
                    it = view[self.sel]
                    open_url(it.get("link", ""))
                    self.read[it["_key"]] = int(time.time())
                    save_read(self.read)
            elif c == ord("m"):
                if view:
                    k = view[self.sel]["_key"]
                    if k in self.read:
                        del self.read[k]
                    else:
                        self.read[k] = int(time.time())
                    save_read(self.read)
            elif c == ord("A"):
                for it in view:
                    self.read[it["_key"]] = int(time.time())
                save_read(self.read)
            elif c == ord("u"):
                self.unread_only = not self.unread_only
            elif c == ord("t"):
                opts = [None] + self.tags
                i = opts.index(self.tag_filter) if self.tag_filter in opts else 0
                self.tag_filter = opts[(i + 1) % len(opts)]
            elif c == ord("/"):
                self.text_filter = self.prompt("find:").strip()
            elif c == ord("r"):
                self.run_fetch()
            self.clamp(self.view)


def main():
    sys.stdout.write("\033]0;rssd reader\007")
    sys.stdout.flush()
    if not ITEMS.exists():
        print("no articles yet - run `rssd` first (or press r inside the reader "
              "once it opens).", file=sys.stderr)
    curses.wrapper(lambda scr: Reader(scr).loop())


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""Parse ~/notes/orgzly/todo.org into a per-day agenda for the quickshell
calendar panel (bar/CalendarExpanded.qml).

Prints one JSON object on stdout:

    {
      "generated": "2026-08-29T23:40:00",
      "source": "/home/user1/notes/orgzly/todo.org",
      "days": {
        "2026-09-01": [
          {"text": "Buy rome hotel", "done": false, "time": "17:30", "kind": "scheduled"}
        ]
      }
    }

kind is one of: scheduled | deadline | timestamp

Placement rules (kept deliberately close to what org-agenda / orgzly show):
  - SCHEDULED / DEADLINE planning stamps land on their date.
  - Plain active <timestamps> in the entry body land on their date.
  - CLOSED stamps and inactive [timestamps] are metadata only, never placed.
  - A repeating stamp (".+1w", "++2d", "+1y" ...) lands on its next
    occurrence on or after today, i.e. the one instance org would surface.

Always exits 0 and always prints valid JSON (empty "days" on any error) so
the QML side never has to special-case a failure.
"""

import json
import os
import re
import sys
from datetime import date, datetime, timedelta

ORG = os.path.expanduser("~/notes/orgzly/todo.org")

HEADING_RE = re.compile(r"^(\*+)\s+(.*)$")
DONE_KEYWORDS = {"DONE", "CANCELLED", "CANCELED"}
TODO_KEYWORDS = {"TODO", "NEXT", "WAITING", "HOLD", "SOMEDAY", "STARTED"} | DONE_KEYWORDS

# A single org timestamp, active <...> or inactive [...].
#   <2026-09-01 Tue 17:30 .+1w -1d>
TS_RE = re.compile(
    r"([<\[])"
    r"(\d{4})-(\d{2})-(\d{2})"
    r"(?:\s+[^\s\d>\]]+)?"                 # day name (any non-numeric word)
    r"(?:\s+(\d{2}):(\d{2}))?"             # start time
    r"(?:-\d{2}:\d{2})?"                   # end time of a range
    r"(?:\s+(?:\.\+|\+\+|\+)(\d+)([hdwmy]))?"  # repeater
    r"(?:\s+-\d+[hdwmy])?"                 # warning period
    r"\s*([>\]])"
)

PLANNING_RE = re.compile(
    r"(SCHEDULED|DEADLINE|CLOSED):\s*(<[^>]*>|\[[^\]]*\])"
)


def add_interval(d: date, n: int, unit: str) -> date:
    if unit == "h":
        return d
    if unit == "d":
        return d + timedelta(days=n)
    if unit == "w":
        return d + timedelta(weeks=n)
    if unit == "m":
        idx = d.month - 1 + n
        year = d.year + idx // 12
        return date(year, idx % 12 + 1, min(d.day, 28))
    if unit == "y":
        try:
            return d.replace(year=d.year + n)
        except ValueError:  # Feb 29
            return d.replace(year=d.year + n, day=28)
    return d + timedelta(days=n)


def next_occurrence(d: date, n: int, unit: str, today: date) -> date:
    guard = 0
    while d < today and guard < 6000:
        nxt = add_interval(d, n, unit)
        if nxt <= d:
            break
        d = nxt
        guard += 1
    return d


def clean_title(title: str) -> str:
    parts = title.split(None, 1)
    done = False
    if parts and parts[0] in TODO_KEYWORDS:
        done = parts[0] in DONE_KEYWORDS
        title = parts[1] if len(parts) > 1 else ""
    title = re.sub(r"^\[#[A-Z]\]\s*", "", title)          # priority cookie
    title = re.sub(r"\s+:[\w@#%:]+:\s*$", "", title)      # trailing :tags:
    title = re.sub(r"\s+\[\d+%\]\s*$", "", title)         # [50%] cookie
    title = re.sub(r"\s+\[\d+/\d+\]\s*$", "", title)      # [2/5] cookie
    return title.strip(), done


def parse_ts(text: str):
    m = TS_RE.search(text)
    if not m:
        return None
    bracket, y, mo, da, hh, mm, rep_n, rep_u, _close = m.groups()
    try:
        d = date(int(y), int(mo), int(da))
    except ValueError:
        return None
    time_str = f"{hh}:{mm}" if hh else None
    rep = (int(rep_n), rep_u) if rep_n else None
    return bracket, d, time_str, rep


def main() -> None:
    result = {
        "generated": datetime.now().isoformat(timespec="seconds"),
        "source": ORG,
        "days": {},
    }
    today = date.today()

    try:
        with open(ORG, encoding="utf-8", errors="replace") as fh:
            lines = fh.readlines()
    except OSError:
        json.dump(result, sys.stdout)
        return

    days = result["days"]
    title = None
    done = False

    def emit(d: date, time_str, kind: str) -> None:
        key = d.isoformat()
        bucket = days.setdefault(key, [])
        for rec in bucket:
            if rec["text"] == title and rec["time"] == time_str and rec["kind"] == kind:
                return
        bucket.append({"text": title, "done": done, "time": time_str, "kind": kind})

    for raw in lines:
        line = raw.rstrip("\n")

        hm = HEADING_RE.match(line)
        if hm:
            title, done = clean_title(hm.group(2).strip())
            continue
        if title is None:
            continue

        stripped = line.lstrip()
        if stripped.startswith(("SCHEDULED:", "DEADLINE:", "CLOSED:", "SCHEDULED ", "DEADLINE ")):
            for kw, ts in PLANNING_RE.findall(line):
                if kw == "CLOSED":
                    continue
                parsed = parse_ts(ts)
                if not parsed:
                    continue
                _bracket, d, time_str, rep = parsed
                if rep:
                    d = next_occurrence(d, rep[0], rep[1], today)
                emit(d, time_str, "deadline" if kw == "DEADLINE" else "scheduled")
            continue

        # Body line: only plain active <timestamps> get placed.
        for m in TS_RE.finditer(line):
            if m.group(1) != "<":
                continue
            parsed = parse_ts(m.group(0))
            if not parsed:
                continue
            _bracket, d, time_str, rep = parsed
            if rep:
                d = next_occurrence(d, rep[0], rep[1], today)
            emit(d, time_str, "timestamp")

    # Keep the window the calendar realistically shows: roughly a year back
    # (scroll-back history) through a few years forward. Bounds the payload
    # no matter how large todo.org grows.
    lo = (today - timedelta(days=400)).isoformat()
    hi = (today + timedelta(days=1500)).isoformat()
    for key in [k for k in days if k < lo or k > hi]:
        del days[key]

    for bucket in days.values():
        bucket.sort(key=lambda r: (r["time"] or "", r["done"], r["text"].lower()))

    json.dump(result, sys.stdout)


if __name__ == "__main__":
    main()

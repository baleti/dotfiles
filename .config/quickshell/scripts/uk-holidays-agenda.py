#!/usr/bin/env python3
"""UK public holidays for the quickshell calendar panel
(bar/CalendarExpanded.qml), sourced from Google's public UK holiday
calendar (no auth needed - anyone can fetch this feed).

Prints one JSON object on stdout, same shape as org-agenda.py's:

    {
      "generated": "2026-08-30T23:40:00",
      "source": "UK Holidays",
      "days": {
        "2026-08-31": [
          {"text": "Summer Bank Holiday (regional holiday)", "done": false, "time": null, "kind": "holiday"}
        ]
      }
    }

Cached to ~/.cache/uk-holidays-agenda.json for 24h (public holidays
change at most a few times a year, and this avoids hitting Google's
servers every time the panel opens / every 5-minute refresh). A fetch
failure falls back to the last good cache, then to an empty result -
always exits 0 and always prints valid JSON so the QML side never has
to special-case a failure, same contract as org-agenda.py.
"""

import json
import os
import re
import sys
import time
import urllib.request
from datetime import date, datetime, timedelta

FEED_URL = "https://calendar.google.com/calendar/ical/en.uk%23holiday%40group.v.calendar.google.com/public/basic.ics"
CACHE = os.path.expanduser("~/.cache/uk-holidays-agenda.json")
CACHE_TTL = 24 * 60 * 60

EVENT_RE = re.compile(r"BEGIN:VEVENT(.*?)END:VEVENT", re.S)
DTSTART_RE = re.compile(r"DTSTART;VALUE=DATE:(\d{4})(\d{2})(\d{2})")
SUMMARY_RE = re.compile(r"SUMMARY:(.*)")


def unfold(text: str) -> str:
    # RFC5545 line folding: a continuation line starts with a space.
    return re.sub(r"\r?\n[ \t]", "", text)


def parse_ics(text: str) -> dict:
    days: dict = {}
    text = unfold(text)
    today = date.today()
    lo = today - timedelta(days=400)
    hi = today + timedelta(days=1500)
    for block in EVENT_RE.findall(text):
        m = DTSTART_RE.search(block)
        s = SUMMARY_RE.search(block)
        if not m or not s:
            continue
        d = date(int(m.group(1)), int(m.group(2)), int(m.group(3)))
        if d < lo or d > hi:
            continue
        summary = s.group(1).strip().replace("\\,", ",").replace("\\;", ";")
        key = d.isoformat()
        days.setdefault(key, []).append(
            {"text": summary, "done": False, "time": None, "kind": "holiday"}
        )
    return days


def load_cache():
    try:
        with open(CACHE, encoding="utf-8") as fh:
            cached = json.load(fh)
        if time.time() - cached.get("fetched_at", 0) < CACHE_TTL:
            return cached["days"]
    except (OSError, ValueError, KeyError):
        pass
    return None


def load_stale_cache():
    try:
        with open(CACHE, encoding="utf-8") as fh:
            return json.load(fh).get("days", {})
    except (OSError, ValueError, KeyError):
        return {}


def save_cache(days: dict) -> None:
    try:
        os.makedirs(os.path.dirname(CACHE), exist_ok=True)
        with open(CACHE, "w", encoding="utf-8") as fh:
            json.dump({"fetched_at": time.time(), "days": days}, fh)
    except OSError:
        pass


def main() -> None:
    result = {
        "generated": datetime.now().isoformat(timespec="seconds"),
        "source": "UK Holidays",
        "days": {},
    }

    days = load_cache()
    if days is None:
        try:
            req = urllib.request.Request(FEED_URL, headers={"User-Agent": "quickshell-calendar/1.0"})
            with urllib.request.urlopen(req, timeout=5) as resp:
                text = resp.read().decode("utf-8", errors="replace")
            days = parse_ics(text)
            save_cache(days)
        except Exception:
            days = load_stale_cache()

    result["days"] = days
    json.dump(result, sys.stdout)


if __name__ == "__main__":
    main()

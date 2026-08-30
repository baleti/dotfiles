#!/usr/bin/env python3
"""the personal Gmail account's primary Google Calendar for the quickshell
calendar panel (bar/CalendarExpanded.qml). Same JSON output shape as
org-agenda.py, tagged "kind": "google" so the QML side can render it
distinctly from org-agenda/UK-holiday entries.

Credentials: ~/.config/claude-calendar/accounts/krajnik.dan/
  client_secret.json + token-calendar.json (calendar scope, long-lived
  refresh token - see ~/.config/docs/google-cloud-oauth.md).

Always exits 0 and always prints valid JSON (empty "days" on any
error - missing/invalid credentials, network failure, API error) so
the QML side never has to special-case a failure, same contract as
org-agenda.py.
"""

import json
import os
import sys
import urllib.error
import urllib.parse
import urllib.request
from datetime import date, datetime, timedelta

ACCOUNT_DIR = os.path.expanduser("~/.config/claude-calendar/accounts/krajnik.dan")
CLIENT_SECRET = os.path.join(ACCOUNT_DIR, "client_secret.json")
TOKEN = os.path.join(ACCOUNT_DIR, "token-calendar.json")

# Narrower window than org-agenda.py's ~5-year span - a calendar feed
# that wide isn't useful in a small widget.
WINDOW_PAST_DAYS = 30
WINDOW_FUTURE_DAYS = 180


def get_access_token() -> str:
    with open(CLIENT_SECRET, encoding="utf-8") as fh:
        client = json.load(fh)["installed"]
    with open(TOKEN, encoding="utf-8") as fh:
        tok = json.load(fh)

    data = urllib.parse.urlencode({
        "refresh_token": tok["refresh_token"],
        "client_id": client["client_id"],
        "client_secret": client["client_secret"],
        "grant_type": "refresh_token",
    }).encode()
    req = urllib.request.Request(tok["token_uri"], data=data, method="POST")
    with urllib.request.urlopen(req, timeout=5) as resp:
        return json.load(resp)["access_token"]


def fetch_events(access_token: str) -> list:
    today = date.today()
    time_min = (today - timedelta(days=WINDOW_PAST_DAYS)).isoformat() + "T00:00:00Z"
    time_max = (today + timedelta(days=WINDOW_FUTURE_DAYS)).isoformat() + "T00:00:00Z"
    params = urllib.parse.urlencode({
        "timeMin": time_min,
        "timeMax": time_max,
        "singleEvents": "true",
        "orderBy": "startTime",
        "maxResults": "250",
    })
    url = f"https://www.googleapis.com/calendar/v3/calendars/primary/events?{params}"
    req = urllib.request.Request(url, headers={"Authorization": f"Bearer {access_token}"})
    with urllib.request.urlopen(req, timeout=5) as resp:
        return json.load(resp).get("items", [])


def main() -> None:
    result = {
        "generated": datetime.now().isoformat(timespec="seconds"),
        "source": "Google Calendar",
        "days": {},
    }

    try:
        access_token = get_access_token()
        events = fetch_events(access_token)
    except (OSError, urllib.error.URLError, KeyError, ValueError, TimeoutError):
        json.dump(result, sys.stdout)
        return

    days = result["days"]
    for ev in events:
        if ev.get("status") == "cancelled":
            continue
        start = ev.get("start", {})
        date_str = start.get("date")  # all-day event
        datetime_str = start.get("dateTime")  # timed event
        if date_str:
            key = date_str
            time_str = None
        elif datetime_str:
            # "2026-08-31T14:00:00+01:00" -> date part + local HH:MM
            key = datetime_str[:10]
            time_str = datetime_str[11:16]
        else:
            continue
        days.setdefault(key, []).append({
            "text": ev.get("summary", "(no title)"),
            "done": False,
            "time": time_str,
            "kind": "google",
        })

    for bucket in days.values():
        bucket.sort(key=lambda r: r["time"] or "")

    json.dump(result, sys.stdout)


if __name__ == "__main__":
    main()

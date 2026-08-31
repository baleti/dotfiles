#!/usr/bin/env python3
"""Polls Anthropic's account-usage endpoint for this machine's Claude Code
accounts (~/.claude, ~/.claude2, ~/.claude3) and writes one combined
snapshot for the quickshell bar to read.

This is the same endpoint the `claude` CLI itself calls for `/usage` --
GET https://api.anthropic.com/api/oauth/usage, Bearer-authenticated with
the OAuth access token already sitting in each account's
.credentials.json. It is not a documented public API, just the client's
own account-info call, made with credentials the user already holds.

No OAuth refresh is implemented here on purpose: each account already has
live `claude` CLI sessions that keep .credentials.json refreshed on their
own (access tokens are short-lived, ~8h, refreshed continuously by normal
use). This daemon just re-reads the file fresh every cycle and skips an
account for that cycle on an auth failure, rather than reimplementing the
refresh flow and taking on new places to mishandle a refresh token.

Poll interval adapts to how likely anyone is to be watching the bar:
  - a monitor is DPMS-off, or the session is locked   -> hourly
  - a transcript under ~/.claude*/projects was written
    in the last ACTIVITY_WINDOW seconds                -> every 30s
  - otherwise (screen on, nothing actively generating)  -> every 5 minutes

State is written atomically to ~/.cache/claude-usage/state.json.
"""
import json
import subprocess
import time
import urllib.error
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

ACCOUNTS = [
    ("claude", Path.home() / ".claude"),
    ("claude2", Path.home() / ".claude2"),
    ("claude3", Path.home() / ".claude3"),
]

STATE_DIR = Path.home() / ".cache" / "claude-usage"
STATE_FILE = STATE_DIR / "state.json"

USAGE_URL = "https://api.anthropic.com/api/oauth/usage"

INTERVAL_LOCKED = 3600
INTERVAL_ACTIVE = 30
INTERVAL_IDLE = 300
ACTIVITY_WINDOW = 90
# How often the main loop wakes to re-evaluate which tier it's in --
# independent of INTERVAL_ACTIVE so a screen-off transition mid-idle-wait is
# noticed promptly instead of only at the next scheduled fetch.
CHECK_GRANULARITY = 15


def is_screen_off_or_locked() -> bool:
    try:
        out = subprocess.run(
            ["hyprctl", "-j", "monitors"],
            capture_output=True, timeout=3, text=True, check=True,
        )
        mons = json.loads(out.stdout)
        if any(not m.get("dpmsStatus", True) for m in mons):
            return True
    except Exception:
        pass
    try:
        out = subprocess.run(
            ["loginctl", "show-session", "self", "-p", "LockedHint", "--value"],
            capture_output=True, timeout=3, text=True, check=True,
        )
        if out.stdout.strip() == "yes":
            return True
    except Exception:
        pass
    return False


def is_actively_using() -> bool:
    cutoff = time.time() - ACTIVITY_WINDOW
    for _, base in ACCOUNTS:
        projects = base / "projects"
        if not projects.is_dir():
            continue
        try:
            for jsonl in projects.glob("*/*.jsonl"):
                if jsonl.stat().st_mtime >= cutoff:
                    return True
        except OSError:
            continue
    return False


def current_tier() -> tuple[str, int]:
    if is_screen_off_or_locked():
        return "locked", INTERVAL_LOCKED
    if is_actively_using():
        return "active", INTERVAL_ACTIVE
    return "idle", INTERVAL_IDLE


def fetch_usage(cred_path: Path) -> dict:
    try:
        creds = json.loads(cred_path.read_text())
        token = creds["claudeAiOauth"]["accessToken"]
    except Exception as e:
        return {"error": f"no credentials ({e.__class__.__name__})"}

    req = urllib.request.Request(
        USAGE_URL,
        headers={
            "Authorization": f"Bearer {token}",
            "Content-Type": "application/json",
        },
    )
    try:
        with urllib.request.urlopen(req, timeout=8) as r:
            data = json.load(r)
    except urllib.error.HTTPError as e:
        return {"error": f"http {e.code}"}
    except Exception as e:
        return {"error": f"{e.__class__.__name__}: {e}"}

    limits = {item.get("kind"): item for item in (data.get("limits") or [])}
    session = limits.get("session")
    weekly = limits.get("weekly_all")
    return {
        "session_pct": session.get("percent") if session else None,
        "session_resets_at": session.get("resets_at") if session else None,
        "weekly_pct": weekly.get("percent") if weekly else None,
        "weekly_resets_at": weekly.get("resets_at") if weekly else None,
        "fetched_at": datetime.now(timezone.utc).isoformat(),
    }


def write_state(accounts_data: list, mode: str, interval: int) -> None:
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    payload = {
        "accounts": accounts_data,
        "poll_mode": mode,
        "poll_interval_s": interval,
        "updated_at": datetime.now(timezone.utc).isoformat(),
    }
    tmp = STATE_FILE.with_suffix(".json.tmp")
    tmp.write_text(json.dumps(payload, indent=2))
    tmp.replace(STATE_FILE)


def main() -> None:
    next_fetch = 0.0
    while True:
        mode, interval = current_tier()
        now = time.time()
        if now >= next_fetch:
            accounts_data = []
            for name, base in ACCOUNTS:
                result = fetch_usage(base / ".credentials.json")
                result["account"] = name
                accounts_data.append(result)
            write_state(accounts_data, mode, interval)
            next_fetch = now + interval
        time.sleep(CHECK_GRANULARITY)


if __name__ == "__main__":
    main()

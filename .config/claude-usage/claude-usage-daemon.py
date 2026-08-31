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
    in the last ACTIVITY_WINDOW seconds                -> every 2 minutes
  - otherwise (screen on, nothing actively generating)  -> every 5 minutes

2026-08-31: the initial version used a 30s "active" interval and fired all
3 accounts back-to-back with no spacing. That tripped a 429 on this
endpoint within ~30 minutes of continuous "active" use, on all 3 accounts
simultaneously -- which points at an IP-wide limit, not a per-account one.
Fixed by widening ACTIVE to 2 minutes, staggering the 3 accounts'
requests, and adding real backoff below: a 429 now suspends ALL polling
(not just the account that got it) for a while, growing exponentially on
repeated 429s and respecting a Retry-After header when the response sends
one. A 429/other error also no longer blanks out that account's last-known
numbers in state.json -- it carries the last good reading forward, flagged
"stale", so the bar doesn't just go blank/red on every hiccup.

State is written atomically to ~/.cache/claude-usage/state.json.
"""
import json
import subprocess
import sys
import time
import urllib.error
import urllib.request
from datetime import datetime, timezone
from email.utils import parsedate_to_datetime
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
INTERVAL_ACTIVE = 120
INTERVAL_IDLE = 300
ACTIVITY_WINDOW = 90
# How often the main loop wakes to re-evaluate which tier it's in --
# independent of INTERVAL_ACTIVE so a screen-off transition mid-idle-wait is
# noticed promptly instead of only at the next scheduled fetch.
CHECK_GRANULARITY = 15
# Gap between each account's own request within one fetch cycle, so 3
# accounts never look like one 3-request burst to whatever's rate-limiting
# this endpoint.
ACCOUNT_STAGGER = 5

# Backoff after a 429: at least this long, or the response's own
# Retry-After if that's longer, doubling on each further 429 hit before the
# backoff has cleared (capped at MAX_BACKOFF).
BACKOFF_MIN = 600
BACKOFF_MAX = 3600


def log(msg: str) -> None:
    print(f"[{datetime.now(timezone.utc).isoformat()}] {msg}", flush=True)


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


def parse_retry_after(headers) -> float | None:
    raw = headers.get("Retry-After")
    if not raw:
        return None
    try:
        return float(raw)
    except ValueError:
        pass
    try:
        dt = parsedate_to_datetime(raw)
        return max(0.0, (dt - datetime.now(dt.tzinfo)).total_seconds())
    except Exception:
        return None


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
        result = {"error": f"http {e.code}", "http_status": e.code}
        if e.code == 429:
            result["retry_after"] = parse_retry_after(e.headers)
        return result
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
    log("claude-usage-daemon starting")
    next_fetch = 0.0
    backoff_until = 0.0
    consecutive_429 = 0
    # account name -> last successful fetch_usage() result (no "account" key)
    last_good: dict[str, dict] = {}

    while True:
        now = time.time()
        if now < backoff_until:
            time.sleep(CHECK_GRANULARITY)
            continue

        mode, interval = current_tier()
        if now < next_fetch:
            time.sleep(CHECK_GRANULARITY)
            continue

        accounts_data = []
        hit_429 = False
        retry_after_max = 0.0
        for i, (name, base) in enumerate(ACCOUNTS):
            if i > 0:
                time.sleep(ACCOUNT_STAGGER)
            result = fetch_usage(base / ".credentials.json")

            if result.get("http_status") == 429:
                hit_429 = True
                retry_after_max = max(retry_after_max, result.get("retry_after") or 0.0)

            if "error" in result:
                prev = last_good.get(name)
                row = dict(prev) if prev else {}
                row["account"] = name
                row["error"] = result["error"]
                row["stale"] = prev is not None
                accounts_data.append(row)
                if result["error"] != "http 429":
                    log(f"{name}: {result['error']}")
            else:
                result["account"] = name
                last_good[name] = {k: v for k, v in result.items() if k != "account"}
                accounts_data.append(result)

        if hit_429:
            consecutive_429 += 1
            backoff_s = min(
                BACKOFF_MAX,
                max(BACKOFF_MIN, retry_after_max) * (2 ** (consecutive_429 - 1)),
            )
            backoff_until = time.time() + backoff_s
            mode = "backoff"
            interval = int(backoff_s)
            log(f"hit 429 (consecutive={consecutive_429}), backing off {backoff_s:.0f}s")
        else:
            consecutive_429 = 0

        write_state(accounts_data, mode, interval)
        next_fetch = time.time() + interval


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        sys.exit(0)

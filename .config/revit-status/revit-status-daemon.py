#!/usr/bin/env python3
"""Keeps ~/.cache/revit-status/state.json current: one row per Revit instance reachable through the revit-ballet agents
(`revit-remote status`), for the quickshell CTRL+ALT+r panel (bar/RevitStatusExpanded.qml), which only reads that file -- so the panel
shows the last known view the instant it opens instead of waiting ~3 s for an ssh probe.

A probe costs ssh round trips into every VM, so the interval adapts the way claude-usage-daemon's does:
  - a monitor is DPMS-off, or the session is locked          -> every 10 min
  - the panel is open (it touches ~/.cache/revit-status/watch every few seconds while open) -> every 5 s (probe-bound, ~3 s each)
  - something changed within the last 10 min (instance came/went, state/dialog/queue/engine changed) -> every 30 s
  - otherwise (screen on, nothing moving)                    -> every 2 min
  - every probe that fails outright (ssh to the VM host down) doubles the wait up to 10 min, resetting on the next success
Waits are taken in 1 s slices so opening the panel (or the screen coming back on) cuts an idle wait short.
"""
import importlib.machinery
import importlib.util
import json
import os
import subprocess
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

STATE_DIR = Path.home() / ".cache" / "revit-status"
STATE_FILE = STATE_DIR / "state.json"
WATCH_FILE = STATE_DIR / "watch"
REMOTE = Path(os.environ.get("REVIT_BALLET_REPO", str(Path.home() / "src" / "revit-ballet"))) / "tools" / "remote" / "revit-remote"

INTERVAL_LOCKED = 600
INTERVAL_WATCHED = 5
INTERVAL_ACTIVE = 30
INTERVAL_IDLE = 120
MAX_BACKOFF = 600
WATCH_WINDOW = 20      # the panel counts as open while the watch file is newer than this
ACTIVE_WINDOW = 600    # "something changed" lingers this long


def log(msg):
    print(msg, file=sys.stderr, flush=True)


def load_remote():
    l = importlib.machinery.SourceFileLoader("revit_remote", str(REMOTE.resolve()))
    spec = importlib.util.spec_from_loader("revit_remote", l)
    mod = importlib.util.module_from_spec(spec)
    l.exec_module(mod)
    return mod


def screen_off_or_locked():
    try:
        mons = json.loads(subprocess.run(["hyprctl", "-j", "monitors"], capture_output=True, timeout=3, text=True, check=True).stdout)
        if any(not m.get("dpmsStatus", True) for m in mons):
            return True
    except Exception:
        pass
    try:
        out = subprocess.run(["loginctl", "show-session", "self", "-p", "LockedHint", "--value"], capture_output=True, timeout=3, text=True, check=True)
        if out.stdout.strip() == "yes":
            return True
    except Exception:
        pass
    return False


def watched():
    try:
        return time.time() - WATCH_FILE.stat().st_mtime < WATCH_WINDOW
    except OSError:
        return False


def signature(rows):
    """What counts as 'something changed': the identity and live state of every instance."""
    return sorted(json.dumps([r.get("target"), r.get("port"), r.get("pid"), r.get("state"), r.get("dialog"), r.get("running"),
                              r.get("queued"), r.get("active_engine"), r.get("responsive")]) for r in rows)


def write_state(rows, mode, interval, ok):
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    payload = {"rows": rows, "poll_mode": mode, "poll_interval_s": interval, "ok": ok,
               "updated_at": datetime.now(timezone.utc).isoformat(), "updated_ms": int(time.time() * 1000)}
    tmp = STATE_FILE.with_suffix(".json.tmp")
    tmp.write_text(json.dumps(payload))
    tmp.replace(STATE_FILE)


def probe(rr):
    cfg = rr.load_config()
    targets = rr.expand_targets(cfg)
    probes = rr.probe_all(targets, commands=False)
    rows = rr.build_status_rows(probes, targets)
    # every target failing (the VM host itself is unreachable) is a failed probe, not a legitimate "nothing running"
    ok = not (rows and all(not r.get("instance") and r.get("state") == "unreachable" for r in rows))
    return rows, ok


def main():
    rr = load_remote()
    last_sig = None
    last_change = 0.0
    failures = 0
    last_rows = []
    while True:
        try:
            rows, ok = probe(rr)
        except Exception as e:  # never die: the next cycle retries
            log("probe failed: %r" % (e,))
            rows, ok = last_rows, False
        if ok:
            failures = 0
            sig = signature(rows)
            if sig != last_sig:
                last_sig, last_change = sig, time.time()
            last_rows = rows
        else:
            failures += 1
            rows = last_rows or rows   # keep showing the last good view; the panel dims it via `ok`

        def tier():
            if screen_off_or_locked():
                return "locked", INTERVAL_LOCKED
            if watched():
                return "watched", INTERVAL_WATCHED
            if time.time() - last_change < ACTIVE_WINDOW:
                return "active", INTERVAL_ACTIVE
            return "idle", INTERVAL_IDLE

        mode, interval = tier()
        if failures:
            mode, interval = "backoff", min(MAX_BACKOFF, max(interval, 15) * 2 ** min(failures, 6))
        write_state(rows, mode, interval, ok)
        # wait in 1 s slices; the panel opening or the tier dropping to a shorter interval ends the wait early
        waited = 0
        while waited < interval:
            time.sleep(1)
            waited += 1
            m2, i2 = tier()
            if not failures and i2 < interval - waited + 1 and i2 <= waited:
                break


if __name__ == "__main__":
    main()

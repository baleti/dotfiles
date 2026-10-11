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
Each row also carries `claude`: the live Claude Code session that last ran a command naming that VM (ClaudeXref).
Waits are taken in 1 s slices so opening the panel (or the screen coming back on) cuts an idle wait short.
"""
import importlib.machinery
import importlib.util
import json
import os
import re
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


CLAUDE_STATE = Path.home() / ".cache" / "claude-usage" / "state.json"
CLAUDE_BASES = {"claude": Path.home() / ".claude", "claude2": Path.home() / ".claude2", "claude3": Path.home() / ".claude3"}


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


class ClaudeXref:
    """Which live Claude Code session last drove each VM: scans the new tail of every live session's transcript (the sessions claude-usage-daemon
    lists, so title and tmux ids come with them) for tool calls that name the VM -- its cid ("cid20", "guest-cid=20", "VSOCK-CONNECT:20",
    "rdp-windows-vm 20") or its qemu name -- and keeps the newest hit per VM. A heuristic: a command that merely mentions the VM counts."""

    def __init__(self):
        self.files = {}          # transcript path -> {"offset": int, "hits": {target: iso-ts}}
        self.vm_key = None
        self.pats = {}

    @staticmethod
    def patterns(rows):
        pats = {}
        for r in rows:
            if r["target"] in pats:
                continue
            parts = []
            if r.get("cid") is not None:
                c = int(r["cid"])
                parts += [r"(?<!\w)cid[ =:_-]?%d(?!\d)" % c, r"guest-cid=%d(?!\d)" % c, r"VSOCK-CONNECT:%d(?!\d)" % c,
                          r"vsock%d(?!\d)" % c, r"rdp-windows-vm %d(?!\d)" % c]
            if r.get("vm"):
                parts.append(re.escape(r["vm"]))
            if parts:
                pats[r["target"]] = re.compile("|".join(parts), re.I)
        return pats

    @staticmethod
    def live_sessions():
        try:
            d = json.loads(CLAUDE_STATE.read_text())
        except Exception:
            return []
        out = []
        for acct, ss in (d.get("sessions") or {}).items():
            for s in ss:
                if s.get("session_id") and acct in CLAUDE_BASES:
                    out.append(dict(s, account=acct))
        return out

    def scan(self, path, rec):
        try:
            size = path.stat().st_size
        except OSError:
            return
        if size < rec["offset"]:
            rec["offset"], rec["hits"] = 0, {}
        if size == rec["offset"]:
            return
        with open(path, "rb") as f:
            f.seek(rec["offset"])
            data = f.read(size - rec["offset"])
        end = data.rfind(b"\n") + 1          # only whole lines; a half-written last line is read next time
        rec["offset"] += end
        for line in data[:end].decode("utf-8", "replace").splitlines():
            if '"type":"tool_use"' not in line:
                continue
            m = re.search(r'"timestamp":"([^"]+)"', line)
            ts = m.group(1) if m else ""
            for target, pat in self.pats.items():
                if pat.search(line) and ts > rec["hits"].get(target, ""):
                    rec["hits"][target] = ts

    def attach(self, rows):
        pats = self.patterns(rows)
        key = tuple(sorted((t, p.pattern) for t, p in pats.items()))
        if key != self.vm_key:          # a VM appeared/went: the old per-file hits no longer cover the new patterns
            self.vm_key, self.pats, self.files = key, pats, {}
        best = {}                        # target -> (ts, session)
        for sess in self.live_sessions():
            path = next(iter((CLAUDE_BASES[sess["account"]] / "projects").glob("*/%s.jsonl" % sess["session_id"])), None)
            if path is None:
                continue
            rec = self.files.setdefault(str(path), {"offset": 0, "hits": {}})
            self.scan(path, rec)
            for target, ts in rec["hits"].items():
                if target not in best or ts > best[target][0]:
                    best[target] = (ts, sess)
        for r in rows:
            hit = best.get(r["target"])
            if hit:
                s = hit[1]
                r["claude"] = {"title": re.sub(r"^[^\w(\[]+\s*", "", s.get("title") or ""), "account": s["account"], "status": s.get("status") or "",
                               "tmux_session": s.get("tmux_session") or "", "tmux_window": s.get("tmux_window") or "",
                               "tmux_pane": s.get("tmux_pane") or "", "ts": hit[0]}
            else:
                r["claude"] = None
        return rows


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
    xref = ClaudeXref()
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
        try:
            rows = xref.attach(rows)
        except Exception as e:
            log("claude cross-reference failed: %r" % (e,))
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

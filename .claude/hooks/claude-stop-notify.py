#!/usr/bin/env python3
"""
Stop hook: fire a desktop notification when a Claude Code session finishes
responding to a turn, unless the window already running that session is
currently focused (no point interrupting something you're already looking
at).

Every external call is wrapped so a failure anywhere just skips notifying
rather than raising -- this must never block or delay the real Stop event,
same convention as ~/.claude/hooks/block-unbounded-scan.py.

v1 scope: only sessions running inside tmux are handled (the norm on this
host). A session with no resolvable tmux session name (bare terminal, no
tmux) is silently skipped -- see the tmux-agents-desktop-notify plan for
why click-to-focus needs the tmux path either way.

Click handling (focus the window, or attach a new terminal if the tmux
session has no live window) lives in
~/.config/hypr/scripts/notify-summon.sh's "claude-stop:" branch, keyed off
this script's notify-send -a value.
"""
import glob
import json
import os
import subprocess
import sys

MATCH_SCRIPT = os.path.expanduser(
    "~/.config/hypr/scripts/lib/tmux-window-match.py"
)
DEBUG_FLAG = os.path.expanduser("~/.cache/claude-stop-notify-debug")
DEBUG_LOG = os.path.expanduser("~/.cache/claude-stop-notify-debug.log")
SESSION_MAP_CACHE = os.path.expanduser("~/.cache/claude-stop-notify-session-map.json")
BODY_BUDGET = 200
TAIL_INITIAL_BYTES = 65536
TAIL_MAX_BYTES = 8 * 1024 * 1024


def debug_log(msg):
    try:
        if not os.path.exists(DEBUG_FLAG):
            return
        with open(DEBUG_LOG, "a") as f:
            f.write(f"[pid={os.getpid()}] {msg}\n")
    except OSError:
        pass


def _load_session_map_cache():
    try:
        with open(SESSION_MAP_CACHE) as f:
            return json.load(f)
    except (OSError, json.JSONDecodeError):
        return {}


def _save_session_map_cache(cache):
    try:
        tmp = f"{SESSION_MAP_CACHE}.tmp{os.getpid()}"
        with open(tmp, "w") as f:
            json.dump(cache, f)
        os.replace(tmp, SESSION_MAP_CACHE)
    except OSError:
        pass


def _tmux_and_name(sf):
    tmux = sf.get("tmux")
    if not tmux:
        return None, sf.get("name")
    return tmux.split(":", 1)[0], sf.get("name")


def resolve_tmux_session(session_id):
    """Session name from this session_id's own ~/.claude*/sessions/<pid>.json
    'tmux' field ("<session>:@<win>.%<pane>"), or None.

    A session fires this hook once per turn, always with the same
    session_id, so a persistent sessionId->path cache turns every
    invocation after the first into a single small file read instead of
    a glob + JSON-parse of every registry file on the host (100+ once
    stub/background sessions accumulate)."""
    cache = _load_session_map_cache()
    cached_path = cache.get(session_id)
    if cached_path:
        try:
            with open(cached_path) as f:
                sf = json.load(f)
            if sf.get("sessionId") == session_id:
                return _tmux_and_name(sf)
        except (OSError, json.JSONDecodeError):
            pass  # stale entry -- fall through to a full rescan

    new_cache = {}
    result = (None, None)
    for path in glob.glob(os.path.expanduser("~/.claude*/sessions/*.json")):
        try:
            with open(path) as f:
                sf = json.load(f)
        except (OSError, json.JSONDecodeError):
            continue
        sid = sf.get("sessionId")
        if not sid:
            continue
        new_cache[sid] = path
        if sid == session_id:
            result = _tmux_and_name(sf)
    _save_session_map_cache(new_cache)
    return result


def resolve_tmux_session_from_env():
    """Fallback for the (currently unverified) case where the hook
    subprocess inherits $TMUX_PANE from its parent Claude process."""
    pane = os.environ.get("TMUX_PANE")
    if not pane:
        return None
    try:
        out = subprocess.run(
            ["tmux", "display-message", "-p", "-t", pane, "#{session_name}"],
            capture_output=True, text=True, timeout=2,
        )
    except (OSError, subprocess.TimeoutExpired):
        return None
    if out.returncode != 0:
        return None
    name = out.stdout.strip()
    return name or None


def matched_window_address(session_name):
    try:
        out = subprocess.run(
            [sys.executable, MATCH_SCRIPT, session_name],
            capture_output=True, text=True, timeout=3,
        )
    except (OSError, subprocess.TimeoutExpired):
        return None
    if out.returncode != 0:
        return None
    addr = out.stdout.strip()
    return addr or None


def active_window_address():
    try:
        out = subprocess.run(
            ["hyprctl", "activewindow", "-j"],
            capture_output=True, text=True, timeout=2,
        )
        return json.loads(out.stdout).get("address")
    except Exception:
        return None


def _tail_text(path, num_bytes):
    """Last num_bytes of path, decoded, with a possibly-partial leading
    line dropped. Avoids loading multi-MB transcripts fully into memory."""
    try:
        total = os.path.getsize(path)
    except OSError:
        return "", 0
    read_size = min(num_bytes, total)
    try:
        with open(path, "rb") as f:
            f.seek(total - read_size)
            data = f.read()
    except OSError:
        return "", total
    if read_size < total and b"\n" in data:
        data = data.split(b"\n", 1)[1]
    return data.decode("utf-8", "replace"), total


def stop_fields(transcript_path):
    """Most recent ai-title and assistant text, in a single reversed pass
    over a growing tail of the transcript (instead of two separate full-file
    reads) -- the fields we want are always near the end of the file, so
    this only reads the whole thing on the rare transcript where they
    aren't found within TAIL_MAX_BYTES."""
    read_size = TAIL_INITIAL_BYTES
    while True:
        text, total = _tail_text(transcript_path, read_size)
        title = None
        body = ""
        for line in reversed(text.splitlines()):
            try:
                v = json.loads(line)
            except json.JSONDecodeError:
                continue
            vtype = v.get("type")
            if title is None and vtype == "ai-title":
                title = v.get("aiTitle")
            elif not body and vtype == "assistant":
                content = v.get("message", {}).get("content")
                if isinstance(content, str):
                    body = content
                elif isinstance(content, list):
                    parts = [
                        b.get("text", "")
                        for b in content
                        if isinstance(b, dict) and b.get("type") == "text"
                    ]
                    body = " ".join(p for p in parts if p)
            if title is not None and body:
                return title, body
        if read_size >= total or read_size >= TAIL_MAX_BYTES:
            return title, body
        read_size = min(read_size * 4, TAIL_MAX_BYTES, total)


def main():
    try:
        payload = json.load(sys.stdin)
    except Exception:
        sys.exit(0)

    session_id = payload.get("session_id", "")
    cwd = payload.get("cwd", "")
    transcript_path = payload.get("transcript_path", "")

    try:
        session_name, registry_name = resolve_tmux_session(session_id)
        if not session_name:
            session_name = resolve_tmux_session_from_env()
            registry_name = None
        if not session_name:
            debug_log(f"session_id={session_id}: no resolvable tmux session, skipping")
            sys.exit(0)

        target_addr = matched_window_address(session_name)
        if target_addr and target_addr == active_window_address():
            debug_log(f"session={session_name}: window already focused, skipping")
            sys.exit(0)

        ai_title, body = stop_fields(transcript_path)
        title = ai_title or registry_name or os.path.basename(cwd.rstrip("/")) or session_name
        body = body.strip()
        if len(body) > BODY_BUDGET:
            body = body[:BODY_BUDGET].rstrip() + "…"

        subprocess.run(
            ["notify-send", "-a", f"claude-stop:{session_name}", title, body],
            timeout=3,
        )
        debug_log(f"session={session_name}: notified (title={title!r})")
    except Exception as e:
        debug_log(f"exception: {e!r}")
        sys.exit(0)

    sys.exit(0)


if __name__ == "__main__":
    main()

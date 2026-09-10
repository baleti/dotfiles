#!/usr/bin/env python3
"""claude-agents: HTTP bridge between this machine's tmux/claude sessions and
the Claude Agents Android app, over a private tunnel (WireGuard or
equivalent) only.

Security model:
  - socket bound to the tunnel interface IP only, never 0.0.0.0
  - peer IP must be in ALLOWED_SUBNET
  - X-Claude-Agents-Token header must match the on-disk token (constant-time)
  - any Origin header -> reject (no browser caller has legitimate business)
  - no CORS headers, ever
  - naive per-IP rate limit on mutating endpoints
  - token itself is never logged
"""
import base64
import hmac
import http.server
import ipaddress
import json
import os
import re
import secrets
import socketserver
import subprocess
import sys
import threading
import time
import urllib.parse
import uuid as uuid_mod
from collections import defaultdict
from datetime import datetime
from pathlib import Path

HOME = Path.home()
CONFIG_DIR = HOME / ".config" / "claude-agents"
TOKEN_FILE = CONFIG_DIR / "token"
LIVE_FILE = CONFIG_DIR / "live-sessions.json"
QUEUE_DIR = CONFIG_DIR / "queue"
DELIVERED_FILE = CONFIG_DIR / "delivered.json"
LOG_FILE = CONFIG_DIR / "daemon.log"
UPLOADS_DIR = CONFIG_DIR / "uploads"
MAX_UPLOAD_BYTES = 25 * 1024 * 1024  # 25MB -- images and small files; not meant for video
UPLOAD_RATE_LIMIT = 10  # per 60s window, tighter than plain /send (bigger payloads, disk writes)
UPLOAD_RETENTION_SEC = 30 * 86400  # sweep uploads older than this (see prune_old_uploads)
PROJECTS_DIR = HOME / ".claude" / "projects"

# Real ceiling, not a guess: every genuine "Prompt is too long" failure
# found across this account's own transcript history (grep for
# isApiErrorMessage+invalid_request) landed with context_tokens at
# 974,041-977,494 -- consistently ~976K, not the plain-Sonnet 200K window a
# first guess assumed (confirmed wrong live 2026-09-08: a real, otherwise-
# healthy conversation sat at 252K tokens with the banner already claiming
# "127% full"). This account's sessions clearly run with a ~1M token
# context window. 1_000_000 here (not the exact 976K figure) leaves a
# little headroom so the banner reads "getting close" rather than "already
# over" right at the point real conversations have actually failed.
CONTEXT_WINDOW_TOKENS = 1_000_000
CONTEXT_WARN_PCT = 80

def _env_or_fatal(name):
    val = os.environ.get(name)
    if not val:
        sys.stderr.write(f"claude-agents: {name} must be set (see README) - refusing to start\n")
        raise SystemExit(1)
    return val


BIND_IP = _env_or_fatal("CLAUDE_AGENTS_BIND_IP")
PORT = int(os.environ.get("CLAUDE_AGENTS_PORT", "8790"))
ALLOWED_SUBNET = ipaddress.ip_network(_env_or_fatal("CLAUDE_AGENTS_ALLOWED_SUBNET"))

ACCOUNT_DIRS = {"claude": HOME / ".claude", "claude2": HOME / ".claude2", "claude3": HOME / ".claude3"}

CLAUDE_PROC_RE = re.compile(r'(^|/)claude(\s|$)')

_log_lock = threading.Lock()


def log(msg):
    line = f"{time.strftime('%Y-%m-%dT%H:%M:%S')} {msg}\n"
    with _log_lock:
        with open(LOG_FILE, "a") as f:
            f.write(line)
    sys.stderr.write(line)


# ---------------------------------------------------------------------------
# Token + account map
# ---------------------------------------------------------------------------

def load_or_create_token():
    if TOKEN_FILE.exists():
        return TOKEN_FILE.read_text().strip()
    tok = secrets.token_hex(32)
    TOKEN_FILE.write_text(tok + "\n")
    os.chmod(TOKEN_FILE, 0o600)
    print(f"[claude-agents] generated pairing token: {tok}")
    print(f"[claude-agents] (also saved to {TOKEN_FILE}, 0600)")
    return tok


def build_account_map():
    """accountUuid -> {dir_key, label, email}"""
    m = {}
    for key, d in ACCOUNT_DIRS.items():
        cfg = d / ".claude.json"
        if not cfg.exists():
            continue
        try:
            data = json.loads(cfg.read_text())
        except Exception as e:
            log(f"account-map: failed to parse {cfg}: {e}")
            continue
        oa = data.get("oauthAccount") or {}
        uuid = oa.get("accountUuid")
        if uuid:
            m[uuid] = {
                "dir_key": key,
                "label": oa.get("displayName") or oa.get("emailAddress") or key,
                "email": oa.get("emailAddress"),
            }
    return m


TOKEN = load_or_create_token()
ACCOUNT_MAP = build_account_map()
log(f"account map loaded: {[(v['dir_key'], v['email']) for v in ACCOUNT_MAP.values()]}")


# ---------------------------------------------------------------------------
# Live-session scanning (tmux panes -> claude process -> account/session id)
# ---------------------------------------------------------------------------

_live_lock = threading.Lock()
_live_sessions = {}  # session_id -> {account, dir_key, pane, confidence}


def scan_tmux_panes():
    try:
        out = subprocess.run(
            ["tmux", "list-panes", "-a", "-F",
             "#{pane_id}\t#{pane_pid}\t#{session_name}:#{window_index}.#{pane_index}"],
            capture_output=True, text=True, timeout=5,
        )
    except Exception as e:
        log(f"tmux list-panes failed: {e}")
        return []
    panes = []
    for line in out.stdout.splitlines():
        parts = line.split("\t")
        if len(parts) == 3:
            try:
                panes.append({"pane_id": parts[0], "pid": int(parts[1]), "target": parts[2]})
            except ValueError:
                pass
    return panes


def build_proc_tree():
    try:
        out = subprocess.run(["ps", "-eo", "pid,ppid,args"], capture_output=True, text=True, timeout=5).stdout
    except Exception as e:
        log(f"ps failed: {e}")
        return {}, defaultdict(list)
    procs = {}
    children = defaultdict(list)
    for line in out.splitlines()[1:]:
        parts = line.strip().split(None, 2)
        if len(parts) < 3:
            continue
        try:
            pid, ppid = int(parts[0]), int(parts[1])
        except ValueError:
            continue
        args = parts[2]
        procs[pid] = (ppid, args)
        children[ppid].append(pid)
    return procs, children


def find_claude_descendants(root_pid, procs, children):
    stack = [root_pid]
    seen = set()
    matches = []
    while stack:
        pid = stack.pop()
        if pid in seen:
            continue
        seen.add(pid)
        info = procs.get(pid)
        if info:
            _, args = info
            if CLAUDE_PROC_RE.search(args):
                matches.append(pid)
        stack.extend(children.get(pid, []))
    # prefer a match that carries an explicit --resume/--session-id
    def score(pid):
        _, args = procs[pid]
        return 1 if ("--resume" in args or "--session-id" in args) else 0
    matches.sort(key=score, reverse=True)
    return matches


def read_proc_cmdline(pid):
    try:
        raw = Path(f"/proc/{pid}/cmdline").read_bytes()
        return [p.decode("utf-8", "ignore") for p in raw.split(b"\0") if p]
    except Exception:
        return []


def read_proc_environ(pid):
    try:
        raw = Path(f"/proc/{pid}/environ").read_bytes()
        env = {}
        for entry in raw.split(b"\0"):
            if not entry:
                continue
            k, _, v = entry.partition(b"=")
            env[k.decode("utf-8", "ignore")] = v.decode("utf-8", "ignore")
        return env
    except Exception:
        return {}


def read_proc_cwd(pid):
    try:
        return os.readlink(f"/proc/{pid}/cwd")
    except Exception:
        return None


def cwd_to_project_dir(cwd):
    if not cwd:
        return None
    return PROJECTS_DIR / cwd.replace("/", "-")


def owner_account_uuid_of_jsonl(path):
    try:
        with open(path, "r", errors="ignore") as f:
            for i, line in enumerate(f):
                if i >= 8:
                    break
                try:
                    d = json.loads(line)
                except Exception:
                    continue
                if d.get("type") == "bridge-session" and d.get("ownerAccountUuid"):
                    return d["ownerAccountUuid"]
    except Exception:
        pass
    return None


def account_dir_key_from_config_dir(path_str):
    if not path_str:
        return "claude"
    p = Path(path_str)
    name = p.name
    return name if name in ACCOUNT_DIRS else "claude"


TMUX_PANE_ID_RE = re.compile(r"(%\d+)")


def is_pid_alive(pid):
    try:
        return Path(f"/proc/{int(pid)}").is_dir()
    except Exception:
        return False


def scan_sessions_registry():
    """Primary, authoritative live-session source: each account's own
    ~/.claudeN/sessions/<pid>.json (Claude Code's own registry of its
    currently-running processes -- confirmed present and populated live)
    carries a "tmux" field like "812:@1194.%2225". The trailing %NNNN is
    tmux's own *stable* global pane id, immune to the pane-index drift that
    scan_tmux_panes' "session:window.pane" targets are vulnerable to.

    Confirmed live 2026-09-08 as the actual cause of a reported-critical
    bug (a sent message and its response never appearing in the app):
    this function did not exist in the deployed daemon at all -- despite
    being described as already built in an earlier session's own notes --
    so every live-session resolution went through scan_live_sessions'
    positional-target fallback below. A window's pane arrangement changed
    at some point after this session's own pane (%2225) was first
    resolved, and the stale positional target "812:0.0" silently started
    pointing at a *different* pane (%117, a different claude process
    entirely) -- tmux send-keys still returns success against a
    syntactically valid target, so nothing ever signaled the mismatch;
    the message was really typed, just into the wrong live session, while
    this one saw nothing.
    """
    result = {}
    for dir_key, base in ACCOUNT_DIRS.items():
        sessions_dir = base / "sessions"
        if not sessions_dir.is_dir():
            continue
        for f in sessions_dir.glob("*.json"):
            try:
                data = json.loads(f.read_text())
            except Exception:
                continue
            pid = data.get("pid")
            session_id = data.get("sessionId")
            tmux_field = data.get("tmux")
            if not (pid and session_id and tmux_field and is_pid_alive(pid)):
                continue
            m = TMUX_PANE_ID_RE.search(tmux_field)
            if not m:
                continue
            _record_live(result, session_id, dir_key, m.group(1), "exact", status=data.get("status"))
    return result


def scan_live_sessions():
    # Authoritative first -- see scan_sessions_registry's docstring for why
    # this must win over anything positional. The proc-tree scan below only
    # fills in sessions it didn't already resolve (e.g. a session started
    # by something other than this machine's normal launch path, with no
    # sessions/<pid>.json of its own).
    result = scan_sessions_registry()
    panes = scan_tmux_panes()
    procs, children = build_proc_tree()
    # pending[proj_dir] = list of (pane_id, dir_key) with no explicit session
    # id yet -- resolved below only when a cwd has exactly one candidate
    # pane, since with several sibling panes sharing a cwd there is no
    # external way to tell them apart and guessing risks routing a reply
    # into the wrong conversation.
    pending = defaultdict(list)
    for pane in panes:
        candidates = find_claude_descendants(pane["pid"], procs, children)
        if not candidates:
            continue
        pid = candidates[0]
        argv = read_proc_cmdline(pid)
        session_id = None
        for i, a in enumerate(argv):
            if a in ("--resume", "--session-id") and i + 1 < len(argv):
                candidate = argv[i + 1]
                if re.fullmatch(r"[0-9a-fA-F-]{36}", candidate):
                    session_id = candidate
                    break
        if session_id and session_id in result:
            continue  # already resolved authoritatively above
        env = read_proc_environ(pid)
        dir_key = account_dir_key_from_config_dir(env.get("CLAUDE_CONFIG_DIR"))
        # pane["pane_id"] (stable "%N"), never pane["target"] (positional
        # "session:window.pane") -- see scan_sessions_registry's docstring.
        if session_id:
            _record_live(result, session_id, dir_key, pane["pane_id"], "exact")
        else:
            cwd = read_proc_cwd(pid)
            proj_dir = cwd_to_project_dir(cwd)
            if proj_dir and proj_dir.is_dir():
                pending[str(proj_dir)].append((pane["pane_id"], dir_key))
    for proj_dir_str, group in pending.items():
        if len(group) != 1:
            continue  # ambiguous cwd shared by multiple live panes -- skip
        pane_id, dir_key = group[0]
        jsonls = sorted(Path(proj_dir_str).glob("*.jsonl"), key=lambda p: p.stat().st_mtime, reverse=True)
        if jsonls:
            sid = jsonls[0].stem
            if sid not in result:
                _record_live(result, sid, dir_key, pane_id, "cwd-heuristic")
    return result


def _record_live(result, session_id, dir_key, pane_target, confidence, status=None):
    # cross-check / refine account via the transcript's own owner uuid, when resolvable
    jsonl_path = PROJECTS_DIR_glob_by_id(session_id)
    if jsonl_path:
        uuid = owner_account_uuid_of_jsonl(jsonl_path)
        if uuid and uuid in ACCOUNT_MAP:
            dir_key = ACCOUNT_MAP[uuid]["dir_key"]
    result[session_id] = {
        "dir_key": dir_key,
        "pane": pane_target,
        "confidence": confidence,
        # "busy" / "idle" -- Claude Code's own sessions/<pid>.json already
        # tracks this (it's what a "processing" indicator would otherwise
        # have to guess at from transcript activity); only available for
        # sessions resolved via scan_sessions_registry, which is the only
        # place that file is actually read. None for the proc-tree
        # fallback -- the client treats that as "unknown", not "idle".
        "status": status,
    }


_jsonl_index_cache = {"mtime": 0, "index": {}}


def _projects_signature():
    # A new file inside an *existing* account subdirectory (the common case:
    # ~/.claude/projects/<cwd>/<new-session>.jsonl, where <cwd> already has
    # older sessions in it) only bumps that subdirectory's own mtime, not
    # PROJECTS_DIR's - confirmed live (2026-09-05) that using PROJECTS_DIR's
    # mtime alone left a brand-new session's transcript invisible to this
    # index for as long as no *unrelated* top-level project directory
    # happened to appear. Taking the max mtime across every subdirectory
    # (plus PROJECTS_DIR itself, so a new subdirectory is caught too) fixes
    # detection without turning this into a full recursive walk.
    try:
        top_mtime = PROJECTS_DIR.stat().st_mtime
        sub_mtimes = [d.stat().st_mtime for d in PROJECTS_DIR.iterdir() if d.is_dir()]
    except Exception:
        return 0.0
    return max(sub_mtimes + [top_mtime])


def PROJECTS_DIR_glob_by_id(session_id):
    # cheap cached id -> path index, rebuilt if the projects dir changed
    signature = _projects_signature()
    if signature != _jsonl_index_cache["mtime"]:
        idx = {}
        try:
            for d in PROJECTS_DIR.iterdir():
                if d.is_dir():
                    for f in d.glob("*.jsonl"):
                        idx[f.stem] = f
        except Exception:
            pass
        _jsonl_index_cache["mtime"] = signature
        _jsonl_index_cache["index"] = idx
    return _jsonl_index_cache["index"].get(session_id)


def drain_queue(live_sessions):
    if not QUEUE_DIR.exists():
        return
    for qfile in QUEUE_DIR.glob("*.jsonl"):
        session_id = qfile.stem
        info = live_sessions.get(session_id)
        if not info:
            continue
        try:
            lines = qfile.read_text().splitlines()
        except Exception:
            continue
        if not lines:
            continue
        remaining = []
        for line in lines:
            try:
                item = json.loads(line)
            except Exception:
                continue
            ok = send_to_pane(info["pane"], item.get("text", ""))
            if not ok:
                remaining.append(line)
                # if the pane vanished mid-drain, stop trying the rest this round
                break
        if remaining:
            qfile.write_text("\n".join(remaining) + "\n")
        else:
            qfile.unlink(missing_ok=True)


def _pane_input_box_text(pane_target):
    """Text currently sitting in Claude Code's own input box (the `> ...`
    line the CLI draws bounded by its own horizontal-rule border), or None
    if it can't be determined. Used only to verify Enter actually
    registered -- tmux send-keys reporting success only means the
    keystroke was injected into the pty, not that the TUI acted on it."""
    try:
        out = subprocess.run(
            ["tmux", "capture-pane", "-t", pane_target, "-p"],
            capture_output=True, text=True, timeout=5, check=True,
        ).stdout
    except Exception:
        return None
    lines = out.rstrip("\n").split("\n")

    def is_rule(s):
        return bool(s) and set(s) <= {"─", "-"}

    # The input box is bounded by its own top and bottom horizontal-rule
    # border, always drawn even when the box is empty -- the LAST two rule
    # lines in the pane are always that pair (confirmed live 2026-09-09:
    # scanning backward for the first rule line hit the box's *bottom*
    # border first, immediately below the status-bar footer that follows
    # it on screen, before ever reaching the "❯ ..." line above it --
    # always returned "nothing pending" even when something plainly was).
    rule_indices = [i for i, l in enumerate(lines) if is_rule(l.strip())]
    if len(rule_indices) < 2:
        return None
    top, bottom = rule_indices[-2], rule_indices[-1]
    for line in lines[top + 1:bottom]:
        stripped = line.strip()
        if stripped[:1] in ("❯", ">"):  # "❯" (Claude Code's own prompt glyph) or a plain ">"
            return stripped[1:].strip()
    return None


def send_to_pane(pane_target, text):
    try:
        subprocess.run(["tmux", "send-keys", "-t", pane_target, "-l", "--", text],
                        check=True, timeout=5)
        # A bare "Enter" sent immediately after the literal-text paste can
        # race Claude Code's own TUI (still processing the bracketed-paste
        # block) and get silently swallowed -- confirmed live 2026-09-09: a
        # real message sat typed-but-unsubmitted in a pane for over 11
        # hours, with tmux send-keys itself reporting success both times
        # and nothing anywhere signaling the Enter never actually
        # registered. The fixed delay narrows the race; the verify-and-
        # retry loop below closes it -- Enter is idempotent against an
        # already-submitted message (pressing it again on an empty prompt
        # is a harmless no-op), so retrying is safe even if the check
        # itself is wrong.
        time.sleep(0.15)
        for attempt in range(3):
            subprocess.run(["tmux", "send-keys", "-t", pane_target, "Enter"], check=True, timeout=5)
            time.sleep(0.3)
            pending = _pane_input_box_text(pane_target)
            # An empty (or unreadable) input box means it submitted --
            # anything still sitting in it, whether or not it looks exactly
            # like what we sent, means Enter didn't take and is worth
            # another try.
            if not pending:
                return True
            log(f"send_to_pane({pane_target}): Enter attempt {attempt + 1} didn't submit (still pending: {pending[:60]!r}), retrying")
        log(f"send_to_pane({pane_target}): text still appears unsubmitted after 3 Enter attempts -- reporting delivered anyway (tmux itself succeeded); reconcileDeliveredOutbox on the client only retires the row once the real message actually appears")
        return True
    except Exception as e:
        log(f"send_to_pane({pane_target}) failed: {e}")
        return False


def deliver_text_to_conversation(session_id, text, msg_id, ip, log_prefix="send"):
    """Shared by /send and /attachments: deliver `text` into the
    conversation's live tmux pane if one exists, else durably queue it --
    same idempotency (msg_id replay, see record_send_result/
    lookup_send_result) and result shape either caller needs, so an
    attachment's reference line gets exactly the same delivery guarantees
    a plain text message does."""
    if msg_id:
        replay = lookup_send_result(msg_id)
        if replay is not None:
            log(f"{log_prefix}: replay id={msg_id} for {session_id} from {ip} (already handled, not re-sent)")
            replay = dict(replay)
            replay["replayed"] = True
            return replay

    live = get_live_sessions().get(session_id)
    if live:
        ok = send_to_pane(live["pane"], text)
        if ok:
            log(f"{log_prefix}: delivered to {session_id} via {live['pane']} from {ip}")
            result = {"delivered": True, "via": "tmux", "pane": live["pane"]}
            record_send_result(msg_id, session_id, result)
            return result
        # fall through to queue on send failure

    QUEUE_DIR.mkdir(parents=True, exist_ok=True)
    qfile = QUEUE_DIR / f"{session_id}.jsonl"
    with open(qfile, "a") as f:
        f.write(json.dumps({"id": msg_id, "text": text, "queued_at": time.time()}) + "\n")
    log(f"{log_prefix}: queued for {session_id} from {ip} (no live pane)")
    result = {"delivered": False, "queued": True}
    record_send_result(msg_id, session_id, result)
    return result


# ---------------------------------------------------------------------------
# Attachments
#
# Never trust the client's claimed mime_type for what we tell Claude is an
# "image" -- sniff real magic bytes instead. Not a security boundary in the
# sense of blocking a malicious file (nothing on this daemon ever decodes
# or renders the bytes; Claude's own Read tool does, server-side, on
# Anthropic's infrastructure), but it keeps a mislabeled non-image from
# being confidently announced as one, and it's a cheap, well-understood
# check worth having regardless.
# ---------------------------------------------------------------------------
_IMAGE_SNIFFERS = (
    (b"\xff\xd8\xff", "image/jpeg"),
    (b"\x89PNG\r\n\x1a\n", "image/png"),
    (b"GIF87a", "image/gif"),
    (b"GIF89a", "image/gif"),
)


def sniff_image_mime(data):
    for magic, mime in _IMAGE_SNIFFERS:
        if data.startswith(magic):
            return mime
    if len(data) >= 12 and data[0:4] == b"RIFF" and data[8:12] == b"WEBP":
        return "image/webp"
    return None


def save_attachment(session_id, filename, claimed_mime, data):
    """Stores `data` under a server-generated id -- never the client's
    filename, which only ever becomes display metadata (sidecar JSON),
    closing off path traversal entirely regardless of what a caller sends.
    Returns (attachment_id, effective_mime) -- effective_mime is the
    sniffed type when the bytes are recognizably an image, the client's
    claimed type otherwise (there's no equivalent sniff table worth
    building for every non-image format this might ever see; those are
    opaque attachments either way, sniffing wouldn't change how they're
    handled)."""
    UPLOADS_DIR.mkdir(parents=True, exist_ok=True)
    attachment_id = secrets.token_hex(16)
    blob_path = UPLOADS_DIR / attachment_id
    tmp_path = UPLOADS_DIR / f"{attachment_id}.tmp"
    tmp_path.write_bytes(data)
    tmp_path.rename(blob_path)  # atomic on the same filesystem -- no partial-write blob ever visible under attachment_id

    sniffed = sniff_image_mime(data)
    effective_mime = sniffed or claimed_mime
    # Display-only -- stripped of any path component and control characters,
    # capped in length. Never used to construct a filesystem path.
    safe_display_name = re.sub(r"[\x00-\x1f/\\]", "_", filename)[:200] or "file"
    meta = {
        "session_id": session_id,
        "filename": safe_display_name,
        "mime_type": effective_mime,
        "size": len(data),
        "uploaded_at": time.time(),
    }
    (UPLOADS_DIR / f"{attachment_id}.json").write_text(json.dumps(meta))
    return attachment_id, effective_mime


def prune_old_uploads():
    if not UPLOADS_DIR.is_dir():
        return
    now = time.time()
    for meta_path in UPLOADS_DIR.glob("*.json"):
        try:
            meta = json.loads(meta_path.read_text())
            if now - meta.get("uploaded_at", now) < UPLOAD_RETENTION_SEC:
                continue
        except Exception:
            pass  # unreadable metadata -- prune it and its blob too, below
        attachment_id = meta_path.stem
        (UPLOADS_DIR / attachment_id).unlink(missing_ok=True)
        meta_path.unlink(missing_ok=True)


SPAWN_SESSION_PREFIX = "rss-agent"
CLAUDE_BIN = str(HOME / ".local" / "bin" / "claude")


def spawn_session(dir_key, initial_text):
    """Starts a brand-new tmux+claude session with a caller-known session id,
    primes it with the first message, and waits until the transcript file
    exists so the caller's very next /stream call is guaranteed to find it.

    Unlike the existing live-scan discovery (5s-interval, heuristic for a
    bare spawn with no --session-id), this passes --session-id explicitly -
    the same "exact" high-confidence path scan_live_sessions() already
    prefers, just without waiting up to 5s for the next scan tick to notice
    it. Returns (session_id, error) - error is None on success.
    """
    if dir_key not in ACCOUNT_DIRS:
        return None, f"unknown account {dir_key!r}"

    session_id = str(uuid_mod.uuid4())
    tmux_session = f"{SPAWN_SESSION_PREFIX}-{time.strftime('%Y%m%d-%H%M%S')}-{secrets.token_hex(2)}"
    config_dir = str(ACCOUNT_DIRS[dir_key])

    argv = [
        "tmux", "new-session", "-d", "-s", tmux_session,
        "-e", f"CLAUDE_CONFIG_DIR={config_dir}",
        "--",
        CLAUDE_BIN, "--dangerously-skip-permissions", "--session-id", session_id,
    ]
    try:
        subprocess.run(argv, check=True, capture_output=True, timeout=10)
    except Exception as e:
        log(f"spawn: tmux new-session failed: {e}")
        return None, "failed to start session"

    # The TUI needs a moment to finish drawing before it can accept
    # keystrokes - same fixed-delay approach send_to_pane's callers already
    # rely on elsewhere in this file, there being no readiness signal to
    # poll for that doesn't itself risk racing the first real prompt.
    time.sleep(2)

    if not send_to_pane(f"{tmux_session}:0.0", initial_text):
        log(f"spawn: initial send to {tmux_session} failed")
        return None, "session started but initial message failed to send"

    # Block until the transcript file actually exists, so the caller's
    # first /stream call (which 404s on a missing file, it doesn't wait for
    # one to appear) doesn't race a Claude Code process that is still
    # booting or mid-first-response.
    deadline = time.time() + 15
    while time.time() < deadline:
        if PROJECTS_DIR_glob_by_id(session_id):
            return session_id, None
        time.sleep(0.5)
    log(f"spawn: transcript for {session_id} never appeared within 15s")
    return session_id, None  # still return it - the session is real, just slow to write its first line


def cwd_of_transcript(path):
    """Best-effort real working directory a transcript's session was
    started in, read straight from its own per-line "cwd" field (present
    on every user/assistant message) -- the authoritative source, not a
    guess decoded from the project directory's own name, which lossily
    replaces every "/" with "-" and so can't be safely inverted for a
    real path that itself contains a literal "-". Falls back to $HOME if
    no line carries one (e.g. a stub transcript with only summary/system
    lines -- see list_conversations' real_messages==0 filter, which
    should already keep those out of the archive view, but this is a
    harmless fallback regardless)."""
    try:
        with open(path, "r", errors="ignore") as f:
            for line in f:
                try:
                    d = json.loads(line)
                except Exception:
                    continue
                cwd = d.get("cwd")
                if cwd:
                    return cwd
    except Exception:
        pass
    return str(HOME)


# Serializes concurrent /resume calls for the same session_id -- without
# this, two sends landing in the outbox drain close together for the same
# closed conversation could each see "not live yet" and both spawn a
# `claude --resume <id>` tmux session, which corrupts the transcript (two
# processes writing the same jsonl). Keyed by session_id, created lazily;
# never removed once created (bounded by the number of distinct
# conversations ever resumed in this daemon's lifetime, not worth
# cleaning up).
_resume_locks = defaultdict(threading.Lock)
_resume_locks_guard = threading.Lock()


def _resume_lock_for(session_id):
    with _resume_locks_guard:
        return _resume_locks[session_id]


def resume_session(session_id, initial_text):
    """Relaunches a closed (no live tmux pane) conversation via `claude
    --resume <session_id>` in a fresh tmux session, run from the same cwd
    and account the conversation originally used, then primes it with
    `initial_text` -- the archive view's equivalent of spawn_session for a
    brand-new conversation. Returns (session_id, error); error is None on
    success. Safe to call even if another /resume call for the same
    session_id is racing this one -- see _resume_lock_for."""
    lock = _resume_lock_for(session_id)
    with lock:
        # Re-check live status under the lock: either a racing /resume call
        # just finished spawning this same session, or an unrelated tmux
        # pane resumed it manually in the few seconds since the caller's
        # own live-status check -- either way, deliver into the real pane
        # instead of spawning a second process against the same session id.
        live = get_live_sessions().get(session_id)
        if live:
            ok = send_to_pane(live["pane"], initial_text)
            if ok:
                return session_id, None
            return None, "session is live but delivering to its pane failed"

        path = find_conversation_path(session_id)
        if not path:
            return None, "conversation not found"
        meta = conversation_meta(path)
        dir_key = meta.get("account")
        if dir_key not in ACCOUNT_DIRS:
            dir_key = "claude"
        config_dir = str(ACCOUNT_DIRS[dir_key])
        cwd = cwd_of_transcript(path)
        if not Path(cwd).is_dir():
            cwd = str(HOME)

        tmux_session = f"{SPAWN_SESSION_PREFIX}-resume-{time.strftime('%Y%m%d-%H%M%S')}-{secrets.token_hex(2)}"
        argv = [
            "tmux", "new-session", "-d", "-s", tmux_session,
            "-c", cwd,
            "-e", f"CLAUDE_CONFIG_DIR={config_dir}",
            "--",
            CLAUDE_BIN, "--dangerously-skip-permissions", "--resume", session_id,
        ]
        try:
            subprocess.run(argv, check=True, capture_output=True, timeout=10)
        except Exception as e:
            log(f"resume: tmux new-session failed for {session_id}: {e}")
            return None, "failed to start session"

        # claude --resume has strictly more to do before its first prompt
        # is interactive than a brand-new session does (load + replay the
        # whole prior transcript) -- spawn_session's 2s undershoots this
        # for anything but a short conversation.
        time.sleep(4)

        if not send_to_pane(f"{tmux_session}:0.0", initial_text):
            log(f"resume: initial send to {tmux_session} failed for {session_id}")
            return None, "session resumed but initial message failed to send"

        return session_id, None


def live_scan_loop():
    tick = 0
    while True:
        try:
            sessions = scan_live_sessions()
            with _live_lock:
                _live_sessions.clear()
                _live_sessions.update(sessions)
            with open(LIVE_FILE, "w") as f:
                json.dump(sessions, f)
            drain_queue(sessions)
            # Uploaded attachments accumulate indefinitely otherwise --
            # ~hourly is plenty (720 * 5s), no need for this on every tick.
            if tick % 720 == 0:
                prune_old_uploads()
        except Exception as e:
            log(f"live_scan_loop error: {e}")
        tick += 1
        time.sleep(5)


def get_live_sessions():
    with _live_lock:
        return dict(_live_sessions)


# ---------------------------------------------------------------------------
# Transcript parsing
# ---------------------------------------------------------------------------

def summarize_tool_use(name, tool_input):
    """Tool-aware summary, not a raw json.dumps of the input dict.

    json.dumps of a Bash call's {"command": "...multi-line..."} escapes
    every real newline in the command to the literal two characters
    backslash-n -- confirmed live (2026-09-05) that this is exactly what
    was rendering on-device as "...restart claude-agents.service\nsleep
    2\n..." instead of an actual multi-line command. Pulling the real
    field out and wrapping it as a fenced ```bash block instead means it
    flows through the app's own Markdown.kt/SyntaxHighlight.kt pipeline
    (already built) with real line breaks and syntax coloring, the way
    Claude Code's own CLI output reads.
    """
    if not isinstance(tool_input, dict):
        tool_input = {}
    if name == "Bash":
        cmd = tool_input.get("command", "")
        return f"→ Bash\n```bash\n{cmd}\n```"
    if name in ("Read", "Write", "NotebookEdit"):
        path = tool_input.get("file_path") or tool_input.get("notebook_path") or ""
        return f"→ {name}(`{path}`)"
    if name == "Edit":
        return f"→ Edit(`{tool_input.get('file_path', '')}`)"
    if name == "Glob":
        return f"→ Glob(`{tool_input.get('pattern', '')}`)"
    if name == "Grep":
        pattern = tool_input.get("pattern", "")
        path = tool_input.get("path", "")
        return f"→ Grep(`{pattern}`" + (f" in `{path}`)" if path else ")")
    if name in ("WebFetch", "WebSearch"):
        target = tool_input.get("url") or tool_input.get("query") or ""
        return f"→ {name}(`{target}`)"
    if name == "TodoWrite":
        return "→ TodoWrite(updated task list)"
    try:
        arg_str = json.dumps(tool_input, ensure_ascii=False)[:300]
    except Exception:
        arg_str = ""
    return f"→ {name}({arg_str})"


def summarize_content_blocks(content):
    if isinstance(content, str):
        return content
    if not isinstance(content, list):
        return ""
    parts = []
    for block in content:
        if not isinstance(block, dict):
            continue
        t = block.get("type")
        if t == "text":
            parts.append(block.get("text", ""))
        elif t == "tool_use":
            parts.append(summarize_tool_use(block.get("name", "?"), block.get("input", {})))
        elif t == "tool_result":
            c = block.get("content")
            if isinstance(c, str):
                parts.append(c[:2000])
            elif isinstance(c, list):
                for cc in c:
                    if not isinstance(cc, dict):
                        continue
                    ct = cc.get("type")
                    if ct == "text":
                        parts.append(cc.get("text", "")[:2000])
                    elif ct == "image":
                        # A screenshot Read (very common in this workflow)
                        # returns ONLY an image block, no text -- confirmed
                        # live (2026-09-05) that these whole exchanges were
                        # silently vanishing from the app (empty summary ->
                        # parse_transcript_line drops the line entirely),
                        # which is exactly what read as "skipping messages".
                        parts.append("[image]")
                    elif ct == "tool_reference":
                        parts.append(f"[{cc.get('tool_name', 'tool')} reference]")
        # "thinking" blocks intentionally omitted (bandwidth + noise)
    return "\n".join(p for p in parts if p)


# Wrapper tags the harness itself injects as a synthetic `type: "user"`
# transcript line -- confirmed live 2026-09-07: a background-task
# completion notification showed up as a "YOU" bubble in the app (the
# transcript's message.role is literally "user" for these, same as a real
# human turn -- there is no other field that distinguishes them). None of
# these are something the human actually typed, so they get the same
# "not really you" reclassification as a tool_result below.
SYNTHETIC_USER_TAGS = (
    "task-notification", "local-command-stdout", "local-command-caveat",
    "command-name", "command-message", "system-reminder",
    "user-prompt-submit-hook",
)


def parse_transcript_line(line, line_no):
    try:
        d = json.loads(line)
    except Exception:
        return None
    t = d.get("type")
    if t not in ("user", "assistant"):
        return None
    msg = d.get("message") or {}
    role = msg.get("role", t)
    content = msg.get("content")
    error_type = None
    if d.get("isApiErrorMessage") is True:
        # Claude Code's own synthetic error turn (message.model is the
        # literal string "<synthetic>") -- not a real assistant reply, but
        # wire-formatted as one (type/role both "assistant"), so up to now
        # it just rendered as an ordinary bubble reading "Prompt is too
        # long" with nothing telling the human what that meant or that
        # anything could be done about it. Tagged here so the app can
        # render it distinctly and, for the context-limit case, offer a
        # one-tap /compact instead.
        err = d.get("error")
        preview = summarize_content_blocks(content)
        if err == "invalid_request" and "too long" in preview.lower():
            error_type = "context_limit"
        elif err == "rate_limit":
            error_type = "rate_limit"
        else:
            error_type = "api_error"
        role = "error"
    if role == "user":
        if isinstance(content, list):
            # A tool result is *also* wire-formatted as a `type: "user"`
            # line with message.role "user" -- it's the output of a
            # Bash/Read/etc call being fed back to Claude, not something
            # the human said. Confirmed live 2026-09-05: these were
            # rendering as "YOU" bubbles (a daemon status printout the
            # model itself produced looked like the user had typed it).
            block_types = {b.get("type") for b in content if isinstance(b, dict)}
            if block_types and block_types <= {"tool_result", "image", "tool_reference"}:
                role = "tool_result"
        elif isinstance(content, str):
            stripped = content.strip()
            if stripped.startswith("<") and stripped[1:].split(">", 1)[0].split(" ", 1)[0] in SYNTHETIC_USER_TAGS:
                role = "tool_result"
    text = summarize_content_blocks(content)
    if not text.strip():
        return None
    result = {
        "line": line_no,
        "role": role,
        "text": text,
        "ts": d.get("timestamp"),
        "uuid": d.get("uuid"),
    }
    if error_type:
        result["error_type"] = error_type
    return result


def first_user_text(path, max_lines=50):
    try:
        with open(path, "r", errors="ignore") as f:
            for i, line in enumerate(f):
                if i >= max_lines:
                    break
                m = parse_transcript_line(line, i)
                if m and m["role"] == "user":
                    return m["text"][:140]
    except Exception:
        pass
    return "(untitled)"


def parse_iso_ts(ts):
    try:
        return datetime.fromisoformat(ts.replace("Z", "+00:00")).timestamp()
    except Exception:
        return None


def scan_transcript_stats(path):
    """(line_count, last_message_epoch, context_tokens, real_messages).
    real_messages is the count of actual user/assistant lines -- used by
    list_conversations() to drop pure-metadata stub sessions (mode/
    permission-mode/bridge-session/cost-state etc, zero real content) from
    the list entirely. These are a known, harmless byproduct of
    restore_plan.py's tmux-restore --resume path: when it can't confidently
    resolve which prior conversation belongs in a given pane, it
    deliberately launches a *plain* claude session there rather than
    guessing wrong and resuming into someone else's history -- confirmed
    live 2026-09-07 by reading several of these end to end (nothing but
    mode/permission-mode/bridge-session/system/last-prompt/cost-state
    lines, no user or assistant message ever sent). The original
    conversation a pane was supposed to restore is untouched on disk
    either way; this only ever discards an empty stub, never real history.

    line_count is every physical line (matches the "since" cursor
    semantics used elsewhere -- a
    positional index into the raw file, not just message-producing lines).
    last_message_epoch is the *last real user/assistant message's own
    timestamp* field, not the file's mtime -- confirmed live (2026-09-05)
    that raw mtime is unreliable for "age": an idle, already-finished
    session can still get its file touched (attach/resume, a bare
    mode-line write) minutes after the last real exchange, which made
    long-idle conversations look freshly active and threw off both the
    AGE column and the whole list's sort order. Falls back to None if no
    timestamped user/assistant line exists at all (caller falls back to
    st_mtime in that case).

    context_tokens is input + cache_creation + cache_read from the *last*
    assistant message's own usage object -- same figure and same field
    formula as claude-usage-daemon.py's context_tokens_for (the ctrl+alt+c
    quickshell panel's TKNS column), captured here in the same forward pass
    rather than a second tail-window read of the file, since this loop
    already walks every line anyway."""
    n = 0
    real_messages = 0
    last_ts = None
    context_tokens = None
    ai_title = None
    with open(path, "r", errors="ignore") as f:
        for line in f:
            n += 1
            try:
                d = json.loads(line)
            except Exception:
                continue
            if d.get("type") in ("user", "assistant"):
                real_messages += 1
                ts = d.get("timestamp")
                if ts:
                    last_ts = ts
            if d.get("type") == "assistant":
                usage = (d.get("message") or {}).get("usage")
                if usage:
                    context_tokens = (
                        (usage.get("input_tokens") or 0)
                        + (usage.get("cache_creation_input_tokens") or 0)
                        + (usage.get("cache_read_input_tokens") or 0)
                    )
            # Claude Code's own title for this session, written straight
            # into the transcript once it has enough context to generate
            # one (this is the exact same field the desktop's claude-history
            # tool reads for tmux pane titles / the ctrl+alt+c quickshell
            # panel -- see that tool's parse_session()). Reading it here
            # directly, in the same forward pass this function already
            # does, instead of only through load_history_titles()'s copy
            # of claude-history's own cache (below) -- that cache is only
            # ever refreshed when someone launches claude-history
            # interactively on the desktop, so a conversation this app
            # shows could sit with a stale first-message fallback for
            # hours after Claude Code itself had already titled it.
            # Confirmed live 2026-09-10 as the cause of a reported
            # inconsistency ("some just seem like first messages... we
            # need to keep them in sync"). A later ai-title line overwrites
            # an earlier one, matching claude-history's own "last one wins"
            # behavior.
            if d.get("type") == "ai-title":
                ai_title = d.get("aiTitle") or ai_title
    return n, (parse_iso_ts(last_ts) if last_ts else None), context_tokens, real_messages, ai_title


HISTORY_CACHE_PATH = HOME / ".cache" / "claude-history-parse-cache.json"
_history_titles_cache = {"mtime": 0.0, "titles": {}}


def load_history_titles():
    """session_id -> ai_title, straight from the same cache the `claude-history`
    picker builds (~/.cache/claude-history-parse-cache.json). This is the
    real, human-set conversation title (what shows in tmux pane titles /
    the ctrl+alt+c quickshell panel) -- a first-user-message snippet is
    just a fallback for anything that tool hasn't indexed yet."""
    try:
        st = HISTORY_CACHE_PATH.stat()
    except OSError:
        return {}
    if st.st_mtime != _history_titles_cache["mtime"]:
        titles = {}
        try:
            data = json.loads(HISTORY_CACHE_PATH.read_text())
            for entry in (data.get("files") or {}).values():
                idx = entry.get("indexed") or {}
                sid = idx.get("session_id")
                title = idx.get("ai_title")
                if sid and title:
                    titles[sid] = title
        except Exception as e:
            log(f"history-titles: failed to load {HISTORY_CACHE_PATH}: {e}")
        _history_titles_cache["mtime"] = st.st_mtime
        _history_titles_cache["titles"] = titles
    return _history_titles_cache["titles"]


_conv_meta_cache = {}  # path -> (mtime, size, meta)


def conversation_meta(path, history_titles=None):
    st = path.stat()
    key = str(path)
    cached = _conv_meta_cache.get(key)
    if cached and cached[0] == st.st_mtime and cached[1] == st.st_size:
        return cached[2]
    owner_uuid = owner_account_uuid_of_jsonl(path)
    account_info = ACCOUNT_MAP.get(owner_uuid) if owner_uuid else None
    if history_titles is None:
        history_titles = load_history_titles()
    line_count, last_message_epoch, context_tokens, real_messages, ai_title = scan_transcript_stats(path)
    # Preference order: this transcript's own ai-title line (freshest --
    # see scan_transcript_stats's doc), then the desktop claude-history
    # tool's separately cached copy of the same field (covers a session
    # this daemon hasn't rescanned since its mtime-keyed cache above was
    # last populated, but claude-history has), then a plain first-message
    # snippet for anything with no real title yet either way.
    title = ai_title or history_titles.get(path.stem) or first_user_text(path)
    meta = {
        "id": path.stem,
        "title": title,
        "mtime": last_message_epoch if last_message_epoch is not None else st.st_mtime,
        "line_count": line_count,
        "tokens": context_tokens,
        "context_pct": round(context_tokens / CONTEXT_WINDOW_TOKENS * 100) if context_tokens is not None else None,
        "real_messages": real_messages,
        "account": account_info["dir_key"] if account_info else "unknown",
        "account_label": account_info["label"] if account_info else "unknown",
    }
    _conv_meta_cache[key] = (st.st_mtime, st.st_size, meta)
    return meta


def list_conversations(account_filter=None):
    live = get_live_sessions()
    history_titles = load_history_titles()
    out = []
    if not PROJECTS_DIR.is_dir():
        return out
    for proj_dir in PROJECTS_DIR.iterdir():
        if not proj_dir.is_dir():
            continue
        for f in proj_dir.glob("*.jsonl"):
            try:
                meta = dict(conversation_meta(f, history_titles))
            except Exception as e:
                log(f"meta failed for {f}: {e}")
                continue
            # Pure-metadata stub sessions (see scan_transcript_stats) --
            # restore_plan.py's tmux-restore fallback when it can't
            # confidently resolve which prior conversation belongs in a
            # pane. Not real conversations, just noise; skip them outright
            # rather than showing an empty "(untitled)" row that goes
            # nowhere useful if tapped.
            if meta.pop("real_messages", 0) == 0:
                continue
            live_info = live.get(meta["id"])
            if live_info:
                meta["live"] = {"pane": live_info["pane"], "confidence": live_info["confidence"]}
                if meta["account"] == "unknown":
                    meta["account"] = live_info["dir_key"]
            else:
                meta["live"] = None
            if account_filter and meta["account"] != account_filter:
                continue
            out.append(meta)
    out.sort(key=lambda m: m["mtime"], reverse=True)
    return out


def find_conversation_path(session_id):
    if not re.fullmatch(r"[0-9a-fA-F-]{36}", session_id or ""):
        return None
    return PROJECTS_DIR_glob_by_id(session_id)


def read_messages_since(path, since_line):
    out = []
    with open(path, "r", errors="ignore") as f:
        for i, line in enumerate(f):
            if i < since_line:
                continue
            m = parse_transcript_line(line, i)
            if m:
                out.append(m)
    return out


# ---------------------------------------------------------------------------
# Rate limiting
# ---------------------------------------------------------------------------

_rate_lock = threading.Lock()
_rate_hits = defaultdict(list)


# ---------------------------------------------------------------------------
# Send idempotency
#
# A spotty-connection retry means the phone can legitimately POST the exact
# same outbox row twice: the daemon delivers it (tmux send-keys, or a queue
# append) and returns 200, but the response never makes it back across the
# tunnel before OutboxLogic's request times out, so the row stays "pending"
# locally and the next drain re-POSTs the identical text. Without something
# to recognize that as the same send, that's a real duplicate -- either
# typed twice into a live Claude Code session, or double-queued so it fires
# twice once the session comes back live. HTTP/TCP and WireGuard's own
# Poly1305 auth tag already rule out a response silently arriving corrupted
# or truncated (a completed response is intact, full stop), so the actual
# gap is exactly-once *delivery*, not data integrity -- solved with a
# client-generated id per outbox row, not a content hash (the retried text
# is always byte-identical to the first attempt anyway, since it's the same
# DB row being resent).
# ---------------------------------------------------------------------------
_delivered_lock = threading.Lock()
_delivered = {}  # msg_id -> {"session_id", "result": {...}, "ts"}
DELIVERED_RETENTION_SEC = 7 * 86400


def _load_delivered():
    global _delivered
    try:
        data = json.loads(DELIVERED_FILE.read_text())
    except Exception:
        data = {}
    now = time.time()
    _delivered = {k: v for k, v in data.items() if now - v.get("ts", 0) < DELIVERED_RETENTION_SEC}


def _save_delivered():
    tmp = DELIVERED_FILE.with_suffix(".tmp")
    tmp.write_text(json.dumps(_delivered))
    tmp.replace(DELIVERED_FILE)


def record_send_result(msg_id, session_id, result):
    """Remembers the outcome of a client-generated send id so a retried
    POST with the same id replays the original result instead of acting
    (typing into tmux, or appending to the queue file) a second time."""
    if not msg_id:
        return
    with _delivered_lock:
        _delivered[msg_id] = {"session_id": session_id, "result": result, "ts": time.time()}
        if len(_delivered) % 20 == 0:  # cheap, infrequent prune-and-persist
            now = time.time()
            for k in [k for k, v in _delivered.items() if now - v.get("ts", 0) >= DELIVERED_RETENTION_SEC]:
                del _delivered[k]
        _save_delivered()


def lookup_send_result(msg_id):
    if not msg_id:
        return None
    with _delivered_lock:
        entry = _delivered.get(msg_id)
        return dict(entry["result"]) if entry else None


def rate_limited(ip, bucket, limit, window=10):
    now = time.time()
    key = (ip, bucket)
    with _rate_lock:
        hits = _rate_hits[key]
        hits[:] = [t for t in hits if now - t < window]
        if len(hits) >= limit:
            return True
        hits.append(now)
        return False


# ---------------------------------------------------------------------------
# HTTP handler
# ---------------------------------------------------------------------------

class Handler(http.server.BaseHTTPRequestHandler):
    server_version = "claude-agents/1.0"

    def log_message(self, fmt, *args):
        pass  # we do our own logging below

    def handle_error(self, request, client_address):
        # An Android client abandoning a long-poll /stream request mid-flight
        # (screen off, app backgrounded, tunnel blip) is routine and happens
        # constantly with dozens of concurrent phone polls -- the base
        # handler's default handle_error prints a full traceback to stderr
        # for it, which just floods `journalctl --user -u claude-agents`
        # with noise for something that isn't a real error. Anything else
        # still gets the real traceback.
        exc = sys.exc_info()[1]
        if isinstance(exc, (BrokenPipeError, ConnectionResetError, TimeoutError)):
            log(f"client {client_address[0]} dropped mid-response: {exc}")
            return
        super().handle_error(request, client_address)

    def _reject(self, code, msg="denied"):
        body = json.dumps({"error": msg}).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _ok(self, obj, code=200):
        body = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _security_check(self, bucket="read", limit=1000):
        ip = self.client_address[0]
        try:
            addr = ipaddress.ip_address(ip)
            if isinstance(addr, ipaddress.IPv6Address) and addr.ipv4_mapped:
                addr = addr.ipv4_mapped
        except Exception:
            log(f"deny: unparseable source {ip}")
            self._reject(403, "forbidden")
            return False
        if addr not in ALLOWED_SUBNET and not addr.is_loopback:
            log(f"deny: source {ip} not in {ALLOWED_SUBNET}")
            self._reject(403, "forbidden")
            return False
        if self.headers.get("Origin") is not None:
            log(f"deny: Origin header present from {ip}")
            self._reject(403, "forbidden")
            return False
        token = self.headers.get("X-Claude-Agents-Token", "")
        if not hmac.compare_digest(token, TOKEN):
            log(f"deny: bad token from {ip}")
            self._reject(401, "unauthorized")
            return False
        if rate_limited(ip, bucket, limit):
            log(f"deny: rate limited {ip} ({bucket})")
            self._reject(429, "rate limited")
            return False
        return True

    def do_GET(self):
        if not self._security_check():
            return
        parsed = urllib.parse.urlsplit(self.path)
        path = parsed.path
        qs = urllib.parse.parse_qs(parsed.query)
        ip = self.client_address[0]

        if path == "/api/v1/accounts":
            out = [{"dir_key": v["dir_key"], "label": v["label"], "email": v["email"]} for v in ACCOUNT_MAP.values()]
            return self._ok(out)

        if path == "/api/v1/conversations":
            account = (qs.get("account") or [None])[0]
            return self._ok(list_conversations(account))

        m = re.match(r"^/api/v1/attachments/([0-9a-f]{32})$", path)
        if m:
            attachment_id = m.group(1)
            # attachment_id is regex-validated hex above, before it ever
            # touches a filesystem path -- no path-traversal input reaches
            # here regardless of what a caller sends.
            meta_path = UPLOADS_DIR / f"{attachment_id}.json"
            blob_path = UPLOADS_DIR / attachment_id
            if not (meta_path.is_file() and blob_path.is_file()):
                return self._reject(404, "not found")
            try:
                meta = json.loads(meta_path.read_text())
                data = blob_path.read_bytes()
            except Exception as e:
                log(f"attachment read failed for {attachment_id}: {e}")
                return self._reject(500, "read failed")
            return self._ok({
                "filename": meta.get("filename", "file"),
                "mime_type": meta.get("mime_type", "application/octet-stream"),
                "size": len(data),
                "data_base64": base64.b64encode(data).decode("ascii"),
            })

        m = re.match(r"^/api/v1/conversations/([0-9a-fA-F-]{36})/messages$", path)
        if m:
            session_id = m.group(1)
            p = find_conversation_path(session_id)
            if not p:
                return self._reject(404, "not found")
            since = int((qs.get("since") or ["0"])[0])
            meta = conversation_meta(p)
            return self._ok({
                "messages": read_messages_since(p, since),
                "context_pct": meta.get("context_pct"),
            })

        m = re.match(r"^/api/v1/conversations/([0-9a-fA-F-]{36})/stream$", path)
        if m:
            session_id = m.group(1)
            p = find_conversation_path(session_id)
            if not p:
                return self._reject(404, "not found")
            since = int((qs.get("since") or ["0"])[0])
            timeout = min(float((qs.get("timeout") or ["25"])[0]), 30.0)
            deadline = time.time() + timeout
            # Full re-parse from line 0 is the expensive part (a 20k-line
            # transcript costs real CPU+churn) -- only worth paying once the
            # file has actually grown, not on every 1s tick of a 25s wait.
            # Confirmed the naive re-read-every-second version was the
            # actual cause of daemon RSS climbing toward MemoryMax during
            # normal ChatActivity polling, not a real leak elsewhere.
            last_size = -1
            msgs = []
            # A busy -> idle flip (or vice versa) with *no* new transcript
            # content in between used to have no early-exit at all here --
            # only new message bytes broke the wait, so the "Claude is
            # working…" indicator could sit stale for up to the full
            # timeout (confirmed live 2026-09-08: a 2s turn, but the
            # indicator kept spinning 20-30s after it actually finished).
            # get_live_sessions() is a cheap in-memory dict read (populated
            # by the daemon's own 5s background scan, not re-scanned per
            # request), so checking it on the same 1s tick this loop
            # already has is essentially free.
            initial_status = (get_live_sessions().get(session_id) or {}).get("status")
            while time.time() < deadline:
                try:
                    cur_size = p.stat().st_size
                except OSError:
                    break
                if cur_size != last_size:
                    last_size = cur_size
                    msgs = read_messages_since(p, since)
                    if msgs:
                        break
                cur_status = (get_live_sessions().get(session_id) or {}).get("status")
                if cur_status != initial_status:
                    break
                time.sleep(1)
            live = get_live_sessions().get(session_id)
            status = live.get("status") if live else None
            meta = conversation_meta(p)
            return self._ok({
                "messages": msgs,
                "status": status,
                "context_pct": meta.get("context_pct"),
            })

        m = re.match(r"^/api/v1/conversations/([0-9a-fA-F-]{36})/queue$", path)
        if m:
            session_id = m.group(1)
            qfile = QUEUE_DIR / f"{session_id}.jsonl"
            items = []
            if qfile.exists():
                for line in qfile.read_text().splitlines():
                    try:
                        items.append(json.loads(line))
                    except Exception:
                        pass
            return self._ok({"queued": items})

        log(f"404 {ip} GET {path}")
        self._reject(404, "not found")

    def do_POST(self):
        # sends land in a live tmux pane or a durable queue -- keep this
        # bucket tight regardless of how generous reads are, since it's the
        # one endpoint that can inject text into a session.
        if not self._security_check(bucket="send", limit=15):
            return
        parsed = urllib.parse.urlsplit(self.path)
        path = parsed.path
        ip = self.client_address[0]

        if path == "/api/v1/spawn":
            # Tighter than the "send" bucket - this starts a real Claude
            # Code process per call, not just a keystroke into an existing
            # one.
            if rate_limited(ip, "spawn", limit=5, window=60):
                log(f"deny: spawn rate limited {ip}")
                return self._reject(429, "rate limited")
            length = int(self.headers.get("Content-Length", "0"))
            if length <= 0 or length > 1_000_000:
                return self._reject(400, "bad request")
            try:
                body = json.loads(self.rfile.read(length))
            except Exception:
                return self._reject(400, "bad json")
            account = body.get("account", "claude2")
            text = body.get("text")
            if not isinstance(text, str) or not text.strip():
                return self._reject(400, "empty text")
            text = text[:20000]

            session_id, err = spawn_session(account, text)
            if err:
                log(f"spawn: failed for {ip}: {err}")
                return self._reject(500, err)
            log(f"spawn: started {session_id} (account={account}) for {ip}")
            return self._ok({"session_id": session_id, "account": account})

        m = re.match(r"^/api/v1/conversations/([0-9a-fA-F-]{36})/resume$", path)
        if m:
            # Archive view's send action: the conversation has no live
            # tmux pane, so relaunch it via `claude --resume` instead of
            # queuing text at nothing (see resume_session). Same "spawn a
            # real process" cost as /spawn, so it shares that tighter rate
            # bucket rather than plain /send's.
            if rate_limited(ip, "spawn", limit=5, window=60):
                log(f"deny: resume rate limited {ip}")
                return self._reject(429, "rate limited")
            session_id = m.group(1)
            length = int(self.headers.get("Content-Length", "0"))
            if length <= 0 or length > 1_000_000:
                return self._reject(400, "bad request")
            try:
                body = json.loads(self.rfile.read(length))
            except Exception:
                return self._reject(400, "bad json")
            text = body.get("text")
            if not isinstance(text, str) or not text.strip():
                return self._reject(400, "empty text")
            text = text[:20000]
            msg_id = body.get("id")
            if not (isinstance(msg_id, str) and msg_id):
                msg_id = None
                log(f"resume: no id from {ip} (older client build) -- can't dedupe a retry of this one")

            if msg_id:
                replay = lookup_send_result(msg_id)
                if replay is not None:
                    log(f"resume: replay id={msg_id} for {session_id} from {ip} (already handled, not re-sent)")
                    replay = dict(replay)
                    replay["replayed"] = True
                    return self._ok(replay)

            live = get_live_sessions().get(session_id)
            if live:
                # Already running again by the time this request landed --
                # deliver like a normal /send instead of resuming a second
                # process against the same session id.
                result = deliver_text_to_conversation(session_id, text, msg_id, ip, log_prefix="resume")
                return self._ok(result)

            new_session_id, err = resume_session(session_id, text)
            if err:
                log(f"resume: failed for {session_id} from {ip}: {err}")
                return self._reject(500, err)
            result = {"delivered": True, "via": "tmux", "resumed": True}
            record_send_result(msg_id, session_id, result)
            log(f"resume: relaunched {session_id} for {ip}")
            return self._ok(result)

        m = re.match(r"^/api/v1/conversations/([0-9a-fA-F-]{36})/send$", path)
        if m:
            session_id = m.group(1)
            length = int(self.headers.get("Content-Length", "0"))
            if length <= 0 or length > 1_000_000:
                return self._reject(400, "bad request")
            try:
                body = json.loads(self.rfile.read(length))
            except Exception:
                return self._reject(400, "bad json")
            text = body.get("text")
            if not isinstance(text, str) or not text.strip():
                return self._reject(400, "empty text")
            text = text[:20000]
            msg_id = body.get("id")
            if not (isinstance(msg_id, str) and msg_id):
                msg_id = None
                log(f"send: no id from {ip} (older client build) -- can't dedupe a retry of this one")
            result = deliver_text_to_conversation(session_id, text, msg_id, ip)
            return self._ok(result)

        m = re.match(r"^/api/v1/conversations/([0-9a-fA-F-]{36})/attachments$", path)
        if m:
            session_id = m.group(1)
            if not find_conversation_path(session_id):
                return self._reject(404, "not found")
            if rate_limited(ip, "upload", limit=UPLOAD_RATE_LIMIT, window=60):
                log(f"deny: upload rate limited {ip}")
                return self._reject(429, "rate limited")
            length = int(self.headers.get("Content-Length", "0"))
            # Rejected before ever reading the body -- an oversized upload
            # must never be buffered into memory first and validated after.
            # Base64 inflates size by ~4/3, so the raw request is checked
            # against that inflated ceiling; the decoded-bytes size is
            # re-checked below regardless (a malformed/truncated encoding
            # could still slip a bigger payload past this first gate).
            if length <= 0 or length > int(MAX_UPLOAD_BYTES * 4 / 3) + 4096:
                return self._reject(400, "bad request")
            try:
                body = json.loads(self.rfile.read(length))
            except Exception:
                return self._reject(400, "bad json")
            filename = body.get("filename")
            mime_type = body.get("mime_type")
            data_b64 = body.get("data_base64")
            caption = body.get("caption") or ""
            if not isinstance(filename, str) or not filename.strip():
                return self._reject(400, "missing filename")
            if not isinstance(mime_type, str) or not mime_type.strip():
                return self._reject(400, "missing mime_type")
            if not isinstance(data_b64, str) or not data_b64:
                return self._reject(400, "missing data_base64")
            if not isinstance(caption, str):
                return self._reject(400, "bad caption")
            caption = caption[:2000]
            try:
                data = base64.b64decode(data_b64, validate=True)
            except Exception:
                return self._reject(400, "bad base64")
            if len(data) == 0 or len(data) > MAX_UPLOAD_BYTES:
                return self._reject(400, "file too large or empty")
            msg_id = body.get("id")
            if not (isinstance(msg_id, str) and msg_id):
                msg_id = None
            if msg_id:
                replay = lookup_send_result(msg_id)
                if replay is not None:
                    log(f"upload: replay id={msg_id} for {session_id} from {ip} (already handled, not re-sent)")
                    replay = dict(replay)
                    replay["replayed"] = True
                    return self._ok(replay)
            try:
                attachment_id, stored_mime = save_attachment(session_id, filename, mime_type, data)
            except Exception as e:
                log(f"upload: failed to store attachment for {session_id} from {ip}: {e}")
                return self._reject(500, "failed to store attachment")
            kind = "image" if stored_mime.startswith("image/") else "file"
            ref_text = f"[{kind} attached: {UPLOADS_DIR / attachment_id}, original name: {filename}, {len(data)} bytes]"
            if caption.strip():
                ref_text += f"\n{caption}"
            result = deliver_text_to_conversation(session_id, ref_text, msg_id, ip, log_prefix="upload")
            result["attachment_id"] = attachment_id
            return self._ok(result)

        log(f"404 {ip} POST {path}")
        self._reject(404, "not found")


class Server(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True
    allow_reuse_address = True


def main():
    QUEUE_DIR.mkdir(parents=True, exist_ok=True)
    _load_delivered()
    t = threading.Thread(target=live_scan_loop, daemon=True)
    t.start()
    srv = Server((BIND_IP, PORT), Handler)
    log(f"claude-agents listening on {BIND_IP}:{PORT}")
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()

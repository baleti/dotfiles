#!/usr/bin/env python3
"""claude-relay: HTTP bridge between host3's tmux/claude sessions and the
Claude Relay Android app, over WireGuard only.

Security model (mirrors ~/peeragent's BridgeHttpServer.kt on the phone):
  - socket bound to the WireGuard interface IP only, never 0.0.0.0
  - peer IP must be in ALLOWED_SUBNET
  - X-Claude-Relay-Token header must match the on-disk token (constant-time)
  - any Origin header -> reject (no browser caller has legitimate business)
  - no CORS headers, ever
  - naive per-IP rate limit on mutating endpoints
  - token itself is never logged
"""
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
from collections import defaultdict
from pathlib import Path

HOME = Path.home()
CONFIG_DIR = HOME / ".config" / "claude-relay"
TOKEN_FILE = CONFIG_DIR / "token"
LIVE_FILE = CONFIG_DIR / "live-sessions.json"
QUEUE_DIR = CONFIG_DIR / "queue"
LOG_FILE = CONFIG_DIR / "daemon.log"
PROJECTS_DIR = HOME / ".claude" / "projects"

BIND_IP = "10.10.0.2"
PORT = 8790
ALLOWED_SUBNET = ipaddress.ip_network("10.10.0.0/24")

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
    print(f"[claude-relay] generated pairing token: {tok}")
    print(f"[claude-relay] (also saved to {TOKEN_FILE}, 0600)")
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


def scan_live_sessions():
    panes = scan_tmux_panes()
    procs, children = build_proc_tree()
    result = {}
    # pending[proj_dir] = list of (pane_target, pid, dir_key) with no explicit
    # session id yet -- resolved below only when a cwd has exactly one
    # candidate pane, since with several sibling panes sharing a cwd there is
    # no external way to tell them apart and guessing risks routing a reply
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
        env = read_proc_environ(pid)
        dir_key = account_dir_key_from_config_dir(env.get("CLAUDE_CONFIG_DIR"))
        if session_id:
            _record_live(result, session_id, dir_key, pane["target"], "exact")
        else:
            cwd = read_proc_cwd(pid)
            proj_dir = cwd_to_project_dir(cwd)
            if proj_dir and proj_dir.is_dir():
                pending[str(proj_dir)].append((pane["target"], dir_key))
    for proj_dir_str, group in pending.items():
        if len(group) != 1:
            continue  # ambiguous cwd shared by multiple live panes -- skip
        pane_target, dir_key = group[0]
        jsonls = sorted(Path(proj_dir_str).glob("*.jsonl"), key=lambda p: p.stat().st_mtime, reverse=True)
        if jsonls:
            _record_live(result, jsonls[0].stem, dir_key, pane_target, "cwd-heuristic")
    return result


def _record_live(result, session_id, dir_key, pane_target, confidence):
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
    }


_jsonl_index_cache = {"mtime": 0, "index": {}}


def PROJECTS_DIR_glob_by_id(session_id):
    # cheap cached id -> path index, rebuilt if the projects dir changed
    try:
        top_mtime = PROJECTS_DIR.stat().st_mtime
    except Exception:
        return None
    if top_mtime != _jsonl_index_cache["mtime"]:
        idx = {}
        try:
            for d in PROJECTS_DIR.iterdir():
                if d.is_dir():
                    for f in d.glob("*.jsonl"):
                        idx[f.stem] = f
        except Exception:
            pass
        _jsonl_index_cache["mtime"] = top_mtime
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


def send_to_pane(pane_target, text):
    try:
        subprocess.run(["tmux", "send-keys", "-t", pane_target, "-l", "--", text],
                        check=True, timeout=5)
        subprocess.run(["tmux", "send-keys", "-t", pane_target, "Enter"], check=True, timeout=5)
        return True
    except Exception as e:
        log(f"send_to_pane({pane_target}) failed: {e}")
        return False


def live_scan_loop():
    while True:
        try:
            sessions = scan_live_sessions()
            with _live_lock:
                _live_sessions.clear()
                _live_sessions.update(sessions)
            with open(LIVE_FILE, "w") as f:
                json.dump(sessions, f)
            drain_queue(sessions)
        except Exception as e:
            log(f"live_scan_loop error: {e}")
        time.sleep(5)


def get_live_sessions():
    with _live_lock:
        return dict(_live_sessions)


# ---------------------------------------------------------------------------
# Transcript parsing
# ---------------------------------------------------------------------------

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
            name = block.get("name", "?")
            try:
                arg_str = json.dumps(block.get("input", {}))[:200]
            except Exception:
                arg_str = ""
            parts.append(f"→ {name}({arg_str})")
        elif t == "tool_result":
            c = block.get("content")
            if isinstance(c, str):
                parts.append(c[:2000])
            elif isinstance(c, list):
                for cc in c:
                    if isinstance(cc, dict) and cc.get("type") == "text":
                        parts.append(cc.get("text", "")[:2000])
        # "thinking" blocks intentionally omitted (bandwidth + noise)
    return "\n".join(p for p in parts if p)


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
    text = summarize_content_blocks(msg.get("content"))
    if not text.strip():
        return None
    return {
        "line": line_no,
        "role": role,
        "text": text,
        "ts": d.get("timestamp"),
        "uuid": d.get("uuid"),
    }


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


def count_lines(path):
    n = 0
    with open(path, "rb") as f:
        for _ in f:
            n += 1
    return n


_conv_meta_cache = {}  # path -> (mtime, size, meta)


def conversation_meta(path):
    st = path.stat()
    key = str(path)
    cached = _conv_meta_cache.get(key)
    if cached and cached[0] == st.st_mtime and cached[1] == st.st_size:
        return cached[2]
    owner_uuid = owner_account_uuid_of_jsonl(path)
    account_info = ACCOUNT_MAP.get(owner_uuid) if owner_uuid else None
    meta = {
        "id": path.stem,
        "title": first_user_text(path),
        "mtime": st.st_mtime,
        "line_count": count_lines(path),
        "account": account_info["dir_key"] if account_info else "unknown",
        "account_label": account_info["label"] if account_info else "unknown",
    }
    _conv_meta_cache[key] = (st.st_mtime, st.st_size, meta)
    return meta


def list_conversations(account_filter=None):
    live = get_live_sessions()
    out = []
    if not PROJECTS_DIR.is_dir():
        return out
    for proj_dir in PROJECTS_DIR.iterdir():
        if not proj_dir.is_dir():
            continue
        for f in proj_dir.glob("*.jsonl"):
            try:
                meta = dict(conversation_meta(f))
            except Exception as e:
                log(f"meta failed for {f}: {e}")
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
    server_version = "claude-relay/1.0"

    def log_message(self, fmt, *args):
        pass  # we do our own logging below

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
        token = self.headers.get("X-Claude-Relay-Token", "")
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

        m = re.match(r"^/api/v1/conversations/([0-9a-fA-F-]{36})/messages$", path)
        if m:
            session_id = m.group(1)
            p = find_conversation_path(session_id)
            if not p:
                return self._reject(404, "not found")
            since = int((qs.get("since") or ["0"])[0])
            return self._ok({"messages": read_messages_since(p, since)})

        m = re.match(r"^/api/v1/conversations/([0-9a-fA-F-]{36})/stream$", path)
        if m:
            session_id = m.group(1)
            p = find_conversation_path(session_id)
            if not p:
                return self._reject(404, "not found")
            since = int((qs.get("since") or ["0"])[0])
            timeout = min(float((qs.get("timeout") or ["25"])[0]), 30.0)
            deadline = time.time() + timeout
            msgs = []
            while time.time() < deadline:
                msgs = read_messages_since(p, since)
                if msgs:
                    break
                time.sleep(1)
            return self._ok({"messages": msgs})

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

            live = get_live_sessions().get(session_id)
            if live:
                ok = send_to_pane(live["pane"], text)
                if ok:
                    log(f"send: delivered to {session_id} via {live['pane']} from {ip}")
                    return self._ok({"delivered": True, "via": "tmux", "pane": live["pane"]})
                # fall through to queue on send failure

            QUEUE_DIR.mkdir(parents=True, exist_ok=True)
            qfile = QUEUE_DIR / f"{session_id}.jsonl"
            with open(qfile, "a") as f:
                f.write(json.dumps({"text": text, "queued_at": time.time()}) + "\n")
            log(f"send: queued for {session_id} from {ip} (no live pane)")
            return self._ok({"delivered": False, "queued": True})

        log(f"404 {ip} POST {path}")
        self._reject(404, "not found")


class Server(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True
    allow_reuse_address = True


def main():
    QUEUE_DIR.mkdir(parents=True, exist_ok=True)
    t = threading.Thread(target=live_scan_loop, daemon=True)
    t.start()
    srv = Server((BIND_IP, PORT), Handler)
    log(f"claude-relay listening on {BIND_IP}:{PORT}")
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()

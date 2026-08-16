#!/usr/bin/env python3
"""Full-text search over Claude Code conversation history (prefix+C-c).

Sibling to window-search.py (prefix+C-w, scrollback) and focus-picker.py
(prefix+W, MRU panes) - same fzf-popup shape, same BM25-ish ranking idea,
same #{client_tty}-bridging and verified switch-client sequence. What's
different is the corpus: not live pane scrollback but every past
conversation Claude Code has ever saved, in ~/.claude/projects/*/*.jsonl
(one file per session; nested */subagents/agent-*.jsonl files are forked
subagent transcripts, not resumable top-level sessions, so the glob below
deliberately stays at exactly one directory level and never recurses into
them).

Enter on a result does one of two things:
  - if that session has a live, verified-alive Claude Code process attached
    to a tmux pane right now: switch-client there (same jump() sequence as
    window-search.py) rather than starting a second instance against the
    same transcript.
  - otherwise: send `claude --resume <id> --dangerously-skip-permissions`
    into the ORIGIN pane (the one that opened the picker), i.e. the current
    shell picks up the resume - not a new popup, not a new window (unless
    the origin pane turns out not to be at a shell prompt - see
    resume_in_pane).

"Live right now" is answered by Claude Code's own bookkeeping rather than
guessed: every running interactive session maintains
~/.claude*/sessions/<pid>.json (one per CLAUDE_CONFIG_DIR - .claude,
.claude2, .claude3 here all happen to share the same underlying
~/.claude/projects via symlink, but each keeps its own independent
sessions/ directory of currently-running pids) containing sessionId, pid,
procStart (the process's /proc/<pid>/stat start-time, in clock ticks - the
same disambiguator the kernel itself uses to tell a live pid from a reused
one), and, when launched inside tmux, a "tmux" field of the form
"session_name:@window_id.%pane_id" - a pane_id is a stable, globally unique
tmux target on its own, no window/session lookup needed. This was found by
inspecting that directory directly (see the window-search-debugging-session
memory for the same "verify against real state" approach) rather than
inferring liveness from process argv or scanning /proc/*/fd for an open
transcript file - the latter looked appealing but Claude Code opens,
appends, and closes the jsonl per write rather than holding it open, so an
fd-scan mostly observes "not open" for a session that is very much running.
procStart is re-checked against /proc/<pid>/stat at both list-time and
jump-time - a sessions/*.json file left behind by a killed/crashed process
is a stale claim, not a live one, and pid reuse by the OS would otherwise
make a stale entry look alive again.

Deps: tmux, fzf, python3.
"""
import argparse
import atexit
import glob
import json
import math
import os
import re
import shlex
import signal
import subprocess
import sys
import tempfile
import time
from concurrent.futures import ThreadPoolExecutor
from collections import namedtuple

CLAUDE_DIR = os.path.expanduser(os.environ.get("CLAUDE_CONFIG_DIR", "~/.claude"))
PROJECTS_GLOB = os.path.join(CLAUDE_DIR, "projects", "*", "*.jsonl")
# every CLAUDE_CONFIG_DIR-like directory keeps its own live-session
# registry (see module docstring) - bounded to ~/.claude* (a handful of
# dirs), never an unbounded $HOME scan
SESSIONS_GLOB = os.path.expanduser("~/.claude*/sessions/*.json")

MAX_MSG_CHARS = 20000  # cap one message's indexed/stored text - same guard
# window-search's CAPTURE_LINES is, against one pasted file dump or huge
# tool transcript blowing up snapshot size/tokenize time for one outlier
TITLE_BOOST = 8  # mirrors window-search's PANE_TITLE_BOOST: the AI-generated
# title is a deliberate one-line summary of the whole conversation, a much
# stronger signal than the same word merely occurring somewhere in it
USER_BOOST = 2  # what you typed is what you'll later search for; the
# assistant's (usually much longer) reply gets no boost so it doesn't drown
# the user's own words out just by being verbose
K1, B = 1.5, 0.75  # standard Okapi BM25 defaults, see window-search.py

TOKEN_RE = re.compile(r"[a-z0-9]+")
SHELLS = {"bash", "zsh", "sh", "fish", "dash"}

_DEBUG = os.path.exists(os.path.expanduser("~/.cache/claude-history-search-debug"))
_T0 = time.time()


def _dbg(msg):
    if not _DEBUG:
        return
    with open(os.path.expanduser("~/.cache/claude-history-search-timing.log"), "a") as f:
        f.write(f"[abs={time.time():.3f} rel={time.time() - _T0:.3f} pid={os.getpid()}] {msg}\n")


def tokenize(text):
    return TOKEN_RE.findall(text.lower())


# --- query language: identical to window-search.py's (see there for the
# full reasoning) - bare words are prefix-expanded and ANDed, "phrases" are
# exact and required, !negated drops, and a bare word carrying punctuation
# ("--stat", "ctrl+.") gets a soft literal bonus without filtering anything.
# Duplicated rather than imported: these two tools evolve independently and
# the query engine is the only thing they share (same reasoning
# focus-picker.py gives for not sharing jump() as a module).
QUERY_ELEM_RE = re.compile(r'(!?)(?:"([^"]*)"|(\S+))')
MATCH_MODE = os.environ.get("TMUX_WINDOW_SEARCH_MATCH", "all").lower()

Query = namedtuple("Query", "terms phrases neg_terms neg_phrases soft")


def parse_query(query):
    terms, phrases, neg_terms, neg_phrases, soft = [], [], [], [], []
    for neg, quoted, bare in QUERY_ELEM_RE.findall(query):
        if bare:
            toks = tokenize(bare)
            for tok in toks:
                (neg_terms if neg else terms).append(tok)
            if not neg and toks and any(not c.isalnum() for c in bare):
                soft.append(bare.lower())
        elif quoted.strip():
            (neg_phrases if neg else phrases).append(quoted.strip().lower())
    return Query(terms, phrases, neg_terms, neg_phrases, soft)


def phrase_re(raw, prefix=False):
    raw = raw.strip().lower()
    parts = [p for p in re.split(r"(\s+)", raw) if p]
    pattern = "".join(r"\s+" if p.isspace() else re.escape(p) for p in parts)
    pre = r"(?<![a-z0-9])" if raw[:1].isalnum() else ""
    post = "" if prefix else (r"(?![a-z0-9])" if raw[-1:].isalnum() else "")
    return re.compile(pre + pattern + post)


CONNECTOR_RE = re.compile(r"^[^\sA-Za-z0-9]+$")


def highlight(text, qset, rxs=()):
    if not qset and not rxs:
        return text
    low = text.lower()
    spans = []
    for rx in rxs:
        for m in rx.finditer(low):
            spans.append((m.start(), m.end()))
    matches = list(TOKEN_RE.finditer(low))
    i = 0
    while i < len(matches):
        if not any(matches[i].group().startswith(q) for q in qset):
            i += 1
            continue
        start, end = matches[i].start(), matches[i].end()
        j = i + 1
        while (j < len(matches)
               and any(matches[j].group().startswith(q) for q in qset)
               and CONNECTOR_RE.match(text[end:matches[j].start()])):
            end = matches[j].end()
            j += 1
        spans.append((start, end))
        i = j
    spans.sort()
    merged = []
    for s, e in spans:
        if merged and s <= merged[-1][1]:
            merged[-1][1] = max(merged[-1][1], e)
        else:
            merged.append([s, e])
    for start, end in reversed(merged):
        text = text[:start] + "\x1b[1;33m" + text[start:end] + "\x1b[0m" + text[end:]
    return text


def expand_prefix(prefix, vocab):
    from bisect import bisect_left
    lo = bisect_left(vocab, prefix)
    hi = bisect_left(vocab, prefix + "￿")
    return vocab[lo:hi]


def bm25_term_score(f, n_q, dl, n, avgdl):
    if f == 0:
        return 0.0
    idf = math.log((n - n_q + 0.5) / (n_q + 0.5) + 1)
    return idf * (f * (K1 + 1)) / (f + K1 * (1 - B + B * dl / avgdl))


# --- conversation parsing --------------------------------------------------

def extract_text(content):
    """message.content is either a plain string (typical user turn) or a
    list of content blocks (assistant turns, and user turns carrying a
    tool_result). Only "text" blocks are pulled out - thinking blocks are
    internal monologue nobody searches for by its wording, and tool_use/
    tool_result are the noisiest and largest part of a transcript (whole
    file contents, command output) for the least search value; skipping
    them is what keeps the indexed corpus at a few MB instead of the ~270MB
    these transcripts take up on disk raw."""
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        parts = [b.get("text", "") for b in content
                 if isinstance(b, dict) and b.get("type") == "text"]
        return "\n".join(p for p in parts if p)
    return ""


def parse_session(path):
    session_id = cwd = ai_title = first_ts = last_ts = None
    turns = []
    msg_count = 0
    try:
        with open(path, errors="replace") as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                try:
                    d = json.loads(line)
                except ValueError:
                    continue
                t = d.get("type")
                if t == "ai-title":
                    ai_title = d.get("aiTitle") or ai_title
                    session_id = session_id or d.get("sessionId")
                    continue
                if t not in ("user", "assistant"):
                    continue
                session_id = session_id or d.get("sessionId") or d.get("session_id")
                cwd = d.get("cwd") or cwd
                ts = d.get("timestamp")
                if ts:
                    first_ts = first_ts or ts
                    last_ts = ts
                msg = d.get("message") or {}
                text = extract_text(msg.get("content")).strip()
                if not text:
                    continue
                msg_count += 1
                if len(text) > MAX_MSG_CHARS:
                    text = text[:MAX_MSG_CHARS] + " …[truncated]"
                turns.append((msg.get("role", t), text))
    except OSError as e:
        _dbg(f"parse_session {path} failed: {e}")
        return None
    if session_id is None or not turns:
        return None
    return {
        "session_id": session_id, "path": path, "cwd": cwd or "?",
        "ai_title": ai_title, "turns": turns, "msg_count": msg_count,
        "first_ts": first_ts, "last_ts": last_ts,
        "mtime": os.path.getmtime(path),
    }


def build_snapshot():
    files = glob.glob(PROJECTS_GLOB)
    if not files:
        die(f"no conversation history found matching {PROJECTS_GLOB}")

    with ThreadPoolExecutor(max_workers=min(16, len(files))) as ex:
        parsed = [s for s in ex.map(parse_session, files) if s]

    sessions = {}
    for s in parsed:
        tf, doclen = {}, 0
        for role, text in s["turns"]:
            counts = {}
            for tok in TOKEN_RE.findall(text.lower()):
                counts[tok] = counts.get(tok, 0) + 1
            boost = USER_BOOST if role == "user" else 1
            for tok, c in counts.items():
                tf[tok] = tf.get(tok, 0.0) + c * boost
            doclen += sum(counts.values()) * boost
        if s["ai_title"]:
            title_tokens = tokenize(s["ai_title"])
            for tok in title_tokens * TITLE_BOOST:
                tf[tok] = tf.get(tok, 0) + 1.0
            doclen += TITLE_BOOST * len(title_tokens)
        sessions[s["session_id"]] = {**s, "tf": tf, "doclen": doclen}

    df = {}
    for s in sessions.values():
        for tok in s["tf"]:
            df[tok] = df.get(tok, 0) + 1

    avgdl = sum(s["doclen"] for s in sessions.values()) / max(1, len(sessions))
    vocab = sorted(df.keys())
    return {"sessions": sessions, "df": df, "n": len(sessions), "avgdl": avgdl,
            "vocab": vocab}


# --- live-session detection -------------------------------------------------

def proc_start_ticks(pid):
    """/proc/<pid>/stat field 22 (starttime, clock ticks since boot) - the
    kernel's own answer to "is this really the same process", immune to pid
    reuse. comm (field 2) can contain spaces or parens, so this splits after
    the matching ')' the way procps itself does rather than on whitespace."""
    try:
        with open(f"/proc/{pid}/stat") as f:
            content = f.read()
        fields = content[content.rindex(")") + 2:].split()
        return fields[19]  # field 22, minus the 3 consumed (pid, comm, state)
    except (OSError, ValueError, IndexError):
        return None


def get_live_sessions():
    """session_id -> {pid, pane_id, status, cwd} for every session whose
    sessions/<pid>.json still names a pid that (a) exists and (b) has the
    same /proc start-time procStart records - see module docstring for why
    both checks matter. pane_id is parsed out of the "session:@win.%pane"
    tmux field tmux(1) accepts a bare %pane_id as a fully-qualified target,
    so nothing else about the window/session needs resolving."""
    live = {}
    for jf in glob.glob(SESSIONS_GLOB):
        try:
            with open(jf) as f:
                d = json.load(f)
        except (OSError, ValueError):
            continue
        pid, proc_start, sid = d.get("pid"), d.get("procStart"), d.get("sessionId")
        if not (pid and proc_start and sid):
            continue
        if proc_start_ticks(pid) != str(proc_start):
            continue  # dead, or the pid was recycled by something else
        tmux_field = d.get("tmux") or ""
        pane_id = None
        if "." in tmux_field:
            tail = tmux_field.rsplit(".", 1)[-1]
            if tail.startswith("%"):
                pane_id = tail
        live[sid] = {"pid": pid, "pane_id": pane_id,
                     "status": d.get("status", "?"), "cwd": d.get("cwd")}
    return live


# --- rendering ---------------------------------------------------------------

HOME = os.path.expanduser("~")


def shorten(path):
    if not path:
        return "?"
    return "~" + path[len(HOME):] if path.startswith(HOME) else path


def relative_age(mtime):
    secs = time.time() - mtime
    if secs < 60:
        return "just now"
    if secs < 3600:
        return f"{int(secs // 60)}m ago"
    if secs < 86400:
        return f"{int(secs // 3600)}h ago"
    return f"{int(secs // 86400)}d ago"


STATUS_COLOR = {"busy": "\x1b[1;33m", "waiting": "\x1b[1;33m"}  # default: green


def live_badge(live):
    if not live:
        return "  "
    color = STATUS_COLOR.get(live["status"], "\x1b[1;32m")
    return f"{color}●\x1b[0m"


def row(sid, s, live_map, qset=frozenset(), rxs=()):
    badge = live_badge(live_map.get(sid))
    age = relative_age(s["mtime"])
    title = s["ai_title"] or (s["turns"][0][1][:80] if s["turns"] else "(empty)")
    title = highlight(title.replace("\n", " ").strip(), qset, rxs)
    label = f'{badge} {age:>8}  {shorten(s["cwd"]):<40}  {title}  ({s["msg_count"]}m)'
    return f"{sid}\t{label}"


# --- search / preview subcommands (invoked by fzf's reload on every keystroke,
# same shape as window-search.py's --search/--preview) --------------------

def search(snapshot_path, query):
    with open(snapshot_path) as f:
        snap = json.load(f)
    sessions, df, n, avgdl = snap["sessions"], snap["df"], snap["n"], snap["avgdl"]
    live_map = get_live_sessions()  # fetched fresh every keystroke - real
    # process state, not the once-per-popup snapshot, so status updates
    # (idle -> busy) show up live while you're still typing your search
    q = parse_query(query)

    if not any(q):
        ranked = sorted(sessions.items(), key=lambda kv: -kv[1]["mtime"])
        for sid, s in ranked:
            print(row(sid, s, live_map))
        return

    vocab = snap["vocab"]
    groups = [expand_prefix(tok, vocab) for tok in q.terms]
    terms = [t for g in groups for t in g]
    neg_terms = {t for tok in q.neg_terms for t in expand_prefix(tok, vocab)}

    rxs = [phrase_re(p) for p in q.phrases]
    neg_rxs = [phrase_re(p) for p in q.neg_phrases]
    soft_rxs = [phrase_re(s, prefix=True) for s in q.soft]

    scored = []
    for sid, s in sessions.items():
        if neg_terms and not neg_terms.isdisjoint(s["tf"]):
            continue
        text = "\n".join(t for _, t in s["turns"]).lower()
        if any(rx.search(text) for rx in neg_rxs):
            continue
        if rxs and not all(rx.search(text) for rx in rxs):
            continue
        if MATCH_MODE == "all" and not all(
                any(s["tf"].get(t) for t in g) for g in groups):
            continue

        score = 0.0
        dl = s["doclen"]
        for term in terms:
            f = s["tf"].get(term, 0)
            if f:
                score += bm25_term_score(f, df.get(term, 0), dl, n, avgdl)
        for rx in rxs:
            hits = len(rx.findall(text))
            if hits:
                df_p = sum(1 for _, s2 in sessions.items()
                           if rx.search("\n".join(t for _, t in s2["turns"]).lower()))
                score += bm25_term_score(hits, df_p, dl, n, avgdl)
        for rx in soft_rxs:
            hits = len(rx.findall(text))
            if hits:
                score += bm25_term_score(hits, 1, dl, n, avgdl)
        if score > 0 or (not terms and not rxs):
            scored.append((score if (terms or rxs) else s["mtime"], sid, s))

    scored.sort(key=lambda t: -t[0])
    qset = set(q.terms)
    show_rxs = rxs + soft_rxs
    for _, sid, s in scored:
        print(row(sid, s, live_map, qset, show_rxs))


PREVIEW_CONTEXT_TURNS = 2  # turns of leading context kept above a jumped-to match


def preview(session_id, query, snap_path):
    if not snap_path or not os.path.exists(snap_path):
        print("[snapshot unavailable]")
        return
    with open(snap_path) as f:
        snap = json.load(f)
    s = snap["sessions"].get(session_id)
    if not s:
        print("[session not found in snapshot]")
        return

    q = parse_query(query)
    qset = set(q.terms)
    rxs = ([phrase_re(p) for p in q.phrases]
           + [phrase_re(soft, prefix=True) for soft in q.soft])

    live_map = get_live_sessions()
    live = live_map.get(session_id)
    header = f"{shorten(s['cwd'])}  ·  {s['msg_count']} messages  ·  {relative_age(s['mtime'])}"
    if live:
        where = f"pane {live['pane_id']}" if live["pane_id"] else "not in tmux"
        header += f"\n\x1b[1;32m● running now\x1b[0m (pid {live['pid']}, {live['status']}, {where})"
    print(header)
    print("─" * 60)

    turns = s["turns"]
    match_idx = None
    if qset or rxs:
        for i in range(len(turns) - 1, -1, -1):
            low = turns[i][1].lower()
            if any(rx.search(low) for rx in rxs):
                match_idx = i
                break
            if qset and any(t.startswith(q_) for t in tokenize(low) for q_ in qset):
                match_idx = i
                break

    start = 0
    if match_idx is not None and match_idx > PREVIEW_CONTEXT_TURNS:
        start = match_idx - PREVIEW_CONTEXT_TURNS
        print(f"… {start} earlier message(s) not shown …\n")

    for role, text in turns[start:]:
        who = "You" if role == "user" else "Claude"
        print(f"\x1b[1m{who}:\x1b[0m {highlight(text, qset, rxs)}\n")


# --- jump / resume -----------------------------------------------------------

def die(msg):
    _dbg(f"FATAL: {msg}")
    print(f"claude-history-search: {msg}", file=sys.stderr)
    sys.exit(1)


def jump_to_pane(client, pane_id):
    """Land the client on an already-running session's pane. Verbatim copy
    of window-search.py's jump() sequence (switch-client -c, then
    select-window/select-pane, then re-verified against a fresh
    list-clients rather than trusting the return code) - that sequence was
    hard-won against a real switch-client bug there, see its comments."""
    cr = subprocess.run(["tmux", "list-clients", "-F", "#{client_tty}\t#{session_name}"],
                        capture_output=True, text=True)
    if cr.returncode != 0:
        die(f"tmux list-clients failed (rc={cr.returncode}): {cr.stderr.strip()}")
    clients = {c: sn for c, sn in (line.split("\t") for line in cr.stdout.splitlines())}
    if client not in clients:
        die(f"client {client!r} isn't in the current attached-client list "
            f"{sorted(clients)!r} - can't target a switch-client to it")

    for cmd in (["switch-client", "-c", client, "-t", pane_id],
                ["select-window", "-t", pane_id],
                ["select-pane", "-t", pane_id]):
        r = subprocess.run(["tmux", *cmd], capture_output=True, text=True)
        if r.returncode != 0:
            die(f"tmux {' '.join(cmd)} failed: {r.stderr.strip()}")

    after = {c: p for c, p in (
        line.split("\t") for line in
        subprocess.run(["tmux", "list-clients", "-F", "#{client_tty}\t#{pane_id}"],
                        capture_output=True, text=True).stdout.splitlines()
    )}
    if after.get(client) != pane_id:
        die(f"selected {pane_id} but client {client} ended up on "
            f"{after.get(client)!r} instead - switch-client silently landed "
            f"on the wrong pane")


def display(client, msg):
    """tmux display-message with an explicit -c <client>: display-message
    with no target resolves ambiently, and with several attached clients
    (routine here - see the sessions/*.json dump above) there is no telling
    which one that lands on. Same lesson as switch-client throughout this
    file and resurrect-restore.sh's comment on the same pitfall."""
    subprocess.run(["tmux", "display-message", "-c", client, msg])


def resume_in_pane(client, origin_pane, session_id, cwd):
    """Run `claude --resume <id> --dangerously-skip-permissions` in the pane
    that opened the picker - the literal "current shell" the user asked for.
    Only injects keystrokes if that pane is actually sitting at a plain
    shell prompt right now (checked fresh, not from bind-time state): typing
    an arbitrary command into whatever else might be running there - vim,
    another claude session, anything with its own keymap - would be
    confusing at best. When it isn't a shell, a fresh window is opened in
    the right directory instead, so the resume still happens without
    guessing at what the origin pane was doing."""
    r = subprocess.run(["tmux", "display-message", "-p", "-t", origin_pane,
                        "#{pane_current_command}"], capture_output=True, text=True)
    current_cmd = r.stdout.strip() if r.returncode == 0 else None
    target = origin_pane
    if current_cmd not in SHELLS:
        # -t origin_pane: new-window with no target also resolves ambiently
        # (the attached client's current session) - anchoring it to the
        # origin pane's own session/window is well-defined regardless of
        # which client happens to be "current" from run-shell's point of view
        nr = subprocess.run(["tmux", "new-window", "-P", "-F", "#{pane_id}",
                             "-t", origin_pane, "-c", cwd or HOME],
                            capture_output=True, text=True)
        if nr.returncode != 0:
            die(f"origin pane {origin_pane} isn't at a shell prompt "
                f"({current_cmd!r}) and opening a new window failed: "
                f"{nr.stderr.strip()}")
        target = nr.stdout.strip()
        display(client, f"claude-history: origin pane was running "
                f"{current_cmd!r}, resuming in a new window instead")

    resume_cmd = f"cd {shlex.quote(cwd or HOME)} 2>/dev/null; " \
                 f"claude --resume {shlex.quote(session_id)} --dangerously-skip-permissions"
    subprocess.run(["tmux", "send-keys", "-t", target, "-l", "--", resume_cmd], check=True)
    subprocess.run(["tmux", "send-keys", "-t", target, "Enter"], check=True)


def resolve(session_id, cwd, client, origin_pane):
    live = get_live_sessions().get(session_id)  # re-checked fresh: time
    # passed while the user was browsing/searching, status may have changed
    if live and live["pane_id"]:
        jump_to_pane(client, live["pane_id"])
        display(client, f"claude-history: switched to the already-running "
                f"session (pid {live['pid']}, {live['status']})")
        return
    if live:
        display(client, f"claude-history: session is already running "
                f"elsewhere (pid {live['pid']}, cwd {live['cwd']}, not "
                f"attached to any tmux pane) - not resuming, that would "
                f"start a second instance against the same transcript")
        return
    resume_in_pane(client, origin_pane, session_id, cwd)


SNAP_PREFIX = "claude-history-search-"


def snapshot_dir():
    xdg = os.environ.get("XDG_RUNTIME_DIR")
    if xdg and os.path.isdir(xdg) and os.access(xdg, os.W_OK):
        return xdg
    return tempfile.gettempdir()


def _rm(path):
    try:
        os.unlink(path)
    except OSError:
        pass


def sweep_stale_snapshots():
    """Same reasoning as window-search.py's sweep - a snapshot here holds
    the extracted text of every conversation, so an interrupted invocation
    (popup dismissed with Escape, second C-c SIGHUPing the first) leaking
    it is worth cleaning up even though these run only a few MB each."""
    seen = set()
    for d in (snapshot_dir(), tempfile.gettempdir()):
        if d in seen:
            continue
        seen.add(d)
        try:
            names = os.listdir(d)
        except OSError:
            continue
        for name in names:
            if not (name.startswith(SNAP_PREFIX) and name.endswith(".json")):
                continue
            try:
                pid = int(name[len(SNAP_PREFIX):].split("-", 1)[0])
            except ValueError:
                continue
            try:
                os.kill(pid, 0)
                continue
            except ProcessLookupError:
                pass
            except OSError:
                continue
            _rm(os.path.join(d, name))


def drive(client, origin_pane):
    if not client:
        die("--client was empty - the bind-key's run-shell did not interpolate "
            "#{client_tty} (see .tmux.conf, prefix+C-c)")
    if not origin_pane:
        die("--origin-pane was empty - the bind-key's run-shell did not "
            "interpolate #{pane_id} (see .tmux.conf, prefix+C-c)")

    snapshot = build_snapshot()
    sweep_stale_snapshots()
    fd, snap_path = tempfile.mkstemp(prefix=f"{SNAP_PREFIX}{os.getpid()}-",
                                     suffix=".json", dir=snapshot_dir())
    atexit.register(lambda: _rm(snap_path))
    for sig in (signal.SIGHUP, signal.SIGTERM, signal.SIGINT):
        signal.signal(sig, lambda *_: sys.exit(1))
    with os.fdopen(fd, "w") as f:
        json.dump(snapshot, f)

    py = f"{shlex.quote(sys.executable)} {shlex.quote(os.path.abspath(__file__))}"
    self_cmd = f"{py} --search {shlex.quote(snap_path)} --query={{q}}"
    preview_cmd = f"{py} --preview {{1}} --query={{q}} --snapshot={shlex.quote(snap_path)}"
    resize_on_result = (
        'c=$FZF_MATCH_COUNT; list_rows=$((c + 3)); '
        '[ "$list_rows" -lt 4 ] && list_rows=4; '
        'max_list=$((FZF_LINES - 4)); '
        '[ "$list_rows" -gt "$max_list" ] && list_rows=$max_list; '
        'echo "change-preview-window(down,$((FZF_LINES - list_rows)))"'
    )
    try:
        result = subprocess.run(
            [
                "fzf", "--ansi", "--disabled", "--layout=reverse",
                "--delimiter", "\t", "--with-nth", "2..",
                "--prompt", "claude history> ",
                "--preview", preview_cmd,
                "--preview-window", "down,50%,border-top,wrap",
                "--bind", f"start:reload:{self_cmd}",
                "--bind", f"change:reload:{self_cmd}",
                "--bind", f"result:transform:{resize_on_result}",
                "--bind", "ctrl-left:backward-word",
                "--bind", "ctrl-right:forward-word",
            ],
            capture_output=True, text=True,
        )
    finally:
        _rm(snap_path)

    selected = result.stdout.strip()
    if not selected:
        return
    session_id = selected.split("\t", 1)[0]
    s = snapshot["sessions"].get(session_id)
    if not s:
        die(f"selected session {session_id} vanished from the snapshot")
    resolve(session_id, s["cwd"], client, origin_pane)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--search", metavar="SNAPSHOT")
    parser.add_argument("--preview", metavar="SESSION_ID")
    parser.add_argument("--query", default="")
    parser.add_argument("--snapshot", metavar="SNAPSHOT")
    parser.add_argument("--client", metavar="TTY")
    parser.add_argument("--origin-pane", metavar="PANE_ID")
    args = parser.parse_args()

    if args.preview:
        preview(args.preview, args.query, args.snapshot)
    elif args.search:
        search(args.search, args.query)
    else:
        drive(args.client, args.origin_pane)


if __name__ == "__main__":
    main()

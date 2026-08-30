#!/usr/bin/env python3
"""MRU pane switcher for tmux (prefix+w), distinct from both prefix+W (tmux's
own choose-tree) and prefix+C-w (window-search.py's full-text search): this
one lists windows/panes in the order the user last actually *visited* them,
most-recent first - no scoring, no scrollback content involved.

Every entry in that order comes from one real-timestamped log
(~/.cache/tmux-focus-order.log, written by focus-track.sh) fed by five tmux
hooks registered in .tmux.conf:

  - after-select-pane, after-select-window, session-window-changed,
    client-session-changed: explicit navigation commands *within* one
    terminal window (arrow keys, prefix+w, mouse, this picker's own jump).
    These only fire when a bound key or mouse action on an attached client
    changes the active pane - never when an unfocused pane merely produces
    output, which is what keeps a Claude Code session churning away in a
    background window from polluting the order: it never calls
    select-pane, so it never appends to the log no matter how much it
    prints.
  - client-focus-in: *switching to a different terminal window* (click,
    alt-tab, any window manager) runs no tmux command at all, so the four
    hooks above never fire for it - tmux has no visibility into
    window-manager focus by itself. What it does have natively is the
    terminal's own standard focus-reporting escape sequences (DEC private
    mode 1004, `focus-events on` in .tmux.conf): Alacritty sends focus-in
    to whichever pty currently has it the instant real OS focus changes,
    independent of window manager - no polling, no IPC socket, no daemon.

All five write through the same script into the same log with real
Unix timestamps, so - unlike an earlier version of this picker that tried
to merge tmux's log against a separately-queried Hyprland window-order
snapshot - there is one honest clock behind the whole list: no signal can
dominate the other just because it happens to update on a different scale.
A pane simply not yet hit by any hook sorts last, which is the only case
this can't say anything about.

The list is paired with a live preview of the highlighted pane's recent
scrollback (see preview()) and the same dynamic list/preview resize
window-search.py and claude-history already use - the list only takes as
many rows as it has matches, the preview gets the rest.

Query DSL (parse_query) - the /verb command grammar shared with winswitch
and the GTK pickers (see ~/.config/docs/query-dsl.md). The base list is
MRU-ordered; /sort and /reverse are opt-in on top of that.

  foo bar              every bare word must appear (case-insensitive
                       substring) somewhere in the pane's searchable text -
                       session, window name, title, and any tracked-but-
                       not-shown extra data (ssh host/ip - see COLUMN_GROUPS
                       below). A bare word is identical to /fv <word>.
  /fv session:word     scope: word must appear in one field (session /
  /filter-value ...    window / title). The field name is substring-
                       resolved (/fv se:foo reaches session).
  /at ssh.host         add a tracked column to the display; /at ssh adds
  /add-type ...        every ssh.* column. Group/sub substring-resolved.
  /rt ssh              remove matching columns (mirror of /at).
  /ft host             narrow the displayed extra columns to matches.
  /s title [desc]      order the list by session / window / title / time,
  /sort ...            optional ascending/descending (substring-matched).
  /rv  /reverse        reverse the current order.

Verb names are exact-matched (short or long form); everything else -
field names, group/sub, directions - is substring containment. "..."
quotes span whitespace and are the literal escape hatch. This exists
because tracking more per-pane data (ssh connection info today) shouldn't
mean permanent columns everyone sees - the data rides along in every
snapshot (computed once per invocation, see build_snapshot / ssh_info)
and stays searchable via bare words either way; /at//rt just change what
is visible.

Deps: tmux, fzf, python3. ssh columns additionally use ps, lsof.
"""
import argparse
import atexit
import json
import os
import re
import shlex
import signal
import subprocess
import sys
import tempfile
import time

LOG_PATH = os.path.expanduser("~/.cache/tmux-focus-order.log")
PREVIEW_LINES = 500  # recent scrollback only - this isn't a search tool
# (that's prefix+C-w), so there's no match to jump to or highlight; just
# enough tail to answer "what was I doing here"


def die(msg):
    print(f"focus-picker: {msg}", file=sys.stderr)
    sys.exit(1)


def read_focus_order():
    """pane_id -> most recent visit timestamp (int), in file order (which is
    already newest-first, see focus-track.sh) - order is what matters here,
    the timestamp is only used for the display label."""
    order = []
    seen = set()
    try:
        with open(LOG_PATH) as f:
            for line in f:
                ts, _, pane_id = line.rstrip("\n").partition("\t")
                if not pane_id or pane_id in seen:
                    continue
                seen.add(pane_id)
                order.append((pane_id, ts))
    except FileNotFoundError:
        pass
    return order


def list_live_panes():
    # pane_pid + pane_current_command: not shown anywhere, only used to find
    # which panes are worth an ssh_info() lookup (see build_snapshot) without
    # spawning ps/lsof/ssh for every pane on every invocation.
    fields = ["pane_id", "session_name", "window_index", "window_name",
              "window_flags", "pane_active", "pane_title", "pane_pid",
              "pane_current_command"]
    fmt = "\t".join(f"#{{{f}}}" for f in fields)
    r = subprocess.run(["tmux", "list-panes", "-a", "-F", fmt],
                        capture_output=True, text=True)
    if r.returncode != 0:
        die(f"tmux list-panes failed (rc={r.returncode}): {r.stderr.strip()}")
    panes = {}
    for line in r.stdout.splitlines():
        pane_id, session, widx, wname, wflags, active, ptitle, pid, cmd = line.split("\t")
        panes[pane_id] = {
            "session": session, "window_index": widx, "window_name": wname,
            "window_flags": wflags, "active": active == "1", "pane_title": ptitle,
            "pid": pid, "current_command": cmd,
        }
    return panes


def current_pane(client):
    r = subprocess.run(
        ["tmux", "display-message", "-p", "-t", client, "#{pane_id}"],
        capture_output=True, text=True,
    )
    return r.stdout.strip() if r.returncode == 0 else None


LOC_WIDTH = 10  # "session:index" - session names here are short (tmux's own
# numeric ids, or short custom ones); see claude-history's row() for what
# happens when a column like this overflows in practice
NAME_WIDTH = 16
TIME_WIDTH = 4  # "99d" etc - a pane not yet hit by any hook (see drive())
# has no log entry at all, shown as "-" rather than left blank so the
# column stays aligned


def humanize_ago(ts):
    """ts is a real Unix timestamp from focus-track.sh's `date +%s`, not a
    synthetic value - None just means this pane was never logged."""
    if ts is None:
        return "-"
    delta = int(time.time()) - int(ts)
    if delta < 60:
        return f"{delta}s"
    if delta < 3600:
        return f"{delta // 60}m"
    if delta < 86400:
        return f"{delta // 3600}h"
    return f"{delta // 86400}d"


# --- extra tracked data: ssh -----------------------------------------------
#
# COLUMN_GROUPS maps a "+$group" name to its ordered sub-columns; more
# providers (git branch/dirty, cwd, ...) can join this later without
# touching the DSL, row(), or header_line() - only a new *_info() lookup and
# an entry here.
COLUMN_GROUPS = {"ssh": ["name", "host", "ip"]}
COLUMN_WIDTHS = {("ssh", "name"): 14, ("ssh", "host"): 20, ("ssh", "ip"): 15}
COLUMN_LABELS = {("ssh", "name"): "SSH.NAME", ("ssh", "host"): "SSH.HOST", ("ssh", "ip"): "SSH.IP"}

# ssh(1)'s own short options that consume a separate argv token as their
# value (from `man ssh`'s usage line) - needed to walk past them without
# mistaking a flag's value (`-p 2222`) for the destination.
SSH_VALUE_OPTS = set("BbcDEeFIiJLlmOopQRSWw")


def find_ssh_child(pane_pid):
    """The ssh process a pane is running, or None. #{pane_current_command}
    (see list_live_panes) already told the caller this pane's foreground
    command resolves to "ssh" - tmux derives that from the whole process
    group, not necessarily pane_pid's direct child, so this re-walks from
    pane_pid to find the actual pid /proc and lsof below need. Descends
    through at most a few single-child hops (covers one wrapper level, e.g.
    a shell function) rather than an unbounded walk."""
    pid = pane_pid
    for _ in range(4):
        r = subprocess.run(["ps", "--ppid", str(pid), "-o", "pid=,comm="],
                            capture_output=True, text=True)
        children = [line.split(None, 1) for line in r.stdout.splitlines() if line.split()]
        if not children:
            return None
        for cpid, comm in children:
            if comm == "ssh":
                return int(cpid)
        if len(children) == 1:
            pid = int(children[0][0])
            continue
        return None
    return None


def ssh_cmdline(pid):
    """argv of a live process, read straight from /proc - not the shell's
    idea of what was typed, so it's already correctly split with no
    quoting/aliasing ambiguity to resolve."""
    try:
        with open(f"/proc/{pid}/cmdline", "rb") as f:
            raw = f.read()
    except OSError:
        return None
    return [p.decode(errors="replace") for p in raw.split(b"\0") if p]


def parse_ssh_destination(argv):
    """The destination argument as ssh's own getopt would find it (alias or
    user@host, whichever was actually typed) - walks argv skipping flags,
    consuming a second token for any flag in SSH_VALUE_OPTS unless its value
    is already attached (`-p2222`, `-oFoo=bar`). Not a full option-parsing
    reimplementation, just enough to not mistake `-p 2222`'s "2222" for the
    destination, which covers every ordinary interactive `ssh ...`
    invocation this is actually run against."""
    i = 1  # argv[0] is the ssh binary itself
    while i < len(argv):
        tok = argv[i]
        if tok == "--":
            i += 1
            break
        if tok.startswith("-") and len(tok) > 1:
            if tok[1] in SSH_VALUE_OPTS and len(tok) == 2:
                i += 2
            else:
                i += 1
            continue
        break
    return argv[i] if i < len(argv) else None


def ssh_resolve_config(argv, timeout=2):
    """`ssh -G <same args>` prints ssh's fully-evaluated config (Host/Match
    blocks, ProxyJump, the works) without connecting anywhere - confirmed
    directly against a live pane: instant, no network I/O. This is what
    turns a config alias into the real target hostname, which grepping
    ~/.ssh/config by hand can't do (Match blocks, Include, multiple
    candidate Host stanzas)."""
    if len(argv) < 2:
        return {}
    try:
        r = subprocess.run(["ssh", "-G", *argv[1:]],
                            capture_output=True, text=True, timeout=timeout)
    except (subprocess.TimeoutExpired, OSError):
        return {}
    if r.returncode != 0:
        return {}
    cfg = {}
    for line in r.stdout.splitlines():
        key, _, val = line.partition(" ")
        if key and key not in cfg:  # first occurrence wins (e.g. repeated identityfile)
            cfg[key] = val
    return cfg


def ssh_remote_ip(pid, timeout=2):
    """The IP ssh is actually connected to, from the live established TCP
    socket (lsof) - unlike ssh -G's resolved hostname, this is proof the
    tunnel is really up, past whatever DNS/ProxyJump indirection got it
    there. Confirmed directly: `lsof -p PID -a -i tcp -n` on a live ssh
    session prints `laddr:lport->raddr:rport (ESTABLISHED)`."""
    try:
        r = subprocess.run(["lsof", "-p", str(pid), "-a", "-i", "tcp", "-n"],
                            capture_output=True, text=True, timeout=timeout)
    except (subprocess.TimeoutExpired, OSError):
        return None
    for line in r.stdout.splitlines()[1:]:  # [0] is lsof's own column header
        m = re.search(r"->([0-9.]+):\S+\s+\(ESTABLISHED\)", line)
        if m:
            return m.group(1)
    return None


def ssh_info(pane_pid):
    """{"name", "host", "ip"} for a pane whose current command is ssh, or
    None. Only called for such panes (see build_snapshot) - ps/ssh -G/lsof
    together are a handful of subprocess calls, cheap for the rare ssh pane
    but wasteful to run against every pane on every invocation."""
    ssh_pid = find_ssh_child(pane_pid)
    if ssh_pid is None:
        return None
    argv = ssh_cmdline(ssh_pid)
    if not argv:
        return None
    name = parse_ssh_destination(argv)
    if not name:
        return None
    cfg = ssh_resolve_config(argv)
    return {
        "name": name,
        "host": cfg.get("hostname") or name,
        "ip": ssh_remote_ip(ssh_pid) or "-",
    }


# --- query DSL --------------------------------------------------------------

FILTER_FIELDS = ["session", "window", "title"]
FIELD_KEY = {"session": "session", "window": "window_name", "title": "pane_title"}

# Sortable types for /sort: the three text fields plus focus time. `time`
# is the raw ts (absolute, so "descending" = newest first, applied
# literally - no age-bucket direction trap here).
SORT_KEYS = {
    "session": lambda p: p["session"].lower(),
    "window": lambda p: p["window_name"].lower(),
    "title": lambda p: p["pane_title"].lower(),
    "time": lambda p: p["ts"],
}

# The verb command DSL - one grammar shared (by hand, not import) with
# winswitch and the GTK pickers; see ~/.config/docs/query-dsl.md.
#   /fv /filter-value  keep matching panes (bare text = this)
#   /at /add-type      add a tracked column (ssh.*) to the display
#   /rt /remove-type   drop one
#   /ft /filter-type   narrow the displayed extra columns to matches
#   /s  /sort          order the (MRU) list by a type [+ direction]
#   /rv /reverse       reverse the current order
# The base TIME/SESSION/NAME/TITLE columns are always shown; only the
# tracked group columns (COLUMN_GROUPS) are toggled by /at//rt//ft.
VERB_SHORTS = ["fv", "ft", "at", "rt", "s", "rv"]
VERB_FORMS = VERB_SHORTS + ["filter-value", "filter-type", "add-type", "remove-type", "sort", "reverse"]
FV_FORMS = {"fv", "filter-value"}
FT_FORMS = {"ft", "filter-type"}
AT_FORMS = {"at", "add-type"}
RT_FORMS = {"rt", "remove-type"}
SORT_FORMS = {"s", "sort"}
REV_FORMS = {"rv", "reverse"}
DIRECTIONS = ["ascending", "descending"]


def tokenize(query):
    """[(start, text, lead_quote)] - whitespace split, "..." kept whole
    (quotes dropped), unterminated quote still closes at end-of-input.
    lead_quote marks a run that began with " (never read as a command)."""
    toks, cur = [], []
    start = None
    lead_quote = in_quotes = False
    for i, c in enumerate(query):
        if c == '"':
            if start is None:
                start, lead_quote = i, True
            in_quotes = not in_quotes
            continue
        if c.isspace() and not in_quotes:
            if start is not None:
                toks.append((start, "".join(cur), lead_quote))
                cur, start, lead_quote = [], None, False
            continue
        if start is None:
            start = i
        cur.append(c)
    if start is not None:
        toks.append((start, "".join(cur), lead_quote))
    return toks


def is_verb_prefix(s):
    return bool(s) and any(v.startswith(s) for v in VERB_FORMS)


def starts_cmd(text, lead_quote):
    """True if a token begins (or is still being typed toward) a command,
    so it can't be swallowed as another verb's argument."""
    if lead_quote or not text.startswith("/"):
        return False
    rest = text[1:]
    return rest in VERB_FORMS or is_verb_prefix(rest)


def resolve_by_substring(prefix, names):
    """Every entry in names containing prefix as a substring - "ho" reaches
    "host", "ti" reaches "title". The one resolution rule everywhere."""
    prefix = prefix.lower()
    return [n for n in names if prefix in n]


def parse_direction(tok):
    """A direction token -> "ascending"/"descending"/None. Any substring
    match counts; ambiguous or empty -> ascending."""
    m = [d for d in DIRECTIONS if tok.lower() in d]
    if not m:
        return None
    return "descending" if m == ["descending"] else "ascending"


def _apply_col(verb, arg, active_cols, seen_cols):
    """/at //rt //ft over the tracked group columns. arg is `group.sub`,
    or a single segment matching a group name (-> all its subs) or a sub
    name (-> that sub in any group)."""
    group_pfx, dot, sub_pfx = arg.partition(".")
    cols = []
    if dot:
        for g in resolve_by_substring(group_pfx, COLUMN_GROUPS):
            cols.extend((g, s) for s in resolve_by_substring(sub_pfx, COLUMN_GROUPS[g]))
    else:
        seg = group_pfx.lower()
        for g, subs in COLUMN_GROUPS.items():
            for s in subs:
                if (seg in g or seg in s) and (g, s) not in cols:
                    cols.append((g, s))
    if verb in AT_FORMS:
        for col in cols:
            if col not in seen_cols:
                seen_cols.add(col)
                active_cols.append(col)
    elif verb in RT_FORMS:
        for col in cols:
            if col in seen_cols:
                seen_cols.discard(col)
                active_cols.remove(col)
    else:  # /ft - keep only matches
        keep = set(cols)
        active_cols[:] = [c for c in active_cols if c in keep]
        seen_cols.intersection_update(keep)


def _add_filter(arg, bare_terms, field_terms):
    """One /fv argument (or a bare word): scoped when it has a colon and
    the field resolves, else a plain bare term."""
    field_pfx, sep, term = arg.partition(":")
    if sep:
        fields = resolve_by_substring(field_pfx, FILTER_FIELDS)
        if fields:
            field_terms.append((fields, term.lower()))
            return
    bare_terms.append(arg.lower())


def parse_query(query):
    """-> (bare_terms, field_terms, active_cols, sort, reverse).

    sort is (SORT_KEYS name, "ascending"/"descending") or None (last /sort
    wins); reverse is a bool (any number of /rv == one). A bare word is an
    implicit /fv term - identical to /fv <word>. A "-led token is literal
    text; a /xyz that is neither a verb nor a verb-prefix (e.g. /usr/bin)
    is literal text too; a /prefix still on its way to a verb is inert."""
    toks = tokenize(query)
    bare_terms, field_terms, active_cols = [], [], []
    seen_cols = set()
    sort = None
    reverse = False
    i, n = 0, len(toks)

    def take_arg():
        nonlocal i
        if i < n and not starts_cmd(toks[i][1], toks[i][2]):
            a = toks[i][1]
            i += 1
            return a
        return None

    while i < n:
        _, text, lead_quote = toks[i]
        i += 1
        if not lead_quote and text.startswith("/"):
            rest = text[1:]
            if rest in FV_FORMS:
                arg = take_arg()
                if arg is not None:
                    _add_filter(arg, bare_terms, field_terms)
                continue
            if rest in AT_FORMS or rest in RT_FORMS or rest in FT_FORMS:
                arg = take_arg()
                if arg is not None:
                    _apply_col(rest, arg, active_cols, seen_cols)
                continue
            if rest in SORT_FORMS:
                path = take_arg()
                if path is not None:
                    fields = resolve_by_substring(path, list(SORT_KEYS))
                    if len(fields) == 1:
                        direction = "ascending"
                        if i < n and not starts_cmd(toks[i][1], toks[i][2]):
                            d = parse_direction(toks[i][1])
                            if d is not None:
                                direction = d
                                i += 1
                        sort = (fields[0], direction)
                continue
            if rest in REV_FORMS:
                reverse = True
                continue
            if is_verb_prefix(rest):
                continue  # mid-typing a verb - inert
            # a literal /usr/bin etc
            bare_terms.append(text.lower())
            continue
        # bare word or "-quoted literal
        bare_terms.append(text.lower())
    return bare_terms, field_terms, active_cols, sort, reverse


def suggest_completion(query):
    """If the query's trailing token is a partial verb or a partial
    argument to /fv//at//rt//ft, -> (completed_query, hint); (None, None)
    otherwise. Trailing token only - editing happens at the end."""
    if not query or query[-1].isspace():
        return None, None
    toks = tokenize(query)
    if not toks:
        return None, None
    start, text, lead_quote = toks[-1]
    if lead_quote:
        return None, None
    prefix = query[:start]

    # partial verb: "/f" -> "/fv "
    if text.startswith("/"):
        rest = text[1:]
        cands = [v for v in VERB_SHORTS if rest in v]
        if not cands or (len(cands) == 1 and cands[0] == rest):
            return None, None
        completed = f"/{cands[0]} "
        return prefix + completed, completed

    # argument to the governing verb (the last /verb before this token)
    gv = None
    for _, t, lq in reversed(toks[:-1]):
        if not lq and t.startswith("/") and t[1:] in VERB_FORMS:
            gv = t[1:]
            break
        if not lq and t.startswith("/") and is_verb_prefix(t[1:]):
            return None, None
    if gv in AT_FORMS or gv in RT_FORMS or gv in FT_FORMS:
        group_pfx, dot, sub_pfx = text.partition(".")
        groups = resolve_by_substring(group_pfx, COLUMN_GROUPS) if group_pfx else []
        if not groups:
            return None, None
        g = groups[0]
        if dot:
            subs = resolve_by_substring(sub_pfx, COLUMN_GROUPS[g]) if sub_pfx else COLUMN_GROUPS[g]
            if not subs:
                return None, None
            completed = f"{g}.{subs[0]}"
        else:
            completed = g
        if completed == text:
            return None, None
        return prefix + completed, completed
    if gv in FV_FORMS and ":" not in text and text:
        fields = resolve_by_substring(text, FILTER_FIELDS)
        if not fields:
            return None, None
        completed = f"{fields[0]}:"
        if completed == text:
            return None, None
        return prefix + completed, completed
    return None, None


def row(p, active_cols):
    loc = f'{p["session"]}:{p["window_index"]}'
    name = p["window_name"] + p["window_flags"]
    when = humanize_ago(p["ts"])
    parts = [f'{when:>{TIME_WIDTH}}', f'{loc:<{LOC_WIDTH}}', f'{name:<{NAME_WIDTH}}']
    for col in active_cols:
        val = "-"
        info = p.get(col[0])  # e.g. p["ssh"], or None if not that kind of pane
        if info:
            val = info.get(col[1], "-")
        parts.append(f'{val:<{COLUMN_WIDTHS[col]}}')
    parts.append(f'"{p["pane_title"]}"')
    return f'{p["pane_id"]}\t' + "  ".join(parts)


def header_line(active_cols, hint=None):
    parts = [f'{"TIME":>{TIME_WIDTH}}', f'{"SESSION:WIN":<{LOC_WIDTH}}', f'{"NAME":<{NAME_WIDTH}}']
    for col in active_cols:
        parts.append(f'{COLUMN_LABELS[col]:<{COLUMN_WIDTHS[col]}}')
    parts.append("TITLE")
    line = "  ".join(parts)
    if hint:
        # the closest approximation of inline "ghost text" autocompletion
        # fzf's own query box supports: it has no primitive for suggestion
        # text at the cursor, but the header is redrawn live off the same
        # query anyway (see drive()'s transform-header bind), so showing
        # what tab would produce here is visible in the same glance as
        # typing, and tab actually applying it (suggest_completion, wired
        # to tab:transform-query in drive()) makes it more than a label.
        line += f"   [tab → {hint}]"
    return line


def header(query):
    _, _, active_cols, _, _ = parse_query(query)
    _, hint = suggest_completion(query)
    sys.stdout.write(header_line(active_cols, hint))


def complete(query):
    completed, _ = suggest_completion(query)
    sys.stdout.write(completed if completed is not None else query)


def preview(pane_id):
    # -e (unlike window-search.py's preview): nothing here inserts its own
    # highlight ANSI codes on top, so the pane's real colors can just be
    # kept instead of stripped - there's no query to match/highlight, this
    # is a plain "what was I doing here" glance, not a search result
    r = subprocess.run(
        ["tmux", "capture-pane", "-p", "-e", "-J", "-t", pane_id,
         "-S", f"-{PREVIEW_LINES}"],
        capture_output=True, text=True, errors="replace",
    )
    if r.returncode != 0:
        sys.stdout.write(f"[capture-pane {pane_id} failed: {r.stderr.strip()}]\n")
        return
    sys.stdout.write(r.stdout)


def current_client_tty():
    """The tty of the client viewing THIS pane, resolved from directly
    inside the pane's own process tree. .tmux.conf runs this script via
    `new-window`, a real pane - not a popup, which has no controlling pane
    of its own to resolve #{client_tty} *from* (see window-search.py's
    current_client_tty() and its .tmux.conf entry for the full saga this
    sidesteps). A real pane needs none of it: tmux resolves "#{client_tty}"
    the same as if you'd typed the command at the prompt yourself."""
    r = subprocess.run(["tmux", "display-message", "-p", "#{client_tty}"],
                       capture_output=True, text=True)
    return r.stdout.strip() if r.returncode == 0 else None


def jump(client, pane_id):
    """Land the client that opened this window on the chosen pane. Mirrors
    window-search.py's jump() exactly (see its comments for why each step is
    there - the three-command fallback chain, and verifying against
    list-clients rather than display-message -c) - that function was
    hard-won against a real switch-client bug, so this reuses the same
    verified sequence rather than a fresh guess."""
    if not client:
        die("current_client_tty() couldn't resolve #{client_tty} for this "
            "pane - can't switch-client without it (see .tmux.conf, prefix+w)")

    cr = subprocess.run(["tmux", "list-clients", "-F", "#{client_tty}\t#{session_name}"],
                        capture_output=True, text=True)
    if cr.returncode != 0:
        die(f"tmux list-clients failed (rc={cr.returncode}): {cr.stderr.strip()}")
    clients = {c: s for c, s in (line.split("\t") for line in cr.stdout.splitlines())}
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
    actual = after.get(client)
    if actual != pane_id:
        die(f"selected {pane_id} but client {client} ended up on {actual!r} instead - "
            f"switch-client silently landed on the wrong pane")


SNAP_PREFIX = "tmux-focus-picker-"


def snapshot_dir():
    """Where to put the snapshot - pane metadata plus, for ssh panes,
    hostnames/IPs. Same XDG_RUNTIME_DIR-preferred, 0600-file choice
    window-search.py uses for its (far more sensitive - full scrollback)
    snapshot; see its snapshot_dir() for the full reasoning. Lower stakes
    here, but no reason to pick a laxer default."""
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
    """Delete snapshots left behind by invocations no longer alive (crash,
    SIGKILL, or a window closed out from under a still-running invocation) -
    same liveness-by-pid approach as window-search.py's sweep, see its
    docstring for why mtime alone isn't good enough."""
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
                continue  # owner still running
            except OSError:
                pass
            _rm(os.path.join(d, name))


def build_snapshot():
    client = current_client_tty()
    live = list_live_panes()
    if not live:
        die("tmux list-panes returned no panes - nothing to switch to")

    me = current_pane(client) if client else None

    focus_order = read_focus_order()
    ts_map = dict(focus_order)
    ordered_ids = [pid for pid, _ in focus_order if pid in live and pid != me]
    # panes that exist but were never logged (created since the last focus
    # event, or from before focus-track.sh existed) still have to be
    # reachable - tacked on at the end, in list-panes' own order, rather than
    # silently hidden from the picker
    for pid in live:
        if pid != me and pid not in ordered_ids:
            ordered_ids.append(pid)

    if not ordered_ids:
        die("no other panes to switch to")

    panes = []
    for pid in ordered_ids:
        p = live[pid]
        entry = {
            "pane_id": pid, "session": p["session"], "window_index": p["window_index"],
            "window_name": p["window_name"], "window_flags": p["window_flags"],
            "pane_title": p["pane_title"], "ts": ts_map.get(pid),
        }
        entry["ssh"] = ssh_info(p["pid"]) if p["current_command"] == "ssh" else None
        panes.append(entry)
    return client, panes


def search(snapshot_path, query):
    """Filter+format the pre-built snapshot for one query - re-run on every
    keystroke via fzf's reload, but ssh_info() itself already ran once at
    snapshot-build time (build_snapshot/drive), so this does no subprocess
    calls of its own and stays fast regardless of typing speed.

    The header (which columns active_cols produces are visible) is kept in
    sync separately, via drive()'s own transform-header bind calling
    header() - not baked in here. --header-lines was tried first and
    dropped: it only slices a header out of fzf's very first synchronous
    input, never out of a later reload, so with --disabled (candidates start
    empty until the first reload) there was nothing to slice - confirmed
    directly, the header area just stayed permanently blank."""
    with open(snapshot_path) as f:
        panes = json.load(f)
    bare_terms, field_terms, active_cols, sort, reverse = parse_query(query)

    matched = []
    for p in panes:
        haystack_parts = [p["session"], p["window_name"], p["pane_title"]]
        if p["ssh"]:
            haystack_parts.extend(p["ssh"].values())
        haystack = " ".join(haystack_parts).lower()
        if bare_terms and not all(t in haystack for t in bare_terms):
            continue
        if not all(any(term in p[FIELD_KEY[f]].lower() for f in fields)
                   for fields, term in field_terms):
            continue
        matched.append(p)

    # Default order is MRU (snapshot file order); /sort and /reverse are
    # opt-in on top of it.
    if sort is not None:
        key_name, direction = sort
        matched.sort(key=SORT_KEYS[key_name], reverse=(direction == "descending"))
    if reverse:
        matched.reverse()

    sys.stdout.write("\n".join(row(p, active_cols) for p in matched))


def drive():
    client, panes = build_snapshot()

    sweep_stale_snapshots()
    fd, snap_path = tempfile.mkstemp(prefix=f"{SNAP_PREFIX}{os.getpid()}-",
                                     suffix=".json", dir=snapshot_dir())
    # the `finally` below only covers a normal fzf exit. The window this
    # runs in being closed out from under it (kill-window, `prefix+x`) sends
    # SIGHUP mid-fzf and would otherwise strand the snapshot in /tmp.
    # Turning the signal into SystemExit lets both atexit and finally run.
    atexit.register(lambda: _rm(snap_path))
    for sig in (signal.SIGHUP, signal.SIGTERM, signal.SIGINT):
        signal.signal(sig, lambda *_: sys.exit(1))
    with os.fdopen(fd, "w") as f:
        json.dump(panes, f)

    py = f"{shlex.quote(sys.executable)} {shlex.quote(os.path.abspath(__file__))}"
    # --query={q}, not --query {q}: fzf shell-quotes {q} correctly, but argparse
    # is a second parsing layer that refuses an option value which itself looks
    # like an option - joined with "=" it stays one token and parses fine even
    # when the query looks like a flag (see window-search.py's self_cmd).
    self_cmd = f"{py} --search {shlex.quote(snap_path)} --query={{q}}"
    header_cmd = f"{py} --header --query={{q}}"
    complete_cmd = f"{py} --complete --query={{q}}"
    preview_cmd = f"{py} --preview {{1}}"
    # same list/preview split as window-search.py and claude-history: react
    # to each match-set change (a reload here, not fzf's own filtering - the
    # list is fully regenerated by search() above on every keystroke) and
    # give the list just enough rows for $FZF_MATCH_COUNT, preview gets the
    # rest - EXCEPT the list is also capped at half of FZF_LINES, so the
    # preview never drops below half regardless of match count, and grows
    # past half on its own the fewer results there are to list. +4 is the
    # header line, the prompt line, and the match-count info line, plus one
    # more - $FZF_LINES doesn't shrink for a header, confirmed directly, so
    # it has to be budgeted for here.
    resize_on_result = (
        'c=$FZF_MATCH_COUNT; list_rows=$((c + 4)); '
        '[ "$list_rows" -lt 4 ] && list_rows=4; '
        'half=$((FZF_LINES / 2)); '
        '[ "$list_rows" -gt "$half" ] && list_rows=$half; '
        'echo "change-preview-window(down,$((FZF_LINES - list_rows)))"'
    )

    try:
        result = subprocess.run(
            [
                "fzf", "--ansi", "--disabled", "--layout=reverse",
                "--delimiter", "\t", "--with-nth", "2..",
                "--header", header_line([]),  # transform-header below takes
                # over from the first start/change event; this static value
                # only covers the brief instant before that first event's
                # async command has actually returned.
                "--prompt", "focus history> ",
                "--preview", preview_cmd,
                "--preview-window", "down,50%,border-top,wrap",
                # reload+transform-header chained with "+" into ONE bind per
                # event, not two separate --bind flags for the same event
                # (tried first, and broken: confirmed directly - fzf does
                # NOT combine multiple --bind entries for the same event,
                # the second one silently replaces the first, so reload
                # never ran at all and fzf fell back to its own default
                # filesystem-walk candidate source instead. The paren form
                # is safe with the {q} placeholder inside it despite also
                # using parens for chaining: fzf substitutes {q} - already
                # shell-quoted - only when the command actually runs, after
                # the action list itself has been parsed from the static
                # template text, so a paren typed into the live query can't
                # break the chain).
                "--bind", f"start:reload({self_cmd})+transform-header({header_cmd})",
                "--bind", f"change:reload({self_cmd})+transform-header({header_cmd})",
                # tab completes the query's trailing "+$group[.sub]"/"$field"
                # token to what it's about to resolve to (see
                # suggest_completion) - the header already shows that same
                # target as a live hint (header()), so this is "tab accepts
                # the hint you can already see", not a blind guess. Not bound
                # to anything by default in single-select mode (no --multi
                # here), so this doesn't shadow existing behaviour.
                "--bind", f"tab:transform-query:{complete_cmd}",
                "--bind", f"result:transform:{resize_on_result}",
                # `result` alone only re-runs this on a filtering change - a
                # terminal resize while sitting on an unchanged query never
                # fired it, so the list/preview split stayed exactly as
                # computed at whatever size the window happened to be when
                # you last typed. `resize` (fzf 0.44+) is the event fzf
                # itself provides for this, triggered on terminal size
                # change specifically - same transform, just a second
                # trigger for it.
                "--bind", f"resize:transform:{resize_on_result}",
            ],
            capture_output=True, text=True,
        )
    finally:
        _rm(snap_path)
    selected = result.stdout.strip()
    if not selected:
        return
    pane_id = selected.split("\t", 1)[0]
    jump(client, pane_id)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--search", metavar="SNAPSHOT")
    parser.add_argument("--preview", metavar="PANE_ID")
    parser.add_argument("--header", action="store_true")
    parser.add_argument("--complete", action="store_true")
    parser.add_argument("--query", default="")
    args = parser.parse_args()
    if args.preview:
        preview(args.preview)
    elif args.search:
        search(args.search, args.query)
    elif args.header:
        header(args.query)
    elif args.complete:
        complete(args.query)
    else:
        drive()


if __name__ == "__main__":
    main()

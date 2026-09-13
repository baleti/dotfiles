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
  /fv tmux.session:word  scope: word must appear in one field
  /filter-value ...      (tmux.session / tmux.window / tmux.title). The
                       field name is substring-resolved (/fv se:foo
                       reaches tmux.session; a bare "tmux" reaches all
                       three - see FILTER_FIELDS). /fv/tmux.session word
                       (a second "/" gluing the field onto the verb
                       instead of a colon - query-dsl.md's "Via paths")
                       means exactly the same thing; Tab steers toward
                       this spelling (see completion_stage), the colon
                       form still works typed by hand. /fv/tmux word
                       (a bare group, no subfield) searches all three
                       together, same union rule as any ambiguous path
                       segment elsewhere in this grammar.
  /at ssh.host         add a tracked column to the display; /at ssh adds
  /add-type ...        every ssh.* column. Group/sub substring-resolved.
                       /at/ssh.host is the same via spelling as above.
  /rt ssh              remove matching columns (mirror of /at).
  /ft host             narrow the displayed extra columns to matches.
  /s tmux.title [desc]  order the list by tmux.session / tmux.window /
  /sort ...             tmux.title / time, optional ascending/descending
                       (substring-matched). /s/tmux.title is the via
                       spelling; single-key only - this picker's /sort
                       never grew the doc's multi-key via chaining
                       (/sort/a/b/c).
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
# Search-box history (query-dsl.md's "Search-box history" section): one
# line per submitted query, oldest first (fzf's own --history format).
# ctrl-p/ctrl-n, not Up/Down, are this picker's "Up-arrow" - Up/Down are
# already list-navigation (fzf's default "up"/"down" actions, bound to the
# arrow keys AND ctrl-k/ctrl-j - see drive()). --history only remaps
# ctrl-p/ctrl-n (from the rarely-used up-match/down-match) to
# prev-history/next-history, so nothing existing gets displaced. Confirmed
# directly (a scripted `expect` session against real fzf, 2026-09-13):
# --history writes the file only on an actual accept (never on Escape/
# ctrl-c), and next-history restores the original in-progress buffer
# verbatim once you walk forward past the newest entry - exactly the
# doc's "pre-cycle draft" behavior, for free.
HISTORY_PATH = os.path.expanduser("~/.cache/tmux-focus-picker-history")
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

# Grouped under "tmux." to match winswitch's own tmux.session/tmux.window/
# tmux.title naming (query-dsl.md's "Group and flat-type names are each
# picker's own vocabulary" note explicitly says this isn't required - every
# row here already *is* a tmux pane, so the prefix is redundant, not
# disambiguating anything the way it does for winswitch's Hyprland windows -
# but consistency with the reference implementation was asked for anyway
# 2026-09-13, so the plain "session"/"window"/"title" names from before are
# gone, not kept as an alias). Still a plain flat list, not real nested
# group machinery (no /at/rt/ft column-toggling, no bare-group existence
# filter beyond what substring resolution already gives for free - see
# below) - just the dotted spelling. resolve_by_substring's ordinary
# substring rule means an old bare "session:" query, or a bare via path of
# just "tmux" with nothing more specific, still resolves: "session" is a
# substring of "tmux.session" same as "tmux" is, and an ambiguous prefix
# matching all three unions across them the same way any other ambiguous
# path segment does elsewhere in this grammar (Type paths, above) - which
# is also what makes a bare "/fv/tmux query" search session+window+title
# together, the same union a real bare-group filter gives in winswitch,
# without this picker needing separate existence-filter code for it.
FILTER_FIELDS = ["tmux.session", "tmux.window", "tmux.title"]
FIELD_KEY = {"tmux.session": "session", "tmux.window": "window_name", "tmux.title": "pane_title"}

# Sortable types for /sort: the three tmux.* text fields plus focus time.
# `time` is the raw ts (absolute, so "descending" = newest first, applied
# literally - no age-bucket direction trap here) and stays flat - it has
# no winswitch counterpart to mirror the naming of.
SORT_KEYS = {
    "tmux.session": lambda p: p["session"].lower(),
    "tmux.window": lambda p: p["window_name"].lower(),
    "tmux.title": lambda p: p["pane_title"].lower(),
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
    """A prefix of some verb form - no separate empty-string guard: every
    verb form trivially starts with "" already, so a bare "/" (s == "")
    is correctly a prefix of all of them too - excluding it would make
    the very first keystroke of any command fall through as a literal
    bare-word search instead of staying inert (reported 2026-09-13
    against the sibling winswitch implementation - typing "/" alone was
    clearing the whole pane list)."""
    return any(v.startswith(s) for v in VERB_FORMS)


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

            # via-path form: /verb/path ... - a second "/" glues the path
            # onto the verb instead of it arriving as a separate space
            # token (query-dsl.md "Via paths"; every path-taking verb
            # accepts this the same way). /s's via form is single-key
            # only here, same as its space form - this picker's sort
            # never supported the doc's multi-key chaining
            # (`/sort/a/b/c`), so an embedded further "/" in the path just
            # fails to resolve to any one SORT_KEYS name and the whole
            # command stays inert, same as any other unresolvable path.
            verb_part, via_slash, via_path = rest.partition("/")
            if via_slash:
                if verb_part in FV_FORMS:
                    arg = take_arg()
                    if arg is not None:
                        _add_filter(f"{via_path}:{arg}", bare_terms, field_terms)
                    continue
                if verb_part in AT_FORMS or verb_part in RT_FORMS or verb_part in FT_FORMS:
                    _apply_col(verb_part, via_path, active_cols, seen_cols)
                    continue
                if verb_part in SORT_FORMS:
                    fields = resolve_by_substring(via_path, list(SORT_KEYS))
                    if len(fields) == 1:
                        direction = "ascending"
                        if i < n and not starts_cmd(toks[i][1], toks[i][2]):
                            d = parse_direction(toks[i][1])
                            if d is not None:
                                direction = d
                                i += 1
                        sort = (fields[0], direction)
                    continue
                if verb_part in REV_FORMS or is_verb_prefix(verb_part):
                    continue  # /rv takes no path; a still-forming verb/path is inert
                # not a real verb - falls through to the plain checks below,
                # which will also miss and land it as literal text (e.g.
                # /usr/bin)

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


def _column_paths():
    """Every /at//rt//ft path: each column group's name plus each of its
    dotted subfields - "ssh", "ssh.name", "ssh.host", "ssh.ip"."""
    out = []
    for g, subs in COLUMN_GROUPS.items():
        out.append(g)
        out.extend(f"{g}.{s}" for s in subs)
    return out


def verb_stage_universe():
    """Every Verb-stage candidate (query-dsl.md's "Verb-stage depth"): the
    six bare short verbs, plus every path-taking verb (all but /rv)
    crossed with every path it can actually take - "fv/tmux.session",
    "at/ssh.host", ... so a fragment of the *path*, not just the verb, is
    enough to reach a whole command in one Tab. Two disjoint path
    registries feed this (unlike winswitch's one shared type registry,
    the reference implementation this mirrors): /fv and /s draw from this
    picker's flat filter/sort fields, /at//rt//ft from its column
    groups."""
    paths = {
        "fv": FILTER_FIELDS,
        "s": list(SORT_KEYS),
        "at": _column_paths(), "rt": _column_paths(), "ft": _column_paths(),
    }
    out = list(VERB_SHORTS)
    for v in VERB_SHORTS:
        if v == "rv":
            continue
        out.extend(f"{v}/{p}" for p in paths[v])
    return out


def completion_stage(query):
    """The candidates for the query's trailing token - a partial verb (or
    verb/path), or a partial argument to /fv//at//rt//ft/s - as (prefix,
    suffix, candidates). The finished query for a chosen candidate is
    prefix + candidate + suffix; empty candidates means nothing to
    complete here. Each candidate is the *full* replacement for the
    trailing token (leading "/" included for a verb, dotted path for a
    column group, trailing ":" for an /fv field), so the caller never
    needs to know which stage produced it. Trailing token only - editing
    happens at the end. complete()'s own only caller."""
    if not query or query[-1].isspace():
        return "", "", []
    toks = tokenize(query)
    if not toks:
        return "", "", []
    start, text, lead_quote = toks[-1]
    if lead_quote:
        return "", "", []
    prefix = query[:start]

    if text.startswith("/"):
        rest = text[1:]
        verb_part, via_slash, via_frag = rest.partition("/")
        if via_slash:
            # already committed to one verb via a glued "/path" - narrow
            # within THAT verb's own path universe only (query-dsl.md's
            # Type-path stage, via spelling), not the full verb x path
            # crossing below (that's for choosing the verb in the first
            # place). Mirrors winswitch's completionContext: a second "/"
            # in the fragment is a "typePath, via: true" completion, not
            # a "verb" one.
            base = f"{prefix}/{verb_part}/"
            if verb_part in FV_FORMS:
                cands = [f for f in resolve_by_substring(via_frag, FILTER_FIELDS) if f != via_frag]
                return (base, " ", cands) if cands else ("", "", [])
            if verb_part in SORT_FORMS:
                cands = [f for f in resolve_by_substring(via_frag, list(SORT_KEYS)) if f != via_frag]
                return (base, " ", cands) if cands else ("", "", [])
            if verb_part in AT_FORMS or verb_part in RT_FORMS or verb_part in FT_FORMS:
                group_pfx, dot, sub_pfx = via_frag.partition(".")
                groups = resolve_by_substring(group_pfx, COLUMN_GROUPS)
                if dot:
                    cands = []
                    for g in groups:
                        subs = resolve_by_substring(sub_pfx, COLUMN_GROUPS[g])
                        cands.extend(f"{g}.{s}" for s in subs)
                    suffix = " "  # a resolved subfield - ready for the next command
                else:
                    cands = list(groups)
                    suffix = ""  # a bare group - ready for ".sub"
                cands = [c for c in cands if c != via_frag]
                return (base, suffix, cands) if cands else ("", "", [])
            return "", "", []  # /rv takes no path; an unrecognized verb_part isn't a command
        # no second "/" yet - still choosing the verb, or a whole deep
        # verb/path combo in one step ("Verb-stage depth"): cross every
        # path-taking verb with every path it can take, rendered as the
        # complete "verb/path" string - same universe verb_stage_universe()
        # builds, matched the same substring-anywhere way as everything
        # else in this grammar.
        rest_l = rest.lower()
        cands = [f"/{v}" for v in verb_stage_universe() if rest_l in v]
        if not cands or (len(cands) == 1 and cands[0] == text):
            return "", "", []
        return prefix, " ", cands

    # argument to the governing verb (the last /verb before this token)
    gv = None
    for _, t, lq in reversed(toks[:-1]):
        if not lq and t.startswith("/") and t[1:] in VERB_FORMS:
            gv = t[1:]
            break
        if not lq and t.startswith("/") and is_verb_prefix(t[1:]):
            return "", "", []
    if gv in AT_FORMS or gv in RT_FORMS or gv in FT_FORMS:
        group_pfx, dot, sub_pfx = text.partition(".")
        groups = resolve_by_substring(group_pfx, COLUMN_GROUPS) if group_pfx else []
        if not groups:
            return "", "", []
        if dot:
            cands = []
            for g in groups:
                subs = resolve_by_substring(sub_pfx, COLUMN_GROUPS[g]) if sub_pfx else COLUMN_GROUPS[g]
                cands.extend(f"{g}.{s}" for s in subs)
            suffix = " "  # a resolved subfield - ready for the next command
        else:
            cands = list(groups)
            suffix = ""  # a bare group - ready for ".sub"
        cands = [c for c in cands if c != text]
        if not cands:
            return "", "", []
        return prefix, suffix, cands
    if gv in FV_FORMS and ":" not in text and text:
        fields = resolve_by_substring(text, FILTER_FIELDS)
        cands = [c for c in (f"{f}:" for f in fields) if c != text]
        if not cands:
            return "", "", []
        return prefix, "", cands
    return "", "", []


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


def header_line(active_cols):
    parts = [f'{"TIME":>{TIME_WIDTH}}', f'{"SESSION:WIN":<{LOC_WIDTH}}', f'{"NAME":<{NAME_WIDTH}}']
    for col in active_cols:
        parts.append(f'{COLUMN_LABELS[col]:<{COLUMN_WIDTHS[col]}}')
    parts.append("TITLE")
    return "  ".join(parts)


def header(query):
    _, _, active_cols, _, _ = parse_query(query)
    sys.stdout.write(header_line(active_cols))


def complete(query):
    """A unique candidate completes directly, same as before; 2+ opens a
    small nested fzf popup to choose among them - run via drive()'s
    tab:execute(...) bind, which is what gives this the real terminal a
    nested interactive fzf needs (unlike transform-query, which never had
    one to hand over - see drive()'s comment on the bind). Mirrors
    claude-history's complete_query/CLIENT_SRC popup, same "narrow match
    completes silently, ambiguous one shows a list" rule."""
    prefix, suffix, cands = completion_stage(query)
    if not cands:
        sys.stdout.write(query)
        return
    if len(cands) == 1:
        sys.stdout.write(prefix + cands[0] + suffix)
        return
    p = subprocess.run(
        ["fzf", "--height=100%", "--layout=reverse", "--border=rounded",
         "--prompt=complete> "],
        input="\n".join(cands), capture_output=True, text=True,
    )
    chosen = p.stdout.strip()
    sys.stdout.write(prefix + chosen + suffix if chosen else query)


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


def dedupe_history():
    """Collapse HISTORY_PATH to query-dsl.md's HIST_IGNORE_ALL_DUPS +
    HIST_REDUCE_BLANKS rule: normalize whitespace runs to one space, drop
    blank lines, and keep only the LAST occurrence of an identical line
    (re-appended at the end) - fzf's own --history just appends on every
    accept with no dedup at all (confirmed directly), so a query typed
    three times would otherwise pile up three near-identical rows in the
    Ctrl+R popup instead of floating the repeat back to "most recent".
    Run after fzf exits, so the *next* invocation's --history load (and
    this invocation's own Ctrl+R popup, which rereads the file fresh -
    see history_search()) already sees a clean file. Atomic write, same
    tempfile+replace pattern the rest of this codebase uses for a file
    another process might be reading concurrently."""
    try:
        with open(HISTORY_PATH) as f:
            lines = f.read().splitlines()
    except FileNotFoundError:
        return
    seen = {}
    order = []
    for line in lines:
        norm = " ".join(line.split())
        if not norm:
            continue
        if norm not in seen:
            order.append(norm)
        seen[norm] = True
    # last-occurrence-wins order: drop earlier dups, keep each surviving
    # line at its LAST position, not its first
    last_pos = {}
    for idx, line in enumerate(lines):
        norm = " ".join(line.split())
        if norm:
            last_pos[norm] = idx
    order.sort(key=lambda norm: last_pos[norm])
    d = os.path.dirname(HISTORY_PATH)
    fd, tmp = tempfile.mkstemp(dir=d, prefix=".focus-picker-history-")
    try:
        with os.fdopen(fd, "w") as f:
            f.write("\n".join(order) + ("\n" if order else ""))
        os.chmod(tmp, 0o600)
        os.replace(tmp, HISTORY_PATH)
    except OSError:
        _rm(tmp)


def history_search(query):
    """Ctrl+R (query-dsl.md's "Search-box history"): a nested fzf over
    HISTORY_PATH, most-recent-first, seeded with the current query
    (mirrors zsh's `fzf --query "$LBUFFER"` ctrl-r widget) and left at
    fzf's own default fuzzy matcher - deliberately NOT this DSL's
    substring rule (see the doc section) - which this nested fzf already
    gets for free by not passing --disabled, same as complete()'s own
    nested popup. Reads the file fresh every call rather than trusting an
    in-memory snapshot (this process is one-shot per invocation anyway,
    so there's nothing stale to have cached - see the doc's
    INC_APPEND_HISTORY/SHARE_HISTORY note, which matters more for the
    long-lived QML/GTK pickers than here)."""
    try:
        with open(HISTORY_PATH) as f:
            entries = [l for l in f.read().splitlines() if l.strip()]
    except FileNotFoundError:
        entries = []
    entries.reverse()  # file is oldest-first; popup shows newest-first
    # Always opens, even with zero entries - same reasoning as zsh's own
    # ctrl-r widget, which shows its (empty) popup rather than doing
    # nothing the first time it's pressed with no history yet. An earlier
    # version returned early here instead, which looked indistinguishable
    # from Ctrl+R being unbound entirely (reported 2026-09-13).
    p = subprocess.run(
        ["fzf", "--height=100%", "--layout=reverse", "--border=rounded",
         "--prompt=history> ", f"--query={query}"],
        input="\n".join(entries), capture_output=True, text=True,
    )
    chosen = p.stdout.strip()
    sys.stdout.write(chosen if chosen else query)


def record_history(query):
    """Append the current query to HISTORY_PATH the moment the user acts
    on it in the grid - either a real accept (already handled for free by
    fzf's own --history flag, see HISTORY_PATH's comment) or just moving
    the row selection after typing (drive()'s up/down/ctrl-j/ctrl-k
    binds, added 2026-09-13 - "the moment user finishes typing and makes
    an action in the data grid... or only start moving selection around",
    not gated behind a full accept). Deliberately NOT bound to every
    keystroke - only to selection-movement, which only fires once typing
    has paused for an actual navigation - so a query still being composed
    never gets a half-typed fragment recorded (query-dsl.md's own "never
    flash..." spirit, applied to history instead of results). Blind
    append, no read-modify-write and no dedup here: repeatedly moving the
    selection on an unchanged query appends the same line several times
    in one sitting, cheap and harmless - dedupe_history() collapses it
    once, right after this invocation's fzf exits (see drive())."""
    q = " ".join(query.split())
    if not q:
        return
    try:
        with open(HISTORY_PATH, "a") as f:
            f.write(q + "\n")
        os.chmod(HISTORY_PATH, 0o600)
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
    # complete()'s output lands here rather than on stdout: tab's bind
    # below runs it via execute(...), not transform-query directly, since
    # transform-query captures a command's stdout without ever handing it
    # the real terminal - fine for the old single-candidate case, but no
    # good for the ambiguous case's nested interactive fzf popup, which
    # needs real terminal control the way execute(...) alone provides
    # (same as fzf's own `execute(less {})` example, and the same
    # execute+transform-query split claude-history's complete_query/
    # CLIENT_SRC popup uses). transform-query then just loads whatever
    # complete() decided into this file back into the query.
    complete_fd, complete_path = tempfile.mkstemp(
        prefix=f"{SNAP_PREFIX}{os.getpid()}-complete-", suffix=".txt", dir=snapshot_dir())
    os.close(complete_fd)
    atexit.register(lambda: _rm(complete_path))
    # same execute()+transform-query() split as tab: below, just aimed at
    # history_search() instead of complete() - see HISTORY_PATH's own
    # comment for why ctrl-r rather than a bare Ctrl+Space-style bind.
    history_fd, history_path = tempfile.mkstemp(
        prefix=f"{SNAP_PREFIX}{os.getpid()}-history-", suffix=".txt", dir=snapshot_dir())
    os.close(history_fd)
    atexit.register(lambda: _rm(history_path))
    os.makedirs(os.path.dirname(HISTORY_PATH), exist_ok=True)
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
    complete_cmd = f"{py} --complete --query={{q}} > {shlex.quote(complete_path)}"
    history_cmd = f"{py} --history-search --query={{q}} > {shlex.quote(history_path)}"
    record_cmd = f"{py} --record-history --query={{q}}"
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
                # query-dsl.md's "Search-box history": Up/Down cycle
                # submitted queries most-recent-first (fzf's own
                # --history feature below, explicitly rebound here from
                # its up/down list-navigation default - row navigation
                # moves to ctrl-j/ctrl-k instead, already fzf's default
                # synonyms for down/up so nothing new to bind for them);
                # ctrl-r opens the fuzzy history popup (history_search()).
                "--history", HISTORY_PATH,
                "--bind", "up:prev-history",
                "--bind", "down:next-history",
                "--bind", f"ctrl-j:down+execute-silent({record_cmd})",
                "--bind", f"ctrl-k:up+execute-silent({record_cmd})",
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
                # completion_stage): a unique candidate completes directly,
                # 2+ candidates open complete()'s own nested fzf popup to
                # choose among them (see complete_path above). Not bound to
                # anything by default in single-select mode (no --multi
                # here), so this doesn't shadow existing behaviour.
                "--bind", f"tab:execute({complete_cmd})+transform-query(cat {shlex.quote(complete_path)})",
                "--bind", f"ctrl-r:execute({history_cmd})+transform-query(cat {shlex.quote(history_path)})",
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
        _rm(complete_path)
        _rm(history_path)
        dedupe_history()
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
    parser.add_argument("--history-search", action="store_true")
    parser.add_argument("--record-history", action="store_true")
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
    elif args.history_search:
        history_search(args.query)
    elif args.record_history:
        record_history(args.query)
    else:
        drive()


if __name__ == "__main__":
    main()

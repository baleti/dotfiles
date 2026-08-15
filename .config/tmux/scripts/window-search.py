#!/usr/bin/env python3
"""Full-text window switcher for tmux (prefix+w), replacing choose-tree.

tmux's built-in `choose-tree -Zw` only lets `/` search match window/pane
*titles*. This searches pane *scrollback content* across every session, with
results ranked instead of just filtered - recoll/Xapian/Lucene's default is
Okapi BM25, so that's the base score here too. Two deliberate, low-risk
deviations from textbook BM25, both already-established patterns elsewhere
in this dotfiles repo rather than one-off tuning:

  - term frequency is recency-weighted: a hit in the last few lines of a
    pane counts for more than the same word buried in old scrollback. This
    is the same "recent wins" principle as _dir_history_chpwd's cd history
    and fzf-execute-widget's MRU-first widget list in .zshrc - just wired
    into a real relevance score instead of being the whole score.
  - the window title is folded into the document as a boosted pseudo-field
    (repeated tokens), the standard "boost the title field" trick every
    real search engine does, so a literal title match still wins like the
    old `/` search did.

No stopword list, no stemming, no per-user tuning knobs beyond capture
depth - keeping the scoring textbook-standard is what keeps it from
overfitting to this one person's shell history.

Two modes:
  driver (no args):        snapshot every pane once, drive fzf, jump on select
  --search FILE --query Q: score the snapshot against Q, print ranked lines

Deps: tmux, fzf, python3. No compiled binary needed - the corpus is a few
dozen panes and a few thousand lines each, captured once per invocation, so
a script comfortably keeps up with live typing.
"""
import argparse
import json
import math
import os
import re
import shlex
import subprocess
import sys
import tempfile
import time
from bisect import bisect_left
from collections import Counter
from concurrent.futures import ThreadPoolExecutor

CAPTURE_LINES = int(os.environ.get("TMUX_WINDOW_SEARCH_LINES", 5000))

# opt-in latency logging: `touch ~/.cache/tmux-window-search-debug` to enable,
# rm it to disable. Zero cost when the marker is absent (checked once at
# import, not per-call) - kept in the script rather than stripped after use
# since perf regressions here are easy to introduce and hard to notice.
_DEBUG = os.path.exists(os.path.expanduser("~/.cache/tmux-window-search-debug"))
_T0 = time.time()


def _dbg(msg):
    if not _DEBUG:
        return
    with open(os.path.expanduser("~/.cache/tmux-window-search-timing.log"), "a") as f:
        f.write(f"[abs={time.time():.3f} rel={time.time() - _T0:.3f} pid={os.getpid()}] {msg}\n")
WINDOW_NAME_BOOST = 4  # how many times a window-name token is repeated into the doc
PANE_TITLE_BOOST = 8  # pane_title is a full, deliberate sentence rather than
# a generic command name (e.g. Claude Code sets it to the actual
# conversation topic) - a hit there is a much stronger signal than the same
# word merely appearing somewhere in scrollback, so it's boosted harder
# than window_name
K1, B = 1.5, 0.75  # standard Okapi BM25 defaults
RECENCY_CHUNKS = 8  # coarse recency buckets per window instead of per-line -
# per-line tokenizing was 380ms of a 445ms build on ~50 windows/250k lines,
# almost all Python-level loop/call overhead rather than regex matching;
# chunking amortizes that to ~190ms with no measurable ranking difference
# (recency only needs to distinguish "recent" from "old", not exact line)

TOKEN_RE = re.compile(r"[a-z0-9]+")


def tokenize(text):
    return TOKEN_RE.findall(text.lower())


def capture_pane(pane_id):
    out = subprocess.run(
        ["tmux", "capture-pane", "-p", "-J", "-t", pane_id, "-S", f"-{CAPTURE_LINES}"],
        capture_output=True, text=True, errors="replace",
    ).stdout
    return pane_id, out.splitlines()


def chunked_tf(lines):
    """Recency-weighted term frequency for a window's lines, in RECENCY_CHUNKS
    Counter() passes over joined chunks instead of one tokenize() call per
    line - same ranking behavior, far fewer Python-level calls."""
    tf = {}
    n = max(1, len(lines) - 1)
    chunk_size = max(1, len(lines) // RECENCY_CHUNKS)
    doclen = 0
    for c in range(0, len(lines), chunk_size):
        chunk = lines[c:c + chunk_size]
        recency = 0.3 + 0.7 * ((c + len(chunk) // 2) / n)
        counts = Counter(TOKEN_RE.findall("\n".join(t for _, t in chunk).lower()))
        doclen += sum(counts.values())
        for tok, cnt in counts.items():
            tf[tok] = tf.get(tok, 0.0) + cnt * recency
    return tf, doclen


def build_snapshot():
    fields = ["session_name", "window_id", "window_index", "window_name",
              "window_flags", "pane_id", "pane_active", "pane_title",
              "window_activity"]
    fmt = "\t".join(f"#{{{f}}}" for f in fields)
    out = subprocess.run(
        ["tmux", "list-panes", "-a", "-F", fmt],
        capture_output=True, text=True,
    ).stdout

    panes_by_window = {}
    for line in out.splitlines():
        session, wid, widx, wname, wflags, pane_id, active, ptitle, activity = line.split("\t")
        w = panes_by_window.setdefault(wid, {
            "session": session, "window_index": widx, "window_name": wname,
            "window_flags": wflags, "activity": int(activity),
            "panes": [], "active_pane": None, "pane_title": "",
        })
        w["panes"].append(pane_id)
        if active == "1":
            w["active_pane"] = pane_id
            w["pane_title"] = ptitle

    pane_ids = [pid for w in panes_by_window.values() for pid in w["panes"]]
    with ThreadPoolExecutor(max_workers=min(32, max(1, len(pane_ids)))) as ex:
        captures = dict(ex.map(capture_pane, pane_ids))

    windows = {}
    for wid, w in panes_by_window.items():
        lines = []  # [pane_id, text]
        for pid in w["panes"]:
            for text in captures[pid]:
                lines.append([pid, text])

        tf, doclen = chunked_tf(lines)
        for boost, field in ((WINDOW_NAME_BOOST, w["window_name"]),
                             (PANE_TITLE_BOOST, w["pane_title"])):
            field_tokens = tokenize(field)
            for tok in field_tokens * boost:
                tf[tok] = tf.get(tok, 0) + 1.0
            doclen += boost * len(field_tokens)

        windows[wid] = {
            **w, "lines": lines, "tf": tf, "doclen": doclen,
        }

    df = {}
    for w in windows.values():
        for tok in w["tf"]:
            df[tok] = df.get(tok, 0) + 1

    avgdl = sum(w["doclen"] for w in windows.values()) / max(1, len(windows))
    # sorted once here so prefix queries ("ric" -> "ricing", "rice", ...) can
    # binary-search a contiguous range at query time instead of scanning -
    # see expand_prefix()
    vocab = sorted(df.keys())
    return {"windows": windows, "df": df, "n": len(windows), "avgdl": avgdl,
            "vocab": vocab}


CONNECTOR_RE = re.compile(r"^[^\sA-Za-z0-9]+$")  # punctuation, no whitespace


def highlight(text, qset):
    """Wrap query-token matches in text with bold-yellow ANSI.

    Matching itself stays word-level (TOKEN_RE strips punctuation, same as
    everywhere else - "alt" still finds "ctrl+alt+h", "case" still finds
    "case-insensitive"), and prefix-aware like scoring ("ric" highlights the
    "ric" inside "ricing"), but highlighting is span-merged: consecutive
    matched words joined only by punctuation (no whitespace between them)
    get highlighted as one run, "+"/"-" included, so "ctrl+alt+h" doesn't
    render as three disconnected highlighted letters with plain symbols
    poking through - while "alt" typed alone still only lights up "alt".
    """
    if not qset:
        return text
    matches = list(TOKEN_RE.finditer(text.lower()))
    spans = []
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
    for start, end in sorted(spans, reverse=True):
        text = text[:start] + "\x1b[1;33m" + text[start:end] + "\x1b[0m" + text[end:]
    return text


def expand_prefix(prefix, vocab):
    """All corpus vocabulary terms starting with prefix, via binary search
    over the sorted term list - same technique recoll/Xapian use for
    wildcard/prefix queries. Without this, live-as-you-type search is
    useless: typing "ric" while looking for a window titled "...ricing..."
    would find nothing until the whole word was typed, since matching was
    otherwise always exact-token."""
    lo = bisect_left(vocab, prefix)
    hi = bisect_left(vocab, prefix + "￿")  # sorts after anything TOKEN_RE produces
    return vocab[lo:hi]


def best_pane(window, qset):
    """Which pane, of possibly several in this window, actually matched the
    query - that's the one to jump to and preview, not just window["active_pane"].
    qset holds the raw typed prefixes (e.g. {"ric"}), matched by startswith
    against the window's own tokens - same prefix semantics as scoring."""
    best = None  # (n_matched, index, pane_id)
    for i, (pane_id, text) in enumerate(window["lines"]):
        # cheap substring pre-check (C-level `in`) before paying for a real
        # tokenize() - most lines don't match, and this alone cut this loop
        # from 130ms to 35ms across a 17-window result set. Already prefix-
        # aware for free: "ric" in "...ricing..." is a plain substring test.
        low = text.lower()
        if not any(q in low for q in qset):
            continue
        matched = {t for t in tokenize(text) if any(t.startswith(q) for q in qset)}
        if not matched:
            continue
        key = (len(matched), i)
        if best is None or key > best[0]:
            best = (key, pane_id)
    if best is None:
        return window["active_pane"] or window["panes"][0]
    return best[1]


def bm25_score(window, terms, df, n, avgdl):
    """terms are already-expanded vocabulary terms (see expand_prefix), not
    raw query tokens - each contributes its own idf/tf like an independent
    OR'd query term, standard treatment for wildcard-expanded queries."""
    score = 0.0
    dl = window["doclen"]
    for term in terms:
        f = window["tf"].get(term, 0)
        if f == 0:
            continue
        n_q = df.get(term, 0)
        idf = math.log((n - n_q + 0.5) / (n_q + 0.5) + 1)
        score += idf * (f * (K1 + 1)) / (f + K1 * (1 - B + B * dl / avgdl))
    return score


def search(snapshot_path, query):
    _dbg(f"search() start query={query!r}")
    with open(snapshot_path) as f:
        snap = json.load(f)
    windows, df, n, avgdl = snap["windows"], snap["df"], snap["n"], snap["avgdl"]
    query_tokens = tokenize(query)
    _dbg("snapshot loaded")

    if not query_tokens:
        ranked = sorted(windows.items(), key=lambda kv: -kv[1]["activity"])
        for wid, w in ranked:
            pane_id = w["active_pane"] or w["panes"][0]
            print(row(pane_id, w))
        _dbg("printed (empty query)")
        return

    # expand each typed token to matching vocabulary terms ONCE here (it only
    # depends on the corpus-wide vocab, not on any particular window), then
    # score every window against that flat, pre-expanded term list
    vocab = snap["vocab"]
    terms = [t for tok in query_tokens for t in expand_prefix(tok, vocab)]
    _dbg(f"query tokens {query_tokens} expanded to {len(terms)} terms")

    scored = []
    for wid, w in windows.items():
        s = bm25_score(w, terms, df, n, avgdl)
        if s > 0:
            scored.append((s, wid, w))
    scored.sort(key=lambda t: -t[0])

    qset = set(query_tokens)
    for _, wid, w in scored:
        pane_id = best_pane(w, qset)
        print(row(pane_id, w, qset))
    _dbg(f"printed ({len(scored)} results)")


def row(pane_id, w, qset=frozenset()):
    # mirrors tmux's own choose-tree row: "index: name+flags: \"pane title\"" -
    # the preview pane below already shows content, so this only needs to
    # identify the window, not summarize what matched inside it. name/title
    # matches are highlighted same as the preview - they're boosted in
    # scoring (see PANE_TITLE_BOOST) precisely because they're a strong
    # signal, so the highlight should make that visible too, not just the
    # ranking.
    name = highlight(w["window_name"], qset)
    title = highlight(w["pane_title"], qset)
    panes_suffix = f" ({len(w['panes'])}p)" if len(w["panes"]) > 1 else ""
    label = f'{w["session"]}:{w["window_index"]} {name}{w["window_flags"]}: "{title}"{panes_suffix}'
    return f"{pane_id}\t{label}"


PREVIEW_CONTEXT_BEFORE = 5  # lines of leading context kept above a jumped-to match


def preview(pane_id, query):
    # no -e here (unlike the old plain capture): highlighting has to insert
    # its own ANSI codes into the text, and re-coloring on top of the pane's
    # *own* existing color codes without clobbering them would mean tracking
    # SGR state across every match - not worth it for a preview pane, so this
    # trades the pane's original colors for reliable highlighting instead.
    #
    # depth matches CAPTURE_LINES, the same depth indexing/scoring searched -
    # this used to be hardcoded to 300, so a window could rank (and get
    # highlighted title matches) purely from a hit between line 300 and
    # CAPTURE_LINES back in scrollback while the preview - unable to show
    # what it never captured - looked like nothing had matched at all.
    out = subprocess.run(
        ["tmux", "capture-pane", "-p", "-t", pane_id, "-S", f"-{CAPTURE_LINES}"],
        capture_output=True, text=True, errors="replace",
    ).stdout
    qset = set(tokenize(query))
    if not qset:
        sys.stdout.write(out)
        return

    # jump near the match instead of always opening at the top of a
    # potentially thousands-of-lines capture: scan from the *end* backwards
    # for the most recent matching line, consistent with the recency
    # weighting already used in scoring (the match that actually justified
    # a high recency-weighted score is more likely near the bottom).
    lines = out.split("\n")
    match_idx = None
    for i in range(len(lines) - 1, -1, -1):
        low = lines[i].lower()
        if not any(q in low for q in qset):
            continue
        if any(t.startswith(q) for t in tokenize(lines[i]) for q in qset):
            match_idx = i
            break
    if match_idx is not None and match_idx > PREVIEW_CONTEXT_BEFORE:
        skipped = match_idx - PREVIEW_CONTEXT_BEFORE
        lines = [f"… {skipped} earlier lines not shown …"] + lines[skipped:]
        out = "\n".join(lines)

    sys.stdout.write(highlight(out, qset))


def resolve_client():
    """The client that opened the popup, stashed into tmux's global
    environment by the bind-key's run-shell step (see .tmux.conf for why
    it has to be a bridge like this rather than a plain argument)."""
    r = subprocess.run(["tmux", "show-environment", "-g", "TMUX_WINDOW_SEARCH_CLIENT"],
                        capture_output=True, text=True)
    subprocess.run(["tmux", "set-environment", "-gu", "TMUX_WINDOW_SEARCH_CLIENT"],
                    capture_output=True, text=True)
    if r.returncode != 0 or "=" not in r.stdout:
        return None
    return r.stdout.strip().split("=", 1)[1]


def drive():
    client = resolve_client()
    _dbg(f"drive() start client={client!r}")
    snapshot = build_snapshot()
    _dbg("build_snapshot done")
    if not snapshot["windows"]:
        return

    fd, snap_path = tempfile.mkstemp(prefix="tmux-window-search-", suffix=".json")
    with os.fdopen(fd, "w") as f:
        json.dump(snapshot, f)
    _dbg("snapshot written to disk")

    py = f"{shlex.quote(sys.executable)} {shlex.quote(os.path.abspath(__file__))}"
    self_cmd = f"{py} --search {shlex.quote(snap_path)} --query {{q}}"
    preview_cmd = f"{py} --preview {{1}} --query {{q}}"
    # fzf has no "size list to fit its rows" primitive for preview-window (it
    # only sizes the preview pane, list gets the remainder) - so this reacts
    # to each completed search (the `result` event) and hands the list back
    # just enough rows for $FZF_MATCH_COUNT, giving the rest to the preview.
    # $FZF_LINES/$FZF_MATCH_COUNT are exported by fzf to every child process,
    # including this one - exact row arithmetic instead of coarse percentage
    # tiers, which always left a few rows of dead space unless the match
    # count happened to land right at a tier boundary. +3 is the prompt line
    # plus the match-count info line above the list (--layout=reverse, no
    # --info=inline) plus one extra row - +2 measured one row short in
    # practice, clipping the last result; floor/ceiling keep both panes from
    # collapsing to nothing at either extreme. POSIX sh, since this runs
    # through fzf's $SHELL, not necessarily zsh.
    resize_on_result = (
        'c=$FZF_MATCH_COUNT; list_rows=$((c + 3)); '
        '[ "$list_rows" -lt 4 ] && list_rows=4; '
        'max_list=$((FZF_LINES - 4)); '
        '[ "$list_rows" -gt "$max_list" ] && list_rows=$max_list; '
        'echo "change-preview-window(down,$((FZF_LINES - list_rows)))"'
    )
    _dbg("launching fzf")
    try:
        result = subprocess.run(
            [
                "fzf", "--ansi", "--disabled", "--layout=reverse",
                "--delimiter", "\t", "--with-nth", "2..",
                "--prompt", "window search> ",
                "--preview", preview_cmd,
                "--preview-window", "down,50%,border-top",
                "--bind", f"start:reload:{self_cmd}",
                "--bind", f"change:reload:{self_cmd}",
                "--bind", f"result:transform:{resize_on_result}",
                # move-by-word, matching alt-left/right (fzf's own default
                # binding for backward-word/forward-word) rather than
                # deleting - fzf has no configurable WORDCHARS like zsh's,
                # so word boundaries are fzf's own fixed logic either way
                "--bind", "ctrl-left:backward-word",
                "--bind", "ctrl-right:forward-word",
            ],
            capture_output=True, text=True,
        )
    finally:
        os.unlink(snap_path)
    _dbg(f"fzf exited rc={result.returncode} stdout_len={len(result.stdout)} stderr={result.stderr!r}")

    selected = result.stdout.strip()
    if not selected:
        _dbg("no selection (cancelled)")
        return
    pane_id = selected.split("\t", 1)[0]
    _dbg(f"selected pane_id={pane_id}")
    jump(client, pane_id)


def jump(client, pane_id):
    """The actual point of this tool: land the client that opened the popup
    on the chosen pane. Every step here is verified against real tmux state
    rather than trusted from a subprocess return code, and any failure is
    fatal (loud, not silent) - this is the one thing that must not quietly
    stop working, see git log on this function before touching it."""
    # switch-client with no -c doesn't affect "the client that ran this" - a
    # popup's shell process has no controlling pane of its own (popups aren't
    # real panes, so tmux can't map it back to a client the way it does for
    # a command typed inside a normal pane), so it silently falls back to
    # some other attached client instead. #{client_tty}, captured at bind
    # time when tmux does know who pressed the key, fixes that - but only if
    # it actually arrived, so treat a missing one as fatal rather than
    # quietly degrading to the ambiguous no -c behavior.
    if not client:
        die(f"no client argument received (argv={sys.argv!r}) - "
            f"check the bind-key still passes '#{{client_tty}}'")

    clients = {c: s for c, s in (
        line.split("\t") for line in
        subprocess.run(["tmux", "list-clients", "-F", "#{client_tty}\t#{session_name}"],
                        capture_output=True, text=True).stdout.splitlines()
    )}
    if client not in clients:
        die(f"client {client!r} isn't in the current attached-client list "
            f"{sorted(clients)!r} - can't target a switch-client to it")

    for cmd in (["switch-client", "-c", client, "-t", pane_id],
                ["select-window", "-t", pane_id],
                ["select-pane", "-t", pane_id]):
        r = subprocess.run(["tmux", *cmd], capture_output=True, text=True)
        _dbg(f"tmux {' '.join(cmd)} -> rc={r.returncode} stderr={r.stderr!r}")
        if r.returncode != 0:
            die(f"tmux {' '.join(cmd)} failed: {r.stderr.strip()}")

    # verify via list-clients, not `display-message -c` - the latter turned
    # out to be unreliable in testing (returned stale/wrong data regardless
    # of -c, independent of whether the switch itself had actually worked),
    # whereas list-clients enumerating every client fresh was consistently
    # accurate against directly-observed tmux state
    after = {c: p for c, p in (
        line.split("\t") for line in
        subprocess.run(["tmux", "list-clients", "-F", "#{client_tty}\t#{pane_id}"],
                        capture_output=True, text=True).stdout.splitlines()
    )}
    actual = after.get(client)
    _dbg(f"post-jump check: client {client} now on pane {actual!r}, wanted {pane_id!r}")
    if actual != pane_id:
        die(f"selected {pane_id} but client {client} ended up on {actual!r} instead - "
            f"switch-client silently landed on the wrong pane")


def die(msg):
    _dbg(f"FATAL: {msg}")
    print(f"window-search: {msg}", file=sys.stderr)
    sys.exit(1)


def main():
    _dbg(f"main() argv={sys.argv[1:]}")
    parser = argparse.ArgumentParser()
    parser.add_argument("--search", metavar="SNAPSHOT")
    parser.add_argument("--preview", metavar="PANE_ID")
    parser.add_argument("--query", default="")
    args = parser.parse_args()

    if args.preview:
        preview(args.preview, args.query)
    elif args.search:
        search(args.search, args.query)
    else:
        drive()


if __name__ == "__main__":
    main()

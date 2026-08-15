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
TITLE_BOOST = 4  # how many times a title token is repeated into the doc
K1, B = 1.5, 0.75  # standard Okapi BM25 defaults
SNIPPET_WIDTH = 90
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
              "pane_id", "pane_active", "window_activity"]
    fmt = "\t".join(f"#{{{f}}}" for f in fields)
    out = subprocess.run(
        ["tmux", "list-panes", "-a", "-F", fmt],
        capture_output=True, text=True,
    ).stdout

    panes_by_window = {}
    for line in out.splitlines():
        session, wid, widx, wname, pane_id, active, activity = line.split("\t")
        w = panes_by_window.setdefault(wid, {
            "session": session, "window_index": widx, "window_name": wname,
            "activity": int(activity), "panes": [], "active_pane": None,
        })
        w["panes"].append(pane_id)
        if active == "1":
            w["active_pane"] = pane_id

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
        title_tokens = tokenize(w["window_name"])
        for tok in title_tokens * TITLE_BOOST:
            tf[tok] = tf.get(tok, 0) + 1.0
        doclen += TITLE_BOOST * len(title_tokens)

        windows[wid] = {
            **w, "lines": lines, "tf": tf, "doclen": doclen,
        }

    df = {}
    for w in windows.values():
        for tok in w["tf"]:
            df[tok] = df.get(tok, 0) + 1

    avgdl = sum(w["doclen"] for w in windows.values()) / max(1, len(windows))
    return {"windows": windows, "df": df, "n": len(windows), "avgdl": avgdl}


def highlight(text, qset):
    """Wrap query-token matches in text with bold-yellow ANSI, longest tokens
    first so e.g. "git" doesn't shadow a match of "github" underneath it."""
    for tok in sorted(qset, key=len, reverse=True):
        text = re.sub(f"(?i)({re.escape(tok)})", "\x1b[1;33m\\1\x1b[0m", text)
    return text


def best_snippet(window, query_tokens):
    qset = set(query_tokens)
    best = None  # (n_matched, index, pane_id, text)
    for i, (pane_id, text) in enumerate(window["lines"]):
        # cheap substring pre-check (C-level `in`) before paying for a real
        # tokenize() - most lines don't match, and this alone cut best_snippet
        # from 130ms to 35ms across a 17-window result set
        low = text.lower()
        if not any(tok in low for tok in qset):
            continue
        matched = qset & set(tokenize(text))
        if not matched:
            continue
        key = (len(matched), i)
        if best is None or key > best[0]:
            best = (key, pane_id, text)
    if best is None:
        pane_id = window["active_pane"] or window["panes"][0]
        return pane_id, ""
    _, pane_id, text = best

    highlighted = highlight(text, qset)
    plain = re.sub(r"\x1b\[[0-9;]*m", "", highlighted)
    if len(plain) > SNIPPET_WIDTH:
        m = re.search("(?i)" + "|".join(re.escape(t) for t in qset), text)
        start = max(0, (m.start() if m else 0) - SNIPPET_WIDTH // 3)
        # re-slice from the *plain* text then re-highlight, simpler than
        # tracking ansi-code offsets through the truncation
        window_text = text[start:start + SNIPPET_WIDTH]
        highlighted = highlight(window_text, qset)
        prefix = "…" if start > 0 else ""
        suffix = "…" if start + SNIPPET_WIDTH < len(text) else ""
        highlighted = prefix + highlighted + suffix
    return pane_id, highlighted.strip()


def bm25_score(window, query_tokens, df, n, avgdl):
    score = 0.0
    dl = window["doclen"]
    for tok in query_tokens:
        f = window["tf"].get(tok, 0)
        if f == 0:
            continue
        n_q = df.get(tok, 0)
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
            print(row(pane_id, w, ""))
        _dbg("printed (empty query)")
        return

    scored = []
    for wid, w in windows.items():
        s = bm25_score(w, query_tokens, df, n, avgdl)
        if s > 0:
            scored.append((s, wid, w))
    scored.sort(key=lambda t: -t[0])

    for _, wid, w in scored:
        pane_id, snippet = best_snippet(w, query_tokens)
        print(row(pane_id, w, snippet))
    _dbg(f"printed ({len(scored)} results)")


def row(pane_id, w, snippet):
    panes_suffix = f" ({len(w['panes'])}p)" if len(w["panes"]) > 1 else ""
    label = f"{w['session']}:{w['window_index']} [{w['window_name']}]{panes_suffix}"
    tail = f" │ {snippet}" if snippet else ""
    return f"{pane_id}\t{label}{tail}"


def preview(pane_id, query):
    # no -e here (unlike the old plain capture): highlighting has to insert
    # its own ANSI codes into the text, and re-coloring on top of the pane's
    # *own* existing color codes without clobbering them would mean tracking
    # SGR state across every match - not worth it for a preview pane, so this
    # trades the pane's original colors for reliable highlighting instead
    out = subprocess.run(
        ["tmux", "capture-pane", "-p", "-t", pane_id, "-S", "-300"],
        capture_output=True, text=True, errors="replace",
    ).stdout
    query_tokens = tokenize(query)
    if query_tokens:
        out = highlight(out, set(query_tokens))
    sys.stdout.write(out)


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
    _dbg("launching fzf")
    try:
        result = subprocess.run(
            [
                "fzf", "--ansi", "--disabled",
                "--delimiter", "\t", "--with-nth", "2..",
                "--prompt", "window search> ",
                "--header", "type to full-text search all pane scrollback (BM25 + recency) · enter to jump",
                "--preview", preview_cmd,
                "--preview-window", "right,55%,border-left",
                "--bind", f"start:reload:{self_cmd}",
                "--bind", f"change:reload:{self_cmd}",
                # fzf has no configurable WORDCHARS like zsh's - this is its
                # own fixed word-boundary logic, closest available match
                "--bind", "ctrl-left:backward-kill-word",
                "--bind", "ctrl-right:kill-word",
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

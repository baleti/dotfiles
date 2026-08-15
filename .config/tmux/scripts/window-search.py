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
from collections import Counter
from concurrent.futures import ThreadPoolExecutor

CAPTURE_LINES = int(os.environ.get("TMUX_WINDOW_SEARCH_LINES", 5000))
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

    highlighted = text
    for tok in sorted(qset, key=len, reverse=True):
        highlighted = re.sub(
            f"(?i)({re.escape(tok)})", "\x1b[1;33m\\1\x1b[0m", highlighted
        )
    plain = re.sub(r"\x1b\[[0-9;]*m", "", highlighted)
    if len(plain) > SNIPPET_WIDTH:
        m = re.search("(?i)" + "|".join(re.escape(t) for t in qset), text)
        start = max(0, (m.start() if m else 0) - SNIPPET_WIDTH // 3)
        # re-slice from the *plain* text then re-highlight, simpler than
        # tracking ansi-code offsets through the truncation
        window_text = text[start:start + SNIPPET_WIDTH]
        highlighted = window_text
        for tok in sorted(qset, key=len, reverse=True):
            highlighted = re.sub(
                f"(?i)({re.escape(tok)})", "\x1b[1;33m\\1\x1b[0m", highlighted
            )
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
    with open(snapshot_path) as f:
        snap = json.load(f)
    windows, df, n, avgdl = snap["windows"], snap["df"], snap["n"], snap["avgdl"]
    query_tokens = tokenize(query)

    if not query_tokens:
        ranked = sorted(windows.items(), key=lambda kv: -kv[1]["activity"])
        for wid, w in ranked:
            pane_id = w["active_pane"] or w["panes"][0]
            print(row(pane_id, w, ""))
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


def row(pane_id, w, snippet):
    panes_suffix = f" ({len(w['panes'])}p)" if len(w["panes"]) > 1 else ""
    label = f"{w['session']}:{w['window_index']} [{w['window_name']}]{panes_suffix}"
    tail = f" │ {snippet}" if snippet else ""
    return f"{pane_id}\t{label}{tail}"


def drive():
    snapshot = build_snapshot()
    if not snapshot["windows"]:
        return

    fd, snap_path = tempfile.mkstemp(prefix="tmux-window-search-", suffix=".json")
    with os.fdopen(fd, "w") as f:
        json.dump(snapshot, f)

    self_cmd = f"{shlex.quote(sys.executable)} {shlex.quote(os.path.abspath(__file__))} --search {shlex.quote(snap_path)} --query {{q}}"
    try:
        result = subprocess.run(
            [
                "fzf", "--ansi", "--disabled",
                "--delimiter", "\t", "--with-nth", "2..",
                "--prompt", "window search> ",
                "--header", "type to full-text search all pane scrollback (BM25 + recency) · enter to jump",
                "--preview", "tmux capture-pane -p -e -t {1} | tail -n 300",
                "--preview-window", "right,55%,border-left",
                "--bind", f"start:reload:{self_cmd}",
                "--bind", f"change:reload:{self_cmd}",
            ],
            capture_output=True, text=True,
        )
    finally:
        os.unlink(snap_path)

    selected = result.stdout.strip()
    if not selected:
        return
    pane_id = selected.split("\t", 1)[0]
    subprocess.run(["tmux", "switch-client", "-t", pane_id])
    subprocess.run(["tmux", "select-window", "-t", pane_id])
    subprocess.run(["tmux", "select-pane", "-t", pane_id])


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--search", metavar="SNAPSHOT")
    parser.add_argument("--query", default="")
    args = parser.parse_args()

    if args.search:
        search(args.search, args.query)
    else:
        drive()


if __name__ == "__main__":
    main()

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

Query syntax (the subset of recoll's query language that earns its keep
here - see parse_query/phrase_re). Two orthogonal rules: quotes mean exact,
! means negate.

  foo bar        bare words: prefix-expanded ("ric" finds "ricing"). All of
                 them must be present (recoll's implicit AND) - see
                 MATCH_MODE to get the older any-word-ranks behaviour back
  ctrl+.         bare word carrying punctuation: still searches the word
                 ("ctrl"), but windows containing the literal "ctrl+." are
                 ranked above those that merely have "ctrl". Nothing is
                 excluded, so it stays useful while half-typed
  "foo bar"      phrase: that text literally, whitespace runs excepted.
                 Never prefix-expanded, and required
  "ctrl+."       punctuation included - the only way to demand an exact
                 keybinding, flag or path rather than just its words
  "foo"          one-word phrase: the exact whole word, i.e. the way to say
                 "we" and not also match "web"/"weight"
  !foo           drop windows containing foo (prefix-expanded, so !log also
                 drops logs/login - use !"log" to be exact)
  !"foo bar"     drop windows containing that exact phrase

Everything present is required; ranking then orders what survived. So
`error "connection refused" !timeout` keeps only windows with the exact
phrase and the word error and no timeout, and ranks the rest by relevance.

! rather than recoll's - for negation: a leading dash has to stay available,
because searching scrollback for `-rf` or `--stat` is a thing you actually
do in a terminal-history index.

Two modes:
  driver (no args):        snapshot every pane once, drive fzf, jump on select
  --search FILE --query Q: score the snapshot against Q, print ranked lines

Deps: tmux, fzf, python3. No compiled binary needed - the corpus is a few
dozen panes and a few thousand lines each, captured once per invocation, so
a script comfortably keeps up with live typing.
"""
import argparse
import atexit
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
from bisect import bisect_left
from collections import Counter, namedtuple
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


# one query element: optional leading ! (negation), then either a
# double-quoted phrase or a run of non-space characters
QUERY_ELEM_RE = re.compile(r'(!?)(?:"([^"]*)"|(\S+))')

# recoll ANDs all elements together ("all elements in the search entry are
# normally combined with an implicit AND"). "all" reproduces that: every bare
# word must be present somewhere in the window. "any" is the original
# behaviour - a window matching only one word still appears, just ranked
# lower - kept switchable because which one feels right depends on how you
# type, and swapping back is a one-word change rather than a revert.
MATCH_MODE = os.environ.get("TMUX_WINDOW_SEARCH_MATCH", "all").lower()

Query = namedtuple("Query", "terms phrases neg_terms neg_phrases soft")


def parse_query(query):
    """Parse a query into positive/negative bare words and phrases.

    The rule is orthogonal in both directions, which is what makes it
    memorable: quotes mean exact (never prefix-expanded), and ! means
    negate. So all four combinations do what they look like -

      foo        bare, prefix-expanded ("ric" finds "ricing"), required
                 when MATCH_MODE is "all"
      "foo bar"  those words adjacent and in that order, exact, required
      !foo       drop windows containing foo (prefix-expanded, so !log
                 also drops logs/login - use !"log" to be exact)
      !"foo bar" drop windows containing that exact phrase

    Bare words are the split recoll/Xapian make for the same reason: loose
    ranked evidence versus an exact constraint. Per recoll's manual, "words
    inside phrases [...] are not stem-expanded" and phrases are "searched
    verbatim".

    ! rather than recoll's - because a leading dash is not available here:
    scrollback is full of CLI flags, and `-rf` or `--stat` is a thing you
    genuinely want to search *for* in a terminal-history index. ! has no such
    conflict, since TOKEN_RE never produces it and no flag begins with it.

    An unterminated quote (every phrase mid-typing, e.g. `"we ne`) falls back
    to bare words, so live-as-you-type keeps narrowing instead of blanking
    the list while the phrase is half-entered."""
    terms, phrases, neg_terms, neg_phrases, soft = [], [], [], [], []
    for neg, quoted, bare in QUERY_ELEM_RE.findall(query):
        # exactly one alternative participates; `bare` is non-empty whenever
        # it is the one that matched, so it doubles as the discriminator.
        # An unterminated quote lands here (no closing quote for the phrase
        # branch to match), and tokenize drops the stray " - which is what
        # degrades a half-typed phrase to bare words rather than to nothing.
        if bare:
            toks = tokenize(bare)
            for tok in toks:
                (neg_terms if neg else terms).append(tok)
            # A bare word carrying punctuation - ctrl+., --stat, ~/.config -
            # loses that punctuation to TOKEN_RE, so `ctrl+.` searches for
            # nothing more than `ctrl`. Rather than make bare words literal
            # (which would break prefix expansion, and with it typing), the
            # raw text is kept as a *soft* literal: it adds score where it
            # actually occurs but filters nothing, so the window holding the
            # real "ctrl+." rises to the top while every "ctrl" window still
            # shows up. prefix=True keeps the bonus live mid-word.
            if not neg and toks and any(not c.isalnum() for c in bare):
                soft.append(bare.lower())
        elif quoted.strip():
            # kept as the raw string, not tokens - see phrase_re. A phrase of
            # pure punctuation ("+.") is legal and searchable for that reason.
            (neg_phrases if neg else phrases).append(quoted.strip().lower())
    return Query(terms, phrases, neg_terms, neg_phrases, soft)


def phrase_re(raw, prefix=False):
    """Regex matching the quoted text literally in lowercased text, with
    runs of whitespace allowed to differ in length.

    With prefix=True the closing word boundary is dropped, so the pattern
    still matches while the user is only part-way through typing it. That is
    what the soft literal bonus on bare words needs (see parse_query).

    Built from the raw quoted string rather than from its tokens, because
    tokens cannot represent punctuation at all: TOKEN_RE is [a-z0-9]+, so
    tokenizing "ctrl+." yields just ["ctrl"] and every trace of the "+."
    is gone before the query is even assembled. Matching on tokens therefore
    made `"ctrl+."`, `"ctrl"` and a bare `ctrl` the same query, and made
    punctuation-bearing strings - which in a terminal-history index is most
    of the interesting ones: keybindings, flags, paths, operators -
    impossible to search for exactly.

    Whitespace stays flexible (\\s+) so a phrase still matches across the
    column-aligned or re-wrapped spacing programs emit, but every other
    character is literal: `"we-need"` now requires the hyphen, where the
    older token-adjacency version would also have accepted "we need".
    That is the tighter and more predictable reading of "exact", and it is
    what makes quoting able to express something bare words cannot.

    The lookarounds are applied only at ends that are alphanumeric, so
    `"we"` is a whole word and does not fire inside "web", while a phrase
    ending in punctuation like `"ctrl+."` is not asked to justify a word
    boundary it does not have."""
    raw = raw.strip().lower()
    parts = [p for p in re.split(r"(\s+)", raw) if p]
    pattern = "".join(r"\s+" if p.isspace() else re.escape(p) for p in parts)
    pre = r"(?<![a-z0-9])" if raw[:1].isalnum() else ""
    post = "" if prefix else (r"(?![a-z0-9])" if raw[-1:].isalnum() else "")
    return re.compile(pre + pattern + post)


SNAP_PREFIX = "tmux-window-search-"


def snapshot_dir():
    """Where to put the snapshot, which is a verbatim copy of every pane's
    last CAPTURE_LINES lines - i.e. potentially every secret that has been
    echoed, pasted or printed into any pane on this machine.

    $XDG_RUNTIME_DIR is preferred because it is guaranteed to be a 0700
    per-user directory on a non-persistent filesystem that the system clears
    when the last session ends. /tmp is only the fallback: it is
    world-traversable, and on a minimal server it is frequently disk-backed
    rather than tmpfs, which would commit that scrollback to persistent
    storage. The file itself is 0600 either way (mkstemp), so this is
    defence in depth rather than the only thing keeping it private."""
    xdg = os.environ.get("XDG_RUNTIME_DIR")
    if xdg and os.path.isdir(xdg) and os.access(xdg, os.W_OK):
        return xdg
    return tempfile.gettempdir()


def _rm(path):
    """Idempotent unlink - both atexit and the finally in drive() call this."""
    try:
        os.unlink(path)
    except OSError:
        pass


def sweep_stale_snapshots():
    """Delete snapshots left behind by invocations that are no longer alive.

    The signal handler in drive() covers a window closed out from under a
    still-running invocation (e.g. `prefix+x`/kill-window), but it cannot
    cover every way this process can die - dismissing fzf with Escape still
    runs the normal `finally`, but a SIGKILL or a crash never runs Python
    code at all. Since each snapshot is a multi-megabyte copy of every
    pane's scrollback, an uncovered path is not a small leak: 38 files
    totalling ~180MB had accumulated in /tmp before this existed. Owning
    pid is in the filename, so liveness is exact rather than a guess from
    mtime, and a window legitimately open for hours is never swept out from
    under itself. Both candidate directories are swept, so
    switching between them (or a server without XDG_RUNTIME_DIR) still
    cleans up whatever an earlier run left in the other one."""
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
                continue  # pre-pid-tagging file; leave it, it may be in use
            try:
                os.kill(pid, 0)
                continue  # owner still running
            except ProcessLookupError:
                pass
            except OSError:
                continue  # exists but not ours to judge (EPERM)
            _rm(os.path.join(d, name))


def capture_pane(pane_id):
    # a pane can legitimately vanish between list-panes and here (it exited
    # while the snapshot was being built), so a failure isn't fatal the way
    # list-panes is - but it must not pass silently either: an ignored
    # non-zero rc leaves a window in the list that is permanently
    # unsearchable, with nothing anywhere saying why.
    r = subprocess.run(
        ["tmux", "capture-pane", "-p", "-J", "-t", pane_id, "-S", f"-{CAPTURE_LINES}"],
        capture_output=True, text=True, errors="replace",
    )
    if r.returncode != 0:
        _dbg(f"capture-pane {pane_id} failed rc={r.returncode} stderr={r.stderr.strip()!r}")
    return pane_id, r.stdout.splitlines()


def chunked_tf(texts, tf=None):
    """Recency-weighted term frequency for ONE pane's lines, in RECENCY_CHUNKS
    Counter() passes over joined chunks instead of one tokenize() call per
    line - same ranking behavior, far fewer Python-level calls.

    Deliberately per-pane, not per-window: recency is derived from a line's
    position in the list, so running it over a window's panes concatenated
    end-to-end would make "recent" mean "belongs to the last pane". In a
    split window that inverts the intended weighting outright - the freshest
    line of pane 1 scored below the stalest line of pane 2 (0.606 vs 0.694
    measured on a 2-pane window), i.e. pane ordering beat actual recency.
    Callers accumulate into a shared tf across the window's panes."""
    if tf is None:
        tf = {}
    n = max(1, len(texts) - 1)
    chunk_size = max(1, len(texts) // RECENCY_CHUNKS)
    doclen = 0
    for c in range(0, len(texts), chunk_size):
        chunk = texts[c:c + chunk_size]
        recency = 0.3 + 0.7 * ((c + len(chunk) // 2) / n)
        counts = Counter(TOKEN_RE.findall("\n".join(chunk).lower()))
        doclen += sum(counts.values())
        for tok, cnt in counts.items():
            tf[tok] = tf.get(tok, 0.0) + cnt * recency
    return tf, doclen


def build_snapshot():
    fields = ["session_name", "window_id", "window_index", "window_name",
              "window_flags", "pane_id", "pane_active", "pane_title",
              "window_activity"]
    fmt = "\t".join(f"#{{{f}}}" for f in fields)
    # checked, not trusted: an ignored failure here yields zero windows, and
    # the caller's "no windows" path used to return 0 - a broken list-panes
    # would then be indistinguishable from a missed keypress. die() prints
    # to stderr and exits non-zero specifically so .tmux.conf's `|| { ...;
    # read; }` wrapper catches it and keeps the window open to be read,
    # instead of the pane just vanishing (tmux's default on any exit).
    r = subprocess.run(
        ["tmux", "list-panes", "-a", "-F", fmt],
        capture_output=True, text=True,
    )
    if r.returncode != 0:
        die(f"tmux list-panes failed (rc={r.returncode}): {r.stderr.strip()}")
    out = r.stdout
    if not out.strip():
        die("tmux list-panes returned no panes - nothing to search")

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
        tf, doclen = {}, 0
        for pid in w["panes"]:
            texts = captures[pid]
            for text in texts:
                lines.append([pid, text])
            # recency is scored within each pane, then summed into the
            # window's single document (see chunked_tf)
            _, pane_doclen = chunked_tf(texts, tf)
            doclen += pane_doclen
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


def highlight(text, qset, rxs=()):
    """Wrap query-token and quoted-phrase matches in text with bold-yellow ANSI.

    Matching itself stays word-level (TOKEN_RE strips punctuation, same as
    everywhere else - "alt" still finds "ctrl+alt+h", "case" still finds
    "case-insensitive"), and prefix-aware like scoring ("ric" highlights the
    "ric" inside "ricing"), but highlighting is span-merged: consecutive
    matched words joined only by punctuation (no whitespace between them)
    get highlighted as one run, "+"/"-" included, so "ctrl+alt+h" doesn't
    render as three disconnected highlighted letters with plain symbols
    poking through - while "alt" typed alone still only lights up "alt".
    """
    if not qset and not rxs:
        return text
    low = text.lower()
    spans = []
    # quoted phrases first - they are whole runs by definition
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
    # phrase and bare-word spans can overlap (the phrase words are usually
    # also bare matches); merge before inserting or the escape codes nest and
    # the reversed-offset insertion below corrupts them
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
    """All corpus vocabulary terms starting with prefix, via binary search
    over the sorted term list - same technique recoll/Xapian use for
    wildcard/prefix queries. Without this, live-as-you-type search is
    useless: typing "ric" while looking for a window titled "...ricing..."
    would find nothing until the whole word was typed, since matching was
    otherwise always exact-token."""
    lo = bisect_left(vocab, prefix)
    hi = bisect_left(vocab, prefix + "￿")  # sorts after anything TOKEN_RE produces
    return vocab[lo:hi]


def best_pane(window, qset, rxs=(), phrase_panes=()):
    """Which pane, of possibly several in this window, actually matched the
    query - that's the one to jump to and preview, not just window["active_pane"].
    qset holds the raw typed prefixes (e.g. {"ric"}), matched by startswith
    against the window's own tokens - same prefix semantics as scoring.

    Ties break on how recent the match is *within its own pane*, for the same
    reason chunked_tf chunks per pane: window["lines"] is the panes laid
    end-to-end, so a raw index would just mean "prefers the last pane".

    When the query had quoted phrases, only panes actually containing every
    phrase are eligible: the phrase is the constraint the user expressed, so
    jumping to a pane that merely has some of the loose words would land them
    away from the thing they asked for."""
    eligible = None
    if rxs and phrase_panes:
        eligible = set.intersection(*[set(p) for p in phrase_panes])
        if not eligible:
            eligible = None
    pane_span = {}  # pane_id -> [first_index, last_index]
    for i, (pane_id, _) in enumerate(window["lines"]):
        span = pane_span.get(pane_id)
        if span is None:
            pane_span[pane_id] = [i, i]
        else:
            span[1] = i

    best = None  # (n_matched, in_pane_recency, pane_id)
    for i, (pane_id, text) in enumerate(window["lines"]):
        if eligible is not None and pane_id not in eligible:
            continue
        low = text.lower()
        # a phrase line counts as a match on its own, so a pure phrase query
        # (no bare words at all) still finds the right pane
        n_phrase = sum(1 for rx in rxs if rx.search(low))
        # cheap substring pre-check (C-level `in`) before paying for a real
        # tokenize() - most lines don't match, and this alone cut this loop
        # from 130ms to 35ms across a 17-window result set. Already prefix-
        # aware for free: "ric" in "...ricing..." is a plain substring test.
        matched = set()
        if qset and any(q in low for q in qset):
            matched = {t for t in tokenize(text) if any(t.startswith(q) for q in qset)}
        if not matched and not n_phrase:
            continue
        start, end = pane_span[pane_id]
        # phrases outrank loose words: an exact hit is the stronger signal
        key = (n_phrase, len(matched), (i - start) / max(1, end - start))
        if best is None or key > best[0]:
            best = (key, pane_id)
    if best is None:
        if eligible:
            return sorted(eligible)[0]
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


def phrase_counts(window, rxs, phrase_toks):
    """How many times each phrase occurs in this window, and which panes it
    occurred in. Counted at query time rather than indexed: a positional
    index (what Xapian keeps to do this properly) would mean storing a
    posting list per token per window, which is far more snapshot than the
    whole corpus is worth here, when the corpus is small enough to rescan."""
    counts = [0] * len(rxs)
    panes = [set() for _ in rxs]
    for pane_id, text in window["lines"]:
        low = text.lower()
        for i, (rx, toks) in enumerate(zip(rxs, phrase_toks)):
            # every word of the phrase must at least appear somewhere in the
            # line before the regex is worth running - plain `in` is a C-level
            # scan and rejects the overwhelming majority of lines, the same
            # trick that took best_pane from 130ms to 35ms. A phrase with no
            # word characters at all ("+.") has nothing to pre-check, so it
            # falls through to the regex, which is correct if slower.
            if toks and not all(t in low for t in toks):
                continue
            hits = len(rx.findall(low))
            if hits:
                counts[i] += hits
                panes[i].add(pane_id)
    return counts, panes


def bm25_term_score(f, n_q, dl, n, avgdl):
    """One term's BM25 contribution, shared by the vocabulary terms and by
    the query-time phrase pseudo-terms so both are ranked on one scale."""
    if f == 0:
        return 0.0
    idf = math.log((n - n_q + 0.5) / (n_q + 0.5) + 1)
    return idf * (f * (K1 + 1)) / (f + K1 * (1 - B + B * dl / avgdl))


def search(snapshot_path, query):
    _dbg(f"search() start query={query!r}")
    with open(snapshot_path) as f:
        snap = json.load(f)
    windows, df, n, avgdl = snap["windows"], snap["df"], snap["n"], snap["avgdl"]
    q = parse_query(query)
    _dbg(f"snapshot loaded; parsed {q}")

    if not any(q):
        ranked = sorted(windows.items(), key=lambda kv: -kv[1]["activity"])
        for wid, w in ranked:
            pane_id = w["active_pane"] or w["panes"][0]
            print(row(pane_id, w))
        _dbg("printed (empty query)")
        return

    # expand each typed token to matching vocabulary terms ONCE here (it only
    # depends on the corpus-wide vocab, not on any particular window). Kept
    # grouped by typed word, not flattened, because "all" mode has to ask
    # "did this window match *this* word" per word - the expansions of one
    # typed word are alternatives for it, not separate requirements.
    vocab = snap["vocab"]
    groups = [expand_prefix(tok, vocab) for tok in q.terms]
    terms = [t for g in groups for t in g]
    neg_terms = {t for tok in q.neg_terms for t in expand_prefix(tok, vocab)}
    _dbg(f"{len(q.terms)} words -> {len(terms)} terms, {len(neg_terms)} negated")

    rxs = [phrase_re(p) for p in q.phrases]
    neg_rxs = [phrase_re(p) for p in q.neg_phrases]
    # one scan covers positive and negative phrases; splitting them into two
    # passes would double the per-keystroke line walk for no benefit
    soft_rxs = [phrase_re(s, prefix=True) for s in q.soft]
    all_rxs = rxs + neg_rxs + soft_rxs
    all_toks = [tokenize(p) for p in q.phrases + q.neg_phrases + q.soft]
    n_pos, n_neg = len(rxs), len(neg_rxs)
    # A quoted phrase is a *constraint*, not just extra evidence: asking for
    # "we need" means the windows without that exact run are wrong answers,
    # not merely lower-ranked ones. Same for the bare words under MATCH_MODE
    # "all", which is recoll's implicit AND.
    hits = {}
    for wid, w in windows.items():
        if neg_terms and not neg_terms.isdisjoint(w["tf"]):
            continue
        counts, panes = phrase_counts(w, all_rxs, all_toks) if all_rxs else ([], [])
        if any(counts[n_pos:n_pos + n_neg]):   # a negated phrase is present
            continue
        # soft counts ride along in the same scan but never filter
        soft_counts = counts[n_pos + n_neg:]
        counts, panes = counts[:n_pos], panes[:n_pos]
        if rxs and not all(counts):
            continue
        if MATCH_MODE == "all" and not all(
                any(w["tf"].get(t) for t in g) for g in groups):
            continue
        hits[wid] = (counts, panes, soft_counts)
    # phrase df is over the windows that survived, computed here because a
    # phrase is not in the indexed vocabulary and so has no precomputed df
    phrase_df = [sum(1 for c, _, _ in hits.values() if c[i]) for i in range(n_pos)]
    soft_df = [sum(1 for _, _, s in hits.values() if s[i]) for i in range(len(soft_rxs))]

    scored = []
    if not terms and not rxs:
        # purely negative query ("!foo", "everything except..."): there is
        # nothing to rank *by*, so fall back to the empty-query ordering
        # (most recent activity) over whatever survived the exclusions.
        # Without this the BM25 sum is 0 for every window and the `s > 0`
        # test below would throw away the entire result set - i.e. asking to
        # exclude one thing would silently hide everything.
        for wid in hits:
            scored.append((windows[wid]["activity"], wid, windows[wid]))
    else:
        for wid, (counts, _, soft_counts) in hits.items():
            w = windows[wid]
            s = bm25_score(w, terms, df, n, avgdl)
            for i, c in enumerate(counts):
                s += bm25_term_score(c, phrase_df[i], w["doclen"], n, avgdl)
            # the soft literal is scored on the same scale as everything else,
            # so a window that really contains "ctrl+." outranks one that only
            # has the word "ctrl" - without excluding the latter
            for i, c in enumerate(soft_counts):
                s += bm25_term_score(c, soft_df[i], w["doclen"], n, avgdl)
            if s > 0:
                scored.append((s, wid, w))
    scored.sort(key=lambda t: -t[0])

    # the soft literals highlight and steer the jump too, since they are what
    # the user typed even though they did not filter
    show_rxs = rxs + soft_rxs
    qset = set(q.terms)
    for _, wid, w in scored:
        pane_id = best_pane(w, qset, show_rxs, hits[wid][1])
        print(row(pane_id, w, qset, show_rxs))
    _dbg(f"printed ({len(scored)} results, mode={MATCH_MODE}, "
         f"{len(rxs)} phrase constraint(s), {len(neg_rxs)} negated phrase(s))")


def row(pane_id, w, qset=frozenset(), rxs=()):
    # mirrors tmux's own choose-tree row: "index: name+flags: \"pane title\"" -
    # the preview pane below already shows content, so this only needs to
    # identify the window, not summarize what matched inside it. name/title
    # matches are highlighted same as the preview - they're boosted in
    # scoring (see PANE_TITLE_BOOST) precisely because they're a strong
    # signal, so the highlight should make that visible too, not just the
    # ranking.
    name = highlight(w["window_name"], qset, rxs)
    title = highlight(w["pane_title"], qset, rxs)
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
    #
    # -J for the same reason the depth matches: it's what the index used, so
    # without it the two disagree about what a token even is. A long path or
    # URL that wrapped in a narrow pane is one token to the indexer and two
    # to an unjoined capture, so the window ranks, gets a highlighted title,
    # and then the preview finds no match to jump to or highlight - the exact
    # "nothing matched" illusion the depth fix above was meant to remove.
    # Wrapped rejoined lines can now run past the preview width, so the
    # preview window is opened with `wrap` (see drive()).
    r = subprocess.run(
        ["tmux", "capture-pane", "-p", "-J", "-t", pane_id, "-S", f"-{CAPTURE_LINES}"],
        capture_output=True, text=True, errors="replace",
    )
    if r.returncode != 0:
        # loud in the preview pane itself rather than a blank one
        sys.stdout.write(f"[capture-pane {pane_id} failed: {r.stderr.strip()}]\n")
        return
    out = r.stdout
    # only the positive half matters here: the preview highlights and scrolls
    # to what was asked for, and a negated term is by definition absent
    q = parse_query(query)
    qset = set(q.terms)
    rxs = ([phrase_re(p) for p in q.phrases]
           + [phrase_re(s, prefix=True) for s in q.soft])
    if not qset and not rxs:
        sys.stdout.write(out)
        return

    # jump near the match instead of always opening at the top of a
    # potentially thousands-of-lines capture: scan from the *end* backwards
    # for the most recent matching line, consistent with the recency
    # weighting already used in scoring (the match that actually justified
    # a high recency-weighted score is more likely near the bottom).
    #
    # A phrase, when present, is what the user actually asked for, so it wins
    # the jump: landing on a loose word-match while the exact run sits
    # offscreen would defeat the point of having quoted it.
    lines = out.split("\n")
    match_idx = find_match_line(lines, qset, rxs)
    if match_idx is not None and match_idx > PREVIEW_CONTEXT_BEFORE:
        skipped = match_idx - PREVIEW_CONTEXT_BEFORE
        lines = [f"… {skipped} earlier lines not shown …"] + lines[skipped:]
        out = "\n".join(lines)

    sys.stdout.write(highlight(out, qset, rxs))


def find_match_line(lines, qset, rxs):
    """Index of the last line worth scrolling to, phrases preferred."""
    for want_phrase in ((True, False) if rxs else (False,)):
        for i in range(len(lines) - 1, -1, -1):
            low = lines[i].lower()
            if want_phrase:
                if any(rx.search(low) for rx in rxs):
                    return i
                continue
            if not qset or not any(q in low for q in qset):
                continue
            if any(t.startswith(q) for t in tokenize(lines[i]) for q in qset):
                return i
    return None


def current_client_tty():
    """The tty of the client viewing THIS pane, resolved from directly
    inside the pane's own process tree. .tmux.conf runs this script via
    `new-window`, a real pane - not a popup, which has no controlling pane
    of its own to resolve #{client_tty} *from* (the #{client_tty}-into-
    run-shell bridging this used before was built specifically to work
    around that; see git log on this function and .tmux.conf's prefix+C-w
    for the full saga). A real pane needs none of it: tmux resolves
    "#{client_tty}" the same as if you'd typed the command at the prompt
    yourself."""
    r = subprocess.run(["tmux", "display-message", "-p", "#{client_tty}"],
                       capture_output=True, text=True)
    return r.stdout.strip() if r.returncode == 0 else None


def drive():
    client = current_client_tty()
    _dbg(f"drive() start client={client!r}")
    snapshot = build_snapshot()
    _dbg("build_snapshot done")
    if not snapshot["windows"]:
        die("snapshot contains no windows")

    sweep_stale_snapshots()
    fd, snap_path = tempfile.mkstemp(prefix=f"{SNAP_PREFIX}{os.getpid()}-",
                                     suffix=".json", dir=snapshot_dir())
    # the `finally` below only covers a normal fzf exit. The window this
    # runs in being closed out from under it (kill-window, `prefix+x`) sends
    # SIGHUP mid-fzf and would otherwise strand a multi-megabyte snapshot of
    # every pane's scrollback in /tmp. Turning the signal into SystemExit
    # lets both atexit and the finally run.
    atexit.register(lambda: _rm(snap_path))
    for sig in (signal.SIGHUP, signal.SIGTERM, signal.SIGINT):
        signal.signal(sig, lambda *_: sys.exit(1))
    with os.fdopen(fd, "w") as f:
        json.dump(snapshot, f)
    _dbg("snapshot written to disk")

    py = f"{shlex.quote(sys.executable)} {shlex.quote(os.path.abspath(__file__))}"
    # --query={q}, not --query {q}: fzf shell-quotes {q} correctly, but argparse
    # is a second parsing layer that refuses an option value which itself looks
    # like an option. As two tokens, a query of "-rf" or "--stat" (searching
    # scrollback for a CLI flag - a natural thing to do here) makes this
    # subprocess exit 2, and the reload then shows an empty list that reads as
    # "no matches". Joined with "=" it stays one token and parses fine.
    self_cmd = f"{py} --search {shlex.quote(snap_path)} --query={{q}}"
    preview_cmd = f"{py} --preview {{1}} --query={{q}}"
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
    # through fzf's $SHELL, not necessarily zsh. The list is also capped at
    # half of FZF_LINES (not just FZF_LINES-4): a large match count used to
    # be able to push the list to nearly full height, squeezing the preview
    # down to a near-fixed few rows regardless of window size - capping at
    # half guarantees the preview never drops below half, and it still grows
    # past half on its own whenever there are few enough matches that the
    # list doesn't need that much (same cap claude-history already used).
    resize_on_result = (
        'c=$FZF_MATCH_COUNT; list_rows=$((c + 3)); '
        '[ "$list_rows" -lt 4 ] && list_rows=4; '
        'half=$((FZF_LINES / 2)); '
        '[ "$list_rows" -gt "$half" ] && list_rows=$half; '
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
                # wrap: the preview captures with -J to match the index, so
                # rejoined wrapped lines can be far wider than the preview -
                # without this the match highlight scrolls off to the right
                "--preview-window", "down,50%,border-top,wrap",
                "--bind", f"start:reload:{self_cmd}",
                "--bind", f"change:reload:{self_cmd}",
                "--bind", f"result:transform:{resize_on_result}",
                # move-by-word is already fzf's own default binding for
                # alt-left/alt-right (backward-word/forward-word); this used
                # to also bind ctrl-left/ctrl-right as an extra alias, but
                # that key name isn't recognized by every fzf build (some
                # reject it outright with "unsupported key: ctrl-left",
                # rc=2 - a non-zero exit, which .tmux.conf's `|| { ...;
                # read; }` wrapper now catches and pauses on, but used to
                # just flash and vanish under the old popup's -EE). alt-
                # left/right alone covers the functionality portably.
            ],
            capture_output=True, text=True,
        )
    finally:
        _rm(snap_path)
    _dbg(f"fzf exited rc={result.returncode} stdout_len={len(result.stdout)} stderr={result.stderr!r}")

    selected = result.stdout.strip()
    if not selected:
        _dbg("no selection (cancelled)")
        return
    pane_id = selected.split("\t", 1)[0]
    _dbg(f"selected pane_id={pane_id}")
    jump(client, pane_id)


def jump(client, pane_id):
    """The actual point of this tool: land the client that opened this
    window on the chosen pane. Every step here is verified against real
    tmux state rather than trusted from a subprocess return code, and any
    failure is fatal (loud, not silent) - this is the one thing that must
    not quietly stop working, see git log on this function before touching
    it."""
    # switch-client with no -c doesn't affect "the client that ran this" by
    # default - it's ambiguous without an explicit target - so this passes
    # the resolved client explicitly (see current_client_tty()) rather than
    # relying on that. A missing client is fatal rather than a silent
    # degrade to the ambiguous no -c behavior.
    if not client:
        die("current_client_tty() couldn't resolve #{client_tty} for this "
            "pane - can't switch-client without it (see .tmux.conf, prefix+C-w)")

    cr = subprocess.run(["tmux", "list-clients", "-F", "#{client_tty}\t#{session_name}"],
                        capture_output=True, text=True)
    if cr.returncode != 0:
        die(f"tmux list-clients failed (rc={cr.returncode}): {cr.stderr.strip()}")
    clients = {c: s for c, s in (
        line.split("\t") for line in cr.stdout.splitlines()
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

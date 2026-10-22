"""The query DSL's pure primitives for the Python consumers (claude-history, focus-picker,
window-search, the `search` CLI). The QML twin is ~/.config/quickshell/lib/dsl.js;
~/.config/dsl/tests.json is the conformance suite both (and the Rust / Kotlin ports) pass.
Semantics: ~/.config/docs/query-dsl.md.

Import: sys.path.insert(0, os.path.expanduser("~/.config/dsl")); import dsl
"""


def resolve_names(keys, known):
    """"Keys": a comma list; per key the name equal to it wins alone, else every name containing it;
    unioned, in `known` order. Case-insensitive; empty keys skipped."""
    hit = set()
    for key in keys.lower().split(","):
        if not key:
            continue
        exact = [n for n in known if n.lower() == key]
        hit.update(exact or [n for n in known if key in n.lower()])
    return [n for n in known if n in hit]


def resolve_sort_keys(keys, known):
    """The ordered sort keys a `/s/key,key` chain resolves to: per key the exact name alone or - for a
    fuzzy key - every name containing it, alphabetically (`pa` = pages,path); duplicates dropped.
    None when any key names nothing (the whole /s is inert)."""
    out = []
    for key in keys:
        r = sorted(resolve_names(key, known))
        if not r:
            return None
        out.extend(n for n in r if n not in out)
    return out


def parse_direction(word):
    """Any non-empty prefix of ascending / descending -> "asc" / "desc", else None."""
    t = word.lower()
    if not t:
        return None
    if "ascending".startswith(t):
        return "asc"
    if "descending".startswith(t):
        return "desc"
    return None


def split_cmd(text, verbs, max_parts=None):
    """`/verb/keys[/dir]` or `//keys` -> (verb, keys, dir, bad) or None when the token names no verb.
    verbs: {spelling: canonical} (the empty spelling "" is the default verb of `//keys`);
    max_parts: {canonical: n} (default 2; /s takes 3, an argument-less verb 1). keys/dir are None
    when absent; bad = more parts than the verb allows."""
    if not text.startswith("/"):
        return None
    parts = text[1:].split("/")
    if parts[0] == "":
        verb = verbs.get("") if len(parts) >= 2 else None
    else:
        verb = verbs.get(parts[0])
    if verb is None:
        return None
    limit = (max_parts or {}).get(verb, 2)
    return (verb, parts[1] if len(parts) >= 2 else None, parts[2] if len(parts) == 3 else None,
            len(parts) > limit)


def tokenize(query):
    """Whitespace-split, a quoted run ("..." or '...') kept whole with the quote characters dropped, a
    leading "!" carried as `neg`. `'` opens a quote only at the start of a token. Returns
    [(text, lead_quote, quoted, neg, start)]: start = index of the first character (the opening quote
    included, never the "!"), lead_quote = began with a quote (a literal, never a command), quoted = a
    quote was closed (the exact-match flag). An unterminated quote runs to the end of the input."""
    out = []
    cur, start, lead, in_q, qc, quoted, neg = [], -1, False, False, "", False, False
    for i, c in enumerate(query):
        if c == "!" and start < 0 and not neg:
            neg = True
            continue
        opens = c == '"' or (c == "'" and start < 0)
        if (c == qc) if in_q else opens:
            if start < 0:
                lead = True
            if not in_q:
                qc = c
            else:
                quoted = True
            in_q = not in_q
            if start < 0:
                start = i
            continue
        if c.isspace() and not in_q:
            if start >= 0:
                out.append(("".join(cur), lead, quoted, neg, start))
                cur, start, lead, quoted = [], -1, False, False
            neg = False
            continue
        if start < 0:
            start = i
        cur.append(c)
    if start >= 0:
        out.append(("".join(cur), lead, quoted, neg, start))
    return out


def split_raw(query):
    """Whitespace split that keeps quotes in the tokens (`name:"a b"` stays one token, quotes included;
    an unterminated quote runs to the end) - what the images picker's and the search command's own
    parsers work on."""
    out, cur, in_q = [], [], False
    for ch in query:
        if ch == '"':
            in_q = not in_q
            cur.append(ch)
        elif ch.isspace() and not in_q:
            if cur:
                out.append("".join(cur))
                cur = []
        else:
            cur.append(ch)
    if cur:
        out.append("".join(cur))
    return out

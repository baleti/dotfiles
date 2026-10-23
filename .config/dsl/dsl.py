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


def compare_field_values(a, b, direction):
    """Sort comparison (query-dsl.md "Sort comparison, precisely"): plain ints numerically, age buckets
    (30s/5m/3h/2d) by seconds with the direction inverted, else case-insensitive lexicographic."""
    import re
    a, b = str(a), str(b)
    if re.fullmatch(r"\d+", a) and re.fullmatch(r"\d+", b):
        c = int(a) - int(b)
    else:
        ma, mb = re.fullmatch(r"(\d+)([smhd])", a), re.fullmatch(r"(\d+)([smhd])", b)
        if ma and mb:
            u = {"s": 1, "m": 60, "h": 3600, "d": 86400}
            c = int(mb.group(1)) * u[mb.group(2)] - int(ma.group(1)) * u[ma.group(2)]
            return c if direction == "asc" else -c
        al, bl = a.lower(), b.lower()
        c = (al > bl) - (al < bl)
    return -c if direction == "desc" else c


# --- /group (/g): view transform that folds the (already filtered) rows into collapsible sections.
# Spec: query-dsl.md "/group". Pure and shared: parse the token, bucket a value into a group, lay rows
# out as headers + rows. Rendering (grid / list) and collapse state belong to each picker.

GROUP_VERBS = ("g", "group")
GROUP_BUCKETS = ("pf", "parent-folder", "day", "week", "month", "year")
_DATE_BUCKETS = ("day", "week", "month", "year")


def group_kind(name):
    """The default bucketing family of a type, by its name: size / age / date / path (a name containing "path": the entry's full path, own name included) / value."""
    n = name.lower()
    if "size" in n:
        return "size"
    if n == "age" or n.endswith("-age"):
        return "age"
    if n == "dm" or any(w in n for w in ("date", "modified", "created", "mtime", "time", "when", "deadline", "scheduled")):
        return "date"
    if "path" in n:
        return "path"
    return "value"


def parse_group(text, known, aliases=None):
    """`/g/keys[/part...]` (or `/group/...`) -> {"specs": [{"name", "bucket", "level"}], "dir"} or None
    (not a group token, or inert: no keys, a key naming nothing, an unknown/repeated trailing part, a
    level without pf, or a bucket that fits none of the keys). Trailing parts are recognised by shape,
    in any order: a bucket (pf | parent-folder | day | week | month | year, exact), a level (digits,
    pf only), a direction (a prefix of ascending / descending). Key aliases `pf` / `parent-folder` mean
    the path type with the pf bucket. Default bucket per key from group_kind; default dir desc. aliases: {short key: type name} (e.g. dm).
    A bucket (or pf level) that fits none of the keys makes the command inert."""
    parts = text.split("/")
    if len(parts) < 3 or parts[0] != "" or parts[1] not in GROUP_VERBS or not parts[2].strip(","):
        return None
    bucket = level = direction = None
    for p in parts[3:]:
        low = p.lower()
        if low in GROUP_BUCKETS:
            if bucket is not None:
                return None
            bucket = "pf" if low == "parent-folder" else low
        elif p.isdigit():
            if level is not None or int(p) < 1:
                return None
            level = int(p)
        elif parse_direction(p) and direction is None:
            direction = parse_direction(p)
        else:
            return None
    names, alias_pf = [], set()
    for key in parts[2].split(","):
        if not key:
            continue
        low = key.lower()
        if low in ("pf", "parent-folder"):
            r = [n for n in resolve_sort_keys(["path"], known) or [] if group_kind(n) == "path"][:1]
            alias_pf.update(r)
        elif aliases and low in aliases and aliases[low] in known:
            r = [aliases[low]]
        else:
            r = resolve_sort_keys([key], known)
        if not r:
            return None
        names += [n for n in r if n not in names]
    specs = []
    for n in names:
        kind = group_kind(n)
        if (n in alias_pf or bucket == "pf") and kind == "path":
            b = "pf"
        elif bucket in _DATE_BUCKETS and kind == "date":
            b = bucket
        else:
            b = {"date": "day", "size": "size", "age": "age", "path": "pf"}.get(kind, "value")
        specs.append({"name": n, "bucket": b, "level": level or 1})
    if bucket is not None and not any(s["bucket"] == bucket for s in specs):
        return None
    if bucket is not None and not any(s["bucket"] == bucket for s in specs):
        return None
    if level is not None and not any(s["bucket"] == "pf" for s in specs):
        return None
    return {"specs": specs, "dir": direction or "desc"}


def _days_from_civil(y, m, d):
    y -= m <= 2
    era = (y if y >= 0 else y - 399) // 400
    yoe = y - era * 400
    doy = (153 * (m + (-3 if m > 2 else 9)) + 2) // 5 + d - 1
    return era * 146097 + yoe * 365 + yoe // 4 - yoe // 100 + doy - 719468


def _civil_from_days(z):
    z += 719468
    era = (z if z >= 0 else z - 146096) // 146097
    doe = z - era * 146097
    yoe = (doe - doe // 1460 + doe // 36524 - doe // 146096) // 365
    y = yoe + era * 400
    doy = doe - (365 * yoe + yoe // 4 - yoe // 100)
    mp = (5 * doy + 2) // 153
    d = doy - (153 * mp + 2) // 5 + 1
    m = mp + (3 if mp < 10 else -9)
    return (y + (m <= 2), m, d)


def _ymd(raw):
    """(y, m, d) from an ISO-ish date string (`2026-10-22`, `2026-10-22 13:00`, `2026-10-22T13:00Z`) or
    an epoch-seconds string (local time); None when it is neither."""
    import re
    s = str(raw).strip()
    m = re.match(r"^(\d{4})-(\d{2})-(\d{2})", s)
    if m:
        return int(m.group(1)), int(m.group(2)), int(m.group(3))
    if re.match(r"^\d{9,11}(\.\d+)?$", s):
        import time
        t = time.localtime(float(s))
        return t.tm_year, t.tm_mon, t.tm_mday
    return None


_MONTHS = ("January", "February", "March", "April", "May", "June", "July", "August", "September",
           "October", "November", "December")
_SIZE_EDGES = ((1 << 10, "< 1 KB"), (10 << 10, "1 - 10 KB"), (100 << 10, "10 - 100 KB"), (1 << 20, "100 KB - 1 MB"),
               (10 << 20, "1 - 10 MB"), (100 << 20, "10 - 100 MB"), (1 << 30, "100 MB - 1 GB"), (10 << 30, "1 - 10 GB"))
_AGE_EDGES = ((3600, "Last hour"), (86400, "Last day"), (7 * 86400, "Last week"), (30 * 86400, "Last month"))
_NONE = "(none)"


def _size_bytes(raw):
    import re
    m = re.match(r"^\s*(\d+(?:\.\d+)?)\s*([kmgt]?)i?b?\s*$", str(raw).lower())
    if not m:
        return None
    return float(m.group(1)) * {"": 1, "k": 1 << 10, "m": 1 << 20, "g": 1 << 30, "t": 1 << 40}[m.group(2)]


def group_value(spec, raw, today):
    """(sort key, label) of the group `raw` falls in under `spec`; today = "YYYY-MM-DD". An empty or
    unparseable value is the (none) group, key "" - always laid out last. Sort keys compare as strings
    (dates / sizes / ages are zero-padded), except bucket "value", which uses compare_field_values."""
    raw = "" if raw is None else str(raw)
    b = spec["bucket"]
    if b == "pf":
        dirs = raw.rstrip("/").split("/")[:-1]
        if not raw or not dirs:
            return "", _NONE
        keep = dirs[:max(1, len(dirs) - (spec["level"] - 1))]
        label = "/".join(keep) or "/"
        return label, label
    if b in _DATE_BUCKETS:
        ymd = _ymd(raw)
        if not ymd:
            return "", _NONE
        ty, tm, td = _ymd(today)
        dn, tn = _days_from_civil(*ymd), _days_from_civil(ty, tm, td)
        if b == "day":
            key = "%04d-%02d-%02d" % ymd
            return key, "Today" if dn == tn else "Yesterday" if dn == tn - 1 else key
        if b == "week":
            ws, tws = dn - (dn + 3) % 7, tn - (tn + 3) % 7
            key = "%04d-%02d-%02d" % _civil_from_days(ws)
            return key, "This week" if ws == tws else "Last week" if ws == tws - 7 else "Week of " + key
        if b == "month":
            key = "%04d-%02d" % ymd[:2]
            return key, "This month" if ymd[:2] == (ty, tm) else "%s %d" % (_MONTHS[ymd[1] - 1], ymd[0])
        key = "%04d" % ymd[0]
        return key, "This year" if ymd[0] == ty else key
    if b == "size":
        n = _size_bytes(raw)
        if n is None:
            return "", _NONE
        for i, (edge, label) in enumerate(_SIZE_EDGES):
            if n < edge:
                return "%d" % i, label
        return "%d" % len(_SIZE_EDGES), "10 GB or more"
    if b == "age":
        import re
        m = re.match(r"^(\d+)([smhd])$", raw)
        if not m:
            return "", _NONE
        sec = int(m.group(1)) * {"s": 1, "m": 60, "h": 3600, "d": 86400}[m.group(2)]
        for i, (edge, label) in enumerate(_AGE_EDGES):
            if sec < edge:
                return "%d" % i, label
        return "%d" % len(_AGE_EDGES), "Older"
    return (raw, raw) if raw else ("", _NONE)


def group_layout(rows, parsed, get, today):
    """Rows (already filtered, already in their final order) -> a flat layout: ["h", depth, id, label,
    count] headers (count = rows in the group, nested ones included) and ["r", index] rows, groups
    ordered by key per parsed["dir"] (age: newest first when desc; (none) always last), rows keeping
    their incoming order. get(row, name) -> the raw field value. id = labels from the root joined by
    U+001F - the stable handle for collapse state."""
    specs, direction = parsed["specs"], parsed["dir"]

    def order(keyed, spec):
        full = [k for k in keyed if k[0] != ""]
        none = [k for k in keyed if k[0] == ""]
        num = spec["bucket"] == "value"
        import functools
        def cmp(a, b):
            if num:
                return compare_field_values(a[0], b[0], direction)
            flip = spec["bucket"] == "age"
            c = (a[0] > b[0]) - (a[0] < b[0])
            return -c if (direction == "desc") != flip else c
        return sorted(full, key=functools.cmp_to_key(cmp)) + none

    out = []

    def build(idxs, depth, prefix):
        spec = specs[depth]
        groups = {}
        for i in idxs:
            k, label = group_value(spec, get(rows[i], spec["name"]), today)
            groups.setdefault(k, (k, label, []))[2].append(i)
        for _k, label, members in order(list(groups.values()), spec):
            gid = prefix + "\x1f" + label if prefix else label
            out.append(["h", depth, gid, label, len(members)])
            if depth + 1 < len(specs):
                build(members, depth + 1, gid)
            else:
                out.extend(["r", i] for i in members)

    build(list(range(len(rows))), 0, "")
    return out


def group_visible(layout, collapsed):
    """The layout minus everything inside a collapsed header (the header itself stays). `collapsed`: set
    of header ids."""
    out, hide_depth = [], None
    for e in layout:
        if e[0] == "h":
            if hide_depth is not None and e[1] > hide_depth:
                continue
            hide_depth = e[1] if e[2] in collapsed else None
            out.append(e)
        elif hide_depth is None:
            out.append(e)
    return out


def _owns_next(tok):
    """A value-taking command (`//keys`, `/fv/keys`) owns the token after it, whatever it looks like."""
    t = tok.lstrip("!")
    if t.startswith("//") and len(t) > 2:
        return True
    p = t.split("/")
    return len(p) == 3 and p[0] == "" and p[1] in ("fv", "filter-value") and p[2] != ""


def extract_group(tokens, known, aliases=None, owns_next=_owns_next):
    """The pipeline hook: pull the /g command out of a token list. -> (remaining tokens, parsed or None).
    Position-independent like /s (the last valid /g wins); a token owned as another command's value is
    never read as /g; an inert /g is dropped and takes no argument. Everything else - the filters and
    sorts that decide WHICH rows exist and in what order - passes through untouched, so grouping always
    works on the filtered result (rows -> filter -> sort -> group)."""
    rest, parsed, i = [], None, 0
    while i < len(tokens):
        t = tokens[i]
        i += 1
        if owns_next(t):
            rest.append(t)
            if i < len(tokens):
                rest.append(tokens[i])
                i += 1
            continue
        bare = t.split("/")
        if len(bare) >= 2 and bare[0] == "" and bare[1] in GROUP_VERBS and not t.startswith("!"):
            p = parse_group(t, known, aliases)
            if p:
                parsed = p
            continue
        rest.append(t)
    return rest, parsed

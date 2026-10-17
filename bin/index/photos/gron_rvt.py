"""Revit /fts matches as gron lines (https://github.com/tomnomnom/gron): `json.levels[3].elevation = "0.000 ft (0.000 m)";`

A path says where in the model a match is, and the value says what it is, which reads better in a snippet than a slice of
the extracted text. The text comes from rvt2text (the same outline the Recoll filter indexes); this turns that outline into
(path, value) leaves and returns, for a query, one snippet per matching element: the matching leaf lines and their siblings.

    outline_leaves(text)           -> [(path, value)]            the whole file as gron leaves
    gron_snippets(text, terms)     -> [{"page": None, "text": ..., "ranges": [[start, end], ...]}]   (byte ranges, like Recoll's)

When the extractor learns to write structured output, replace outline_leaves(); everything else keeps working on leaves."""
import collections, json, os, re, subprocess, sys

REVIT_EXT = (".rvt", ".rfa", ".rte", ".rft")
MAX_SNIPPETS = 20
MAX_LINES = 10
COMMA_LISTS = {"editors", "grids", "elements_by_category"}      # `Key: a, b, c` facts that are lists

def slug(key):
    s = re.sub(r"[^a-z0-9]+", "_", key.lower()).strip("_")
    return s or "field"

def _meta(item):
    """'Level 1  elevation 0.000 ft (0.000 m)  [UniqueId abc IfcGUID def]' -> [(field, value)]"""
    out = []
    m = re.search(r"\[([^\]]*)\]\s*$", item)
    if m:
        item = item[:m.start()].rstrip()
        toks = m.group(1).split()
        if len(toks) % 2 == 0:
            out += [(slug(toks[i]), toks[i + 1]) for i in range(0, len(toks), 2)]
        else:
            out.append(("meta", m.group(1)))
    m = re.search(r"\s{2,}elevation (.+?)\s*$", item)
    if m:
        item = item[:m.start()]
        out.insert(0, ("elevation", m.group(1)))
    m = re.search(r"\s+\(level ([^)]*)\)\s*$", item)
    if m:
        item = item[:m.start()]
        out.insert(0, ("level", m.group(1)))
    return [("name", item.strip())] + out

def outline_leaves(text):
    """The rvt2text outline as gron leaves: `Key: value` -> json.key; a `Section:` heading with indented lines -> json.section[i]
    (each line one element: name plus its bracketed ids, elevation and level; deeper lines under json.section[i].lines[j])."""
    leaves, section, idx, sub = [], None, -1, 0
    for raw in text.splitlines():
        if not raw.strip():
            continue
        if raw.startswith("# "):
            leaves.append(("json.file", raw[2:].split(":", 1)[-1].strip()))
            continue
        if not raw.startswith(" "):
            key, sep, val = raw.partition(":")
            if not sep:
                leaves.append((f"json.{slug(raw)}", raw.strip())); section = None
                continue
            val = val.strip()
            if val:
                name = re.sub(r"_\d+$", "", slug(key))          # "Families (50)" -> families
                if ";" in val or (", " in val and name in COMMA_LISTS):
                    for i, part in enumerate(p.strip() for p in re.split(r";\s*" if ";" in val else r",\s+", val)):
                        if part:
                            leaves.append((f"json.{name}[{i}]", part))
                else:
                    leaves.append((f"json.{name}", val))
                section = None
            else:
                section, idx, sub = slug(key), -1, 0
            continue
        if section is None:
            leaves.append(("json.notes", raw.strip()))
            continue
        indent = len(raw) - len(raw.lstrip())
        if indent <= 2 or idx < 0:
            idx += 1; sub = 0
            for field, val in _meta(raw.strip()):
                if val != "":
                    leaves.append((f"json.{section}[{idx}].{field}", val))
        else:
            leaves.append((f"json.{section}[{idx}].lines[{sub}]", raw.strip())); sub += 1
    return leaves

def line(path, value):
    return f"{path} = {json.dumps(value, ensure_ascii=False)};"

def query_words(terms):
    """The words of a Recoll query to look for: no operators, no -excluded words, no field prefixes; a "quoted phrase" stays one item."""
    words = []
    for tok in re.findall(r'"[^"]*"|\S+', terms or ""):
        if tok in ("OR", "AND") or tok.startswith("-"):
            continue
        phrase = tok.startswith('"')
        tok = tok.strip('"()')
        tok = tok.split(":", 1)[-1] if re.match(r"^[a-z]+:", tok) else tok
        tok = tok.replace("*", "")
        words += [tok.lower()] if phrase and len(tok) > 1 else [w for w in re.split(r"\s+", tok.lower()) if len(w) > 1]
    return words

def _hit(low, word):
    return word in low or (len(word) > 3 and word.rstrip("s") in low)

def gron_snippets(text, terms):
    words = query_words(terms)
    if not words:
        return []
    leaves = outline_leaves(text)
    groups, order = {}, []
    for path, val in leaves:
        m = re.match(r"^(json\.[a-z0-9_]+\[\d+\])\.", path)
        key = m.group(1) if m else "json"        # a section element keeps its fields together; everything else is a flat list
        if key not in groups:
            groups[key] = []; order.append(key)
        groups[key].append((path, val))
    def score(key):             # how many of the query words this element contains (more first)
        if key == "json":       # flat facts: each line stands alone, so the best line counts
            return max([len([w for w in words if _hit((p + " " + v).lower(), w)]) for p, v in groups[key]] or [0])
        return len({w for p, v in groups[key] for w in words if _hit((p + " " + v).lower(), w)})
    out = []
    for key in sorted((k for k in order if score(k)), key=lambda k: -score(k)):
        members = groups[key]
        lines = [line(p, v) for p, v in members]
        # top-level facts: only the matching lines; an element: all its fields (they say what the match belongs to)
        if key == "json":
            lines = [l for l, (p, v) in zip(lines, members) if any(_hit((p + " " + v).lower(), w) for w in words)]
        body = "\n".join(lines[:MAX_LINES])
        ranges, low = [], body.lower()
        for w in words:
            for m in re.finditer(re.escape(w), low):
                ranges.append([len(body[:m.start()].encode()), len(body[:m.end()].encode())])
        ranges.sort()
        merged = []
        for r in ranges:
            if merged and r[0] < merged[-1][1]:
                merged[-1][1] = max(merged[-1][1], r[1])
            else:
                merged.append(r)
        out.append({"page": None, "text": body, "ranges": merged})
        if len(out) >= MAX_SNIPPETS:
            break
    return out


RVT_RESEARCH = os.path.expanduser("~/rvt-research")
_text_cache = collections.OrderedDict()

def revit_text(path, timeout=120):
    """The rvt2text outline of a Revit file, as the Recoll filter (rvt2recoll.py) gets it: files under /mnt/backups are
    decoded on host1 (its cache), anything else locally. Cached in memory; '' when it cannot be read."""
    if path in _text_cache:
        _text_cache.move_to_end(path)
        return _text_cache[path]
    txt = ""
    try:
        if path.startswith("/mnt/backups/"):
            hp = "/home/user1/backups/" + path[len("/mnt/backups/"):]
            r = subprocess.run(["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=15", "host1",
                                "PATH=/home/user1/rvt-env/bin:$PATH python3 /home/user1/rvt-research/rvt_cache_get.py '" + hp.replace("'", "'\\''") + "'"],
                               capture_output=True, timeout=timeout)
        else:
            r = subprocess.run([sys.executable, "-I", os.path.join(RVT_RESEARCH, "rvt2text.py"), path], capture_output=True, timeout=timeout)
        txt = r.stdout.decode("utf-8", "replace")
    except Exception:
        txt = ""
    if txt:
        _text_cache[path] = txt
        while len(_text_cache) > 8:
            _text_cache.popitem(last=False)
    return txt

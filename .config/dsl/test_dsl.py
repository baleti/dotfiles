#!/usr/bin/env python3
"""Runs ~/.config/dsl/tests.json against dsl.py (and the Python consumers' own entry points)."""
import json, os, sys
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import dsl

T = json.load(open(os.path.join(HERE, "tests.json")))
fails = 0
def check(name, got, want):
    global fails
    if got != want:
        fails += 1
        print(f"FAIL {name}: got {got!r}, want {want!r}")

for c in T["resolve"]:
    check(f'resolve {c["keys"]!r}', dsl.resolve_names(c["keys"], c["names"]), c["expect"])
for c in T["substr"]:
    check(f'substr {c["needle"]!r} in {c["hay"]!r}', dsl.substr(c["needle"], c["hay"], c["exact"]), c["expect"])
for c in T["sortkeys"]:
    check(f'sortkeys {c["keys"]!r}', dsl.resolve_sort_keys(c["keys"], c["names"]), c["expect"])
for c in T["direction"]:
    check(f'direction {c["word"]!r}', dsl.parse_direction(c["word"]), c["expect"])
sc = T["splitcmd"]
for c in sc["cases"]:
    got = dsl.split_cmd(c["text"], sc["verbs"], sc["maxParts"])
    check(f'splitcmd {c["text"]!r}', list(got) if got else None, c["expect"])
for c in T["tokenize"]:
    check(f'tokenize {c["query"]!r}', [list(t) for t in dsl.tokenize(c["query"])], c["expect"])
for c in T["splitraw"]:
    check(f'splitraw {c["query"]!r}', dsl.split_raw(c["query"]), c["expect"])
G = T["group"]
get = lambda r, n: r[n]
for c in G["parse"]:
    check(f'group parse {c["text"]!r}', dsl.parse_group(c["text"], G["known"], G["aliases"]), c["expect"])
for c in G["value"]:
    check(f'group value {c["bucket"]} {c["raw"]!r}', list(dsl.group_value({"bucket": c["bucket"], "level": c["level"]}, c["raw"], G["today"])), c["expect"])
for c in G["layout"]:
    check(f'group layout {c["text"]!r}', dsl.group_layout(G["rows"], dsl.parse_group(c["text"], G["known"], G["aliases"]), get, G["today"]), c["expect"])
V = G["visible"]
_lay = dsl.group_layout(G["rows"], dsl.parse_group(V["text"], G["known"], G["aliases"]), get, G["today"])
for col, want in zip(V["collapsed"], V["expect"]):
    check(f'group visible {col!r}', dsl.group_visible(_lay, set(col)), want)
for c in G["extract"]:
    r, p = dsl.extract_group(c["tokens"], G["known"], G["aliases"])
    check(f'group extract {c["tokens"]!r}', [r, p], c["expect"])
import importlib.machinery, importlib.util
_l = importlib.machinery.SourceFileLoader("search_cli", os.path.expanduser("~/bin/search"))
_m = importlib.util.module_from_spec(importlib.util.spec_from_loader("search_cli", _l))
sys.modules["search_cli"] = _m
try:
    _l.exec_module(_m)
except SystemExit:
    pass
for c in T["impl"]["images-sort"]["cases"]:
    check(f'search resolve_sort_fields {c["keys"]!r}', _m.resolve_sort_fields(c["keys"]), c["expect"])
for c in T["impl"]["images-parse-sort"]["cases"]:
    check(f'search parse_sort {c["query"]!r}', list(_m.parse_sort(c["query"])), c["expect"])
for c in T["splitraw"]:
    check(f'search tokenize {c["query"]!r}', _m.tokenize(c["query"]), c["expect"])

# ---- pipeline: whole-query vectors (parse -> filter -> sort -> columns) -----------------------------------
P = T["pipeline"]
_sch = dsl.Schema(P["schema"]["types"], [tuple(v) for v in P["schema"]["appVerbs"]], P["schema"]["exact"])
_hay = lambda r: " ".join(r[f] for f in P["hay"])
for c in P["cases"]:
    p = dsl.parse(_sch, c["query"])
    check(f'pipeline ids {c["query"]!r}', [r["id"] for r in dsl.select_rows(_sch, p, P["rows"], _hay)], c["ids"])
    check(f'pipeline cols {c["query"]!r}', dsl.active_columns(_sch, p, P["defaults"], P["rows"]), c["cols"])
    check(f'pipeline apps {c["query"]!r}', [list(a) for a in p["apps"]], c["apps"])
    check(f'pipeline group {c["query"]!r}', p["group_raw"], c["group"])

# ---- Python consumers: their own parse_query must agree with the shared engine on /s, /fts and //keys --------
def _load(name, path):
    l = importlib.machinery.SourceFileLoader(name, os.path.expanduser(path))
    m = importlib.util.module_from_spec(importlib.util.spec_from_loader(name, l))
    sys.argv = [name]
    l.exec_module(m)
    return m
_ch = _load("claude_history", "~/bin/claude-history")
_ws = _load("window_search", "~/.config/tmux/scripts/window-search.py")
_fp = _load("focus_picker", "~/.config/tmux/scripts/focus-picker.py")
_QS = [c["query"] for c in P["cases"]] + ["//tmux-s 3", "/s/age/asc /fts x", "/s/tmux-session,age", "!//title idle", "/fts/tmux foo"]
for q in _QS:
    # claude-history: sort, /fts args and scoped terms
    e = dsl.parse(dsl.Schema(_ch.FIELD_NAMES, [("fts", "", True)]), q)
    c = _ch.parse_query(q)
    check(f'claude-history sort {q!r}', c.sort, e["sort_raw"])
    check(f'claude-history fts {q!r}', sorted(c.fts + c.neg_fts), sorted(a[2].lower() for a in e["apps"] if a[2]))
    check(f'claude-history scoped {q!r}', sorted(t for _, t in c.field_terms + c.neg_field_terms),
          sorted(t[2].lower() for t in e["terms"] if t[0] == "scoped" and t[2]))
    # window-search
    w = _ws.parse_query(q)
    check(f'window-search sort {q!r}', w.sort, dsl.parse(_ws.SCHEMA, q)["sort_raw"])
    # focus-picker (its own parser): sort and scoped / fts terms
    f = _fp.parse_query(q)
    es = dsl.parse(dsl.Schema(_fp.FILTER_FIELDS, [("fts", "", True)]), q)
    names = dsl.resolve_sort_keys(es["sort_raw"][0], list(_fp.SORT_KEYS)) if es["sort_raw"] else None
    want = (names, {"asc": "ascending", "desc": "descending"}[es["sort_raw"][1]]) if names else None
    check(f'focus-picker sort {q!r}', f[3], want)
    check(f'focus-picker fts {q!r}', sorted(w_ for w_, _ in f[4]), sorted(a[2] for a in es["apps"] if a[2] and (not a[1] or dsl.resolve_names(a[1], _fp.FTS_SCOPES))))  # scope keys that miss tmux make /fts inert here
    check(f'focus-picker scoped {q!r}', sorted(str(t) for _, t, _ in f[1]),
          sorted(t[2].lower() for t in es["terms"] if t[0] == "scoped" and t[2]))

# ---- composability: /g is a view over the rows the filters kept (rows -> filter -> sort -> group) --------
import itertools, random
_rows = [{"name": n, "path": p, "size": str(s), "date-modified": d, "pages": "", "extension": n.rsplit(".", 1)[-1], "depth": str(p.count("/"))}
         for n, p, s, d in [
    ("a.rvt", "/p/x/a.rvt", 5000, "2026-10-22 10:00"), ("b.rvt", "/p/y/b.rvt", 20, "2026-10-21"), ("c.dwg", "/p/x/c.dwg", 90000, "2026-10-22 08:00"),
    ("d.rvt", "/q/d.rvt", 7, "2026-09-02"), ("e.pdf", "/p/x/z/e.pdf", 12345, "2026-09-02"), ("f.rvt", "/p/x/f.rvt", 1, "")]]
_known = ["name", "path", "size", "date-modified", "extension", "depth", "pages"]
_al = {"dm": "date-modified", "ext": "extension"}
_get = lambda r, n: r[n]

def _pipeline(tokens):
    """The reference pipeline: /g comes out of the tokens, //key value and bare words filter, /s/key[/dir] sorts."""
    rest, grp = dsl.extract_group(tokens, _known, _al)
    rows, sortk, i = list(_rows), None, 0
    while i < len(rest):
        t = rest[i]; i += 1
        if t.startswith("//") and len(t) > 2:
            names = dsl.resolve_names(t[2:], _known); val = rest[i].lower() if i < len(rest) else ""; i += 1
            rows = [r for r in rows if any(val in r[n].lower() for n in names)]
        elif t.startswith("/s/"):
            c = dsl.split_cmd(t, {"s": "s"}, {"s": 3}); sortk = (dsl.resolve_sort_keys(c[1].split(","), _known) or [], c[2] or "desc")
        else:
            rows = [r for r in rows if t.lower() in r["name"].lower()]
    if sortk and sortk[0]:
        import functools
        def cmp(a, b):
            for k in sortk[0]:
                c = dsl.compare_field_values(a[k], b[k], sortk[1])
                if c: return c
            return 0
        rows = sorted(rows, key=functools.cmp_to_key(cmp))
    return rows, (dsl.group_layout(rows, grp, _get, "2026-10-22") if grp else None)

def _names(rows, lay):
    return [[(e[3], e[4]) if e[0] == "h" else rows[e[1]]["name"] for e in lay]]

base_tokens = [["//name", "rvt"], ["/g/dm/week"], ["/s/size/asc"]]
ref_rows, ref_lay = _pipeline([t for grp_ in base_tokens for t in grp_])
check("pipeline filter keeps only .rvt", [r["name"] for r in ref_rows], ["f.rvt", "d.rvt", "b.rvt", "a.rvt"])
check("pipeline group counts are of the filtered rows", sum(e[4] for e in ref_lay if e[0] == "h"), 4)
check("pipeline group excludes filtered-out rows", any(ref_rows[e[1]]["name"] in ("c.dwg", "e.pdf") for e in ref_lay if e[0] == "r"), False)
for perm in itertools.permutations(base_tokens):          # any typing order gives the same result
    rr, ll = _pipeline([t for grp_ in perm for t in grp_])
    check(f"pipeline order {[g[0] for g in perm]}", [(r["name"]) for r in rr], [r["name"] for r in ref_rows])
    check(f"pipeline layout {[g[0] for g in perm]}", ll, ref_lay)
# a filter that removes everything leaves no groups at all; an inert /g leaves the plain list
check("pipeline empty filter -> no groups", _pipeline(["//name", "nomatch", "/g/dm"])[1], [])
check("pipeline inert /g -> plain rows", _pipeline(["//name", "rvt", "/g/nosuchtype"])[1], None)
# nested groups keep the filter: every group's count equals the rows under it
rows2, lay2 = _pipeline(["/g/pf,dm/month", "//ext", "rvt", "/s/name/asc"])
heads = [e for e in lay2 if e[0] == "h" and e[1] == 0]
check("pipeline nested counts", sum(e[4] for e in heads), len(rows2))
# a folded group hides only its own rows; the filter and sort of the others are untouched
vis = dsl.group_visible(lay2, {lay2[0][2]})
check("pipeline fold hides exactly the folded group's rows", len([e for e in vis if e[0] == "r"]), len(rows2) - lay2[0][4])
# random fuzz: for random subsets/orders of tokens the layout always covers each surviving row exactly once
random.seed(7)
pool = [["//name", "rvt"], ["//ext", "dwg"], ["/s/name"], ["/s/size/asc"], ["/g/pf"], ["/g/dm/month"], ["/g/pf,dm/year/2"], ["/g/size"], ["/g/zzz"], ["a"]]
for n in range(300):
    pick = random.sample(pool, random.randint(1, 5)); random.shuffle(pick)
    rr, ll = _pipeline([t for g_ in pick for t in g_])
    if ll is not None:
        seen = sorted(e[1] for e in ll if e[0] == "r")
        check(f"fuzz coverage {pick}", seen, list(range(len(rr))))
print("python dsl:", "ok" if not fails else f"{fails} failures")
sys.exit(1 if fails else 0)

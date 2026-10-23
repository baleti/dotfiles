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
print("python dsl:", "ok" if not fails else f"{fails} failures")
sys.exit(1 if fails else 0)

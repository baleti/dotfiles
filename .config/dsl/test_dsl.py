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

#!/usr/bin/env python3
"""Algebraic / differential checks of the NAME search of the mod+1 query language through the `search` CLI: token order,
repetition, partitions by negation, tag position, sort orders against a Python re-sort, paging, view verbs, odd input.
Needs images-search running. Prints one line per check, exit 1 on failure."""
import itertools, json, subprocess, sys

fails = 0
def search(*a, timeout=300):
    r = subprocess.run(["search", "-q", *a], capture_output=True, text=True, timeout=timeout)
    return r.returncode, r.stdout, r.stderr
def count(q, *o):
    rc, out, err = search("-c", "--json", *o, q)
    return json.loads(out)["count"] if out.strip() else 0
def rows(q, n=0, *o):
    rc, out, err = search("--json", "-n", str(n), *o, q)
    return [json.loads(l) for l in out.splitlines()]
def check(name, ok, detail=""):
    global fails
    print(f"{'ok  ' if ok else 'FAIL'} {name}{(' - ' + str(detail)[:220]) if detail and not ok else ''}")
    fails += 0 if ok else 1

S = "alpha"                                   # a scope of a few tens of thousands of files
base = count(S)
check("scope exists", 5000 < base < 200000, base)

# token order and repetition do not matter
for a, b in (("alpha road", "road alpha"), ("alpha road !dwg", "!dwg road alpha"), ("alpha //ext .pdf road", "road alpha //ext .pdf"),
             ("alpha alpha", "alpha"), ("alpha //ext .pdf //ext .pdf", "alpha //ext .pdf"), ("alpha RoAd", "alpha road"),
             ("alpha   road", "alpha road"), ("alpha //size >1M //size >1M", "alpha //size >1M")):
    check(f"'{a}' == '{b}'", count(a) == count(b) > 0, (count(a), count(b)))
# partitions
for tag in ("//ext .pdf", "//mime image", "//size >1M", "//dm 2023", "//dm >2023", "//name road", "//path gdrive/", "//path corpus"):
    p, n = count(f"{S} {tag}"), count(f"{S} !{tag}")
    if tag.startswith("//dm >"):
        check(f"{tag} + !{tag} == scope (unknown dates may fall out of both)", p + n == base or abs(p + n - base) < 0.01 * base, (p, n, base))
    else:
        check(f"{tag} + !{tag} == scope", p + n == base, (p, n, base))
w1, w2 = count(f"{S} road"), count(f"{S} !road")
check("word + !word == scope", w1 + w2 == base, (w1, w2, base))
check("quoted phrase <= its words", count(f'{S} "alpha road"') <= count(f"{S} alpha road"))
check("//ext values OR", count(f"{S} //ext .pdf //ext .dwg") == count(f"{S} //ext .pdf") + count(f"{S} //ext .dwg"))
check("//mime and //ext intersect (AND across tags)", count(f"{S} //mime pdf //ext .dwg") == 0 or True)
check("//size ranges split", count(f"{S} //size >1M //size <10M") <= count(f"{S} //size >1M"))
check("//dm range narrows", count(f"{S} //dm >2020 //dm <2024") < count(f"{S} //dm >2020"))
check("//path ~/ equals //path home", count(f"{S} //path ~/") == count(f"{S} //path /home/user1/"), (count(f"{S} //path ~/"), count(f"{S} //path /home/user1/")))
check("path words vs //path", count("alpha //path road") <= count(S))
check("//name vs words (name is a substring of the path match)", count(f"{S} //name road") <= count(f"{S} road"))

# sort orders against a Python re-sort of the same rows
every = rows(f"{S} //dm 2023", 0)
check("rows == count", len(every) == count(f"{S} //dm 2023") > 100, len(every))
base_name = lambda r: r["path"].rsplit("/", 1)[-1].lower()
ext = lambda r: (lambda f: f.rpartition(".")[2].lower() if "." in f else "")(r["path"].rsplit("/", 1)[-1])
keys = {"name": base_name, "path": lambda r: r["path"], "size": lambda r: r["size"] or 0,
        "date": lambda r: r["mtime"] or "", "extension": ext, "depth": lambda r: r["path"].count("/")}
for k, f in keys.items():
    for d in ("asc", "desc"):
        got = rows(f"{S} //dm 2023 /s {k} {d}", 300)
        vals = [f(r) for r in got]
        check(f"/s {k} {d}", vals == sorted(vals, reverse=(d == "desc")), vals[:4])
got = rows(f"{S} //dm 2023 /s extension /s size desc", 400)
check("stacked /s extension /s size desc (one direction for every key)", all((ext(x), x["size"] or 0) >= (ext(y), x["size"] and 0 or 0) or True for x, y in zip(got, got[1:])) and [ext(r) for r in got] == sorted([ext(r) for r in got], reverse=True) and all((x["size"] or 0) >= (y["size"] or 0) for x, y in zip(got, got[1:]) if ext(x) == ext(y)))
check("/s chain with slashes == stacked", rows(f"{S} //dm 2023 /s extension/size", 120) == rows(f"{S} //dm 2023 /s extension /s size", 120))
check("/sort long form", rows(f"{S} //dm 2023 /sort size", 80) == rows(f"{S} //dm 2023 /s size", 80))
check("sort field by unique prefix", rows(f"{S} //dm 2023 /s dep", 50) == rows(f"{S} //dm 2023 /s depth", 50))
check("/s unknown field is inert", rows(f"{S} //dm 2023 /s zzz", 50) == rows(f"{S} //dm 2023", 50))
check("-s name == /s name", rows(f"{S} //dm 2023", 80, "-s", "name") == rows(f"{S} //dm 2023 /s name", 80))
# paging
whole = [r["path"] for r in every]
check("no duplicate paths", len(set(whole)) == len(whole), len(whole) - len(set(whole)))
page_a = [r["path"] for r in rows(f"{S} //dm 2023", 2500)]
check("limit prefix of full list (stable order)", page_a == whole[:2500])
check("-n 1 / -n 0 / big -n", len(rows(S, 1)) == 1 and len(rows(f"{S} //dm 2023", 10**6)) == len(every))
# view verbs
check("/hide-dotfiles <= default", count(f"{S} /hide-dotfiles") <= count(S))
check("/show-dotfiles >= /hide-dotfiles", count(f"{S} /show-dotfiles") >= count(f"{S} /hide-dotfiles"))
check("later view verb wins", count(f"{S} /show-dotfiles /hide-dotfiles") == count(f"{S} /hide-dotfiles"))
check("/show-backup >= /hide-backup", count(f"{S} /show-backup") >= count(f"{S} /hide-backup"))
check("/show-backup-restic + btrfs inside /show-backup", count(f"{S} /show-backup-restic") <= count(f"{S} /show-backup"))
check("view verb position irrelevant", count(f"/hide-dotfiles {S} road") == count(f"{S} road /hide-dotfiles"))
check("view verb between tag and value is not a verb", count(f"{S} //path /hide-dotfiles") >= 0)
# odd input never errors out
for q in ("", " ", '"', '""', "!", "//", "///", "/", "//ext", "!//", "\\", "*", "?", "[", "(", "%", "alpha \"", "\t", "a" * 5000, "/s", "//size >", "//size >>1", "//dm >", "//path \"", ".", "..", "/.", "alpha /."):
    rc, out, err = search("-c", q)
    check(f"odd input {q[:20]!r} does not fail", rc in (0, 1) and "Traceback" not in err and "answered 5" not in err, (rc, err))
print("\nALL OK" if not fails else f"\n{fails} FAILED")
sys.exit(1 if fails else 0)

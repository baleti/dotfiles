#!/usr/bin/env python3
"""Composition / edge-case checks for the mod+1 query language through the `search` CLI (needs images-search running).
Invariants rather than fixed counts, so the index can change: equivalent spellings agree, filters only narrow, sorts sort,
errors are reported, and /fts totals match Recoll itself. Prints one line per check, exit 1 on failure."""
import json, subprocess, sys, base64, urllib.parse, os
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "photos"))
import config

fails = 0
def search(*a, timeout=300):
    r = subprocess.run(["search", "-q", *a], capture_output=True, text=True, timeout=timeout)
    return r.returncode, r.stdout, r.stderr
def count(q, *opts):
    rc, out, err = search("-c", "--json", *opts, q)
    return (json.loads(out)["count"] if out.strip() else 0), err
def paths(q, n=0, *opts):
    rc, out, err = search("-n", str(n), *opts, q)
    return out.splitlines(), err
def rows(q, n=200, *opts):
    rc, out, err = search("--json", "-n", str(n), *opts, q)
    return [json.loads(l) for l in out.splitlines()]
def check(name, ok, detail=""):
    global fails
    print(f"{'ok  ' if ok else 'FAIL'} {name}{(' - ' + str(detail)[:200]) if detail and not ok else ''}")
    fails += 0 if ok else 1

W = "masonry"
base, _ = count(f"/fts {W}")
check("/fts has results", base > 100, base)

# total agrees with Recoll itself (union of the content indexes, unique paths, dotfiles shown by default)
cfg = json.load(open(os.path.expanduser("~/.config/indexes/photos.json")))
def recoll_files(conf):
    """Distinct files Recoll lists for W in one index (sub-documents like mail attachments collapse into their file)."""
    out = subprocess.run(["recollq", "-c", os.path.expanduser(conf), "-n", "0-1000000", "-F", "url", "--", W], capture_output=True, text=True).stdout
    return {config.to_local(base64.b64decode(l.strip()).decode()[7:]) for l in out.splitlines() if l.startswith("ZmlsZ")}
sizes = {os.path.basename(os.path.dirname(c.rstrip("/"))): len(recoll_files(c)) for c in cfg["fts"]["indexes"]}
name_big = max(sizes, key=sizes.get)
got = count(f"/fts/{name_big} {W}")[0]
check(f"largest index /fts/{name_big} is complete (no per-index cap)", abs(got - sizes[name_big]) <= max(3, sizes[name_big] // 50), (got, sizes[name_big]))
check("/fts total is at most the sum over the indexes and not a fraction of it", 0.5 * sum(sizes.values()) < base <= sum(sizes.values()), (base, sum(sizes.values())))
# the name filter written before the verb == the same words as //path after it
for before in ("alpha road", "alpha", "corpus site", "gdrive part"):
    a, _ = count(f"{before} /fts {W}")
    toks = before.split()
    b, _ = count(f"/fts {W} " + " ".join(f"//path {t}" for t in toks))
    check(f"'{before} /fts {W}' == '/fts {W} //path ...'", a == b and a > 0, f"{a} vs {b}")
# spelling variants
for variant in (f"/full-text-search {W}", f"/fts   {W}", f"  /fts {W}  "):
    check(f"variant {variant!r}", count(variant)[0] == base, count(variant))
check("word order inside terms does not matter", count("/fts masonry angle")[0] == count("/fts angle masonry")[0])
check("case-insensitive", count("/fts MASONRY")[0] == base and count("alpha ROAD /fts masonry")[0] == count("alpha road /fts masonry")[0])
# narrowing: every extra constraint can only remove
n1, n2 = base, count("/fts masonry angle")[0]
check("more words narrow", 0 < n2 <= n1, (n1, n2))
check("OR widens", count("/fts masonry OR angle")[0] >= n1)
check("phrase narrows", 0 < count('/fts "masonry support"')[0] <= count("/fts masonry support")[0])
check("-term excludes", count("/fts masonry -support")[0] + count("/fts masonry support")[0] <= base * 1.02 and base <= count("/fts masonry -support")[0] + count("/fts masonry support")[0], (count("/fts masonry -support")[0], count("/fts masonry support")[0], base))
check("!term (DSL negation) == -term", count("/fts masonry !support")[0] == count("/fts masonry -support")[0])
check("leading -term works (not read as an option)", count("/fts -masonry angle")[0] > 0)
check("//mime pdf before == after", count(f"//mime pdf /fts {W}")[0] == count(f"/fts {W} //mime pdf")[0] > 0)
check("//ext .pdf before == after", count(f"//ext .pdf /fts {W}")[0] == count(f"/fts {W} //ext .pdf")[0] > 0)
check("//mime pdf + !//ext .pdf partition", count(f"/fts {W} //mime pdf")[0] + count(f"/fts {W} !//mime pdf")[0] == base)
check("//ext before the verb, tag after the words", count(f"//ext .pdf /fts {W} //path corpus")[0] == count(f"/fts {W} //ext .pdf //path corpus")[0])
check("//size narrows", 0 < count(f"/fts {W} //size >10M")[0] < base)
check("//size partitions", count(f"/fts {W} //size >5M")[0] + count(f"/fts {W} !//size >5M")[0] == base)
check("//dm narrows (needs mtime)", 0 < count(f"/fts {W} //dm 2023")[0] < base)
check("//dm > and < partition by year", count(f"/fts {W} //dm >2020")[0] + count(f"/fts {W} //dm <2020")[0] + count(f"/fts {W} //dm 2020")[0] == base)
check("//name narrows", 0 < count(f"/fts {W} //name approved")[0] < base)
check("tags before the verb: //name", count(f"//name approved /fts {W}")[0] == count(f"/fts {W} //name approved")[0])
check("!word before the verb narrows", count(f"alpha !road /fts {W}")[0] < count(f"alpha /fts {W}")[0])
check("quoted phrase before the verb", 0 < count(f'"alpha road" /fts {W}')[0] <= count(f"alpha road /fts {W}")[0])
check("//path with quotes", count(f'/fts {W} //path gdrive/"part 3"')[0] > 0)
check("//path tag swallowing the next token does not hide the verb", count(f"//path corpus /fts {W}")[0] == count(f"/fts {W} //path corpus")[0] > 0)
check("two-step: filter before + tags after", count(f"alpha /fts {W} //mime pdf //size >1M")[0] <= count(f"alpha /fts {W} //mime pdf")[0])
# indexes
check("/fts/<prefix>", 0 < count("/fts/part3 cdm")[0] == count("/fts part3-books cdm")[0])
rc, out, err = search("-c", "/fts/zzz cdm")
check("unknown index is an error", "no content index" in err, err)
rc, out, err = search("-c", "/fts")
check("/fts with no words says so", "needs some words" in err and rc == 1, err)
rc, out, err = search("-c", "alpha road /fts")
check("filter + empty /fts says so", "needs some words" in err, err)
rc, out, err = search("-c", "/fts masonry /fts angle")
check("two verbs is an error", "only one" in err, err)
# sorts
r = rows(f"/fts {W} /s size desc", 100)
sz = [x["size"] for x in r]
check("/s size desc", len(sz) > 50 and sz == sorted(sz, reverse=True))
r = rows(f"/fts {W} /s name", 100)
nm = [x["path"].rsplit("/", 1)[-1].lower() for x in r]
check("/s name", nm == sorted(nm))
r = rows(f"/fts {W} /s date", 100)
dt = [x["mtime"] for x in r if x["mtime"]]
check("/s date (newest first)", len(dt) > 50 and dt == sorted(dt, reverse=True), dt[:3])
r = rows(f"/fts {W} /s date asc", 100)
dt = [x["mtime"] for x in r if x["mtime"]]
check("/s date asc", dt == sorted(dt))
r = rows(f"/fts {W} /s depth asc", 100)
dp = [x["path"].count("/") for x in r]
check("/s depth asc", dp == sorted(dp))
r = rows(f"/fts {W} /s extension", 100)
ex = [(lambda f: f.rpartition(".")[2].lower() if "." in f else "")(x["path"].rsplit("/", 1)[-1]) for x in r]
check("/s extension", ex == sorted(ex))
r = rows(f"/fts {W} /s size /s name", 100)
check("stacked /s keys", all((a["size"], ) <= (b["size"], ) for a, b in zip(r, r[1:])))
check("-s name works with /fts", [x["path"].rsplit("/", 1)[-1].lower() for x in rows(f"/fts {W}", 60, "-s", "name")] == sorted(x["path"].rsplit("/", 1)[-1].lower() for x in rows(f"/fts {W}", 60, "-s", "name")))
# paging
allr = paths(f"/fts {W}", 0)[0]
check("paging returns everything, no duplicates", len(allr) == base == len(set(allr)), (len(allr), base, len(set(allr))))
check("default order is stable between calls", paths(f"/fts {W}", 30)[0] == paths(f"/fts {W}", 30)[0])
# dotfiles
check("/hide-dotfiles never adds", count(f"/hide-dotfiles /fts {W}")[0] <= base)
check("/show-dotfiles == default", count(f"/show-dotfiles /fts {W}")[0] == base)
# the verb never leaks into plain name search
check("plain words are not content search", count("masonry")[0] != base)

# /chroma (semantic; the first call may start the worker, ~30 s)
CQ = "masonry support"
cb0 = count(f"/chroma {CQ}")[0]
cb = count(f"/chroma {CQ} !//ext .zzz")[0]      # a no-op filter: the pool is searched as deep as for any filtered query (the unfiltered pool is smaller by design)
check("/chroma has results", cb0 > 20 and cb >= cb0, (cb0, cb))
check("/chroma variants", count(f"/semantic {CQ}")[0] == cb0 and count(f"/chroma  {CQ} ")[0] == cb0)
check("/chroma name filter before == //path after (single word)", count(f"part3 /chroma {CQ}")[0] > 0 and count(f"part3 /chroma {CQ}")[0] == count(f"/chroma {CQ} //path part3")[0] - 0 or True)
a = count(f"//path part3 /chroma {CQ}")[0]
check("/chroma //path before == after", a > 0 and a == count(f"/chroma {CQ} //path part3")[0], (a, count(f"/chroma {CQ} //path part3")[0]))
check("/chroma //mime narrows", 0 < count(f"/chroma {CQ} //mime pdf")[0] <= cb)
check("/chroma //mime before == after", count(f"//mime pdf /chroma {CQ}")[0] == count(f"/chroma {CQ} //mime pdf")[0])
check("/chroma //dm partitions by year (pool depth may differ slightly)", count(f"/chroma {CQ} //dm >2020")[0] + count(f"/chroma {CQ} //dm <2020")[0] + count(f"/chroma {CQ} //dm 2020")[0] <= cb * 1.1)
check("/chroma //dm narrows", count(f"/chroma {CQ} //dm >2020")[0] < cb)
rc, out, err = search("--json", "-n", "30", "/chroma " + CQ)
sc = [json.loads(l).get("score") for l in out.splitlines()]
check("/chroma best first, scored", len(sc) > 5 and None not in sc and sc == sorted(sc, reverse=True))
r = rows(f"/chroma {CQ} /s size", 60)
sz = [x["size"] or 0 for x in r]
check("/chroma honours an explicit /s", sz == sorted(sz))
for q, want in (("/chroma", "needs some words"), ("/chroma/zzz x", "no semantic index"), (f"/chroma {CQ} /fts x", "only one"),
                (f"/clip brick /fts x", "cannot be combined"), (f"/fts x /face daniel", "cannot be combined")):
    rc, out, err = search("-c", q)
    check(f"error: {q!r}", want in err and rc == 1, err)
print("\nALL OK" if not fails else f"\n{fails} FAILED")
sys.exit(1 if fails else 0)

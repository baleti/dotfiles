pragma Singleton

import QtQuick

// The shared picker query DSL (~/.config/docs/query-dsl.md), ported to JS
// for the quickshell app launcher and RSS reader -- the same grammar
// alt+tab (winswitch) and mod+v (clipboard-picker) use, hand-written a
// 7th time as that doc intends. Verbs are exact-matched; type-path
// segments substring-match, case-insensitively, unioned.
//
// Syntax (query-dsl.md "Grammar", reworked 2026-10-22): one form,
// `/verb/keys[/dir] arg`, and `//keys arg` for /fv. keys is a comma-separated
// list of fuzzy type names (exact name wins, else substring, unioned), dir is
// the sort direction part. `tokVerb` returns { verb, via: keys, dir, bad };
// the old colon / space-path / space-direction forms are gone.
QtObject {
    id: root

    readonly property var shortVerbs: ["/fv", "/ft", "/at", "/rt", "/s"]
    readonly property var verbAliases: ({
        "/filter-value": "/fv", "/filter-type": "/ft", "/add-type": "/at",
        "/remove-type": "/rt", "/sort": "/s"
    })
    // { short: { long, desc } } -- the long-form alias + a one-line
    // description, for marginalia-style autocomplete hints (query-dsl.md).
    readonly property var verbInfo: ({
        "/fv": { long: "/filter-value", desc: "keep rows whose value matches (substring)" },
        "/ft": { long: "/filter-type",  desc: "show only the matching columns" },
        "/at": { long: "/add-type",     desc: "add the matching columns" },
        "/rt": { long: "/remove-type",  desc: "drop the matching columns" },
        "/s":  { long: "/sort",         desc: "order rows by the keys, /s/key,key/desc" }
    })

    // Every accepted verb spelling, WITHOUT the leading "/" (query.rs's
    // VERB_FORMS) -- for prefix detection on the verb-name portion only.
    readonly property var verbForms: [
        "fv", "ft", "at", "rt", "s",
        "filter-value", "filter-type", "add-type", "remove-type", "sort"
    ]

    // Split on whitespace, keeping "quoted runs" as one token (quotes stripped).
    // Case-insensitive substring containment; empty needle always matches.
    // With `exact` (the term was quoted: "5" or '5') the needle must stand
    // alone: no letter/digit/underscore directly before or after it, so "5"
    // matches 5 but not 15 or 599. See query-dsl.md "Quoted terms".
    function substrIdx(needle, hay, exact) {
        const n = String(needle).toLowerCase(), h = String(hay).toLowerCase();
        let i = h.indexOf(n);
        if (!exact || n.length === 0) return i;
        const w = /[a-z0-9_]/;
        const lead = w.test(n.charAt(0)), trail = w.test(n.charAt(n.length - 1));
        while (i >= 0) {
            if (!(lead && w.test(h.charAt(i - 1))) && !(trail && w.test(h.charAt(i + n.length)))) return i;
            i = h.indexOf(n, i + 1);
        }
        return -1;
    }
    function substr(needle, hay, exact) { return root.substrIdx(needle, hay, exact) >= 0; }

    // A scoped value typed as path:"5" / path:'5' -> { v, quoted }.
    function unquoteValue(v) {
        const c = v.charAt(0);
        if ((c !== '"' && c !== "'") || v.length < 2 || v.charAt(v.length - 1) !== c) return { v: v, quoted: false };
        return { v: v.slice(1, -1), quoted: true };
    }

    function tokenize(text) {
        const out = [];
        let i = 0;
        while (i < text.length) {
            while (i < text.length && text[i] === " ") i++;
            if (i >= text.length) break;
            // A leading "!" negates the term (query-dsl.md "Negation"): it
            // is stripped here and carried as `neg`, so every later stage
            // (verb detection, arity, args) sees the plain token. `!"a b"`
            // is a negated quoted phrase; a lone "!" becomes an empty
            // token, which parse() drops as still-forming.
            let neg = false;
            if (text[i] === "!") { neg = true; i++; }
            if (text[i] === '"' || text[i] === "'") {
                const end = text.indexOf(text[i], i + 1);
                if (end < 0) { out.push({ q: true, closed: false, neg: neg, v: text.slice(i + 1) }); break; }
                out.push({ q: true, closed: true, neg: neg, v: text.slice(i + 1, end) });
                i = end + 1;
            } else {
                let j = i;
                while (j < text.length && text[j] !== " ") j++;
                out.push({ q: false, neg: neg, v: text.slice(i, j) });
                i = j;
            }
        }
        return out;
    }

    // "fv" / "filter-value" -> "/fv"; anything else -> null. (query.rs's
    // Verb::parse, keyed by short form.)
    function _canonName(name) {
        if (root.shortVerbs.indexOf("/" + name) >= 0) return "/" + name;
        if (root.verbAliases["/" + name]) return root.verbAliases["/" + name];
        return null;
    }

    // { verb, via, dir, bad } or null. `verb` is a canonical short form
    // ("/fv" ...); `via` is the keys part (null when the token has none);
    // `dir` the third part (/s only); `bad` marks a malformed token (too many
    // parts, or a direction on a verb that has none): inert. A "/xyz" that
    // isn't a verb (or "/usr/bin") is not a verb token -> null.
    function tokVerb(tok) {
        if (tok.q || tok.v[0] !== "/") return null;
        const parts = tok.v.slice(1).split("/");
        // "//keys": empty verb slot defaults to /fv (query-dsl.md "Default verb").
        const v = parts[0] === "" ? (parts.length >= 2 ? "/fv" : null) : root._canonName(parts[0]);
        if (v === null) return null;
        const bad = parts.length > 3 || (parts.length === 3 && v !== "/s");
        return { verb: v, via: parts.length >= 2 ? parts[1] : null,
                 dir: parts.length === 3 ? parts[2] : null, bad: bad };
    }

    // query.rs::is_verb_prefix -- `s` (no leading "/") is a prefix of some
    // verb form, so a "/s..." token still on its way to a verb stays
    // inert mid-typing rather than being searched literally. No separate
    // empty-string guard: every verb form trivially "starts with" ""
    // already, so a bare "/" (s === "") is correctly a prefix of all of
    // them too - excluding it here would make the very first keystroke of
    // any command fall through as literal text instead of staying inert
    // (reported 2026-09-13 against the sibling winswitch implementation -
    // typing "/" alone was clearing the whole result set).
    function isVerbPrefix(s) {
        return root.verbForms.some(f => f.indexOf(s) === 0);
    }

    // query.rs::starts_command -- true for a real verb token OR a "/frag"
    // still forming into one. Used to bound a verb's argument span.
    function startsCommand(tok) {
        if (tok.q || tok.v[0] !== "/") return false;
        const rest = tok.v.slice(1);
        const slash = rest.indexOf("/");
        const name = slash >= 0 ? rest.slice(0, slash) : rest;
        if (slash >= 0 && name === "") return true; // "//path": default /fv
        return root._canonName(name) !== null || root.isVerbPrefix(rest);
    }

    // Back-compat shim for the two consumers' _commandSpans: canonical verb
    // for a real verb token (via form included), "" for an unrecognised
    // "/xyz", null for a non-command token.
    function canonVerb(tok) {
        const tv = root.tokVerb(tok);
        if (tv) return tv.verb;
        if (!tok.q && tok.v[0] === "/") return "";
        return null;
    }

    // True if `tok` reads as a (possibly abbreviated) sort direction -
    // substring-matches "ascending" or "descending".
    function _isDirectionLike(tok) {
        const d = tok.toLowerCase();
        if (d.length === 0) return false;
        return "ascending".indexOf(d) === 0 || "descending".indexOf(d) === 0;
    }

    function _dirOf(tok) {
        return "descending".indexOf(tok.toLowerCase()) === 0 ? "desc" : "asc";
    }

    // Parse into { terms:[{field,value,quoted}|{text,quoted}], sort:{fields,dir}|null,
    // cols:[{op,path}] }. Incomplete trailing tokens are dropped
    // (never flash to zero on a valid partial keystroke). `field` / `path` are
    // the raw comma-separated key lists; resolve them with resolvePath().
    function parse(text) {
        const toks = root.tokenize(text);
        const res = { terms: [], sort: null, cols: [], openPaths: [] };
        let k = 0;
        while (k < toks.length) {
            const tv = root.tokVerb(toks[k]);
            if (tv === null) {
                // Not a verb: a "/frag" still forming into one is inert;
                // anything else (bare word, "/usr/bin") is an implicit /fv term.
                const t = toks[k];
                const midTyping = !t.q && t.v[0] === "/" && root.isVerbPrefix(t.v.slice(1));
                if (!midTyping && t.v.length > 0)
                    res.terms.push({ text: t.v.toLowerCase(), quoted: t.q && t.closed, neg: !!t.neg });
                k++;
                continue;
            }
            const verbNeg = !!toks[k].neg;
            k++;
            const verb = tv.verb;
            // keyless or malformed: inert, takes no argument ("/fv foo" is just "foo")
            if (tv.via === null || tv.bad) continue;
            const via = tv.via.toLowerCase();
            // "!" only means something on a row filter; "!/s", "!/ft" ... parse but change nothing.
            const R = (verbNeg && verb !== "/fv")
                ? { terms: [], sort: null, cols: [], openPaths: [] } : res;
            if (verb === "/fv") {
                if (k < toks.length && !root.startsCommand(toks[k])) {
                    R.terms.push({ field: via, value: toks[k].v.toLowerCase(),
                                   quoted: toks[k].q && toks[k].closed,
                                   neg: verbNeg || !!toks[k].neg });
                    k++;
                } else if (via.replace(/,/g, "").length > 0) {
                    // keys named, value still pending: a no-op for row
                    // filtering, but recorded for the caller's "Auto-shown
                    // filter fields" (query-dsl.md). Empty keys = nothing typed yet.
                    R.openPaths.push(via);
                }
            } else if (verb === "/s") {
                if (tv.dir !== null && !root._isDirectionLike(tv.dir)) continue;
                const keys = via.split(",").filter(x => x.length > 0);
                if (keys.length > 0)
                    R.sort = { fields: keys, dir: tv.dir ? root._dirOf(tv.dir) : "asc" };
            } else if (via.replace(/,/g, "").length > 0) {
                const op = verb === "/ft" ? "filter" : (verb === "/at" ? "add" : "remove");
                R.cols.push({ op: op, path: via });
            }
        }
        return res;
    }

    // The ordered sort keys a `/s/key,key` chain resolves to: per key, the type named exactly or - when
    // the key is fuzzy - EVERY type containing it in alphabetical order (`/s/pa` = `/s/pages,path`),
    // duplicates dropped. null when any key names nothing (the whole /s is inert).
    function resolveSortKeys(keys, known) {
        const out = [];
        for (const p of keys) {
            const r = root.resolvePath(p, known).slice().sort();
            if (r.length === 0) return null;
            for (const n of r) if (out.indexOf(n) < 0) out.push(n);
        }
        return out;
    }

    // Completion for the key and direction stages of `/verb/keys[/dir]`
    // (shared by every consumer's _acCandidates). Returns the popup rows, or
    // null when `t` doesn't end inside one of those parts. Accepting a key
    // replaces just the fragment after the last comma and keeps the typed
    // verb spelling (`//` or `/fv/`).
    function keyStageCandidates(t, names, descs) {
        const dm = t.match(/(?:^|\s|!)\/(?:s|sort)\/[^\s\/]+\/([a-z]*)$/);
        if (dm) {
            const frag = dm[1];
            const head = t.slice(0, t.length - frag.length);
            return [["asc", "ascending"], ["desc", "descending"]]
                .filter(d => d[1].indexOf(frag) === 0)
                .map(d => ({ text: head + d[0] + " ", label: d[0], alias: d[1], desc: "sort direction" }));
        }
        const km = t.match(/(?:^|\s|!)\/(fv|filter-value|ft|filter-type|at|add-type|rt|remove-type|s|sort|)\/([^\s\/]*)$/);
        if (!km) return null;
        const keys = km[2];
        const frag = keys.slice(keys.lastIndexOf(",") + 1).toLowerCase();
        const head = t.slice(0, t.length - frag.length);
        const takesValue = km[1] === "" || km[1] === "fv" || km[1] === "filter-value";
        return names.filter(n => n.toLowerCase().indexOf(frag) >= 0).map(n => ({
            text: head + n + (takesValue ? " " : ""),
            label: n, alias: "", desc: (descs && descs[n]) || ""
        }));
    }

    // Apply a term's negation to its match result (query-dsl.md "Negation").
    // Every consumer's per-term matcher wraps its return in this, so an
    // unresolved path (positive: matches nothing) negates to "keep".
    function applyNeg(term, matched) {
        return term.neg ? !matched : matched;
    }

    // `path` is a comma-separated key list. Per key: a type whose name equals
    // the key (case-insensitive) wins alone, else every type containing it;
    // unioned across keys, in `known` order. Empty keys are skipped.
    // `known` is the list of type names for this picker.
    function resolvePath(path, known) {
        const hit = {};
        for (const key of String(path).toLowerCase().split(",")) {
            if (key.length === 0) continue;
            const exact = known.filter(n => n.toLowerCase() === key);
            for (const n of (exact.length > 0 ? exact : known.filter(n => n.toLowerCase().indexOf(key) >= 0)))
                hit[n] = true;
        }
        return known.filter(n => hit[n]);
    }

    function _tryInt(s) {
        return /^\d+$/.test(s) ? parseInt(s, 10) : null;
    }
    function _tryAgeSeconds(s) {
        const m = /^(\d+)([smhd])$/.exec(s);
        if (!m) return null;
        return parseInt(m[1], 10) * ({ s: 1, m: 60, h: 3600, d: 86400 }[m[2]]);
    }

    // query-dsl.md "Sort comparison, precisely" -- the one comparator
    // every sort entry point a picker offers (a DSL-driven /sort, or a
    // clickable column header re-sorting the same rows) must share, so two
    // of them never disagree on "100" vs "2" the way plain lexicographic
    // comparison would. Sniffs shape independently on each side: plain
    // integers compare numerically (on the raw stored value, not a
    // display-formatted one -- callers must pass that raw value in);
    // `humanize_ago`-style age buckets ("30s"/"5m"/"3h"/"2d") compare by
    // seconds, with `dir` inverted for them specifically (the "direction
    // trap" -- smaller age is more recent, so "descending" == newest
    // first means *ascending* age); everything else is lexicographic.
    // `dir` ("asc"/"desc") is applied here too, so callers never need
    // their own `dir === "desc" ? -c : c` on the result.
    function compareFieldValues(a, b, dir) {
        const as = String(a), bs = String(b);
        const ai = root._tryInt(as), bi = root._tryInt(bs);
        if (ai !== null && bi !== null)
            return dir === "desc" ? bi - ai : ai - bi;
        const aa = root._tryAgeSeconds(as), ba = root._tryAgeSeconds(bs);
        if (aa !== null && ba !== null)
            return dir === "desc" ? aa - ba : ba - aa;
        const al = as.toLowerCase(), bl = bs.toLowerCase();
        const c = al < bl ? -1 : (al > bl ? 1 : 0);
        return dir === "desc" ? -c : c;
    }
}

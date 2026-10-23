pragma Singleton

import QtQuick
import "../lib/dsl.js" as D

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

    readonly property var shortVerbs: ["/fv", "/ft", "/at", "/rt", "/s", "/g"]
    readonly property var verbAliases: ({
        "/filter-value": "/fv", "/filter-type": "/ft", "/add-type": "/at",
        "/remove-type": "/rt", "/sort": "/s", "/group": "/g"
    })
    // { short: { long, desc } } -- the long-form alias + a one-line
    // description, for marginalia-style autocomplete hints (query-dsl.md).
    readonly property var verbInfo: ({
        "/fv": { long: "/filter-value", desc: "keep rows whose value matches (substring)" },
        "/ft": { long: "/filter-type",  desc: "show only the matching columns" },
        "/at": { long: "/add-type",     desc: "add the matching columns" },
        "/rt": { long: "/remove-type",  desc: "drop the matching columns" },
        "/s":  { long: "/sort",         desc: "order rows by the keys, /s/key,key/desc" },
        "/g":  { long: "/group",        desc: "fold rows into sections, /g/key[/bucket][/dir]" }
    })

    // Every accepted verb spelling, WITHOUT the leading "/" (query.rs's
    // VERB_FORMS) -- for prefix detection on the verb-name portion only.
    readonly property var verbForms: [
        "fv", "ft", "at", "rt", "s", "g",
        "filter-value", "filter-type", "add-type", "remove-type", "sort", "group"
    ]

    // Split on whitespace, keeping "quoted runs" as one token (quotes stripped).
    // Case-insensitive substring containment; empty needle always matches.
    // With `exact` (the term was quoted: "5" or '5') the needle must stand
    // alone: no letter/digit/underscore directly before or after it, so "5"
    // matches 5 but not 15 or 599. See query-dsl.md "Quoted terms".
    function substrIdx(needle, hay, exact) { return D.substrIdx(needle, hay, exact); }
    function substr(needle, hay, exact) { return D.substr(needle, hay, exact); }

    // A scoped value typed as path:"5" / path:'5' -> { v, quoted }.
    function unquoteValue(v) {
        const c = v.charAt(0);
        if ((c !== '"' && c !== "'") || v.length < 2 || v.charAt(v.length - 1) !== c) return { v: v, quoted: false };
        return { v: v.slice(1, -1), quoted: true };
    }

    // Tokens { q (began with a quote: a literal), closed (the quote was closed: exact match), neg, v } from
    // the shared tokenizer (~/.config/quickshell/lib/dsl.js)
    function tokenize(text) {
        return D.tokenize(text).map(t => ({ q: t.leadQuote, closed: t.quoted, neg: t.neg, v: t.text }));
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
    // verb spellings -> canonical short form, for D.splitCmd ("" = the default verb of `//keys`)
    readonly property var _verbMap: ({ "": "/fv", "fv": "/fv", "ft": "/ft", "at": "/at", "rt": "/rt", "s": "/s", "g": "/g",
        "filter-value": "/fv", "filter-type": "/ft", "add-type": "/at", "remove-type": "/rt", "sort": "/s", "group": "/g" })
    readonly property var _maxParts: ({ "/s": 3, "/g": 4 })
    // { verb, via (the keys part), dir, bad } or null (query-dsl.md "Grammar"); a quoted token is never a command
    function tokVerb(tok) {
        if (tok.q) return null;
        const c = D.splitCmd(tok.v, root._verbMap, root._maxParts);
        return c === null ? null : { verb: c.verb, via: c.keys, dir: c.dir, bad: c.bad };
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
    function _isDirectionLike(tok) { return D.parseDirection(tok) !== null; }

    function _dirOf(tok) { return D.parseDirection(tok) || "asc"; }

    // Parse into { terms:[{field,value,quoted}|{text,quoted}], sort:{fields,dir}|null,
    // cols:[{op,path}] }. Incomplete trailing tokens are dropped
    // (never flash to zero on a valid partial keystroke). `field` / `path` are
    // the raw comma-separated key lists; resolve them with resolvePath().
    function parse(text) {
        const toks = root.tokenize(text);
        const res = { terms: [], sort: null, cols: [], openPaths: [], groupRaw: "" };
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
                ? { terms: [], sort: null, cols: [], openPaths: [], groupRaw: "" } : res;
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
                    R.sort = { fields: keys, dir: tv.dir ? root._dirOf(tv.dir) : "desc" };
            } else if (verb === "/g") {
                // the whole token goes to D.parseGroup (the picker resolves it against its own types); last wins
                R.groupRaw = toks[k - 1].v;
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
    function resolveSortKeys(keys, known) { return D.resolveSortKeys(keys, known); }

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
        const gm = t.match(/(?:^|\s|!)\/(?:g|group)\/[^\s\/]+((?:\/[^\s\/]+)*)\/([a-z0-9-]*)$/);
        if (gm) {
            const frag = gm[2].toLowerCase();
            const used = gm[1].split("/");
            const head = t.slice(0, t.length - frag.length);
            return [["pf", "parent folder, then /2 /3 for higher ones"], ["day", "by day"], ["week", "by week"],
                    ["month", "by month"], ["year", "by year"], ["asc", "ascending"], ["desc", "descending"]]
                .filter(d => d[0].indexOf(frag) === 0 && used.indexOf(d[0]) < 0)
                .map(d => ({ text: head + d[0] + " ", label: d[0], alias: "", desc: d[1] }));
        }
        const km = t.match(/(?:^|\s|!)\/(fv|filter-value|ft|filter-type|at|add-type|rt|remove-type|s|sort|g|group|)\/([^\s\/]*)$/);
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
    function resolvePath(path, known) { return D.resolveNames(path, known); }


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
    function compareFieldValues(a, b, dir) { return D.compareFieldValues(a, b, dir); }

    // ---- /group (query-dsl.md "/group"): thin wrappers over lib/dsl.js ----
    function parseGroup(raw, known, aliases) { return raw ? D.parseGroup(raw, known, aliases || null) : null; }
    function groupDisplay(rows, parsed, get, collapsed) { return D.groupDisplay(rows, parsed, get, collapsed); }
    function groupModel(prefix, display) { return D.groupModel(prefix, display); }
    function groupInitial(parsed) { return D.groupInitial(parsed); }
    function groupToggle(collapsed, id) { return D.groupToggle(collapsed, id); }
    function groupOfRow(display, v) { return D.groupOfRow(display, v); }
}

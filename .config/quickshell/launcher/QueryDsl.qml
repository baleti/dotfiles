pragma Singleton

import QtQuick

// The shared picker query DSL (~/.config/docs/query-dsl.md), ported to JS
// for the quickshell app launcher and RSS reader -- the same grammar
// alt+tab (winswitch) and mod+v (clipboard-picker) use, hand-written a
// 7th time as that doc intends. Verbs are exact-matched; type-path
// segments substring-match, case-insensitively, unioned.
//
// Via paths (query-dsl.md "Via paths"): every path-taking verb can carry
// its type path glued straight onto the verb with a second `/` --
// `/fv/feed dezeen` means exactly what `/fv feed:dezeen` did, no colon.
// `tokVerb` returns { verb, via } for this; `parse` handles both spellings
// through the same term shape. Mirrors winswitch's query.rs::tok_verb /
// starts_command / parse.
QtObject {
    id: root

    readonly property var shortVerbs: ["/fv", "/ft", "/at", "/rt", "/s", "/rv"]
    readonly property var verbAliases: ({
        "/filter-value": "/fv", "/filter-type": "/ft", "/add-type": "/at",
        "/remove-type": "/rt", "/sort": "/s", "/reverse": "/rv"
    })
    // { short: { long, desc } } -- the long-form alias + a one-line
    // description, for marginalia-style autocomplete hints (query-dsl.md).
    readonly property var verbInfo: ({
        "/fv": { long: "/filter-value", desc: "keep rows whose value matches (substring)" },
        "/ft": { long: "/filter-type",  desc: "show only the matching columns" },
        "/at": { long: "/add-type",     desc: "add the matching columns" },
        "/rt": { long: "/remove-type",  desc: "drop the matching columns" },
        "/s":  { long: "/sort",         desc: "order rows by one field, optional asc / desc" },
        "/rv": { long: "/reverse",      desc: "flip the current order" }
    })

    // Every accepted verb spelling, WITHOUT the leading "/" (query.rs's
    // VERB_FORMS) -- for prefix detection on the verb-name portion only.
    readonly property var verbForms: [
        "fv", "ft", "at", "rt", "s", "rv",
        "filter-value", "filter-type", "add-type", "remove-type", "sort", "reverse"
    ]

    // Split on whitespace, keeping "quoted runs" as one token (quotes stripped).
    function tokenize(text) {
        const out = [];
        let i = 0;
        while (i < text.length) {
            while (i < text.length && text[i] === " ") i++;
            if (i >= text.length) break;
            if (text[i] === '"') {
                const end = text.indexOf('"', i + 1);
                if (end < 0) { out.push({ q: true, v: text.slice(i + 1) }); break; }
                out.push({ q: true, v: text.slice(i + 1, end) });
                i = end + 1;
            } else {
                let j = i;
                while (j < text.length && text[j] !== " ") j++;
                out.push({ q: false, v: text.slice(i, j) });
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

    // query.rs::tok_verb -- { verb, via } or null. `verb` is a canonical
    // short form ("/fv" ...); `via` is the glued-on type path (lowercased
    // by the caller where it matters) or null. A "/xyz" that isn't a verb
    // (or "/usr/bin") is not a verb token -> null.
    function tokVerb(tok) {
        if (tok.q || tok.v[0] !== "/") return null;
        const rest = tok.v.slice(1);
        const slash = rest.indexOf("/");
        if (slash >= 0) {
            const v = root._canonName(rest.slice(0, slash));
            return v === null ? null : { verb: v, via: rest.slice(slash + 1) };
        }
        const v = root._canonName(rest);
        return v === null ? null : { verb: v, via: null };
    }

    // query.rs::is_verb_prefix -- `s` (no leading "/") is a non-empty
    // prefix of some verb form, so a "/s..." token still on its way to a
    // verb stays inert mid-typing rather than being searched literally.
    function isVerbPrefix(s) {
        return s.length > 0 && root.verbForms.some(f => f.indexOf(s) === 0);
    }

    // query.rs::starts_command -- true for a real verb token OR a "/frag"
    // still forming into one. Used to bound a verb's argument span.
    function startsCommand(tok) {
        if (tok.q || tok.v[0] !== "/") return false;
        const rest = tok.v.slice(1);
        const slash = rest.indexOf("/");
        const name = slash >= 0 ? rest.slice(0, slash) : rest;
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

    // Parse into { terms:[{field,value,quoted}|{text,quoted}], sort:{field,dir}|null,
    // reverse:bool, cols:[{op,path}] }. Incomplete trailing tokens are dropped
    // (never flash to zero on a valid partial keystroke). Mirrors query.rs::parse.
    function parse(text) {
        const toks = root.tokenize(text);
        const res = { terms: [], sort: null, reverse: false, cols: [] };
        let k = 0;
        while (k < toks.length) {
            const tv = root.tokVerb(toks[k]);
            if (tv === null) {
                // Not a verb: a "/frag" still forming into one is inert;
                // anything else (bare word, "/usr/bin") is an implicit /fv term.
                const t = toks[k];
                const midTyping = !t.q && t.v[0] === "/" && root.isVerbPrefix(t.v.slice(1));
                if (!midTyping && t.v.length > 0)
                    res.terms.push({ text: t.v.toLowerCase(), quoted: t.q });
                k++;
                continue;
            }
            k++;
            const verb = tv.verb;

            if (tv.via !== null) {
                // Via form: path came glued onto the verb. Every verb still
                // takes the same *remaining* args, minus the path.
                const via = tv.via.toLowerCase();
                if (verb === "/fv") {
                    if (k < toks.length && !root.startsCommand(toks[k])) {
                        res.terms.push({ field: via, value: toks[k].v.toLowerCase(),
                                         quoted: toks[k].q });
                        k++;
                    }
                    // else: via path alone, no value yet -- a no-op, not
                    // the space form's free-text fallback (query-dsl.md
                    // "Via paths" -- a chosen-but-not-yet-valued via path
                    // is exactly as incomplete as any other still-forming
                    // token; treating it as free text broke "never flash
                    // to zero on a valid partial keystroke", reported
                    // 2026-09-02).
                } else if (verb === "/s") {
                    let dir = "asc";
                    if (k < toks.length && !root.startsCommand(toks[k])
                            && root._isDirectionLike(toks[k].v)) {
                        dir = root._dirOf(toks[k].v);
                        k++;
                    }
                    // Multi-key chaining (added 2026-09-02): each
                    // "/"-separated segment of the via path is its own
                    // sort key, ties on the first broken by the next, and
                    // so on. The space form stays single-key only.
                    res.sort = { fields: via.split("/"), dir: dir };
                } else if (verb === "/rv") {
                    res.reverse = true; // via meaningless here, harmless
                } else {
                    const op = verb === "/ft" ? "filter" : (verb === "/at" ? "add" : "remove");
                    res.cols.push({ op: op, path: via });
                }
                continue;
            }

            // Space form: collect argument tokens up to this verb's arity.
            const args = [];
            const maxArgs = verb === "/rv" ? 0 : (verb === "/s" ? 2 : 1);
            while (args.length < maxArgs && k < toks.length && !root.startsCommand(toks[k])) {
                if (verb === "/s" && args.length === 1 && !root._isDirectionLike(toks[k].v)) break;
                args.push(toks[k]);
                k++;
            }
            root._applyVerb(res, verb, args);
        }
        return res;
    }

    function _applyVerb(res, verb, args) {
        if (verb === "/rv") { res.reverse = true; return; }
        if (args.length === 0) return; // partial -> inert
        const a0 = args[0].v;
        if (verb === "/fv") {
            const colon = a0.indexOf(":");
            if (colon >= 0) {
                res.terms.push({
                    field: a0.slice(0, colon).toLowerCase(),
                    value: a0.slice(colon + 1).toLowerCase(),
                    quoted: args[0].q
                });
            } else {
                res.terms.push({ text: a0.toLowerCase(), quoted: args[0].q });
            }
        } else if (verb === "/s") {
            // Space form: single-key only, no chaining (see the via form
            // above for more than one key).
            const dir = (args.length > 1 && root._isDirectionLike(args[1].v))
                ? root._dirOf(args[1].v) : "asc";
            res.sort = { fields: [a0.toLowerCase()], dir: dir };
        } else {
            const op = verb === "/ft" ? "filter" : (verb === "/at" ? "add" : "remove");
            res.cols.push({ op: op, path: a0.toLowerCase() });
        }
    }

    // Substring, case-insensitive; every match unioned. `known` is the list of
    // type names for this picker.
    function resolvePath(path, known) {
        return known.filter(n => n.indexOf(path) >= 0);
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

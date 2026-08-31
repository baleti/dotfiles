pragma Singleton

import QtQuick

// The shared picker query DSL (~/.config/docs/query-dsl.md), ported to JS
// for the quickshell app launcher -- the same grammar alt+tab (winswitch)
// and mod+v (clipboard-picker) use, just a 7th hand-written implementation
// as that doc intends. Scope here: `/fv` + bare text (row filter), `/s` +
// `/rv` (order), `/ft` `/at` `/rt` (columns). Verbs are exact-matched;
// type-path segments substring-match, case-insensitively, unioned.
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

    function canonVerb(tok) {
        if (tok.q) return null;
        if (root.shortVerbs.indexOf(tok.v) >= 0) return tok.v;
        if (root.verbAliases[tok.v]) return root.verbAliases[tok.v];
        // An unrecognised "/xyz" is inert, not a literal search.
        if (tok.v.startsWith("/")) return "";
        return null;
    }

    // True if `tok` reads as a (possibly abbreviated) sort direction -
    // substring-matches "ascending" or "descending". Empty never matches
    // (a not-yet-typed slot isn't a direction either).
    function _isDirectionLike(tok) {
        const d = tok.toLowerCase();
        if (d.length === 0) return false;
        return "ascending".indexOf(d) === 0 || "descending".indexOf(d) === 0;
    }

    // Parse into { terms:[{field,value,quoted}|{text}], sort:{field,dir}|null,
    // reverse:bool, cols:[{op,path}] }. Incomplete trailing tokens are dropped
    // (never flash to zero on a valid partial keystroke).
    //
    // Every verb has a fixed arity (max argument tokens it will ever take -
    // see query-dsl.md's Grammar section): 0 for /rv, 1 for /fv /ft /at /rt,
    // 1-2 for /s (the 2nd, direction, slot only counts as consumed when the
    // token there actually reads as one). A token past a verb's arity is
    // never swallowed just because no new /verb intervened - it's left for
    // the next loop iteration, where a non-verb token becomes its own /fv
    // term. This is what keeps `/s name blender` from losing `blender` as a
    // rejected sort direction.
    function parse(text) {
        const toks = root.tokenize(text);
        const res = { terms: [], sort: null, reverse: false, cols: [] };
        let k = 0;
        while (k < toks.length) {
            const verb = root.canonVerb(toks[k]);
            if (verb === null) {
                // bare word -> free-text term (each its own AND term)
                if (toks[k].v.length > 0)
                    res.terms.push({ text: toks[k].v.toLowerCase(), quoted: toks[k].q });
                k++;
                continue;
            }
            if (verb === "") { k++; continue; } // inert /xyz
            k++;
            const args = [];
            const maxArgs = verb === "/rv" ? 0 : (verb === "/s" ? 2 : 1);
            while (args.length < maxArgs && k < toks.length && root.canonVerb(toks[k]) === null) {
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
            const dir = (args.length > 1 && root._isDirectionLike(args[1].v)
                         && "descending".indexOf(args[1].v.toLowerCase()) === 0) ? "desc" : "asc";
            res.sort = { field: a0.toLowerCase(), dir: dir };
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
}

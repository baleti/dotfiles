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

    // Parse into { terms:[{field,value,quoted}|{text}], sort:{field,dir}|null,
    // reverse:bool, cols:[{op,path}] }. Incomplete trailing tokens are dropped
    // (never flash to zero on a valid partial keystroke).
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
            // gather args up to the next verb
            const args = [];
            k++;
            while (k < toks.length && root.canonVerb(toks[k]) === null) {
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
                    value: (args[0].q ? a0.slice(colon + 1)
                                      : args.map(a => a.v).join(" ").slice(colon + 1)).toLowerCase(),
                    quoted: args[0].q
                });
            } else {
                res.terms.push({ text: args.map(a => a.v).join(" ").toLowerCase(), quoted: args[0].q });
            }
        } else if (verb === "/s") {
            let dir = "asc";
            if (args.length > 1) {
                const d = args[1].v.toLowerCase();
                if ("descending".indexOf(d) === 0 && d.length > 0) dir = "desc";
            }
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

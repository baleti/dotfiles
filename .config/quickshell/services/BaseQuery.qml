pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

// Base query for the DSL pickers (query-dsl.md "/base-query"): one standing query per picker, keyed by name
// ("rss", "clipboard", "winswitch", ...), run in front of whatever is typed. Persisted in one JSON file,
// ~/.cache/quickshell/base-queries.json: { key: { query, history[] } }.
//
// Typed forms (first token of the box only):
//   /bq <q> + Enter   save <q> as this picker's base query, clear the box  ("/bq " alone clears it)
//   /bq + Enter       box becomes "/bq <current base query>" to edit
//   /bq ...           transparent: the rest runs as the query, the stored base query is switched off
//   !/bq ...          the same, but Enter never saves; Tab on a bare "!/bq" writes the opposite of the base query
// Hook points in a picker: effective(key, text) wherever the text is parsed, run(key, input) on Enter,
// expandNeg(key, input) on Tab.
Singleton {
    id: root

    property var store: ({})

    FileView {
        id: file
        path: Quickshell.env("HOME") + "/.cache/quickshell/base-queries.json"
        atomicWrites: true
        watchChanges: true
        onFileChanged: reload()
        onLoaded: { try { root.store = JSON.parse(file.text()) || ({}); } catch (e) { root.store = ({}); } }
        onLoadFailed: {}
    }

    function get(key) { return ((root.store[key] || {}).query || "").trim(); }
    function history(key) { return (root.store[key] || {}).history || []; }
    function set(key, q) {
        const cur = root.store[key] || {};
        const prev = (cur.query || "").trim();
        let h = (cur.history || []).slice();
        if (q && prev && prev !== q && h.indexOf(prev) < 0) h.unshift(prev);
        if (q) h = [q].concat(h.filter(x => x !== q)).slice(0, 100);
        const n = Object.assign({}, root.store);
        n[key] = { query: q, history: h };
        root.store = n;
        file.setText(JSON.stringify(n));
    }

    // null, or { neg, ws (whitespace after the verb), rest } when text starts with /bq or !/bq
    function match(text) {
        const m = /^\s*(!?)\/(?:base-query|bq)(?:(\s+)([\s\S]*))?$/.exec(text);
        return m ? { neg: m[1] === "!", ws: m[2] !== undefined, rest: m[3] || "" } : null;
    }
    // what actually runs: the base query written in front of the typed text; under /bq or !/bq only the rest
    function effective(key, text) {
        const m = root.match(text);
        const t = (m ? m.rest : text).replace(/\n/g, " ");
        if (m) return t;
        const b = root.get(key);
        return b === "" ? t : (t.trim() === "" ? b : b + " " + t);
    }
    // Enter: true if the box held a saving /bq command (and it was handled)
    function run(key, input) {
        const m = root.match(input.text);
        if (!m || m.neg) return false;
        if (!m.ws) { input.text = "/bq " + root.get(key); }
        else { root.set(key, m.rest.trim()); input.text = ""; }
        input.cursorPosition = input.text.length;
        return true;
    }
    // Tab on a bare "!/bq": write the opposite of the base query after it; true if it did
    function expandNeg(key, input) {
        if (!/^\s*!\/(?:base-query|bq)\s*$/.test(input.text)) return false;
        const inv = root.invert(root.get(key));
        if (inv !== "") { input.text = "!/bq " + inv; input.cursorPosition = input.text.length; }
        return true;
    }
    function invert(q) {
        // Opposite of a base query (query-dsl.md "!/bq"): terms are ANDed, so the complement is "any term fails".
        const toks = [], re = /!?"[^"]*"?|\S+/g;
        let m;
        while ((m = re.exec(q)) !== null) toks.push(m[0]);
        const VERB = /^\/(fv|filter-value|ft|filter-type|at|add-type|rt|remove-type|s|sort|g|group|fts|full-text-search|bq|base-query)(\/\S*)?$/;
        const isVerb = t => { const u = t.replace(/^!/, ""); return /^\/\/[^\s\/]*$/.test(u) || VERB.test(u); };
        const items = [];
        for (let i = 0; i < toks.length;) {
            const t = toks[i], neg = t[0] === "!", u = neg ? t.slice(1) : t;
            let k = null, mm;
            if ((mm = /^\/\/([a-z,-]*)$/.exec(u))) k = mm[1];
            else if ((mm = /^\/(?:fv|filter-value)\/([a-z,-]*)$/.exec(u))) k = mm[1];
            if (k !== null && k !== "") {
                const nx = toks[i + 1];
                if (nx !== undefined && !isVerb(nx)) { items.push({ f: 1, neg: neg, keys: k, value: nx }); i += 2; continue; }
                items.push({ o: t }); i++; continue;
            }
            if (isVerb(t)) {
                let tx = t; i++;
                if (/^\/(fts|full-text-search)/.test(u)) while (i < toks.length && !isVerb(toks[i])) tx += " " + toks[i++];
                items.push({ o: tx }); continue;
            }
            items.push({ f: 1, neg: neg, keys: null, value: u }); i++;
        }
        const fs = items.filter(x => x.f);
        if (!fs.length) return q.trim();
        const merge = fs.length > 1 && fs.every(x => x.neg && x.keys === fs[0].keys && x.value.indexOf('"') < 0);
        const out = [];
        let done = false;
        for (const x of items) {
            if (x.o) { out.push(x.o); continue; }
            if (merge) { if (!done) { done = true; out.push((fs[0].keys !== null ? "//" + fs[0].keys + " " : "") + fs.map(y => y.value).join("||")); } continue; }
            out.push((x.neg ? "" : "!") + (x.keys !== null ? "//" + x.keys + " " : "") + x.value);
        }
        return out.join(" ");
    }
}

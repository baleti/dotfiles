pragma Singleton

import QtQuick

// The shared picker query DSL (~/.config/docs/query-dsl.md), hand-ported a
// 7th time -- for the Quickshell clipboard-picker (mod+v), the UI move
// winswitch made first (see 753e505). This is its own copy, not an import
// of the launcher's QueryDsl.qml: clipboard-picker's grammar differs from
// every other QML consumer in two ways query-dsl.md documents explicitly --
//
//   - bare words join into ONE space-separated phrase matched as a single
//     contiguous substring against the haystack (picker.rs's `Query::text`),
//     not independent AND'd terms the way the launcher/winswitch treat them;
//   - only `/fv`/`/filter-value` (and bare text, the same thing) does
//     anything -- `/ft` `/at` `/rt` `/s` `/rv` are recognised (so their
//     tokens don't leak into the free-text phrase) but otherwise inert, this
//     picker has no columns and no re-sort.
//
// Ported from picker.rs's own functions (named in each comment below) --
// keep both in sync by hand if either changes, same "copy-pasted on
// purpose" reasoning query-dsl.md gives for every consumer in its table.
QtObject {
    id: root

    // picker.rs's VERB_FORMS.
    readonly property var verbForms: [
        "fv", "ft", "at", "rt", "s", "rv",
        "filter-value", "filter-type", "add-type", "remove-type", "sort", "reverse"
    ]

    // picker.rs's verb_meta -- long-form alias + one-line description, for
    // marginalia-style autocomplete hints (query-dsl.md "Suggestion row
    // anatomy"). Keyed without the leading "/".
    readonly property var verbInfo: ({
        "fv": { alias: "/filter-value", desc: "keep rows whose value matches (substring)" },
        "ft": { alias: "/filter-type",  desc: "show only the matching columns" },
        "at": { alias: "/add-type",     desc: "add the matching columns" },
        "rt": { alias: "/remove-type",  desc: "drop the matching columns" },
        "s":  { alias: "/sort",         desc: "order rows by one field, optional asc / desc" },
        "rv": { alias: "/reverse",      desc: "flip the current order" }
    })

    // Case-insensitive substring containment; empty needle always matches
    // (picker.rs's substr).
    function substr(needle, hay) {
        return hay.toLowerCase().indexOf(needle.toLowerCase()) >= 0;
    }

    function isFilterValueVerb(rest) { return rest === "fv" || rest === "filter-value"; }
    function isVerb(rest) { return root.verbForms.indexOf(rest) >= 0; }
    function isVerbPrefix(s) {
        return s.length > 0 && root.verbForms.some(v => v.indexOf(s) === 0);
    }

    // picker.rs's tokenize -- whitespace-split, a `"..."`-quoted run kept
    // whole with the quote characters themselves stripped (not pushed into
    // the token text); `leadQuote` marks a run that started with `"`, which
    // makes it a literal, never a command, even unterminated.
    function tokenize(query) {
        const tokens = [];
        let cur = "";
        let start = -1;
        let leadQuote = false;
        let inQuotes = false;
        for (let i = 0; i < query.length; i++) {
            const c = query[i];
            if (c === "\"") {
                if (start < 0) leadQuote = true;
                inQuotes = !inQuotes;
                if (start < 0) start = i;
                continue;
            }
            if (/\s/.test(c) && !inQuotes) {
                if (start >= 0) {
                    tokens.push({ start: start, text: cur, leadQuote: leadQuote });
                    cur = ""; start = -1; leadQuote = false;
                }
                continue;
            }
            if (start < 0) start = i;
            cur += c;
        }
        if (start >= 0) tokens.push({ start: start, text: cur, leadQuote: leadQuote });
        return tokens;
    }

    // picker.rs's starts_cmd -- true if `tok` begins (or is still typing)
    // a command rather than serving as some other verb's argument.
    function startsCmd(tok) {
        if (tok.leadQuote || tok.text[0] !== "/") return false;
        const rest = tok.text.slice(1);
        return root.isVerb(rest) || root.isVerbPrefix(rest);
    }

    // picker.rs's command_spans -- {start,end,valid} for every unambiguous
    // `/command` attempt in `query`, in char offsets (query-dsl.md "Inline
    // command-validity coloring"). Skips a still-forming verb prefix
    // entirely (neutral, not wrong yet).
    function commandSpans(query) {
        const out = [];
        for (const tok of root.tokenize(query)) {
            if (tok.leadQuote || tok.text[0] !== "/") continue;
            const rest = tok.text.slice(1);
            if (rest.length === 0) continue;
            const valid = root.isVerb(rest);
            if (!valid && root.isVerbPrefix(rest)) continue;
            out.push({ start: tok.start, end: tok.start + tok.text.length, valid: valid });
        }
        return out;
    }

    // picker.rs's resolve_fields -- every field name containing `frag` as a
    // substring, unioned.
    function resolveFields(frag, fieldNames) {
        return fieldNames.filter(f => root.substr(frag, f));
    }

    function _pushFvArg(arg, fieldNames, fieldTerms, words) {
        const colon = arg.indexOf(":");
        if (colon >= 0) {
            fieldTerms.push({ fields: root.resolveFields(arg.slice(0, colon), fieldNames), value: arg.slice(colon + 1) });
        } else {
            words.push(arg);
        }
    }

    // picker.rs's parse_query -- {fieldTerms:[{fields,value}], text}. `text`
    // is every bare word joined into ONE lowercased phrase (this picker's
    // own pre-DSL behaviour, kept as-is -- see this file's header), not
    // independent terms. A `/fv`/`/filter-value` argument with no `:`
    // becomes a phrase word too (query-dsl.md's `/fv text` == bare `text`).
    // Every other verb is recognised and its (own-arity-bounded) argument
    // swallowed so it can't leak into the phrase, but otherwise inert.
    function parse(text, fieldNames) {
        const toks = root.tokenize(text);
        const fieldTerms = [];
        const words = [];
        let i = 0;
        while (i < toks.length) {
            const tok = toks[i];
            if (!tok.leadQuote && tok.text[0] === "/") {
                const rest = tok.text.slice(1);
                if (root.isFilterValueVerb(rest)) {
                    i++;
                    if (i < toks.length && !root.startsCmd(toks[i])) {
                        root._pushFvArg(toks[i].text, fieldNames, fieldTerms, words);
                        i++;
                    }
                    continue;
                }
                if (root.isVerb(rest)) {
                    i++;
                    const n = (rest === "rv" || rest === "reverse") ? 0 : 1;
                    let c = 0;
                    while (c < n && i < toks.length && !root.startsCmd(toks[i])) { i++; c++; }
                    continue;
                }
                if (root.isVerbPrefix(rest)) { i++; continue; } // mid-typing -- inert
                // else: a literal like "/usr/bin" -- real phrase text
            }
            words.push(tok.text);
            i++;
        }
        return { fieldTerms: fieldTerms, text: words.join(" ").toLowerCase() };
    }

    // True if `entry` (shape: {haystack, fields:{name:value}}) survives
    // `query` (picker.rs's listbox filter_func). `fields[f]` absent (not
    // just empty) never matches -- same "absent, not empty" contract
    // Entry::fields keeps throughout.
    function matches(entry, query) {
        for (const t of query.fieldTerms) {
            let ok = false;
            for (const f of t.fields) {
                const v = entry.fields[f];
                if (v !== undefined && root.substr(t.value, v)) { ok = true; break; }
            }
            if (!ok) return false;
        }
        return query.text.length === 0 || entry.haystack.indexOf(query.text) >= 0;
    }

    // Every field name currently /fv-scoped by `query`, first-referenced
    // order, deduped (picker.rs's referenced_fields -- query-dsl.md's
    // "Auto-shown filter fields").
    function referencedFields(query) {
        const out = [];
        for (const t of query.fieldTerms)
            for (const f of t.fields)
                if (out.indexOf(f) < 0) out.push(f);
        return out;
    }

    // picker.rs's fv_open -- whether the last complete command in `context`
    // (tokens before the fragment being completed) is a still-open `/fv`
    // waiting for its value argument. Only while this is true does a bare
    // (colon-less) fragment mean "completing a field name" rather than
    // "just free text, nothing to complete" -- unlike the launcher/winswitch,
    // which key their path-stage completion off a regex on the verb alone.
    function fvOpen(context) {
        let open = false;
        let pending = 0;
        for (const tok of context) {
            if (pending > 0 && !root.startsCmd(tok)) { pending--; open = false; continue; }
            pending = 0;
            if (!tok.leadQuote && tok.text[0] === "/") {
                const rest = tok.text.slice(1);
                if (root.isFilterValueVerb(rest)) { open = true; continue; }
                if (root.isVerb(rest)) { open = false; pending = (rest === "rv" || rest === "reverse") ? 0 : 1; continue; }
                if (root.isVerbPrefix(rest)) { open = false; continue; }
            }
            open = false;
        }
        return open;
    }

    // picker.rs's completion_context -- null (nothing to complete), or
    // {kind:"verb"|"field"|"value", start, frag, field?}.
    function completionContext(text, fieldNames) {
        const toks = root.tokenize(text);
        if (toks.length === 0) return null;
        const trailingSpace = /\s$/.test(text);
        let context, start, frag, leadQuote;
        if (trailingSpace) {
            context = toks; start = text.length; frag = ""; leadQuote = false;
        } else {
            const last = toks[toks.length - 1];
            context = toks.slice(0, -1); start = last.start; frag = last.text; leadQuote = last.leadQuote;
        }
        if (leadQuote) return null;
        if (frag[0] === "/") return { kind: "verb", start: start, frag: frag.slice(1) };
        if (!root.fvOpen(context)) return null; // fresh phrase text -- nothing to complete
        const colon = frag.indexOf(":");
        if (colon >= 0) {
            const resolved = fieldNames.filter(c => root.substr(frag.slice(0, colon), c));
            if (resolved.length !== 1) return null; // ambiguous/unresolved -- no single value set
            return { kind: "value", start: start, field: resolved[0], frag: frag.slice(colon + 1) };
        }
        return { kind: "field", start: start, frag: frag };
    }

    // picker.rs's verb_stage_universe -- the six bare verb shorts
    // (ft/at/rt/s/rv recognised-but-inert here, kept so they still complete
    // rather than falling into free text) plus `/fv` crossed with every
    // field name -- `/fv` is the only verb here a deep candidate turns into
    // a working command (query-dsl.md "Verb-stage depth").
    function verbStageUniverse(fieldNames) {
        const out = ["fv", "ft", "at", "rt", "s", "rv"];
        for (const f of fieldNames) out.push("fv/" + f);
        return out;
    }

    function verbSuggestions(frag, fieldNames) {
        return root.verbStageUniverse(fieldNames).filter(v => root.substr(frag, v));
    }

    function fieldSuggestions(fieldNames, frag) {
        return fieldNames.filter(f => root.substr(frag, f));
    }

    // Every distinct non-empty value `field` actually has across `entries`
    // right now, substring-narrowed, deduplicated, sorted (picker.rs's
    // value_suggestions).
    function valueSuggestions(entries, field, frag) {
        const seen = new Set();
        for (const e of entries) {
            const v = e.fields[field];
            if (v && root.substr(frag, v)) seen.add(v);
        }
        return [...seen].sort();
    }

    // picker.rs's suggest_row -- {label, alias, desc} for one autocomplete
    // row. `fieldDescs` is {name: one-liner}.
    function suggestRow(kind, item, fieldDescs) {
        if (kind === "verb") {
            const slash = item.indexOf("/");
            if (slash >= 0) {
                const v = item.slice(0, slash), f = item.slice(slash + 1);
                return { label: "/" + item, alias: (root.verbInfo[v] || {}).alias || "", desc: fieldDescs[f] || "" };
            }
            const info = root.verbInfo[item] || { alias: "", desc: "" };
            return { label: "/" + item, alias: info.alias, desc: info.desc };
        }
        if (kind === "field") {
            return { label: item, alias: "", desc: fieldDescs[item] || "" };
        }
        return { label: item, alias: "", desc: "" }; // value
    }

    // picker.rs's accept_suggestion -- the new full query text once `chosen`
    // (one item from the candidate list for `ctx`, {kind,start,field?}) is
    // accepted, given the query text it was computed from.
    function acceptText(text, ctx, chosen) {
        const prefix = text.slice(0, ctx.start);
        if (ctx.kind === "verb") {
            const slash = chosen.indexOf("/");
            if (slash >= 0) return prefix + "/" + chosen.slice(0, slash) + " " + chosen.slice(slash + 1) + ":";
            return prefix + "/" + chosen + " ";
        }
        if (ctx.kind === "field") return prefix + chosen + ":";
        // value
        const value = /\s/.test(chosen) ? "\"" + chosen + "\"" : chosen;
        return prefix + ctx.field + ":" + value + " ";
    }
}

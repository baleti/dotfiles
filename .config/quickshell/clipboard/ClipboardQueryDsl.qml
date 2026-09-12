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
// One deliberate divergence from picker.rs (2026-09-12): picker.rs has no
// via-path parser at all (see its own accept_suggestion comment), so its
// Verb-stage deep candidates ("/fv/type") land the colon form ("/fv type:")
// on accept even though the row is labelled with a "/" -- reported here as
// looking wrong. This file adds real `/fv/path value` parsing (mirroring
// winswitch's `tokVerb`/via handling, ported below) so accepting a deep
// candidate can actually produce `/fv/type ` and have it mean what it
// looks like. `notification-picker` still runs the unmodified GTK engine,
// so this is the one place the two now differ -- everything else (bare-
// phrase joining, GTK-family Tab/Ctrl+j/k keyboard handling, no /ft /at /rt
// /s /rv support) stays identical on purpose.
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

    // Long-form -> short-form, for canonicalizing a verb name regardless of
    // which spelling was typed (winswitch's `_canonName`).
    readonly property var _aliasToShort: ({
        "filter-value": "fv", "filter-type": "ft", "add-type": "at",
        "remove-type": "rt", "sort": "s", "reverse": "rv"
    })
    readonly property var _shortForms: ["fv", "ft", "at", "rt", "s", "rv"]
    function _canon(name) {
        if (root._shortForms.indexOf(name) >= 0) return name;
        return root._aliasToShort[name] || null;
    }

    // winswitch's tokVerb -- {verb, via} for a real verb token (verb always
    // the canonical short form), or null if `tok` isn't one at all. `via` is
    // the type path glued on with a second "/" (query-dsl.md "Via paths"),
    // or null if there wasn't one.
    function tokVerb(tok) {
        if (tok.leadQuote || tok.text[0] !== "/") return null;
        const rest = tok.text.slice(1);
        const slash = rest.indexOf("/");
        if (slash >= 0) {
            const v = root._canon(rest.slice(0, slash));
            return v === null ? null : { verb: v, via: rest.slice(slash + 1) };
        }
        const v = root._canon(rest);
        return v === null ? null : { verb: v, via: null };
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
            // Validity is decided on the verb name alone -- a via path after
            // it (query-dsl.md: "/fv/bogus_field still colors as valid")
            // never makes an otherwise-real verb invalid.
            const slash = rest.indexOf("/");
            const name = slash >= 0 ? rest.slice(0, slash) : rest;
            const valid = root._canon(name) !== null;
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
    //
    // Extends picker.rs with real via-path parsing for `/fv` (this file's
    // header) -- `/fv/path value` means exactly what `/fv path:value` does,
    // by synthesizing "path:value" and reusing the same colon-split
    // resolution (`_pushFvArg`), same trick winswitch's own via handling
    // uses. `/fv/path` alone with no value yet is a no-op, not free text
    // (query-dsl.md "Via paths" -- clipboard-picker has no groups, so the
    // "existence filter" case there never applies here, only the flat-type
    // no-op case does). Every other verb's via path is recognised (so it
    // doesn't leak into the phrase) but, like its space form, inert.
    //
    // `openFields` (2026-09-12): the field(s) a still-forming `/fv/path`
    // resolves to, even with no value yet - kept separate from
    // `fieldTerms` (never consulted by `matches`, so filtering stays
    // exactly the no-op it already was) purely so `referencedFields` below
    // can show the column the moment the path is named, not just once a
    // value narrows anything (query-dsl.md "Auto-shown filter fields").
    // Deliberately NOT folded into `fieldTerms` with an empty value the
    // way `_pushFvArg`'s own colon-trailing-empty case already can be:
    // `matches` treats a field genuinely absent from an entry (not just
    // empty) as a hard non-match (see this file's own `matches` doc), so
    // an empty-value fieldTerm can still narrow away entries that lack the
    // field entirely - fine for a real colon typed on purpose, but not
    // something an incomplete via path should risk.
    function parse(text, fieldNames) {
        const toks = root.tokenize(text);
        const fieldTerms = [];
        const words = [];
        const openFields = [];
        let i = 0;
        while (i < toks.length) {
            const tok = toks[i];
            const tv = root.tokVerb(tok);
            if (tv === null) {
                const rest = (!tok.leadQuote && tok.text[0] === "/") ? tok.text.slice(1) : null;
                const midTyping = rest !== null && root.isVerbPrefix(rest);
                if (!midTyping) words.push(tok.text); // real word, or a literal "/usr/bin"
                i++;
                continue;
            }
            i++;
            if (tv.via !== null) {
                if (tv.verb === "fv" && i < toks.length && !root.startsCmd(toks[i])) {
                    root._pushFvArg(tv.via + ":" + toks[i].text, fieldNames, fieldTerms, words);
                    i++;
                } else if (tv.verb === "fv") {
                    for (const f of root.resolveFields(tv.via, fieldNames))
                        if (openFields.indexOf(f) < 0) openFields.push(f);
                }
                // else: some other verb's via (recognised, inert either
                // way) -- nothing to swallow past the one token itself.
                continue;
            }
            if (tv.verb === "fv") {
                if (i < toks.length && !root.startsCmd(toks[i])) {
                    root._pushFvArg(toks[i].text, fieldNames, fieldTerms, words);
                    i++;
                }
                continue;
            }
            const n = tv.verb === "rv" ? 0 : 1;
            let c = 0;
            while (c < n && i < toks.length && !root.startsCmd(toks[i])) { i++; c++; }
        }
        return { fieldTerms: fieldTerms, text: words.join(" ").toLowerCase(), openFields: openFields };
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
        // A still-forming `/fv/path` with no value yet (see `parse`'s
        // `openFields`) shows the field immediately too - query-dsl.md
        // "Auto-shown filter fields", updated 2026-09-12.
        for (const f of (query.openFields || []))
            if (out.indexOf(f) < 0) out.push(f);
        return out;
    }

    // winswitch's _replay, trimmed to this picker's one live verb -- replays
    // `context` (tokens before the fragment being completed) to whatever
    // verb, if any, is still "open" waiting for its next argument:
    // null | {verb, args:[...]}. A via token starts already-open with its
    // via path as args[0] (it supplies the path without a separate
    // argument token), which is what lets a via-typed `/fv/type` reach
    // Value-stage completion the same way a space-form `/fv type` does.
    // Every non-`/fv` verb still gets replayed (so it can't be mistaken for
    // an open `/fv`) but is otherwise a dead end here -- see completionContext.
    function _replay(context) {
        let open = null;
        for (const tok of context) {
            for (;;) {
                if (open === null) {
                    const tv = root.tokVerb(tok);
                    if (tv === null) {
                        // nothing to track
                    } else if (tv.verb === "rv") {
                        // consumes nothing
                    } else if (tv.via !== null) {
                        open = { verb: tv.verb, args: [tv.via] };
                    } else {
                        open = { verb: tv.verb, args: [] };
                    }
                    break;
                }
                if (root.startsCmd(tok)) {
                    open = null;
                    continue; // reprocess this token as a fresh command
                }
                open = null; // single arg consumed -- closes any verb here
                break;
            }
        }
        return open;
    }

    // picker.rs's completion_context, extended with via-path stages --
    // null (nothing to complete), or one of:
    //   {kind:"verb", start, frag}
    //   {kind:"field", start, frag, via}      -- typing the field name
    //   {kind:"value", start, frag, field}    -- typing "field:value"'s value
    //   {kind:"bareValue", start, frag, field} -- typing a via-typed value
    // `via` distinguishes the two ways to reach "field" stage: `/fv frag`
    // (space form, GTK pickers land the ":" form on accept) vs `/fv/frag`
    // (via form, still forming its own path segment) -- see acceptText.
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

        if (frag[0] === "/") {
            const rest = frag.slice(1);
            const slash = rest.indexOf("/");
            if (slash >= 0) {
                const name = rest.slice(0, slash), viaFrag = rest.slice(slash + 1);
                if (root._canon(name) !== "fv") return null; // only /fv does anything here
                return { kind: "field", start: start + 1 + name.length + 1, frag: viaFrag, via: true };
            }
            return { kind: "verb", start: start, frag: rest };
        }

        const open = root._replay(context);
        if (open === null || open.verb !== "fv") return null; // fresh phrase text, or some other (inert) verb
        if (open.args.length === 1) {
            // Via form already supplied the field via args[0] -- resolve it
            // the same substring way a typed field name would.
            const resolved = root.resolveFields(open.args[0], fieldNames);
            if (resolved.length !== 1) return null; // unresolvable via path -- no-op (see parse)
            return { kind: "bareValue", start: start, field: resolved[0], frag: frag };
        }
        const colon = frag.indexOf(":");
        if (colon >= 0) {
            const resolved = fieldNames.filter(c => root.substr(frag.slice(0, colon), c));
            if (resolved.length !== 1) return null; // ambiguous/unresolved -- no single value set
            return { kind: "value", start: start, field: resolved[0], frag: frag.slice(colon + 1) };
        }
        return { kind: "field", start: start, frag: frag, via: false };
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
    // (one item from the candidate list for `ctx`, from completionContext)
    // is accepted, given the query text it was computed from. Diverges from
    // picker.rs for "verb": a deep candidate ("fv/type") now lands the via
    // form it's labelled with ("/fv/type ") instead of the colon form
    // ("/fv type:") -- see this file's header. Plain field-stage completion
    // (`/fv frag` with no via) is unchanged, still colon form, matching
    // query-dsl.md's stated GTK-picker convention.
    function acceptText(text, ctx, chosen) {
        const prefix = text.slice(0, ctx.start);
        switch (ctx.kind) {
        case "verb":
            // chosen is already the full "verb" or "verb/path" text --
            // "/" + chosen + " " lands "/ft " or "/fv/type " alike.
            return prefix + "/" + chosen + " ";
        case "field":
            return prefix + chosen + (ctx.via ? " " : ":");
        case "value": {
            const value = /\s/.test(chosen) ? "\"" + chosen + "\"" : chosen;
            return prefix + ctx.field + ":" + value + " ";
        }
        case "bareValue": {
            // Via-typed field ("/fv/type") already named the field in the
            // verb token itself -- just append the value, no "field:" glue.
            const value = /\s/.test(chosen) ? "\"" + chosen + "\"" : chosen;
            return prefix + value + " ";
        }
        }
        return text;
    }
}

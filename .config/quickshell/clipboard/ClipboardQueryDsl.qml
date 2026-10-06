pragma Singleton

import QtQuick

// The shared picker query DSL (~/.config/docs/query-dsl.md), hand-ported a
// 7th time -- for the Quickshell clipboard-picker (mod+v), the UI move
// winswitch made first (see 753e505). This is its own copy, not an import
// of the launcher's QueryDsl.qml: clipboard-picker's grammar differs from
// every other QML consumer in one way query-dsl.md documents explicitly --
// bare words join into ONE space-separated phrase matched as a single
// contiguous substring against the haystack (picker.rs's `Query::text`),
// not independent AND'd terms the way the launcher/winswitch treat them.
//
// `/ft` `/at` `/rt` `/s` `/rv` (columns + sort) went live 2026-09-28 --
// through 2026-09-27 these were recognised (so their tokens didn't leak
// into the free-text phrase) but otherwise inert, matching picker.rs's own
// GTK engine, which had no column/re-sort machinery at all. Both pickers
// on this grammar are flat (no groups the way winswitch's `claude`/`tmux`
// are), so "type path" here just means `resolveFields`'s ordinary
// substring match against `fieldNames` -- see `activeColumns`/`applySort`
// below, closest in spirit to focus-picker.py's own flat column/sort
// implementation (query-dsl.md's Verb-stage depth rollout note) rather
// than winswitch's group-aware one.
//
// One deliberate divergence from picker.rs (2026-09-12): picker.rs has no
// via-path parser at all (see its own accept_suggestion comment), so its
// Verb-stage deep candidates ("/fv/type") land the colon form ("/fv type:")
// on accept even though the row is labelled with a "/" -- reported here as
// looking wrong. This file adds real `/fv/path value` parsing (mirroring
// winswitch's `tokVerb`/via handling, ported below) so accepting a deep
// candidate can actually produce `/fv/type ` and have it mean what it
// looks like.
//
// notification-picker (mod+CTRL+n) made its own GTK->Quickshell move on
// 2026-09-28 and imports this same singleton directly (`import
// "../clipboard"` from NotificationPicker.qml) rather than getting an 8th
// hand-port: it was built on the identical `picker.rs` engine and shares
// this grammar byte-for-byte, and every entry point below already takes
// `fieldNames`/`fieldDescs` as plain arguments -- there was nothing
// clipboard-specific baked in here to port around. The `/fv/path value`
// divergence above is no longer clipboard-only; notification-picker gets
// it too, for free.
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
    // No separate empty-string guard: every verb form trivially "starts
    // with" "" already, so a bare "/" (s === "") is correctly a prefix of
    // all of them too - excluding it would make the very first keystroke
    // of any command fall through as literal phrase text instead of
    // staying inert (reported 2026-09-13 against the sibling winswitch
    // implementation - typing "/" alone was clearing the whole list).
    function isVerbPrefix(s) {
        return root.verbForms.some(v => v.indexOf(s) === 0);
    }

    // Long-form -> short-form, for canonicalizing a verb name regardless of
    // which spelling was typed (winswitch's `_canonName`).
    readonly property var _aliasToShort: ({
        "filter-value": "fv", "filter-type": "ft", "add-type": "at",
        "remove-type": "rt", "sort": "s", "reverse": "rv"
    })
    readonly property var _shortForms: ["fv", "ft", "at", "rt", "s", "rv"]
    // "" (the empty verb slot of "//path") is the default verb /fv -
    // query-dsl.md "Default verb". Only reachable with a via slash after
    // it; tokVerb guards the bare-"/" case.
    function _canon(name) {
        if (name === "") return "fv";
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
        if (rest === "") return null; // bare "/" - not the default verb
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
        // Leading "!" negates the token (query-dsl.md "Negation"); not part
        // of it, so `start` stays on the char after it.
        let neg = false;
        for (let i = 0; i < query.length; i++) {
            const c = query[i];
            if (c === "!" && start < 0 && !neg) { neg = true; continue; }
            if (c === "\"") {
                if (start < 0) leadQuote = true;
                inQuotes = !inQuotes;
                if (start < 0) start = i;
                continue;
            }
            if (/\s/.test(c) && !inQuotes) {
                if (start >= 0) {
                    tokens.push({ start: start, text: cur, leadQuote: leadQuote, neg: neg });
                    cur = ""; start = -1; leadQuote = false;
                }
                neg = false;
                continue;
            }
            if (start < 0) start = i;
            cur += c;
        }
        if (start >= 0) tokens.push({ start: start, text: cur, leadQuote: leadQuote, neg: neg });
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

    function _pushFvArg(arg, fieldNames, fieldTerms, words, neg, negWords) {
        const colon = arg.indexOf(":");
        if (colon >= 0) {
            fieldTerms.push({ fields: root.resolveFields(arg.slice(0, colon), fieldNames), value: arg.slice(colon + 1), neg: !!neg });
        } else if (neg) {
            negWords.push(arg);
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
    // Direction token for `/sort` -- substring-matches "ascending" or
    // "descending" the same way every other fragment match in this file
    // does (query-dsl.md: "asc / desc / de all work"). Returns null if
    // `tok` doesn't match either, so the caller knows to leave it
    // unconsumed (falls through to plain phrase text -- see `parse`).
    function _sortDirection(tok) {
        if (tok.length === 0) return null;
        if (root.substr(tok, "ascending")) return "ascending";
        if (root.substr(tok, "descending")) return "descending";
        return null;
    }

    // picker.rs's parse_query -- {fieldTerms:[{fields,value}], text}. `text`
    // is every bare word joined into ONE lowercased phrase (this picker's
    // own pre-DSL behaviour, kept as-is -- see this file's header), not
    // independent terms. A `/fv`/`/filter-value` argument with no `:`
    // becomes a phrase word too (query-dsl.md's `/fv text` == bare `text`).
    //
    // `/ft`/`/at`/`/rt` each swallow one type-path argument into
    // `columnOps` (`{verb, path}`, in left-to-right order -- see
    // `activeColumns`); `/sort`/`/s` swallows its path chain (space form:
    // one path plus an optional direction token; via form: `/`-chained
    // paths, e.g. `/s/tokens/title`, with the same optional direction
    // token following) into `sort` (`{paths, direction}`, last one wins);
    // `/reverse`/`/rv` just flips `reverse` (idempotent -- any count is
    // the same as one). See `activeColumns`/`applySort` for how these are
    // actually applied; `parse` only ever records raw path text, same
    // "resolve later" split `fieldTerms`/`matches` already keeps.
    function parse(text, fieldNames) {
        const toks = root.tokenize(text);
        const fieldTerms = [];
        const words = [];
        const negWords = []; // each "!word": the row must NOT contain it
        const openFields = [];
        const columnOps = [];
        let sort = null;
        let reverse = false;
        let i = 0;
        while (i < toks.length) {
            const tok = toks[i];
            const tv = root.tokVerb(tok);
            if (tv === null) {
                const rest = (!tok.leadQuote && tok.text[0] === "/") ? tok.text.slice(1) : null;
                const midTyping = rest !== null && root.isVerbPrefix(rest);
                if (!midTyping) (tok.neg ? negWords : words).push(tok.text); // real word, or a literal "/usr/bin"
                i++;
                continue;
            }
            i++;
            // "!" only means something on a row filter: "!/s", "!/ft" ...
            // still consume their arguments but change nothing.
            const verbNeg = !!tok.neg;
            if (verbNeg && tv.verb !== "fv") {
                if (tv.via === null && tv.verb !== "rv" && i < toks.length && !root.startsCmd(toks[i])) {
                    i++;
                    if (tv.verb === "s" && i < toks.length && !root.startsCmd(toks[i])
                            && root._sortDirection(toks[i].text.toLowerCase()) !== null) i++;
                }
                continue;
            }
            if (tv.via !== null) {
                if (tv.verb === "fv" && i < toks.length && !root.startsCmd(toks[i])) {
                    root._pushFvArg(tv.via + ":" + toks[i].text, fieldNames, fieldTerms, words, verbNeg || toks[i].neg, negWords);
                    i++;
                } else if (tv.verb === "fv" && tv.via.length > 0) {
                    // `tv.via.length > 0` matters on its own: an empty via
                    // ("/fv/" with nothing typed after the second "/" yet)
                    // would otherwise resolve through `resolveFields` as
                    // if it matched every field name at once - an empty
                    // substring needle matches everything - so "/fv/"
                    // alone auto-showed every field (reported 2026-09-13).
                    // Nothing typed yet must stay inert, not get treated
                    // as an ambiguous fragment to union across.
                    for (const f of root.resolveFields(tv.via, fieldNames))
                        if (openFields.indexOf(f) < 0) openFields.push(f);
                } else if (tv.verb === "ft" || tv.verb === "at" || tv.verb === "rt") {
                    if (tv.via.length > 0) columnOps.push({ verb: tv.verb, path: tv.via });
                } else if (tv.verb === "s" && tv.via.length > 0) {
                    const paths = tv.via.split("/").filter(p => p.length > 0);
                    let direction = "ascending";
                    if (i < toks.length && !root.startsCmd(toks[i])) {
                        const d = root._sortDirection(toks[i].text.toLowerCase());
                        if (d !== null) { direction = d; i++; }
                    }
                    if (paths.length > 0) sort = { paths: paths, direction: direction };
                } else if (tv.verb === "rv") {
                    reverse = true;
                }
                // else: an empty via on ft/at/rt/s (nothing typed after
                // the second "/" yet) -- stays inert, same "nothing typed
                // yet" reasoning as fv's empty-via guard above.
                continue;
            }
            if (tv.verb === "fv") {
                if (i < toks.length && !root.startsCmd(toks[i])) {
                    root._pushFvArg(toks[i].text, fieldNames, fieldTerms, words, verbNeg || toks[i].neg, negWords);
                    i++;
                }
                continue;
            }
            if (tv.verb === "ft" || tv.verb === "at" || tv.verb === "rt") {
                if (i < toks.length && !root.startsCmd(toks[i])) {
                    columnOps.push({ verb: tv.verb, path: toks[i].text });
                    i++;
                }
                continue;
            }
            if (tv.verb === "s") {
                if (i < toks.length && !root.startsCmd(toks[i])) {
                    const path = toks[i].text;
                    i++;
                    let direction = "ascending";
                    if (i < toks.length && !root.startsCmd(toks[i])) {
                        const d = root._sortDirection(toks[i].text.toLowerCase());
                        if (d !== null) { direction = d; i++; }
                    }
                    sort = { paths: [path], direction: direction };
                }
                continue;
            }
            if (tv.verb === "rv") {
                reverse = true;
                continue;
            }
        }
        return {
            fieldTerms: fieldTerms, text: words.join(" ").toLowerCase(), negWords: negWords.map(w => w.toLowerCase()), openFields: openFields,
            columnOps: columnOps, sort: sort, reverse: reverse
        };
    }

    // `/fv field:>4` (or via, `//field >4`) -- a fieldTerm's value prefixed
    // with `>` `<` `>=` `<=` compares numerically/by-age instead of
    // substring-matching, added 2026-09-28. `{op, operand}` if `value`
    // starts with one of the four (longest first, so `>=`/`<=` aren't
    // mistaken for `>`/`<` plus a leading `=`), else null -- a value with
    // no operator prefix is entirely unaffected, still plain `substr`.
    function _parseComparison(value) {
        if (value.startsWith(">=")) return { op: ">=", operand: value.slice(2) };
        if (value.startsWith("<=")) return { op: "<=", operand: value.slice(2) };
        if (value.startsWith(">")) return { op: ">", operand: value.slice(1) };
        if (value.startsWith("<")) return { op: "<", operand: value.slice(1) };
        return null;
    }

    // Reuses `/sort`'s own comparator (`compareFieldValues`) so a value and
    // an operand agree on what "greater" means the same way a sort and a
    // filter should never disagree about it (query-dsl.md's "any sort UI a
    // picker offers must share this one comparator" - the reverse case of
    // that rule: one comparator, every numeric-shaped operation). Only
    // means anything for the two shapes `compareFieldValues` itself
    // recognises (plain integers, age buckets); `false` for anything else
    // (a comparison against a field that isn't currently that shape, or an
    // operand that isn't) - degrades to "never matches" rather than
    // silently falling back to a literal `">4"` substring search, which
    // would almost always also be "never matches" in practice but for the
    // wrong reason.
    function _compareMatches(v, op, operand) {
        const comparable = (root._isPlainInt(v) && root._isPlainInt(operand))
            || (root._isAgeBucket(v) && root._isAgeBucket(operand));
        if (!comparable) return false;
        const cmp = root.compareFieldValues(v, operand);
        switch (op) {
        case ">": return cmp > 0;
        case "<": return cmp < 0;
        case ">=": return cmp >= 0;
        case "<=": return cmp <= 0;
        }
        return false;
    }

    // True if `entry` (shape: {haystack, fields:{name:value}}) survives
    // `query` (picker.rs's listbox filter_func). `fields[f]` absent (not
    // just empty) never matches -- same "absent, not empty" contract
    // Entry::fields keeps throughout.
    function matches(entry, query) {
        for (const t of query.fieldTerms) {
            const cmp = root._parseComparison(t.value);
            let ok = false;
            for (const f of t.fields) {
                const v = entry.fields[f];
                if (v === undefined) continue;
                if (cmp !== null ? root._compareMatches(v, cmp.op, cmp.operand) : root.substr(t.value, v)) {
                    ok = true; break;
                }
            }
            if (ok === !!t.neg) return false;
        }
        for (const w of (query.negWords || []))
            if (entry.haystack.indexOf(w) >= 0) return false;
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

    // query-dsl.md's `/ft`/`/at`/`/rt` semantics: one running ordered set
    // that starts at `defaultColumns`, then each `columnOps` entry applied
    // left to right (`ft` intersects, `at` unions onto the end, `rt`
    // subtracts) - "adding a column that's already shown, or
    // removing/filtering one that's not, is a silent no-op" falls out of
    // using plain array membership throughout. `referencedFields` (Auto-
    // shown filter fields) is folded in last and is always additive, never
    // a replacement, same as every other consumer.
    function activeColumns(query, fieldNames, defaultColumns) {
        let cols = defaultColumns.slice();
        for (const op of query.columnOps) {
            const matched = root.resolveFields(op.path, fieldNames);
            if (op.verb === "ft") cols = cols.filter(c => matched.indexOf(c) >= 0);
            else if (op.verb === "at") { for (const m of matched) if (cols.indexOf(m) < 0) cols.push(m); }
            else if (op.verb === "rt") cols = cols.filter(c => matched.indexOf(c) < 0);
        }
        for (const f of root.referencedFields(query))
            if (cols.indexOf(f) < 0) cols.push(f);
        return cols;
    }

    function _isPlainInt(v) { return /^\d+$/.test(v); }
    function _isAgeBucket(v) { return /^\d+[smhd]$/.test(v); }
    function _ageSeconds(v) {
        return parseInt(v, 10) * ({ s: 1, m: 60, h: 3600, d: 86400 })[v[v.length - 1]];
    }

    // query-dsl.md's "Sort comparison, precisely" -- `compare_field_values`.
    // Both sides sniffed by shape: plain integers compare numerically (a
    // display-formatted string like "58k" doesn't match `_isPlainInt` and
    // falls through to lexicographic, same as the spec calls out), age
    // buckets ("5m", "3h") compare by real seconds, everything else
    // lexicographic. A field missing on one side (`entry.fields` contract:
    // absent, not empty) sorts last regardless of direction -- there's no
    // "the trap" (below) equivalent for "nothing to compare".
    function compareFieldValues(a, b) {
        if (a === undefined && b === undefined) return 0;
        if (a === undefined) return 1;
        if (b === undefined) return -1;
        if (root._isAgeBucket(a) && root._isAgeBucket(b)) return root._ageSeconds(a) - root._ageSeconds(b);
        if (root._isPlainInt(a) && root._isPlainInt(b)) return parseInt(a, 10) - parseInt(b, 10);
        return a < b ? -1 : (a > b ? 1 : 0);
    }

    // query-dsl.md's `/sort`/`/reverse` application -- `entries` already
    // filtered (`matches`), returns a new re-ordered array. An unresolvable
    // or ambiguous sort path (any chain segment not resolving to exactly
    // one field) makes the *whole* `/sort` inert, per spec -- falls back to
    // `entries`' own incoming order (backend recency), which `/reverse` can
    // still flip on its own.
    function applySort(entries, query, fieldNames) {
        let result = entries;
        if (query.sort) {
            const keys = query.sort.paths.map(p => root.resolveFields(p, fieldNames));
            if (keys.every(k => k.length === 1)) {
                const flatKeys = keys.map(k => k[0]);
                const dirSign = query.sort.direction === "descending" ? -1 : 1;
                result = entries.slice().sort((ea, eb) => {
                    for (const k of flatKeys) {
                        const a = ea.fields[k], b = eb.fields[k];
                        // The direction trap (query-dsl.md): an age-bucket
                        // field's stored value is seconds-*ago*, so
                        // "ascending" (oldest first, chronological) is
                        // *descending* by that raw number - invert the
                        // requested direction whenever either side looks
                        // like an age bucket.
                        const ageShaped = (a !== undefined && root._isAgeBucket(a)) || (b !== undefined && root._isAgeBucket(b));
                        const cmp = root.compareFieldValues(a, b) * (ageShaped ? -dirSign : dirSign);
                        if (cmp !== 0) return cmp;
                    }
                    return 0;
                });
            }
        }
        if (query.reverse) result = result.slice().reverse();
        return result;
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

    // Verbs that take exactly one type-path argument and nothing else --
    // `/fv` also takes a path but continues on into a value stage, so it's
    // handled on its own below.
    readonly property var _pathOnlyVerbs: ["ft", "at", "rt", "s"]

    // picker.rs's completion_context, extended with via-path stages --
    // null (nothing to complete), or one of:
    //   {kind:"verb", start, frag}
    //   {kind:"field", start, frag, via, verb}  -- typing a field/path name
    //   {kind:"value", start, frag, field}      -- typing "field:value"'s value
    //   {kind:"bareValue", start, frag, field}  -- typing a via-typed value
    // `via` distinguishes the two ways to reach "field" stage: `/fv frag`
    // (space form, GTK pickers land the ":" form on accept) vs `/fv/frag`
    // (via form, still forming its own path segment) -- see acceptText.
    // `verb` is which verb the field/path belongs to: `/fv`'s field stage
    // leads into a value (colon or bareValue); `/ft`/`/at`/`/rt`/`/s`'s
    // path stage is terminal -- a bare field name, no value ever follows
    // (added 2026-09-28 alongside those verbs going live -- see acceptText).
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
                const verb = root._canon(name);
                // /fv and the four column/sort path-taking verbs all reach
                // a field/path stage this way; /reverse takes no path, and
                // an unrecognised verb name isn't a command at all.
                if (verb !== "fv" && root._pathOnlyVerbs.indexOf(verb) < 0) return null;
                return { kind: "field", start: start + 1 + name.length + 1, frag: viaFrag, via: true, verb: verb };
            }
            return { kind: "verb", start: start, frag: rest };
        }

        const open = root._replay(context);
        if (open === null) return null; // fresh phrase text
        if (open.verb !== "fv") {
            // /ft, /at, /rt, /s (space form): one bare path argument, no
            // value stage -- once it has one (open.args.length === 1, from
            // _replay closing the verb the instant it sees an argument
            // token), there's nothing left to complete.
            if (root._pathOnlyVerbs.indexOf(open.verb) < 0 || open.args.length !== 0) return null;
            return { kind: "field", start: start, frag: frag, via: false, verb: open.verb };
        }
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
        return { kind: "field", start: start, frag: frag, via: false, verb: "fv" };
    }

    // picker.rs's verb_stage_universe, extended once `/ft`/`/at`/`/rt`/`/s`
    // went live (2026-09-28): the six bare verb shorts, plus every
    // path-taking verb (all but `/reverse`, which takes no path) crossed
    // with every field name (query-dsl.md "Verb-stage depth" -- this
    // picker's flat `fieldNames` stands in for the type registry a
    // group-aware consumer like winswitch draws deep candidates from).
    function verbStageUniverse(fieldNames) {
        const out = ["fv", "ft", "at", "rt", "s", "rv"];
        for (const v of ["fv", "ft", "at", "rt", "s"])
            for (const f of fieldNames) out.push(v + "/" + f);
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
            // /ft, /at, /rt, /s take a bare path with no value to follow --
            // always land a trailing space, via or space form alike, never
            // the colon /fv's field stage lands (that colon exists only to
            // introduce /fv's own value stage, which these verbs don't have).
            if (ctx.verb !== "fv") return prefix + chosen + " ";
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

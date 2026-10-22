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
// `/ft` `/at` `/rt` `/s` (columns + sort) went live 2026-09-28 --
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
        "fv", "ft", "at", "rt", "s",
        "filter-value", "filter-type", "add-type", "remove-type", "sort"
    ]

    // picker.rs's verb_meta -- long-form alias + one-line description, for
    // marginalia-style autocomplete hints (query-dsl.md "Suggestion row
    // anatomy"). Keyed without the leading "/".
    readonly property var verbInfo: ({
        "fv": { alias: "/filter-value", desc: "keep rows whose value matches (substring)" },
        "ft": { alias: "/filter-type",  desc: "show only the matching columns" },
        "at": { alias: "/add-type",     desc: "add the matching columns" },
        "rt": { alias: "/remove-type",  desc: "drop the matching columns" },
        "s":  { alias: "/sort",         desc: "order rows by one field, optional asc / desc" }
    })

    // Case-insensitive substring containment; empty needle always matches
    // (picker.rs's substr).
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
        "remove-type": "rt", "sort": "s"
    })
    readonly property var _shortForms: ["fv", "ft", "at", "rt", "s"]
    // "" (the empty verb slot of "//path") is the default verb /fv -
    // query-dsl.md "Default verb". Only reachable with a via slash after
    // it; tokVerb guards the bare-"/" case.
    function _canon(name) {
        if (name === "") return "fv";
        if (root._shortForms.indexOf(name) >= 0) return name;
        return root._aliasToShort[name] || null;
    }

    // {verb, via, dir, bad} for a real verb token (verb always the canonical
    // short form), or null if `tok` isn't one (query-dsl.md "Grammar"): `via`
    // is the keys part, `dir` the third part (/s only), `bad` marks a
    // malformed token (too many parts): inert.
    function tokVerb(tok) {
        if (tok.leadQuote || tok.text[0] !== "/") return null;
        const parts = tok.text.slice(1).split("/");
        // "//keys": empty verb slot defaults to /fv
        const v = parts[0] === "" ? (parts.length >= 2 ? "fv" : null) : root._canon(parts[0]);
        if (v === null) return null;
        return { verb: v, via: parts.length >= 2 ? parts[1] : null,
                 dir: parts.length === 3 ? parts[2] : null,
                 bad: parts.length > (v === "s" ? 3 : 2) };
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
        let qc = "";
        let quoted = false;
        // Leading "!" negates the token (query-dsl.md "Negation"); not part
        // of it, so `start` stays on the char after it.
        let neg = false;
        for (let i = 0; i < query.length; i++) {
            const c = query[i];
            if (c === "!" && start < 0 && !neg) { neg = true; continue; }
            // `'` only opens a quote at the start of a token or of a scoped
            // value (after ":"), so apostrophes inside words stay text.
            const opens = c === "\"" || (c === "'" && (start < 0 || query[i - 1] === ":"));
            if (inQuotes ? c === qc : opens) {
                if (start < 0) leadQuote = true;
                if (!inQuotes) qc = c;
                else quoted = true; // closed: an unterminated quote is still being typed
                inQuotes = !inQuotes;
                if (start < 0) start = i;
                continue;
            }
            if (/\s/.test(c) && !inQuotes) {
                if (start >= 0) {
                    tokens.push({ start: start, text: cur, leadQuote: leadQuote, quoted: quoted, neg: neg });
                    cur = ""; start = -1; leadQuote = false; quoted = false;
                }
                neg = false;
                continue;
            }
            if (start < 0) start = i;
            cur += c;
        }
        if (start >= 0) tokens.push({ start: start, text: cur, leadQuote: leadQuote, quoted: quoted, neg: neg });
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

    // query-dsl.md "Keys": `keys` is a comma-separated list; per key a field
    // whose name equals it wins alone, else every field containing it as a
    // substring; unioned across the list, in `fieldNames` order.
    function resolveFields(keys, fieldNames) {
        const hit = {};
        for (const key of String(keys).toLowerCase().split(",")) {
            if (key.length === 0) continue;
            const exact = fieldNames.filter(f => f.toLowerCase() === key);
            for (const f of (exact.length > 0 ? exact : fieldNames.filter(f => root.substr(key, f))))
                hit[f] = true;
        }
        return fieldNames.filter(f => hit[f]);
    }

    // `quoted` terms ("5" / '5') must stand alone, not sit inside a longer
    // run (see `substrIdx`): they go to `exactWords`/`negExact`, or carry
    // `exact` on a fieldTerm, instead of joining the plain phrase.
    function _pushFvArg(arg, fieldNames, fieldTerms, words, neg, negWords, quoted, exactWords, negExact) {
        if (quoted) (neg ? negExact : exactWords).push(arg);
        else if (neg) negWords.push(arg);
        else words.push(arg);
    }

    // `/fv/keys value` / `//keys value`: a scoped term over the resolved fields.
    function _pushScoped(keys, value, fieldNames, fieldTerms, neg, quoted) {
        fieldTerms.push({ fields: root.resolveFields(keys, fieldNames), value: value, neg: !!neg, exact: !!quoted });
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
        if ("ascending".indexOf(tok) === 0) return "ascending";
        if ("descending".indexOf(tok) === 0) return "descending";
        return null;
    }

    function parse(text, fieldNames) {
        const toks = root.tokenize(text);
        const fieldTerms = [];
        const words = [];
        const negWords = []; // each "!word": the row must NOT contain it
        const exactWords = []; // quoted words: must stand alone (see _pushFvArg)
        const negExact = [];
        const openFields = [];
        const columnOps = [];
        let sort = null;
        let i = 0;
        while (i < toks.length) {
            const tok = toks[i];
            const tv = root.tokVerb(tok);
            if (tv === null) {
                const rest = (!tok.leadQuote && tok.text[0] === "/") ? tok.text.slice(1) : null;
                const midTyping = rest !== null && root.isVerbPrefix(rest);
                if (!midTyping) {
                    // real word, or a literal "/usr/bin"
                    if (tok.quoted) (tok.neg ? negExact : exactWords).push(tok.text);
                    else (tok.neg ? negWords : words).push(tok.text);
                }
                i++;
                continue;
            }
            i++;
            // keyless or malformed: inert, takes no argument ("/fv foo" is just "foo")
            if (tv.via === null || tv.bad) continue;
            const via = tv.via.toLowerCase();
            const keysTyped = via.replace(/,/g, "").length > 0;
            // "!" only means something on a row filter: "!/s", "!/ft" ... parse but change nothing.
            const verbNeg = !!tok.neg;
            if (verbNeg && tv.verb !== "fv") continue;
            if (tv.verb === "fv") {
                if (i < toks.length && !root.startsCmd(toks[i])) {
                    root._pushScoped(via, toks[i].text, fieldNames, fieldTerms, verbNeg || toks[i].neg, toks[i].quoted);
                    i++;
                } else if (keysTyped) {
                    // value still pending: a no-op for filtering, but the named
                    // fields are Auto-shown at once (`openFields`, see referencedFields)
                    for (const f of root.resolveFields(via, fieldNames))
                        if (openFields.indexOf(f) < 0) openFields.push(f);
                }
            } else if (tv.verb === "ft" || tv.verb === "at" || tv.verb === "rt") {
                if (keysTyped) columnOps.push({ verb: tv.verb, path: via });
            } else if (tv.verb === "s" && keysTyped) {
                let direction = "ascending";
                if (tv.dir !== null) {
                    const d = root._sortDirection(tv.dir.toLowerCase());
                    if (d === null) continue; // bad direction: the whole /s is inert
                    direction = d;
                }
                sort = { paths: via.split(",").filter(p => p.length > 0), direction: direction };
            }
        }
        return {
            fieldTerms: fieldTerms, text: words.join(" ").toLowerCase(), negWords: negWords.map(w => w.toLowerCase()), exactWords: exactWords, negExact: negExact, openFields: openFields,
            columnOps: columnOps, sort: sort
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
                if (cmp !== null ? root._compareMatches(v, cmp.op, cmp.operand) : root.substr(t.value, v, t.exact)) {
                    ok = true; break;
                }
            }
            if (ok === !!t.neg) return false;
        }
        for (const w of (query.negWords || []))
            if (entry.haystack.indexOf(w) >= 0) return false;
        for (const w of (query.negExact || []))
            if (root.substr(w, entry.haystack, true)) return false;
        for (const w of (query.exactWords || []))
            if (!root.substr(w, entry.haystack, true)) return false;
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

    // query-dsl.md's `/sort` application -- `entries` already
    // filtered (`matches`), returns a new re-ordered array. An unresolvable
    // or ambiguous sort path (any chain segment not resolving to exactly
    // one field) makes the *whole* `/sort` inert, per spec -- falls back to
    // `entries`' own incoming order (backend recency).
    function applySort(entries, query, fieldNames) {
        let result = entries;
        if (query.sort) {
            // fuzzy keys expand to every matching field, alphabetical (`/s/pa` = pages,path); a key that
            // names nothing makes the whole /s inert (query-dsl.md "Keys")
            const keys = query.sort.paths.map(p => root.resolveFields(p, fieldNames).slice().sort());
            if (keys.every(k => k.length > 0)) {
                const flatKeys = [];
                for (const k of keys) for (const f of k) if (flatKeys.indexOf(f) < 0) flatKeys.push(f);
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
        return result;
    }

    // Replays `context` (tokens before the fragment being completed) to the one
    // state that matters here: a `/fv/keys` still waiting for its value
    // (null | {verb:"fv", args:[keys]}); everything else is self-contained.
    function _replay(context) {
        let open = null;
        for (const tok of context) {
            if (open !== null) {
                if (root.startsCmd(tok)) open = null; // reprocess this token as a fresh command
                else { open = null; continue; }       // the value is consumed
            }
            const tv = root.tokVerb(tok);
            if (tv !== null && !tv.bad && tv.verb === "fv" && tv.via !== null && tv.via.replace(/,/g, "").length > 0)
                open = { verb: "fv", args: [tv.via] };
        }
        return open;
    }

    // Completion stages (query-dsl.md "Autocompletion"), null (nothing to
    // complete) or one of:
    //   {kind:"verb", start, frag}
    //   {kind:"field", start, frag, verb}      -- a key fragment (after the last comma)
    //   {kind:"dir", start, frag}              -- /s/keys/<direction>
    //   {kind:"bareValue", start, frag, field} -- the value after /fv/keys
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
            const parts = frag.slice(1).split("/");
            if (parts.length === 1) return { kind: "verb", start: start, frag: parts[0] };
            const verb = parts[0] === "" ? "fv" : root._canon(parts[0]);
            if (verb === null) return null;
            if (parts.length === 2) {
                const comma = parts[1].lastIndexOf(",");
                return { kind: "field", start: start + 1 + parts[0].length + 1 + comma + 1,
                         frag: parts[1].slice(comma + 1), verb: verb };
            }
            if (parts.length === 3 && verb === "s")
                return { kind: "dir", start: start + frag.length - parts[2].length, frag: parts[2] };
            return null;
        }

        const open = root._replay(context);
        if (open === null) return null; // fresh phrase text
        const resolved = root.resolveFields(open.args[0], fieldNames);
        if (resolved.length !== 1) return null; // several (or no) fields: no single value set
        return { kind: "bareValue", start: start, field: resolved[0], frag: frag };
    }

    // picker.rs's verb_stage_universe, extended once `/ft`/`/at`/`/rt`/`/s`
    // went live (2026-09-28): the five bare verb shorts, plus every
    // path-taking verb crossed
    // with every field name (query-dsl.md "Verb-stage depth" -- this
    // picker's flat `fieldNames` stands in for the type registry a
    // group-aware consumer like winswitch draws deep candidates from).
    function verbStageUniverse(fieldNames) {
        const out = ["fv", "ft", "at", "rt", "s"];
        for (const v of ["fv", "ft", "at", "rt", "s"])
            for (const f of fieldNames) out.push(v + "/" + f);
        return out;
    }

    function verbSuggestions(frag, fieldNames) {
        return root.verbStageUniverse(fieldNames).filter(v => root.substr(frag, v));
    }

    function dirSuggestions(frag) {
        return [["asc", "ascending"], ["desc", "descending"]].filter(d => d[1].indexOf(frag.toLowerCase()) === 0).map(d => d[0]);
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
    // (one item from the candidate list for `ctx`) is accepted.
    function acceptText(text, ctx, chosen) {
        const prefix = text.slice(0, ctx.start);
        switch (ctx.kind) {
        case "verb":
            // chosen is "verb" or "verb/key": lands "/ft " or "/fv/key " alike
            return prefix + "/" + chosen + (chosen.indexOf("/") >= 0 && chosen.slice(0, chosen.indexOf("/")) !== "fv" ? "" : " ");
        case "field":
            // /fv takes a value next; the other verbs end at their keys
            // (a "," or "/dir" can still follow)
            return prefix + chosen + (ctx.verb === "fv" ? " " : "");
        case "dir":
            return prefix + chosen + " ";
        case "bareValue": {
            const value = /\s/.test(chosen) ? "\"" + chosen + "\"" : chosen;
            return prefix + value + " ";
        }
        }
        return text;
    }
}

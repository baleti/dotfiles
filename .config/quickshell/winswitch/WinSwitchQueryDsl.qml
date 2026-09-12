pragma Singleton
import QtQuick

// The shared picker query DSL (~/.config/docs/query-dsl.md), ported to JS
// for the alt-tab grid -- the "8th" hand-written copy of this grammar
// (GTK winswitch's own query.rs, picker.rs, rofi, QueryDsl.qml for the
// launcher/RSS reader, clipboard-picker, ...), following QueryDsl.qml's
// own conventions where the shape matches, but a full standalone port
// rather than a wrapper around it: this picker has *groups* (`tmux.*`,
// `claude.*`) and *columns* that actually change what's shown, neither of
// which QueryDsl.qml's launcher-flavored grammar needs, and bolting group
// awareness onto a shared implementation would touch nearly every
// function anyway. Ported from `~/.config/hypr/winswitch/src/query.rs`
// (the same crate's Rust original) function-by-function; comments below
// point back to their Rust counterpart rather than re-explaining from
// scratch.
//
// A resolved field is `{ kind: "flat", name }` or
// `{ kind: "group", group, sub }` (query.rs's `ResolvedField`). Group
// subfield values are read off the enrich NDJSON payload's own key
// naming (`tmux_session`, `claude_contents`, ...) via `group + "_" + sub`,
// which is exactly how `enrich.rs`'s `TmuxClaudeMeta` fields are already
// named -- see `groupSubValue`.
QtObject {
    id: root

    // --- schema (query.rs's COLUMNS / GROUPS / GROUP_DEFAULT_SUB) --------
    readonly property var columns: ["title", "workspace", "pid"]
    readonly property var groupOrder: ["tmux", "claude"]
    readonly property var groups: ({
        tmux: ["session", "window", "title"],
        claude: ["title", "path", "session", "time", "contents"]
    })
    readonly property var groupDefaultSub: ({ tmux: "title", claude: "contents" })
    readonly property var directions: ["ascending", "descending"]
    readonly property var defaultColumns: [{ kind: "flat", name: "title" }]

    readonly property var shortVerbs: ["/fv", "/ft", "/at", "/rt", "/s", "/rv"]
    readonly property var verbAliases: ({
        "/filter-value": "/fv", "/filter-type": "/ft", "/add-type": "/at",
        "/remove-type": "/rt", "/sort": "/s", "/reverse": "/rv"
    })
    readonly property var verbInfo: ({
        "/fv": { long: "/filter-value", desc: "keep windows whose value matches (substring)" },
        "/ft": { long: "/filter-type",  desc: "show only the matching columns" },
        "/at": { long: "/add-type",     desc: "add the matching columns" },
        "/rt": { long: "/remove-type",  desc: "drop the matching columns" },
        "/s":  { long: "/sort",         desc: "order windows by one field, optional asc / desc" },
        "/rv": { long: "/reverse",      desc: "flip the current order" }
    })
    readonly property var verbForms: [
        "fv", "ft", "at", "rt", "s", "rv",
        "filter-value", "filter-type", "add-type", "remove-type", "sort", "reverse"
    ]
    // All resolvable type paths (flat types, groups, and group.subfields),
    // bare, no "*" -- the full depth the Verb stage's completion crosses
    // with every path-taking verb (see query-dsl.md's "Verb-stage depth").
    function allPaths() {
        const out = root.columns.slice();
        for (const g of root.groupOrder) {
            out.push(g);
            for (const s of root.groupSubsOf(g))
                out.push(g + "." + s);
        }
        return out;
    }
    // The full Verb-stage vocabulary: the six bare verb shorts plus every
    // path-taking verb crossed with every resolvable path ("fv/workspace",
    // "fv/claude.title", ...) -- see query-dsl.md's "Verb-stage depth".
    // Exposed rather than inlined in completionCandidates so WinSwitch.qml's
    // Ctrl+Space AND-narrowing mode can filter it with its own
    // multiple-fragment rule instead of completionCandidates' single one.
    function verbStageUniverse() {
        const bareVerbs = root.shortVerbs.map(v => v.slice(1));
        const deep = [];
        for (const v of bareVerbs) {
            if (!root.takesPath("/" + v)) continue;
            for (const p of root.allPaths())
                deep.push(v + "/" + p);
        }
        return bareVerbs.concat(deep);
    }
    // One-line description of a type path, for the type-path autocomplete
    // stage -- mirrors ui.rs's `type_desc`.
    readonly property var typeDescs: ({
        "title": "the window title",
        "workspace": "the Hyprland workspace",
        "pid": "the process id",
        "tmux": "tmux session / window on this terminal",
        "tmux.session": "tmux session name",
        "tmux.window": "tmux window name",
        "tmux.title": "tmux window title",
        "claude": "Claude Code session on this terminal",
        "claude.title": "Claude Code session title",
        "claude.path": "Claude Code working directory",
        "claude.session": "Claude Code session id",
        "claude.time": "how long ago the transcript last changed",
        "claude.contents": "Claude Code transcript text"
    })

    function fieldKey(f) { return f.kind === "flat" ? f.name : f.group + "." + f.sub; }
    function fieldsEqual(a, b) {
        if (!a || !b || a.kind !== b.kind) return false;
        return a.kind === "flat" ? a.name === b.name : a.group === b.group && a.sub === b.sub;
    }
    function takesPath(verb) { return verb !== "/rv"; }

    // --- tokenizer (query.rs's Tok / tokenize) ----------------------------
    // Unlike QueryDsl.qml's own tokenize, this keeps each token's byte
    // offset (`start`) -- needed for `commandSpans` and `completionContext`,
    // neither of which the launcher needs.
    function tokenize(query) {
        const tokens = [];
        let cur = "";
        let start = -1;
        let leadQuote = false;
        let inQuotes = false;
        for (let i = 0; i < query.length; i++) {
            const c = query[i];
            if (c === '"') {
                if (start < 0) leadQuote = true;
                inQuotes = !inQuotes;
                if (start < 0) start = i;
                continue;
            }
            if (/\s/.test(c) && !inQuotes) {
                if (start >= 0) {
                    tokens.push({ start, text: cur, leadQuote });
                    cur = "";
                    start = -1;
                    leadQuote = false;
                }
                continue;
            }
            if (start < 0) start = i;
            cur += c;
        }
        if (start >= 0)
            tokens.push({ start, text: cur, leadQuote });
        return tokens;
    }

    function _canonName(name) {
        if (root.shortVerbs.indexOf("/" + name) >= 0) return "/" + name;
        if (root.verbAliases["/" + name]) return root.verbAliases["/" + name];
        return null;
    }

    // query.rs::tok_verb -- { verb, via } or null.
    function tokVerb(tok) {
        if (tok.leadQuote || tok.text[0] !== "/") return null;
        const rest = tok.text.slice(1);
        const slash = rest.indexOf("/");
        if (slash >= 0) {
            const v = root._canonName(rest.slice(0, slash));
            return v === null ? null : { verb: v, via: rest.slice(slash + 1) };
        }
        const v = root._canonName(rest);
        return v === null ? null : { verb: v, via: null };
    }

    function isVerbPrefix(s) {
        return s.length > 0 && root.verbForms.some(f => f.indexOf(s) === 0);
    }

    function startsCommand(tok) {
        if (tok.leadQuote || tok.text[0] !== "/") return false;
        const rest = tok.text.slice(1);
        const slash = rest.indexOf("/");
        const name = slash >= 0 ? rest.slice(0, slash) : rest;
        return root._canonName(name) !== null || root.isVerbPrefix(rest);
    }

    function _isDirectionLike(tok) {
        const d = tok.toLowerCase();
        if (d.length === 0) return false;
        return "ascending".indexOf(d) === 0 || "descending".indexOf(d) === 0;
    }
    function _dirOf(tok) {
        return "descending".indexOf(tok.toLowerCase()) === 0 ? "desc" : "asc";
    }
    function parseDirection(tok) {
        return root._isDirectionLike(tok) ? root._dirOf(tok) : null;
    }
    function resolveDirections(frag) {
        return root.directions.filter(d => root.substr(frag, d));
    }

    // --- substring matching, schema lookups -------------------------------
    function substr(needle, hay) {
        return hay.toLowerCase().indexOf(String(needle).toLowerCase()) >= 0;
    }
    function groupDefaultSubOf(g) { return root.groupDefaultSub[g] || ""; }
    function groupSubsOf(g) { return root.groups[g] || []; }
    function resolveGroups(seg) { return root.groupOrder.filter(g => root.substr(seg, g)); }
    function resolveGroupSubs(g, seg) { return root.groupSubsOf(g).filter(s => root.substr(seg, s)); }

    function columnValue(win, c) {
        switch (c) {
        case "title": return win.title || "";
        case "workspace": return win.workspace || "";
        case "pid": return String(win.pid ?? "");
        }
        return "";
    }
    // Group subfield values come straight off the enrich NDJSON payload's
    // own key naming (`tmux_session`, `claude_contents`, ...) -- see this
    // file's own doc.
    function groupSubValue(meta, g, s) {
        if (!meta) return "";
        return meta[g + "_" + s] || "";
    }
    function groupHasAnyValue(meta, g) {
        return root.groupSubsOf(g).some(s => root.groupSubValue(meta, g, s) !== "");
    }

    // --- path resolution (query.rs's resolve_filter_fields / _column_fields / _one) --
    function _pathSegs(path) {
        const dot = path.indexOf(".");
        return dot < 0 ? [path, null] : [path.slice(0, dot), path.slice(dot + 1)];
    }

    function resolveFilterFields(path) {
        const [gSeg, sSeg] = root._pathSegs(path);
        if (sSeg === "*") {
            const out = [];
            for (const g of root.resolveGroups(gSeg))
                for (const s of root.groupSubsOf(g))
                    out.push({ kind: "group", group: g, sub: s });
            return out;
        }
        if (sSeg !== null) {
            const out = [];
            for (const g of root.resolveGroups(gSeg))
                for (const s of root.resolveGroupSubs(g, sSeg))
                    out.push({ kind: "group", group: g, sub: s });
            return out;
        }
        const out = root.columns.filter(c => root.substr(gSeg, c)).map(c => ({ kind: "flat", name: c }));
        for (const g of root.resolveGroups(gSeg))
            out.push({ kind: "group", group: g, sub: root.groupDefaultSubOf(g) });
        return out;
    }

    function resolveColumnFields(path) {
        const [gSeg, sSeg] = root._pathSegs(path);
        if (sSeg === "*") {
            const out = [];
            for (const g of root.resolveGroups(gSeg))
                for (const s of root.groupSubsOf(g))
                    out.push({ kind: "group", group: g, sub: s });
            return out;
        }
        if (sSeg !== null) {
            const out = [];
            for (const g of root.resolveGroups(gSeg))
                for (const s of root.resolveGroupSubs(g, sSeg))
                    out.push({ kind: "group", group: g, sub: s });
            return out;
        }
        const out = root.columns.filter(c => root.substr(gSeg, c)).map(c => ({ kind: "flat", name: c }));
        for (const g of root.resolveGroups(gSeg))
            for (const s of root.groupSubsOf(g))
                out.push({ kind: "group", group: g, sub: s });
        return out;
    }

    // The single field a path names, or null if ambiguous/unknown/`*`.
    function resolveOne(path) {
        const [gSeg, sSeg] = root._pathSegs(path);
        if (sSeg === "*") return null;
        if (sSeg !== null) {
            const gs = root.resolveGroups(gSeg);
            if (gs.length !== 1) return null;
            const subs = root.resolveGroupSubs(gs[0], sSeg);
            if (subs.length !== 1) return null;
            return { kind: "group", group: gs[0], sub: subs[0] };
        }
        const c = root.columns.filter(x => root.substr(gSeg, x)).map(x => ({ kind: "flat", name: x }));
        for (const g of root.resolveGroups(gSeg))
            c.push({ kind: "group", group: g, sub: root.groupDefaultSubOf(g) });
        return c.length === 1 ? c[0] : null;
    }

    // --- command parsing (query.rs's filter_term / parse) -----------------
    function filterTerm(arg) {
        const colon = arg.indexOf(":");
        if (colon >= 0)
            return { kind: "scoped", path: arg.slice(0, colon), value: arg.slice(colon + 1) };
        if (arg.indexOf(".") < 0 && root.resolveGroups(arg).length > 0)
            return { kind: "exists", seg: arg };
        return { kind: "free", text: arg };
    }

    // -> { filters: [...], colOps: [{op,path,isVia}], sort: {fields,dir}|null, reverse }
    function parse(query) {
        const toks = root.tokenize(query);
        const out = { filters: [], colOps: [], sort: null, reverse: false };
        let i = 0;
        while (i < toks.length) {
            const tok = toks[i];
            const tv = root.tokVerb(tok);
            if (tv === null) {
                const midTyping = !tok.leadQuote && tok.text[0] === "/" && root.isVerbPrefix(tok.text.slice(1));
                if (!midTyping)
                    out.filters.push(root.filterTerm(tok.text));
                i++;
                continue;
            }
            i++;
            const verb = tv.verb;

            if (tv.via !== null) {
                const via = tv.via;
                if (verb === "/fv") {
                    if (i < toks.length && !root.startsCommand(toks[i])) {
                        out.filters.push(root.filterTerm(via + ":" + toks[i].text));
                        i++;
                    } else if (via.indexOf(".") < 0 && root.resolveGroups(via).length > 0) {
                        out.filters.push({ kind: "exists", seg: via });
                    } else if (root.resolveFilterFields(via).length > 0) {
                        // Via path alone, no value yet, resolving to a
                        // flat type or dotted group subfield (a bare
                        // group is the "exists" branch above) - reuse the
                        // "scoped" term shape with an empty value: an
                        // empty needle always substring-matches (see
                        // `substr`), so this stays a genuine no-op for row
                        // filtering exactly like today, but
                        // `filterReferencedFields` (below) already knows
                        // how to read a "scoped" term's `path` and now
                        // shows the field the moment the command names
                        // it, not just once a value narrows anything
                        // (query-dsl.md "Auto-shown filter fields",
                        // updated 2026-09-12). An unresolvable path (typo,
                        // still mid-typing) hits neither branch, so
                        // nothing is pushed and nothing shows - unchanged.
                        out.filters.push({ kind: "scoped", path: via, value: "" });
                    }
                } else if (verb === "/ft" || verb === "/at" || verb === "/rt") {
                    const op = verb === "/ft" ? "filter" : (verb === "/at" ? "add" : "remove");
                    out.colOps.push({ op, path: via, isVia: true });
                } else if (verb === "/s") {
                    let dir = "asc";
                    if (i < toks.length && !root.startsCommand(toks[i])) {
                        const d = root.parseDirection(toks[i].text);
                        if (d !== null) { dir = d; i++; }
                    }
                    const fields = via.split("/").map(p => root.resolveOne(p));
                    if (fields.every(f => f !== null) && fields.length > 0)
                        out.sort = { fields, dir };
                } else if (verb === "/rv") {
                    out.reverse = true;
                }
                continue;
            }

            const args = [];
            const maxArgs = verb === "/rv" ? 0 : (verb === "/s" ? 2 : 1);
            while (args.length < maxArgs && i < toks.length && !root.startsCommand(toks[i])) {
                if (verb === "/s" && args.length === 1 && root.parseDirection(toks[i].text) === null)
                    break;
                args.push(toks[i]);
                i++;
            }

            if (verb === "/fv") {
                if (args.length > 0) out.filters.push(root.filterTerm(args[0].text));
            } else if (verb === "/ft" || verb === "/at" || verb === "/rt") {
                if (args.length > 0) {
                    const op = verb === "/ft" ? "filter" : (verb === "/at" ? "add" : "remove");
                    out.colOps.push({ op, path: args[0].text, isVia: false });
                }
            } else if (verb === "/s") {
                if (args.length > 0) {
                    const field = root.resolveOne(args[0].text);
                    if (field !== null) {
                        const dir = args.length > 1 ? (root.parseDirection(args[1].text) || "asc") : "asc";
                        out.sort = { fields: [field], dir };
                    }
                }
            } else if (verb === "/rv") {
                out.reverse = true;
            }
        }
        return out;
    }

    // --- axis 1: row filtering ---------------------------------------------
    function fieldValue(win, meta, field) {
        return field.kind === "flat" ? root.columnValue(win, field.name) : root.groupSubValue(meta, field.group, field.sub);
    }

    function _termMatches(win, meta, term) {
        if (term.kind === "free") {
            const haystack = (win.title || "") + " " + (win.class || "");
            return root.substr(term.text, haystack);
        }
        if (term.kind === "scoped") {
            const fields = root.resolveFilterFields(term.path);
            return fields.length > 0 && fields.some(f => root.substr(term.value, root.fieldValue(win, meta, f)));
        }
        // "exists"
        const gs = root.resolveGroups(term.seg);
        return gs.length > 0 && gs.some(g => root.groupHasAnyValue(meta, g));
    }

    function matchesStr(win, meta, query) {
        if (query.length === 0) return true;
        return root.parse(query).filters.every(t => root._termMatches(win, meta, t));
    }

    // --- axis 2: column visibility ------------------------------------------
    function everyField() {
        const out = root.columns.map(c => ({ kind: "flat", name: c }));
        for (const g of root.groupOrder)
            for (const s of root.groupSubsOf(g))
                out.push({ kind: "group", group: g, sub: s });
        return out;
    }

    function globMatch(pattern, value) {
        pattern = pattern.toLowerCase();
        value = value.toLowerCase();
        if (pattern.indexOf("*") < 0)
            return value.indexOf(pattern) >= 0;
        const startsWild = pattern.startsWith("*");
        const endsWild = pattern.endsWith("*");
        const parts = pattern.split("*").filter(p => p.length > 0);
        if (parts.length === 0) return true;
        let pos = 0;
        for (let idx = 0; idx < parts.length; idx++) {
            const part = parts[idx];
            const isFirst = idx === 0;
            const isLast = idx === parts.length - 1;
            if (isFirst && !startsWild) {
                if (value.slice(pos).indexOf(part) !== 0) return false;
                pos += part.length;
            } else if (isLast && !endsWild) {
                if (!value.slice(pos).endsWith(part)) return false;
            } else {
                const found = value.slice(pos).indexOf(part);
                if (found < 0) return false;
                pos += found + part.length;
            }
        }
        return true;
    }

    function fieldsMatchingValuePattern(pattern, windows, metas) {
        return root.everyField().filter(f =>
            windows.some((w, i) => root.globMatch(pattern, root.fieldValue(w, metas[i] || {}, f))));
    }

    // Every field a `/fv` term actually scopes to - a bare/free term has
    // none (it searches the free-text haystack, not one field). Used by
    // activeColumns to auto-show whatever's being filtered on - see
    // query-dsl.md's "Auto-shown filter fields".
    function filterReferencedFields(filters) {
        const out = [];
        for (const term of filters) {
            let fields = [];
            if (term.kind === "scoped") {
                fields = root.resolveFilterFields(term.path);
            } else if (term.kind === "exists") {
                fields = root.resolveGroups(term.seg).map(g => ({ kind: "group", group: g, sub: root.groupDefaultSubOf(g) }));
            }
            for (const f of fields)
                if (!out.some(o => root.fieldsEqual(o, f)))
                    out.push(f);
        }
        return out;
    }

    function activeColumns(query, defaults, windows, metas) {
        const parsed = root.parse(query);
        let cols = defaults.slice();
        for (const { op, path, isVia } of parsed.colOps) {
            const fields = root.resolveColumnFields(path);
            if (fields.length === 0 && isVia && op === "filter") {
                cols = root.fieldsMatchingValuePattern(path, windows, metas);
                continue;
            }
            if (op === "filter") {
                cols = cols.filter(c => fields.some(f => root.fieldsEqual(c, f)));
            } else if (op === "add") {
                for (const f of fields)
                    if (!cols.some(c => root.fieldsEqual(c, f)))
                        cols.push(f);
            } else {
                cols = cols.filter(c => !fields.some(f => root.fieldsEqual(c, f)));
            }
        }
        // Auto-show: a field actively scoped by `/fv` is shown even without
        // an explicit `/at` (and even past an `/ft`/`/rt` that would
        // otherwise hide it) - so a match's own value is visible next to
        // the row it matched, the whole point once there's more than one
        // candidate left to choose between.
        for (const f of root.filterReferencedFields(parsed.filters))
            if (!cols.some(c => root.fieldsEqual(c, f)))
                cols.push(f);
        return cols;
    }

    // --- axis 3: sort / reverse ---------------------------------------------
    function parseActions(query) {
        const p = root.parse(query);
        return { sort: p.sort, reverse: p.reverse };
    }

    function _tryInt(s) { return /^\d+$/.test(s) ? parseInt(s, 10) : null; }
    function _tryAgeSeconds(s) {
        const m = /^(\d+)([smhd])$/.exec(s);
        if (!m) return null;
        return parseInt(m[1], 10) * ({ s: 1, m: 60, h: 3600, d: 86400 }[m[2]]);
    }
    // query.rs's compare_field_values + compare_with_direction combined,
    // `dir` applied here (matches QueryDsl.qml's own compareFieldValues
    // shape) -- see that file's doc for the age-bucket "direction trap".
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
    function sortFieldValue(win, meta, field) { return root.fieldValue(win, meta, field); }

    // --- autocompletion ------------------------------------------------------
    function valueSuggestions(windows, metas, field, fragment) {
        const seen = new Set();
        windows.forEach((w, i) => {
            const v = root.fieldValue(w, metas[i] || {}, field);
            if (v !== "" && root.substr(fragment, v))
                seen.add(v);
        });
        return Array.from(seen).sort();
    }

    function pathSuggestions(fragment) {
        const dot = fragment.indexOf(".");
        if (dot >= 0) {
            const gSeg = fragment.slice(0, dot), sSeg = fragment.slice(dot + 1);
            const gs = root.resolveGroups(gSeg);
            if (gs.length !== 1) return [];
            const group = gs[0];
            const out = root.resolveGroupSubs(group, sSeg).map(s => group + "." + s);
            if (root.substr(sSeg, "*"))
                out.push(group + ".*");
            return out;
        }
        const out = root.columns.filter(c => root.substr(fragment, c)).slice();
        out.push(...root.resolveGroups(fragment));
        return out;
    }

    // Completion: { kind: "verb"|"typePath"|"value"|"bareValue"|"sortDirection",
    //   start, fragment, verb?, via?, field? }
    function _replay(context) {
        // open: null | { verb, args: [string,...] }
        let open = null;
        for (const tok of context) {
            for (;;) {
                if (open === null) {
                    const tv = root.tokVerb(tok);
                    if (tv === null) {
                        // nothing to track
                    } else if (tv.verb === "/rv") {
                        // consumes nothing
                    } else if ((tv.verb === "/ft" || tv.verb === "/at" || tv.verb === "/rt") && tv.via !== null) {
                        // via already supplies the one path this verb takes
                    } else if (tv.via !== null) {
                        open = { verb: tv.verb, args: [tv.via] };
                    } else {
                        open = { verb: tv.verb, args: [] };
                    }
                    break;
                }
                if (root.startsCommand(tok)) {
                    open = null;
                    continue; // reprocess this token as a fresh command
                }
                if (open.verb === "/s") {
                    if (open.args.length === 0) {
                        open.args.push(tok.text); // path; still open for a direction
                    } else if (root.parseDirection(tok.text) !== null) {
                        open = null; // direction consumed
                    } else {
                        open = null; // not a direction - sort closes
                        continue;
                    }
                } else {
                    open = null; // single arg consumed
                }
                break;
            }
        }
        return open;
    }

    function completionContext(query) {
        const toks = root.tokenize(query);
        if (toks.length === 0) return null;
        const trailingSpace = /\s$/.test(query);
        let context, start, frag, leadQuote;
        if (trailingSpace) {
            context = toks; start = query.length; frag = ""; leadQuote = false;
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
                const verb = root._canonName(name);
                if (verb === null) return null;
                const viaStart = start + 1 + name.length + 1;
                if (verb === "/ft" && root.pathSuggestions(viaFrag).length === 0)
                    return { kind: "bareValue", start: viaStart, field: null, fragment: viaFrag };
                return { kind: "typePath", start: viaStart, verb, fragment: viaFrag, via: true };
            }
            return { kind: "verb", start, fragment: rest };
        }

        const open = root._replay(context);
        if (open === null || !root.takesPath(open.verb))
            return null;
        const verb = open.verb, args = open.args;
        if (verb === "/s" && args.length === 1) {
            const field = root.resolveOne(args[0]);
            return field !== null
                ? { kind: "sortDirection", start, field, fragment: frag }
                : { kind: "typePath", start, verb, fragment: frag, via: false };
        }
        if (verb === "/fv") {
            if (args.length === 1) {
                const field = root.resolveOne(args[0]);
                return field !== null
                    ? { kind: "bareValue", start, field, fragment: frag }
                    : { kind: "typePath", start, verb, fragment: frag, via: false };
            }
            const colon = frag.indexOf(":");
            if (colon >= 0) {
                const field = root.resolveOne(frag.slice(0, colon));
                if (field === null) return null;
                return { kind: "value", start, field, fragment: frag.slice(colon + 1) };
            }
        }
        return { kind: "typePath", start, verb, fragment: frag, via: false };
    }

    function completionCandidates(completion, windows, metas) {
        switch (completion.kind) {
        case "verb":
            // Bare (no leading "/"), matching query.rs's own VERB_SHORTS --
            // `shortVerbs` here carries the "/" for canonical-identity
            // comparisons elsewhere (tokVerb's return value, etc.), but the
            // accept side (WinSwitch.qml's `_acAccept`) already prepends
            // its own "/" the same way ui.rs's `SuggestionKind::Verb` does,
            // so a candidate that already had one produced "//fv" (reported
            // 2026-09-09).
            return root.verbStageUniverse().filter(v => root.substr(completion.fragment, v));
        case "typePath":
            return root.pathSuggestions(completion.fragment);
        case "value":
            return root.valueSuggestions(windows, metas, completion.field, completion.fragment);
        case "bareValue":
            if (completion.field !== null)
                return root.valueSuggestions(windows, metas, completion.field, completion.fragment);
            {
                const seen = new Set();
                for (const field of root.everyField())
                    for (const v of root.valueSuggestions(windows, metas, field, completion.fragment))
                        seen.add(v);
                return Array.from(seen).sort();
            }
        case "sortDirection":
            return root.resolveDirections(completion.fragment);
        }
        return [];
    }

    function isGroup(candidate) {
        return candidate.indexOf(".") < 0 && root.groupOrder.indexOf(candidate) >= 0;
    }

    // --- inline command-validity spans --------------------------------------
    function commandSpans(query) {
        const out = [];
        for (const tok of root.tokenize(query)) {
            if (tok.leadQuote || tok.text[0] !== "/") continue;
            const rest = tok.text.slice(1);
            if (rest.length === 0) continue;
            const slash = rest.indexOf("/");
            const name = slash >= 0 ? rest.slice(0, slash) : rest;
            const valid = root._canonName(name) !== null;
            if (!valid && root.isVerbPrefix(rest)) continue;
            out.push({ start: tok.start, end: tok.start + tok.text.length, valid });
        }
        return out;
    }
}

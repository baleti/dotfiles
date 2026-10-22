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
// naming (`tmux_session`, `claude_fts`, ...) via `group + "_" + sub`,
// which is exactly how `enrich.rs`'s `TmuxClaudeMeta` fields are already
// named -- see `groupSubValue`.
QtObject {
    id: root

    // --- schema (query.rs's COLUMNS / GROUPS / GROUP_DEFAULT_SUB) --------
    readonly property var columns: ["title", "workspace", "pid", "monitor", "windows"]
    readonly property var groupOrder: ["tmux", "claude"]
    readonly property var groups: ({
        tmux: ["session", "window", "title"],
        claude: ["title", "path", "session", "age", "fts"]
    })
    readonly property var directions: ["ascending", "descending"]
    readonly property var defaultColumns: [{ kind: "flat", name: "title" }, { kind: "flat", name: "workspace" }]
    // /sw (workspace view): what each workspace shows under its thumbnail.
    readonly property var workspaceColumns: [{ kind: "flat", name: "title" }, { kind: "flat", name: "monitor" }, { kind: "flat", name: "windows" }]

    readonly property var shortVerbs: ["/fv", "/ft", "/at", "/rt", "/s", "/sw"]
    readonly property var verbAliases: ({
        "/filter-value": "/fv", "/filter-type": "/ft", "/add-type": "/at",
        "/remove-type": "/rt", "/sort": "/s",
        "/switch-workspace": "/sw"
    })
    readonly property var verbInfo: ({
        "/fv": { long: "/filter-value", desc: "keep windows whose value matches (substring)" },
        "/ft": { long: "/filter-type",  desc: "show only the matching columns" },
        "/at": { long: "/add-type",     desc: "add the matching columns" },
        "/rt": { long: "/remove-type",  desc: "drop the matching columns" },
        "/s":  { long: "/sort",         desc: "order windows by one field, optional asc / desc" },
        "/fts": { long: "", desc: "full text of the running and archived Claude conversations" },
        "/sw": { long: "/switch-workspace", desc: "show workspaces instead of windows; pick one to switch to it" }
    })
    readonly property var verbForms: [
        "fv", "ft", "at", "rt", "s", "sw", "fts",
        "filter-value", "filter-type", "add-type", "remove-type", "sort", "switch-workspace"
    ]
    // Type names (query-dsl.md "Keys"): the flat columns plus the hyphenated
    // family types ("tmux-session", "claude-title", ...). Keys fuzzy-resolve
    // against these; claude-fts is reachable (it is what /fts/live filters on)
    // but not offered in completion - spelled /fts.
    readonly property var typeNames: {
        const out = root.columns.slice();
        for (const g of root.groupOrder)
            for (const s of root.groups[g])
                out.push(g + "-" + s);
        return out;
    }
    function allPaths() { return root.typeNames.filter(n => n !== "claude-fts"); }
    // The full Verb-stage vocabulary: the bare verbs plus every key-taking verb
    // crossed with every type name ("fv/workspace", "s/claude-title", ...) --
    // query-dsl.md's "Verb-stage depth". Exposed rather than inlined in
    // completionCandidates so WinSwitch.qml's Ctrl+Space AND-narrowing mode can
    // filter it with its own multiple-fragment rule.
    function verbStageUniverse() {
        const bareVerbs = root.shortVerbs.map(v => v.slice(1));
        const deep = [];
        for (const v of ["fv", "ft", "at", "rt", "s"])
            for (const p of root.allPaths())
                deep.push(v + "/" + p);
        return bareVerbs.concat(["fts/claude", "fts/claude-live", "fts/claude-archive", "fts/tmux"], deep);
    }
    // One-line description of a type path, for the type-path autocomplete
    // stage -- mirrors ui.rs's `type_desc`.
    readonly property var typeDescs: ({
        "title": "the window title",
        "workspace": "the Hyprland workspace",
        "pid": "the process id",
        "monitor": "the monitor a workspace is on (/sw view)",
        "windows": "how many windows a workspace holds (/sw view)",
        "tmux": "tmux session / window on this terminal",
        "claude": "running and archived conversations",
        "claude-live": "running conversations only",
        "claude-archive": "past conversations only; Enter resumes one in a new window",
        "tmux": "tmux scrollback (panes without a Claude session)",
        "tmux-session": "tmux session name",
        "tmux-window": "tmux window name",
        "tmux-title": "tmux window title",
        "claude": "Claude Code session on this terminal",
        "claude-title": "Claude Code session title",
        "claude-path": "Claude Code working directory",
        "claude-session": "Claude Code session id",
        "claude-age": "how long ago the transcript last changed",
        "claude-fts": "Claude Code conversation full-text (periodically indexed); /fts/claude-live is the shortcut"
    })

    function fieldKey(f) { return f.kind === "flat" ? f.name : f.group + "-" + f.sub; }
    function fieldsEqual(a, b) {
        if (!a || !b || a.kind !== b.kind) return false;
        return a.kind === "flat" ? a.name === b.name : a.group === b.group && a.sub === b.sub;
    }
    function takesPath(verb) { return true; }

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
        let qc = "";
        let quoted = false;
        // A "!" at the start of a token negates it (query-dsl.md
        // "Negation"). It is not part of the token: `start` stays on the
        // char after it, so command spans / completion offsets see the
        // plain token and a replacement keeps the "!" in front.
        let neg = false;
        for (let i = 0; i < query.length; i++) {
            const c = query[i];
            if (c === "!" && start < 0 && !neg) { neg = true; continue; }
            // `'` only opens a quote at the start of a token or of a scoped
            // value (after ":"), so apostrophes inside words stay text.
            const opens = c === '"' || (c === "'" && (start < 0 || query[i - 1] === ":"));
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
                    tokens.push({ start, text: cur, leadQuote, quoted, neg });
                    cur = "";
                    start = -1;
                    leadQuote = false;
                    quoted = false;
                }
                neg = false;
                continue;
            }
            if (start < 0) start = i;
            cur += c;
        }
        if (start >= 0)
            tokens.push({ start, text: cur, leadQuote, quoted, neg });
        return tokens;
    }

    // "" (the empty verb slot of "//path") is the default verb /fv - see
    // query-dsl.md "Default verb". Callers only reach "" with a via slash
    // after it; tokVerb guards the bare-"/" case itself.
    function _canonName(name) {
        if (name === "") return "/fv";
        // /fts[/claude][/live|/archive]: full text over Claude conversations, see parse()
        if (name === "fts") return "/fts";
        if (root.shortVerbs.indexOf("/" + name) >= 0) return "/" + name;
        if (root.verbAliases["/" + name]) return root.verbAliases["/" + name];
        return null;
    }

    // { verb, via, dir, bad } or null (query-dsl.md "Grammar"): `via` is the
    // keys part (null when absent), `dir` the third part (/s only), `bad` a
    // malformed token (too many parts; /sw takes none): inert.
    function tokVerb(tok) {
        if (tok.leadQuote || tok.text[0] !== "/") return null;
        const parts = tok.text.slice(1).split("/");
        // "//keys": empty verb slot defaults to /fv
        const v = parts[0] === "" ? (parts.length >= 2 ? "/fv" : null) : root._canonName(parts[0]);
        if (v === null) return null;
        const maxParts = v === "/s" ? 3 : (v === "/sw" ? 1 : 2);
        return { verb: v, via: parts.length >= 2 ? parts[1] : null,
                 dir: parts.length === 3 ? parts[2] : null, bad: parts.length > maxParts };
    }

    // A non-empty verb form always "starts with" the empty string, so a
    // bare "/" (s === "") is correctly a prefix of every verb here too -
    // no separate guard needed, and one that excluded "" would be wrong:
    // it would make the very first keystroke of any command ("/" alone)
    // fall through as literal text instead of staying inert (reported
    // 2026-09-13 - typing "/" alone was clearing the whole grid).
    function isVerbPrefix(s) {
        return root.verbForms.some(f => f.indexOf(s) === 0);
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
        return [["asc", "ascending"], ["desc", "descending"]].filter(d => d[1].indexOf(frag.toLowerCase()) === 0).map(d => d[0]);
    }

    // --- substring matching, schema lookups -------------------------------
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
    // A label-line preview of `value`, capped at `maxLen` chars, as
    // `{ text, matchStart, matchLen }` - `matchStart` is -1 when there's no
    // needle or it wasn't found, so a caller can tell "no highlight" apart
    // from "highlight at position 0" without a second lookup. With no
    // `needle` this is a plain start-truncation (unchanged behaviour for
    // fields not tied to a matched filter value). With a `needle`, centers
    // the window on its first occurrence instead - a naive chars[0:maxLen]
    // truncation of a long field (claude-fts, a whole transcript) very
    // rarely contains the matched substring itself within its first 80
    // characters, so the preview read as unrelated noise even though the
    // match was correct (reported 2026-09-13 against winswitch's alt-tab
    // search: `/fv/claude ovh` matched real hits in transcript contents,
    // but every thumbnail showed the same unrelated leading fragment).
    // `matchStart`/`matchLen` index into the returned `text` (post-slicing,
    // already accounting for a leading "…") so WinSwitch.qml can wrap
    // exactly the matched run in a colored span without re-searching.
    function excerpt(value, needle, maxLen) {
        if (!needle) {
            const text = value.length > maxLen ? value.slice(0, maxLen) + "…" : value;
            return { text, matchStart: -1, matchLen: 0 };
        }
        const idx = root.substrIdx(needle, value);
        if (value.length <= maxLen)
            return { text: value, matchStart: idx, matchLen: idx >= 0 ? needle.length : 0 };
        if (idx < 0)
            return { text: value.slice(0, maxLen) + "…", matchStart: -1, matchLen: 0 };
        const half = Math.floor(Math.max(0, maxLen - needle.length) / 2);
        let start = Math.max(0, idx - half);
        let end = Math.min(value.length, start + maxLen);
        start = Math.max(0, end - maxLen);
        let out = value.slice(start, end);
        let matchStart = idx - start;
        if (start > 0) { out = "…" + out; matchStart += 1; }
        if (end < value.length) out = out + "…";
        return { text: out, matchStart, matchLen: needle.length };
    }
    // HTML-escapes `s` for use inside a Text.StyledText string (WinSwitch.qml
    // renders matched excerpts as rich text to color the hit - see excerpt,
    // above). Only the three characters that are actually special in that
    // subset need escaping; arbitrary transcript/title text otherwise passes
    // through unmodified.
    function escapeHtml(s) {
        return String(s).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
    }
    function groupSubsOf(g) { return root.groups[g] || []; }

    function columnValue(win, c) {
        switch (c) {
        case "title": return win.title || "";
        case "workspace": return win.workspace || "";
        case "pid": return String(win.pid ?? "");
        case "monitor": return win.monitor || "";
        case "windows": return win.windowCount === undefined ? "" : String(win.windowCount);
        }
        return "";
    }
    // Group subfield values come straight off the enrich NDJSON payload's
    // own key naming (`tmux_session`, `claude_fts`, ...) -- see this
    // file's own doc.
    function groupSubValue(meta, g, s) {
        if (!meta) return "";
        // claude.age is the backend's `claude_time` (renamed in the DSL only)
        return meta[g + "_" + (g === "claude" && s === "age" ? "time" : s)] || "";
    }
    // --- key resolution (query-dsl.md "Keys") -----------------------------
    // Per key: a name equal to it wins alone, else every name containing it;
    // unioned across the comma list, in `known` order. Empty keys skipped.
    function resolveNames(keys, known) {
        const hit = {};
        for (const key of String(keys).toLowerCase().split(",")) {
            if (key.length === 0) continue;
            const exact = known.filter(n => n === key);
            for (const n of (exact.length > 0 ? exact : known.filter(n => n.indexOf(key) >= 0)))
                hit[n] = true;
        }
        return known.filter(n => hit[n]);
    }
    function fieldOfName(n) {
        if (root.columns.indexOf(n) >= 0) return { kind: "flat", name: n };
        const i = n.indexOf("-");
        return { kind: "group", group: n.slice(0, i), sub: n.slice(i + 1) };
    }
    function resolveKeys(keys) { return root.resolveNames(keys, root.typeNames).map(root.fieldOfName); }
    function resolveFilterFields(path) { return root.resolveKeys(path); }
    function resolveColumnFields(path) { return root.resolveKeys(path); }
    // The single field a sort key names, or null if ambiguous/unknown.
    function resolveOne(path) {
        const f = root.resolveKeys(path);
        return f.length === 1 ? f[0] : null;
    }

    // --- command parsing (query.rs's filter_term / parse) -----------------
    function filterTerm(arg, quoted) {
        return { kind: "free", text: arg, exact: !!quoted };
    }

    // -> { filters: [...], colOps: [{op,path,isVia}], sort: {fields,dir}|null, reverse }
    function parse(query) {
        const toks = root.tokenize(query);
        let out = { filters: [], colOps: [], sort: null, switchWorkspace: false, fts: null };
        const top = out;
        let i = 0;
        while (i < toks.length) {
            out = top; // undo the previous verb's "!" redirect, if any
            const tok = toks[i];
            const tv = root.tokVerb(tok);
            if (tv === null) {
                const midTyping = !tok.leadQuote && tok.text[0] === "/" && root.isVerbPrefix(tok.text.slice(1));
                if (!midTyping)
                    out.filters.push(root.negated(root.filterTerm(tok.text, tok.quoted), tok.neg));
                i++;
                continue;
            }
            i++;
            const verb = tv.verb;
            if (verb === "/fts") {
                // /fts[/claude-live|/claude-archive|...] [term]: full text over the Claude conversations.
                if (tv.bad) continue;
                // scope names: claude-live, claude-archive, tmux (no keys = all three)
                const names = tv.via ? root.resolveNames(tv.via, ["claude-live", "claude-archive", "tmux"])
                                     : ["claude-live", "claude-archive", "tmux"];
                const scope = { live: names.indexOf("claude-live") >= 0, archive: names.indexOf("claude-archive") >= 0, tmux: names.indexOf("tmux") >= 0 };
                let term = "";
                if (i < toks.length && !root.startsCommand(toks[i])) {
                    term = toks[i].text.replace(/"/g, "");
                    i++;
                }
                (top.ftsTokens = top.ftsTokens || []).push({ scope, term, neg: !!tok.neg });
                continue;
            }
            if (verb === "/sw") {
                if (!tv.bad && tv.via === null) top.switchWorkspace = true;
                continue;
            }
            // keyless or malformed: inert, takes no argument ("/fv foo" is just "foo")
            if (tv.via === null || tv.bad) continue;
            const via = tv.via.toLowerCase();
            // "!" only means something on a row filter: "!/s", "!/ft" ... parse but change nothing.
            const verbNeg = !!tok.neg;
            const R = (verbNeg && verb !== "/fv")
                ? { filters: [], colOps: [], sort: null, switchWorkspace: false } : top;
            const keysTyped = via.replace(/,/g, "").length > 0;
            if (verb === "/fv") {
                if (i < toks.length && !root.startsCommand(toks[i])) {
                    R.filters.push(root.negated({ kind: "scoped", path: via, value: toks[i].text, exact: !!toks[i].quoted }, verbNeg || toks[i].neg));
                    i++;
                } else if (keysTyped && root.resolveKeys(via).length > 0) {
                    // keys named, value still pending: an empty value always
                    // substring-matches, so this is a no-op for row filtering but
                    // lets filterReferencedFields Auto-show the field at once.
                    R.filters.push(root.negated({ kind: "scoped", path: via, value: "" }, verbNeg));
                }
            } else if (verb === "/ft" || verb === "/at" || verb === "/rt") {
                if (keysTyped)
                    R.colOps.push({ op: verb === "/ft" ? "filter" : (verb === "/at" ? "add" : "remove"), path: via, isVia: true });
            } else if (verb === "/s") {
                if (tv.dir !== null && root.parseDirection(tv.dir) === null) continue;
                const keys = via.split(",").filter(x => x.length > 0);
                const dir = tv.dir ? root.parseDirection(tv.dir) : "asc";
                // raw keys kept even when they name no window type: the conversations table
                // (/fts view) sorts by its own types (WinSwitch.qml tableView)
                if (keys.length > 0) R.sortRaw = { keys, dir };
                // fuzzy keys expand to every matching type, alphabetical (`/s/pa` = pages,path)
                const groups = keys.map(k => root.resolveKeys(k).slice().sort((a, b) => root.fieldKey(a) < root.fieldKey(b) ? -1 : 1));
                const fields = [];
                for (const g of groups) for (const f of g) if (!fields.some(x => root.fieldsEqual(x, f))) fields.push(f);
                if (keys.length > 0 && groups.every(g => g.length > 0))
                    R.sort = { fields, dir };
            }
        }
        if (top.ftsTokens) {
            // Scope: one spelled scope wins, plain or mixed = both. live -> the window grid is
            // filtered by claude-fts; archive / both -> the table view (WinSwitch.qml).
            const scopes = { live: false, archive: false, tmux: false };
            for (const t of top.ftsTokens) for (const k of ["live", "archive", "tmux"]) scopes[k] = scopes[k] || t.scope[k];
            top.fts = { scopes, liveOnly: scopes.live && !scopes.archive && !scopes.tmux,
                        terms: top.ftsTokens.filter(t => !t.neg && t.term).map(t => t.term),
                        negTerms: top.ftsTokens.filter(t => t.neg && t.term).map(t => t.term) };
            if (top.fts.liveOnly)
                for (const t of top.ftsTokens)
                    if (t.term) top.filters.push(root.negated({ kind: "scoped", path: "claude-fts", value: t.term, exact: false }, t.neg));
        }
        return top;
    }

    // Stamp a filter term with its negation flag (see tokenize's "!").
    function negated(term, neg) {
        if (neg) term.neg = true;
        return term;
    }

    // --- axis 1: row filtering ---------------------------------------------
    function fieldValue(win, meta, field) {
        return field.kind === "flat" ? root.columnValue(win, field.name) : root.groupSubValue(meta, field.group, field.sub);
    }

    function _termMatches(win, meta, term) {
        const m = root._termMatchesPos(win, meta, term);
        return term.neg ? !m : m;
    }

    // claude-fts is answered by `claude-history --fts` (BM25 over every
    // transcript), not by text carried on the window: WinSwitch.qml fills
    // this { lowercase term: { sessionId: score } } for the query's terms.
    property var ftsHits: ({})
    function isFtsField(f) { return f.kind === "group" && f.group === "claude" && f.sub === "fts"; }
    // Distinct lowercase values of every scoped term that reaches claude-fts.
    function ftsTerms(filters) {
        const out = [];
        for (const t of filters) {
            if (t.kind !== "scoped" || !t.value || t.neg) continue;
            if (!root.resolveFilterFields(t.path).some(root.isFtsField)) continue;
            const v = String(t.value).toLowerCase();
            if (out.indexOf(v) < 0) out.push(v);
        }
        return out;
    }
    function _ftsMatch(meta, term) {
        const hits = root.ftsHits[String(term.value).toLowerCase()];
        return !!(hits && meta && meta.claude_session && hits[meta.claude_session] !== undefined);
    }

    function _termMatchesPos(win, meta, term) {
        if (term.kind === "free") {
            const haystack = (win.title || "") + " " + (win.class || "") + " " + (win.workspace || "");
            return root.substr(term.text, haystack, term.exact);
        }
        if (term.kind === "scoped") {
            const fields = root.resolveFilterFields(term.path);
            // a window count is a number: "3" means exactly 3, not 13 or 30
            return fields.length > 0 && fields.some(f => f.kind === "flat" && f.name === "windows"
                ? (term.value === "" || root.fieldValue(win, meta, f) === term.value)
                : root.isFtsField(f) ? (term.value === "" || root._ftsMatch(meta, term))
                : root.substr(term.value, root.fieldValue(win, meta, f), term.exact));
        }
        return false;
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
            const fields = term.kind === "scoped" ? root.resolveFilterFields(term.path) : [];
            for (const f of fields)
                if (!out.some(o => root.fieldsEqual(o, f)))
                    out.push(f);
        }
        return out;
    }

    // Family-wide scoped filters currently in effect ({group, value} pairs): a
    // `//claude foo` key that reaches several types of one family (as opposed to
    // one naming a single type, `//claude-title foo`). The matched type differs
    // row to row, so WinSwitch.qml's labelLines shows only the type(s) that
    // actually matched *this* row, each labelled with its own name (query-dsl.md
    // "Auto-shown filter fields").
    function scopedGroupFilters(query) {
        const out = [];
        for (const t of root.parse(query).filters) {
            if (t.kind !== "scoped" || t.neg) continue;
            const fields = root.resolveFilterFields(t.path);
            if (fields.length < 2) continue;
            const groups = [];
            for (const f of fields)
                if (f.kind === "group" && groups.indexOf(f.group) < 0) groups.push(f.group);
            for (const g of groups)
                out.push({ group: g, value: t.value });
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

    // --- axis 3: sort ---------------------------------------------
    function parseActions(query) {
        const p = root.parse(query);
        return { sort: p.sort };
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
        return root.allPaths().filter(n => root.substr(fragment, n));
    }

    // Completion: { kind: "verb"|"typePath"|"value"|"bareValue"|"sortDirection",
    //   start, fragment, verb?, via?, field? }
    function _replay(context) {
        // open: null | { verb, args: [string,...] } - only `/fv/keys` leaves a value pending
        let open = null;
        for (const tok of context) {
            if (open !== null) {
                if (root.startsCommand(tok)) open = null; // reprocess this token as a fresh command
                else { open = null; continue; }           // the value is consumed
            }
            const tv = root.tokVerb(tok);
            if (tv !== null && !tv.bad && tv.verb === "/fv" && tv.via !== null && tv.via.replace(/,/g, "").length > 0)
                open = { verb: "/fv", args: [tv.via] };
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
            const parts = rest.split("/");
            if (parts.length === 1) return { kind: "verb", start, fragment: rest };
            const verb = parts[0] === "" ? "/fv" : root._canonName(parts[0]);
            if (verb === null) return null;
            if (parts.length === 2) {
                // key stage: complete the fragment after the last comma
                const comma = parts[1].lastIndexOf(",");
                const keyFrag = parts[1].slice(comma + 1);
                const viaStart = start + 1 + parts[0].length + 1 + comma + 1;
                if (verb === "/ft" && comma < 0 && root.pathSuggestions(keyFrag).length === 0)
                    return { kind: "bareValue", start: viaStart, field: null, fragment: keyFrag };
                return { kind: "typePath", start: viaStart, verb, fragment: keyFrag, via: true };
            }
            if (parts.length === 3 && verb === "/s")
                return { kind: "sortDirection", start: start + frag.length - parts[2].length, field: null, fragment: parts[2] };
            return null;
        }

        const open = root._replay(context);
        if (open === null) return null;
        // value stage after `/fv/keys `: live values of the resolved types
        const fields = root.resolveKeys(open.args[0]);
        return { kind: "bareValue", start, field: fields.length === 1 ? fields[0] : null, fields, fragment: frag };
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
            if (completion.verb === "/fts")
                return ["claude", "claude-live", "claude-archive", "tmux"].filter(n => root.substr(completion.fragment, n));
            return root.pathSuggestions(completion.fragment);
        case "value":
            return root.valueSuggestions(windows, metas, completion.field, completion.fragment);
        case "bareValue":
            if (completion.field !== null)
                return root.valueSuggestions(windows, metas, completion.field, completion.fragment);
            if (completion.fields) {
                const seen = new Set();
                for (const field of completion.fields)
                    for (const v of root.valueSuggestions(windows, metas, field, completion.fragment))
                        seen.add(v);
                return Array.from(seen).sort();
            }
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

    function isGroup(candidate) { return false; }

    // --- inline command-validity spans --------------------------------------
    function commandSpans(query) {
        const out = [];
        for (const tok of root.tokenize(query)) {
            if (tok.leadQuote || tok.text[0] !== "/") continue;
            const rest = tok.text.slice(1);
            if (rest.length === 0) continue;
            const tv = root.tokVerb(tok);
            const valid = tv !== null && !tv.bad;
            if (!valid && tv === null && root.isVerbPrefix(rest.split("/")[0]) && rest.indexOf("/") < 0) continue;
            out.push({ start: tok.start, end: tok.start + tok.text.length, valid });
        }
        return out;
    }
}

import QtQuick
import Quickshell
import Quickshell.Wayland
import Quickshell.Hyprland
import Quickshell.Io
import "../theme"
import "../services"

// Application launcher -- replaces `rofi -show drun` (mod + Super_l). Just
// launches apps: icon + name, nothing else (no descriptions, no
// run-a-command / calc / window modes). Search box speaks the shared
// picker DSL (QueryDsl.qml / ~/.config/docs/query-dsl.md): bare text + /fv
// match name + generic name only (short, controlled strings - matching
// prose Comment= / Keywords= in the free haystack made `ala` hit
// "scALAble" and "bALAnce"); comment/keywords/exec/categories are
// searchable but only when named (`/fv comment:vector`). /s and /rv for
// order. The column verbs (/ft /at /rt) are inert here -- no columns.
// One instance per monitor; only the focused one is ever shown.
PanelWindow {
    id: root

    // `screen` is PanelWindow's own property, set from shell.qml's Variants
    // (do NOT redeclare it -- that shadows the real one, see NotifLayer).
    // `open` is set imperatively (not a binding) so nothing downstream of it
    // -- visible, keyboardFocus, the autocomplete -- can feed a binding loop
    // back into it.
    property bool open: false

    // Ignore the pointer until it has genuinely moved since the popup
    // opened (a stationary mouse under the popup must not select a row).
    property var _hoverOrigin: null
    property bool _hoverArmed: false
    function _pointerMoved(item, mouse) {
        if (root._hoverArmed)
            return true;
        const p = item.mapToItem(null, mouse.x, mouse.y);
        if (!root._hoverOrigin) {
            root._hoverOrigin = p;
            return false;
        }
        if (Math.abs(p.x - root._hoverOrigin.x) + Math.abs(p.y - root._hoverOrigin.y) > 8)
            root._hoverArmed = true;
        return root._hoverArmed;
    }

    // Type names filterable / sortable via the DSL. `name` and `generic`
    // are also the free-text (bare / `/fv text`) haystack; the rest are
    // scoped-only, because substring-matching prose Comment= or a
    // Keywords= list produces mid-word noise (`ala` in "scalable").
    readonly property var typeNames: ["name", "generic", "comment", "exec", "categories", "keywords"]
    readonly property var typeDescs: ({
        "name": "the application name",
        "generic": "the generic name (\"Web Browser\")",
        "comment": "the freedesktop Comment= description",
        "exec": "the launch command",
        "categories": "freedesktop Categories= entries",
        "keywords": "freedesktop Keywords= entries"
    })

    function _recompute() {
        root.open = LauncherState.active && LauncherState.monitor === root.screen.name;
    }
    Component.onCompleted: root._recompute()
    Connections {
        target: LauncherState
        function onActiveChanged() { root._recompute(); }
        function onMonitorChanged() { root._recompute(); }
    }

    onOpenChanged: {
        root._hoverOrigin = null;
        root._hoverArmed = false;
        if (root.open) {
            root.wsPrompt = false;
            query.text = "";
            root.selected = 0;
            ac.visible = false;
            root.acVerbMulti = false;
            root.acActive = false;
            focusGrab.active = true;
            Qt.callLater(() => query.forceActiveFocus());
        } else {
            focusGrab.active = false;
        }
    }
    function hide() { LauncherState.close(); }

    // ---- app records -- recomputed when the desktop-entry set changes ---
    readonly property var apps: {
        const out = [];
        const list = DesktopEntries.applications.values;
        for (let i = 0; i < list.length; i++) {
            const e = list[i];
            if (e.noDisplay)
                continue;
            const cats = (e.categories || []).map(c => String(c));
            const kws = (e.keywords || []).map(c => String(c));
            out.push({
                entry: e,
                id: e.id || "",
                name: e.name || "",
                comment: e.comment || "",
                generic: e.genericName || "",
                exec: e.execString || "",
                categories: cats,
                keywords: kws,
                haystack: [e.name, e.genericName]
                    .filter(s => !!s).join(" ").toLowerCase(),
            });
        }
        return out;
    }

    // ---- query -> results ------------------------------------------
    property var parsed: QueryDsl.parse(query.text)
    property int selected: 0

    function _fieldVals(app, field) {
        switch (field) {
        case "name": return [app.name];
        case "generic": return [app.generic];
        case "comment": return [app.comment];
        case "exec": return [app.exec];
        case "categories": return app.categories;
        case "keywords": return app.keywords;
        }
        return [];
    }

    function _matches(app, term) {
        return QueryDsl.applyNeg(term, root._matchesPos(app, term));
    }

    function _matchesPos(app, term) {
        if (term.text !== undefined)
            return QueryDsl.substr(term.text, app.haystack, term.quoted);
        // scoped path:value
        const fields = QueryDsl.resolvePath(term.field, root.typeNames);
        if (fields.length === 0)
            return false; // unresolvable complete path -> narrows to nothing
        for (const f of fields) {
            for (const v of root._fieldVals(app, f)) {
                if (QueryDsl.substr(term.value, String(v), term.quoted))
                    return true;
            }
        }
        return false;
    }

    // Rank: exact name, name-prefix, name-substring, other -- then alpha.
    function _rank(app) {
        let firstText = "";
        for (const t of root.parsed.terms)
            if (t.text !== undefined && !t.neg) { firstText = t.text; break; }
        if (firstText.length === 0)
            return 3;
        const n = app.name.toLowerCase();
        if (n === firstText) return 0;
        if (n.startsWith(firstText)) return 1;
        if (n.indexOf(firstText) >= 0) return 2;
        return 3;
    }

    // ---- action commands -------------------------------------------
    // `/move-to-workspace` is not a filter/sort verb: typing it shows one
    // action row, and Enter opens a second list (`wsPrompt`) of workspaces
    // for the window that was focused when the launcher opened
    // (LauncherState.windowAddress). Typing filters the list; Enter on a row
    // moves the window there, and a typed name with no exact match creates
    // a new workspace right after the window's current one.
    readonly property var actionVerbs: ({
        "/move-to-workspace": "move the focused window to a workspace (typed name may be new)",
        "/move-workspace": "move the current workspace to just after a chosen one"
    })
    readonly property var _actionMatch: query.text.match(/^\s*(\/move-to-workspace|\/move-workspace)(?:\s+(.*))?$/)
    property bool wsPrompt: false
    // which action the open workspace list serves: "window" | "workspace"
    property string promptKind: "window"
    readonly property bool actionMode: root.wsPrompt
    readonly property string actionArg: root.wsPrompt ? query.text.trim() : ""

    readonly property var workspaceRows: {
        const arg = root.actionArg.toLowerCase();
        const list = Hyprland.workspaces.values.filter(w => w.id >= 0 && String(w.name).indexOf("special:") !== 0
            && !(root.promptKind === "workspace" && w.id === LauncherState.workspaceId));
        list.sort((a, b) => a.id - b.id);
        const out = [];
        let exact = false;
        for (const w of list) {
            const n = String(w.name);
            if (arg && n.toLowerCase().indexOf(arg) < 0) continue;
            if (n.toLowerCase() === arg) exact = true;
            const tl = w.toplevels ? w.toplevels.values : [];
            const classes = [];
            for (const t of tl) {
                const c = t.lastIpcObject && t.lastIpcObject["class"] ? String(t.lastIpcObject["class"]) : "";
                if (c && classes.indexOf(c) < 0) classes.push(c);
            }
            out.push({ ws: true, name: n, target: n, id: w.id, cnt: tl.length,
                       mon: w.monitor ? w.monitor.name : "", apps: classes.join(", "),
                       entry: { icon: "" } });
        }
        if (root.actionArg && !exact && root.promptKind === "window")
            out.push({ ws: true, name: "+ new workspace \"" + root.actionArg + "\"", target: root.actionArg,
                       create: true, cnt: -1, mon: "", apps: "created after the current workspace", entry: { icon: "" } });
        return out;
    }

    // Lua string literal (user-typed names must not break out of the quotes).
    function _luaStr(s) {
        return "\"" + String(s).replace(/\\/g, "\\\\").replace(/"/g, "\\\"") + "\"";
    }

    // Reorder: Hyprland can't renumber, so the current workspace's windows
    // go to the smallest unused id above the chosen workspace, keeping the
    // name, and the view follows them.
    function moveWorkspaceAfter(row) {
        const cur = LauncherState.workspaceId;
        if (cur < 0) return;
        const lua = "local cur = hl.get_workspace(" + cur + ") local name = cur and cur.name or '' "
            + "local used = {} for _, x in ipairs(hl.get_workspaces()) do used[x.id] = true end "
            + "local id = " + row.id + " + 1 while used[id] and id ~= " + cur + " do id = id + 1 end "
            + "if id == " + cur + " then return end "
            + "for _, w in ipairs(hl.get_windows()) do if w.workspace.id == " + cur
            + " then hl.dispatch(hl.dsp.window.move({ workspace = id, window = w, follow = false })) end end "
            + "hl.dispatch(hl.dsp.workspace.rename({ workspace = id, name = name })) "
            + "hl.dispatch(hl.dsp.focus({ workspace = id }))";
        moveProc.exec(["hyprctl", "repl", lua]);
    }

    function moveToWorkspace(row) {
        const addr = LauncherState.windowAddress.replace(/^0x/, "");
        if (!addr) return;
        const t = String(row.target);
        const find = "for _, w in ipairs(hl.get_windows()) do if tostring(w.address):gsub('^0x', '') == "
            + root._luaStr(addr) + " then ";
        let lua;
        if (row.create) {
            // Hyprland orders workspaces by integer id and can't renumber,
            // so "right after the current one" = the smallest unused id
            // above the window's workspace, then named via rename.
            lua = find + "local used = {} for _, x in ipairs(hl.get_workspaces()) do used[x.id] = true end "
                + "local id = w.workspace.id + 1 while used[id] do id = id + 1 end "
                + "hl.dispatch(hl.dsp.window.move({ workspace = id, window = w })) "
                + "hl.dispatch(hl.dsp.workspace.rename({ workspace = id, name = " + root._luaStr(t) + " })) break end end";
        } else {
            const ws = /^[0-9]+$/.test(t) ? t : root._luaStr("name:" + t);
            lua = find + "hl.dispatch(hl.dsp.window.move({ workspace = " + ws + ", window = w })) break end end";
        }
        moveProc.exec(["hyprctl", "repl", lua]);
    }
    Process { id: moveProc }

    readonly property var results: {
        if (root.actionMode)
            return root.workspaceRows;
        if (root._actionMatch)
            return [{ action: root._actionMatch[1], name: root._actionMatch[1] === "/move-workspace"
                      ? "Move workspace after\u2026" : "Move window to workspace\u2026",
                      detail: "", entry: { icon: "" } }];
        let rows = root.apps.filter(app => root.parsed.terms.every(t => root._matches(app, t)));

        const s = root.parsed.sort;
        // Each chain segment must resolve to exactly one field (query-dsl.md
        // "/sort"); any segment that doesn't makes the *whole* /sort inert,
        // not just that key -- falls through to the default order below.
        const sortFields = s ? s.fields.map(p => QueryDsl.resolvePath(p, root.typeNames)) : null;
        if (s && sortFields.every(fl => fl.length === 1)) {
            const keys = sortFields.map(fl => fl[0]);
            rows = rows.slice().sort((a, b) => {
                for (const f of keys) {
                    const av = root._fieldVals(a, f)[0] || "";
                    const bv = root._fieldVals(b, f)[0] || "";
                    const c = QueryDsl.compareFieldValues(av, bv, s.dir);
                    if (c !== 0) return c;
                }
                return 0;
            });
        } else {
            // rank first (only meaningful when text was typed), then launch
            // frecency, then alphabetical.
            rows = rows.slice().sort((a, b) => {
                const r = root._rank(a) - root._rank(b);
                if (r !== 0) return r;
                const f = LauncherHistory.score(b.id) - LauncherHistory.score(a.id);
                if (f !== 0) return f;
                return a.name.toLowerCase() < b.name.toLowerCase() ? -1 : 1;
            });
        }
        if (root.parsed.reverse)
            rows = rows.slice().reverse();
        return rows;
    }

    onResultsChanged: {
        if (root.selected >= results.length)
            root.selected = Math.max(0, results.length - 1);
        root._measure();
    }

    function launch(i) {
        const app = root.results[i];
        if (!app) return;
        if (app.action) {
            LauncherQueryHistory.record(query.text);
            root.wsPrompt = true;
            root.promptKind = app.action === "/move-workspace" ? "workspace" : "window";
            query.text = "";
            root.selected = 0;
            return;
        }
        if (app.ws) {
            LauncherQueryHistory.record(query.text);
            if (root.promptKind === "workspace") root.moveWorkspaceAfter(app);
            else root.moveToWorkspace(app);
            root.hide();
            return;
        }
        // query-dsl.md's "Search-box history": a real accept records the
        // query, same as fzf's own --history flag does for the tmux
        // pickers - before LauncherHistory.bump, which is a different
        // thing (per-app launch frecency, not the search-box history).
        LauncherQueryHistory.record(query.text);
        LauncherHistory.bump(app.id);
        app.entry.execute();
        root.hide();
    }

    // Resolve every app's icon name to a real file path once the entry set
    // is known (quickshell's own provider misses the hicolor fallback here).
    onAppsChanged: LauncherIcons.resolve(root.apps.map(a => a.entry.icon))

    // Every field currently `/fv field:value`-scoped by the query, deduped
    // - shown as an extra line under the app name (see the results
    // delegate) even though this launcher has no general column system,
    // so a hidden field (comment/keywords/...) that matched is visible
    // rather than left a mystery. query-dsl.md's "Auto-shown filter fields"
    // - includes `openPaths` (a via path named but not yet valued, e.g.
    // `/fv/comment` with nothing after it yet) so the field shows the
    // moment the command names it, not just once a value narrows anything;
    // an unresolvable path (typo, still mid-typing) resolves to nothing
    // here exactly like it already does for a complete term.
    readonly property var referencedFields: {
        const out = [];
        for (const t of root.parsed.terms) {
            if (t.field === undefined) continue;
            for (const f of QueryDsl.resolvePath(t.field, root.typeNames))
                if (out.indexOf(f) < 0) out.push(f);
        }
        for (const p of root.parsed.openPaths) {
            for (const f of QueryDsl.resolvePath(p, root.typeNames))
                if (out.indexOf(f) < 0) out.push(f);
        }
        return out;
    }

    // ---- autocomplete (marginalia-style) --------------------------
    // Rows carry: what accepting inserts (`text`), the short label, the
    // long-form alias, and a one-line description -- alias + desc rendered
    // grey, like emacs marginalia / zsh completion hints. Stages: verb
    // (`/frag`, only the verbs that do something here) and `/fv path`
    // (before the `:`), including the bare `/fv ` / `/s ` case (empty
    // fragment -> all candidates).
    readonly property var _acVerbs: ["/fv", "/s", "/rv"] // /ft /at /rt are inert here

    // ---- inline command-validity coloring (query-dsl.md) -----------
    // True if `v` (leading "/" included) is still a genuine prefix of some
    // real verb form - not wrong yet, just incomplete, so `_commandSpans`
    // leaves it in the default text color rather than either accent.
    function _isVerbPrefix(v) {
        if (v.length <= 1) return false; // just "/" - too early to call wrong
        const forms = QueryDsl.shortVerbs.concat(Object.keys(QueryDsl.verbAliases), Object.keys(root.actionVerbs));
        return forms.some(f => f.startsWith(v));
    }

    // Every `/`-led token in `text` that's unambiguously a command attempt
    // - {start, end, valid} for each (byte/char offsets into `text`,
    // since JS strings are UTF-16 code units the same way QML text
    // positions are). Ported from winswitch's query.rs::command_spans.
    function _commandSpans(text) {
        const spans = [];
        let i = 0;
        while (i < text.length) {
            while (i < text.length && text[i] === " ") i++;
            if (i >= text.length) break;
            const start = i;
            if (text[i] === '"') {
                const end = text.indexOf('"', i + 1);
                i = end < 0 ? text.length : end + 1;
                continue; // quoted literal - never a command
            }
            let j = i;
            while (j < text.length && text[j] !== " ") j++;
            // A leading "!" negates the term (query-dsl.md "Negation"); it is
            // not part of the command, so the span starts after it.
            const bang = text[i] === "!" ? 1 : 0;
            const tok = text.slice(i + bang, j);
            i = j;
            if (tok.length > 1 && tok[0] === "/") {
                if (QueryDsl.canonVerb({ q: false, v: tok }) || root.actionVerbs[tok] !== undefined) {
                    spans.push({ start: start + bang, end: start + bang + tok.length, valid: true });
                } else if (!root._isVerbPrefix(tok)) {
                    spans.push({ start: start + bang, end: start + bang + tok.length, valid: false });
                }
                // else: still forming - neutral, no span at all
            }
        }
        return spans;
    }

    // The full Verb-stage vocabulary: the three verbs that do anything here
    // (`_acVerbs`) plus `/fv` and `/s` - the two that take a real path -
    // crossed with every type name ("fv/comment", "s/name", ...), so a
    // fragment of the *type*, not just the verb, reaches a whole working
    // command. `/rv` isn't crossed (takes no path). See query-dsl.md's
    // "Verb-stage depth".
    function _verbStageUniverse() {
        const bare = root._acVerbs.map(v => v.slice(1)).concat(Object.keys(root.actionVerbs).map(v => v.slice(1)));
        const deep = [];
        for (const v of ["fv", "s"])
            for (const n of root.typeNames)
                deep.push(v + "/" + n);
        return bare.concat(deep);
    }

    // Turns one universe entry ("fv", or the deep "fv/comment") into an
    // autocomplete row, given the query prefix before the completion's
    // opening "/". A deep `/fv` candidate lands the colon form
    // ("/fv comment:"), matching how the plain type-path stage below
    // already lands here (query-dsl.md: "the GTK pickers and app launcher
    // still land the : form"); `/s` lands its ordinary space form.
    function _verbStageItem(prefix, v) {
        const slash = v.indexOf("/");
        if (slash < 0 && root.actionVerbs["/" + v] !== undefined)
            return { text: prefix + "/" + v + " ", label: "/" + v, alias: "", desc: root.actionVerbs["/" + v] };
        if (slash < 0) {
            return { text: prefix + "/" + v + " ", label: "/" + v,
                     alias: QueryDsl.verbInfo["/" + v].long, desc: QueryDsl.verbInfo["/" + v].desc };
        }
        const verb = v.slice(0, slash), name = v.slice(slash + 1);
        const text = verb === "fv" ? `${prefix}/${verb} ${name}:` : `${prefix}/${verb} ${name} `;
        return { text, label: "/" + v, alias: QueryDsl.verbInfo["/" + verb].long, desc: root.typeDescs[name] || "" };
    }

    // Ctrl+Space AND-narrowing (query-dsl.md): true while a Verb-stage
    // popup is being narrowed by more than one space-separated fragment;
    // `acVerbMultiStart` freezes the char offset of that completion's
    // opening "/". See the Ctrl+Space key handler below.
    property bool acVerbMulti: false
    property int acVerbMultiStart: 0

    function _acCandidates() {
        const t = query.text;

        if (root.acVerbMulti) {
            if (root.acVerbMultiStart < t.length && t[root.acVerbMultiStart] === "/") {
                const frags = t.slice(root.acVerbMultiStart + 1).split(/\s+/).filter(f => f.length > 0);
                const prefix = t.slice(0, root.acVerbMultiStart);
                return root._verbStageUniverse()
                    .filter(v => frags.every(f => v.indexOf(f) >= 0))
                    .map(v => root._verbStageItem(prefix, v));
            }
            root.acVerbMulti = false;
        }

        const vm = t.match(/(?:^|\s|!)(\/[a-z-]*)$/);
        if (vm) {
            const frag = vm[1].slice(1);
            const prefix = t.slice(0, t.length - vm[1].length);
            return root._verbStageUniverse().filter(v => v.indexOf(frag) >= 0).map(v => root._verbStageItem(prefix, v));
        }

        const pm = t.match(/(?:\/fv|\/filter-value|\/s|\/sort)\s+([a-z.]*)$/);
        if (pm && t.indexOf(":", t.length - pm[1].length) < 0) {
            const frag = pm[1];
            const isFv = /\/fv|\/filter-value/.test(t.slice(0, t.length - frag.length));
            return root.typeNames.filter(n => n.indexOf(frag) >= 0).map(n => ({
                text: t.slice(0, t.length - frag.length) + n + (isFv ? ":" : " "),
                label: n, alias: "", desc: root.typeDescs[n] || ""
            }));
        }
        return [];
    }
    // Tab-triggered to *open* (see _triggerCompletion) - typing alone
    // never opens it from nothing, only narrows it once it's already open
    // (query's onTextChanged) - a popup that popped open on every
    // keystroke was obtrusive and could steal focus at the wrong moment.
    // A plain property rather than a binding on query.text since it needs
    // to stay whatever it last was (open or closed) across keystrokes,
    // not recompute unconditionally on every one.
    property var acItems: []
    property int acSel: 0
    // Whether a completion session is open, independent of whether it
    // currently has any candidates to show -- see query's onTextChanged.
    property bool acActive: false
    onAcItemsChanged: {
        // A history popup (Ctrl+R, query-dsl.md's "Search-box history")
        // stays visible even at zero current candidates - unlike every
        // other kind, where zero means "nothing to complete, don't show
        // a popup at all" - same as zsh's own ctrl-r widget always
        // showing its popup (bug found 2026-09-14 testing winswitch's
        // identical gap: a fresh-install empty history made Ctrl+R look
        // completely unbound instead of showing an empty popup).
        ac.visible = acItems.length > 0 || root.acHistoryMode;
        acSel = 0;
        if (!ac.visible) root.acVerbMulti = false;
    }

    function _applyAcItem(it) {
        if (!it) return;
        query.text = it.text;
        query.cursorPosition = query.text.length;
    }

    function acAccept() {
        root._applyAcItem(root.acItems[root.acSel]);
    }

    // Tab's entire job when the popup isn't already open: a single
    // candidate completes immediately with no popup ever shown, same as
    // ordinary shell tab-completion; 2+ reveals the popup (via
    // onAcItemsChanged) so Up/Down can choose one. Returns whether it
    // found anything to do.
    function _triggerCompletion() {
        // Marks the session open the moment Tab is pressed, even if this
        // exact keystroke turns up zero candidates -- onTextChanged below
        // keeps recomputing from here on, so a later edit that makes the
        // fragment valid again reopens the popup on its own instead of
        // requiring another Tab press.
        root.acHistoryMode = false;
        root.acActive = true;
        const items = root._acCandidates();
        if (items.length === 0) return false;
        if (items.length === 1) {
            root._applyAcItem(items[0]);
            return true;
        }
        root.acSel = 0;
        root.acItems = items;
        return true;
    }

    // ---- search-box history (query-dsl.md's "Search-box history") --
    // Ctrl+R reuses the completion popup's own rendering/highlight/accept
    // machinery (acItems/acSel/acAccept/_applyAcItem all already just
    // read-and-replace `it.text` generically) rather than a second popup
    // component - acHistoryMode only changes what *computes* acItems
    // (this vs. _acCandidates) and what typing recomputes against.
    property bool acHistoryMode: false

    // The QML pickers' own approximation of fzf's default fuzzy algorithm
    // (deliberately not this DSL's plain substring rule - see the doc
    // section): ordered-subsequence match, same as fzf's core heuristic
    // without its scoring/highlighting.
    function _fuzzySubsequence(hay, needle) {
        let i = 0;
        for (let j = 0; j < hay.length && i < needle.length; j++)
            if (hay[j] === needle[i]) i++;
        return i === needle.length;
    }

    function _acHistoryCandidates() {
        const q = query.text.toLowerCase();
        const entries = LauncherQueryHistory.listMostRecentFirst();
        const matched = q.length === 0 ? entries
            : entries.filter(e => root._fuzzySubsequence(e.toLowerCase(), q));
        return matched.map(e => ({ text: e, label: e, alias: "", desc: "" }));
    }

    // Ctrl+R: opens unconditionally, even with zero history yet - same as
    // zsh's own ctrl-r widget, which shows its (empty) popup rather than
    // doing nothing the first time there's no history - so the binding is
    // never indistinguishable from unbound.
    function _triggerHistorySearch() {
        root.acHistoryMode = true;
        root.acActive = true;
        root.acSel = 0;
        root.acItems = root._acHistoryCandidates();
        ac.visible = true;
    }

    // Up/Down cycling (query-dsl.md): most-recent-first with draft-restore,
    // scoped to whenever the completion/history popup ISN'T open (see the
    // doc's Up-arrow bullet) - Up/Down there stay popup-highlight
    // movement, and results-list navigation moves to Ctrl+J/Ctrl+K, since
    // this picker (unlike the fzf-native tmux ones) already overloads
    // Up/Down for popup-vs-list depending on state.
    property string acHistDraft: ""
    property int acHistIndex: -1  // -1 = sitting on the draft, not cycling
    property bool _histCycling: false  // guards onTextChanged (below) from
    // treating OUR OWN text-set as a fresh edit that should cancel cycling

    function _setQueryTextForHistory(text) {
        root._histCycling = true;
        query.text = text;
        query.cursorPosition = query.text.length;
        root._histCycling = false;
    }

    function _historyPrev() {
        const entries = LauncherQueryHistory.entries;  // oldest-first
        if (entries.length === 0) return;
        if (root.acHistIndex < 0) {
            root.acHistDraft = query.text;
            root.acHistIndex = entries.length;
        }
        if (root.acHistIndex > 0) {
            root.acHistIndex--;
            root._setQueryTextForHistory(entries[root.acHistIndex]);
        }
    }

    function _historyNext() {
        if (root.acHistIndex < 0) return;  // not cycling - nothing to do
        const entries = LauncherQueryHistory.entries;
        root.acHistIndex++;
        if (root.acHistIndex >= entries.length) {
            root.acHistIndex = -1;
            root._setQueryTextForHistory(root.acHistDraft);
        } else {
            root._setQueryTextForHistory(entries[root.acHistIndex]);
        }
    }

    // ---- dynamic card width: fit the widest visible name -----------
    // Measured imperatively (from onResultsChanged) into a plain property --
    // reading TextMetrics.width inside the width *binding* while also
    // setting its text there is a binding loop.
    TextMetrics {
        id: nameMetrics
        font.family: Theme.fontFamily
        font.pixelSize: Theme.fontSize - 1
    }
    property real _widestName: 0
    function _measure() {
        let w = 0;
        const n = Math.min(root.results.length, 13);
        for (let i = 0; i < n; i++) {
            nameMetrics.text = root.results[i].name;
            if (nameMetrics.width > w) w = nameMetrics.width;
        }
        root._widestName = w;
    }
    // icon gutter (40) + name + right padding (28); floored so the search
    // box always fits, capped so it never sprawls.
    readonly property real cardWidth: root.wsPrompt ? 780 : Math.max(360, Math.min(560, root._widestName + 68))
    // workspace-table column widths (name column takes the rest of the row)
    readonly property int wsColId: 56
    readonly property int wsColWin: 64
    readonly property int wsColMon: 96
    readonly property int wsColApps: 260

    // ---- window -------------------------------------------------
    // Sized box with partial anchors, not a 4-edge full-screen anchor -- the
    // latter is an Overlay surface that doesn't reliably map on every output
    // here (the volume OSD's unresolved bug); NotifLayer proved this shape
    // maps everywhere.
    anchors { top: true; left: true }
    implicitWidth: root.screen ? root.screen.width : 1920
    implicitHeight: root.screen ? root.screen.height : 1080
    color: "transparent"
    visible: root.open
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: root.open ? WlrKeyboardFocus.OnDemand : WlrKeyboardFocus.None
    WlrLayershell.namespace: "quickshell-launcher"
    exclusionMode: ExclusionMode.Ignore

    HyprlandFocusGrab {
        id: focusGrab
        windows: [root]
        onCleared: root.hide()
    }

    // Transparent backdrop -- no dim. Click outside the card closes.
    MouseArea {
        anchors.fill: parent
        onClicked: root.hide()
    }

    Rectangle {
        id: card
        anchors.horizontalCenter: parent.horizontalCenter
        // Pinned by its top edge (where the 60%-tall card's top sits when
        // centred), so the search box never moves when the card's height
        // changes -- only the results area grows/shrinks below it.
        anchors.top: parent.top
        anchors.topMargin: Math.round((root.screen ? root.screen.height : 1080) * 0.2)
        width: root.cardWidth
        // Fixed at 60% of the screen height, centred -- the results list
        // fills whatever's left under the search box (and the autocomplete
        // popup when it's up).
        height: root.wsPrompt
            ? Math.min(Math.round((root.screen ? root.screen.height : 1080) * 0.8),
                       header.height + (ac.visible ? ac.height : 0) + wsHead.height + list.topMargin
                       + root.results.length * 30 + list.bottomMargin + 12)
            : Math.round((root.screen ? root.screen.height : 1080) * 0.6)
        radius: Theme.rounding
        color: Theme.bgAlpha
        // Thin border in the wallpaper-derived accent (scheme.primary).
        border.color: Theme.cyan
        border.width: 1

        Behavior on width { NumberAnimation { duration: 90; easing.type: Easing.OutQuad } }
        // Swallow clicks so they don't reach the backdrop.
        MouseArea { anchors.fill: parent }

        Item {
            id: header
            width: parent.width
            height: 44

            Text {
                id: prompt
                anchors.verticalCenter: parent.verticalCenter
                x: 16
                text: "" // magnifier
                font.family: Theme.iconFontFamily
                font.pixelSize: Theme.fontSize
                color: Theme.textDim
            }

            TextInput {
                id: query
                anchors.verticalCenter: parent.verticalCenter
                x: 40
                width: parent.width - 56
                font.family: Theme.fontFamily
                font.pixelSize: Theme.fontSize + 1
                color: Theme.text
                selectionColor: Theme.cyan
                selectByMouse: true
                clip: true
                // Once a session is open (`acActive`, set by Tab -- see
                // _triggerCompletion), keep recomputing candidates from the
                // new text instead of clearing -- narrows the list as you
                // type (e.g. `/` + Tab shows every verb, typing `f` narrows
                // to /fv) rather than closing and forcing another Tab press.
                // Gated on `acActive`, not `ac.visible`: the popup itself
                // hides the instant candidates drop to zero (e.g. a typo),
                // but the session stays open, so fixing the typo recomputes
                // and reopens it rather than dead-ending until another Tab
                // (the same bug reported 2026-09-13 against winswitch's
                // identical pattern: "/cla tt" -> zero candidates hid the
                // popup, and correcting it never brought the list back).
                // Typing while no session is open still doesn't
                // spontaneously show anything, matching "Tab-triggered,
                // never live". Also fires (harmlessly) when accepting a
                // completion sets this text itself, on an already-open
                // (fine, recomputes to the same thing) or already-closed
                // (no-op) session.
                onTextChanged: {
                    // A real edit cancels an in-progress Up/Down history
                    // cycle (query-dsl.md: editing invalidates the cycle
                    // the same way it does in a real shell) - but not when
                    // WE just set the text ourselves while cycling.
                    if (!root._histCycling) root.acHistIndex = -1;
                    root.acItems = root.acActive
                        ? (root.acHistoryMode ? root._acHistoryCandidates() : root._acCandidates())
                        : [];
                }

                Text {
                    anchors.verticalCenter: parent.verticalCenter
                    text: root.wsPrompt ? (root.promptKind === "workspace" ? qsTr("move this workspace after   ·   pick one") : qsTr("move window to workspace   ·   pick or type a new name")) : ""
                    color: Theme.muted
                    font: query.font
                    visible: query.text.length === 0
                }

                // Inline command-validity coloring (query-dsl.md): an
                // underline under each `/command` token, not a recolored
                // glyph - TextInput has no per-range text styling to hook
                // (unlike GTK's Pango-backed Entry, see winswitch's
                // apply_command_colors), and coloring the *whole* input
                // would falsely tint bare filter words alongside it, so an
                // underline positioned via positionToRectangle (already
                // scroll-adjusted, unlike a manual TextMetrics measurement)
                // is the safe middle ground: real color signal, zero risk
                // to the TextInput's own text/cursor/selection rendering.
                DslHighlight { input: query; spans: query.text.length ? root._commandSpans(query.text) : [] }

                // Standard completion-menu convention (reported 2026-09-09
                // against winswitch's identical pattern -- accepting on
                // every Tab press without ever letting you cycle through
                // options was confusing): the first Tab opens the popup;
                // every Tab after that just moves the highlight, the same
                // as Down/Ctrl+j; Enter is the one key that actually
                // accepts the highlighted suggestion.
                // Hold-to-repeat for list/popup navigation (Ctrl+J/K,
                // arrows, PageUp/Down): the held key re-fires its own step
                // on a timer rather than relying on this layer-shell
                // surface forwarding Qt's own key-repeat, which isn't
                // guaranteed -- same reasoning as the CTRL+ALT+h/l
                // Hyprland-side repeat fix.
                property var _navRepeatFn: null
                Timer { id: navRepeatDelay; interval: 600; onTriggered: navRepeatTimer.start() }
                Timer { id: navRepeatTimer; interval: 40; repeat: true; onTriggered: if (query._navRepeatFn) query._navRepeatFn() }
                function _startNavRepeat(fn) {
                    _navRepeatFn = fn;
                    fn();
                    navRepeatDelay.restart();
                }
                function _stopNavRepeat() {
                    navRepeatDelay.stop();
                    navRepeatTimer.stop();
                    _navRepeatFn = null;
                }
                // The Wayland/Qt stack here delivers native key-repeat as a
                // flood of RELEASE events flagged isAutoRepeat=true (not
                // repeated press events) -- confirmed live 2026-10-04, see
                // the mirrored PRESS/START/DELAY/dozens-of-RELEASE+STOP
                // sequence in `journalctl --user -u quickshell.service`.
                // Without this guard, the very first synthetic release
                // landed within milliseconds of arming the delay timer and
                // killed the repeat before a single tick could fire --
                // exactly the "moves once, then nothing" symptom reported.
                // Only a genuine key-up should actually stop it.
                Keys.onReleased: event => { if (!event.isAutoRepeat) _stopNavRepeat(); }

                // zsh-autosuggestions (query-dsl.md "Search-box history"): greyed-out
                // rest of the newest history entry starting with the text; Right, End
                // or Ctrl+F at the end of the text takes it.
                readonly property string ghost:
                    (cursorPosition === text.length && !(ac.visible)) ? LauncherQueryHistory.suggest(text) : ""
                // Measured from the text itself, not positionToRectangle():
                // that reads TextInput's layout, which updates after this
                // binding re-evaluates, leaving the ghost one keystroke behind.
                TextMetrics {
                    id: ghostMetrics
                    font: query.font
                    text: query.text
                }
                Text {
                    visible: query.ghost.length > 0
                    x: ghostMetrics.advanceWidth
                    y: query.positionToRectangle(query.text.length).y
                    text: query.ghost
                    color: Theme.muted
                    font: query.font
                }
                Keys.onPressed: event => {
                    if (query.ghost.length > 0 && !((event.modifiers & Qt.ShiftModifier))
                            && ((event.key === Qt.Key_Right && !(event.modifiers & ~Qt.KeypadModifier))
                                || event.key === Qt.Key_End
                                || (event.key === Qt.Key_F && (event.modifiers & Qt.ControlModifier)))) {
                        query.insert(query.text.length, query.ghost);
                        event.accepted = true;
                        return;
                    }
                    if (event.key === Qt.Key_Escape) {
                        if (ac.visible) { ac.visible = false; root.acVerbMulti = false; root.acActive = false; root.acHistoryMode = false; }
                        else if (root.wsPrompt) { root.wsPrompt = false; query.text = ""; root.selected = 0; }
                        else root.hide();
                        event.accepted = true;
                    } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                        if (ac.visible) root.acAccept();
                        else root.launch(root.selected);
                        event.accepted = true;
                    } else if (event.key === Qt.Key_Tab) {
                        // Tab accepts the highlighted suggestion (same as
                        // Space); Shift+Tab still steps the highlight back.
                        if (ac.visible && (event.modifiers & Qt.ShiftModifier))
                            root.acSel = (root.acSel - 1 + root.acItems.length) % root.acItems.length;
                        else if (ac.visible)
                            root.acAccept();
                        else
                            root._triggerCompletion();
                        event.accepted = true;
                    } else if (event.key === Qt.Key_Space && !ac.visible && (event.modifiers & Qt.ControlModifier)) {
                        // Ctrl+Space also opens completion, same as Tab
                        // (query-dsl.md Autocompletion section) -
                        // ClipboardPicker.qml/NotificationPicker.qml's
                        // reference implementation, ported here.
                        root._triggerCompletion();
                        event.accepted = true;
                    } else if (event.key === Qt.Key_Space && ac.visible && (event.modifiers & Qt.ControlModifier)) {
                        // AND-narrows instead of accepting (query-dsl.md):
                        // only meaningful once the popup's on a Verb-stage
                        // fragment - `_acCandidates`'s multi branch is a
                        // no-op otherwise (empty universe cross), so this
                        // just always tries it rather than re-deriving the
                        // current stage here too.
                        const vm = query.text.match(/(?:^|\s|!)(\/[a-z-]*)$/);
                        if (vm || root.acVerbMulti) {
                            if (!root.acVerbMulti) {
                                root.acVerbMulti = true;
                                root.acVerbMultiStart = query.text.length - vm[1].length;
                            }
                            query.insert(query.cursorPosition, " ");
                        }
                        event.accepted = true;
                    } else if (event.key === Qt.Key_Space && ac.visible) {
                        root.acAccept();
                        event.accepted = true;
                    } else if (event.key === Qt.Key_R && (event.modifiers & Qt.ControlModifier)) {
                        // query-dsl.md's "Search-box history": always
                        // (re)opens, even with an empty history file yet.
                        root._triggerHistorySearch();
                        event.accepted = true;
                    } else if (event.key === Qt.Key_Down) {
                        // Popup open: highlight-move, unchanged. Popup
                        // closed: history-cycle instead of list-nav - see
                        // acHistIndex's own comment for why this picker
                        // can't just reuse Ctrl+J/Ctrl+K's dual-purpose
                        // trick the way it does for Tab-completion.
                        if (ac.visible) root.acSel = Math.min(root.acItems.length - 1, root.acSel + 1);
                        else root._historyNext();
                        event.accepted = true;
                    } else if (event.key === Qt.Key_Up) {
                        if (ac.visible) root.acSel = Math.max(0, root.acSel - 1);
                        else root._historyPrev();
                        event.accepted = true;
                    } else if (event.key === Qt.Key_J && (event.modifiers & Qt.ControlModifier)) {
                        if (!event.isAutoRepeat) _startNavRepeat(() => {
                            if (ac.visible) {
                                root.acSel = Math.min(root.acItems.length - 1, root.acSel + 1);
                            } else {
                                root.selected = Math.min(root.results.length - 1, root.selected + 1);
                                LauncherQueryHistory.record(query.text);
                            }
                        });
                        event.accepted = true;
                    } else if (event.key === Qt.Key_K && (event.modifiers & Qt.ControlModifier)) {
                        if (!event.isAutoRepeat) _startNavRepeat(() => {
                            if (ac.visible) {
                                root.acSel = Math.max(0, root.acSel - 1);
                            } else {
                                root.selected = Math.max(0, root.selected - 1);
                                LauncherQueryHistory.record(query.text);
                            }
                        });
                        event.accepted = true;
                    } else if (event.key === Qt.Key_PageDown) {
                        if (!event.isAutoRepeat) _startNavRepeat(() => {
                            if (ac.visible) {
                                root.acSel = Math.min(root.acItems.length - 1, root.acSel + 7);
                            } else {
                                root.selected = Math.min(root.results.length - 1,
                                                          root.selected + Math.max(1, Math.floor(list.height / 30)));
                                list.positionViewAtIndex(root.selected, ListView.Contain);
                                LauncherQueryHistory.record(query.text);
                            }
                        });
                        event.accepted = true;
                    } else if (event.key === Qt.Key_PageUp) {
                        if (!event.isAutoRepeat) _startNavRepeat(() => {
                            if (ac.visible) {
                                root.acSel = Math.max(0, root.acSel - 7);
                            } else {
                                root.selected = Math.max(0, root.selected - Math.max(1, Math.floor(list.height / 30)));
                                list.positionViewAtIndex(root.selected, ListView.Contain);
                                LauncherQueryHistory.record(query.text);
                            }
                        });
                        event.accepted = true;
                    }
                }
            }

            Rectangle { // divider
                anchors.bottom: parent.bottom
                width: parent.width
                height: 1
                color: Theme.border
            }
        }

        // Autocomplete popup, in-layout under the header (like the GTK
        // pickers). Each row: label, then the long-form alias and a
        // one-line description, both dim (marginalia).
        Column {
            id: ac
            visible: false
            anchors.top: header.bottom
            width: parent.width
            height: visible ? Math.min(root.acItems.length, 7) * 24 + 8 : 0
            clip: true
            padding: 4

            Repeater {
                model: root.acItems
                Rectangle {
                    id: acRow
                    required property var modelData
                    required property int index
                    readonly property bool cur: index === root.acSel
                    width: ac.width - 8
                    height: 24
                    radius: Theme.rounding - 5
                    color: cur ? Qt.rgba(Theme.cyan.r, Theme.cyan.g, Theme.cyan.b, 0.18) : "transparent"

                    Row {
                        id: acFields
                        anchors.verticalCenter: parent.verticalCenter
                        x: 10
                        spacing: 8

                        Text {
                            id: acLabel
                            text: acRow.modelData.label
                            font.family: Theme.fontFamily
                            font.pixelSize: Theme.fontSize - 1
                            color: acRow.cur ? Theme.cyan : Theme.text
                        }
                        Text {
                            visible: !!acRow.modelData.alias
                            anchors.baseline: acLabel.baseline
                            text: "(" + acRow.modelData.alias + ")"
                            font.family: Theme.fontFamily
                            font.pixelSize: Theme.fontSize - 2
                            color: Theme.muted
                        }
                        Text {
                            anchors.baseline: acLabel.baseline
                            text: acRow.modelData.desc
                            font.family: Theme.fontFamily
                            font.pixelSize: Theme.fontSize - 2
                            color: Theme.textDim
                        }
                    }

                    MouseArea {
                        anchors.fill: parent
                        onClicked: { root.acSel = acRow.index; root.acAccept(); }
                    }
                }
            }
        }

        // Column header of the workspace table (second-stage lists only),
        // same dim small-caps-less style as mod+v's column headers.
        Row {
            id: wsHead
            visible: root.wsPrompt
            anchors.top: ac.visible ? ac.bottom : header.bottom
            x: 12
            width: parent.width - 24
            height: visible ? 18 : 0
            spacing: 10
            readonly property real nameW: width - root.wsColId - root.wsColWin - root.wsColMon - root.wsColApps - 4 * spacing
            Repeater {
                model: [
                    { t: "workspace", w: wsHead.nameW, a: Text.AlignLeft },
                    { t: "id", w: root.wsColId, a: Text.AlignRight },
                    { t: "windows", w: root.wsColWin, a: Text.AlignRight },
                    { t: "monitor", w: root.wsColMon, a: Text.AlignLeft },
                    { t: "apps", w: root.wsColApps, a: Text.AlignLeft }
                ]
                Text {
                    required property var modelData
                    width: modelData.w
                    horizontalAlignment: modelData.a
                    text: modelData.t
                    font.family: Theme.fontFamily
                    font.pixelSize: Theme.fontSize - 2
                    color: Theme.text
                    opacity: 0.55
                }
            }
        }

        ListView {
            id: list
            anchors.top: root.wsPrompt ? wsHead.bottom : (ac.visible ? ac.bottom : header.bottom)
            anchors.bottom: parent.bottom
            width: parent.width
            clip: true
            model: root.results
            currentIndex: root.selected
            // The built-in follow-current-item scroll animates over
            // highlightMoveDuration, so a page jump's selection showed up
            // offscreen and the view crept after it. Snap it instead; the
            // page keys also positionViewAtIndex directly for the same reason.
            highlightMoveDuration: 0
            boundsBehavior: Flickable.StopAtBounds
            topMargin: 4
            bottomMargin: 4

            // One compact line per entry: icon + name -- plus, once a
            // `/fv field:value` term is actively scoping the query, a second
            // dim line showing that field's own value (query-dsl.md's
            // "Auto-shown filter fields") - this launcher has no general
            // column system, but a hidden field (comment/keywords/...) that
            // matched shouldn't stay invisible once there's more than one
            // candidate left to choose between.
            delegate: Rectangle {
                id: row
                required property var modelData
                required property int index
                readonly property string extraText: {
                    if (modelData.ws) return "";
                    if (modelData.action) return modelData.detail;
                    if (root.referencedFields.length === 0) return "";
                    const parts = [];
                    for (const f of root.referencedFields)
                        for (const v of root._fieldVals(modelData, f)) {
                            const s = String(v);
                            if (s) parts.push(s);
                        }
                    return parts.join("  ·  ");
                }
                width: list.width
                height: row.extraText ? 44 : 30
                color: index === root.selected ? Qt.rgba(Theme.cyan.r, Theme.cyan.g, Theme.cyan.b, 0.16)
                                               : "transparent"

                Row {
                    visible: !!row.modelData.ws
                    x: 12
                    width: parent.width - 24
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: 10
                    readonly property real nameW: width - root.wsColId - root.wsColWin - root.wsColMon - root.wsColApps - 4 * spacing
                    Repeater {
                        model: row.modelData.ws ? [
                            { t: row.modelData.name, w: parent.nameW, a: Text.AlignLeft, hi: true },
                            { t: row.modelData.create ? "" : String(row.modelData.id), w: root.wsColId, a: Text.AlignRight },
                            { t: row.modelData.cnt < 0 ? "" : String(row.modelData.cnt), w: root.wsColWin, a: Text.AlignRight },
                            { t: row.modelData.mon, w: root.wsColMon, a: Text.AlignLeft },
                            { t: row.modelData.apps, w: root.wsColApps, a: Text.AlignLeft }
                        ] : []
                        Text {
                            required property var modelData
                            width: modelData.w
                            horizontalAlignment: modelData.a
                            elide: Text.ElideRight
                            text: modelData.t
                            font.family: Theme.fontFamily
                            font.pixelSize: Theme.fontSize - 1
                            color: modelData.hi ? Theme.text : Theme.textDim
                        }
                    }
                }

                Image {
                    id: appIcon
                    visible: !row.modelData.ws
                    x: 10
                    anchors.verticalCenter: parent.verticalCenter
                    width: 20
                    height: 20
                    sourceSize.width: 40
                    sourceSize.height: 40
                    fillMode: Image.PreserveAspectFit
                    asynchronous: true
                    // Our own XDG resolution first, quickshell's provider as
                    // a fallback for anything it misses.
                    source: (modelData.ws || modelData.action) ? ""
                            : (LauncherIcons.pathFor(modelData.entry.icon)
                               || Quickshell.iconPath(modelData.entry.icon, "application-x-executable"))
                }
                // Generic glyph when no icon resolves at all.
                Text {
                    anchors.centerIn: appIcon
                    visible: !row.modelData.ws && appIcon.status !== Image.Ready
                    text: ""
                    font.family: Theme.iconFontFamily
                    font.pixelSize: 14
                    color: Theme.textDim
                }

                Column {
                    visible: !row.modelData.ws
                    x: 40
                    anchors.verticalCenter: parent.verticalCenter
                    width: parent.width - 52
                    spacing: 1

                    Text {
                        width: parent.width
                        text: row.modelData.name
                        elide: Text.ElideRight
                        font.family: Theme.fontFamily
                        font.pixelSize: Theme.fontSize - 1
                        color: Theme.text
                    }
                    Text {
                        visible: !!row.extraText
                        width: parent.width
                        text: row.extraText
                        elide: Text.ElideRight
                        font.family: Theme.fontFamily
                        font.pixelSize: Theme.fontSize - 2
                        color: Theme.textDim
                        opacity: 0.7
                    }
                }

                MouseArea {
                    anchors.fill: parent
                    hoverEnabled: true
                    id: rowHover
                    onPositionChanged: mouse => { if (root._pointerMoved(rowHover, mouse)) root.selected = index; }
                    onClicked: root.launch(index)
                }
            }
        }
    }
}

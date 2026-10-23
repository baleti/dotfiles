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
// searchable but only when named (`/fv comment:vector`). /s for
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
            // snap to the default width (no animation from the last
            // session's width); re-armed once the first results settle
            root._animWidth = false;
            widthArm.restart();
            query.text = "";
            root.selected = 0;
            root.acVerbMulti = false; root.acArgMulti = false;
            root.acHistoryMode = false;
            focusGrab.active = true;
            if (LauncherState.pendingQuery !== "") {
                // handed over from the native launcher: keep what was typed there
                query.text = LauncherState.pendingQuery;
                LauncherState.pendingQuery = "";
                Qt.callLater(() => { query.forceActiveFocus(); query.cursorPosition = query.text.length; });
            } else
                Qt.callLater(() => query.forceActiveFocus());
        } else {
            focusGrab.active = false;
        }
    }
    property bool _animWidth: true
    Timer { id: widthArm; interval: 150; onTriggered: root._animWidth = true }
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
        "/move-to-workspace": "move focused window to a workspace",
        "/move-workspace": "move this workspace after another",
        "/add-workspace": "add an empty workspace after this one"
    })
    readonly property var _actionMatch: query.text.match(/^\s*(\/move-to-workspace|\/move-workspace)(?:\s+(.*))?$/)
    // Typing the full verb swaps the results for the workspace list in
    // place; whatever follows the verb is the filter / the target name.
    readonly property bool wsPrompt: root._actionMatch !== null
    // which action the workspace list serves: "window" | "workspace"
    readonly property string promptKind: !root._actionMatch ? "window" : root._actionMatch[1] === "/move-workspace" ? "workspace" : "window"
    readonly property bool actionMode: root.wsPrompt
    readonly property string actionArg: root._actionMatch && root._actionMatch[2] ? root._actionMatch[2].trim() : ""

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
            out[n.toLowerCase() === arg ? "unshift" : "push"]({ ws: true, name: n, target: n, id: w.id, cnt: tl.length,
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

    // /add-workspace: an empty workspace at the smallest unused id above the
    // current one and focused (the existing empty-workspace cleanup removes it
    // once focus leaves). No name = the first free integer above the current
    // workspace's number (order of names doesn't matter, only list position).
    function addWorkspace(row) {
        const lua = "local cur = hl.get_workspace(" + LauncherState.workspaceId + ") "
            + "local used, names = {}, {} for _, x in ipairs(hl.get_workspaces()) do used[x.id] = true names[tostring(x.name)] = true end "
            + "local name = " + root._luaStr(row.target) + " "
            + "if name == '' then local base = cur and tonumber(cur.name) or 0 "
            + "local n = math.floor(base) + 1 while names[tostring(n)] do n = n + 1 end name = tostring(n) end "
            + "if names[name] then return end "
            + "local anchor = cur and cur.id or 0 "
            + "local id = anchor + 1 "
            // id cur+1 is taken: shift the contiguous run of workspaces
            // above the current one up by one (windows move, names are
            // kept) so the new one really lands right after it. Skipped
            // (falls back to the first free id) when a window in the run
            // is grouped or a run workspace is showing on another monitor.
            + "if used[id] then local k = id while used[k + 1] do k = k + 1 end local ok = true "
            + "local by = {} for _, w in ipairs(hl.get_windows()) do local wid = w.workspace.id "
            + "if wid >= id and wid <= k then if w.group then ok = false end by[wid] = by[wid] or {} table.insert(by[wid], w) end end "
            + "for _, m in ipairs(hl.get_monitors()) do local a = m.active_workspace if a and a.id >= id and a.id <= k and not m.focused then ok = false end end "
            + "if ok then local nm = {} for _, x in ipairs(hl.get_workspaces()) do nm[x.id] = x.name end "
            + "for i = k, id, -1 do if by[i] then for _, w in ipairs(by[i]) do hl.dispatch(hl.dsp.window.move({ workspace = i + 1, window = w, follow = false })) end "
            + "hl.dispatch(hl.dsp.workspace.rename({ workspace = i + 1, name = nm[i] })) end end "
            + "else while used[id] do id = id + 1 end end end "
            + "hl.dispatch(hl.dsp.focus({ workspace = id })) "
            + "hl.dispatch(hl.dsp.workspace.rename({ workspace = id, name = name }))";
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
            // above the window's workspace, then named via rename (also for
            // numeric names like 37, which are names here, not ids).
            lua = find + "local used = {} for _, x in ipairs(hl.get_workspaces()) do used[x.id] = true end "
                + "local id = w.workspace.id + 1 while used[id] do id = id + 1 end "
                + "hl.dispatch(hl.dsp.window.move({ workspace = id, window = w })) "
                + "hl.dispatch(hl.dsp.workspace.rename({ workspace = id, name = " + root._luaStr(t) + " })) break end end";
        } else {
            const ws = row.id !== undefined ? String(row.id) : /^[0-9]+$/.test(t) ? t : root._luaStr("name:" + t);
            lua = find + "hl.dispatch(hl.dsp.window.move({ workspace = " + ws + ", window = w })) break end end";
        }
        moveProc.exec(["hyprctl", "repl", lua]);
    }
    // Workspaces created/renamed/shifted through `hyprctl repl` can leave
    // quickshell's workspace model (and so the bar pill) missing entries
    // until the next event, so re-query once the command is done.
    Process { id: moveProc; onExited: { Hyprland.refreshWorkspaces(); refreshTimer.restart(); } }
    Timer { id: refreshTimer; interval: 400; onTriggered: Hyprland.refreshWorkspaces() }

    // completions (verbs, /fv paths, history) are rows of the list too
    readonly property var _comps: root.acItems.map(it => ({ comp: true, action: true, item: it, name: it.label,
        detail: (it.alias ? "(" + it.alias + ") " : "") + it.desc, entry: { icon: "" } }))
    // /group: sections folded by clicking a header (or Ctrl+G on the selected row); reset when the query changes
    property var groupCollapsed: ({})
    readonly property var groupParsed: root.actionMode ? null : QueryDsl.parseGroup(root.parsed.groupRaw, root.typeNames)
    readonly property var groupView: {
        if (!root.groupParsed || root.acHistoryMode) return null;
        const d = QueryDsl.groupDisplay(root._rowsSorted, root.groupParsed, (a, f) => String(root._fieldVals(a, f)[0] || ""), root.groupCollapsed);
        return { display: d, mm: QueryDsl.groupModel(root._comps, d) };
    }
    onGroupParsedChanged: root.groupCollapsed = ({})
    function toggleGroup(id) {
        const c = Object.assign({}, root.groupCollapsed);
        if (c[id]) delete c[id]; else c[id] = true;
        root.groupCollapsed = c;
    }

    readonly property var results: {
        if (root.actionMode)
            return root.workspaceRows;
        if (root.acHistoryMode) return root._comps;
        return root._comps.concat(root.groupView ? root.groupView.display.rows : root._rowsSorted);
    }

    readonly property var _rowsSorted: {
        if (root.actionMode || root.acHistoryMode) return [];
        let rows = root.apps.filter(app => root.parsed.terms.every(t => root._matches(app, t)));

        const s = root.parsed.sort;
        // Each key resolves to one or more fields (fuzzy keys expand, query-dsl.md "Keys");
        // a key that names nothing makes the *whole* /sort inert,
        // not just that key -- falls through to the default order below.
        const keys = s ? QueryDsl.resolveSortKeys(s.fields, root.typeNames) : null;
        if (s && keys !== null) {
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
        if (app.comp) {
            root._applyAcItem(app.item);
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
    readonly property var _acVerbs: ["/fv", "/s"] // /ft /at /rt are inert here

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
    // command. See query-dsl.md's
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
    // opening "/". A deep candidate lands the one syntax ("/fv/comment ",
    // "/s/name"), see query-dsl.md "Grammar".
    function _verbStageItem(prefix, v) {
        const slash = v.indexOf("/");
        if (slash < 0 && root.actionVerbs["/" + v] !== undefined)
            return { text: prefix + "/" + v + " ", label: "/" + v, alias: "", desc: root.actionVerbs["/" + v] };
        if (slash < 0) {
            return { text: prefix + "/" + v + " ", label: "/" + v,
                     alias: QueryDsl.verbInfo["/" + v].long, desc: QueryDsl.verbInfo["/" + v].desc };
        }
        const verb = v.slice(0, slash), name = v.slice(slash + 1);
        const text = `${prefix}/${verb}/${name}` + (verb === "fv" ? " " : "");
        return { text, label: "/" + v, alias: QueryDsl.verbInfo["/" + verb].long, desc: root.typeDescs[name] || "" };
    }

    // Ctrl+Space AND-narrowing (query-dsl.md): true while a Verb-stage
    // popup is being narrowed by more than one space-separated fragment;
    // `acVerbMultiStart` freezes the char offset of that completion's
    // opening "/". See the Ctrl+Space key handler below.
    property bool acVerbMulti: false
    property int acVerbMultiStart: 0

    // Ctrl+Space AND-narrowing for the non-Verb popups (type-path, value,
    // sort direction): "//cla" + Tab + Ctrl+Space + "fts" keeps the
    // candidates matching both. `acArgMultiStart` freezes where the fragment
    // began; the first word is completed as usual (via the `tIn` re-entry
    // below) and the rest are ANDed against each candidate's label.
    property bool acArgMulti: false
    property int acArgMultiStart: 0

    function _acCandidates(tIn) {
        if (tIn === undefined && root.acArgMulti) {
            const full = query.text;
            if (root.acArgMultiStart <= full.length) {
                const frags = full.slice(root.acArgMultiStart).split(/\s+/).filter(f => f.length > 0);
                return root._acCandidates(full.slice(0, root.acArgMultiStart) + (frags.length > 0 ? frags[0] : ""))
                    .filter(it => frags.slice(1).every(f => String(it.label).indexOf(f) >= 0));
            }
            root.acArgMulti = false;
        }
        const t = tIn !== undefined ? tIn : query.text;

        if (root.acVerbMulti) {
            if (root.acVerbMultiStart < t.length && t[root.acVerbMultiStart] === "/") {
                const frags = t.slice(root.acVerbMultiStart + 1).split(/\s+/).filter(f => f.length > 0);
                const prefix = t.slice(0, root.acVerbMultiStart);
                return root._verbStageUniverse()
                    .filter(v => frags.every(f => v.indexOf(f) >= 0))
                    .map(v => root._verbStageItem(prefix, v));
            }
            root.acVerbMulti = false; root.acArgMulti = false;
        }

        const ks = QueryDsl.keyStageCandidates(t, root.typeNames, root.typeDescs);
        if (ks !== null) return ks;

        const vm = t.match(/(?:^|\s|!)(\/[a-z-]*)$/);
        if (vm) {
            const frag = vm[1].slice(1);
            const prefix = t.slice(0, t.length - vm[1].length);
            return root._verbStageUniverse().filter(v => v.indexOf(frag) >= 0).map(v => root._verbStageItem(prefix, v));
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
    onAcItemsChanged: {
        root.selected = 0;
        if (acItems.length === 0) { root.acVerbMulti = false; root.acArgMulti = false; }
    }

    function _applyAcItem(it) {
        if (!it) return;
        // choosing an entry of the Ctrl+R history popup ends it (query-dsl.md "Search-box
        // history"); close before the text changes, or the text-change recompute reopens it
        if (root.acHistoryMode) {
            root.acHistoryMode = false;
            root.acItems = [];
        }
        if (/\/add-workspace\s*$/.test(it.text)) {
            LauncherQueryHistory.record("/add-workspace");
            root.addWorkspace({ target: "" });
            root.hide();
            return;
        }
        query.text = it.text;
        query.cursorPosition = query.text.length;
    }

    // ---- search-box history (query-dsl.md's "Search-box history") --
    // Ctrl+R reuses the completion popup's own rendering/highlight/accept
    // machinery (acItems/_applyAcItem all already just
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
        root.acItems = root._acHistoryCandidates();
    }

    // Up/Down cycling (query-dsl.md): most-recent-first with draft-restore,
    // scoped to whenever the completion/history popup ISN'T open (see the
    // doc's Up-arrow bullet) - Up/Down there stay popup-highlight
    // movement, and results-list navigation moves to Ctrl+J/Ctrl+K, since
    // this picker (unlike the fzf-native tmux ones) already overloads
    // Up/Down for popup-vs-list depending on state.
    property string acHistDraft: ""
    property int acHistIndex: -1  // -1 = sitting on the draft, not cycling
    // Down/Ctrl+J walked the results from the search box: Up/Ctrl+K then walks
    // them back up (until the first row) instead of cycling history. Cleared by
    // any text change (history cycling included).
    property bool resultsWalked: false
    function _upKey() {
        if (root.resultsWalked && root.selected > 0) root.selected = root.selected - 1;
        else { root.resultsWalked = false; root._historyPrev(); }
    }
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
            ? Math.min(Math.round((root.screen ? root.screen.height : 1080) * 0.6),
                       header.height + wsHead.height + list.topMargin
                       + root.results.length * 30 + list.bottomMargin + 12)
            : Math.round((root.screen ? root.screen.height : 1080) * 0.6)
        radius: Theme.rounding
        color: Theme.bgAlpha
        // Thin border in the wallpaper-derived accent (scheme.primary).
        border.color: Theme.cyan
        border.width: 1

        Behavior on width { enabled: root._animWidth; NumberAnimation { duration: 90; easing.type: Easing.OutQuad } }
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
                // Completions are live: every edit recomputes them, and they
                // show as the first rows of the main results list.
                onTextChanged: {
                    // A real edit cancels an in-progress Up/Down history
                    // cycle (query-dsl.md: editing invalidates the cycle
                    // the same way it does in a real shell) - but not when
                    // WE just set the text ourselves while cycling.
                    if (!root._histCycling) root.acHistIndex = -1;
                    root.resultsWalked = false;
                    root.acItems = root.acHistoryMode ? root._acHistoryCandidates() : root._acCandidates();
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
                    (cursorPosition === text.length && root.acItems.length === 0) ? LauncherQueryHistory.suggest(text) : ""
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
                        if (root.acHistoryMode) { root.acHistoryMode = false; root.acItems = root._acCandidates(); }
                        else root.hide();
                        event.accepted = true;
                    } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                        root.launch(root.selected);
                        event.accepted = true;
                    } else if (event.key === Qt.Key_G && (event.modifiers & Qt.ControlModifier) && root.groupView) {
                        // fold / unfold the /group section of the selected row
                        const gid = QueryDsl.groupOfRow(root.groupView.display, root.selected - root._comps.length);
                        if (gid) root.toggleGroup(gid);
                        event.accepted = true;
                    } else if (event.key === Qt.Key_Tab) {
                        // Tab accepts the highlighted completion row, else the first one
                        const cur = root.results[root.selected];
                        if (cur && cur.comp) root._applyAcItem(cur.item);
                        else if (root.acItems.length > 0) root._applyAcItem(root.acItems[0]);
                        event.accepted = true;
                    } else if (event.key === Qt.Key_Space && (event.modifiers & Qt.ControlModifier)) {
                        // AND-narrows (query-dsl.md): only meaningful on a
                        // Verb-stage / path fragment with candidates showing
                        const vm = query.text.match(/(?:^|\s|!)(\/[a-z-]*)$/);
                        if (vm || root.acVerbMulti) {
                            if (!root.acVerbMulti) {
                                root.acVerbMulti = true;
                                root.acVerbMultiStart = query.text.length - vm[1].length;
                            }
                            query.insert(query.cursorPosition, " ");
                        } else if (root.acArgMulti || root.acItems.length > 0) {
                            if (!root.acArgMulti) {
                                root.acArgMulti = true;
                                root.acArgMultiStart = query.text.search(/[^\s:\/]*$/);
                            }
                            query.insert(query.cursorPosition, " ");
                        }
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
                        if (root.acHistIndex >= 0) root._historyNext();
                        else { root.selected = Math.min(root.results.length - 1, root.selected + 1); root.resultsWalked = true; } // single-focus: Down walks the results
                        event.accepted = true;
                    } else if (event.key === Qt.Key_Up) {
                        root._upKey();
                        event.accepted = true;
                    } else if (event.key === Qt.Key_J && (event.modifiers & Qt.ControlModifier) ) {
                        // query-dsl.md "Search-box history": Ctrl+J == Down
                        // (forward through history only once Up/Ctrl+K has
                        // started cycling, else walk the results).
                        if (root.acHistIndex >= 0) root._historyNext();
                        else {
                            root.selected = Math.min(root.results.length - 1, root.selected + 1);
                            root.resultsWalked = true;
                            LauncherQueryHistory.record(query.text);
                        }
                        event.accepted = true;
                    } else if (event.key === Qt.Key_K && (event.modifiers & Qt.ControlModifier) ) {
                        root._upKey(); // Ctrl+K == Up
                        event.accepted = true;
                    } else if (event.key === Qt.Key_J && (event.modifiers & Qt.ControlModifier)) {
                        if (!event.isAutoRepeat) _startNavRepeat(() => {
                            {
                                root.selected = Math.min(root.results.length - 1, root.selected + 1);
                                LauncherQueryHistory.record(query.text);
                            }
                        });
                        event.accepted = true;
                    } else if (event.key === Qt.Key_K && (event.modifiers & Qt.ControlModifier)) {
                        if (!event.isAutoRepeat) _startNavRepeat(() => {
                            {
                                root.selected = Math.max(0, root.selected - 1);
                                LauncherQueryHistory.record(query.text);
                            }
                        });
                        event.accepted = true;
                    } else if (event.key === Qt.Key_PageDown) {
                        if (!event.isAutoRepeat) _startNavRepeat(() => {
                            {
                                root.selected = Math.min(root.results.length - 1,
                                                          root.selected + Math.max(1, Math.floor(list.height / 30)));
                                list.positionViewAtIndex(root.groupView ? root.groupView.mm.vOf.indexOf(root.selected) : root.selected, ListView.Contain);
                                LauncherQueryHistory.record(query.text);
                            }
                        });
                        event.accepted = true;
                    } else if (event.key === Qt.Key_PageUp) {
                        if (!event.isAutoRepeat) _startNavRepeat(() => {
                            {
                                root.selected = Math.max(0, root.selected - Math.max(1, Math.floor(list.height / 30)));
                                list.positionViewAtIndex(root.groupView ? root.groupView.mm.vOf.indexOf(root.selected) : root.selected, ListView.Contain);
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

        // Column header of the workspace table (second-stage lists only),
        // same dim small-caps-less style as mod+v's column headers.
        Row {
            id: wsHead
            visible: root.wsPrompt
            anchors.top: header.bottom
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
            anchors.top: root.wsPrompt ? wsHead.bottom : header.bottom
            anchors.bottom: parent.bottom
            width: parent.width
            clip: true
            model: root.groupView ? root.groupView.mm.model : root.results
            currentIndex: root.groupView ? root.groupView.mm.vOf.indexOf(root.selected) : root.selected
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
                // position in root.results (a /group header has none, and is never selected)
                readonly property int logical: root.groupView ? root.groupView.mm.vOf[index] : index
                readonly property bool isGroup: !!modelData.grp
                readonly property string extraText: {
                    if (modelData.ws || modelData.grp) return "";
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
                height: row.isGroup ? 26 : row.extraText ? 44 : 30
                color: row.isGroup ? "transparent" : row.logical === root.selected ? Qt.rgba(Theme.cyan.r, Theme.cyan.g, Theme.cyan.b, 0.16)
                                               : "transparent"

                Item {
                    visible: row.isGroup
                    anchors.fill: parent
                    Rectangle { x: 8 + (row.modelData.depth || 0) * 14; width: parent.width - x - 8; height: 1; anchors.bottom: parent.bottom; color: Theme.textDim; opacity: 0.35 }
                    Text {
                        x: 10 + (row.modelData.depth || 0) * 14
                        anchors.bottom: parent.bottom
                        anchors.bottomMargin: 3
                        text: (row.modelData.folded ? "▸ " : "▾ ") + (row.modelData.label || "") + "   " + (row.modelData.count || 0) + (row.modelData.folded ? " (folded)" : "")
                        font.family: Theme.fontFamily
                        font.pixelSize: Theme.fontSize - 2
                        font.bold: true
                        color: Theme.text
                        opacity: 0.85
                    }
                    MouseArea { anchors.fill: parent; onClicked: root.toggleGroup(row.modelData.id) }
                }

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
                    visible: !row.modelData.ws && !row.isGroup
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
                    source: (modelData.ws || modelData.action || modelData.grp) ? ""
                            : (LauncherIcons.pathFor(modelData.entry.icon)
                               || Quickshell.iconPath(modelData.entry.icon, "application-x-executable"))
                }
                // Generic glyph when no icon resolves at all.
                Text {
                    anchors.centerIn: appIcon
                    visible: !row.modelData.ws && !row.isGroup && appIcon.status !== Image.Ready
                    text: ""
                    font.family: Theme.iconFontFamily
                    font.pixelSize: 14
                    color: Theme.textDim
                }

                Column {
                    visible: !row.modelData.ws && !row.isGroup
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
                    enabled: !row.isGroup
                    hoverEnabled: true
                    id: rowHover
                    onPositionChanged: mouse => { if (root._pointerMoved(rowHover, mouse)) root.selected = row.logical; }
                    onClicked: root.launch(row.logical)
                }
            }
        }
    }
}

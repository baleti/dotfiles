import QtQuick
import Quickshell
import Quickshell.Wayland
import Quickshell.Io
import Quickshell.Hyprland
import "../theme"
import "../services"

// Alt-tab grid (ALT+Tab / ALT+SHIFT+Tab). One instance per monitor; only the
// one on WinSwitchState.monitor is ever shown.
//
// This is a view: keys, window order, selection, tap-vs-hold and confirming
// all live in services/WinSwitchState.qml (fed by ~/.config/hypr/winswitch.lua
// over Hyprland's event socket). What stays here is layout, the search/DSL
// mode (WinSwitchQueryDsl.qml) and its autocomplete, and mouse handling.
//
// Thumbnails come from the Rust backend (~/.config/hypr/winswitch), which
// WinSwitchState spawns once the grid is actually shown; cells render a
// placeholder frame sized to the window's aspect ratio until one arrives.
PanelWindow {
    id: root

    // `screen` is PanelWindow's own property, set from shell.qml's Variants
    // (do NOT redeclare it -- see AppLauncher.qml's identical note).
    // Set imperatively, not bound: `visible`/`keyboardFocus` follow it and
    // mapping the surface feeds back into `screen`, which a binding here
    // reads -- a binding loop (same reason as AppLauncher.qml's `open`).
    property bool open: false
    function _recompute() {
        root.open = WinSwitchState.active && WinSwitchState.shown && WinSwitchState.monitor === root.screen.name;
    }
    // Touching the history singleton here makes it load at startup, not at the first Ctrl+R / confirm.
    Component.onCompleted: { root._recompute(); WinSwitchQueryHistory.loaded; }
    readonly property var windows: WinSwitchState.windows
    readonly property int selected: WinSwitchState.selected
    readonly property bool locked: WinSwitchState.locked

    // Session that activated this view's focus grab, so a `cleared` arriving
    // late from a previous session can't close a newer one.
    property int _grabSession: -1

    // Locked (search mode) but with keyboard focus moved down into the grid:
    // Down in the search box (popup closed, not cycling history) puts focus
    // here, Tab goes back (query-dsl.md "Focus between search box and
    // results"). searchInput regaining focus by any route clears it.
    property bool listFocused: false
    function _focusList() {
        root.listFocused = true;
        searchInput.focus = false;
        card.forceActiveFocus();
        // the table has no "first Down only moves focus" step: land on the row below
        if (root.tableMode) root._resumeMove(1);
    }
    function _focusSearch() {
        root.listFocused = false;
        searchInput.forceActiveFocus();
        searchInput.cursorPosition = searchInput.text.length;
    }

    onOpenChanged: {
        // A held nav key's release is never delivered once the panel closes
        // (or a new session starts), which left the repeat timer stepping
        // the selection by itself in the next session.
        root._stopNavRepeat();
        if (root.open) {
            root.queryText = "";
            root._hideSuggestions();
            root._hoverOrigin = null;
            root._hoverArmed = false;
            root.listFocused = false;
            root._grabSession = WinSwitchState.sessionId;
            focusGrab.active = true;
            root._claimFocus();
        } else {
            focusGrab.active = false;
        }
    }

    // Grabs `card`'s active focus as early as physically possible, and keeps
    // retrying every event-loop turn until it actually sticks, rather than
    // the single deferred attempt this used to be ("requesting focus before
    // the surface has mapped doesn't stick," matching AppLauncher's own
    // note - true, but a *single* Qt.callLater tick is a race: under load
    // (reported 2026-09-13, heavier under memory pressure) that one tick can
    // still land before the surface has actually mapped, and since nothing
    // else ever retries it, `card` is left with no active focus - key events
    // reach the surface but no QML item accepts them, and the character
    // typed to start the search box is silently lost even though nothing
    // about the grid/thumbnails/enrichment (all independent of this) was
    // actually still loading). Tried immediately too, not just deferred, so
    // whichever ordering wins on a given run, focus lands in the same frame
    // where it's actually possible rather than always waiting a fixed tick.
    function _claimFocus() {
        if (!root.open)
            return;
        card.forceActiveFocus();
        if (!card.activeFocus)
            Qt.callLater(root._claimFocus);
    }

    function hide(reason) {
        WinSwitchState.close(reason || "hide");
    }
    function confirm(i) {
        if (root.tableMode) { root._resumeConfirm(); return; }
        // query-dsl.md's "Search-box history": a real accept records the
        // query, same as fzf's own --history flag does for the tmux
        // pickers.
        WinSwitchQueryHistory.record(root.queryText);
        WinSwitchState.confirm(i);
    }

    Connections {
        target: WinSwitchState
        function onActiveChanged() { root._recompute(); }
        function onShownChanged() { root._recompute(); }
        function onMonitorChanged() { root._recompute(); }
        // ALT+Tab while locked into search mode cycles autocomplete, same as
        // a plain Tab in the search box (Tab never reaches Qt while Alt is
        // held: the compositor bind eats it).
        function onLockedTab(direction) {
            if (root.open)
                root._completionTab(direction);
        }
    }

    // ---- hover selection --------------------------------------------------
    // The grid maps under a stationary pointer (follow_mouse puts it on the
    // pointer's monitor), and hover-enter on whatever cell appears under the
    // cursor used to silently steal the selection, so releasing Alt focused
    // that window instead of the tabbed one. Hover only selects once the
    // pointer has genuinely moved since the grid opened.
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

    // ---- filtering / sorting (query DSL) -----------------------------
    readonly property var parsedQuery: WinSwitchQueryDsl.parse(root.queryText)
    // /fts[/claude][/live|/archive] [term]: full text over the Claude conversations.
    // /fts/live filters the window grid; /fts/archive (past conversations) and plain
    // /fts with a term (live + archived) replace the grid by a table from
    // `claude-history --sessions`. Enter on a live row focuses its window, on an
    // archived one resumes it in a new tmux session in an alacritty window.
    readonly property var ftsSpec: root.parsedQuery.fts
    readonly property bool tableMode: !!root.ftsSpec && (root.ftsSpec.scope === "archive"
        || (root.ftsSpec.scope === "all" && root.ftsSpec.terms.length > 0))
    readonly property string tableQuery: !root.tableMode ? "" : root.ftsSpec.terms
        .concat(root.ftsSpec.negTerms.map(t => "!" + t))
        .map(t => /\s/.test(t.replace(/^!/, "")) ? t.replace(/^(!?)(.*)$/, '$1"$2"') : t).join(" ")
    readonly property string tableScope: root.tableMode ? (root.ftsSpec.scope === "archive" ? "archive" : "all") : ""
    property var tableRows: []
    readonly property int tableStatusW: root.tableScope === "archive" ? 0 : 52   // no status column in the archive-only view
    // live rows carry the window that shows them (matched by claude session id)
    readonly property var tableView: root.tableRows.map(r => {
        if (!r.live) return r;
        const w = root.windows.find(x => (root.metas[x.index] || {}).claude_session === r.session_id);
        return Object.assign({}, r, { winIndex: w ? w.index : -1 });
    })
    property int resumeSel: 0
    readonly property int resumeRowH: 24
    onTableQueryChanged: root._tableRefresh()
    onTableScopeChanged: root._tableRefresh()
    function _tableRefresh() {
        root.resumeSel = 0;
        if (!root.tableMode) { root.tableRows = []; return; }
        archiveProc.command = [Quickshell.env("HOME") + "/bin/claude-history", "--sessions", root.tableQuery, "--scope", root.tableScope];
        archiveProc.running = false;
        archiveProc.running = true;
    }
    function _resumeMove(delta) {
        const n = root.tableView.length;
        if (n === 0) return;
        root.resumeSel = Math.max(0, Math.min(n - 1, root.resumeSel + delta));
        resumeList.positionViewAtIndex(root.resumeSel, ListView.Contain);
    }
    function _resumeConfirm() {
        const row = root.tableView[root.resumeSel];
        if (!row) return;
        if (row.live) {
            if (row.winIndex >= 0) { WinSwitchQueryHistory.record(root.queryText); WinSwitchState.confirm(row.winIndex); }
            return;
        }
        WinSwitchQueryHistory.record(root.queryText);
        resumeProc.exec([Quickshell.env("HOME") + "/bin/claude-history", "--resume-window", row.session_id]);
        WinSwitchState.close("resume");
    }
    Process {
        id: archiveProc
        stdout: StdioCollector {
            onStreamFinished: {
                try { root.tableRows = JSON.parse(text); } catch (e) { root.tableRows = []; }
            }
        }
    }
    Process { id: resumeProc }
    // status column of the conversations table, same words/colours as the usage panel
    function _statusLabel(r) {
        if (!r.live) return qsTr("archive");
        return ({ busy: qsTr("busy"), waiting: qsTr("wait"), idle: qsTr("idle"), frozen: qsTr("frozen"), stopped: qsTr("stopped") })[r.status] || r.status || "?";
    }
    function _statusColor(r) {
        if (!r.live) return Theme.textDim;
        return ({ busy: Theme.red, waiting: Theme.orange, idle: Theme.muted, frozen: Theme.cyan, stopped: Theme.textDim })[r.status] || Theme.textDim;
    }
    // the bare account number: claude -> 1, claude6 -> 6 (as in the usage panel)
    function _acctNo(account) {
        const d = String(account || "").replace(/\D/g, "");
        return d.length > 0 ? d : "1";
    }
    function _ago(mtime) {
        const d = Math.max(0, Date.now() / 1000 - (mtime || 0));
        if (d < 3600) return Math.max(1, Math.round(d / 60)) + "m";
        if (d < 86400) return Math.round(d / 3600) + "h";
        return Math.round(d / 86400) + "d";
    }
    function _shortPath(p) {
        const h = Quickshell.env("HOME");
        return p && p.indexOf(h) === 0 ? "~" + p.slice(h.length) : (p || "");
    }

    // /fts/live: one `claude-history --fts` query per distinct term, queued
    // through ftsProc; results land in WinSwitchQueryDsl.ftsHits.
    property var _ftsQueue: []
    property string _ftsCurrent: ""
    onParsedQueryChanged: {
        const terms = WinSwitchQueryDsl.ftsTerms(root.parsedQuery.filters);
        if (terms.length === 0 && Object.keys(WinSwitchQueryDsl.ftsHits).length > 0)
            WinSwitchQueryDsl.ftsHits = ({}); // fresh index next time
        root._ftsQueue = terms.filter(v => WinSwitchQueryDsl.ftsHits[v] === undefined);
        root._ftsNext();
    }
    // Match preview strip (only while a full-text term is in the query):
    // excerpts of the highlighted window's Claude conversation.
    readonly property var _ftsActiveTerms: root.tableMode
        ? root.ftsSpec.terms
        : WinSwitchQueryDsl.ftsTerms(root.parsedQuery.filters)
    readonly property bool ftsActive: root._ftsActiveTerms.length > 0
    // Sized to the excerpts (at least 120), at most half the card's maximum height.
    readonly property int snippetH: Math.min(card.maxCardH * 0.5, Math.max(120, snippetText.implicitHeight + 14))
    property string snippetHtml: ""
    property string _snipKey: ""
    function _snipRefresh() {
        const meta = root.tableMode
            ? { claude_session: (root.tableView[root.resumeSel] || {}).session_id }
            : (root.metas[root.selected] || {});
        if (!root.ftsActive || !meta.claude_session) {
            root._snipKey = ""; root.snippetHtml = "";
            return;
        }
        const key = meta.claude_session + "|" + root._ftsActiveTerms.join(" ");
        if (key === root._snipKey) return;
        root._snipKey = key;
        snipProc.command = [Quickshell.env("HOME") + "/bin/claude-history", "--snippets", meta.claude_session, root._ftsActiveTerms.join(" ")];
        snipProc.running = false;
        snipProc.running = true;
    }
    on_FtsActiveTermsChanged: root._snipRefresh()
    onSelectedChanged: root._snipRefresh()
    onResumeSelChanged: root._snipRefresh()
    onTableViewChanged: root._snipRefresh()
    Process {
        id: snipProc
        stdout: StdioCollector {
            onStreamFinished: {
                const esc = t => t.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
                const hit = "<b><font color=\"" + Theme.cyan + "\">";
                root.snippetHtml = text.split("\n").filter(l => l.length > 0)
                    .map(l => esc(l).replace(/\x01/g, hit).replace(/\x02/g, "</font></b>"))
                    .join("<br><br>");
            }
        }
    }
    function _ftsNext() {
        if (ftsProc.running || root._ftsQueue.length === 0) return;
        root._ftsCurrent = root._ftsQueue[0];
        root._ftsQueue = root._ftsQueue.slice(1);
        ftsProc.command = [Quickshell.env("HOME") + "/bin/claude-history", "--fts", root._ftsCurrent];
        ftsProc.running = true;
    }
    Process {
        id: ftsProc
        stdout: StdioCollector {
            onStreamFinished: {
                const hits = {};
                for (const line of text.split("\n")) {
                    const m = line.split("\t");
                    if (m.length === 2) hits[m[0]] = parseFloat(m[1]);
                }
                const nh = Object.assign({}, WinSwitchQueryDsl.ftsHits);
                nh[root._ftsCurrent] = hits;
                WinSwitchQueryDsl.ftsHits = nh;
                root._ftsNext();
            }
        }
    }
    // /sw (/switch-workspace): swap the rows for workspaces (state fetches them).
    readonly property bool wantWorkspaces: root.parsedQuery.switchWorkspace
    onWantWorkspacesChanged: {
        if (root.open)
            WinSwitchState.setWorkspaceMode(root.wantWorkspaces);
    }
    // Parallel to `windows` (same index), built once per windows/enrichMeta
    // change, not per keystroke.
    readonly property var metas: root.windows.map(w => root.metaOf(w))
    // A workspace row has no meta of its own: it gets its windows' tmux/claude
    // fields joined, so "/sw/claude.title foo" keeps workspaces where ANY window
    // matches, and the cell shows every window's value.
    function metaOf(w) {
        if (!w.wins)
            return WinSwitchState.enrichMeta[w.address] || {};
        const out = {};
        for (const win of w.wins) {
            const m = WinSwitchState.enrichMeta[win.address];
            for (const k in m)
                if (m[k] !== "" && m[k] !== undefined)
                    out[k] = k in out ? out[k] + " | " + m[k] : String(m[k]);
        }
        return out;
    }
    readonly property var activeColumns: WinSwitchQueryDsl.activeColumns(root.queryText, root.wantWorkspaces ? WinSwitchQueryDsl.workspaceColumns : WinSwitchQueryDsl.defaultColumns, root.windows, root.metas)

    readonly property var results: {
        // Reference-stable fast path: with no query, hand back `windows`
        // itself so enrichment updates don't rebuild every grid delegate.
        if (root.queryText.length === 0)
            return root.windows;

        // Workspace view: bare words match the workspace name only ("/sw 3" -> 3, 13, 23, ...).
        let rows = root.wantWorkspaces
            ? root.windows.filter(w => root.parsedQuery.filters.every(t =>
                t.kind === "free" ? WinSwitchQueryDsl.substr(t.text, w.workspace) !== !!t.neg
                    : WinSwitchQueryDsl._termMatches(w, root.metas[w.index] || {}, t)))
            : root.windows.filter(w => WinSwitchQueryDsl.matchesStr(w, root.metas[w.index] || {}, root.queryText));
        const s = root.parsedQuery.sort;
        if (s) {
            rows = rows.slice().sort((a, b) => {
                for (const f of s.fields) {
                    const av = WinSwitchQueryDsl.sortFieldValue(a, root.metas[a.index] || {}, f);
                    const bv = WinSwitchQueryDsl.sortFieldValue(b, root.metas[b.index] || {}, f);
                    const c = WinSwitchQueryDsl.compareFieldValues(av, bv, s.dir);
                    if (c !== 0) return c;
                }
                return 0;
            });
        }
        return rows;
    }
    // Visual position of the selection in `results`, -1 if not visible.
    readonly property int visualSelected: root.results.findIndex(w => w.index === root.selected)
    onResultsChanged: {
        // A search that filters out the selection moves it to the first match.
        if (root.queryText.length > 0 && root.results.length > 0 && root.visualSelected < 0)
            WinSwitchState.selected = root.results[0].index;
    }

    function _advance(direction) {
        if (root.tableMode) { root._resumeMove(direction === "prev" ? -1 : 1); return; }
        const n = root.results.length;
        if (n === 0) return;
        const cur = root.visualSelected;
        let next;
        if (cur < 0)
            next = direction === "prev" ? n - 1 : 0;
        else
            next = direction === "prev" ? (cur - 1 + n) % n : (cur + 1) % n;
        WinSwitchState.selected = root.results[next].index;
        // query-dsl.md's "Search-box history": moving the grid selection
        // after typing counts as "acted on" too, not just a full accept -
        // record() itself no-ops on an empty query, so this is a
        // harmless no-op during plain (unlocked) Alt+Tab cycling.
        WinSwitchQueryHistory.record(root.queryText);
    }
    Connections {
        target: WinSwitchState
        function onNavKey(direction: string): void {
            if (!root.open)
                return;
            if (direction === "history") {
                // Ctrl+Alt+R: with Alt held the compositor sees the chord first
                // (the Revit panel bind), so it arrives as a nav event.
                if (WinSwitchState.locked && searchInput.activeFocus)
                    root._triggerHistorySearch();
                else
                    root._openHistoryCold();
            } else if (direction === "up")
                root._advanceRow(-root.cols);
            else if (direction === "down")
                root._advanceRow(root.cols);
            else
                root._advance(direction === "left" ? "prev" : "next");
        }
    }
    function _openHistoryCold() {
        WinSwitchState.locked = true;
        Qt.callLater(() => {
            searchInput.forceActiveFocus();
            // A second callLater, not one: acPopup's height/maxH
            // depend on searchHeader.height, which only settles
            // to its locked (32px) value once this first tick's
            // layout pass has actually run - triggering the
            // history search in the SAME tick as the focus grab
            // computed the popup against the still-unlocked (0px)
            // geometry, so it never visibly appeared until a
            // second Ctrl+R press (reported 2026-09-14: "only
            // focuses the search box, need to press Ctrl+R again
            // to see the popup").
            Qt.callLater(() => root._triggerHistorySearch());
        });
    }
    function _advanceRow(delta) {
        if (root.tableMode) { root._resumeMove(delta < 0 ? -1 : 1); return; }
        const n = root.results.length;
        if (n === 0) return;
        const k = Math.max(0, Math.min(n - 1, Math.max(0, root.visualSelected) + delta));
        WinSwitchState.selected = root.results[k].index;
        WinSwitchQueryHistory.record(root.queryText);
    }

    // Hold-to-repeat for grid/list/popup navigation (arrows, Ctrl+H/J/K/L,
    // PageUp/Down): the held key re-fires its own step on a timer rather
    // than relying on whichever item currently holds focus forwarding
    // Qt's own key-repeat, which isn't guaranteed -- same reasoning as the
    // CTRL+ALT+h/l Hyprland-side repeat fix and the ClipboardPicker/
    // NotificationPicker DSL pickers' identical mechanism.
    property var _navRepeatFn: null
    Timer { id: navRepeatDelay; interval: 600; onTriggered: navRepeatTimer.start() }
    Timer { id: navRepeatTimer; interval: 40; repeat: true; onTriggered: { if (root._navRepeatFn && root.open) root._navRepeatFn(); else root._stopNavRepeat(); } }
    function _startNavRepeat(fn) {
        root._navRepeatFn = fn;
        fn();
        navRepeatDelay.restart();
    }
    function _stopNavRepeat() {
        navRepeatDelay.stop();
        navRepeatTimer.stop();
        root._navRepeatFn = null;
    }

    // ---- grid layout (ported from the old GTK ui.rs's typical_aspect /
    // grid_dims / cell_size / frame_size) ------------------------------------
    readonly property int minFrame: 64
    readonly property int maxFrame: 320
    // Base allowance fits the title's own (possibly wrapped) 2 lines;
    // each further active column - `/at`-added, or auto-shown because it's
    // actively `/fv`-scoped (query-dsl.md's "Auto-shown filter fields") -
    // gets its own line below, so the grid's cells grow to fit rather than
    // clipping or overlapping the row beneath.
    readonly property int labelAllowance: 54 + Math.max(0, root.activeColumns.length - 2) * 14
    readonly property int cellHOverhead: 24
    readonly property int cellVOverhead: 24

    function _typicalAspect() {
        const ratios = root.windows.filter(w => w.width > 0 && w.height > 0)
            .map(w => Math.max(0.3, Math.min(3.0, w.height / w.width)))
            .sort((a, b) => a - b);
        return ratios.length === 0 ? 1.0 : ratios[Math.floor(ratios.length / 2)];
    }
    function _gridDims(n, aspect, availW, availH) {
        n = Math.max(n, 1);
        if (n === 1) return [1, 1];
        const idealCols = Math.sqrt(aspect * n * availW / availH);
        const cols = Math.max(2, Math.min(Math.round(idealCols), Math.min(n, 8)));
        const rows = Math.ceil(n / cols);
        return [cols, rows];
    }
    function _cellSize(winW, winH, cols, rows) {
        const cellW = Math.max(winW / cols - root.cellHOverhead, root.minFrame);
        const cellH = Math.max(winH / rows - root.cellVOverhead, root.minFrame + root.labelAllowance);
        const maxH = Math.max(root.minFrame, Math.min(root.maxFrame, cellH - root.labelAllowance));
        return [cellW, maxH];
    }
    // Fits one window's own aspect ratio into a `budgetW`x`budgetH` box.
    function frameSize(winW, winH, budgetW, budgetH) {
        if (winW <= 0 || winH <= 0) return [budgetW, budgetH];
        const aspect = winH / winW;
        const hAtFullWidth = Math.round(budgetW * aspect);
        if (hAtFullWidth <= budgetH)
            return [budgetW, Math.max(root.minFrame, hAtFullWidth)];
        const wAtMaxH = Math.round(budgetH / aspect);
        return [Math.max(root.minFrame, wAtMaxH), budgetH];
    }

    readonly property real _aspect: root._typicalAspect()
    readonly property int _availW: root.screen ? Math.round(root.screen.width * 0.7) : 1400
    readonly property int _availH: root.screen ? Math.round(root.screen.height * 0.78) : 800
    readonly property var _dims: root._gridDims(root.windows.length, root._aspect, root._availW, root._availH)
    readonly property int cols: root._dims[0]
    readonly property int rows: root._dims[1]
    readonly property int cellWBudget: Math.max(Math.floor(root._availW / root.cols), root.minFrame + root.cellHOverhead)
    readonly property int cellHBudget: Math.max(
        Math.min(Math.round(root.cellWBudget * root._aspect), Math.floor(root._availH / root.rows)),
        root.minFrame + root.labelAllowance + root.cellVOverhead)
    readonly property int gridWinW: Math.min(root.cellWBudget * root.cols, root._availW)
    readonly property int gridWinH: Math.min(root.cellHBudget * root.rows, root._availH)
    readonly property var _cellSizeResult: root._cellSize(root.gridWinW, root.gridWinH, root.cols, root.rows)
    readonly property int cellW: root._cellSizeResult[0]
    readonly property int maxH: root._cellSizeResult[1]
    readonly property int cellHeight: root.maxH + root.labelAllowance + root.cellVOverhead

    // ---- search box / DSL state --------------------------------------
    // Two modes: unlocked, Tab/Shift+Tab cycle and releasing Alt confirms;
    // typing any printable key locks into search mode (a filter/sort/column
    // DSL, see WinSwitchQueryDsl.qml), where Alt release no longer confirms
    // and Enter/Escape confirm/cancel. Locking doesn't require releasing Alt.
    property string queryText: ""

    readonly property var _commandSpans: root.queryText.length ? WinSwitchQueryDsl.commandSpans(root.queryText) : []

    // ---- autocomplete (marginalia-style, same as AppLauncher.qml) ---------
    property var acItems: []
    property int acSel: 0
    property var acSuggestionKind: null // {kind, start, verb?, via?, field?}
    // Whether a completion session is open, independent of whether it
    // currently has any candidates to show -- see onTextChanged below.
    property bool acActive: false
    // A history popup (Ctrl+R, query-dsl.md's "Search-box history") stays
    // visible even at zero current candidates - unlike every other kind,
    // where zero means "nothing to complete, don't show a popup at all" -
    // same as zsh's own ctrl-r widget always showing its popup.
    onAcItemsChanged: {
        acPopup.visible = root.acItems.length > 0
            || (root.acSuggestionKind !== null && root.acSuggestionKind.kind === "history");
        root.acSel = 0;
    }
    // Keeps the highlighted row in the ListView's visible window as
    // Up/Down/Tab move it past either end of the current scroll position.
    onAcSelChanged: if (acList) acList.positionViewAtIndex(acSel, ListView.Contain)

    // Ctrl+Space AND-narrowing (query-dsl.md's "Verb-stage depth"): once a
    // Verb-stage popup is open, Ctrl+Space inserts a literal space and keeps
    // it open instead of accepting, so a second (third, ...) substring can
    // be typed and ANDed against the first -- "/wo" + Tab + Ctrl+Space +
    // "fv" narrows the whole verb/path universe down to whichever
    // candidates contain *both* "wo" and "fv" ("/fv/workspace"), rather
    // than "wo" alone matching every verb crossed with `workspace`.
    // `acVerbMultiStart` freezes the position of the completion's opening
    // "/" at the moment multi-mode is entered - ordinary typing after that
    // updates `queryText` for real (no special-casing of the TextInput
    // itself), and `_acRecompute` below re-derives the fragments from
    // whatever now sits between that frozen start and the cursor.
    property bool acVerbMulti: false
    property int acVerbMultiStart: 0

    // The same AND-narrowing for every non-Verb popup (typePath, value,
    // bareValue, sortDirection): "//cla" + Tab + Ctrl+Space + "fts" narrows
    // the candidates that contain "cla" to those that also contain "fts"
    // (-> claude.fts). `acArgMulti` holds the completion object the popup
    // was on when multi-mode began (its `start` is frozen); recompute takes
    // the first fragment as the real completion fragment and ANDs the rest
    // against each candidate's text.
    property var acArgMulti: null

    function _hideSuggestions() {
        // Kind first: onAcItemsChanged keeps a "history" popup visible at zero
        // items, so clearing the items while the kind was still "history" left
        // the (empty) popup up and it took a second Escape to close.
        root.acSuggestionKind = null;
        root.acItems = [];
        root.acVerbMulti = false;
        root.acArgMulti = null;
        root.acActive = false;
    }

    function _acRowInfo(kind, item) {
        if (!kind) return { label: item, alias: "", desc: "" }; // transient: acSuggestionKind resets before acItems does
        if (kind.kind === "verb") {
            // `item` is bare; `verbInfo` is keyed with the leading "/". A
            // deep candidate (query-dsl.md's "Verb-stage depth") carries its
            // path glued on after a "/" -- show the verb's long form as the
            // alias and the path's own description, same roles each already
            // plays at the plain verb / typePath stages, just combined.
            const slash = item.indexOf("/");
            if (slash >= 0) {
                const verbPart = item.slice(0, slash), pathPart = item.slice(slash + 1);
                const info = WinSwitchQueryDsl.verbInfo["/" + verbPart] || { long: "", desc: "" };
                return { label: "/" + item, alias: info.long, desc: WinSwitchQueryDsl.typeDescs[pathPart] || info.desc };
            }
            const info = WinSwitchQueryDsl.verbInfo["/" + item] || { long: "", desc: "" };
            return { label: "/" + item, alias: info.long, desc: info.desc };
        }
        if (kind.kind === "typePath")
            return { label: item, alias: "", desc: WinSwitchQueryDsl.typeDescs[item] || "" };
        return { label: item, alias: "", desc: "" };
    }

    // Candidates for the current queryText without auto-accepting a unique
    // one (safe to call on every keystroke while narrowing an open popup).
    function _acRecompute() {
        // A history popup (Ctrl+R) recomputes against a completely
        // different corpus/matcher (see _acHistoryCandidates) - checked
        // first, and returned from directly, so the ordinary DSL
        // completion-context logic below never runs and overwrites
        // acSuggestionKind out from under an open history search the
        // moment the user types a character to narrow it (that was a
        // real bug: typing during Ctrl+R silently closed the popup
        // instead of narrowing it, reported 2026-09-14).
        if (root.acSuggestionKind !== null && root.acSuggestionKind.kind === "history")
            return root._acHistoryCandidates();
        if (root.acVerbMulti) {
            // Bail out of multi-mode if editing has erased back past the
            // frozen "/" (e.g. backspacing the whole command away) - falls
            // through to the ordinary single-fragment recompute below,
            // exactly as if multi-mode had never started.
            if (root.acVerbMultiStart < root.queryText.length && root.queryText[root.acVerbMultiStart] === "/") {
                const buf = root.queryText.slice(root.acVerbMultiStart + 1);
                const frags = buf.split(/\s+/).filter(f => f.length > 0);
                root.acSuggestionKind = { kind: "verb", start: root.acVerbMultiStart, fragment: frags.join(" ") };
                return WinSwitchQueryDsl.verbStageUniverse().filter(v => frags.every(f => WinSwitchQueryDsl.substr(f, v)));
            }
            root.acVerbMulti = false;
        }
        if (root.acArgMulti !== null) {
            const base = root.acArgMulti;
            if (base.start <= root.queryText.length) {
                const frags = root.queryText.slice(base.start).split(/\s+/).filter(f => f.length > 0);
                // a "value" completion's start is the "field:" token start; its fragment is what follows the colon
                if (base.kind === "value" && frags.length > 0) frags[0] = frags[0].slice(frags[0].indexOf(":") + 1);
                const comp = Object.assign({}, base, { fragment: frags.length > 0 ? frags[0] : "" });
                root.acSuggestionKind = Object.assign({}, comp, { fragment: frags.join(" ") });
                return WinSwitchQueryDsl.completionCandidates(comp, root.windows, root.metas)
                    .filter(c => frags.slice(1).every(f => WinSwitchQueryDsl.substr(f, c)));
            }
            root.acArgMulti = null;
        }
        const completion = WinSwitchQueryDsl.completionContext(root.queryText);
        root.acSuggestionKind = completion;
        if (completion === null) return [];
        return WinSwitchQueryDsl.completionCandidates(completion, root.windows, root.metas);
    }

    function _triggerCompletion() {
        const completion = WinSwitchQueryDsl.completionContext(root.queryText);
        if (completion === null) return false;
        // Marks the session open the moment Tab lands in a trackable
        // argument position, even if this exact keystroke has zero
        // candidates -- onTextChanged below keeps recomputing from here on,
        // so a later edit that makes the fragment valid again reopens the
        // popup on its own instead of requiring another Tab press.
        root.acActive = true;
        const items = WinSwitchQueryDsl.completionCandidates(completion, root.windows, root.metas);
        if (items.length === 0) return false;
        root.acSuggestionKind = completion;
        root.acItems = items;
        root.acSel = 0;
        if (items.length === 1)
            root._acAccept();
        return true;
    }

    // First Tab opens the popup; later Tabs move the highlight; Enter accepts.
    function _completionTab(direction) {
        if (acPopup.visible)
            root.acSel = (root.acSel + (direction === "prev" ? -1 : 1) + root.acItems.length) % root.acItems.length;
        else
            root._triggerCompletion();
    }

    function _acAccept() {
        const kind = root.acSuggestionKind;
        const chosen = root.acItems[root.acSel];
        if (!kind || chosen === undefined) return;
        const prefix = root.queryText.slice(0, kind.start);
        let newQuery;
        switch (kind.kind) {
        case "verb":
            newQuery = prefix + "/" + chosen + " ";
            break;
        case "typePath":
            // /fv and /fts take a value next; the other verbs end at their keys
            // (so a "," or "/dir" can follow)
            newQuery = prefix + chosen + (kind.verb === "/fv" || kind.verb === "/fts" ? " " : "");
            break;
        case "sortDirection":
            newQuery = prefix + chosen + " ";
            break;
        case "value": {
            const val = /\s/.test(chosen) ? `"${chosen}"` : chosen;
            newQuery = prefix + WinSwitchQueryDsl.fieldKey(kind.field) + ":" + val + " ";
            break;
        }
        case "bareValue": {
            const val = /\s/.test(chosen) ? `"${chosen}"` : chosen;
            newQuery = prefix + val + " ";
            break;
        }
        case "history":
            // Whole-line replace, no prefix (kind.start is 0 - see
            // _triggerHistorySearch) - matches zsh's own `LBUFFER=$selected`.
            newQuery = chosen;
            break;
        default:
            return;
        }
        root._hideSuggestions();
        root.queryText = newQuery;
        Qt.callLater(() => { searchInput.cursorPosition = searchInput.text.length; });
    }

    // ---- search-box history (query-dsl.md's "Search-box history") ---------
    // Ctrl+R reuses the completion popup's own rendering/highlight/accept
    // machinery (acItems/acSel/_acAccept all already just read `chosen` and
    // build `newQuery` generically per `kind.kind`) rather than a second
    // popup component - "history" is just one more case in that switch.

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
        const q = root.queryText.toLowerCase();
        const entries = WinSwitchQueryHistory.listMostRecentFirst();
        return q.length === 0 ? entries
            : entries.filter(e => root._fuzzySubsequence(e.toLowerCase(), q));
    }

    // Ctrl+R: opens unconditionally, even with zero history yet - same as
    // zsh's own ctrl-r widget, which shows its (empty) popup rather than
    // doing nothing the first time there's no history - so the binding is
    // never indistinguishable from unbound.
    function _triggerHistorySearch() {
        root.acSuggestionKind = { kind: "history", start: 0 };
        root.acActive = true;
        root.acSel = 0;
        root.acItems = root._acHistoryCandidates();
    }

    // Up/Down cycling: most-recent-first with draft-restore, scoped to
    // whenever the completion/history popup ISN'T open (query-dsl.md's
    // Up-arrow bullet) - Up/Down there stay popup-highlight movement, and
    // grid navigation moves to Ctrl+J/Ctrl+K (already an existing alias
    // for Down/Up here, same as AppLauncher.qml).
    property string acHistDraft: ""
    property int acHistIndex: -1  // -1 = sitting on the draft, not cycling
    property bool _histCycling: false  // guards searchInput's onTextChanged
    // (below) from treating OUR OWN text-set as a fresh edit that should
    // cancel cycling or reopen a stale completion session

    function _setQueryTextForHistory(text) {
        root._hideSuggestions();  // avoid recomputing completion candidates
        // against whatever history text just landed (same reasoning
        // _acAccept already follows)
        root._histCycling = true;
        root.queryText = text;
        root._histCycling = false;
        Qt.callLater(() => { searchInput.cursorPosition = searchInput.text.length; });
    }

    function _historyPrev() {
        const entries = WinSwitchQueryHistory.entries;  // oldest-first
        if (entries.length === 0) return;
        if (root.acHistIndex < 0) {
            root.acHistDraft = root.queryText;
            root.acHistIndex = entries.length;
        }
        if (root.acHistIndex > 0) {
            root.acHistIndex--;
            root._setQueryTextForHistory(entries[root.acHistIndex]);
        }
    }

    function _historyNext() {
        if (root.acHistIndex < 0) return;  // not cycling - nothing to do
        const entries = WinSwitchQueryHistory.entries;
        root.acHistIndex++;
        if (root.acHistIndex >= entries.length) {
            root.acHistIndex = -1;
            root._setQueryTextForHistory(root.acHistDraft);
        } else {
            root._setQueryTextForHistory(entries[root.acHistIndex]);
        }
    }

    // ---- window ---------------------------------------------------
    anchors { top: true; left: true }
    implicitWidth: root.screen ? root.screen.width : 1920
    implicitHeight: root.screen ? root.screen.height : 1080
    color: "transparent"
    visible: root.open
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: root.open ? WlrKeyboardFocus.OnDemand : WlrKeyboardFocus.None
    WlrLayershell.namespace: "quickshell-winswitch"
    exclusionMode: ExclusionMode.Ignore

    HyprlandFocusGrab {
        id: focusGrab
        windows: [root]
        onCleared: {
            if (root._grabSession !== WinSwitchState.sessionId)
                return;
            // Alt still held (unlocked cycling): the grab clearing is not the
            // user leaving. Under load the grab can be cleared by focus
            // churn around the grid's own mapping; closing here dropped the
            // session, so the next Tab restarted from the focused window and
            // landed on the second entry again. The Alt release ends it.
            if (WinSwitchState.altHeld && !WinSwitchState.locked) {
                console.log("winswitch: focus grab cleared while Alt held, ignoring");
                return;
            }
            root.hide("grab-cleared");
        }
    }

    MouseArea {
        id: backdropMouse
        anchors.fill: parent
        hoverEnabled: true
        onPositionChanged: mouse => root._pointerMoved(backdropMouse, mouse)
        onClicked: root.hide()
    }

    Rectangle {
        id: card
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.verticalCenter: parent.verticalCenter
        width: root.gridWinW + 32
        // Grows to fit the search box + autocomplete popup once locked,
        // capped so the GridView's own scrolling takes over beyond that.
        readonly property int maxCardH: root.screen ? Math.round(root.screen.height * 0.92) : 1000
        height: Math.min(card.maxCardH, (root.locked ? searchHeader.height : 0) + acPopup.height + gridScroll.contentHeightHint + (root.ftsActive && !root.tableMode ? root.snippetH + 4 : 0) + 32)
        radius: Theme.rounding
        color: Theme.bgAlpha
        border.color: Theme.cyan
        border.width: 1
        focus: true

        MouseArea { anchors.fill: parent } // swallow clicks so they don't reach the backdrop

        Column {
            id: contentColumn
            anchors.fill: parent
            anchors.margins: 16
            spacing: 4

            Item {
                id: searchHeader
                width: parent.width
                height: root.locked ? 32 : 0
                visible: root.locked
                clip: true

                Text {
                    id: prompt
                    anchors.verticalCenter: parent.verticalCenter
                    text: "" // magnifier, matches the launcher's own prompt glyph
                    font.family: Theme.iconFontFamily
                    font.pixelSize: Theme.fontSize
                    color: Theme.textDim
                }

                TextInput {
                    id: searchInput
                    onActiveFocusChanged: if (activeFocus) root.listFocused = false
                    anchors.verticalCenter: parent.verticalCenter
                    x: 22
                    width: parent.width - 22
                    text: root.queryText
                    font.family: Theme.fontFamily
                    font.pixelSize: Theme.fontSize
                    color: Theme.text
                    selectionColor: Theme.cyan
                    selectByMouse: true
                    clip: true
                    onTextChanged: {
                        if (root.queryText !== text)
                            root.queryText = text;
                        // A real edit cancels an in-progress Up/Down history
                        // cycle (query-dsl.md: editing invalidates the cycle
                        // the same way it does in a real shell) - but not
                        // when WE just set the text ourselves while cycling
                        // (_setQueryTextForHistory already calls
                        // _hideSuggestions() itself, so this only needs to
                        // skip the index reset, not the branch below).
                        if (!root._histCycling)
                            root.acHistIndex = -1;
                        // An open session narrows as you type instead of
                        // closing -- gated on `acActive`, not `acPopup.visible`:
                        // the popup itself hides the instant candidates drop
                        // to zero (e.g. a typo), but the session stays open,
                        // so fixing the typo recomputes and reopens it rather
                        // than requiring a fresh Tab (reported 2026-09-13:
                        // "/cla tt" -> zero candidates hid the popup, and
                        // correcting it never brought the list back because
                        // this used to re-test itself against the
                        // already-false `acPopup.visible`).
                        if (root.acActive)
                            root.acItems = root._acRecompute();
                        else
                            root._hideSuggestions();
                    }

                    // Syntax highlighting (query-dsl.md): recognised /commands in the accent colour.
                    DslHighlight { input: searchInput; spans: root.queryText.length ? root._commandSpans : [] }

                    // zsh-autosuggestions (query-dsl.md "Search-box history"): greyed-out
                    // rest of the newest history entry starting with the text; Right, End
                    // or Ctrl+F at the end of the text takes it.
                    readonly property string ghost:
                        (cursorPosition === text.length && !(acPopup.visible)) ? WinSwitchQueryHistory.suggest(text) : ""
                    Text {
                        visible: searchInput.ghost.length > 0
                        // cursorRectangle (cursor is at the end whenever the ghost
                        // shows) notifies on change; positionToRectangle() doesn't,
                        // so the ghost kept the previous keystroke's x and overlapped.
                        x: searchInput.cursorRectangle.x + searchInput.cursorRectangle.width
                        y: searchInput.cursorRectangle.y
                        text: searchInput.ghost
                        color: Theme.muted
                        font: searchInput.font
                    }
                    Keys.onPressed: event => {
                        if (searchInput.ghost.length > 0 && !((event.modifiers & Qt.ShiftModifier))
                                && ((event.key === Qt.Key_Right && !(event.modifiers & ~Qt.KeypadModifier))
                                    || event.key === Qt.Key_End
                                    || (event.key === Qt.Key_F && (event.modifiers & Qt.ControlModifier)))) {
                            searchInput.insert(searchInput.text.length, searchInput.ghost);
                            event.accepted = true;
                            return;
                        }
                        if (event.key === Qt.Key_Escape) {
                            if (acPopup.visible) root._hideSuggestions();
                            else root.hide();
                            event.accepted = true;
                        } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                            if (acPopup.visible) root._acAccept();
                            else root.confirm(root.selected);
                            event.accepted = true;
                        } else if (event.key === Qt.Key_Tab || event.key === Qt.Key_Backtab) {
                            // Tab confirms the highlighted suggestion
                            // (query-dsl.md); Shift+Tab steps back. Alt+Tab
                            // (onLockedTab) still cycles.
                            const back = event.key === Qt.Key_Backtab || (event.modifiers & Qt.ShiftModifier);
                            if (acPopup.visible && !back) root._acAccept();
                            else root._completionTab(back ? "prev" : "next");
                            event.accepted = true;
                        } else if (event.key === Qt.Key_Space && !acPopup.visible && (event.modifiers & Qt.ControlModifier)) {
                            // Ctrl+Space also opens completion, same as Tab
                            // (query-dsl.md Autocompletion section) -
                            // ClipboardPicker.qml/NotificationPicker.qml's
                            // reference implementation, ported here.
                            root._triggerCompletion();
                            event.accepted = true;
                        } else if (event.key === Qt.Key_Space && acPopup.visible && (event.modifiers & Qt.ControlModifier)) {
                            // AND-narrow instead of accept - see acVerbMulti
                            // above. No-op outside the Verb stage (a value/
                            // sort-direction popup has nothing to cross).
                            if (root.acSuggestionKind && root.acSuggestionKind.kind === "verb") {
                                if (!root.acVerbMulti) {
                                    root.acVerbMulti = true;
                                    root.acVerbMultiStart = root.acSuggestionKind.start;
                                }
                                searchInput.insert(searchInput.cursorPosition, " ");
                            } else if (root.acSuggestionKind && root.acSuggestionKind.kind !== "history") {
                                if (root.acArgMulti === null)
                                    root.acArgMulti = Object.assign({}, root.acSuggestionKind);
                                searchInput.insert(searchInput.cursorPosition, " ");
                            }
                            event.accepted = true;
                        } else if (event.key === Qt.Key_Space && acPopup.visible) {
                            root._acAccept();
                            event.accepted = true;
                        } else if (event.key === Qt.Key_R && (event.modifiers & Qt.ControlModifier)) {
                            // query-dsl.md's "Search-box history": always
                            // (re)opens, even with an empty history file yet.
                            root._triggerHistorySearch();
                            event.accepted = true;
                        } else if (event.key === Qt.Key_Down) {
                            // Popup open: highlight-move, unchanged. Popup
                            // closed: history-cycle instead of grid-advance -
                            // see acHistIndex's own comment.
                            if (acPopup.visible) {
                                if (!event.isAutoRepeat) root._startNavRepeat(() => { root.acSel = Math.min(root.acItems.length - 1, root.acSel + 1); });
                            } else if (root.acHistIndex >= 0) root._historyNext();
                            else root._focusList();
                            event.accepted = true;
                        } else if (event.key === Qt.Key_Up) {
                            if (acPopup.visible) {
                                if (!event.isAutoRepeat) root._startNavRepeat(() => { root.acSel = Math.max(0, root.acSel - 1); });
                            } else root._historyPrev();
                            event.accepted = true;
                        } else if (event.key === Qt.Key_J && (event.modifiers & Qt.ControlModifier)) {
                            if (acPopup.visible) {
                                if (!event.isAutoRepeat) root._startNavRepeat(() => { root.acSel = Math.min(root.acItems.length - 1, root.acSel + 1); });
                            } else if (root.acHistIndex >= 0) root._historyNext(); // Ctrl+J == Down (query-dsl.md "Search-box history")
                            else root._focusList();
                            event.accepted = true;
                        } else if (event.key === Qt.Key_K && (event.modifiers & Qt.ControlModifier)) {
                            if (acPopup.visible) {
                                if (!event.isAutoRepeat) root._startNavRepeat(() => { root.acSel = Math.max(0, root.acSel - 1); });
                            } else root._historyPrev(); // Ctrl+K == Up
                            event.accepted = true;
                        } else if (!acPopup.visible && event.key === Qt.Key_L && (event.modifiers & Qt.ControlModifier)) {
                            // Ctrl+H/L mirror the grid's own Left/Right (unlocked
                            // Keys.onPressed, below) the same way Ctrl+J/K above
                            // already mirror Up/Down - no popup meaning (a
                            // vertical list has no left/right), so only act while
                            // the popup isn't showing.
                            if (!event.isAutoRepeat) root._startNavRepeat(() => root._advance("next"));
                            event.accepted = true;
                        } else if (!acPopup.visible && event.key === Qt.Key_H && (event.modifiers & Qt.ControlModifier)) {
                            if (!event.isAutoRepeat) root._startNavRepeat(() => root._advance("prev"));
                            event.accepted = true;
                        } else if (event.key === Qt.Key_PageDown && acPopup.visible) {
                            if (!event.isAutoRepeat) root._startNavRepeat(() => { root.acSel = Math.min(root.acItems.length - 1, root.acSel + Math.max(1, Math.floor(acList.height / 24))); });
                            event.accepted = true;
                        } else if (event.key === Qt.Key_PageUp && acPopup.visible) {
                            if (!event.isAutoRepeat) root._startNavRepeat(() => { root.acSel = Math.max(0, root.acSel - Math.max(1, Math.floor(acList.height / 24))); });
                            event.accepted = true;
                        }
                    }
                    // Native key-repeat here delivers a flood of RELEASE
                    // events flagged isAutoRepeat=true (confirmed live
                    // 2026-10-04, see AppLauncher.qml's identical comment)
                    // -- only a genuine key-up should actually stop it.
                    Keys.onReleased: event => { if (!event.isAutoRepeat) root._stopNavRepeat(); }
                }
            }

            // Autocomplete popup, in-layout under the search box: label, then
            // the long-form alias and a one-line description, both dim.
            // ListView instead of a plain Column+Repeater so entries past
            // the visible window are reachable -- wheel-scrollable, and
            // Up/Down (root.onAcSelChanged below) keeps the selection in
            // view via positionViewAtIndex. Grows with the candidate count
            // (Verb-stage depth, query-dsl.md, routinely produces far more
            // than a 7- or 12-row cap ever fit) up to the card's own height
            // budget -- gridScroll (below) just yields the space, since the
            // grid isn't usable while the popup has focus anyway; the
            // hand-rolled scrollbar mirrors bar/ClaudeUsageExpanded.qml's
            // identical pattern for whatever still doesn't fit even at that
            // height.
            Item {
                id: acPopup
                visible: false
                width: parent.width
                readonly property bool isHistory: root.acSuggestionKind !== null && root.acSuggestionKind.kind === "history"
                // Ctrl+R history is capped at half the card's max height; completion keeps the full height.
                readonly property int maxH: root.screen ? (isHistory ? Math.round(card.maxCardH / 2) : (card.maxCardH - searchHeader.height - 32)) : 900
                height: visible ? Math.min(root.acItems.length * 24 + 8, acPopup.maxH) : 0
                clip: true

                ListView {
                    id: acList
                    anchors.fill: parent
                    anchors.margins: 4
                    anchors.rightMargin: 10
                    clip: true
                    model: root.acItems
                    currentIndex: root.acSel
                    boundsBehavior: Flickable.StopAtBounds
                    delegate: Rectangle {
                        id: acRow
                        required property var modelData
                        required property int index
                        readonly property bool cur: index === root.acSel
                        readonly property var info: root._acRowInfo(root.acSuggestionKind, modelData)
                        width: acList.width
                        height: 24
                        radius: Theme.rounding - 5
                        color: cur ? Qt.rgba(Theme.cyan.r, Theme.cyan.g, Theme.cyan.b, 0.18) : "transparent"

                        Row {
                            anchors.verticalCenter: parent.verticalCenter
                            x: 10
                            spacing: 8

                            Text {
                                id: acLabel
                                text: acRow.info.label
                                font.family: Theme.fontFamily
                                font.pixelSize: Theme.fontSize - 1
                                color: acRow.cur ? Theme.cyan : Theme.text
                            }
                            Text {
                                visible: !!acRow.info.alias
                                anchors.baseline: acLabel.baseline
                                text: "(" + acRow.info.alias + ")"
                                font.family: Theme.fontFamily
                                font.pixelSize: Theme.fontSize - 2
                                color: Theme.muted
                                opacity: 0.55
                            }
                            Text {
                                visible: !!acRow.info.desc
                                anchors.baseline: acLabel.baseline
                                text: acRow.info.desc
                                font.family: Theme.fontFamily
                                font.pixelSize: Theme.fontSize - 2
                                color: Theme.textDim
                                opacity: 0.55
                            }
                        }

                        MouseArea {
                            anchors.fill: parent
                            onClicked: { root.acSel = acRow.index; root._acAccept(); }
                        }
                    }
                }

                // Hand-rolled vertical scrollbar (no QtQuick.Controls anywhere
                // in this project) - visible only once acItems overflows the
                // visible window, thumb size/position proportional to how
                // much of the list is in view.
                Rectangle {
                    id: acScrollBar
                    visible: acList.contentHeight > acList.height + 1
                    anchors.top: acList.top
                    anchors.right: parent.right
                    anchors.rightMargin: 3
                    width: 4
                    height: acList.height
                    radius: 2
                    color: Qt.rgba(1, 1, 1, 0.06)

                    readonly property real thumbH: Math.max(10, acList.visibleArea.heightRatio * height)
                    readonly property real travel: Math.max(1, height - thumbH)
                    readonly property real maxContentY: Math.max(0, acList.contentHeight - acList.height)

                    function scrollToThumbTop(ty: real): void {
                        const clamped = Math.max(0, Math.min(acScrollBar.travel, ty));
                        acList.contentY = (clamped / acScrollBar.travel) * acScrollBar.maxContentY;
                    }

                    Rectangle {
                        width: parent.width
                        radius: 2
                        height: acScrollBar.thumbH
                        y: Math.min(acScrollBar.travel, acList.visibleArea.yPosition * acScrollBar.height)
                        color: acSbArea.pressed ? Theme.text
                            : (acSbArea.containsMouse ? Theme.textDim : Qt.rgba(1, 1, 1, 0.28))
                    }

                    MouseArea {
                        id: acSbArea
                        anchors.fill: parent
                        anchors.leftMargin: -8
                        anchors.topMargin: -2
                        anchors.bottomMargin: -2
                        hoverEnabled: true
                        preventStealing: true
                        property real grabOffset: 0

                        onPressed: mouse => {
                            const ty = mouse.y + anchors.topMargin;
                            const thumbY = Math.min(acScrollBar.travel, acList.visibleArea.yPosition * acScrollBar.height);
                            if (ty >= thumbY && ty <= thumbY + acScrollBar.thumbH) {
                                grabOffset = ty - thumbY;
                            } else {
                                grabOffset = acScrollBar.thumbH / 2;
                                acScrollBar.scrollToThumbTop(ty - grabOffset);
                            }
                        }
                        onPositionChanged: mouse => {
                            if (pressed)
                                acScrollBar.scrollToThumbTop(mouse.y + anchors.topMargin - grabOffset);
                        }
                    }
                }
            }

            Item {
                id: gridScroll
                width: parent.width
                height: parent.height - searchHeader.height - acPopup.height - (root.ftsActive ? root.snippetH + 4 : 0) - contentColumn.spacing * 2
                readonly property int contentHeightHint: root.rows * root.cellHeight   // the resume table keeps the grid's height

                // Conversations table (/fts/archive, plain /fts with a term)
                Column {
                    anchors.fill: parent
                    visible: root.tableMode
                    spacing: 0
                    Row {
                        height: root.resumeRowH
                        spacing: 8
                        Repeater {
                            model: root.tableScope === "archive" ? [["acct", 32], ["title", -1], ["msgs", 48], ["tkns", 56], ["age", 64], ["path", 220]] : [["status", 52], ["acct", 32], ["title", -1], ["msgs", 48], ["tkns", 56], ["age", 64], ["path", 220]]
                            Text {
                                required property var modelData
                                width: modelData[1] < 0 ? Math.max(100, gridScroll.width - root.tableStatusW - 32 - 56 - 48 - 64 - 220 - 8 * (root.tableScope === "archive" ? 6 : 7)) : modelData[1]
                                text: modelData[0]
                                color: Theme.muted
                                font.family: Theme.fontFamily
                                font.pixelSize: Theme.fontSize - 3
                                horizontalAlignment: (modelData[0] === "tkns" || modelData[0] === "msgs" || modelData[0] === "age") ? Text.AlignRight : Text.AlignLeft
                            }
                        }
                    }
                    ListView {
                        id: resumeList
                        width: parent.width
                        height: parent.height - root.resumeRowH
                        clip: true
                        boundsBehavior: Flickable.StopAtBounds
                        model: root.tableView
                        delegate: Rectangle {
                            id: resumeRow
                            required property var modelData
                            required property int index
                            width: resumeList.width
                            height: root.resumeRowH
                            color: index === root.resumeSel ? Qt.rgba(Theme.cyan.r, Theme.cyan.g, Theme.cyan.b, 0.25) : "transparent"
                            radius: 3
                            Row {
                                anchors.fill: parent
                                spacing: 8
                                Text { width: 52; visible: root.tableScope !== "archive"; text: root._statusLabel(resumeRow.modelData); color: root._statusColor(resumeRow.modelData)
                                       font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize - 3; anchors.verticalCenter: parent.verticalCenter }
                                Text { width: 32; text: root._acctNo(resumeRow.modelData.account); color: Theme.muted; elide: Text.ElideRight
                                       font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize - 3; anchors.verticalCenter: parent.verticalCenter }
                                Text { width: Math.max(100, gridScroll.width - root.tableStatusW - 32 - 56 - 48 - 64 - 220 - 8 * (root.tableScope === "archive" ? 6 : 7)); text: resumeRow.modelData.title; color: Theme.text; elide: Text.ElideRight
                                       font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize - 2; anchors.verticalCenter: parent.verticalCenter }
                                Text { width: 48; text: String(resumeRow.modelData.msgs); color: Theme.muted; horizontalAlignment: Text.AlignRight
                                       font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize - 3; anchors.verticalCenter: parent.verticalCenter }
                                Text { width: 56; text: resumeRow.modelData.tokens ? Math.round(resumeRow.modelData.tokens / 1000) + "k" : ""; color: Theme.muted; horizontalAlignment: Text.AlignRight
                                       font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize - 3; anchors.verticalCenter: parent.verticalCenter }
                                Text { width: 64; text: root._ago(resumeRow.modelData.mtime); color: Theme.muted; horizontalAlignment: Text.AlignRight
                                       font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize - 3; anchors.verticalCenter: parent.verticalCenter }
                                Text { width: 220; text: root._shortPath(resumeRow.modelData.cwd); color: Theme.muted; elide: Text.ElideRight
                                       font.family: Theme.fontFamily; font.pixelSize: Theme.fontSize - 3; anchors.verticalCenter: parent.verticalCenter }
                            }
                            MouseArea {
                                anchors.fill: parent
                                onClicked: { root.resumeSel = resumeRow.index; root._resumeConfirm(); }
                            }
                        }
                    }
                }

                GridView {
                    id: grid
                    visible: !root.tableMode
                    anchors.fill: parent
                    cellWidth: root.cellW + root.cellHOverhead
                    cellHeight: root.cellHeight
                    clip: true
                    boundsBehavior: Flickable.StopAtBounds
                    currentIndex: root.visualSelected
                    model: root.results

                    delegate: Item {
                        id: cellItem
                        required property var modelData
                        required property int index
                        width: grid.cellWidth
                        height: grid.cellHeight

                        readonly property var thumb: WinSwitchState.thumbnails[modelData.address]
                        readonly property string thumbPath: cellItem.thumb ? cellItem.thumb.path : ""
                        // What's on screen: only swapped once the incoming
                        // capture has decoded, so a refresh never blanks.
                        property string shownPath: ""
                        readonly property bool isSelected: modelData.index === root.selected
                        readonly property var frameDims: root.frameSize(modelData.width, modelData.height, root.cellW, root.maxH)
                        readonly property var meta: root.metaOf(modelData)
                        // One line per active column (title, the default,
                        // plus whichever fields are `/at`-added or currently
                        // scoped-filtered - see WinSwitchQueryDsl.qml's
                        // `activeColumns`/`filterReferencedFields` and
                        // query-dsl.md's "Auto-shown filter fields") rather
                        // than one space-joined line, so a field you're
                        // actively filtering on (`/fv/claude.title foo`)
                        // reads as its own row under the title, not run
                        // together with it - the whole point being to see
                        // what matched when more than one candidate remains.
                        // One record per active column: { prefix, text,
                        // matchStart, matchLen }. Kept structured (not
                        // pre-joined into plain strings) so the details Text
                        // below can render `text` as rich text and color just
                        // the `[matchStart, matchStart+matchLen)` run - see
                        // WinSwitchQueryDsl's excerpt for where matchStart/Len
                        // come from.
                        readonly property var labelParts: {
                            const parts = [];
                            // Bare-group filters (`/fv/claude foo`) now match
                            // across every subfield (WinSwitchQueryDsl's
                            // resolveFilterFields), so which subfield
                            // actually matched varies row to row - gate each
                            // group-subfield line to rows where it's the one
                            // that matched, rather than showing all of a
                            // group's subfields regardless of relevance
                            // (query-dsl.md "Auto-shown filter fields").
                            const groupGate = WinSwitchQueryDsl.scopedGroupFilters(root.queryText);
                            for (const f of root.activeColumns) {
                                let v = WinSwitchQueryDsl.sortFieldValue(cellItem.modelData, cellItem.meta, f);
                                if (f.kind === "flat" && f.name === "title" && v === "") v = cellItem.modelData.class || "";
                                if (v === "") continue;
                                // For a field reached via a bare-group filter,
                                // skip it unless it's the subfield that
                                // actually matched this row, and center the
                                // preview on the match instead of always
                                // truncating from the start (see
                                // WinSwitchQueryDsl's excerpt/scopedGroupFilters).
                                let needle = null;
                                if (f.kind === "group") {
                                    const gated = groupGate.filter(g => g.group === f.group);
                                    if (gated.length > 0) {
                                        const hit = gated.find(g => WinSwitchQueryDsl.substr(g.value, v));
                                        if (!hit) continue;
                                        needle = hit.value;
                                    }
                                }
                                const ex = WinSwitchQueryDsl.excerpt(v, needle, 80);
                                const prefix = f.kind === "group" ? (f.sub + ": ") : (f.name === "workspace" ? "#" : (f.name === "monitor" || f.name === "windows" ? f.name + ": " : ""));
                                parts.push({ prefix, text: ex.text, matchStart: ex.matchStart, matchLen: ex.matchLen });
                            }
                            return parts;
                        }
                        readonly property string titleText: cellItem.labelParts.length > 0
                            ? cellItem.labelParts[0].prefix + cellItem.labelParts[0].text : ""
                        // Rich-text (Text.StyledText) body for every line past
                        // the title: `sub: value` with the matched substring
                        // (if any) wrapped in a colored span, same accent
                        // color the rest of the UI uses for "this is the
                        // thing that matched" (command-validity coloring,
                        // selection highlight). Escaped since transcript/
                        // title text can contain literal `&`/`<`/`>`.
                        readonly property string detailsHtml: {
                            const esc = WinSwitchQueryDsl.escapeHtml;
                            const lines = [];
                            for (let i = 1; i < cellItem.labelParts.length; i++) {
                                const p = cellItem.labelParts[i];
                                if (p.matchStart < 0) {
                                    lines.push(esc(p.prefix) + esc(p.text));
                                    continue;
                                }
                                const before = p.text.slice(0, p.matchStart);
                                const hit = p.text.slice(p.matchStart, p.matchStart + p.matchLen);
                                const after = p.text.slice(p.matchStart + p.matchLen);
                                lines.push(esc(p.prefix) + esc(before) +
                                    "<font color=\"" + Theme.cyan.toString() + "\">" + esc(hit) + "</font>" + esc(after));
                            }
                            return lines.join("<br>");
                        }

                        Rectangle {
                            anchors.fill: parent
                            anchors.margins: 4
                            radius: Theme.rounding - 4
                            color: cellItem.isSelected ? Qt.rgba(Theme.cyan.r, Theme.cyan.g, Theme.cyan.b, 0.16) : "transparent"
                            border.color: cellItem.isSelected ? Theme.cyan : "transparent"
                            border.width: 1

                            Rectangle { // thumbnail frame placeholder
                                id: frame
                                anchors.top: parent.top
                                anchors.horizontalCenter: parent.horizontalCenter
                                anchors.topMargin: 6
                                width: cellItem.frameDims[0]
                                height: cellItem.frameDims[1]
                                radius: 4
                                color: Qt.rgba(1, 1, 1, 0.02)
                                border.color: Qt.rgba(1, 1, 1, 0.18)
                                border.width: 1

                                Image {
                                    anchors.fill: parent
                                    fillMode: Image.PreserveAspectFit
                                    visible: cellItem.shownPath !== "" && !cellItem.modelData.wins
                                    source: cellItem.shownPath
                                }
                                // /sw view: the whole workspace, each window's
                                // capture at its real spot on the monitor (like
                                // the bar's workspace-pill hover preview). Rows
                                // are back-to-front, so the focused window is on top.
                                Item {
                                    anchors.fill: parent
                                    clip: true
                                    visible: !!cellItem.modelData.wins
                                    Repeater {
                                        model: cellItem.modelData.wins || []
                                        delegate: Image {
                                            required property var modelData
                                            readonly property var t: WinSwitchState.thumbnails[modelData.address]
                                            x: modelData.x / cellItem.modelData.width * frame.width
                                            y: modelData.y / cellItem.modelData.height * frame.height
                                            width: modelData.w / cellItem.modelData.width * frame.width
                                            height: modelData.h / cellItem.modelData.height * frame.height
                                            fillMode: Image.Stretch
                                            asynchronous: true
                                            source: t ? t.path : ""
                                        }
                                    }
                                }
                                Image {
                                    visible: false
                                    asynchronous: true
                                    source: cellItem.thumbPath
                                    onStatusChanged: {
                                        if (status === Image.Ready)
                                            cellItem.shownPath = source.toString();
                                    }
                                }
                            }

                            // Window title stays centered on its own first
                            // line; every extra `sub: value` line below it is
                            // left-set instead of centered, and (below) has
                            // its matched substring colored - two separate
                            // Text items rather than one, since QML's
                            // horizontalAlignment/textFormat apply to a whole
                            // Text item, not per line.
                            Column {
                                anchors.top: frame.top
                                anchors.topMargin: root.maxH + 4
                                anchors.horizontalCenter: parent.horizontalCenter
                                width: parent.width - 12

                                Text {
                                    width: parent.width
                                    textFormat: Text.PlainText
                                    horizontalAlignment: Text.AlignHCenter
                                    elide: Text.ElideRight
                                    maximumLineCount: 2
                                    wrapMode: Text.Wrap
                                    text: cellItem.titleText
                                    font.family: Theme.fontFamily
                                    font.pixelSize: Theme.fontSize - 2
                                    color: Theme.text
                                }
                                Text {
                                    width: parent.width
                                    // Plain left-align, not Text.AlignJustify:
                                    // each `sub: value` entry is its own short
                                    // "paragraph" (joined by "\n"), and most
                                    // wrap into just one or two lines with a
                                    // short remainder - real justify stretches
                                    // that remainder to fill the *entire* cell
                                    // width, which reads as huge, uneven gaps
                                    // between two or three words rather than
                                    // clean text (reported 2026-09-13,
                                    // screenshot showed exactly this on
                                    // wrapped `contents:` lines). Left-align
                                    // keeps natural word spacing and still
                                    // satisfies "values flush to the left."
                                    horizontalAlignment: Text.AlignLeft
                                    elide: Text.ElideRight
                                    maximumLineCount: Math.max(1, root.activeColumns.length - 1)
                                    wrapMode: Text.Wrap
                                    // Rich text: detailsHtml wraps the matched
                                    // substring (if this line came from a
                                    // matched filter) in a colored <font>
                                    // span - see labelParts/detailsHtml above.
                                    textFormat: Text.StyledText
                                    text: cellItem.detailsHtml
                                    font.family: Theme.fontFamily
                                    font.pixelSize: Theme.fontSize - 2
                                    color: Theme.text
                                }
                            }
                        }

                        MouseArea {
                            id: cellMouse
                            anchors.fill: parent
                            hoverEnabled: true
                            onPositionChanged: mouse => {
                                if (root._pointerMoved(cellMouse, mouse))
                                    WinSwitchState.selected = cellItem.modelData.index;
                            }
                            onClicked: root.confirm(cellItem.modelData.index)
                        }
                    }
                }
            }

            // /fts match preview for the highlighted window.
            Rectangle {
                width: parent.width
                height: root.ftsActive ? root.snippetH : 0
                visible: root.ftsActive
                color: "transparent"
                border.color: Theme.border
                border.width: 1
                radius: 4
                clip: true
                Text {
                    id: snippetText
                    anchors.fill: parent
                    anchors.margins: 6
                    textFormat: Text.RichText
                    wrapMode: Text.Wrap
                    elide: Text.ElideRight
                    color: Theme.muted
                    font.family: Theme.fontFamily
                    font.pixelSize: Theme.fontSize - 2
                    text: root.snippetHtml.length > 0 ? root.snippetHtml : qsTr("no excerpts")
                }
            }
        }

        // Only reached while unlocked (searchInput has focus once locked).
        // Alt+Tab never arrives here -- the compositor bind eats it -- so
        // this is Escape/Enter/arrows, plus typing to enter search mode.
        Keys.onPressed: event => {
            if (root.locked && !root.listFocused)
                return;
            if (event.key === Qt.Key_Escape) {
                root.hide();
                event.accepted = true;
            } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                root.confirm(root.selected);
                event.accepted = true;
            } else if (root.listFocused && (event.key === Qt.Key_Tab || event.key === Qt.Key_Backtab)) {
                root._focusSearch();
                event.accepted = true;
            } else if (event.key === Qt.Key_Tab || event.key === Qt.Key_Backtab) {
                root._advance(event.key === Qt.Key_Backtab || (event.modifiers & Qt.ShiftModifier) ? "prev" : "next");
                event.accepted = true;
            } else if (event.key === Qt.Key_Right || (event.key === Qt.Key_L && (event.modifiers & Qt.ControlModifier))) {
                if (!event.isAutoRepeat) root._startNavRepeat(() => root._advance("next"));
                event.accepted = true;
            } else if (event.key === Qt.Key_Left || (event.key === Qt.Key_H && (event.modifiers & Qt.ControlModifier))) {
                if (!event.isAutoRepeat) root._startNavRepeat(() => root._advance("prev"));
                event.accepted = true;
            } else if (event.key === Qt.Key_Down || (event.key === Qt.Key_J && (event.modifiers & Qt.ControlModifier))) {
                if (!event.isAutoRepeat) root._startNavRepeat(() => root._advanceRow(root.cols));
                event.accepted = true;
            } else if (event.key === Qt.Key_Up || (event.key === Qt.Key_K && (event.modifiers & Qt.ControlModifier))) {
                if (!event.isAutoRepeat) root._startNavRepeat(() => root._advanceRow(-root.cols));
                event.accepted = true;
            } else if (event.key === Qt.Key_R && (event.modifiers & Qt.ControlModifier)) {
                // query-dsl.md's "Search-box history": Ctrl+R works
                // immediately after Alt+Tab too, before any character has
                // been typed - locks into search (empty query, unlike the
                // printable-key branch below which seeds it) and opens
                // the history popup right away, same "works from a blank
                // prompt" expectation zsh's own ctrl-r widget gives.
                root._openHistoryCold();
                event.accepted = true;
            } else if (event.text && event.text.length > 0 && event.text.charCodeAt(0) >= 0x20) {
                // Any printable key (Alt may still be held) locks into search;
                // from list focus it appends to the existing query instead.
                WinSwitchState.locked = true;
                root.queryText = root.listFocused ? root.queryText + event.text : event.text;
                Qt.callLater(() => {
                    searchInput.forceActiveFocus();
                    searchInput.cursorPosition = searchInput.text.length;
                });
                event.accepted = true;
            }
        }
        // Native key-repeat here delivers a flood of RELEASE events flagged
        // isAutoRepeat=true (confirmed live 2026-10-04, see AppLauncher.qml's
        // identical comment) -- only a genuine key-up should actually stop it.
        Keys.onReleased: event => { if (!event.isAutoRepeat) root._stopNavRepeat(); }
    }
}

import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Hyprland
import "../theme"
import "../services"

// Alt-tab grid (ALT+Tab / ALT+SHIFT+Tab) -- replaces the old standalone GTK
// winswitch binary (~/.config/hypr/winswitch). That binary is now a headless
// backend only: it still does the real work (window enumeration, live
// thumbnail capture via wayland-toplevel-export/dmabuf, tmux/Claude
// correlation -- see its own src/wayland_capture.rs and enrich.rs, both
// unchanged by this rewrite) and streams NDJSON to stdout instead of
// drawing a GTK grid itself. This file is the presentation layer only.
//
// PHASE 2 (2026-09-09): search/filter DSL (WinSwitchQueryDsl.qml, a port of
// query.rs the same way QueryDsl.qml ports the launcher's grammar) plus the
// aspect-ratio-tuned grid layout ui.rs originally used (`typicalAspect`/
// `gridDims`/`cellSize`/`frameSize` below), replacing phase 1's simpler
// fixed-cell GridView and fixing the overflow that caused (reported
// 2026-09-09).
//
// One instance per monitor; only the one WinSwitchState latched is ever
// shown (see WinSwitchState.qml's own doc for why `cycle` is reentrant).
PanelWindow {
    id: root

    // `screen` is PanelWindow's own property, set from shell.qml's Variants
    // (do NOT redeclare it -- see AppLauncher.qml's identical note).
    //
    // `open` only ever flips true once the backend's `windows` line
    // actually arrives -- the surface is never mapped at all for what
    // turns out to be a tap. An earlier version of this grabbed keyboard
    // input *immediately* on every press, before knowing tap vs. hold, to
    // avoid missing a quick Alt release; that traded one problem for three
    // worse ones (a visible flicker on every press regardless of
    // opacity/size tricks, a noisy single-instant `is_alt_down()` read, and
    // occasionally a grab that hadn't finished establishing by the time
    // Alt was released, leaving the grid stuck open needing Enter/Escape --
    // all reported 2026-09-09). The real fix was moving the debounce into
    // the backend instead (`main.rs`'s `TAP_HOLD_DEBOUNCE`): by the time a
    // `windows` line can possibly arrive, the backend has already spent
    // that debounce plus enumeration confirming Alt was still down, which
    // gives the compositor's focus grab handshake ample headroom to finish
    // before a human can react and release -- so this is back to the
    // simple "never do anything until we're sure" shape.
    property bool open: false
    // The direction that *started* the current determination, captured at
    // spawn time -- read back once `windows` arrives to seed `selected` at
    // index 1 (or the last index for "prev"), not 0. index 0 is always the
    // *currently* focused window (see hyprctl.rs::list_windows's own doc);
    // classic alt-tab releases onto the *previously* active one on a single
    // tap, so leaving `selected` at its default 0 made a release-to-confirm
    // silently re-focus the already-focused window -- looked exactly like
    // "nothing happened" (reported 2026-09-09).
    property string _initialDirection: "next"

    property var windows: [] // raw backend order -- index into this is each window's stable identity
    property var thumbnails: ({}) // index -> {path, width, height}
    property var enrichMeta: ({}) // index -> merged tmux/claude fields
    // `selected` is a *window index* (stable identity into `windows`), not
    // a visual grid position -- the same distinction ui.rs's own doc
    // documents at length: once `/s` can reorder the grid, "visual
    // position" and "windows[]'s own index" stop being the same number.
    // `visualSelected` below is the derived visual position `_advance`
    // and the GridView actually need.
    property int selected: 0

    function _recompute() {
        const wantsSession = WinSwitchState.active && WinSwitchState.monitor === root.screen.name;
        if (!wantsSession)
            root.open = false;
    }
    Component.onCompleted: root._recompute()
    // Updated on *every* cycle() call (not just session starts) -- the gap
    // checked below is between consecutive calls, not "how long has the
    // current session been running." Measuring against session-start was a
    // real bug (caught in review, 2026-09-10): if a single determination
    // ever took longer than the guard window -- plausible under the very
    // load a fast auto-repeat burst itself creates, spawning many
    // overlapping `qs`/backend processes -- a *later* auto-repeat firing
    // would incorrectly clear the guard and restart again, right back into
    // the same loop this was meant to fix. Measuring the inter-call gap
    // instead keeps swallowing repeats for as long as they keep arriving
    // fast, however long the key stays down, regardless of how slow any
    // individual determination happens to be.
    property real _lastCycleAt: 0
    // Below this gap (ms) since the previous cycle() call, a repeat call
    // while still undetermined is treated as OS keyboard auto-repeat, not
    // a genuine second press -- see `onCycleSeqChanged`. Comfortably above
    // typical auto-repeat intervals (often 20-50ms once repeating) and
    // comfortably below a genuine fast human double-tap's own gap.
    readonly property int _autoRepeatGuardMs: 150
    Connections {
        target: WinSwitchState
        function onActiveChanged() { root._recompute(); }
        function onMonitorChanged() { root._recompute(); }
        // Fires for *every* cycle() call, including the one that opens a
        // session. Three cases, not two:
        //
        // 1. A confirmed grid already showing (`open`) just gets its
        //    selection advanced in place -- the whole point of `cycle`
        //    being reentrant, see WinSwitchState's own doc.
        //
        // 2. Still undetermined (`open` false) and this call landed within
        //    `_autoRepeatGuardMs` of the *previous* call -- ignore it.
        //    Hyprland's "ALT + Tab" bind re-fires on the compositor's own
        //    keyboard auto-repeat for as long as Tab stays physically
        //    down, not just on the initial press, so a *sustained* hold
        //    generates a steady stream of these calls (every 20-50ms) for
        //    as long as it lasts. Restarting on every one of them -- which
        //    is what this used to do, added for case 3 below -- meant a
        //    determination could never actually finish while the key kept
        //    auto-repeating: each restart threw away the in-flight backend
        //    and began the ~40-70ms debounce/enumeration cycle over again,
        //    so the grid only ever got a chance to complete once the user
        //    *released* the key and the repeats stopped. For a natural
        //    "hold Alt+Tab while scanning for a window" gesture lasting a
        //    couple of seconds, that's a couple of seconds of
        //    restart-looping before anything ever appears -- exactly the
        //    "2-3 second" delay reported 2026-09-10 (confirmed by
        //    measuring directly: a single trigger resolves in ~350-450ms,
        //    matching the backend's own timing, but a burst of triggers
        //    close together never resolved at all within a 5s window).
        //
        // 3. Still undetermined, but this call landed *after*
        //    `_autoRepeatGuardMs` since the previous one -- restart fresh.
        //    This is what makes a genuine rapid double/triple *tap*
        //    (release between presses, each its own fresh keybind fire,
        //    reported 2026-09-09) still resolve against the latest press
        //    instead of getting stuck waiting on a stale one: a real
        //    second press is comfortably slower than auto-repeat's own
        //    interval, so it clears the guard and is treated as new intent.
        function onCycleSeqChanged() {
            if (WinSwitchState.monitor !== root.screen.name)
                return;
            const now = Date.now();
            const gapSincePrevCall = now - root._lastCycleAt;
            root._lastCycleAt = now;
            if (root.open) {
                root._advance(WinSwitchState.pendingDirection);
            } else if (gapSincePrevCall < root._autoRepeatGuardMs) {
                // likely auto-repeat -- do nothing, let the in-flight session finish
            } else {
                root._startSession();
            }
        }
    }

    onOpenChanged: {
        if (root.open) {
            focusGrab.active = true;
            // `card` (an Item), not the PanelWindow root itself, is what
            // needs `focus`/`forceActiveFocus()` -- same reason
            // AppLauncher.qml focuses its inner TextInput rather than
            // itself. Deferred a tick, matching AppLauncher's own
            // `Qt.callLater` -- requesting focus before the surface has
            // actually mapped doesn't stick.
            Qt.callLater(() => card.forceActiveFocus());
        } else {
            focusGrab.active = false;
        }
    }
    function hide() {
        WinSwitchState.close();
    }

    function _startSession() {
        root.windows = [];
        root.thumbnails = ({});
        root.enrichMeta = ({});
        // Drop anything a just-killed previous session's still-in-flight
        // batch had accumulated -- otherwise a stale flush lands on top of
        // this new session's own (unrelated) window indices.
        root._pendingThumbnails = ({});
        root._pendingEnrich = ({});
        flushTimer.stop();
        root._flushScheduled = false;
        root.selected = 0;
        root.queryText = "";
        root.locked = false;
        root._hideSuggestions();
        root._initialDirection = WinSwitchState.pendingDirection;
        // Unconditional stop first (a harmless no-op if nothing was
        // running): a repeat tap arriving before the previous invocation
        // resolved means that previous backend's *output* is now stale and
        // about to be replaced above, but the process itself would
        // otherwise keep running to completion in the background --
        // pointless work, and its trailing NDJSON lines would otherwise
        // still land in `_handleLine` and corrupt the new session's state.
        // (The old backend's own tap-path side effect, if it had already
        // gotten far enough to run `hyprctl::focus_window` before being
        // killed, already happened independently by that point -- nothing
        // here can or needs to undo that.)
        backendProc.running = false;
        backendProc.command = [
            Quickshell.env("HOME") + "/.config/hypr/winswitch/target/release/winswitch",
            WinSwitchState.pendingDirection,
        ];
        backendProc.running = true;
    }

    // ---- filtering / sorting (query DSL) -----------------------------
    readonly property var parsedQuery: WinSwitchQueryDsl.parse(root.queryText)
    // Parallel to `windows` -- built once per windows/enrichMeta change,
    // not per keystroke, since every matcher/sorter call below takes
    // "the meta for this window" as a same-index array (mirrors query.rs's
    // own `&[TmuxClaudeMeta]` shape).
    readonly property var metas: root.windows.map(w => root.enrichMeta[w.index] || {})
    readonly property var activeColumns: WinSwitchQueryDsl.activeColumns(root.queryText, WinSwitchQueryDsl.defaultColumns, root.windows, root.metas)

    readonly property var results: {
        // Fast path, and *reference-stable*: with nothing typed and no
        // /s /rv active (the common state right after opening, before the
        // user has done anything), just hand back `windows` itself rather
        // than a freshly `.filter()`ed copy. This isn't only about the
        // per-keystroke cost query.rs's own filtering was already fine
        // with -- `enrichMeta` (tmux/Claude data) streams in as dozens of
        // separate NDJSON lines right after the grid opens, and each one
        // was retriggering this whole binding (it reads `metas`, which
        // reads `enrichMeta`). `.filter()`/`.slice()` always allocate a
        // *new* array even when the resulting contents are unchanged, and
        // GridView has no way to know a reassigned `model` array is
        // content-identical to the last one -- it just rebuilds every
        // delegate. Fifty-plus of those rebuilds landing in the first
        // second after opening is a very plausible read on "the grid takes
        // 2-3 seconds to settle" (reported 2026-09-10; investigated at
        // length but couldn't get reliable QML-side timing instrumentation
        // working to confirm precisely -- this is the strongest concrete
        // lead from reasoning through the binding graph instead). Returning
        // the *same* `windows` reference here means GridView's model
        // doesn't change identity at all while this fast path holds, no
        // matter how many enrich lines arrive.
        if (root.queryText.length === 0 && !root.parsedQuery.sort && !root.parsedQuery.reverse)
            return root.windows;

        let rows = root.windows.filter(w => WinSwitchQueryDsl.matchesStr(w, root.metas[w.index] || {}, root.queryText));
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
        } else {
            rows = rows.slice(); // stable "recency" order (backend's own) -- already sorted that way
        }
        if (root.parsedQuery.reverse)
            rows = rows.slice().reverse();
        return rows;
    }
    readonly property int visualSelected: {
        const k = root.results.findIndex(w => w.index === root.selected);
        return k >= 0 ? k : 0;
    }
    onResultsChanged: {
        // Keep `selected` pointing at something visible -- if the current
        // selection just got filtered out, land on the first visible
        // result instead (matches ui.rs's own connect_search_changed
        // behavior: move to the first visually-positioned match).
        if (root.results.length > 0 && root.visualSelected === 0 && root.results[0].index !== root.selected)
            root.selected = root.results[0].index;
    }

    function _advance(direction) {
        const n = root.results.length;
        if (n === 0) return;
        const cur = root.visualSelected;
        const next = direction === "prev" ? (cur - 1 + n) % n : (cur + 1) % n;
        root.selected = root.results[next].index;
    }

    function confirm(i) {
        const w = root.windows[i];
        if (!w) return;
        // hyprctl repl + a Lua snippet, not `hyprctl dispatch
        // focuswindow:...` -- this Hyprland build is Lua-scriptable
        // (hl.* API) rather than stock-dispatch, mirrors
        // ~/.config/hypr/winswitch/src/hyprctl.rs::focus_window exactly.
        focusProc.command = ["hyprctl", "repl",
            `local ws = hl.get_windows({})\nfor i, win in ipairs(ws) do\n    if tostring(win.address) == "${w.address}" then\n        hl.dispatch(hl.dsp.focus({ window = win }))\n        break\n    end\nend`];
        focusProc.running = true;
        root.hide();
    }

    // ---- backend process --------------------------------------------
    readonly property Process backendProc: Process {
        stdout: SplitParser {
            onRead: line => root._handleLine(line)
        }
    }
    readonly property Process focusProc: Process {}

    function _handleLine(line) {
        let msg;
        try {
            msg = JSON.parse(line);
        } catch (e) {
            return; // a partial/garbled line -- ignore, never crash the panel over it
        }
        switch (msg.type) {
        case "tap":
            // The backend already dispatched the focus switch itself, and
            // (see `open`'s doc) no surface was ever mapped for this
            // determination -- just tell WinSwitchState the session's done.
            root.hide();
            break;
        case "windows": {
            root.windows = msg.list;
            const n = msg.list.length;
            // index 0 is always the currently-focused window (see
            // `_initialDirection`'s doc) -- classic alt-tab starts the
            // selection on the *previous* one instead, same as the old
            // GTK version's own `start_idx`.
            root.selected = n > 0 ? (root._initialDirection === "prev" ? n - 1 : Math.min(1, n - 1)) : 0;
            root.open = true; // first time the surface actually maps -- see `open`'s doc
            break;
        }
        case "thumbnail":
            root._pendingThumbnails[msg.index] = { path: msg.path, width: msg.width, height: msg.height };
            root._scheduleFlush();
            break;
        case "enrich":
            root._pendingEnrich[msg.index] = Object.assign({}, root._pendingEnrich[msg.index] || {}, msg.meta);
            root._scheduleFlush();
            break;
        }
    }

    // Reviewer-caught gap (2026-09-10, thanks Codex): every incoming
    // `thumbnail`/`enrich` NDJSON line used to reassign the *whole*
    // `thumbnails`/`enrichMeta` dictionary immediately -- for a ~45-window
    // session that's dozens of full-dictionary copies in the first
    // several hundred ms, and each one invalidates *every* delegate's
    // `thumb`/`meta` bindings simultaneously (they read `root.thumbnails`/
    // `root.enrichMeta` directly), not just the one window that actually
    // changed. The earlier `results` fast-path fix only addressed the
    // *model*-level churn this caused (GridView rebuilding delegates from
    // scratch); it didn't touch this separate, per-delegate-binding
    // source of the same kind of repeated work. Coalescing into one flush
    // per animation frame (~16ms) cuts what could be 100+ reassignments
    // down to roughly one per frame for as long as data keeps streaming
    // in, while staying well under human perception of "instant."
    property var _pendingThumbnails: ({})
    property var _pendingEnrich: ({})
    property bool _flushScheduled: false
    function _scheduleFlush() {
        if (!root._flushScheduled) {
            root._flushScheduled = true;
            flushTimer.start();
        }
    }
    Timer {
        id: flushTimer
        interval: 16
        repeat: false
        onTriggered: root._flushPending()
    }
    function _flushPending() {
        root._flushScheduled = false;
        if (Object.keys(root._pendingThumbnails).length > 0) {
            root.thumbnails = Object.assign({}, root.thumbnails, root._pendingThumbnails);
            root._pendingThumbnails = {};
        }
        if (Object.keys(root._pendingEnrich).length > 0) {
            const e = Object.assign({}, root.enrichMeta);
            for (const idx in root._pendingEnrich)
                e[idx] = Object.assign({}, e[idx] || {}, root._pendingEnrich[idx]);
            root.enrichMeta = e;
            root._pendingEnrich = {};
        }
    }

    // ---- grid layout (ported from the old ui.rs's typical_aspect /
    // grid_dims / cell_size / frame_size -- see that file's own doc for the
    // reasoning behind each constant/formula; this is a straight port, not
    // a redesign) ------------------------------------------------------
    readonly property int minFrame: 64
    readonly property int maxFrame: 320
    readonly property int labelAllowance: 54
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
    // Fits one window's own aspect ratio into a `budgetW`x`budgetH` box --
    // ui.rs's `frame_size`, used both for each cell's placeholder frame and
    // (implicitly, since the backend already downscaled to fit) for how
    // large its `Image` renders.
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
    property string queryText: ""
    // Two-phase key state machine, ported from ui.rs's own module doc:
    // while unlocked, Tab/Shift+Tab cycle the selection and releasing Alt
    // confirms it; pressing any other printable key locks the grid into
    // search mode (a filter/sort/column DSL -- see WinSwitchQueryDsl.qml),
    // Alt no longer confirms once locked, and Enter/Escape confirm/cancel
    // in either mode. Locking doesn't require releasing Alt first --
    // holding Alt while typing a search is a completely normal sequence.
    property bool locked: false

    readonly property var _commandSpans: root.queryText.length ? WinSwitchQueryDsl.commandSpans(root.queryText) : []

    // ---- autocomplete (marginalia-style, ported from ui.rs's own
    // suggestion machinery / AppLauncher.qml's simpler equivalent) -----
    property var acItems: []
    property int acSel: 0
    property var acSuggestionKind: null // {kind, start, verb?, via?, field?}
    onAcItemsChanged: { acPopup.visible = root.acItems.length > 0; root.acSel = 0; }

    function _hideSuggestions() {
        root.acItems = [];
        root.acSuggestionKind = null;
    }

    function _acRowInfo(kind, item) {
        if (kind.kind === "verb") {
            // `item` is bare (see WinSwitchQueryDsl.completionCandidates's
            // own doc); `verbInfo` is keyed with the leading "/" (its
            // canonical-identity form), and the displayed label gets one
            // put back too -- matches ui.rs's own `SuggestRow { label:
            // format!("/{item}"), ... }` for the identical stage.
            const info = WinSwitchQueryDsl.verbInfo["/" + item] || { long: "", desc: "" };
            return { label: "/" + item, alias: info.long, desc: info.desc };
        }
        if (kind.kind === "typePath")
            return { label: item, alias: "", desc: WinSwitchQueryDsl.typeDescs[item] || "" };
        return { label: item, alias: "", desc: "" };
    }

    // Candidates for the *current* queryText with no side effects beyond
    // updating acSuggestionKind (render-time row info needs it) - unlike
    // _triggerCompletion below, never auto-accepts a unique candidate, so
    // it's safe to call on every keystroke while narrowing an
    // already-open popup (see searchInput.onTextChanged).
    function _acRecompute() {
        const completion = WinSwitchQueryDsl.completionContext(root.queryText);
        root.acSuggestionKind = completion;
        if (completion === null) return [];
        return WinSwitchQueryDsl.completionCandidates(completion, root.windows, root.metas);
    }

    function _triggerCompletion() {
        const completion = WinSwitchQueryDsl.completionContext(root.queryText);
        if (completion === null) return false;
        const items = WinSwitchQueryDsl.completionCandidates(completion, root.windows, root.metas);
        if (items.length === 0) return false;
        root.acSuggestionKind = completion;
        if (items.length === 1) {
            root.acItems = items;
            root.acSel = 0;
            root._acAccept();
            return true;
        }
        root.acItems = items;
        root.acSel = 0;
        return true;
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
            if (WinSwitchQueryDsl.isGroup(chosen)) {
                newQuery = prefix + chosen; // ready for ".sub", or to stand on its own
            } else if (kind.verb === "/fv" && !kind.via) {
                newQuery = prefix + chosen + ":";
            } else {
                newQuery = prefix + chosen + " ";
            }
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
        default:
            return;
        }
        root._hideSuggestions();
        root.queryText = newQuery;
        Qt.callLater(() => { searchInput.cursorPosition = searchInput.text.length; });
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
        onCleared: root.hide()
    }

    MouseArea {
        anchors.fill: parent
        onClicked: root.hide()
    }

    Rectangle {
        id: card
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.verticalCenter: parent.verticalCenter
        width: root.gridWinW + 32
        // Grows to fit the search box + autocomplete popup once locked, on
        // top of the grid's own budget height -- capped a bit past
        // `_availH` so it can't sprawl past a usable fraction of the
        // screen; the GridView's own scrolling takes over beyond that.
        readonly property int maxCardH: root.screen ? Math.round(root.screen.height * 0.92) : 1000
        height: Math.min(card.maxCardH, (root.locked ? searchHeader.height : 0) + acPopup.height + gridScroll.contentHeightHint + 32)
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
                        // Once the popup is already open, keep recomputing
                        // candidates from the new text instead of closing
                        // it -- narrows the list as you type rather than
                        // forcing another Tab press. `wasOpen` is read
                        // before root.acItems below can change it.
                        const wasOpen = acPopup.visible;
                        if (wasOpen)
                            root.acItems = root._acRecompute();
                        else
                            root._hideSuggestions();
                    }

                    // Inline command-validity coloring (query-dsl.md): an
                    // underline under each /command token -- TextInput has
                    // no per-range text color hook the way GTK's
                    // Pango-backed Entry did (see ui.rs's
                    // apply_command_colors), so an underline positioned via
                    // positionToRectangle is the safe middle ground here,
                    // same approach AppLauncher.qml already uses.
                    Repeater {
                        model: root.queryText.length ? root._commandSpans : []
                        Rectangle {
                            required property var modelData
                            x: searchInput.positionToRectangle(modelData.start).x
                            y: searchInput.positionToRectangle(modelData.start).y
                               + searchInput.positionToRectangle(modelData.start).height - 2
                            width: Math.max(1, searchInput.positionToRectangle(modelData.end).x - x)
                            height: 2
                            radius: 1
                            color: modelData.valid ? Theme.cyan : Theme.red
                        }
                    }

                    // Standard completion-menu convention (reported
                    // 2026-09-09 that accepting on every Tab press without
                    // ever letting you cycle through options was
                    // confusing): the first Tab opens the popup; every Tab
                    // after that just moves the highlight, the same as
                    // Down; Enter is the one key that actually accepts the
                    // highlighted suggestion. Same fix applied to
                    // AppLauncher.qml's identical pattern.
                    Keys.onPressed: event => {
                        if (event.key === Qt.Key_Escape) {
                            if (acPopup.visible) root._hideSuggestions();
                            else root.hide();
                            event.accepted = true;
                        } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                            if (acPopup.visible) root._acAccept();
                            else root.confirm(root.selected);
                            event.accepted = true;
                        } else if (event.key === Qt.Key_Tab) {
                            if (acPopup.visible)
                                root.acSel = (root.acSel + (event.modifiers & Qt.ShiftModifier ? -1 : 1) + root.acItems.length) % root.acItems.length;
                            else
                                root._triggerCompletion();
                            event.accepted = true;
                        } else if (event.key === Qt.Key_Space && acPopup.visible) {
                            root._acAccept();
                            event.accepted = true;
                        } else if (event.key === Qt.Key_Down || (event.key === Qt.Key_J && (event.modifiers & Qt.ControlModifier))) {
                            if (acPopup.visible) root.acSel = Math.min(root.acItems.length - 1, root.acSel + 1);
                            else root._advance("next");
                            event.accepted = true;
                        } else if (event.key === Qt.Key_Up || (event.key === Qt.Key_K && (event.modifiers & Qt.ControlModifier))) {
                            if (acPopup.visible) root.acSel = Math.max(0, root.acSel - 1);
                            else root._advance("prev");
                            event.accepted = true;
                        }
                    }
                }
            }

            // Autocomplete popup, in-layout under the search box -- one row
            // per candidate: label, then the long-form alias and a
            // one-line description, both dim (marginalia), matching
            // AppLauncher.qml's identical popup.
            Column {
                id: acPopup
                visible: false
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
                        readonly property var info: root._acRowInfo(root.acSuggestionKind, modelData)
                        width: acPopup.width - 8
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
            }

            Item {
                id: gridScroll
                width: parent.width
                height: parent.height - searchHeader.height - acPopup.height - contentColumn.spacing * 2
                readonly property int contentHeightHint: root.rows * root.cellHeight

                GridView {
                    id: grid
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

                        readonly property var thumb: root.thumbnails[modelData.index]
                        readonly property bool isSelected: modelData.index === root.selected
                        readonly property var frameDims: root.frameSize(modelData.width, modelData.height, root.cellW, root.maxH)
                        readonly property var meta: root.enrichMeta[modelData.index] || {}
                        readonly property string label: {
                            if (root.activeColumns.length === 0) return "";
                            const parts = [];
                            for (const f of root.activeColumns) {
                                let v = WinSwitchQueryDsl.sortFieldValue(cellItem.modelData, cellItem.meta, f);
                                if (f.kind === "flat" && f.name === "title" && v === "") v = cellItem.modelData.class || "";
                                if (v === "") continue;
                                if (v.length > 80) v = v.slice(0, 80) + "…";
                                parts.push(f.kind === "flat" && f.name === "workspace" ? ("#" + v) : v);
                            }
                            return parts.join(" ");
                        }

                        Rectangle {
                            anchors.fill: parent
                            anchors.margins: 4
                            radius: Theme.rounding - 4
                            color: cellItem.isSelected ? Qt.rgba(Theme.cyan.r, Theme.cyan.g, Theme.cyan.b, 0.16) : "transparent"
                            border.color: cellItem.isSelected ? Theme.cyan : "transparent"
                            border.width: 1

                            Rectangle { // thumbnail frame placeholder, matches ui.rs's outline-only "thumb-frame"
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
                                    asynchronous: true
                                    visible: !!cellItem.thumb
                                    source: cellItem.thumb ? cellItem.thumb.path : ""
                                }
                            }

                            Text {
                                anchors.top: frame.top
                                anchors.topMargin: root.maxH + 4
                                anchors.horizontalCenter: parent.horizontalCenter
                                width: parent.width - 12
                                horizontalAlignment: Text.AlignHCenter
                                elide: Text.ElideRight
                                maximumLineCount: 2
                                wrapMode: Text.Wrap
                                text: cellItem.label
                                font.family: Theme.fontFamily
                                font.pixelSize: Theme.fontSize - 2
                                color: Theme.text
                            }
                        }

                        MouseArea {
                            anchors.fill: parent
                            hoverEnabled: true
                            onEntered: root.selected = cellItem.modelData.index
                            onClicked: root.confirm(cellItem.modelData.index)
                        }
                    }
                }
            }
        }

        Keys.onPressed: event => {
            if (root.locked)
                return; // searchInput owns input once locked, see its own Keys.onPressed
            if (event.key === Qt.Key_Escape) {
                root.hide();
                event.accepted = true;
            } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                root.confirm(root.selected);
                event.accepted = true;
            } else if (event.key === Qt.Key_Tab) {
                root._advance(event.modifiers & Qt.ShiftModifier ? "prev" : "next");
                event.accepted = true;
            } else if (event.key === Qt.Key_Right) {
                root._advance("next");
                event.accepted = true;
            } else if (event.key === Qt.Key_Left) {
                root._advance("prev");
                event.accepted = true;
            } else if (event.key === Qt.Key_Down) {
                const k = Math.min(root.results.length - 1, root.visualSelected + root.cols);
                if (root.results[k]) root.selected = root.results[k].index;
                event.accepted = true;
            } else if (event.key === Qt.Key_Up) {
                const k = Math.max(0, root.visualSelected - root.cols);
                if (root.results[k]) root.selected = root.results[k].index;
                event.accepted = true;
            } else if (event.text && event.text.length > 0) {
                // Any other printable key locks the grid into search mode
                // -- see `locked`'s own doc. Holding Alt doesn't exempt a
                // key from this (typing while Alt is still down is a
                // normal sequence), so no modifier check beyond "did this
                // produce real text" (Qt's own `event.text`, empty for a
                // bare modifier press).
                root.locked = true;
                root.queryText = event.text;
                Qt.callLater(() => {
                    searchInput.forceActiveFocus();
                    searchInput.cursorPosition = searchInput.text.length;
                });
                event.accepted = true;
            }
        }

        // Classic alt-tab: releasing Alt (not typing Enter) is what
        // confirms the held selection -- ported from the old GTK version's
        // own `key_release_event` handler (Alt_L/Alt_R, only outside
        // search-lock mode). Qt.Key_Alt covers Alt_L on a standard layout;
        // AltGr (right Alt on many non-US layouts) reports as
        // Qt.Key_AltGr separately, so both are handled the same way here.
        // Attached to `card`, not `searchInput`: once locked, active focus
        // has moved to `searchInput`, and key-release events bubble up to
        // `card` the same way unhandled presses would, so this still sees
        // them -- the `!root.locked` guard is what actually implements
        // "Alt no longer confirms once locked."
        Keys.onReleased: event => {
            if (!root.locked && (event.key === Qt.Key_Alt || event.key === Qt.Key_AltGr)) {
                root.confirm(root.selected);
                event.accepted = true;
            }
        }
    }
}

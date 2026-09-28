import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import "../theme"
import "../services"

// Clipboard history picker (mod+v) -- replaces the standalone GTK3 +
// gtk-layer-shell app (~/.config/hypr/clipboard-picker/), matching the
// winswitch GTK->Quickshell move (753e505). The Rust binary becomes a
// headless backend (`list`/`thumbs`/`activate` subcommands, NDJSON out --
// see its own module doc) that just talks to cliphist/wl-copy; this file
// owns the search box, the DSL (ClipboardQueryDsl.qml, its own hand-port --
// see that file's header for why it's not a shared import, and for why
// `/ft`/`/at`/`/rt`/`/sort`/`/reverse` are real here as of 2026-09-28, not
// just recognised-but-inert), keyboard nav, column rendering and
// thumbnails. `notification-picker` (this same crate's other bin) made its
// own GTK->Quickshell move on 2026-09-28.
//
// Deliberately keeps two things this port could have "modernized" away,
// because query-dsl.md documents them as this picker's actual behaviour,
// not GTK incidental: bare words join into one phrase (not AND'd terms, see
// ClipboardQueryDsl.parse), and the popup's own keyboard family is the GTK
// one (Tab accepts outright, Ctrl+j/k move the highlight) rather than the
// other QML pickers' Tab-cycles convention (query-dsl.md "Suggestion row
// anatomy"). Also keeps `KeyboardMode::Exclusive`'s full keyboard grab
// (WlrKeyboardFocus.Exclusive below) rather than the OnDemand+FocusGrab
// pattern every other quickshell popup here uses -- a real behavioural
// difference (nothing else on the desktop gets a key while this is open),
// not an oversight, and why this component must never be self-triggered
// for testing (see memory: gtk_layer_shell_picker_testing_risk).
PanelWindow {
    id: root

    property bool open: false

    readonly property var fieldNames: ["type", "date", "chars", "lines", "mime"]
    readonly property var fieldDescs: ({
        "type": "text or image",
        "date": "how long ago it was copied",
        "chars": "character count",
        "lines": "line count",
        "mime": "MIME type(s) offered, comma-separated if more than one"
    })
    // `chars`/`lines` default on -- this picker's old always-on size badge,
    // now real columns instead (query-dsl.md's `/ft`/`/at`/`/rt`). `mime`
    // defaults on too (requested 2026-09-28, right after it was added --
    // opt-in read as "not showing" rather than "hidden on purpose"), last
    // rather than first -- `chars`/`lines` keep the old badge's rightmost
    // position, `mime` trails behind them. `type`/`date` still stay hidden
    // until `/at`'d or Auto-shown by a `/fv` filter.
    readonly property var defaultColumns: ["chars", "lines", "mime"]
    readonly property var columnLabels: ({ type: "type", date: "date", chars: "ch", lines: "l", mime: "mime" })
    // `mime` shrunk from 160 (values are trimmed to the bare type now --
    // `bundle_mimes` drops `;charset=...` -- so they rarely need more).
    readonly property var columnWidths: ({ type: 60, date: 46, chars: 50, lines: 34, mime: 90 })
    // Which column header (if any) is currently hovered, and where to
    // center its tooltip (box-local x) -- see colHeader/headerTip below.
    property string _headerHoverName: ""
    property real _headerHoverCenterX: 0
    function _colWidth(name) { return root.columnWidths[name] || 70; }
    readonly property var activeColumns: ClipboardQueryDsl.activeColumns(root.parsed, root.fieldNames, root.defaultColumns)
    readonly property real _columnsWidth: root.activeColumns.reduce((sum, c) => sum + root._colWidth(c), 0)
    // Shrunk from the GTK version's 160/480 (reported too big after the
    // first live test).
    readonly property int thumbHeight: 120
    readonly property int thumbMaxWidth: 360
    readonly property string _bin: Quickshell.env("HOME") + "/.config/hypr/clipboard-picker/target/release/clipboard-picker"

    function _recompute() {
        root.open = ClipboardPickerState.active && ClipboardPickerState.monitor === root.screen.name;
    }
    Component.onCompleted: root._recompute()
    Connections {
        target: ClipboardPickerState
        function onActiveChanged() { root._recompute(); }
        function onMonitorChanged() { root._recompute(); }
    }

    onOpenChanged: {
        if (root.open) {
            query.text = "";
            root.selectedId = null;
            root._hideSuggestions();
            root._entries = [];
            root._thumbPaths = ({});
            root._animPaths = ({});
            root._noThumb = ({});
            root._refresh();
            Qt.callLater(() => query.forceActiveFocus());
        }
    }
    function hide() { ClipboardPickerState.close(); }

    // ---- entries: `clipboard-picker list` (NDJSON), fetched fresh on open,
    // same as the GTK version re-ran `cliphist list` every invocation ----
    property var _entries: []
    property var _thumbPaths: ({}) // id -> cached PNG path, once resolved
    property var _thumbMeta: ({})  // id -> {width, height} of that cached PNG (its real pixels)
    property var _animPaths: ({})  // id -> small looping GIF (backend re-encoded), played on the selected row only
    property var _noThumb: ({})    // id -> true once the backend found no way to thumbnail it (row falls back to text)
    // id -> a partial `fields` patch waiting to be merged into the matching
    // `_entries` row -- `{chars, lines}` from statsProc, or `{mime}` from
    // mimesProc, both streamed in after `list` (decoding/shelling out for
    // every entry inside `list` itself delayed first paint). Merged in
    // batches (statsFlush): reassigning `_entries` re-filters `results` and
    // rebuilds every delegate, so doing that per line would itself stall
    // the UI, same reasoning textsProc below already documents.
    property var _statsPending: ({})

    // cliphist's own `list` preview hard-truncates at a fixed rune count
    // (observed 100 + its own "…"), independent of the picker's actual
    // width -- a wide box then elides a short, already-truncated string
    // "too early" with a lot of blank space after it, which reads as a
    // layout bug but isn't one (reported 2026-09-12). Detected by shape
    // (long + cliphist's own ellipsis char) rather than trusting an exact
    // length, in case that cap ever changes.
    function _looksTruncated(preview) {
        return preview.length >= 95 && preview.endsWith("…");
    }

    function _refresh() {
        if (listProc.running) return;
        listProc.running = true;
    }

    Process {
        id: listProc
        command: [root._bin, "list"]
        stdout: StdioCollector {
            id: listOut
            onStreamFinished: {
                const rows = [];
                for (const line of listOut.text.split("\n")) {
                    const l = line.trim();
                    if (!l) continue;
                    try { rows.push(JSON.parse(l)); } catch (e) { /* skip */ }
                }
                root._entries = rows;
                const thumbIds = rows.filter(e => e.thumb).map(e => e.id);
                if (thumbIds.length > 0) {
                    thumbsProc.command = [root._bin, "thumbs"].concat(thumbIds);
                    thumbsProc.running = true;
                }
                const statIds = rows.filter(e => !e.thumb && e.fields.chars === undefined).map(e => e.id);
                if (statIds.length > 0 && !statsProc.running) {
                    statsProc.command = [root._bin, "stats"].concat(statIds);
                    statsProc.running = true;
                }
                // `mime` is already filled in directly by `list` for ids
                // with a bundle (cheap manifest read, no subprocess) -- only
                // backfill the rest (pre-existing entries, or a single-
                // format copy with no manifest), same as `chars`/`lines`
                // above but keyed on a different field.
                const mimeIds = rows.filter(e => e.fields.mime === undefined).map(e => e.id);
                if (mimeIds.length > 0 && !mimesProc.running) {
                    mimesProc.command = [root._bin, "mimes"].concat(mimeIds);
                    mimesProc.running = true;
                }
                const longIds = rows.filter(e => !e.thumb && root._looksTruncated(e.preview)).map(e => e.id);
                if (longIds.length > 0) {
                    textsProc.command = [root._bin, "texts"].concat(longIds);
                    textsProc.running = true;
                }
            }
        }
    }

    // Stats/mimes stream in one NDJSON line per entry, but are merged into
    // `_entries` in batches (statsFlush) -- see `_statsPending`'s own doc.
    // Two separate Processes (different subcommands), one shared
    // pending-map/flush-timer pair: both are "backfill one field into
    // `_entries.fields` by id" with identical batching needs, so there's
    // nothing process-specific about the merge step itself.
    Process {
        id: statsProc
        stdout: SplitParser {
            onRead: line => {
                try {
                    const m = JSON.parse(line);
                    root._statsPending[m.id] = Object.assign({}, root._statsPending[m.id],
                        { chars: String(m.chars), lines: String(m.lines) });
                    statsFlush.start();
                } catch (e) { /* skip */ }
            }
        }
        onRunningChanged: if (!running) statsFlush.triggerFlush()
    }
    Process {
        id: mimesProc
        stdout: SplitParser {
            onRead: line => {
                try {
                    const m = JSON.parse(line);
                    root._statsPending[m.id] = Object.assign({}, root._statsPending[m.id], { mime: m.mime });
                    statsFlush.start();
                } catch (e) { /* skip */ }
            }
        }
        onRunningChanged: if (!running) statsFlush.triggerFlush()
    }
    Timer {
        id: statsFlush
        interval: 80
        function triggerFlush() {
            statsFlush.stop();
            const pend = root._statsPending;
            if (Object.keys(pend).length === 0) return;
            root._statsPending = ({});
            root._entries = root._entries.map(e => pend[e.id]
                ? Object.assign({}, e, { fields: Object.assign({}, e.fields, pend[e.id]) })
                : e);
        }
        onTriggered: triggerFlush()
    }

    // Streamed as each decodes (mirrors winswitch's per-window thumbnail
    // events) so images pop in progressively rather than all at once.
    Process {
        id: thumbsProc
        stdout: SplitParser {
            onRead: line => {
                try {
                    const m = JSON.parse(line);
                    if (m.anim) {
                        const a = Object.assign({}, root._animPaths);
                        a[m.id] = m.anim;
                        root._animPaths = a;
                        return;
                    }
                    if (m.nothumb) {
                        const n = Object.assign({}, root._noThumb);
                        n[m.id] = true;
                        root._noThumb = n;
                        return;
                    }
                    const paths = Object.assign({}, root._thumbPaths);
                    paths[m.id] = m.path;
                    root._thumbPaths = paths;
                    const meta = Object.assign({}, root._thumbMeta);
                    meta[m.id] = { width: m.width, height: m.height };
                    root._thumbMeta = meta;
                } catch (e) { /* skip */ }
            }
        }
    }

    // Swaps a truncated entry's preview/haystack for the real full text
    // once decoded (see _looksTruncated) -- mutates `_entries` in place so
    // both the row label and search matching pick it up through the normal
    // path, no separate fallback needed at render time. Multi-line copies
    // are flattened to one line, matching how a short/untruncated cliphist
    // preview already reads.
    Process {
        id: textsProc
        property var pending: ({})
        stdout: SplitParser {
            onRead: line => {
                try {
                    const m = JSON.parse(line);
                    const full = m.text.replace(/\s+/g, " ").trim();
                    if (full) textsProc.pending[m.id] = full;
                } catch (e) { /* skip */ }
            }
        }
        // Applied once, when the stream ends, not per line: every `_entries`
        // assignment re-filters `results`, which resets the ListView and
        // rebuilds every delegate, so one reassignment per long entry (dozens
        // in a row) is what made the picker re-render repeatedly and go
        // unresponsive on open (reported 2026-09-19).
        onRunningChanged: {
            if (running) return;
            const pend = textsProc.pending;
            textsProc.pending = ({});
            if (Object.keys(pend).length === 0) return;
            root._entries = root._entries.map(e => pend[e.id]
                ? Object.assign({}, e, { preview: pend[e.id], haystack: pend[e.id].toLowerCase() })
                : e);
        }
    }

    Process {
        id: activateProc
    }
    function activate(idx) {
        const e = root.results[idx];
        if (!e) return;
        activateProc.command = [root._bin, "activate", e.id];
        activateProc.running = true;
        root.hide();
    }
    function _activateSelectedOrFirst() {
        root.activate(root.selectedIndex >= 0 ? root.selectedIndex : 0);
    }

    // ---- query -> results (ClipboardQueryDsl.parse's bare-words-join-into-
    // one-phrase semantics, picker.rs's own pre-DSL behaviour) -----------
    property var parsed: ClipboardQueryDsl.parse(query.text, root.fieldNames)
    readonly property var results: {
        const filtered = root._entries.filter(e => ClipboardQueryDsl.matches(e, root.parsed));
        return ClipboardQueryDsl.applySort(filtered, root.parsed, root.fieldNames);
    }

    // Selection tracked by entry id, not index -- a row filtered out of view
    // clears the selection instead of silently re-pointing at whatever now
    // sits at the same index (query-dsl.md "Selection follows the user").
    // No auto-selection on open or on every keystroke; the first navigation
    // is what selects anything at all (see _move).
    property var selectedId: null
    readonly property int selectedIndex: {
        if (root.selectedId === null) return -1;
        for (let i = 0; i < root.results.length; i++)
            if (root.results[i].id === root.selectedId) return i;
        return -1;
    }
    onResultsChanged: {
        if (root.selectedId !== null && root.selectedIndex < 0)
            root.selectedId = null;
    }

    // Keeps row `idx` inside the viewport. positionViewAtIndex alone isn't
    // enough here: rows differ in height (thumbnails, badge/extra lines) and
    // a ListView only estimates the position of delegates it hasn't created
    // yet, so a far jump (PageDown) can land short and leave the selection
    // below the window (reported 2026-09-19). So position roughly first, then,
    // once the delegate exists, nudge contentY by its real geometry.
    function _reveal(idx) {
        list.positionViewAtIndex(idx, ListView.Contain);
        Qt.callLater(() => {
            const it = list.itemAtIndex(idx);
            if (!it) return;
            const viewTop = list.contentY + list.topMargin;
            const viewBottom = list.contentY + list.height - list.bottomMargin;
            if (it.y + it.height > viewBottom)
                list.contentY = it.y + it.height - list.height + list.bottomMargin;
            else if (it.y < viewTop)
                list.contentY = it.y - list.topMargin;
        });
    }

    // Home/End: select the first/last result (these no longer move the
    // search box's text cursor).
    function _jump(toEnd) {
        const n = root.results.length;
        if (n === 0) return;
        const idx = toEnd ? n - 1 : 0;
        root.selectedId = root.results[idx].id;
        root._reveal(idx);
    }

    function _move(step) {
        const n = root.results.length;
        if (n === 0) return;
        if (root.selectedIndex < 0) {
            root.selectedId = root.results[0].id; // any first nav lands on top, not step-from-0
            root._reveal(0);
            return;
        }
        const idx = Math.max(0, Math.min(n - 1, root.selectedIndex + step));
        root.selectedId = root.results[idx].id;
        // Keyboard navigation only (mouse hover sets selectedId directly and
        // must not scroll): keep the selected row inside the viewport.
        root._reveal(idx);
    }

    // ---- autocomplete (Tab-triggered to open; GTK-family key handling --
    // see this file's header) -------------------------------------------
    property var acItems: []
    property int acSel: 0
    property var _acCtx: null // {start, kind, field?} the current acItems were computed from
    property bool _verbMulti: false
    property int _verbMultiStart: 0
    // Whether a completion session is open, independent of whether it
    // currently has any candidates to show -- see query's onTextChanged.
    property bool acActive: false

    function _candidates(text) {
        // Ctrl+Space AND-narrowing (query-dsl.md "Ctrl+Space AND-narrows a
        // Verb-stage popup"): every space-separated fragment since the
        // frozen opening "/" must independently substring-match.
        if (root._verbMulti) {
            if (root._verbMultiStart < text.length && text[root._verbMultiStart] === "/") {
                const frags = text.slice(root._verbMultiStart + 1).split(/\s+/).filter(f => f.length > 0);
                const items = ClipboardQueryDsl.verbStageUniverse(root.fieldNames)
                    .filter(v => frags.every(f => ClipboardQueryDsl.substr(f, v)));
                return items.length > 0 ? { start: root._verbMultiStart, kind: "verb", items: items } : null;
            }
            root._verbMulti = false;
        }
        const ctx = ClipboardQueryDsl.completionContext(text, root.fieldNames);
        if (!ctx) return null;
        let items;
        if (ctx.kind === "verb") items = ClipboardQueryDsl.verbSuggestions(ctx.frag, root.fieldNames);
        else if (ctx.kind === "field") items = ClipboardQueryDsl.fieldSuggestions(root.fieldNames, ctx.frag);
        else items = ClipboardQueryDsl.valueSuggestions(root._entries, ctx.field, ctx.frag);
        if (items.length === 0) return null;
        return { start: ctx.start, kind: ctx.kind, field: ctx.field, via: ctx.via, verb: ctx.verb, items: items };
    }

    // Clears what's shown but leaves the session (`acActive`) alone -- used
    // when a keystroke transiently yields zero candidates, so the next
    // keystroke still recomputes instead of dead-ending (see
    // _refreshSuggestions and query's onTextChanged).
    function _clearItems() {
        root.acItems = [];
        root._acCtx = null;
        root._verbMulti = false;
    }

    function _hideSuggestions() {
        root._clearItems();
        root.acActive = false;
    }

    function _applyCandidates(cand) {
        root._acCtx = { start: cand.start, kind: cand.kind, field: cand.field, via: cand.via, verb: cand.verb };
        root.acSel = 0;
        root.acItems = cand.items;
    }

    // Single candidate applies directly, no popup ever shown, same as
    // ordinary shell tab-completion; 2+ reveals the popup. Returns whether
    // it found anything to do.
    function _triggerCompletion() {
        // Marks the session open the moment Tab is pressed, even if this
        // exact keystroke turns up no candidates -- onTextChanged below
        // keeps recomputing from here on, so a later edit that makes the
        // fragment valid again reopens the popup on its own instead of
        // requiring another Tab press.
        root.acActive = true;
        const cand = root._candidates(query.text);
        if (!cand) return false;
        if (cand.items.length === 1) {
            root._applyCandidates(cand);
            root._acceptSuggestion();
            return true;
        }
        root._applyCandidates(cand);
        return true;
    }

    // Called on every keystroke while the popup is already open -- narrows
    // in place, never auto-accepts a unique candidate by typing alone.
    function _refreshSuggestions() {
        const cand = root._candidates(query.text);
        if (cand) root._applyCandidates(cand);
        else root._clearItems(); // keep the session open -- see _clearItems
    }

    function _acceptSuggestion() {
        if (!root._acCtx || root.acItems.length === 0) return;
        const chosen = root.acItems[root.acSel];
        const newText = ClipboardQueryDsl.acceptText(query.text, root._acCtx, chosen);
        root._hideSuggestions();
        query.text = newText;
        query.cursorPosition = query.text.length;
    }

    // ---- window ----------------------------------------------------
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    visible: root.open
    WlrLayershell.layer: WlrLayer.Overlay
    // Full keyboard grab, not OnDemand -- see this file's header.
    WlrLayershell.keyboardFocus: root.open ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None
    WlrLayershell.namespace: "quickshell-clipboard-picker"
    exclusionMode: ExclusionMode.Ignore

    // Only the box itself accepts input -- no click-to-dismiss backdrop
    // (the GTK version had none either: only Escape / Enter / the toggle
    // keybind closes it). Everything outside the box passes straight
    // through to whatever's underneath.
    mask: Region {
        x: box.x
        y: box.y
        width: box.width
        height: box.height
    }

    Rectangle {
        id: box
        anchors.centerIn: parent
        width: root.screen ? Math.round(root.screen.width * 0.5) : 800
        // bottomPad is real structural space below the list, not just
        // ListView's own bottomMargin (which lives *inside* its computed
        // height and kept reading as "too close to the border" even bumped
        // up several times -- this reserves the gap at the box level
        // instead, so it can't be eaten by anything list-internal).
        height: header.height + (ac.visible ? ac.height : 0) + (colHeader.visible ? colHeader.height : 0) + list.height + box.bottomPad
        radius: Theme.rounding
        color: Theme.bgAlpha
        border.color: Theme.cyan
        border.width: 1

        readonly property real _maxTotal: root.screen ? root.screen.height * 0.8 : 800
        readonly property int bottomPad: 14

        Item {
            id: header
            width: parent.width
            // Shrunk from AppLauncher's 44 (reported too tall after the
            // first live test) -- this picker has no icon column to match
            // height with, so it can run more compact.
            height: 34

            TextInput {
                id: query
                anchors.verticalCenter: parent.verticalCenter
                // No leading icon (dropped -- reported as an unwanted left
                // margin) -- 8px matches the list rows' own left inset
                // (col's anchors.leftMargin below) so the text lines up
                // with entry previews underneath.
                x: 8
                width: parent.width - 16
                font.family: Theme.fontFamily
                font.pixelSize: Theme.fontSize
                color: Theme.text
                selectionColor: Theme.cyan
                selectByMouse: true
                clip: true
                onTextChanged: {
                    // Gated on `acActive` (the session), not `acItems.length`
                    // (what's currently shown): the popup hides the instant
                    // candidates drop to zero (e.g. a typo), but the session
                    // stays open, so fixing the typo recomputes and reopens
                    // it rather than dead-ending until another Tab (the same
                    // bug reported 2026-09-13 against winswitch's identical
                    // pattern: "/cla tt" -> zero candidates hid the popup,
                    // and correcting it never brought the list back).
                    if (root.acActive) root._refreshSuggestions();
                }

                // No placeholder text -- the old "$type: $date:" hint used
                // syntax this DSL doesn't speak any more (it's `/ft type`,
                // `/fv type:...` now); "/" + Tab already discovers the
                // grammar (query-dsl.md's Autocompletion section), so a
                // blank box on open beats a stale hint.

                // Inline command-validity coloring (query-dsl.md) -- an
                // underline under each `/command` token (TextInput has no
                // per-range text color the way GTK's Pango Entry does).
                Repeater {
                    model: query.text.length ? ClipboardQueryDsl.commandSpans(query.text) : []
                    Rectangle {
                        required property var modelData
                        x: query.positionToRectangle(modelData.start).x
                        y: query.positionToRectangle(modelData.start).y
                           + query.positionToRectangle(modelData.start).height - 2
                        width: Math.max(1, query.positionToRectangle(modelData.end).x - x)
                        height: 2
                        radius: 1
                        color: modelData.valid ? Theme.cyan : Theme.red
                    }
                }

                Keys.onPressed: event => {
                    const ctrl = (event.modifiers & Qt.ControlModifier) !== 0;

                    if (root.acItems.length > 0) {
                        if (ctrl && event.key === Qt.Key_J) {
                            root.acSel = Math.min(root.acItems.length - 1, root.acSel + 1);
                            event.accepted = true; return;
                        }
                        if (ctrl && event.key === Qt.Key_K) {
                            root.acSel = Math.max(0, root.acSel - 1);
                            event.accepted = true; return;
                        }
                        // GTK-family: Tab accepts the highlighted row
                        // outright (does not cycle -- contrast the other
                        // QML pickers here).
                        if (event.key === Qt.Key_Tab) {
                            root._acceptSuggestion();
                            event.accepted = true; return;
                        }
                        if (ctrl && event.key === Qt.Key_Space) {
                            if (root._acCtx && root._acCtx.kind === "verb") {
                                if (!root._verbMulti) {
                                    root._verbMulti = true;
                                    root._verbMultiStart = root._acCtx.start;
                                }
                                const pos = query.cursorPosition;
                                query.text = query.text.slice(0, pos) + " " + query.text.slice(pos);
                                query.cursorPosition = pos + 1;
                            }
                            event.accepted = true; return; // no-op outside Verb stage
                        }
                        if (event.key === Qt.Key_Space) {
                            root._acceptSuggestion();
                            event.accepted = true; return;
                        }
                        if (event.key === Qt.Key_Escape) {
                            root._hideSuggestions();
                            event.accepted = true; return;
                        }
                        // Up/Down/PageUp/PageDown fall through to the main
                        // list navigation below, unhandled here -- matches
                        // picker.rs (only Ctrl+j/k move the popup highlight).
                    }

                    // Ctrl+Space opens completion too, same as Tab -- not
                    // just the AND-narrowing space it inserts once a
                    // Verb-stage popup is already open (see above). Query-
                    // dsl.md's Autocompletion section documents this as a
                    // second trigger key, not a replacement for Tab.
                    if (event.key === Qt.Key_Tab || (ctrl && event.key === Qt.Key_Space)) {
                        root._triggerCompletion();
                        event.accepted = true; return; // consumed either way
                    }
                    if (event.key === Qt.Key_Escape) {
                        root.hide();
                        event.accepted = true; return;
                    }
                    if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                        root._activateSelectedOrFirst();
                        event.accepted = true; return;
                    }

                    if (event.key === Qt.Key_Home || event.key === Qt.Key_End) {
                        root._jump(event.key === Qt.Key_End);
                        event.accepted = true; return;
                    }

                    let step = 0;
                    if (event.key === Qt.Key_Up || (ctrl && event.key === Qt.Key_K)) step = -1;
                    else if (event.key === Qt.Key_Down || (ctrl && event.key === Qt.Key_J)) step = 1;
                    else if (event.key === Qt.Key_PageUp) step = -20;
                    else if (event.key === Qt.Key_PageDown) step = 20;
                    else return; // let the search entry have it

                    root._move(step);
                    event.accepted = true;
                }
            }

            Rectangle {
                anchors.bottom: parent.bottom
                width: parent.width
                height: 1
                color: Theme.border
            }
        }

        // Autocomplete popup -- in-layout under the header, like the GTK
        // pickers' own in-layout ListBox (no popover to anchor to on a
        // layer surface either way).
        Column {
            id: ac
            visible: root.acItems.length > 0
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
                    readonly property var row: root._acCtx
                        ? ClipboardQueryDsl.suggestRow(root._acCtx.kind, acRow.modelData, root.fieldDescs)
                        : { label: acRow.modelData, alias: "", desc: "" }
                    width: ac.width - 8
                    height: 24
                    radius: Theme.rounding - 5
                    color: cur ? Qt.rgba(Theme.cyan.r, Theme.cyan.g, Theme.cyan.b, 0.18) : "transparent"

                    Row {
                        anchors.verticalCenter: parent.verticalCenter
                        x: 10
                        spacing: 8

                        Text {
                            id: acLabel
                            text: acRow.row.label
                            font.family: Theme.fontFamily
                            font.pixelSize: Theme.fontSize - 1
                            color: acRow.cur ? Theme.cyan : Theme.text
                        }
                        Text {
                            visible: !!acRow.row.alias
                            anchors.baseline: acLabel.baseline
                            text: "(" + acRow.row.alias + ")"
                            font.family: Theme.fontFamily
                            font.pixelSize: Theme.fontSize - 2
                            color: Theme.muted
                        }
                        Text {
                            visible: !!acRow.row.desc
                            anchors.baseline: acLabel.baseline
                            text: acRow.row.desc
                            font.family: Theme.fontFamily
                            font.pixelSize: Theme.fontSize - 2
                            color: Theme.textDim
                        }
                    }

                    MouseArea {
                        anchors.fill: parent
                        onClicked: { root.acSel = acRow.index; root._acceptSuggestion(); }
                    }
                }
            }
        }

        // Column headers (query-dsl.md's `/ft`/`/at`/`/rt`-driven column
        // set, `activeColumns`) -- replaces the old always-on "N ch · M l"
        // badge, which repeated its own units on every row -- see
        // `defaultColumns`. Spans the box the same way `col`/`previewRow`
        // below do (left+right anchors, same 8/8 margins) with a leading
        // invisible spacer computed by the *exact same formula*
        // `previewText.width` uses, rather than an independently
        // right-anchored Row kept in sync with `col`'s margin by hand --
        // that used to be a plain `rightMargin: 16` a few pixels off from
        // `col`'s own 8, which put every header a few px left of where its
        // column's actual values land (reported 2026-09-28). This
        // construction makes that class of bug structurally impossible:
        // header cells and value cells are laid out by the same width
        // arithmetic, so they can't drift apart again.
        Row {
            id: colHeader
            visible: root.activeColumns.length > 0
            anchors {
                top: ac.visible ? ac.bottom : header.bottom
                left: parent.left
                right: parent.right
                leftMargin: 8
                rightMargin: 8
            }
            height: visible ? 18 : 0
            spacing: 10

            Item {
                // Mirrors previewText's width formula exactly (see below) --
                // pushes the header cells that follow to the same x
                // positions their column's values occupy.
                width: colHeader.width - root._columnsWidth
                       - (root.activeColumns.length > 0 ? colHeader.spacing * root.activeColumns.length : 0)
                height: 1
            }

            Repeater {
                model: root.activeColumns
                Text {
                    id: headerCell
                    required property string modelData
                    width: root._colWidth(modelData)
                    horizontalAlignment: Text.AlignRight
                    text: root.columnLabels[modelData] || modelData
                    font.family: Theme.fontFamily
                    font.pixelSize: Theme.fontSize - 2
                    opacity: 0.55
                    color: Theme.text

                    // Explains what a short column label means (e.g. "l =
                    // line count") -- see headerTip below. Guards clearing
                    // `_headerHoverName` on the way out against a value
                    // another cell's HoverHandler already moved on to (the
                    // outgoing cell's `hovered -> false` can fire after the
                    // incoming one's `hovered -> true` when the cursor
                    // crosses straight from one cell into the next).
                    HoverHandler {
                        id: headerHover
                        onHoveredChanged: {
                            if (headerHover.hovered) {
                                root._headerHoverName = headerCell.modelData;
                                root._headerHoverCenterX = colHeader.x + headerCell.x + headerCell.width / 2;
                            } else if (root._headerHoverName === headerCell.modelData) {
                                root._headerHoverName = "";
                            }
                        }
                    }
                }
            }
        }

        // Tooltip for the hovered column header -- "label = description"
        // (query-dsl.md's fieldDescs, e.g. "l = line count"). Positioned
        // just under the header row rather than above it: the header row
        // sits close to the box's own top edge, with no guaranteed room
        // above it to grow into.
        Rectangle {
            id: headerTip
            visible: root._headerHoverName.length > 0
            z: 50
            width: Math.min(220, headerTipText.implicitWidth + 16)
            height: headerTipText.implicitHeight + 10
            x: Math.max(4, Math.min(box.width - width - 4, root._headerHoverCenterX - width / 2))
            y: colHeader.y + colHeader.height + 4
            radius: Theme.rounding
            color: Theme.bg
            border.color: Theme.border
            border.width: 1

            Text {
                id: headerTipText
                anchors.fill: parent
                anchors.margins: 6
                text: root._headerHoverName.length > 0
                      ? (root.columnLabels[root._headerHoverName] || root._headerHoverName) + " = " + (root.fieldDescs[root._headerHoverName] || "")
                      : ""
                wrapMode: Text.WordWrap
                color: Theme.text
                font.family: Theme.fontFamily
                font.pixelSize: Theme.fontSize - 3
            }
        }

        ListView {
            id: list
            anchors.top: colHeader.visible ? colHeader.bottom : (ac.visible ? ac.bottom : header.bottom)
            width: parent.width
            height: Math.max(0, Math.min(contentHeight, box._maxTotal - header.height - (ac.visible ? ac.height : 0) - (colHeader.visible ? colHeader.height : 0) - box.bottomPad))
            clip: true
            model: root.results
            boundsBehavior: Flickable.StopAtBounds
            topMargin: 4
            bottomMargin: 4

            delegate: Rectangle {
                id: row
                required property var modelData
                required property int index
                width: list.width
                height: col.implicitHeight + 4
                color: row.index === root.selectedIndex
                       ? Qt.rgba(Theme.cyan.r, Theme.cyan.g, Theme.cyan.b, 0.16) : "transparent"

                Column {
                    id: col
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.leftMargin: 8
                    anchors.rightMargin: 8
                    y: 2
                    spacing: 2

                    // Placeholder-sized until its thumbnail resolves (keeps
                    // the row from jumping around as thumbnails stream in),
                    // then shrinks to the real target size. Sized from the
                    // backend's *reported* native pixel dimensions
                    // (_thumbMeta), not Qt's `sourceSize`-driven implicit
                    // sizing -- images were coming out visibly larger than
                    // thumbHeight/thumbMaxWidth and softly pixelated
                    // (reported 2026-09-12), consistent with Image ending
                    // up upscaled rather than down. Explicit width/height
                    // computed here can only ever shrink (min(...,1) below),
                    // never upscale.
                    Item {
                        id: thumbBox
                        visible: row.modelData.thumb && !root._noThumb[row.modelData.id]
                        readonly property var _nat: root._thumbMeta[row.modelData.id]
                        readonly property real _scale: thumbBox._nat
                            ? Math.min(root.thumbMaxWidth / thumbBox._nat.width, root.thumbHeight / thumbBox._nat.height, 1)
                            : 1
                        width: thumbBox._nat ? Math.max(1, Math.round(thumbBox._nat.width * thumbBox._scale)) : 1
                        height: thumbBox._nat ? Math.max(1, Math.round(thumbBox._nat.height * thumbBox._scale)) : root.thumbHeight

                        Image {
                            id: thumbImg
                            anchors.fill: parent
                            source: root._thumbPaths[row.modelData.id]
                                    ? ("file://" + root._thumbPaths[row.modelData.id]) : ""
                            fillMode: Image.PreserveAspectFit
                            asynchronous: true
                            smooth: true
                            mipmap: true
                        }

                        // Only the selected/hovered row loads and plays its
                        // animation; every other GIF row stays the still above.
                        AnimatedImage {
                            anchors.fill: parent
                            readonly property string _path: root._animPaths[row.modelData.id] || ""
                            source: (row.index === root.selectedIndex && _path) ? ("file://" + _path) : ""
                            visible: source != "" && status === Image.Ready
                            playing: visible
                            fillMode: Image.PreserveAspectFit
                            smooth: true
                        }
                    }

                    // Preview (flexes) + one right-aligned cell per active
                    // column, ending flush with colHeader's own labels
                    // above -- replaces the old inline "N ch · M l" badge
                    // and the separate dim "extraText" line (query-dsl.md's
                    // Auto-shown filter fields are folded into
                    // activeColumns now, so there's nothing left for a
                    // separate line to show).
                    Row {
                        id: previewRow
                        visible: !row.modelData.thumb
                        width: col.width
                        spacing: 10

                        // Bounded on purpose: textsProc swaps in the *full*
                        // flattened text (up to tens of KB) and shaping all
                        // of that per row, again on every batch of preview
                        // updates, froze the picker on open. No row is
                        // wide enough to show _previewCap chars, so a
                        // capped slice decides "wider than the row" just as
                        // well.
                        readonly property int _previewCap: 300
                        readonly property string shownPreview: row.modelData.preview.length > previewRow._previewCap
                            ? row.modelData.preview.slice(0, previewRow._previewCap) : row.modelData.preview

                        Text {
                            id: previewText
                            width: previewRow.width - root._columnsWidth
                                   - (root.activeColumns.length > 0 ? previewRow.spacing * root.activeColumns.length : 0)
                            text: previewRow.shownPreview
                            elide: Text.ElideRight
                            maximumLineCount: 1
                            font.family: Theme.fontFamily
                            font.pixelSize: Theme.fontSize - 1
                            color: Theme.text
                        }

                        Repeater {
                            model: root.activeColumns
                            Text {
                                required property string modelData
                                width: root._colWidth(modelData)
                                anchors.verticalCenter: previewText.verticalCenter
                                horizontalAlignment: Text.AlignRight
                                text: row.modelData.fields[modelData] || ""
                                elide: Text.ElideRight
                                font.family: Theme.fontFamily
                                font.pixelSize: Theme.fontSize - 2
                                opacity: 0.55
                                color: Theme.text
                            }
                        }
                    }
                }

                MouseArea {
                    anchors.fill: parent
                    hoverEnabled: true
                    onEntered: root.selectedId = row.modelData.id
                    onClicked: root.activate(row.index)
                }
            }
        }

        // Scrollbar drawn by hand off the ListView's visibleArea instead of
        // QtQuick.Controls' ScrollBar: no style/palette to fight the theme,
        // nothing extra to load on the picker's open path. A *sibling* of
        // `list`, not a child -- a ListView's declared children live in its
        // scrolling contentItem and would scroll away with the rows.
        Item {
            id: sbar
            visible: list.contentHeight > list.height
            x: list.x + list.width - width - 2
            y: list.y + 4
            width: 6
            height: list.height - 8

            readonly property real _thumbH: Math.max(28, sbar.height * list.visibleArea.heightRatio)
            readonly property real _travel: sbar.height - sbar._thumbH

            Rectangle {
                id: sthumb
                width: parent.width
                radius: width / 2
                height: sbar._thumbH
                y: sbar._travel * list.visibleArea.yPosition
                     / Math.max(0.0001, 1 - list.visibleArea.heightRatio)
                color: Theme.text
                opacity: sdrag.pressed ? 0.6 : (sdrag.containsMouse ? 0.45 : 0.25)
            }

            // Wider than the drawn thumb so it's easy to grab.
            MouseArea {
                id: sdrag
                x: -6
                width: parent.width + 8
                height: parent.height
                hoverEnabled: true
                function _seek(my) {
                    const frac = Math.max(0, Math.min(1, (my - sbar._thumbH / 2) / Math.max(1, sbar._travel)));
                    list.contentY = list.originY - list.topMargin
                        + frac * Math.max(0, list.contentHeight + list.topMargin + list.bottomMargin - list.height);
                }
                onPressed: mouse => sdrag._seek(mouse.y)
                onPositionChanged: mouse => { if (pressed) sdrag._seek(mouse.y); }
            }
        }
    }
}

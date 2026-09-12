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
// owns the search box, the `/fv`-only DSL (ClipboardQueryDsl.qml, its own
// hand-port -- see that file's header for why it's not a shared import),
// keyboard nav and thumbnail rendering. `notification-picker` (this same
// crate's other bin) is untouched and still the GTK `picker::run` engine --
// only mod+v moved.
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

    readonly property var fieldNames: ["type", "date"]
    readonly property var fieldDescs: ({
        "type": "text or image",
        "date": "how long ago it was copied"
    })
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
                const longIds = rows.filter(e => !e.thumb && root._looksTruncated(e.preview)).map(e => e.id);
                if (longIds.length > 0) {
                    textsProc.command = [root._bin, "texts"].concat(longIds);
                    textsProc.running = true;
                }
            }
        }
    }

    // Streamed as each decodes (mirrors winswitch's per-window thumbnail
    // events) so images pop in progressively rather than all at once.
    Process {
        id: thumbsProc
        stdout: SplitParser {
            onRead: line => {
                try {
                    const m = JSON.parse(line);
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
        stdout: SplitParser {
            onRead: line => {
                try {
                    const m = JSON.parse(line);
                    const full = m.text.replace(/\s+/g, " ").trim();
                    if (!full) return;
                    const idx = root._entries.findIndex(e => e.id === m.id);
                    if (idx < 0) return;
                    const next = root._entries.slice();
                    next[idx] = Object.assign({}, next[idx], { preview: full, haystack: full.toLowerCase() });
                    root._entries = next;
                } catch (e) { /* skip */ }
            }
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
    readonly property var results: root._entries.filter(e => ClipboardQueryDsl.matches(e, root.parsed))

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

    function _move(step) {
        const n = root.results.length;
        if (n === 0) return;
        if (root.selectedIndex < 0) {
            root.selectedId = root.results[0].id; // any first nav lands on top, not step-from-0
            return;
        }
        const idx = Math.max(0, Math.min(n - 1, root.selectedIndex + step));
        root.selectedId = root.results[idx].id;
    }

    // ---- autocomplete (Tab-triggered to open; GTK-family key handling --
    // see this file's header) -------------------------------------------
    property var acItems: []
    property int acSel: 0
    property var _acCtx: null // {start, kind, field?} the current acItems were computed from
    property bool _verbMulti: false
    property int _verbMultiStart: 0

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
        return { start: ctx.start, kind: ctx.kind, field: ctx.field, via: ctx.via, items: items };
    }

    function _hideSuggestions() {
        root.acItems = [];
        root._acCtx = null;
        root._verbMulti = false;
    }

    function _applyCandidates(cand) {
        root._acCtx = { start: cand.start, kind: cand.kind, field: cand.field, via: cand.via };
        root.acSel = 0;
        root.acItems = cand.items;
    }

    // Single candidate applies directly, no popup ever shown, same as
    // ordinary shell tab-completion; 2+ reveals the popup. Returns whether
    // it found anything to do.
    function _triggerCompletion() {
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
        else root._hideSuggestions();
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
        height: header.height + (ac.visible ? ac.height : 0) + list.height
        radius: Theme.rounding
        color: Theme.bgAlpha
        border.color: Theme.cyan
        border.width: 1

        readonly property real _maxTotal: root.screen ? root.screen.height * 0.8 : 800

        Item {
            id: header
            width: parent.width
            // Shrunk from AppLauncher's 44 (reported too tall after the
            // first live test) -- this picker has no icon column to match
            // height with, so it can run more compact.
            height: 34

            Text {
                anchors.verticalCenter: parent.verticalCenter
                x: 16
                text: ""
                font.family: Theme.iconFontFamily
                font.pixelSize: Theme.fontSize - 1
                color: Theme.textDim
            }

            TextInput {
                id: query
                anchors.verticalCenter: parent.verticalCenter
                x: 40
                width: parent.width - 56
                font.family: Theme.fontFamily
                font.pixelSize: Theme.fontSize
                color: Theme.text
                selectionColor: Theme.cyan
                selectByMouse: true
                clip: true
                onTextChanged: {
                    if (root.acItems.length > 0) root._refreshSuggestions();
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

                    if (event.key === Qt.Key_Tab) {
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

                    let step = 0;
                    if (event.key === Qt.Key_Up || (ctrl && event.key === Qt.Key_K)) step = -1;
                    else if (event.key === Qt.Key_Down || (ctrl && event.key === Qt.Key_J)) step = 1;
                    else if (event.key === Qt.Key_PageUp) step = -10;
                    else if (event.key === Qt.Key_PageDown) step = 10;
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

        ListView {
            id: list
            anchors.top: ac.visible ? ac.bottom : header.bottom
            width: parent.width
            height: Math.max(0, Math.min(contentHeight, box._maxTotal - header.height - (ac.visible ? ac.height : 0)))
            clip: true
            model: root.results
            boundsBehavior: Flickable.StopAtBounds
            topMargin: 4
            // Still reported cut off at 12px, bumped further.
            bottomMargin: 24

            delegate: Rectangle {
                id: row
                required property var modelData
                required property int index
                width: list.width
                height: col.implicitHeight + 4
                color: row.index === root.selectedIndex
                       ? Qt.rgba(Theme.cyan.r, Theme.cyan.g, Theme.cyan.b, 0.16) : "transparent"

                readonly property string extraText: {
                    const fields = ClipboardQueryDsl.referencedFields(root.parsed);
                    const vals = fields.map(f => row.modelData.fields[f]).filter(v => !!v);
                    return vals.join("  ·  ");
                }

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
                        visible: row.modelData.thumb
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
                    }

                    Text {
                        visible: !row.modelData.thumb
                        width: col.width
                        text: row.modelData.preview
                        elide: Text.ElideRight
                        maximumLineCount: 1
                        font.family: Theme.fontFamily
                        font.pixelSize: Theme.fontSize - 1
                        color: Theme.text
                    }

                    Text {
                        visible: row.extraText.length > 0
                        width: col.width
                        text: row.extraText
                        elide: Text.ElideRight
                        font.family: Theme.fontFamily
                        font.pixelSize: Theme.fontSize - 2
                        opacity: 0.55
                        color: Theme.text
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
    }
}

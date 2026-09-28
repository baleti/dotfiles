import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import "../theme"
import "../services"
import "../clipboard"

// Notification-history picker (mod+CTRL+n) -- replaces the standalone
// GTK3 + gtk-layer-shell app (~/.config/hypr/clipboard-picker/src/bin/
// notification-picker.rs), matching clipboard-picker's own GTK->Quickshell
// move (mod+v, 2026-09-11) so both search boxes now look and behave the
// same. The Rust binary becomes a headless backend (`list`/`activate`
// subcommands, NDJSON out -- see its own module doc) that just talks to
// notifyctl; this file owns the search box, keyboard nav and result list.
//
// Imports `ClipboardQueryDsl` straight from the clipboard folder rather
// than hand-porting a second copy: both bins were built on the exact same
// `picker.rs` GTK engine and share its grammar byte-for-byte (bare words
// join into one phrase, only `/fv` does anything, GTK-family Tab-accepts/
// Ctrl+j/k keyboard family -- see query-dsl.md), and every DSL entry
// point already takes `fieldNames`/`fieldDescs` as plain arguments, so
// there's nothing clipboard-specific baked into it to hand-port around.
// Once notification-picker also moved off the GTK engine, the two picker
// grammars had no remaining reason to diverge.
//
// Deliberately keeps the same two things ClipboardPicker.qml's own port
// keeps for the same reason (see its header): the GTK-family keyboard
// handling, and `KeyboardMode::Exclusive`'s full keyboard grab (nothing
// else on the desktop gets a key while this is open) rather than the
// OnDemand+FocusGrab pattern every other quickshell popup here uses --
// why this component must never be self-triggered for testing (see
// memory: gtk_layer_shell_picker_testing_risk).
PanelWindow {
    id: root

    property bool open: false

    readonly property var fieldNames: ["app", "date"]
    readonly property var fieldDescs: ({
        "app": "the sending application",
        "date": "how long ago it arrived"
    })
    // Shown as real columns from open, not gated behind Auto-shown filter
    // fields (query-dsl.md) the way clipboard-picker's `type`/`date` still
    // are -- there's no "unconditional" info this picker showed before
    // (clipboard-picker's `chars`/`lines` badge was), so defaulting both
    // on is what makes the table useful the moment it opens. `/rt app`
    // still drops either.
    readonly property var defaultColumns: ["app", "date"]
    readonly property var columnLabels: ({ app: "app", date: "date" })
    readonly property var columnWidths: ({ app: 120, date: 46 })
    function _colWidth(name) { return root.columnWidths[name] || 70; }
    // Which column header (if any) is currently hovered, and where to
    // center its tooltip (box-local x) -- see colHeader/headerTip below.
    property string _headerHoverName: ""
    property real _headerHoverCenterX: 0
    readonly property var activeColumns: ClipboardQueryDsl.activeColumns(root.parsed, root.fieldNames, root.defaultColumns)
    readonly property real _columnsWidth: root.activeColumns.reduce((sum, c) => sum + root._colWidth(c), 0)
    readonly property string _bin: Quickshell.env("HOME") + "/.config/hypr/clipboard-picker/target/release/notification-picker"

    function _recompute() {
        root.open = NotificationPickerState.active && NotificationPickerState.monitor === root.screen.name;
    }
    Component.onCompleted: root._recompute()
    Connections {
        target: NotificationPickerState
        function onActiveChanged() { root._recompute(); }
        function onMonitorChanged() { root._recompute(); }
    }

    onOpenChanged: {
        if (root.open) {
            query.text = "";
            root.selectedId = null;
            root._hideSuggestions();
            root._entries = [];
            root._refresh();
            Qt.callLater(() => query.forceActiveFocus());
        }
    }
    function hide() { NotificationPickerState.close(); }

    // ---- entries: `notification-picker list` (NDJSON), fetched fresh on
    // open, same as the GTK version re-ran `notifyctl list` every
    // invocation ----
    property var _entries: []

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
    // enough here: rows can differ slightly in height (the extra-fields
    // line) and a ListView only estimates the position of delegates it
    // hasn't created yet, so a far jump (PageDown) can land short and
    // leave the selection below the window. So position roughly first,
    // then, once the delegate exists, nudge contentY by its real geometry.
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
    WlrLayershell.namespace: "quickshell-notification-picker"
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
        // Full screen width minus the same edge inset the notification
        // cards sit in from -- HyprGaps.left/right (live Hyprland
        // gaps_out) *plus* HyprGaps.extraInset, the same aesthetic nudge
        // NotifLayer.qml applies on top of the bare gap (checked
        // 2026-09-28: the bare gap alone sits flush with a real tiled
        // window's edge, visibly less inset than where the cards actually
        // sit) -- rather than a fixed 0.5 fraction of screen width
        // (reported too narrow once columns started eating into the
        // preview text).
        anchors {
            verticalCenter: parent.verticalCenter
            left: parent.left
            right: parent.right
            leftMargin: HyprGaps.left + HyprGaps.extraInset
            rightMargin: HyprGaps.right + HyprGaps.extraInset
        }
        // bottomPad is real structural space below the list, not just
        // ListView's own bottomMargin (which lives *inside* its computed
        // height) -- see ClipboardPicker.qml, same reasoning.
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
            height: 34

            TextInput {
                id: query
                anchors.verticalCenter: parent.verticalCenter
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
                    // (what's currently shown) -- see ClipboardPicker.qml.
                    if (root.acActive) root._refreshSuggestions();
                }

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
        // set, `activeColumns`) -- right-anchored so it sits flush above
        // the same column cells each row draws at its own right edge,
        // with no separate placeholder needed for the (unlabeled) preview
        // column to its left.
        Row {
            id: colHeader
            visible: root.activeColumns.length > 0
            anchors {
                top: ac.visible ? ac.bottom : header.bottom
                right: parent.right
                rightMargin: 16
            }
            height: visible ? 18 : 0
            spacing: 10

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

                    // Explains what a short column label means (e.g. "app =
                    // the sending application") -- see headerTip below.
                    // Guards clearing `_headerHoverName` against a value
                    // another cell's HoverHandler already moved on to -- see
                    // ClipboardPicker.qml's identical comment.
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
        // (query-dsl.md's fieldDescs, e.g. "app = the sending
        // application"). Positioned just under the header row rather than
        // above it: the header row sits close to the box's own top edge,
        // with no guaranteed room above it to grow into.
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
                height: rowContent.implicitHeight + 4
                color: row.index === root.selectedIndex
                       ? Qt.rgba(Theme.cyan.r, Theme.cyan.g, Theme.cyan.b, 0.16) : "transparent"

                // preview (flexes) + one right-aligned cell per active
                // column, ending flush with colHeader's own labels above --
                // replaces the old dim "extraText" line (query-dsl.md's
                // Auto-shown filter fields are folded into activeColumns
                // now, so there's nothing left for a separate line to show).
                Row {
                    id: rowContent
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.leftMargin: 8
                    anchors.rightMargin: 16
                    y: 2
                    spacing: 10

                    Text {
                        id: previewText
                        width: rowContent.width - root._columnsWidth
                               - (root.activeColumns.length > 0 ? rowContent.spacing * root.activeColumns.length : 0)
                        text: row.modelData.preview
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

                MouseArea {
                    anchors.fill: parent
                    hoverEnabled: true
                    onEntered: root.selectedId = row.modelData.id
                    onClicked: root.activate(row.index)
                }
            }
        }

        // Scrollbar drawn by hand off the ListView's visibleArea -- see
        // ClipboardPicker.qml, same reasoning (no ScrollBar style/palette
        // to fight, nothing extra to load on the picker's open path).
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

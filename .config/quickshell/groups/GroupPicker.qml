import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import "../theme"
import "../services"
import "../clipboard"

// Group picker (mod+Tab) -- lists the tabs of the active window's Hyprland
// group and switches to the one you pick. A trimmed copy of
// NotificationPicker.qml (itself a trimmed ClipboardPicker.qml), so it looks and
// behaves like mod+v / mod+CTRL+n: same search box and query DSL (imported from
// ../clipboard), same keyboard family, same full-keyboard-grab layer surface --
// which is why it must not be self-triggered for testing (see memory:
// gtk_layer_shell_picker_testing_risk). Data comes from ~/bin/group-windows
// (`list` / `activate`), which reads hyprctl. The tab that is showing when it
// opens is pre-selected.
PanelWindow {
    id: root

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

    readonly property var fieldNames: ["app", "tab", "title"]
    readonly property var fieldDescs: ({
        "app": "the window's application class",
        "tab": "position in the group",
        "title": "the window title"
    })
    readonly property var defaultColumns: ["app", "tab"]
    readonly property var columnLabels: ({ app: "app", tab: "tab", title: "title" })
    readonly property var columnWidths: ({ app: 120, tab: 40, title: 260 })
    function _colWidth(name) { return root.columnWidths[name] || 70; }
    // Which column header (if any) is currently hovered, and where to
    // center its tooltip (box-local x) -- see colHeader/headerTip below.
    property string _headerHoverName: ""
    property real _headerHoverCenterX: 0
    readonly property var activeColumns: ClipboardQueryDsl.activeColumns(root.parsed, root.fieldNames, root.defaultColumns)
    readonly property real _columnsWidth: root.activeColumns.reduce((sum, c) => sum + root._colWidth(c), 0)

    readonly property string _bin: Quickshell.env("HOME") + "/bin/group-windows"

    function _recompute() {
        root.open = GroupPickerState.active && GroupPickerState.monitor === root.screen.name;
    }
    Component.onCompleted: root._recompute()
    Connections {
        target: GroupPickerState
        function onActiveChanged() { root._recompute(); }
        function onMonitorChanged() { root._recompute(); }
    }

    onOpenChanged: {
        root._hoverOrigin = null;
        root._hoverArmed = false;
        if (root.open) {
            query.text = "";
            root.selectedId = null;
            root._hideSuggestions();
            root._entries = [];
            root._refresh();
            Qt.callLater(() => query.forceActiveFocus());
        }
    }
    function hide() { GroupPickerState.close(); }

    // ---- entries: `group-windows list` (NDJSON), fetched fresh on open ----
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
                // Land on the tab that is showing now.
                const cur = rows.findIndex(r => r.current);
                if (cur >= 0 && root.selectedId === null) {
                    root.selectedId = rows[cur].id;
                    Qt.callLater(() => root._reveal(cur));
                }
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
    WlrLayershell.namespace: "quickshell-group-picker"
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
        // Full screen width minus the same edge inset the notification cards
        // and the other pickers sit in from (HyprGaps.left/right plus the
        // aesthetic HyprGaps.extraInset nudge).
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
                // Native key-repeat here delivers a flood of RELEASE events
                // flagged isAutoRepeat=true (confirmed live 2026-10-04, see
                // AppLauncher.qml's identical comment) -- only a genuine
                // key-up should actually stop the repeat.
                Keys.onReleased: event => { if (!event.isAutoRepeat) _stopNavRepeat(); }

                Keys.onPressed: event => {
                    const ctrl = (event.modifiers & Qt.ControlModifier) !== 0;

                    if (root.acItems.length > 0) {
                        if (ctrl && event.key === Qt.Key_J) {
                            if (!event.isAutoRepeat) _startNavRepeat(() => { root.acSel = Math.min(root.acItems.length - 1, root.acSel + 1); });
                            event.accepted = true; return;
                        }
                        if (ctrl && event.key === Qt.Key_K) {
                            if (!event.isAutoRepeat) _startNavRepeat(() => { root.acSel = Math.max(0, root.acSel - 1); });
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

                    if (!event.isAutoRepeat) _startNavRepeat(() => root._move(step));
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

                    // Themed icon for the window's class; fixed-width cell so it
                    // forms an aligned first column even when an icon is missing.
                    Item {
                        id: iconCell
                        width: 20
                        height: 20
                        anchors.verticalCenter: previewText.verticalCenter
                        Image {
                            anchors.fill: parent
                            fillMode: Image.PreserveAspectFit
                            smooth: true
                            asynchronous: true
                            visible: status === Image.Ready
                            sourceSize.width: 40
                            sourceSize.height: 40
                            source: Quickshell.iconPath((row.modelData.icon ?? "").toString(), "application-x-executable")
                        }
                    }

                    Text {
                        id: previewText
                        width: rowContent.width - root._columnsWidth - iconCell.width - rowContent.spacing
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
                    id: rowHover
                    onPositionChanged: mouse => { if (root._pointerMoved(rowHover, mouse)) root.selectedId = row.modelData.id; }
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

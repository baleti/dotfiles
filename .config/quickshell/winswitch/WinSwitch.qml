import QtQuick
import Quickshell
import Quickshell.Wayland
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
    Component.onCompleted: root._recompute()
    readonly property var windows: WinSwitchState.windows
    readonly property int selected: WinSwitchState.selected
    readonly property bool locked: WinSwitchState.locked

    // Session that activated this view's focus grab, so a `cleared` arriving
    // late from a previous session can't close a newer one.
    property int _grabSession: -1

    onOpenChanged: {
        if (root.open) {
            root.queryText = "";
            root._hideSuggestions();
            root._hoverOrigin = null;
            root._hoverArmed = false;
            root._grabSession = WinSwitchState.sessionId;
            focusGrab.active = true;
            // Deferred a tick, matching AppLauncher: requesting focus before
            // the surface has mapped doesn't stick.
            Qt.callLater(() => card.forceActiveFocus());
        } else {
            focusGrab.active = false;
        }
    }

    function hide() {
        WinSwitchState.close();
    }
    function confirm(i) {
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
    // Parallel to `windows` (same index), built once per windows/enrichMeta
    // change, not per keystroke.
    readonly property var metas: root.windows.map(w => WinSwitchState.enrichMeta[w.address] || {})
    readonly property var activeColumns: WinSwitchQueryDsl.activeColumns(root.queryText, WinSwitchQueryDsl.defaultColumns, root.windows, root.metas)

    readonly property var results: {
        // Reference-stable fast path: with no query, hand back `windows`
        // itself so enrichment updates don't rebuild every grid delegate.
        if (root.queryText.length === 0)
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
        }
        if (root.parsedQuery.reverse)
            rows = rows.slice().reverse();
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
        const n = root.results.length;
        if (n === 0) return;
        const cur = root.visualSelected;
        let next;
        if (cur < 0)
            next = direction === "prev" ? n - 1 : 0;
        else
            next = direction === "prev" ? (cur - 1 + n) % n : (cur + 1) % n;
        WinSwitchState.selected = root.results[next].index;
    }
    function _advanceRow(delta) {
        const n = root.results.length;
        if (n === 0) return;
        const k = Math.max(0, Math.min(n - 1, Math.max(0, root.visualSelected) + delta));
        WinSwitchState.selected = root.results[k].index;
    }

    // ---- grid layout (ported from the old GTK ui.rs's typical_aspect /
    // grid_dims / cell_size / frame_size) ------------------------------------
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
    onAcItemsChanged: { acPopup.visible = root.acItems.length > 0; root.acSel = 0; }

    function _hideSuggestions() {
        root.acItems = [];
        root.acSuggestionKind = null;
    }

    function _acRowInfo(kind, item) {
        if (kind.kind === "verb") {
            // `item` is bare; `verbInfo` is keyed with the leading "/".
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
        onCleared: {
            if (root._grabSession === WinSwitchState.sessionId)
                root.hide();
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
                        // An already-open popup narrows as you type instead
                        // of closing.
                        if (acPopup.visible)
                            root.acItems = root._acRecompute();
                        else
                            root._hideSuggestions();
                    }

                    // Inline command-validity coloring (query-dsl.md): an
                    // underline under each /command token, same approach as
                    // AppLauncher.qml (TextInput has no per-range color).
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

                    Keys.onPressed: event => {
                        if (event.key === Qt.Key_Escape) {
                            if (acPopup.visible) root._hideSuggestions();
                            else root.hide();
                            event.accepted = true;
                        } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                            if (acPopup.visible) root._acAccept();
                            else root.confirm(root.selected);
                            event.accepted = true;
                        } else if (event.key === Qt.Key_Tab || event.key === Qt.Key_Backtab) {
                            root._completionTab(event.key === Qt.Key_Backtab || (event.modifiers & Qt.ShiftModifier) ? "prev" : "next");
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

            // Autocomplete popup, in-layout under the search box: label, then
            // the long-form alias and a one-line description, both dim.
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

                        readonly property var thumb: WinSwitchState.thumbnails[modelData.address]
                        readonly property string thumbPath: cellItem.thumb ? cellItem.thumb.path : ""
                        // What's on screen: only swapped once the incoming
                        // capture has decoded, so a refresh never blanks.
                        property string shownPath: ""
                        readonly property bool isSelected: modelData.index === root.selected
                        readonly property var frameDims: root.frameSize(modelData.width, modelData.height, root.cellW, root.maxH)
                        readonly property var meta: WinSwitchState.enrichMeta[modelData.address] || {}
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
                                    visible: cellItem.shownPath !== ""
                                    source: cellItem.shownPath
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
        }

        // Only reached while unlocked (searchInput has focus once locked).
        // Alt+Tab never arrives here -- the compositor bind eats it -- so
        // this is Escape/Enter/arrows, plus typing to enter search mode.
        Keys.onPressed: event => {
            if (root.locked)
                return;
            if (event.key === Qt.Key_Escape) {
                root.hide();
                event.accepted = true;
            } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                root.confirm(root.selected);
                event.accepted = true;
            } else if (event.key === Qt.Key_Tab || event.key === Qt.Key_Backtab) {
                root._advance(event.key === Qt.Key_Backtab || (event.modifiers & Qt.ShiftModifier) ? "prev" : "next");
                event.accepted = true;
            } else if (event.key === Qt.Key_Right) {
                root._advance("next");
                event.accepted = true;
            } else if (event.key === Qt.Key_Left) {
                root._advance("prev");
                event.accepted = true;
            } else if (event.key === Qt.Key_Down) {
                root._advanceRow(root.cols);
                event.accepted = true;
            } else if (event.key === Qt.Key_Up) {
                root._advanceRow(-root.cols);
                event.accepted = true;
            } else if (event.text && event.text.length > 0 && event.text.charCodeAt(0) >= 0x20) {
                // Any printable key (Alt may still be held) locks into search.
                WinSwitchState.locked = true;
                root.queryText = event.text;
                Qt.callLater(() => {
                    searchInput.forceActiveFocus();
                    searchInput.cursorPosition = searchInput.text.length;
                });
                event.accepted = true;
            }
        }
    }
}

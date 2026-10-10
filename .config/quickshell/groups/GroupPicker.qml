import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Hyprland
import "../theme"
import "../services"

// Group picker (mod+Tab): a thumbnail grid of the tabs in the active window's
// Hyprland group, laid out and styled like the alt+tab grid (winswitch/
// WinSwitch.qml), minus its search mode. Enter / click switches to the tab.
//
// Data: ~/bin/group-windows (`list` / `activate`, reads hyprctl). Thumbnails:
// the alt+tab capture backend (~/.config/hypr/winswitch), run with
// WINSWITCH_ONLY=<the group's addresses> so it captures just these tabs --
// hidden tabs capture fine. Captures are kept in GroupPickerState so a re-open
// shows the last picture straight away.
//
// Opens with OnDemand keyboard focus + a HyprlandFocusGrab, like the alt+tab
// grid (not the pickers' exclusive grab), so it is safe to leave open.
PanelWindow {
    id: root

    // Set imperatively, not bound -- see WinSwitch.qml / AppLauncher.qml.
    property bool open: false
    function _recompute() {
        root.open = GroupPickerState.active && GroupPickerState.monitor === root.screen.name;
    }
    Component.onCompleted: root._recompute()
    Connections {
        target: GroupPickerState
        function onActiveChanged() { root._recompute(); }
        function onMonitorChanged() { root._recompute(); }
    }

    readonly property string _bin: Quickshell.env("HOME") + "/bin/group-windows"
    readonly property string _captureBin: Quickshell.env("HOME") + "/.config/hypr/winswitch/target/release/winswitch"

    // [{id, address, index, preview, icon, current, width, height, fields}]
    property var windows: []
    property int selected: -1

    function hide() { GroupPickerState.close(); }

    onOpenChanged: {
        root._stopNavRepeat();
        if (root.open) {
            root._hoverOrigin = null;
            root._hoverArmed = false;
            root.windows = [];
            root.selected = -1;
            root._refresh();
            focusGrab.active = true;
            root._claimFocus();
        } else {
            focusGrab.active = false;
            captureTimer.stop();
        }
    }

    // Keep retrying until the card really has keyboard focus (a single
    // deferred tick can land before the surface has mapped).
    function _claimFocus() {
        if (!root.open) return;
        card.forceActiveFocus();
        if (!card.activeFocus) Qt.callLater(root._claimFocus);
    }

    // ---- data ------------------------------------------------------------
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
                if (!root.open) return;
                root.windows = rows;
                root.selected = Math.max(0, rows.findIndex(r => r.current));
                Qt.callLater(() => grid.positionViewAtIndex(root.selected, GridView.Contain));
                if (rows.length > 0) captureTimer.restart();
            }
        }
    }

    // Capture waits for the surface to be up so Hyprland's main thread isn't
    // busy rendering windows while the grid maps (see WinSwitchState.qml).
    Timer {
        id: captureTimer
        interval: 150
        onTriggered: {
            if (!root.open || captureProc.running) return;
            captureProc.command = ["env", "WINSWITCH_ONLY=" + root.windows.map(w => w.address).join(","), root._captureBin];
            captureProc.running = true;
        }
    }
    Process {
        id: captureProc
        stdout: SplitParser {
            onRead: line => {
                let msg;
                try { msg = JSON.parse(line); } catch (e) { return; }
                if (msg.type !== "thumbnail") return;
                const t = Object.assign({}, GroupPickerState.thumbnails);
                t[msg.address] = { path: msg.path, width: msg.width, height: msg.height };
                GroupPickerState.thumbnails = t;
            }
        }
    }

    Process { id: activateProc }
    function confirm(i) {
        const w = root.windows[i];
        root.hide();
        if (!w) return;
        if (!w.current) {
            activateProc.command = [root._bin, "activate", w.address];
            activateProc.running = true;
        }
    }

    // ---- navigation --------------------------------------------------------
    function _advance(direction) {
        const n = root.windows.length;
        if (n === 0) return;
        const cur = Math.max(0, root.selected);
        root.selected = direction === "prev" ? (cur - 1 + n) % n : (cur + 1) % n;
        grid.positionViewAtIndex(root.selected, GridView.Contain);
    }
    function _advanceRow(delta) {
        const n = root.windows.length;
        if (n === 0) return;
        root.selected = Math.max(0, Math.min(n - 1, Math.max(0, root.selected) + delta));
        grid.positionViewAtIndex(root.selected, GridView.Contain);
    }
    function _jump(toEnd) {
        const n = root.windows.length;
        if (n === 0) return;
        root.selected = toEnd ? n - 1 : 0;
        grid.positionViewAtIndex(root.selected, GridView.Contain);
    }

    // Hold-to-repeat, same mechanism as the other pickers (layer-shell key
    // repeat isn't guaranteed to reach us).
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

    // Hover only selects once the pointer has genuinely moved since opening
    // (a stationary mouse under the grid must not steal the selection).
    property var _hoverOrigin: null
    property bool _hoverArmed: false
    function _pointerMoved(item, mouse) {
        if (root._hoverArmed) return true;
        const p = item.mapToItem(null, mouse.x, mouse.y);
        if (!root._hoverOrigin) { root._hoverOrigin = p; return false; }
        if (Math.abs(p.x - root._hoverOrigin.x) + Math.abs(p.y - root._hoverOrigin.y) > 8)
            root._hoverArmed = true;
        return root._hoverArmed;
    }

    // ---- grid layout (same maths as the alt+tab grid) --------------------
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
        return [cols, Math.ceil(n / cols)];
    }
    function _cellSize(winW, winH, cols, rows) {
        const cellW = Math.max(winW / cols - root.cellHOverhead, root.minFrame);
        const cellH = Math.max(winH / rows - root.cellVOverhead, root.minFrame + root.labelAllowance);
        const maxH = Math.max(root.minFrame, Math.min(root.maxFrame, cellH - root.labelAllowance));
        return [cellW, maxH];
    }
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
    // Capped at the largest thumbnail so a small group gets a compact card
    // instead of one stretched across 70% of the screen.
    readonly property int cellWBudget: Math.max(Math.min(Math.floor(root._availW / root.cols), root.maxFrame + root.cellHOverhead), root.minFrame + root.cellHOverhead)
    readonly property int cellHBudget: Math.max(
        Math.min(Math.round(root.cellWBudget * root._aspect), Math.floor(root._availH / root.rows)),
        root.minFrame + root.labelAllowance + root.cellVOverhead)
    readonly property int gridWinW: Math.min(root.cellWBudget * root.cols, root._availW)
    readonly property int gridWinH: Math.min(root.cellHBudget * root.rows, root._availH)
    readonly property var _cellSizeResult: root._cellSize(root.gridWinW, root.gridWinH, root.cols, root.rows)
    readonly property int cellW: root._cellSizeResult[0]
    readonly property int maxH: root._cellSizeResult[1]
    readonly property int cellHeight: root.maxH + root.labelAllowance + root.cellVOverhead

    // ---- window ----------------------------------------------------------
    anchors { top: true; left: true }
    implicitWidth: root.screen ? root.screen.width : 1920
    implicitHeight: root.screen ? root.screen.height : 1080
    color: "transparent"
    visible: root.open
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: root.open ? WlrKeyboardFocus.OnDemand : WlrKeyboardFocus.None
    WlrLayershell.namespace: "quickshell-group-picker"
    exclusionMode: ExclusionMode.Ignore

    HyprlandFocusGrab {
        id: focusGrab
        windows: [root]
        onCleared: root.hide()
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
        readonly property int maxCardH: root.screen ? Math.round(root.screen.height * 0.92) : 1000
        height: Math.min(card.maxCardH, root.rows * root.cellHeight + 32)
        radius: Theme.rounding
        color: Theme.bgAlpha
        border.color: Theme.cyan
        border.width: 1
        focus: true

        MouseArea { anchors.fill: parent } // swallow clicks so they don't reach the backdrop

        GridView {
            id: grid
            anchors.fill: parent
            anchors.margins: 16
            cellWidth: root.cellW + root.cellHOverhead
            cellHeight: root.cellHeight
            clip: true
            boundsBehavior: Flickable.StopAtBounds
            currentIndex: root.selected
            model: root.windows

            delegate: Item {
                id: cellItem
                required property var modelData
                required property int index
                width: grid.cellWidth
                height: grid.cellHeight

                readonly property var thumb: GroupPickerState.thumbnails[modelData.address]
                readonly property string thumbPath: cellItem.thumb ? cellItem.thumb.path : ""
                // Only swapped once the incoming capture has decoded, so a
                // refresh never blanks the frame.
                property string shownPath: ""
                readonly property bool isSelected: cellItem.index === root.selected
                readonly property var frameDims: root.frameSize(modelData.width, modelData.height, root.cellW, root.maxH)

                Rectangle {
                    anchors.fill: parent
                    anchors.margins: 4
                    radius: Theme.rounding - 4
                    color: cellItem.isSelected ? Qt.rgba(Theme.cyan.r, Theme.cyan.g, Theme.cyan.b, 0.16) : "transparent"
                    border.color: cellItem.isSelected ? Theme.cyan : "transparent"
                    border.width: 1

                    Rectangle { // thumbnail frame / placeholder
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

                        // Tab number, top-left.
                        Rectangle {
                            x: 6
                            y: 6
                            width: tabNum.implicitWidth + 10
                            height: tabNum.implicitHeight + 4
                            radius: 3
                            color: Qt.rgba(0, 0, 0, 0.55)
                            Text {
                                id: tabNum
                                anchors.centerIn: parent
                                text: cellItem.modelData.index + 1
                                font.family: Theme.fontFamily
                                font.pixelSize: Theme.fontSize - 3
                                color: cellItem.modelData.current ? Theme.cyan : Theme.text
                            }
                        }
                    }

                    Text {
                        anchors.top: frame.top
                        anchors.topMargin: root.maxH + 4
                        anchors.horizontalCenter: parent.horizontalCenter
                        width: parent.width - 12
                        textFormat: Text.PlainText
                        horizontalAlignment: Text.AlignHCenter
                        elide: Text.ElideRight
                        maximumLineCount: 2
                        wrapMode: Text.Wrap
                        text: cellItem.modelData.preview
                        font.family: Theme.fontFamily
                        font.pixelSize: Theme.fontSize - 2
                        color: Theme.text
                    }
                }

                MouseArea {
                    id: cellMouse
                    anchors.fill: parent
                    hoverEnabled: true
                    onPositionChanged: mouse => { if (root._pointerMoved(cellMouse, mouse)) root.selected = cellItem.index; }
                    onClicked: root.confirm(cellItem.index)
                }
            }
        }

        Keys.onPressed: event => {
            const ctrl = (event.modifiers & Qt.ControlModifier) !== 0;
            if (event.key === Qt.Key_Escape) {
                root.hide();
            } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                root.confirm(Math.max(0, root.selected));
            } else if (event.key === Qt.Key_Tab || event.key === Qt.Key_Backtab) {
                root._advance(event.key === Qt.Key_Backtab || (event.modifiers & Qt.ShiftModifier) ? "prev" : "next");
            } else if (event.key === Qt.Key_Home || event.key === Qt.Key_End) {
                root._jump(event.key === Qt.Key_End);
            } else if (event.key === Qt.Key_Right || (ctrl && event.key === Qt.Key_L)) {
                if (!event.isAutoRepeat) root._startNavRepeat(() => root._advance("next"));
            } else if (event.key === Qt.Key_Left || (ctrl && event.key === Qt.Key_H)) {
                if (!event.isAutoRepeat) root._startNavRepeat(() => root._advance("prev"));
            } else if (event.key === Qt.Key_Down || (ctrl && event.key === Qt.Key_J)) {
                if (!event.isAutoRepeat) root._startNavRepeat(() => root._advanceRow(root.cols));
            } else if (event.key === Qt.Key_Up || (ctrl && event.key === Qt.Key_K)) {
                if (!event.isAutoRepeat) root._startNavRepeat(() => root._advanceRow(-root.cols));
            } else {
                return;
            }
            event.accepted = true;
        }
        // Native key-repeat delivers a flood of RELEASE events flagged
        // isAutoRepeat=true (see AppLauncher.qml); only a real key-up stops it.
        Keys.onReleased: event => { if (!event.isAutoRepeat) root._stopNavRepeat(); }
    }
}

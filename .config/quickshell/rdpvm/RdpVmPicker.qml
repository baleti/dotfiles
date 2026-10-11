import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Hyprland
import "../theme"
import "../services"

// Revit VM RDP picker, opened by the "RDP: Revit VM" launcher entry (~/bin/rdp-revit-vm-menu). Looks like the app launcher (mod + Super_l):
// same card, search box and row styling. The rows are the Revit VMs running on host2 right now (`rdp-revit-vm-menu --list`, queried
// each time it opens); Enter runs `rdp-windows-vm <cid>`. Plain substring filter, no query DSL (a handful of rows).
// Exclusive-ish keyboard grab like the other pickers: never self-launch it to test, use the launcher entry.
PanelWindow {
    id: root

    property bool open: false
    property int selected: 0
    property var vms: []
    property string status: ""
    readonly property string _bin: Quickshell.env("HOME") + "/bin/rdp-revit-vm-menu"

    // Ignore the pointer until it has genuinely moved since the popup opened.
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

    function _recompute() {
        root.open = RdpVmPickerState.active && RdpVmPickerState.monitor === root.screen.name;
    }
    Component.onCompleted: root._recompute()
    Connections {
        target: RdpVmPickerState
        function onActiveChanged() { root._recompute(); }
        function onMonitorChanged() { root._recompute(); }
    }

    onOpenChanged: {
        root._hoverOrigin = null;
        root._hoverArmed = false;
        if (root.open) {
            query.text = "";
            root.selected = 0;
            root.vms = [];
            root.status = "asking host2...";
            if (!listProc.running) listProc.running = true;
            focusGrab.active = true;
            Qt.callLater(() => query.forceActiveFocus());
        } else {
            focusGrab.active = false;
        }
    }
    function hide() { RdpVmPickerState.close(); }

    // `cid <TAB> name <TAB> cpus <TAB> mem <TAB> gpu|qxl <TAB> revit instances <TAB> claude title` per running VM
    Process {
        id: listProc
        command: [root._bin, "--list"]
        stdout: StdioCollector {
            id: listOut
            onStreamFinished: {
                root.vms = listOut.text.split("\n").filter(l => l.length > 0).map(l => {
                    const f = l.split("\t");
                    return { cid: f[0], name: f[1] || "", detail: (f[2] || "?") + " cpu  " + (f[3] || "?"), gpu: f[4] === "gpu", revit: f[5] || "", claude: f[6] || "" };
                });
                root.status = root.vms.length === 0 ? "no Revit VM running on host2 (or host2 unreachable)" : "";
            }
        }
    }

    readonly property var results: {
        const q = query.text.trim().toLowerCase();
        return root.vms.filter(v => q === "" || ("cid " + v.cid + " " + (v.gpu ? "gpu passthrough" : "qxl") + " " + v.name + " " + v.detail + " " + v.revit + " " + v.claude).toLowerCase().indexOf(q) >= 0);
    }
    onResultsChanged: if (root.selected >= results.length) root.selected = Math.max(0, results.length - 1)

    Process { id: rdpProc }
    function launch(i) {
        const v = root.results[i];
        if (!v) return;
        rdpProc.command = [Quickshell.env("HOME") + "/bin/rdp-windows-vm", v.cid];
        rdpProc.running = true;
        root.hide();
    }

    anchors { top: true; left: true }
    implicitWidth: root.screen ? root.screen.width : 1920
    implicitHeight: root.screen ? root.screen.height : 1080
    color: "transparent"
    visible: root.open
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: root.open ? WlrKeyboardFocus.OnDemand : WlrKeyboardFocus.None
    WlrLayershell.namespace: "quickshell-rdpvm"
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
        width: 520
        height: Math.min(Math.round((root.screen ? root.screen.height : 1080) * 0.6), 44 + 8 + Math.max(1, root.results.length) * 76 + 24)
        radius: Theme.rounding
        color: Theme.bgAlpha
        border.color: Theme.cyan
        border.width: 1
        MouseArea { anchors.fill: parent }

        Item {
            id: header
            width: parent.width
            height: 44

            Text {
                anchors.verticalCenter: parent.verticalCenter
                x: 16
                text: ""
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

                Text {
                    anchors.verticalCenter: parent.verticalCenter
                    text: qsTr("RDP into a running Revit VM")
                    color: Theme.muted
                    font: query.font
                    visible: query.text.length === 0
                }

                Keys.onPressed: event => {
                    const ctrl = event.modifiers & Qt.ControlModifier;
                    if (event.key === Qt.Key_Escape) {
                        root.hide();
                    } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                        root.launch(root.selected);
                    } else if (event.key === Qt.Key_Down || (ctrl && event.key === Qt.Key_J) || event.key === Qt.Key_Tab) {
                        if (root.results.length > 0) root.selected = Math.min(root.results.length - 1, root.selected + 1);
                    } else if (event.key === Qt.Key_Up || (ctrl && event.key === Qt.Key_K) || event.key === Qt.Key_Backtab) {
                        root.selected = Math.max(0, root.selected - 1);
                    } else {
                        return;
                    }
                    event.accepted = true;
                }
                onTextChanged: root.selected = 0
            }
        }

        Text {
            anchors.top: header.bottom
            anchors.topMargin: 10
            x: 16
            width: parent.width - 32
            visible: root.status !== ""
            text: root.status
            wrapMode: Text.WordWrap
            font.family: Theme.fontFamily
            font.pixelSize: Theme.fontSize - 1
            color: Theme.textDim
        }

        ListView {
            id: list
            anchors.top: header.bottom
            anchors.bottom: parent.bottom
            width: parent.width
            clip: true
            model: root.results
            currentIndex: root.selected
            highlightMoveDuration: 0
            boundsBehavior: Flickable.StopAtBounds
            topMargin: 4
            bottomMargin: 4

            delegate: Rectangle {
                id: row
                required property var modelData
                required property int index
                width: list.width
                height: 76
                color: index === root.selected ? Qt.rgba(Theme.cyan.r, Theme.cyan.g, Theme.cyan.b, 0.16) : "transparent"

                Text {
                    x: 12
                    anchors.verticalCenter: parent.verticalCenter
                    text: ""
                    font.family: Theme.iconFontFamily
                    font.pixelSize: 16
                    color: row.modelData.gpu ? Theme.cyan : Theme.textDim
                }
                Column {
                    x: 40
                    anchors.verticalCenter: parent.verticalCenter
                    width: parent.width - 52
                    spacing: 1
                    Text {
                        width: parent.width
                        text: "Revit VM  CID " + row.modelData.cid + "  ·  " + (row.modelData.gpu ? "GPU passthrough" : "QXL")
                        elide: Text.ElideRight
                        font.family: Theme.fontFamily
                        font.pixelSize: Theme.fontSize - 1
                        color: Theme.text
                    }
                    Text {
                        width: parent.width
                        text: row.modelData.name + "  ·  " + row.modelData.detail
                        elide: Text.ElideRight
                        font.family: Theme.fontFamily
                        font.pixelSize: Theme.fontSize - 2
                        color: Theme.textDim
                        opacity: 0.7
                    }
                    Text {
                        width: parent.width
                        text: "Revit  " + row.modelData.revit
                        elide: Text.ElideRight
                        font.family: Theme.fontFamily
                        font.pixelSize: Theme.fontSize - 2
                        color: Theme.textDim
                        opacity: 0.7
                    }
                    Text {
                        visible: row.modelData.claude !== ""
                        width: parent.width
                        text: "Claude  " + row.modelData.claude
                        elide: Text.ElideRight
                        font.family: Theme.fontFamily
                        font.pixelSize: Theme.fontSize - 2
                        color: Theme.textDim
                        opacity: 0.7
                    }
                }
                MouseArea {
                    id: rowHover
                    anchors.fill: parent
                    hoverEnabled: true
                    onPositionChanged: mouse => { if (root._pointerMoved(rowHover, mouse)) root.selected = index; }
                    onClicked: root.launch(index)
                }
            }
        }
    }
}

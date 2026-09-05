import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import "../theme"

// hyprland/workspaces equivalent: {name} buttons, click to activate.
Row {
    id: root

    required property ShellScreen screen

    spacing: 2

    // `Hyprland.dispatch()` sends a raw `dispatch <cmd>` string over the
    // socket, which this install's Lua-scriptable Hyprland fork doesn't
    // understand (see hyprland_lua_binding_dispatch_syntax memory) -- has
    // to go through `hyprctl repl` + `hl.dispatch(hl.dsp.focus(...))`
    // instead, same as ClaudeUsageExpanded.qml's focusHyprWindow().
    function switchToWorkspace(id) {
        switchProc.exec(["hyprctl", "repl", "hl.dispatch(hl.dsp.focus({ workspace = " + id + " }))"]);
    }

    Process { id: switchProc }

    Repeater {
        // ScriptModel (not a plain array) so Repeater diffs by object
        // identity -- an unrelated workspace change elsewhere used to
        // rebuild every delegate here, causing a visible flicker.
        model: ScriptModel {
            // Exclude special/scratch workspaces (negative ids, per
            // Hyprland convention) -- these back the mod+<key> pinned-app
            // scratch feature in hyprland/keybinds.lua, not a real
            // workspace to switch to. Scoped to this bar's own monitor.
            values: Hyprland.workspaces.values.filter(ws => ws.id > 0 && ws.monitor?.name === root.screen.name)
        }

        Rectangle {
            id: wsBtn

            required property HyprlandWorkspace modelData

            readonly property bool isActive: modelData.active
            readonly property bool isUrgent: modelData.urgent

            implicitWidth: label.implicitWidth + 16
            implicitHeight: 24
            width: implicitWidth
            height: implicitHeight
            radius: 7
            color: isActive ? Theme.cyan : isUrgent ? Theme.red : hover.containsMouse ? Qt.rgba(0.2, 0.8, 1, 0.15) : "transparent"

            Text {
                id: label
                anchors.centerIn: parent
                text: wsBtn.modelData.name
                color: wsBtn.isActive || wsBtn.isUrgent ? "#1a1a1a" : Theme.muted
                font.family: Theme.fontFamily
                font.pixelSize: Theme.fontSize
            }

            MouseArea {
                id: hover
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: root.switchToWorkspace(wsBtn.modelData.id)
            }
        }
    }
}

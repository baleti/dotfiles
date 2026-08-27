import QtQuick
import Quickshell.Hyprland
import "../theme"

// hyprland/submap equivalent. Quickshell.Hyprland has no direct "submap"
// property, so this tracks the raw IPC event stream itself (matches
// Hyprland's own socket2 "submap>>name" event, empty name = default/reset).
// Self-contained pill that collapses to nothing when there's no active
// submap, rather than leaving an empty rounded box in the bar.
Rectangle {
    id: root

    property string submap: ""

    visible: submap.length > 0
    implicitWidth: visible ? label.implicitWidth + Theme.pillPadH * 2 : 0
    implicitHeight: Theme.barHeight - 10
    width: implicitWidth
    height: implicitHeight

    color: Theme.bgAlpha
    border.color: Theme.border
    border.width: 1
    radius: Theme.rounding

    Text {
        id: label
        anchors.centerIn: parent
        text: root.submap
        font.italic: true
        color: Theme.green
        font.family: Theme.fontFamily
        font.pixelSize: Theme.fontSize
    }

    Connections {
        target: Hyprland
        function onRawEvent(event: var): void {
            if (event.name === "submap")
                root.submap = event.data;
        }
    }
}

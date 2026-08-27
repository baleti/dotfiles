import QtQuick
import "../theme"

// One "island": rgba(26,26,26,0.9) rounded rect with a subtle border, matching
// the old waybar style.css #workspaces/#tray/etc rules.
Rectangle {
    default property alias content: inner.children
    property int hPad: Theme.pillPadH

    implicitWidth: inner.implicitWidth + hPad * 2
    implicitHeight: Theme.barHeight - 10
    width: implicitWidth
    height: implicitHeight

    color: Theme.bgAlpha
    border.color: Theme.border
    border.width: 1
    radius: Theme.rounding

    Row {
        id: inner
        anchors.centerIn: parent
        spacing: 8
    }
}

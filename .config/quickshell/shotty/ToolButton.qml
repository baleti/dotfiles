import QtQuick
import "../theme"

// Toolbar button: icon only (bigger, no cramped inline caption) -- the
// shortcut shows as a small tooltip next to the cursor on hover instead.
Rectangle {
    id: tb
    required property string icon
    required property string tooltip
    property bool active: false
    signal activated()

    width: 38; height: 38; radius: 6
    color: active ? Theme.cyan : Theme.bgAlpha
    border.width: 1
    border.color: Theme.border

    Text {
        anchors.centerIn: parent
        text: tb.icon
        font.pixelSize: 18
        color: active ? Theme.bg : Theme.text
    }

    MouseArea {
        id: ma
        anchors.fill: parent
        hoverEnabled: true
        onClicked: tb.activated()
    }

    Rectangle {
        id: tip
        visible: ma.containsMouse
        x: ma.mouseX + 14
        y: ma.mouseY + 14
        z: 1000
        width: tipText.implicitWidth + 12
        height: tipText.implicitHeight + 6
        radius: 4
        color: Theme.bgAlpha
        border.width: 1
        border.color: Theme.border

        Text {
            id: tipText
            anchors.centerIn: parent
            text: tb.tooltip
            font.pixelSize: 11
            color: Theme.text
        }
    }
}

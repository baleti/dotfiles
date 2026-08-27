import QtQuick
import Quickshell
import Quickshell.Widgets
import Quickshell.Services.SystemTray
import "../theme"

// Self-contained pill that collapses to nothing when there are no tray
// icons, rather than leaving an empty rounded box in the bar.
Rectangle {
    id: root

    readonly property bool hasItems: SystemTray.items.values.length > 0

    visible: hasItems
    implicitWidth: hasItems ? inner.implicitWidth + Theme.pillPadH * 2 : 0
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
        spacing: 10

        Repeater {
            model: SystemTray.items.values

            IconImage {
                id: icon

                required property var modelData

                implicitSize: 16
                source: modelData.icon ? Quickshell.iconPath(modelData.icon, true) : ""

                MouseArea {
                    anchors.fill: parent
                    acceptedButtons: Qt.LeftButton | Qt.RightButton
                    cursorShape: Qt.PointingHandCursor
                    onClicked: mouse => {
                        if (mouse.button === Qt.LeftButton)
                            icon.modelData.activate();
                        else
                            icon.modelData.secondaryActivate();
                    }
                }
            }
        }
    }
}

import QtQuick
import "../theme"

Text {
    id: root

    property date now: new Date()

    font.family: Theme.fontFamily
    font.pixelSize: Theme.fontSize
    font.bold: true
    color: Theme.cyan
    text: Qt.formatDateTime(now, "ddd dd MMM  hh:mm")

    Timer {
        interval: 1000
        running: true
        repeat: true
        onTriggered: root.now = new Date()
    }
}

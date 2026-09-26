import QtQuick
import "../theme"

Text {
    id: root

    // Per-bar override (Bar.qml shrinks it when the bar runs out of room).
    property int fontSize: Theme.fontSize

    property date now: new Date()

    font.family: Theme.fontFamily
    font.pixelSize: root.fontSize
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

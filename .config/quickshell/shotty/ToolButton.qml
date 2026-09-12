import QtQuick

// Toolbar button: icon glyph + tiny shortcut-letter caption underneath, so
// the toolbar doubles as its own shortcut reference.
Rectangle {
    id: tb
    required property string icon
    required property string letter
    property bool active: false
    signal activated()
    width: 30; height: 34; radius: 5
    color: active ? "#3a5a7a" : "#333333"
    Column {
        anchors.centerIn: parent
        spacing: 0
        Text { anchors.horizontalCenter: parent.horizontalCenter; text: tb.icon; font.pixelSize: 14; color: "white" }
        Text { anchors.horizontalCenter: parent.horizontalCenter; text: tb.letter; font.pixelSize: 8; color: "#aaaaaa" }
    }
    MouseArea { anchors.fill: parent; onClicked: tb.activated() }
}

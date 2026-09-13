import QtQuick
import "../theme"

// Toolbar button: a small flat vector icon (drawn on a Canvas, not an emoji
// glyph -- emoji render inconsistently sized/styled across fonts) with a
// tooltip next to the cursor on hover instead of a cramped inline caption.
Rectangle {
    id: tb
    required property string iconType // arrow | rect | line | copy | save | cancel
    required property string tooltip
    property bool active: false
    signal activated()

    width: 28; height: 28; radius: 5
    color: active ? Theme.cyan : Theme.bgAlpha
    border.width: 1
    border.color: Theme.border

    Canvas {
        id: canvas
        anchors.centerIn: parent
        width: 16; height: 16
        property color strokeColor: tb.active ? Theme.bg : Theme.text
        onStrokeColorChanged: requestPaint()
        Component.onCompleted: requestPaint()

        onPaint: {
            const ctx = getContext("2d");
            ctx.reset();
            ctx.strokeStyle = strokeColor;
            ctx.fillStyle = strokeColor;
            ctx.lineWidth = 1.4;
            ctx.lineCap = "round";
            ctx.lineJoin = "round";

            switch (tb.iconType) {
            case "arrow":
                ctx.beginPath();
                ctx.moveTo(2, 14);
                ctx.lineTo(14, 2);
                ctx.stroke();
                ctx.beginPath();
                ctx.moveTo(14, 2);
                ctx.lineTo(8, 2);
                ctx.moveTo(14, 2);
                ctx.lineTo(14, 8);
                ctx.stroke();
                break;
            case "rect":
                ctx.strokeRect(2.5, 3.5, 11, 9);
                break;
            case "line":
                ctx.beginPath();
                ctx.moveTo(2, 14);
                ctx.lineTo(14, 2);
                ctx.stroke();
                break;
            case "copy":
                ctx.strokeRect(3.5, 3.5, 8, 10);
                ctx.beginPath();
                ctx.moveTo(6, 3.5);
                ctx.lineTo(6, 1.5);
                ctx.lineTo(9.5, 1.5);
                ctx.lineTo(9.5, 3.5);
                ctx.stroke();
                break;
            case "save":
                ctx.strokeRect(2.5, 2.5, 11, 11);
                ctx.strokeRect(5, 2.5, 6, 4);
                ctx.strokeRect(4.5, 9, 7, 4.5);
                break;
            case "cancel":
                ctx.beginPath();
                ctx.moveTo(3, 3);
                ctx.lineTo(13, 13);
                ctx.moveTo(13, 3);
                ctx.lineTo(3, 13);
                ctx.stroke();
                break;
            }
        }
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
        x: ma.mouseX + 12
        y: ma.mouseY + 12
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

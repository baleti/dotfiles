import QtQuick
import QtQuick.Shapes
import "../theme"

// Toolbar button: a small flat icon built from native scene-graph
// primitives (Rectangle borders / Shape paths), NOT a Canvas -- Canvas
// rasterizes to a bitmap that doesn't reliably track the real per-monitor
// scale (this machine's eDP-2 already has a confirmed Qt-vs-Hyprland scale
// mismatch, see Shotty.qml's _grabAndReport comment), so canvas-drawn icons
// came out visibly blurry. Rectangle/Shape are rendered natively by the
// scene graph at the real backing resolution, same as every other item in
// this shell, so they stay crisp regardless of monitor scale. Also not an
// emoji glyph -- those render inconsistently sized/styled across fonts.
Rectangle {
    id: tb
    required property string iconType // arrow | rect | line | copy | save | cancel
    required property string tooltip
    property bool active: false
    signal activated()

    readonly property color strokeColor: active ? Theme.bg : Theme.text

    width: 28; height: 28; radius: 5
    color: active ? Theme.cyan : Theme.bgAlpha
    border.width: 1
    border.color: Theme.border

    Item {
        id: icon
        anchors.centerIn: parent
        width: 16; height: 16

        // Boxy icons: plain bordered Rectangles, inherently crisp.
        Rectangle {
            visible: tb.iconType === "rect"
            x: 2; y: 3; width: 12; height: 10
            color: "transparent"
            border.width: 1.4
            border.color: tb.strokeColor
        }
        Rectangle {
            // Clipboard body
            visible: tb.iconType === "copy"
            x: 3; y: 3; width: 9; height: 11
            color: "transparent"
            border.width: 1.4
            border.color: tb.strokeColor
        }
        Rectangle {
            // Clipboard clip
            visible: tb.iconType === "copy"
            x: 6; y: 1; width: 4; height: 2.5
            radius: 0.5
            color: "transparent"
            border.width: 1.2
            border.color: tb.strokeColor
        }
        Rectangle {
            // Floppy disk body
            visible: tb.iconType === "save"
            x: 2; y: 2; width: 12; height: 12
            color: "transparent"
            border.width: 1.4
            border.color: tb.strokeColor
        }
        Rectangle {
            // Floppy disk shutter
            visible: tb.iconType === "save"
            x: 5; y: 2; width: 6; height: 4
            color: "transparent"
            border.width: 1.2
            border.color: tb.strokeColor
        }
        Rectangle {
            // Floppy disk label
            visible: tb.iconType === "save"
            x: 4.5; y: 9; width: 7; height: 4.5
            color: "transparent"
            border.width: 1.2
            border.color: tb.strokeColor
        }

        // Line-based icons: real vector paths (Shape/ShapePath), not a
        // raster canvas -- stays crisp at any scale. ShapePath isn't a
        // QQuickItem (no `visible` of its own -- it's a QQuickPath data
        // element), so each icon needing conditional paths gets its own
        // Shape, gated at the Shape level where `visible` genuinely exists.
        Shape {
            anchors.fill: parent
            visible: tb.iconType === "arrow"
            preferredRendererType: Shape.CurveRenderer
            ShapePath {
                strokeColor: tb.strokeColor
                strokeWidth: 1.4
                fillColor: "transparent"
                capStyle: ShapePath.RoundCap
                startX: 2; startY: 14
                PathLine { x: 14; y: 2 }
            }
            ShapePath {
                strokeColor: tb.strokeColor
                strokeWidth: 1.4
                fillColor: "transparent"
                capStyle: ShapePath.RoundCap
                startX: 8; startY: 2
                PathLine { x: 14; y: 2 }
                PathLine { x: 14; y: 8 }
            }
        }
        Shape {
            anchors.fill: parent
            visible: tb.iconType === "line"
            preferredRendererType: Shape.CurveRenderer
            ShapePath {
                strokeColor: tb.strokeColor
                strokeWidth: 1.4
                fillColor: "transparent"
                capStyle: ShapePath.RoundCap
                startX: 2; startY: 14
                PathLine { x: 14; y: 2 }
            }
        }
        Shape {
            anchors.fill: parent
            visible: tb.iconType === "cancel"
            preferredRendererType: Shape.CurveRenderer
            ShapePath {
                strokeColor: tb.strokeColor
                strokeWidth: 1.4
                fillColor: "transparent"
                capStyle: ShapePath.RoundCap
                startX: 3; startY: 3
                PathLine { x: 13; y: 13 }
            }
            ShapePath {
                strokeColor: tb.strokeColor
                strokeWidth: 1.4
                fillColor: "transparent"
                capStyle: ShapePath.RoundCap
                startX: 13; startY: 3
                PathLine { x: 3; y: 13 }
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

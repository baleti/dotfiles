import QtQuick
import "../theme"
import "../services"

// Compact volume readout: speaker icon + current percentage. Click pins the
// detail panel (VolumeExpanded); scroll wheel changes the volume in 5% steps.
Rectangle {
    id: root

    // Per-bar override (Bar.qml shrinks it when the bar runs out of room).
    property int fontSize: Theme.fontSize

    signal toggled
    readonly property alias hovered: mouseArea.containsMouse

    implicitWidth: row.implicitWidth + Theme.pillPadH * 2
    implicitHeight: Theme.barHeight - 10
    width: implicitWidth
    height: implicitHeight

    color: Theme.bgAlpha
    border.color: Theme.border
    border.width: 1
    radius: Theme.rounding

    readonly property string glyph: {
        if (AudioSvc.muted)
            return Icons.volMuted;
        return Icons.levelIcon(Icons.volLevels, Math.min(1, AudioSvc.volume));
    }
    readonly property color tint: AudioSvc.muted ? Theme.muted : Theme.text

    Row {
        id: row
        anchors.centerIn: parent
        spacing: 4

        Text {
            anchors.verticalCenter: parent.verticalCenter
            text: root.glyph
            font.family: Theme.iconFontFamily
            font.pixelSize: root.fontSize
            color: root.tint
        }
        Text {
            anchors.verticalCenter: parent.verticalCenter
            text: AudioSvc.hasSink ? AudioSvc.percent + "%" : "--"
            font.family: Theme.fontFamily
            font.pixelSize: root.fontSize
            color: root.tint
            // Fixed slot wide enough for "150%" so the bar doesn't jiggle
            // as the number gains/loses a digit.
            width: Math.max(implicitWidth, fm.advanceWidth("100%"))
            horizontalAlignment: Text.AlignRight
        }
    }

    FontMetrics {
        id: fm
        font.family: Theme.fontFamily
        font.pixelSize: root.fontSize
    }

    MouseArea {
        id: mouseArea
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: root.toggled()
        onWheel: wheel => {
            const step = wheel.angleDelta.y > 0 ? 0.05 : -0.05;
            AudioSvc.setVolume(Math.round((AudioSvc.volume + step) * 20) / 20);
            wheel.accepted = true;
        }
    }
}

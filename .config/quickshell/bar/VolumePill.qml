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

    // When the MPRIS target (ALT+CTRL+SHIFT+m) is the phone bridge, the pill
    // shows/controls the phone's STREAM_MUSIC via the player's MPRIS Volume
    // (same routing as playerctl-volume.sh) instead of the local sink.
    readonly property var phone: {
        const p = Players.active;
        return (p && p.dbusName === "org.mpris.MediaPlayer2.pixel6" && p.volumeSupported) ? p : null;
    }
    readonly property real vol: phone ? phone.volume : AudioSvc.volume
    readonly property bool isMuted: phone ? false : AudioSvc.muted
    readonly property bool available: phone ? true : AudioSvc.hasSink

    readonly property string glyph: {
        if (root.isMuted)
            return Icons.volMuted;
        return Icons.levelIcon(Icons.volLevels, Math.min(1, root.vol));
    }
    readonly property color tint: root.isMuted ? Theme.muted : Theme.text

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
            text: root.available ? Math.round(root.vol * 100) + "%" : "--"
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
            if (root.phone)
                root.phone.volume = Math.max(0, Math.min(1, root.phone.volume + step));
            else
                AudioSvc.setVolume(Math.round((AudioSvc.volume + step) * 20) / 20);
            wheel.accepted = true;
        }
    }
}

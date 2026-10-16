import QtQuick
import "../theme"
import "../services"

// Detail panel under VolumePill: output volume slider + mute, input (mic)
// state, running PipeWire/WirePlumber info, active app streams, and - for
// Bluetooth headphones - a radio list of the card's selectable profiles
// (A2DP high-fidelity playback vs HSP/HFP headset with microphone).
Rectangle {
    id: root

    property bool expanded: false
    readonly property bool hovered: mouseArea.containsMouse

    // Set from outside by Bar.qml (shared popup-row layout).
    property real panelWidth: 320
    width: panelWidth
    implicitHeight: expanded ? content.implicitHeight + 24 : 0
    height: implicitHeight
    visible: height > 0
    radius: Theme.rounding
    color: Theme.bgAlpha
    border.color: Theme.border
    border.width: 1
    clip: true

    onExpandedChanged: if (expanded) AudioSvc.refresh()

    MouseArea {
        id: mouseArea
        anchors.fill: parent
        hoverEnabled: true
        acceptedButtons: Qt.AllButtons
        onWheel: wheel => wheel.accepted = true
    }

    component Label: Text {
        color: Theme.textDim
        font.family: Theme.fontFamily
        font.pixelSize: Theme.fontSize - 2
        elide: Text.ElideRight
    }

    component Heading: Text {
        color: Theme.text
        font.family: Theme.fontFamily
        font.pixelSize: Theme.fontSize - 1
        font.bold: true
    }

    // Icon-only toggle button (mute).
    component IconButton: Rectangle {
        id: btn
        property string glyph
        property bool active: false
        signal clicked
        width: 30
        height: 26
        radius: Theme.rounding - 3
        color: active ? Qt.rgba(1, 1, 1, 0.14) : (ma.containsMouse ? Qt.rgba(1, 1, 1, 0.08) : Qt.rgba(1, 1, 1, 0.04))
        border.color: Theme.border
        border.width: 1
        Text {
            anchors.centerIn: parent
            text: btn.glyph
            font.family: Theme.iconFontFamily
            font.pixelSize: Theme.fontSize
            color: btn.active ? Theme.red : Theme.text
        }
        MouseArea {
            id: ma
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: btn.clicked()
        }
    }

    // Horizontal 0..150% slider.
    component VolumeSlider: Item {
        id: sl
        property real value: 0
        property bool dimmed: false
        signal moved(real v)
        height: 22
        readonly property real maxValue: 1.5

        Rectangle {
            id: track
            anchors.verticalCenter: parent.verticalCenter
            width: parent.width
            height: 6
            radius: 3
            color: Qt.rgba(1, 1, 1, 0.1)
            Rectangle {
                width: Math.min(1, sl.value / sl.maxValue) * parent.width
                height: parent.height
                radius: 3
                color: sl.dimmed ? Theme.muted : (sl.value > 1 ? Theme.orange : Theme.cyan)
            }
            // 100% tick
            Rectangle {
                x: parent.width / sl.maxValue - 1
                y: -3
                width: 1
                height: parent.height + 6
                color: Theme.muted
            }
        }
        Rectangle {
            x: Math.min(1, sl.value / sl.maxValue) * (track.width - width)
            anchors.verticalCenter: parent.verticalCenter
            width: 12
            height: 12
            radius: 6
            color: Theme.text
        }
        MouseArea {
            anchors.fill: parent
            cursorShape: Qt.PointingHandCursor
            function setFrom(mx) {
                const v = Math.max(0, Math.min(1, mx / width)) * sl.maxValue;
                sl.moved(Math.round(v * 100) / 100);
            }
            onPressed: mouse => setFrom(mouse.x)
            onPositionChanged: mouse => { if (pressed) setFrom(mouse.x); }
        }
    }

    Column {
        id: content
        x: 12
        y: 12
        width: parent.width - 24
        spacing: 10

        // ---- Output -----------------------------------------------------
        Row {
            width: parent.width
            spacing: 8
            Heading { text: qsTr("Output"); anchors.verticalCenter: parent.verticalCenter }
            Label {
                anchors.verticalCenter: parent.verticalCenter
                width: parent.width - x - 0
                text: AudioSvc.sinkDescription || qsTr("no output device")
            }
        }
        Row {
            width: parent.width
            spacing: 10
            IconButton {
                glyph: AudioSvc.muted ? Icons.volMuted : (AudioSvc.sinkBluetooth ? Icons.volHeadphone : Icons.levelIcon(Icons.volLevels, Math.min(1, AudioSvc.volume)))
                active: AudioSvc.muted
                onClicked: AudioSvc.toggleMute()
            }
            VolumeSlider {
                width: parent.width - 30 - 52 - 20
                anchors.verticalCenter: parent.verticalCenter
                value: AudioSvc.volume
                dimmed: AudioSvc.muted
                onMoved: v => AudioSvc.setVolume(v)
            }
            Text {
                width: 52
                anchors.verticalCenter: parent.verticalCenter
                horizontalAlignment: Text.AlignRight
                text: AudioSvc.muted ? qsTr("muted") : AudioSvc.percent + "%"
                color: AudioSvc.muted ? Theme.muted : Theme.text
                font.family: Theme.fontFamily
                font.pixelSize: Theme.fontSize - 1
            }
        }

        // ---- Bluetooth profiles ----------------------------------------
        Repeater {
            model: AudioSvc.btCards

            delegate: Column {
                id: card
                required property var modelData
                width: content.width
                spacing: 4

                Row {
                    width: parent.width
                    spacing: 8
                    Heading { text: qsTr("Bluetooth profile"); anchors.verticalCenter: parent.verticalCenter }
                    Label {
                        anchors.verticalCenter: parent.verticalCenter
                        width: parent.width - x
                        text: card.modelData.description
                    }
                }

                Repeater {
                    model: card.modelData.profiles

                    delegate: Rectangle {
                        id: prof
                        required property var modelData
                        readonly property bool selected: modelData.name === card.modelData.activeProfile
                        width: card.width
                        height: 26
                        radius: Theme.rounding - 3
                        opacity: modelData.available ? 1 : 0.4
                        color: profMa.containsMouse ? Qt.rgba(1, 1, 1, 0.08) : (selected ? Qt.rgba(1, 1, 1, 0.05) : "transparent")

                        // Radio dot
                        Rectangle {
                            id: radio
                            x: 6
                            anchors.verticalCenter: parent.verticalCenter
                            width: 14
                            height: 14
                            radius: 7
                            color: "transparent"
                            border.color: prof.selected ? Theme.cyan : Theme.muted
                            border.width: 1.5
                            Rectangle {
                                anchors.centerIn: parent
                                width: 8
                                height: 8
                                radius: 4
                                color: Theme.cyan
                                visible: prof.selected
                            }
                        }
                        Text {
                            anchors.left: radio.right
                            anchors.leftMargin: 8
                            anchors.right: parent.right
                            anchors.rightMargin: 6
                            anchors.verticalCenter: parent.verticalCenter
                            text: prof.modelData.description
                            elide: Text.ElideRight
                            color: prof.selected ? Theme.text : Theme.textDim
                            font.family: Theme.fontFamily
                            font.pixelSize: Theme.fontSize - 2
                            font.bold: prof.selected
                        }
                        MouseArea {
                            id: profMa
                            anchors.fill: parent
                            hoverEnabled: true
                            enabled: prof.modelData.available
                            cursorShape: Qt.PointingHandCursor
                            onClicked: AudioSvc.setProfile(card.modelData.name, prof.modelData.name)
                        }
                    }
                }
            }
        }

        // ---- Input ------------------------------------------------------
        Row {
            width: parent.width
            spacing: 8
            Heading { text: qsTr("Input"); anchors.verticalCenter: parent.verticalCenter }
            Label {
                anchors.verticalCenter: parent.verticalCenter
                width: parent.width - x
                text: AudioSvc.sourceDescription || qsTr("no input device")
            }
        }
        Row {
            width: parent.width
            spacing: 10
            IconButton {
                glyph: AudioSvc.sourceMuted ? "\uf131" : "\uf130"
                active: AudioSvc.sourceMuted
                onClicked: AudioSvc.toggleSourceMute()
            }
            Rectangle {
                width: parent.width - 30 - 52 - 20
                anchors.verticalCenter: parent.verticalCenter
                height: 6
                radius: 3
                color: Qt.rgba(1, 1, 1, 0.1)
                Rectangle {
                    width: Math.min(1, AudioSvc.sourceVolume) * parent.width
                    height: parent.height
                    radius: 3
                    color: AudioSvc.sourceMuted ? Theme.muted : Theme.green
                }
            }
            Text {
                width: 52
                anchors.verticalCenter: parent.verticalCenter
                horizontalAlignment: Text.AlignRight
                text: AudioSvc.sourceMuted ? qsTr("muted") : Math.round(AudioSvc.sourceVolume * 100) + "%"
                color: AudioSvc.sourceMuted ? Theme.muted : Theme.text
                font.family: Theme.fontFamily
                font.pixelSize: Theme.fontSize - 1
            }
        }

        // ---- Streams + server state ------------------------------------
        Column {
            width: parent.width
            spacing: 3
            Label {
                width: parent.width
                text: qsTr("Playing: ") + (AudioSvc.playbackApps.length ? AudioSvc.playbackApps.join(", ") : qsTr("nothing"))
            }
            Label {
                width: parent.width
                text: qsTr("Recording: ") + (AudioSvc.captureApps.length ? AudioSvc.captureApps.join(", ") : qsTr("nothing"))
            }
            Label {
                width: parent.width
                text: "PipeWire " + (AudioSvc.pipewireVersion || "?")
                    + "  ·  WirePlumber " + (AudioSvc.wireplumberVersion || "?")
            }
        }
    }
}

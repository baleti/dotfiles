import QtQuick
import Quickshell
import Quickshell.Services.Mpris
import "../theme"
import "../services"

// Hover-down expansion of the compact media pill: album art, full title/
// artist/album, a draggable seekbar, and transport controls.
Rectangle {
    id: root

    readonly property MprisPlayer player: Players.active
    readonly property bool hasPlayer: !!player
    readonly property bool hovered: mouseArea.containsMouse
    property bool expanded: false

    property real basePos: 0
    property real baseEpoch: 0
    property bool dragging: false

    function resync(): void {
        if (dragging)
            return;
        basePos = player ? player.position : 0;
        baseEpoch = Date.now() / 1000;
        displayPos = basePos;
    }

    property real displayPos: 0

    onPlayerChanged: resync()
    Component.onCompleted: resync()

    Connections {
        target: root.player
        function onPositionChanged(): void { root.resync(); }
        function onTrackTitleChanged(): void { root.resync(); }
    }

    Timer {
        interval: 500
        running: root.hasPlayer && root.player.isPlaying && !root.dragging
        repeat: true
        onTriggered: {
            const elapsed = (Date.now() / 1000) - root.baseEpoch;
            root.displayPos = Math.min(root.basePos + elapsed * (root.player.rate || 1), root.player.length || 0);
        }
    }

    function fmtTime(s: real): string {
        if (!s || s <= 0)
            return "0:00";
        const total = Math.floor(s);
        const h = Math.floor(total / 3600);
        const m = Math.floor((total % 3600) / 60);
        const sec = total % 60;
        const mm = h > 0 ? String(m).padStart(2, "0") : String(m);
        const ss = String(sec).padStart(2, "0");
        return h > 0 ? `${h}:${mm}:${ss}` : `${mm}:${ss}`;
    }

    width: 320
    implicitHeight: (hasPlayer && expanded) ? content.implicitHeight + 24 : 0
    height: implicitHeight
    visible: height > 0
    radius: Theme.rounding
    color: Theme.bgAlpha
    border.color: Theme.border
    border.width: 1
    clip: true

    MouseArea {
        id: mouseArea
        anchors.fill: parent
        hoverEnabled: true
        // Absorb clicks/scroll so they don't fall through to whatever
        // window sits underneath this overlay.
        acceptedButtons: Qt.AllButtons
        onWheel: wheel => wheel.accepted = true
    }

    Column {
        id: content
        x: 12
        y: 12
        width: parent.width - 24
        spacing: 10

        Row {
            width: parent.width
            spacing: 12

            Rectangle {
                id: artFrame
                width: 64
                height: 64
                radius: Theme.rounding - 2
                color: Qt.rgba(1, 1, 1, 0.05)
                clip: true

                Image {
                    anchors.fill: parent
                    source: root.player ? Players.getArtUrl(root.player) : ""
                    fillMode: Image.PreserveAspectCrop
                    asynchronous: true
                    visible: status === Image.Ready
                }

                Text {
                    anchors.centerIn: parent
                    visible: parent.children[0].status !== Image.Ready
                    text: Icons.play
                    font.family: Theme.iconFontFamily
                    font.pixelSize: 20
                    color: Theme.muted
                }
            }

            Column {
                width: parent.width - artFrame.width - 12
                anchors.verticalCenter: artFrame.verticalCenter
                spacing: 2

                Text {
                    width: parent.width
                    text: root.player ? Players.getIdentity(root.player) : ""
                    color: Theme.textDim
                    font.family: Theme.fontFamily
                    font.pixelSize: Theme.fontSize - 2
                    elide: Text.ElideRight
                }

                Text {
                    width: parent.width
                    text: root.player?.trackTitle ?? ""
                    color: Theme.text
                    font.family: Theme.fontFamily
                    font.pixelSize: Theme.fontSize + 1
                    font.bold: true
                    elide: Text.ElideRight
                }

                Text {
                    width: parent.width
                    text: root.player?.trackArtist ?? ""
                    color: Theme.textDim
                    font.family: Theme.fontFamily
                    font.pixelSize: Theme.fontSize - 1
                    elide: Text.ElideRight
                    visible: text.length > 0
                }
            }
        }

        Column {
            width: parent.width
            spacing: 4
            visible: (root.player?.length ?? 0) > 0

            Rectangle {
                id: seekTrack
                width: parent.width
                height: 5
                radius: 2.5
                color: Qt.rgba(1, 1, 1, 0.12)

                readonly property real frac: root.player?.length ? Math.min(root.displayPos / root.player.length, 1) : 0

                Rectangle {
                    width: seekTrack.width * seekTrack.frac
                    height: parent.height
                    radius: parent.radius
                    color: Theme.cyan
                }

                Rectangle {
                    x: seekTrack.width * seekTrack.frac - width / 2
                    anchors.verticalCenter: parent.verticalCenter
                    width: 11
                    height: 11
                    radius: 5.5
                    color: Theme.cyan
                    visible: root.player?.canSeek ?? false
                }

                MouseArea {
                    anchors.fill: parent
                    anchors.margins: -6
                    enabled: root.player?.canSeek ?? false
                    cursorShape: Qt.PointingHandCursor

                    function seekTo(mx: real): void {
                        // mx is relative to this MouseArea, which is 6px
                        // larger than seekTrack on every side (anchors.margins:
                        // -6, for an easier-to-hit target) -- undo that offset
                        // before scaling against the track's own width.
                        const relX = mx - 6;
                        const frac = Math.max(0, Math.min(1, relX / seekTrack.width));
                        root.dragging = true;
                        root.displayPos = frac * root.player.length;
                    }

                    onPressed: mouse => seekTo(mouse.x)
                    onPositionChanged: mouse => { if (pressed) seekTo(mouse.x); }
                    onReleased: mouse => {
                        if (root.player?.canSeek) {
                            // MprisPlayer.position (SetPosition) isn't
                            // implemented by the phone bridge, only the
                            // relative Seek method -- see
                            // pixel6-mpris-bridge.py / mpris-widget notes.
                            // seek() works generically for every player.
                            root.player.seek(root.displayPos - root.player.position);
                            root.basePos = root.displayPos;
                            root.baseEpoch = Date.now() / 1000;
                        }
                        root.dragging = false;
                    }
                }
            }

            Item {
                width: parent.width
                height: posLabel.implicitHeight

                Text {
                    id: posLabel
                    anchors.left: parent.left
                    text: root.fmtTime(root.displayPos)
                    color: Theme.textDim
                    font.family: Theme.fontFamily
                    font.pixelSize: Theme.fontSize - 2
                }

                Text {
                    anchors.right: parent.right
                    text: root.fmtTime(root.player?.length ?? 0)
                    color: Theme.textDim
                    font.family: Theme.fontFamily
                    font.pixelSize: Theme.fontSize - 2
                }
            }
        }

        Row {
            anchors.horizontalCenter: parent.horizontalCenter
            spacing: 18

            Text {
                text: Icons.prev
                font.family: Theme.iconFontFamily
                font.pixelSize: Theme.fontSize + 3
                color: (root.player?.canGoPrevious ?? false) ? Theme.text : Theme.muted
                MouseArea {
                    anchors.fill: parent
                    anchors.margins: -6
                    enabled: root.player?.canGoPrevious ?? false
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.player.previous()
                }
            }

            Text {
                text: root.hasPlayer && root.player.isPlaying ? Icons.pause : Icons.play
                font.family: Theme.iconFontFamily
                font.pixelSize: Theme.fontSize + 6
                color: Theme.cyan
                MouseArea {
                    anchors.fill: parent
                    anchors.margins: -6
                    enabled: root.player?.canTogglePlaying ?? false
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.player.togglePlaying()
                }
            }

            Text {
                text: Icons.next
                font.family: Theme.iconFontFamily
                font.pixelSize: Theme.fontSize + 3
                color: (root.player?.canGoNext ?? false) ? Theme.text : Theme.muted
                MouseArea {
                    anchors.fill: parent
                    anchors.margins: -6
                    enabled: root.player?.canGoNext ?? false
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.player.next()
                }
            }
        }
    }
}

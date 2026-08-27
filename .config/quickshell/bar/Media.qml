import QtQuick
import Quickshell
import Quickshell.Services.Mpris
import "../theme"
import "../services"

// custom/mpris equivalent, narrower than the old bash-script pill and with a
// real play/pause glyph instead of an empty one. Click toggles play/pause,
// scroll next/previous, middle-click opens the existing player picker --
// same interactions as the old waybar module, same playerctl-current file
// as the source of truth (see services/Players.qml). Self-contained pill
// (own background, unlike the other bar widgets) so Bar.qml can reference
// it directly by id for the hover-expand panel below it.
Rectangle {
    id: root

    color: Theme.bgAlpha
    border.color: Theme.border
    border.width: 1
    radius: Theme.rounding

    readonly property MprisPlayer player: Players.active
    readonly property bool hasPlayer: !!player
    readonly property bool hovered: mouseArea.containsMouse

    // Interpolated position: MprisPlayer.position is query-time computed,
    // not signalled, so smooth ticking needs its own timer. Elapsed time is
    // scaled by the player's own Rate (non-1x playback, e.g. NewPipe at
    // 1.73x) -- see /tmp/mpris-widget-notes-for-quickshell.md.
    property real basePos: 0
    property real baseEpoch: 0

    function resync(): void {
        basePos = player ? player.position : 0;
        baseEpoch = Date.now() / 1000;
    }

    property real displayPos: basePos

    onPlayerChanged: resync()

    Connections {
        target: root.player
        function onPositionChanged(): void { root.resync(); }
        function onTrackTitleChanged(): void { root.resync(); }
    }

    Timer {
        interval: 1000
        running: root.hasPlayer && root.player.isPlaying
        repeat: true
        onTriggered: {
            const elapsed = (Date.now() / 1000) - root.baseEpoch;
            root.displayPos = Math.min(root.basePos + elapsed * (root.player.rate || 1), root.player.length || 0);
        }
    }

    function fmtTime(s: real): string {
        if (!s || s <= 0)
            return "";
        const total = Math.floor(s);
        const h = Math.floor(total / 3600);
        const m = Math.floor((total % 3600) / 60);
        const sec = total % 60;
        const mm = h > 0 ? String(m).padStart(2, "0") : String(m);
        const ss = String(sec).padStart(2, "0");
        return h > 0 ? `${h}:${mm}:${ss}` : `${mm}:${ss}`;
    }

    readonly property string trackText: {
        if (!hasPlayer)
            return "";
        const artist = player.trackArtist;
        const title = player.trackTitle || "";
        let t = artist ? `${artist} - ${title}` : title;
        const max = 28;
        if (t.length > max)
            t = t.slice(0, max - 1) + "…";
        return t;
    }

    readonly property string timeText: {
        if (!hasPlayer || !player.length)
            return "";
        return `${fmtTime(displayPos)}/${fmtTime(player.length)}`;
    }

    visible: hasPlayer
    implicitWidth: hasPlayer ? pillRow.implicitWidth + Theme.pillPadH * 2 : 0
    implicitHeight: Theme.barHeight - 10
    width: implicitWidth
    height: implicitHeight

    Row {
        id: pillRow
        anchors.centerIn: parent
        spacing: 6

        Text {
            text: root.hasPlayer && root.player.isPlaying ? Icons.play : Icons.pause
            font.family: Theme.iconFontFamily
            font.pixelSize: Theme.fontSize
            color: root.hasPlayer && root.player.isPlaying ? Theme.cyan : Theme.muted
        }

        Text {
            text: root.trackText
            font.family: Theme.fontFamily
            font.pixelSize: Theme.fontSize
            color: root.hasPlayer && root.player.isPlaying ? Theme.text : Theme.muted
        }

        Text {
            visible: root.timeText.length > 0
            text: root.timeText
            font.family: Theme.fontFamily
            font.pixelSize: Theme.fontSize - 1
            color: Theme.textDim
        }
    }

    MouseArea {
        id: mouseArea
        anchors.fill: parent
        hoverEnabled: true
        acceptedButtons: Qt.LeftButton | Qt.MiddleButton
        cursorShape: Qt.PointingHandCursor
        onClicked: mouse => {
            if (!root.hasPlayer)
                return;
            if (mouse.button === Qt.LeftButton && root.player.canTogglePlaying)
                root.player.togglePlaying();
            else if (mouse.button === Qt.MiddleButton)
                Quickshell.execDetached(["/home/user1/.config/hypr/scripts/playerctl-picker.sh"]);
        }
        onWheel: wheel => {
            if (!root.hasPlayer)
                return;
            if (wheel.angleDelta.y > 0 && root.player.canGoNext)
                root.player.next();
            else if (wheel.angleDelta.y < 0 && root.player.canGoPrevious)
                root.player.previous();
        }
    }
}

import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Services.Mpris
import "../theme"
import "../services"

// Modal player picker for ALT+CTRL+SHIFT+m (keybinds.lua -> `qs ipc call
// mprisPicker toggle`) and the media pill's middle-click (Media.qml).
// Reimplements the old ~/.config/hypr/scripts/playerctl-picker.sh zenity
// dialog as a themed overlay matching the bar's other panels.
//
// Same contract as that script, so nothing downstream regresses:
//   - writes the bare playerctl player name (MprisPlayer.dbusName minus the
//     "org.mpris.MediaPlayer2." prefix, no trailing newline) to
//     ~/.config/playerctl-current -- the single source of truth shared with
//     the Hyprland playerctl binds, playerctl-seek.sh / playerctl-volume.sh,
//     waybar-mpris.sh and services/Players.qml.
//   - lists every MPRIS player, playing or not (Mpris.players == `playerctl
//     --list-all` here; Players.qml already leans on that equivalence).
//   - the current player is pre-highlighted.
//   - Escape / click-away / a second keybind press never touch the file.
//
// Not its own PanelWindow: a 3rd per-output layer-shell surface doesn't map
// reliably here (see [[quickshell_panelwindow_ipc_gotchas]]), so this is a
// plain Item filling the already-mapped bar PanelWindow, shown only on the
// monitor MprisPickerState latched at open time. shell.qml widens that
// window's input mask and hands it keyboard focus while `showing`.
Item {
    id: root

    required property string screenName

    readonly property bool showing: MprisPickerState.active
        && MprisPickerState.monitor === root.screenName

    readonly property var players: Mpris.players.values
    property int index: 0

    function nameOf(player): string {
        const prefix = "org.mpris.MediaPlayer2.";
        const n = player?.dbusName ?? "";
        return n.startsWith(prefix) ? n.slice(prefix.length) : n;
    }

    // Pre-select whatever Players.qml currently treats as active (driven by
    // the same playerctl-current file), falling back to the first row.
    function syncIndex(): void {
        const want = Players.active;
        const i = want ? root.players.indexOf(want) : -1;
        root.index = i >= 0 ? i : 0;
    }

    function move(delta: int): void {
        const n = root.players.length;
        if (n === 0)
            return;
        root.index = ((root.index + delta) % n + n) % n;
    }

    function commit(): void {
        const player = root.players[root.index];
        if (player)
            currentFile.setText(root.nameOf(player));
        MprisPickerState.close();
    }

    onShowingChanged: if (showing) syncIndex()

    FileView {
        id: currentFile
        path: `${Quickshell.env("HOME")}/.config/playerctl-current`
        // atomicWrites: false => truncate-and-write the same inode, exactly
        // like the old script's `printf '%s' > file`. services/Players.qml
        // (and Background.qml) watch this path with a file watcher that was
        // built and proven against that in-place write; an atomic
        // temp-file+rename swaps the inode and can leave that watch stale.
        // The "never truncate on cancel" guarantee comes from only ever
        // calling setText() on an explicit pick, not from atomic writes.
        atomicWrites: false
        printErrors: false
    }

    anchors.fill: parent
    visible: showing

    Keys.onPressed: event => {
        if (event.key === Qt.Key_Escape) {
            MprisPickerState.close();
        } else if (event.key === Qt.Key_Up || event.key === Qt.Key_K) {
            root.move(-1);
        } else if (event.key === Qt.Key_Down || event.key === Qt.Key_J) {
            root.move(1);
        } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
            root.commit();
        } else if (event.key >= Qt.Key_1 && event.key <= Qt.Key_9) {
            const i = event.key - Qt.Key_1;
            if (i < root.players.length) {
                root.index = i;
                root.commit();
            }
        }
        // Modal grab -- swallow every key while open so nothing leaks to the
        // bar's own panels or the window underneath.
        event.accepted = true;
    }

    // Dim backdrop; a click anywhere outside the card dismisses without
    // touching the file.
    Rectangle {
        anchors.fill: parent
        color: Qt.rgba(0, 0, 0, 0.35)

        MouseArea {
            anchors.fill: parent
            acceptedButtons: Qt.AllButtons
            onClicked: MprisPickerState.close()
            onWheel: wheel => wheel.accepted = true
        }
    }

    Rectangle {
        id: card
        anchors.centerIn: parent
        width: Math.min(420, root.width - 80)
        implicitHeight: cardCol.implicitHeight + 24
        radius: Theme.rounding
        color: Theme.bgAlpha
        border.color: Theme.border
        border.width: 1

        // Absorb clicks on the card itself so they don't fall through to the
        // backdrop's dismiss handler.
        MouseArea {
            anchors.fill: parent
            acceptedButtons: Qt.AllButtons
            onWheel: wheel => wheel.accepted = true
        }

        Column {
            id: cardCol
            x: 12
            y: 12
            width: parent.width - 24
            spacing: 6

            Text {
                text: qsTr("Choose player")
                color: Theme.text
                font.family: Theme.fontFamily
                font.pixelSize: Theme.fontSize
                font.bold: true
                bottomPadding: 2
            }

            Text {
                visible: root.players.length === 0
                width: parent.width
                text: qsTr("No media players")
                color: Theme.muted
                font.family: Theme.fontFamily
                font.pixelSize: Theme.fontSize - 1
            }

            Repeater {
                model: root.players

                Rectangle {
                    id: rowItem
                    required property var modelData
                    required property int index

                    width: parent.width
                    implicitHeight: rowCol.implicitHeight + 12
                    radius: Theme.rounding - 4
                    readonly property bool selected: rowItem.index === root.index
                    color: selected ? Qt.rgba(Theme.cyan.r, Theme.cyan.g, Theme.cyan.b, 0.18)
                        : (rowMouse.containsMouse ? Qt.rgba(1, 1, 1, 0.05) : "transparent")
                    border.color: selected ? Theme.cyan : "transparent"
                    border.width: 1

                    Column {
                        id: rowCol
                        x: 8
                        y: 6
                        width: parent.width - 40
                        spacing: 1

                        Text {
                            width: parent.width
                            elide: Text.ElideRight
                            textFormat: Text.PlainText
                            text: rowItem.modelData.identity || root.nameOf(rowItem.modelData)
                            color: Theme.text
                            font.family: Theme.fontFamily
                            font.pixelSize: Theme.fontSize - 1
                        }

                        Text {
                            width: parent.width
                            elide: Text.ElideRight
                            textFormat: Text.PlainText
                            visible: text.length > 0
                            text: {
                                const t = rowItem.modelData.trackTitle || "";
                                const a = rowItem.modelData.trackArtist || "";
                                return (a && t) ? `${a} - ${t}` : (t || a);
                            }
                            color: Theme.textDim
                            font.family: Theme.fontFamily
                            font.pixelSize: Theme.fontSize - 3
                        }
                    }

                    Text {
                        anchors.right: parent.right
                        anchors.rightMargin: 10
                        anchors.verticalCenter: parent.verticalCenter
                        visible: rowItem.modelData.isPlaying
                        text: Icons.play
                        font.family: Theme.iconFontFamily
                        font.pixelSize: Theme.fontSize - 3
                        color: Theme.cyan
                    }

                    MouseArea {
                        id: rowMouse
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: {
                            root.index = rowItem.index;
                            root.commit();
                        }
                    }
                }
            }

            Text {
                width: parent.width
                horizontalAlignment: Text.AlignHCenter
                topPadding: 2
                color: Theme.muted
                font.family: Theme.fontFamily
                font.pixelSize: Theme.fontSize - 3
                text: qsTr("↑↓ / jk move · Enter pick · Esc cancel")
            }
        }
    }
}

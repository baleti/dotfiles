import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import "../theme"

// mod+F11/F12 (~/.config/hypr/scripts/playerctl-volume.sh) POSTs here via
// `qs ipc call volume-osd-<screen> display <percent> <muted>` -- one
// instance per monitor (shell.qml's Variants over Quickshell.screens), only
// the currently-focused one is ever actually told to show. Purely a
// display: no mouse/keyboard focus, fully click-through, so it never steals
// input from whatever's underneath.
//
// The IpcHandler function is named `display`, not `show`: `qs ipc call
// <target> show ...` collides with the CLI's own `qs ipc show` subcommand
// at the argument-parsing level (confirmed live - it accepted a bare `qs
// ipc call <target> show` but rejected any arguments after it, "the
// following argument was not expected"). Reserved-word collision, not a bug
// in this file - just don't name an IPC function `show`.
PanelWindow {
    id: root

    required property ShellScreen screen

    property real fraction: 0
    property bool muted: false

    function apply(percent: real, isMuted: bool): void {
        root.fraction = Math.max(0, Math.min(100, percent)) / 100;
        root.muted = isMuted;
        card.visible = true;
        hideTimer.restart();
    }

    anchors {
        top: true
        bottom: true
        right: true
    }
    implicitWidth: 74
    color: "transparent"

    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
    // Never reserves screen space (confirmed live: without this, tiled
    // windows visibly narrowed by implicitWidth even though the card is
    // hidden almost all the time) - same property Background.qml uses.
    WlrLayershell.exclusionMode: ExclusionMode.Ignore
    // Empty region: the whole surface passes every click/hover straight
    // through to the window underneath, same trick Bar's PanelWindow uses
    // in reverse (there, the mask carves out the one area that SHOULD
    // accept input; here nothing should).
    mask: Region {}

    Rectangle {
        id: card
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        anchors.rightMargin: 14
        width: 46
        height: 150
        radius: Theme.rounding
        color: Theme.bgAlpha
        border.color: Theme.border
        border.width: 1
        visible: false
        opacity: visible ? 1 : 0

        Behavior on opacity {
            NumberAnimation { duration: 120 }
        }

        Column {
            anchors.centerIn: parent
            spacing: 10

            Text {
                anchors.horizontalCenter: parent.horizontalCenter
                text: root.muted ? Icons.volMuted : Icons.levelIcon(Icons.volLevels, root.fraction)
                font.family: Theme.iconFontFamily
                font.pixelSize: 18
                color: root.muted ? Theme.muted : Theme.text
            }

            Rectangle {
                id: track
                anchors.horizontalCenter: parent.horizontalCenter
                width: 6
                height: 90
                radius: 3
                color: Qt.rgba(1, 1, 1, 0.12)

                Rectangle {
                    anchors.bottom: parent.bottom
                    width: parent.width
                    height: track.height * root.fraction
                    radius: parent.radius
                    color: root.muted ? Theme.muted : Theme.cyan

                    Behavior on height {
                        NumberAnimation { duration: 100 }
                    }
                }
            }

            Text {
                anchors.horizontalCenter: parent.horizontalCenter
                text: Math.round(root.fraction * 100) + "%"
                font.family: Theme.fontFamily
                font.pixelSize: Theme.fontSize - 2
                color: Theme.textDim
            }
        }
    }

    // Auto-hide -- no dismiss interaction exists (nor should it, given the
    // window is click-through), so this is the only thing that ever hides it.
    Timer {
        id: hideTimer
        interval: 1200
        onTriggered: card.visible = false
    }

    IpcHandler {
        target: "volume-osd-" + root.screen.name
        function display(percent: real, muted: bool): void { root.apply(percent, muted); }
    }
}

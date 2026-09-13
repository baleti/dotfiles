import QtQuick
import Quickshell
import Quickshell.Wayland
import Quickshell.Hyprland
import "../theme"
import "../services"

// mod+F11/F12 (~/.config/hypr/scripts/playerctl-volume.sh) calls
// `qs ipc call volume-osd display <percent> <muted>` -> VolumeOsdSvc (a
// singleton, one process-wide instance) -> every VolumeOsd instance here
// (one per monitor, shell.qml's Variants over Quickshell.screens) picks it
// up and only the one on Hyprland's currently focused monitor actually
// draws -- same split NotifLayer uses (NotifSvc for state, per-screen
// PanelWindow gated on Hyprland.focusedMonitor for display).
//
// FIXED 2026-09-13 (was: "only reliably shows on DP-1", see
// [[quickshell_panelwindow_ipc_gotchas]]): the actual bug was a
// `required property ShellScreen screen` on this PanelWindow shadowing its
// own built-in `screen` property, so shell.qml's `VolumeOsd { screen:
// modelData }` never actually placed each Variants delegate on its own
// output -- all three piled onto whichever screen was left as the (unset)
// default, duplicating there across hot reloads while the other two
// outputs got nothing. Full-screen-vs-sized anchoring and on-demand-vs-
// always-mapped were red herrings from the original investigation; see the
// memory file for the corrected writeup. Fixed by removing the
// redeclaration (below) -- same as NotifLayer.qml always did.
//
// This also changes monitor selection to match notifications' behaviour
// (mouse-follows-focus, via Hyprland.focusedMonitor) instead of the old
// script-side "active window's monitor" logic -- what the user actually
// asked for ("show on screen with current focus, like notifications").
PanelWindow {
    id: root

    // Do NOT redeclare `screen` here -- PanelWindow already has one, and a
    // `required property ShellScreen screen` shadows it. shell.qml's
    // `VolumeOsd { screen: modelData }` then sets the shadow property
    // instead of the real placement one, so every Variants delegate ends up
    // on whatever the real (unset) screen defaults to -- which is why every
    // instance piled onto ONE actual output (duplicating there across
    // reloads) while the other outputs got none. This was mistaken for a
    // per-output Hyprland/wlroots layer-shell limit (see
    // [[quickshell_panelwindow_ipc_gotchas]]) but the real bug was here the
    // whole time; NotifLayer.qml's own comment already flagged this exact
    // trap on this exact file, it just never got fixed here until now
    // (2026-09-13).
    readonly property bool onFocusedMonitor:
        (Hyprland.focusedMonitor?.name ?? "") === root.screen.name

    property bool active: false

    // Right-edge, screen-height strip -- sized like NotifLayer's corner
    // box, not full-screen. Not required for the per-output mapping fix
    // (that was the shadowed `screen` property above); kept anyway to
    // match NotifLayer's proven-reliable shape rather than the old
    // full-screen-anchors approach.
    anchors {
        top: true
        bottom: true
        right: true
    }
    implicitWidth: card.width + 36
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

    Connections {
        target: VolumeOsdSvc
        function onRevisionChanged() {
            root.active = true;
            hideTimer.restart();
        }
    }

    Timer {
        id: hideTimer
        interval: 1200
        onTriggered: root.active = false
    }

    Rectangle {
        id: card
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        anchors.rightMargin: 18
        width: 56
        height: 240
        radius: Theme.rounding
        color: Theme.bgAlpha
        border.color: Theme.border
        border.width: 1
        visible: root.active && root.onFocusedMonitor
        opacity: visible ? 1 : 0

        Behavior on opacity {
            NumberAnimation { duration: 120 }
        }

        Column {
            anchors.centerIn: parent
            spacing: 14

            Text {
                anchors.horizontalCenter: parent.horizontalCenter
                text: VolumeOsdSvc.muted ? Icons.volMuted : Icons.levelIcon(Icons.volLevels, VolumeOsdSvc.fraction)
                font.family: Theme.iconFontFamily
                font.pixelSize: 26
                color: VolumeOsdSvc.muted ? Theme.muted : Theme.text
            }

            Rectangle {
                id: track
                anchors.horizontalCenter: parent.horizontalCenter
                width: 8
                height: 126
                radius: 4
                color: Qt.rgba(1, 1, 1, 0.12)

                Rectangle {
                    anchors.bottom: parent.bottom
                    width: parent.width
                    height: track.height * VolumeOsdSvc.fraction
                    radius: parent.radius
                    color: VolumeOsdSvc.muted ? Theme.muted : Theme.cyan

                    Behavior on height {
                        NumberAnimation { duration: 100 }
                    }
                }
            }

            Text {
                anchors.horizontalCenter: parent.horizontalCenter
                text: Math.round(VolumeOsdSvc.fraction * 100) + "%"
                font.family: Theme.fontFamily
                font.pixelSize: Theme.fontSize + 2
                color: Theme.textDim
            }
        }
    }
}

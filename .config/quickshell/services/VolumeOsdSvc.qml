pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

// Volume OSD trigger state, one singleton shared by every VolumeOsd.qml
// instance (osd/) -- mirrors NotifSvc's split of "one shared source of
// state" from "one PanelWindow per screen that decides for itself whether
// to draw". Previously each screen ran its own IpcHandler
// (target "volume-osd-<screen name>") and playerctl-volume.sh had to work
// out which single monitor to poke; that on-demand per-screen mapping only
// ever reliably showed up on DP-1 (see VolumeOsd.qml's history). Routing
// through one shared singleton instead means every VolumeOsd instance is
// always mapped (same trick NotifLayer uses) and just gates its own
// visibility on Hyprland.focusedMonitor, so it now follows focus the same
// way notification cards do.
Singleton {
    id: root

    property real fraction: 0
    property bool muted: false
    // Bumped on every display() call; VolumeOsd watches this (not fraction/
    // muted alone) so a repeat at an unchanged percent still retriggers the
    // auto-hide timer.
    property int revision: 0

    function display(percent: real, isMuted: bool): void {
        root.fraction = Math.max(0, Math.min(100, percent)) / 100;
        root.muted = isMuted;
        root.revision++;
    }

    IpcHandler {
        target: "volume-osd"
        function display(percent: real, muted: bool): void { root.display(percent, muted); }
    }
}

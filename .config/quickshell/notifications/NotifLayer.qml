import QtQuick
import Quickshell
import Quickshell.Wayland
import Quickshell.Hyprland
import "../theme"
import "../services"

// Notification popup stack. One instance per monitor (shell.qml's Variants),
// each always mapped -- the same "persistent transparent surface, input
// masked to just the live content" approach the bar uses, rather than the
// on-demand mapping the volume OSD does (which only reliably maps on one
// output here). Only the monitor Hyprland currently considers focused
// actually draws cards, matching notifyd's follow=mouse behaviour.
PanelWindow {
    id: root

    // `screen` is PanelWindow's own property -- set from shell.qml's
    // Variants. (Redeclaring it here shadows the real one and the surface
    // never lands on the right output -- that's the volume OSD's bug.)

    readonly property bool onFocusedMonitor:
        (Hyprland.focusedMonitor?.name ?? "") === root.screen.name

    // Top-right box, not full-screen -- a full-screen Overlay surface with
    // ExclusionMode.Ignore doesn't reliably map on every output here (same
    // symptom the volume OSD hit); a partially-anchored sized surface, like
    // the bar, does.
    anchors {
        top: true
        right: true
    }
    implicitWidth: 400
    implicitHeight: root.screen.height - Theme.barHeight
    color: "transparent"

    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
    WlrLayershell.exclusionMode: ExclusionMode.Ignore
    // Lets windowrules.lua target the cards for blur (opt-in per namespace
    // for layer-shell surfaces).
    WlrLayershell.namespace: "quickshell-notifications"

    // Only the card column's rectangle accepts input; everything else is
    // click-through. Explicit rect rather than `item:` -- the item form
    // walks the window tree and crashed on reload teardown.
    mask: Region {
        x: stack.x
        y: stack.y
        width: root.onFocusedMonitor ? stack.width : 0
        height: root.onFocusedMonitor ? stack.height : 0
    }

    Column {
        id: stack
        anchors.top: parent.top
        anchors.right: parent.right
        anchors.topMargin: 12
        anchors.rightMargin: 12
        spacing: 8
        visible: root.onFocusedMonitor

        Repeater {
            // Newest-first; the newest card sits at the top, closest to the
            // screen edge, same as notifyd's old reflow().
            model: root.onFocusedMonitor ? NotifSvc.popupModel : null

            NotifCard {
                required property var model
                notification: model.n
                cardWidth: 360
            }
        }
    }
}

import QtQuick
import Quickshell
import Quickshell.Wayland
import "../theme"
import "../services"

// Notification popup stack. One instance per monitor (shell.qml's Variants),
// each always mapped -- the same "persistent transparent surface, input
// masked to just the live content" approach the bar uses, rather than the
// on-demand mapping the volume OSD does (which only reliably maps on one
// output here). Which monitors actually draw cards, and which notifications
// each gets, is decided centrally by NotifSvc (focused monitor first, then
// monitors.json's overflow list, then timed rotation if even that overflows)
// -- this file just renders whatever slice NotifSvc.cardsFor() hands it.
PanelWindow {
    id: root

    // `screen` is PanelWindow's own property -- set from shell.qml's
    // Variants. (Redeclaring it here shadows the real one and the surface
    // never lands on the right output -- that's the volume OSD's bug.)

    readonly property bool isTarget: NotifSvc.orderedMonitors.indexOf(root.screen.name) >= 0
    readonly property var cards: root.isTarget ? NotifSvc.cardsFor(root.screen.name) : []

    // Top-right box, not full-screen -- a full-screen Overlay surface with
    // ExclusionMode.Ignore doesn't reliably map on every output here (same
    // symptom the volume OSD hit); a partially-anchored sized surface, like
    // the bar, does.
    anchors {
        top: true
        right: true
    }
    // ExclusionMode.Ignore below means this surface doesn't respect the
    // bar's exclusive zone on its own -- without an explicit top margin the
    // surface's top edge sits at the real screen edge (y=0), under the bar,
    // not below it. Shrinking implicitHeight alone (below) only trims the
    // bottom edge; it was never enough on its own, it just went unnoticed
    // on bigger/higher-res screens where the overlap was a thin sliver.
    margins {
        top: Theme.barHeight
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
        width: root.cards.length > 0 ? stack.width : 0
        height: root.cards.length > 0 ? stack.height : 0
    }

    Column {
        id: stack
        anchors.top: parent.top
        anchors.right: parent.right
        anchors.topMargin: 6 // matches Bar.qml's pill spacing
        anchors.rightMargin: 12
        spacing: 8
        visible: root.cards.length > 0

        Repeater {
            // Newest-first; the newest card sits at the top, closest to the
            // screen edge, same as notifyd's old reflow(). Which ids land
            // here (and on which monitor) comes from NotifSvc.cardsFor().
            model: root.cards

            NotifCard {
                required property var modelData
                notification: modelData
                cardWidth: 360
            }
        }
    }

    // Off-canvas (x is past the 400px-wide surface, so nothing here is ever
    // actually composited): one real NotifCard per current notification,
    // just to get its true wrapped-text implicitHeight and hand that to
    // NotifSvc. Every monitor does this redundantly for every notification
    // -- harmless, since height only depends on content/width, not screen --
    // so the paging math in NotifSvc always has real numbers instead of a
    // guess at how WordWrap will break lines.
    Column {
        x: -10000
        width: 360

        Repeater {
            model: NotifSvc.popupModel

            NotifCard {
                required property var model
                notification: model.n
                cardWidth: 360
                onImplicitHeightChanged: NotifSvc.reportHeight(model.n.id, implicitHeight)
                Component.onCompleted: NotifSvc.reportHeight(model.n.id, implicitHeight)
            }
        }
    }
}
